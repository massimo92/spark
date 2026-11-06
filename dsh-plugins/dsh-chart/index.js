/**
 * Mitad HOST del bundle dsh-chart.
 * Solo añade una sección ESTÁTICA al system prompt para que el modelo conozca
 * el fence ```dsh-chart. Sin fs, sin red, sin tools, sin rutas HTTP, sin env.
 * Todo el renderizado es el módulo cliente (lib/client.js), que solo toca el DOM.
 */

export const name = '@local/dsh-chart'
export const inject = ['systemPrompt']

/** Texto íntegro que se añade al prompt (en inglés: va dirigido al modelo). */
export const FENCE_PROMPT = `You can draw a chart inside your reply by emitting a fenced block with the language tag \`dsh-chart\` that contains ONE strict JSON object (pure data, no comments, no functions, no trailing commas):

\`\`\`dsh-chart
{"title":"Hours per ISO week","labels":["W01","W02","W03"],"yTitle":"hours","valueFormat":"hours","target":38,
 "series":[{"name":"hours","type":"bar","data":[17.9,27,13.5]}]}
\`\`\`

Top-level keys (all optional except series): title, subtitle, labels (x categories: strings or numbers), series, xTitle (category axis), yTitle (value axis), legend (bool), height (200-800 px), horizontal (bool, horizontal bars), yMin, yMax (numbers), target (number: dashed goal line), showValues (bool: print values on points/bars), valueFormat ("int"|"decimal"|"percent"|"hours").
Series keys: name, type ("line"|"bar"|"area"|"scatter"|"pie"), data, smooth (bool), stack (string: same value = stacked), color ("#rrggbb").
Rules:
- data is an array of numbers (null = gap), aligned with labels; never more values than labels.
- scatter may instead use [x, y] pairs; then every series must be scatter with pairs and labels are ignored.
- pie: exactly one series, non-negative values, slice names come from labels.
- Limits: 24 series, 10000 values per series, 1024 labels, 200 chars per title, 120 per label/name.
- Any other key makes the whole chart fail. Write titles and names in the conversation language.
- Use a chart only when numbers are easier to read visually (trends, comparisons, shares); keep the key figures in the text too.`

export function apply(ctx) {
  ctx.effect(() => ctx.systemPrompt.section({
    name: 'dsh-chart:fence',
    order: ctx.systemPrompt.getSectionOrder('STRUCTURED_OUTPUT'),
    text: FENCE_PROMPT,
    interpolate: false,
  }), 'dsh-chart: fence contract')
}
