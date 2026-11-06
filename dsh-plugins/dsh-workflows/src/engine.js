/**
 * Motor de ejecución: una ejecución como máximo por sesión, solo en memoria.
 *
 * Estados de una ejecución:
 *   pending          espera a que la sesión quede libre para arrancar
 *   running          el agente está atendiendo el prompt de la fase actual
 *   waiting-input    fase `user`: el próximo mensaje que escribas la arranca
 *   waiting-confirm  fase terminada con "esperar tu OK": Continuar (con
 *                    instrucciones extra ocultas) o escribir un mensaje, que
 *                    arranca la fase siguiente
 *   error            la fase falló; Reintentar, Saltar o Detener
 *
 * Mientras una fase corre, escribir en el chat es el steer nativo de DSH: el
 * motor no lo toca.
 */
import { randomUUID } from 'node:crypto'
import { mkdir, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { artifactFile, createUserMessage, hasArtifacts, phaseMarker, renderArtifacts, renderInstructions, renderSkill } from './prompt.js'
import { WorkflowArtifacts } from './artifacts.js'

const SOURCE_KIND = 'workflow'

/** Raíz de los artefactos: fuera del repo, recuperada por la política de retención. */
export const SCRATCH_ROOT = join(homedir(), '.dsh', 'scratch', 'workflows')
const RETENTION_MS = 15 * 24 * 60 * 60 * 1000
const PRUNE_INTERVAL_MS = 24 * 60 * 60 * 1000

const sanitizeKey = (value) => {
  const clean = String(value ?? '').replace(/[^A-Za-z0-9_-]/g, '-').slice(0, 100).replace(/-+$/g, '')
  return clean === '' ? 'session' : clean
}

const pickConfig = (c) => ({ provider: c.provider, model: c.model, reasoningEffort: c.reasoningEffort })
const sameConfig = (a, b) => a.provider === b.provider && a.model === b.model && a.reasoningEffort === b.reasoningEffort
/** Config con ruta y esfuerzo de `base`; un esfuerzo ausente en la base se quita. */
function restoreConfig(config, base) {
  const { reasoningEffort: _drop, ...rest } = config
  return { ...rest, provider: base.provider, model: base.model, ...(base.reasoningEffort === undefined ? {} : { reasoningEffort: base.reasoningEffort }) }
}

export class WorkflowEngine {
  /**
   * @param ctx - contexto cordis con agents, sessionController, skills y logger.
   */
  constructor(ctx, { scratchRoot = SCRATCH_ROOT } = {}) {
    this.ctx = ctx
    this.scratchRoot = scratchRoot
    /** sessionId → ejecución activa */
    this.runs = new Map()
    /** sessionId → último fin (completado/detenido); no se persiste */
    this.notices = new Map()
    this.finishedRuns = new Map()
    /** sessionId → { base, applied }: config real de la sesión y la última que aplicó el plugin */
    this.configs = new Map()
    this.warnedCompaction = false
  }

  // ---------------------------------------------------------------- consultas

  state(sessionId) {
    const run = this.runs.get(sessionId)
    return {
      run: run === undefined ? null : this.view(run),
      notice: this.notices.get(sessionId) ?? null,
    }
  }

  async refreshState(sessionId) {
    const run = this.runs.get(sessionId) ?? this.finishedRuns.get(sessionId)
    if (run) {
      await run.artifacts.refresh()
      const notice = this.notices.get(sessionId)
      if (notice?.id === run.id) notice.files = run.artifacts.files
    }
    return this.state(sessionId)
  }

  view(run) {
    return {
      id: run.id,
      workflowId: run.workflow.id,
      name: run.workflow.name,
      phases: run.workflow.phases.map((p) => ({
        name: p.name,
        input: p.input,
        question: p.question,
        skills: p.skills,
        model: p.model,
        effort: p.effort,
        afterward: p.afterward,
        output: p.output ?? '',
      })),
      index: run.index,
      startIndex: run.startIndex,
      skipped: run.skipped,
      completed: [...run.completed],
      files: run.artifacts?.files ?? [],
      state: run.state,
      error: run.error ?? null,
      warnings: run.warnings,
      startedAt: run.startedAt,
      phaseStartedAt: run.phaseStartedAt,
    }
  }

  // ---------------------------------------------------------------- acciones

  async start({ sessionId, workflow, startIndex = 0, context = '', input = '' }) {
    if (!Number.isInteger(startIndex) || startIndex < 0 || startIndex >= workflow.phases.length) throw new Error('Fase de inicio inválida')
    if (this.runs.has(sessionId)) throw new Error('Ya hay un workflow en marcha en esta conversación')
    const resolved = await this.ctx.sessionController.resolveAgent(sessionId)
    if ('error' in resolved) throw new Error(`No se pudo abrir la conversación: ${resolved.error?.message ?? resolved.error?.code ?? 'desconocido'}`)
    if (this.runs.has(sessionId)) throw new Error('Ya hay un workflow en marcha en esta conversación')
    const run = {
      id: randomUUID(),
      sessionId,
      agent: resolved.agent,
      workflow: structuredClone(workflow),
      index: startIndex,
      startIndex,
      state: 'pending',
      pendingExtra: context.trim(),
      initialInput: input.trim() ? input : undefined,
      messageId: undefined,
      admitted: false,
      turnEnded: false,
      skipping: false,
      injected: false,
      token: 0,
      compacting: undefined,
      dir: join(this.scratchRoot, `${sanitizeKey(sessionId)}-${workflow.name}`),
      artifactMode: hasArtifacts(workflow),
      error: undefined,
      warnings: [],
      skipped: [],
      completed: [],
      startedAt: Date.now(),
      phaseStartedAt: Date.now(),
    }
    this.runs.set(sessionId, run)
    this.notices.delete(sessionId)
    this.finishedRuns.delete(sessionId)
    run.artifacts = new WorkflowArtifacts(run)
    await run.artifacts.initialize()
    void this.pruneOld()
    if (run.artifactMode) await mkdir(run.dir, { recursive: true }).catch(() => {})
    if (run.agent.status === 'idle') this.startPhase(run)
    return this.view(run)
  }

  stop(sessionId) {
    const run = this.require(sessionId)
    const agent = run.agent
    const busy = run.state === 'running' && agent.status === 'running'
    run.compacting?.controller.abort()
    this.finish(run, 'stopped')
    if (busy) agent.cancel({ kind: 'user' })
  }

  skip(sessionId) {
    const run = this.require(sessionId)
    if (!run.skipped.includes(run.index)) run.skipped.push(run.index)
    if (run.state === 'running' && run.agent.status === 'running') {
      run.skipping = true
      run.agent.cancel({ kind: 'user' })
      return
    }
    run.compacting?.controller.abort()
    this.advance(run)
  }

  continue(sessionId, extra = '') {
    const run = this.require(sessionId)
    if (run.state !== 'waiting-confirm') throw new Error('La fase actual no está esperando tu OK')
    run.pendingExtra = extra.trim()
    this.advance(run)
  }

  retry(sessionId) {
    const run = this.require(sessionId)
    if (run.state !== 'error') throw new Error('No hay ningún error que reintentar')
    if (run.agent.status !== 'idle') {
      run.state = 'pending'
      return
    }
    this.startPhase(run)
  }

  dismiss(sessionId) {
    this.notices.delete(sessionId)
    this.finishedRuns.delete(sessionId)
  }

  // ---------------------------------------------------------------- ciclo de fases

  require(sessionId) {
    const run = this.runs.get(sessionId)
    if (run === undefined) throw new Error('No hay ningún workflow en marcha en esta conversación')
    return run
  }

  live(run) {
    return this.runs.get(run.sessionId) === run
  }

  startPhase(run) {
    if (!this.live(run)) return
    const phase = run.workflow.phases[run.index]
    run.phaseStartedAt = Date.now()
    run.messageId = undefined
    run.admitted = false
    run.turnEnded = false
    run.skipping = false
    run.injected = false
    run.error = undefined
    run.token = (run.token ?? 0) + 1
    const initialInput = run.index === run.startIndex ? run.initialInput : undefined
    run.phaseHasUserInput = initialInput !== undefined
    if (phase.input === 'user' && initialInput === undefined) {
      run.state = 'waiting-input'
      this.compact(run, run.index)
      return
    }
    run.state = 'running'
    // Texto del composer o marca visible; instrucciones y extras ocultos en onPreStep.
    const message = createUserMessage({
      content: [{ type: 'text', text: initialInput ?? phaseMarker(run.workflow, run.index) }],
      source: { kind: SOURCE_KIND, part: 'prompt', runId: run.id, phase: run.index, workflow: run.workflow.name },
    })
    // Desde la fase 2, la petición de resumen de contexto va antes del mensaje de la fase.
    const pending = this.compact(run, run.index)
    if (pending !== undefined) {
      const token = run.token
      pending.then(() => {
        if (this.live(run) && run.token === token && run.state === 'running') this.sendPhase(run, message)
      })
      return
    }
    this.sendPhase(run, message)
  }

  sendPhase(run, message) {
    run.messageId = message.id
    try {
      this.ctx.agents.withoutInitiator(() => run.agent.followup(message))
    } catch (error) {
      this.fail(run, `No se pudo enviar la fase: ${error?.message ?? error}`)
    }
  }

  /**
   * Compactación nativa de DSH antes de una fase con índice ≥ 1 (todas menos
   * la primera, cuyo mensaje del usuario es parte del contexto). Se lanza una
   * sola vez por fase y index; el resultado nulo o el error no impiden la
   * fase: se anota como aviso y sigue.
   */
  compact(run, index) {
    if (index < 1 || !this.live(run)) return undefined
    // En el perfil web la compactación pertenece al preset del agente.
    const api = run.agent.ctx?.get?.('compaction') ??
      (typeof this.ctx.get === 'function' ? this.ctx.get('compaction') : this.ctx.compaction)
    if (typeof api?.compactNow !== 'function') {
      if (!this.warnedCompaction) {
        this.warnedCompaction = true
        this.ctx.logger?.warn?.('dsh-workflows: el host no expone compaction; las fases 2+ no compactarán contexto')
      }
      return undefined
    }
    if (run.compacting?.index === index) return run.compacting.promise
    const controller = new AbortController()
    const entry = { index, controller, promise: undefined }
    entry.promise = (async () => {
      try {
        await api.compactNow(run.agent, controller.signal)
      } catch (error) {
        if (controller.signal.aborted) return
        const message = `Fase ${index + 1}: compactación omitida (${error?.message ?? error})`
        if (!run.warnings.includes(message)) run.warnings.push(message)
        this.ctx.logger?.warn?.(`dsh-workflows: ${run.workflow.name} ${message}`)
      } finally {
        if (run.compacting === entry) run.compacting = undefined
      }
    })()
    run.compacting = entry
    return entry.promise
  }

  /**
   * Retención de artefactos: borra carpetas de ejecuciones cuyo archivo más
   * reciente supere RETENTION_MS. Como mucho un barrido por día (archivo
   * marcadora); nunca bloquea el arranque del workflow.
   */
  async pruneOld() {
    try {
      await mkdir(this.scratchRoot, { recursive: true })
      const marker = join(this.scratchRoot, '.last-prune')
      let at = 0
      try {
        at = Number(await readFile(marker, 'utf8')) || 0
      } catch {}
      if (Date.now() - at < PRUNE_INTERVAL_MS) return
      for (const entry of await readdir(this.scratchRoot, { withFileTypes: true })) {
        if (!entry.isDirectory()) continue
        const dir = join(this.scratchRoot, entry.name)
        let newest = 0
        try {
          for (const name of await readdir(dir)) newest = Math.max(newest, (await stat(join(dir, name))).mtimeMs)
          if (newest === 0) newest = (await stat(dir)).mtimeMs
        } catch {
          continue
        }
        if (newest < Date.now() - RETENTION_MS) await rm(dir, { recursive: true, force: true }).catch(() => {})
      }
      await writeFile(marker, String(Date.now()))
    } catch (error) {
      this.ctx.logger?.warn?.(`dsh-workflows: limpieza de artefactos: ${error?.message ?? error}`)
    }
  }

  advance(run) {
    if (!this.live(run)) return
    run.index += 1
    if (run.index >= run.workflow.phases.length) {
      this.finish(run, 'completed')
      return
    }
    if (run.agent.status === 'idle') this.startPhase(run)
    else run.state = 'pending'
  }

  fail(run, message) {
    if (!this.live(run)) return
    run.state = 'error'
    run.error = message
    this.ctx.logger?.warn?.(`dsh-workflows: ${run.workflow.name} fase ${run.index + 1}: ${message}`)
  }

  finish(run, kind) {
    if (!this.live(run)) return
    this.runs.delete(run.sessionId)
    this.finishedRuns.set(run.sessionId, run)
    this.notices.set(run.sessionId, {
      ...this.view(run),
      state: kind,
      kind,
      workflowId: run.workflow.id,
      name: run.workflow.name,
      index: Math.min(run.index, run.workflow.phases.length - 1),
      total: run.workflow.phases.length,
      durationMs: Date.now() - run.startedAt,
      at: Date.now(),
    })
  }

  runForAgent(agent) {
    const run = this.runs.get(agent.session?.id ?? agent.id)
    return run !== undefined && run.agent === agent ? run : undefined
  }

  // ---------------------------------------------------------------- eventos del agente

  /** `agent/status`: el agente quedó libre. */
  onIdle(agent) {
    const run = this.runForAgent(agent)
    if (run === undefined) return
    if (run.state === 'pending') {
      this.startPhase(run)
      return
    }
    if (run.state !== 'running') return
    if (run.admitted && (run.turnEnded || run.skipping)) {
      const skipping = run.skipping
      run.turnEnded = false
      run.skipping = false
      const phase = run.workflow.phases[run.index]
      if (skipping || phase.afterward === 'continue') this.advance(run)
      else {
        run.state = 'waiting-confirm'
        // Se adelanta la compactación de la fase siguiente al tramo de espera.
        if (run.index + 1 < run.workflow.phases.length) this.compact(run, run.index + 1)
      }
      return
    }
    if (!run.admitted && run.messageId !== undefined) {
      const queued = [...agent.inbox.nextTurn, ...agent.inbox.nextStep].some((m) => m.id === run.messageId)
      if (!queued) this.fail(run, 'El prompt de la fase no llegó a entrar en la conversación')
    }
  }

  /** `session/event`: admisión del mensaje de la fase y fin del turno. */
  onSessionEvent(session, event) {
    const run = this.runs.get(session.id)
    if (run === undefined || run.agent.session !== session) return
    if (event.type === 'user/message') {
      if (event.data?.id !== undefined && event.data.id === run.messageId) run.admitted = true
      return
    }
    if (run.admitted && run.state === 'running') run.artifacts.event(event, run.index)
    if (event.type !== 'turn/end' || !run.admitted || run.state !== 'running') return
    const reason = event.data?.reason ?? { kind: 'completed' }
    if (reason.kind === 'aborted') {
      // Saltar cancela a propósito; el resto (botón Stop nativo) detiene el workflow.
      if (!run.skipping) this.finish(run, 'stopped')
      return
    }
    if (reason.kind === 'error') {
      this.fail(run, reason.error?.message ?? 'Error del modelo')
      return
    }
    run.turnEnded = true
    if (!run.completed.includes(run.index)) run.completed.push(run.index)
  }

  /**
   * `agent/pre-step`: en el paso que arranca la fase (la marca automática o
   * tu mensaje cuando el workflow lo espera) inyecta, ocultas, las
   * instrucciones de la fase y sus skills. Tu mensaje no se modifica.
   */
  async onPreStep({ agent, signal }, decision) {
    if (decision.kind !== 'enter') return decision
    const run = this.runForAgent(agent)
    if (run === undefined) return decision
    const messages = decision.messages
    const ours = messages.some((m) => m.source?.kind === SOURCE_KIND && m.source.part === 'prompt' && m.source.runId === run.id && m.source.phase === run.index)
    if (!ours && (run.state === 'waiting-input' || run.state === 'waiting-confirm')) {
      const typed = messages.find((m) => m.source?.kind === 'user')
      if (typed === undefined) return decision
      if (run.state === 'waiting-confirm') {
        if (run.index + 1 >= run.workflow.phases.length) {
          // Era la última fase: tu mensaje pasa tal cual y el workflow termina.
          this.finish(run, 'completed')
          return decision
        }
        // Tu mensaje arranca la fase siguiente, sea automática o no.
        run.index += 1
        run.phaseStartedAt = Date.now()
      }
      run.state = 'running'
      run.messageId = typed.id
      run.admitted = false
      run.turnEnded = false
      run.injected = false
      run.error = undefined
      run.token = (run.token ?? 0) + 1
      // Tu mensaje arranca la fase: la compactación (si cabe) se completa antes de inyectar.
      const pending = this.compact(run, run.index)
      if (pending !== undefined) await pending
      if (!this.live(run) || run.state !== 'running' || run.messageId !== typed.id) return decision
    } else if (!ours) {
      return decision
    }
    if (run.injected) return decision
    run.injected = true
    const injected = await this.injections(run, agent, signal)
    return { ...decision, messages: [...injected, ...messages] }
  }

  async injections(run, agent, signal) {
    const phase = run.workflow.phases[run.index]
    const extra = run.pendingExtra
    run.pendingExtra = ''
    const artifacts = run.artifactMode ? renderArtifacts(run.workflow, run.index, run.dir) : ''
    const out = [createUserMessage({
      content: [{ type: 'text', text: renderInstructions(run.workflow, run.index, extra, run.phaseHasUserInput, artifacts) }],
      source: { kind: SOURCE_KIND, part: 'context', runId: run.id, phase: run.index, workflow: run.workflow.name },
    })]
    const lookup = { cwd: agent.session?.header?.cwd, signal, scope: agent }
    for (const name of phase.skills) {
      let skill
      try {
        skill = await this.ctx.skills.get(name, lookup)
      } catch (error) {
        if (signal?.aborted) throw error
      }
      if (skill === undefined) {
        const warning = `Fase ${run.index + 1}: skill "${name}" no encontrada`
        if (!run.warnings.includes(warning)) run.warnings.push(warning)
        continue
      }
      out.push(createUserMessage({
        content: [{ type: 'text', text: renderSkill(skill) }],
        source: { kind: 'skill-invocation', name, form: 'instructions' },
      }))
    }
    return out
  }

  /**
   * `agent/request`: modelo y esfuerzo de la fase, solo para esta petición.
   *
   * Sin selección explícita, DSH arranca cada petición desde la config de la
   * anterior, así que un cambio de fase se "filtraría" a las siguientes. Por
   * eso se guarda la config real de la sesión (`base`) y, cuando lo que llega
   * es exactamente lo que aplicó el plugin, se vuelve a la base: en las fases
   * que heredan y en la primera petición tras el workflow.
   */
  onRequest(agent, config) {
    const key = agent.session?.id ?? agent.id
    const run = this.runForAgent(agent)
    const active = run !== undefined && run.state === 'running'
    let memo = this.configs.get(key)
    if (memo === undefined) {
      if (!active) return config
      memo = { base: pickConfig(config), applied: undefined }
      this.configs.set(key, memo)
    }
    let base = config
    if (memo.applied !== undefined && sameConfig(config, memo.applied)) base = { ...config, ...restoreConfig(config, memo.base) }
    else memo.base = pickConfig(config)
    if (!active) {
      this.configs.delete(key)
      return base
    }
    const phase = run.workflow.phases[run.index]
    let out = base
    if (phase.model !== null) {
      const { reasoningEffort: _inherited, ...rest } = out
      out = { ...rest, provider: phase.model.provider, model: phase.model.model }
    }
    if (phase.effort !== null) out = { ...out, reasoningEffort: phase.effort }
    memo.applied = pickConfig(out)
    return out
  }

  onDisposed(agent) {
    const run = this.runForAgent(agent)
    if (run !== undefined) this.runs.delete(run.sessionId)
  }

  /** Al descargar el plugin: cancela lo que esté en marcha. */
  async dispose() {
    const waits = []
    for (const run of this.runs.values()) {
      run.compacting?.controller.abort()
      if (run.state === 'running' && run.agent.status === 'running') {
        run.agent.cancel({ kind: 'parent' })
        waits.push(run.agent.whenIdle())
      }
    }
    this.runs.clear()
    this.finishedRuns.clear()
    this.notices.clear()
    await Promise.allSettled(waits)
  }
}
