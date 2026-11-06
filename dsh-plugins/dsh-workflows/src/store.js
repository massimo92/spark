/**
 * Workflows guardados: validación y persistencia en un único JSON.
 * Solo se guardan definiciones; el estado de las ejecuciones vive en memoria.
 */
import { randomUUID } from 'node:crypto'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'

export const LIMITS = Object.freeze({
  name: 64,
  description: 500,
  phaseName: 80,
  instructions: 40000,
  output: 4000,
  question: 300,
  phases: 40,
  skills: 20,
  workflows: 500,
})

/** Mismo formato que el `/nombre` de las skills, para poder invocarlos igual más adelante. */
const NAME_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
const ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/

const isRecord = (value) => typeof value === 'object' && value !== null && !Array.isArray(value)

function text(value, max, label, { required = false } = {}) {
  if (value === undefined || value === null) value = ''
  if (typeof value !== 'string') throw new Error(`${label}: debe ser texto`)
  if (value.length > max) throw new Error(`${label}: máximo ${max} caracteres`)
  if (required && value.trim() === '') throw new Error(`${label}: obligatorio`)
  return value
}

function normalizeModel(value, label) {
  if (value === undefined || value === null) return null
  if (!isRecord(value)) throw new Error(`${label}: modelo inválido`)
  const provider = text(value.provider, 120, `${label}: proveedor`, { required: true })
  const model = text(value.model, 200, `${label}: modelo`, { required: true })
  return { provider, model }
}

export function normalizePhase(input, index) {
  const label = `Fase ${index + 1}`
  if (!isRecord(input)) throw new Error(`${label}: formato inválido`)
  const id = typeof input.id === 'string' && ID_PATTERN.test(input.id) ? input.id : randomUUID()
  const kind = input.input === 'user' ? 'user' : input.input === 'auto' || input.input === undefined ? 'auto' : null
  if (kind === null) throw new Error(`${label}: inicio inválido`)
  const afterward = input.afterward === 'confirm' ? 'confirm' : input.afterward === 'continue' || input.afterward === undefined ? 'continue' : null
  if (afterward === null) throw new Error(`${label}: "al terminar" inválido`)
  // Formato anterior (prompt + contexto) → instrucciones únicas, ocultas en el chat.
  const legacy = [input.context, input.prompt].filter((v) => typeof v === 'string' && v.trim() !== '').join('\n\n')
  const instructions = text(input.instructions ?? legacy, LIMITS.instructions, `${label}: instrucciones`)
  if (kind === 'auto' && instructions.trim() === '') throw new Error(`${label}: una fase automática necesita instrucciones`)
  const rawSkills = input.skills ?? []
  if (!Array.isArray(rawSkills)) throw new Error(`${label}: skills debe ser una lista`)
  const skills = [...new Set(rawSkills)]
  if (skills.length > LIMITS.skills) throw new Error(`${label}: máximo ${LIMITS.skills} skills`)
  for (const skill of skills) {
    if (typeof skill !== 'string' || !NAME_PATTERN.test(skill)) throw new Error(`${label}: skill inválida "${String(skill)}"`)
  }
  const effort = input.effort === undefined || input.effort === null || input.effort === '' ? null : text(input.effort, 40, `${label}: esfuerzo`)
  const output = text(input.output, LIMITS.output, `${label}: salida`)
  return {
    id,
    name: text(input.name, LIMITS.phaseName, `${label}: nombre`, { required: true }).trim(),
    input: kind,
    instructions,
    question: text(input.question, LIMITS.question, `${label}: pregunta`).trim(),
    skills,
    model: normalizeModel(input.model, label),
    effort,
    afterward,
    output,
  }
}

export function normalizeWorkflow(input) {
  if (!isRecord(input)) throw new Error('Workflow: formato inválido')
  const name = text(input.name, LIMITS.name, 'Nombre', { required: true }).trim()
  if (!NAME_PATTERN.test(name)) throw new Error('Nombre: solo minúsculas, números y guiones (como las skills)')
  if (!Array.isArray(input.phases) || input.phases.length === 0) throw new Error('El workflow necesita al menos una fase')
  if (input.phases.length > LIMITS.phases) throw new Error(`Máximo ${LIMITS.phases} fases`)
  const phases = input.phases.map(normalizePhase)
  const ids = new Set()
  for (const phase of phases) {
    if (ids.has(phase.id)) phase.id = randomUUID()
    ids.add(phase.id)
  }
  return {
    id: typeof input.id === 'string' && ID_PATTERN.test(input.id) ? input.id : randomUUID(),
    name,
    description: text(input.description, LIMITS.description, 'Descripción').trim(),
    phases,
  }
}

/** Archivo JSON con escritura atómica (tmp + rename) y operaciones serializadas. */
export class WorkflowStore {
  constructor(path) {
    this.path = path
    this.queue = Promise.resolve()
  }

  async read() {
    let raw
    try {
      raw = await readFile(this.path, 'utf8')
    } catch (error) {
      if (error?.code === 'ENOENT') return []
      throw error
    }
    const data = JSON.parse(raw)
    const list = Array.isArray(data?.workflows) ? data.workflows : []
    const out = []
    for (const item of list) {
      try {
        out.push(normalizeWorkflow(item))
      } catch {
        // Una entrada corrupta no debe tumbar el resto de la biblioteca.
      }
    }
    return out
  }

  async write(workflows) {
    await mkdir(dirname(this.path), { recursive: true })
    const tmp = `${this.path}.${process.pid}.${Date.now()}.tmp`
    await writeFile(tmp, `${JSON.stringify({ version: 1, workflows }, null, 2)}\n`, { mode: 0o600 })
    await rename(tmp, this.path)
  }

  serial(operation) {
    const run = this.queue.then(operation, operation)
    this.queue = run.catch(() => {})
    return run
  }

  list() {
    return this.serial(async () => (await this.read()).sort((a, b) => a.name.localeCompare(b.name)))
  }

  get(id) {
    return this.serial(async () => (await this.read()).find((w) => w.id === id))
  }

  save(input) {
    return this.serial(async () => {
      const workflow = normalizeWorkflow(input)
      const all = await this.read()
      if (all.some((w) => w.name === workflow.name && w.id !== workflow.id)) throw new Error(`Ya existe un workflow llamado "${workflow.name}"`)
      const index = all.findIndex((w) => w.id === workflow.id)
      if (index === -1) {
        if (all.length >= LIMITS.workflows) throw new Error(`Máximo ${LIMITS.workflows} workflows`)
        all.push(workflow)
      } else {
        all[index] = workflow
      }
      await this.write(all)
      return workflow
    })
  }

  delete(id) {
    return this.serial(async () => {
      const all = await this.read()
      const next = all.filter((w) => w.id !== id)
      if (next.length !== all.length) await this.write(next)
      return next.length !== all.length
    })
  }
}
