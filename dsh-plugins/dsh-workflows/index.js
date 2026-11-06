/**
 * Mitad HOST de dsh-workflows.
 *
 * - Guarda las definiciones en ~/.dsh/storages/dsh-workflows.json.
 * - Expone rutas /api/workflows.* (mismo control de acceso que el resto de /api).
 * - Ejecuta las fases sobre el agente raíz de la conversación (ver src/engine.js).
 *
 * Sin red, sin child_process, sin variables de entorno.
 */
import { homedir } from 'node:os'
import { join } from 'node:path'
import { WorkflowEngine } from './src/engine.js'
import { WorkflowStore } from './src/store.js'

export const name = '@local/dsh-workflows'
export const inject = ['connection', 'agents', 'sessionController', 'skills', 'compaction']

/** Rutas `/api/workflows.<endpoint>` (POST JSON → `{ ok, value }` o `{ ok: false, error }`). */
const ROUTE_PREFIX = '/api/workflows.'
export const STORE_PATH = join(homedir(), '.dsh', 'storages', 'dsh-workflows.json')

const isRecord = (value) => typeof value === 'object' && value !== null && !Array.isArray(value)
const reply = (body) => Response.json(body, { headers: { 'cache-control': 'no-store' } })
const str = (value, fallback = '') => (typeof value === 'string' ? value : fallback)

function sessionIdOf(payload) {
  const id = payload?.sessionId
  if (typeof id !== 'string' || id === '' || id.length > 200) throw new Error('sessionId inválido')
  return id
}

export function apply(ctx) {
  const store = new WorkflowStore(STORE_PATH)
  const engine = new WorkflowEngine(ctx)

  async function catalog(payload) {
    const sessionId = typeof payload?.sessionId === 'string' ? payload.sessionId : undefined
    let agent = sessionId === undefined ? undefined : ctx.agents.get(sessionId)
    if (agent === undefined && sessionId !== undefined) {
      // Las skills dependen del cwd y del agente; sin agente vivo la lista sale vacía.
      const resolved = await ctx.sessionController.resolveAgent(sessionId).catch(() => undefined)
      if (resolved !== undefined && 'agent' in resolved) agent = resolved.agent
    }
    const [models, skills] = await Promise.all([
      ctx.sessionController.modelCatalog().catch((error) => ({ groups: [], failures: [{ message: String(error?.message ?? error) }] })),
      ctx.skills.list({ ...(agent?.session?.header?.cwd ? { cwd: agent.session.header.cwd } : {}), ...(agent ? { scope: agent } : {}) }).catch(() => []),
    ])
    return {
      models: {
        default: models.default ?? null,
        groups: (models.groups ?? []).map((g) => ({
          id: g.id,
          name: g.name,
          models: g.models.map((m) => ({ id: m.id, name: m.name, reasoning: m.reasoning ?? null })),
        })),
      },
      skills: skills.map((s) => ({ name: s.name, description: s.description ?? '' })),
    }
  }

  const handlers = {
    list: async () => ({ workflows: await store.list() }),
    save: async (payload) => ({ workflow: await store.save(payload?.workflow) }),
    delete: async (payload) => ({ deleted: await store.delete(str(payload?.id)) }),
    catalog,
    state: async (payload) => engine.refreshState(sessionIdOf(payload)),
    run: async (payload) => {
      const sessionId = sessionIdOf(payload)
      const workflow = await store.get(str(payload?.workflowId))
      if (workflow === undefined) throw new Error('Ese workflow ya no existe')
      const startIndex = payload?.startIndex === undefined ? 0 : payload.startIndex
      await engine.start({ sessionId, workflow, startIndex, context: str(payload?.context), input: str(payload?.input) })
      return engine.state(sessionId)
    },
    // Dedicated endpoint: old hosts reject composer submissions instead of dropping their input.
    submit: async (payload) => handlers.run(payload),
    stop: async (payload) => {
      const sessionId = sessionIdOf(payload)
      engine.stop(sessionId)
      return engine.state(sessionId)
    },
    skip: async (payload) => {
      const sessionId = sessionIdOf(payload)
      engine.skip(sessionId)
      return engine.state(sessionId)
    },
    continue: async (payload) => {
      const sessionId = sessionIdOf(payload)
      engine.continue(sessionId, str(payload?.extra))
      return engine.state(sessionId)
    },
    retry: async (payload) => {
      const sessionId = sessionIdOf(payload)
      engine.retry(sessionId)
      return engine.state(sessionId)
    },
    dismiss: async (payload) => {
      const sessionId = sessionIdOf(payload)
      engine.dismiss(sessionId)
      return engine.state(sessionId)
    },
  }

  // Una ruta exacta por endpoint dentro de /api: misma autenticación que el
  // resto de la API de DSH (Host/Origin + token del navegador).
  for (const [endpoint, handler] of Object.entries(handlers)) {
    ctx.connection.fetch.register({
      path: `${ROUTE_PREFIX}${endpoint}`,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async (request) => {
        let payload
        try {
          payload = await request.json()
        } catch {
          payload = {}
        }
        if (payload !== undefined && payload !== null && !isRecord(payload)) return reply({ ok: false, error: { code: 'invalid', message: 'payload inválido' } })
        try {
          return reply({ ok: true, value: await handler(payload ?? {}) })
        } catch (error) {
          return reply({ ok: false, error: { code: 'failed', message: String(error?.message ?? error) } })
        }
      },
    })
  }

  ctx.effect(function* () {
    ctx.on('agent/status', ({ agent, status }) => {
      if (status !== 'idle') return
      // Fuera del dispatch del evento, igual que goal-round-driver.
      queueMicrotask(() => {
        try {
          ctx.agents.withoutInitiator(() => engine.onIdle(agent))
        } catch (error) {
          ctx.logger.warn(`dsh-workflows: onIdle: ${error?.message ?? error}`)
        }
      })
    })
    ctx.on('session/event', (session, event) => {
      try {
        engine.onSessionEvent(session, event)
      } catch (error) {
        ctx.logger.warn(`dsh-workflows: session/event: ${error?.message ?? error}`)
      }
    })
    ctx.on('agent/disposed', ({ agent }) => engine.onDisposed(agent))
    ctx.on('agent/pre-step', async (payload, next) => engine.onPreStep(payload, await next()))
    // prepend: el listener más externo decide el modelo final de la petición,
    // por encima de la selección de modelo de la sesión.
    ctx.on('agent/request', async (payload, next) => engine.onRequest(payload.agent, await next()), true)
    yield () => engine.dispose()
  }, 'dsh-workflows: motor')
}
