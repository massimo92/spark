/**
 * Qué texto recibe el modelo en cada fase. Funciones puras.
 */
import { randomUUID } from 'node:crypto'
import { join } from 'node:path'

const EXTRA_LABEL = 'Instrucciones adicionales:'

/** Nombre de archivo del artefacto de una fase dentro de la carpeta de la ejecución. */
export function artifactFile(workflow, index) {
  const slug = String(workflow.phases[index]?.name ?? '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || `fase-${index + 1}`
  return `${String(index + 1).padStart(2, '0')}-${slug}.md`
}

/** El workflow usa artefactos si alguna fase declara formato de salida. */
export function hasArtifacts(workflow) {
  return workflow.phases.some((p) => String(p.output ?? '').trim() !== '')
}

/** Bloque oculto con la carpeta de la ejecución, los artefactos previos y el contrato de salida. */
export function renderArtifacts(workflow, index, dir) {
  const phase = workflow.phases[index]
  const previous = workflow.phases
    .slice(0, index)
    .map((p, i) => [p, i])
    .filter(([p]) => String(p.output ?? '').trim() !== '')
    .map(([, i]) => join(dir, artifactFile(workflow, i)))
  const output = String(phase.output ?? '').trim()
  if (previous.length === 0 && output === '') return ''
  const lines = [`<workflow_artifacts dir="${escapeAttr(dir)}">`]
  if (previous.length) {
    lines.push('Archivos de las fases anteriores (léelos antes de trabajar: son tu fuente de verdad; el historial de la conversación es solo contexto):')
    lines.push(...previous.map((p) => `- ${p}`))
  }
  if (output !== '') {
    lines.push(`Escribe el resultado completo de esta fase en: ${join(dir, artifactFile(workflow, index))}`)
    lines.push('Formato requerido del resultado:', output)
  }
  lines.push('</workflow_artifacts>')
  return lines.join('\n')
}

/**
 * Mensaje visible que arranca una fase automática: solo una marca. Las
 * instrucciones van ocultas (ver `renderInstructions`).
 */
export function phaseMarker(workflow, index) {
  const phase = workflow.phases[index]
  return `▸ ${workflow.name} · fase ${index + 1}/${workflow.phases.length} · ${phase.name}`
}

/**
 * Instrucciones ocultas de la fase: el modelo las ve antes del mensaje que
 * arranca la fase; en el chat no aparecen. `extra` = contexto inicial o
 * "Continuar con esto". `artifacts` = bloque opcional de `renderArtifacts`.
 */
export function renderInstructions(workflow, index, extra = '', userMessage = false, artifacts = '') {
  const phase = workflow.phases[index]
  const parts = [phase.instructions.trim(), extra.trim() ? `${EXTRA_LABEL} ${extra.trim()}` : ''].filter(Boolean)
  const kind = phase.input === 'user' || userMessage ? 'Tras estas instrucciones llega el mensaje del usuario para esta fase.' : 'El mensaje siguiente solo marca el inicio de la fase; sigue estas instrucciones.'
  return [
    `<workflow_phase workflow="${escapeAttr(workflow.name)}" phase="${index + 1}/${workflow.phases.length}" name="${escapeAttr(phase.name)}">`,
    kind,
    ...(parts.length ? ['', parts.join('\n\n')] : []),
    ...(artifacts ? ['', artifacts] : []),
    '</workflow_phase>',
  ].join('\n')
}

/** Mismo formato que `renderSkillContent` de dsh-skill, que es lo que inyecta `/skill`. */
export function renderSkill(skill) {
  const base = skill.resourceBase
  let hint
  if (base === undefined) hint = [`Resources for this skill are managed by provider "${escapeText(skill.provider ?? 'unknown')}".`, 'Load referenced resources only as needed.']
  else if (base.kind === 'directory') hint = [`Base directory for this skill: ${escapeText(base.path)}`, 'Resolve relative paths mentioned by this skill against the base directory before using them. Load referenced resources only as needed.']
  else if (base.kind === 'url') hint = [`Base URL for this skill: ${escapeText(base.url)}`, 'Resolve relative URLs mentioned by this skill against the base URL before using them. Load referenced resources only as needed.']
  else hint = [`Resources for this skill: ${escapeText(base.description ?? '')}`, 'Load referenced resources only as needed.']
  return [
    `<skill_content name="${escapeAttr(skill.name)}">`,
    '<skill_resources>',
    ...hint,
    '</skill_resources>',
    '',
    '<skill_instructions>',
    skill.content,
    '</skill_instructions>',
    '</skill_content>',
  ].join('\n')
}

function escapeAttr(value) {
  return String(value).replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;')
}

function escapeText(value) {
  return String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}

/** Réplica de `createUserMessage` de dsh-llm (el host del plugin no puede importar paquetes internos). */
export function createUserMessage({ content, source }, id = randomUUID()) {
  return deepFreeze(structuredClone({ content, source, role: 'user', id }))
}

export function textOf(message) {
  return (message.content ?? []).filter((block) => block.type === 'text').map((block) => block.text).join('\n')
}

export function deepFreeze(value) {
  if (typeof value === 'object' && value !== null && !Object.isFrozen(value)) {
    Object.freeze(value)
    for (const key of Object.keys(value)) deepFreeze(value[key])
  }
  return value
}
