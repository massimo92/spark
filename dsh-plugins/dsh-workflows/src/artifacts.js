import { stat } from 'node:fs/promises'
import { basename, isAbsolute, join, resolve } from 'node:path'
import { artifactFile } from './prompt.js'

const validPath = (value) => typeof value === 'string' && value.trim() !== '' && value.length <= 4096 && !value.includes('\0')
const fingerprint = (info) => `${info.dev}:${info.ino}:${info.size}:${info.mtimeMs}:${info.ctimeMs}`
const fileInfo = (path) => stat(path).then((info) => info.isFile() ? info : null, () => null)

/** Same successful mutation sources as DSH's native deliverables, never reads or failed calls. */
export function mutationPath(name, raw) {
  let args
  try { args = JSON.parse(raw) } catch { return null }
  if (!args || typeof args !== 'object' || Array.isArray(args)) return null
  if (name === 'write' && typeof args.content === 'string' && validPath(args.file_path)) return args.file_path
  if (name === 'edit' && typeof args.old_string === 'string' && args.old_string.length > 0 && typeof args.new_string === 'string' && args.old_string !== args.new_string && validPath(args.file_path)) return args.file_path
  if (name !== 'str_replace_editor' || !validPath(args.path)) return null
  if (args.command === 'create' && typeof args.file_text === 'string') return args.path
  if (args.command === 'str_replace' && typeof args.old_str === 'string' && args.old_str.length > 0 && (args.new_str === undefined || typeof args.new_str === 'string')) return args.path
  if (args.command === 'insert' && Number.isInteger(args.insert_line) && args.insert_line >= 0 && typeof args.new_str === 'string') return args.path
  return null
}

/** Per-run ownership. Expected outputs are advertised only after an actual filesystem change. */
export class WorkflowArtifacts {
  constructor(run) {
    this.cwd = run.agent.session?.header?.cwd
    this.calls = new Map()
    this.candidates = new Map()
    this.files = []
    this.expected = run.workflow.phases.flatMap((phase, index) =>
      phase.output?.trim() && index >= run.startIndex ? [{ path: join(run.dir, artifactFile(run.workflow, index)), phase: index, before: null }] : [])
    this.inflight = null
  }

  async initialize() {
    await Promise.all(this.expected.map(async (entry) => {
      const info = await fileInfo(entry.path)
      entry.before = info ? fingerprint(info) : null
    }))
  }

  add(path, phase) {
    if (!validPath(path) || (!isAbsolute(path) && !this.cwd)) return
    const absolute = isAbsolute(path) ? resolve(path) : resolve(this.cwd, path)
    this.candidates.set(`${phase}:${absolute}`, { path: absolute, phase })
  }

  event(event, phase) {
    if (event.type === 'tool/call') {
      const path = mutationPath(event.data?.name, event.data?.arguments)
      if (path) this.calls.set(String(event.data.callId), { path, phase })
    } else if (event.type === 'tool/result') {
      const message = event.data?.message
      const id = String(message?.source?.callId)
      const call = this.calls.get(id)
      this.calls.delete(id)
      if (call && message?.isError !== true) {
        const recorded = event.data?.meta?.path
        this.add(validPath(recorded) && isAbsolute(recorded) ? recorded : call.path, call.phase)
      }
    } else if (event.type === 'deliverables/presented') {
      for (const file of event.data?.files ?? []) this.add(file?.path, phase)
    }
  }

  async refresh() {
    if (this.inflight) return this.inflight
    this.inflight = (async () => {
      for (const entry of this.expected) {
        const info = await fileInfo(entry.path)
        if (info && fingerprint(info) !== entry.before) this.add(entry.path, entry.phase)
      }
      const files = await Promise.all([...this.candidates.values()].map(async (entry) => {
        const info = await fileInfo(entry.path)
        return info ? { ...entry, name: basename(entry.path), size: info.size, modifiedAt: info.mtimeMs } : null
      }))
      this.files = files.filter(Boolean).sort((a, b) => a.phase - b.phase || a.path.localeCompare(b.path))
    })()
    try { await this.inflight } finally { this.inflight = null }
  }
}
