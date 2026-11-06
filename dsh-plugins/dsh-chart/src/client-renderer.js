/**
 * dsh-chart — puente seguro JSON → ECharts.
 *
 * invariantes de seguridad:
 *  - El JSON del modelo NUNCA llega a setOption tal cual: se valida contra un
 *    schema whitelisted aquí y se construye el option de ECharts desde cero.
 *  - Nada de eval / new Function / innerHTML: todo texto va a canvas (ECharts)
 *    o a textContent (botones y nodos de error).
 *  - Renderer 'canvas' y tooltip 'richText' forzados: ECharts no crea DOM HTML.
 *  - Sin peticiones de red: echarts va vendorizado en este mismo bundle y
 *    build.mjs lo encierra en un closure (no existe window.echarts).
 *
 * `echarts` es una variable libre: la inyecta el wrapper de build.mjs (y el
 * harness de test). Este fichero es TODO el código propio del plugin cliente.
 */
'use strict'

window.__ModuleLoader__.load({
  id: '@local/dsh-chart',
  factory() {
    return {
      inject: [],
      apply(ctx) {
        const engine = start()
        if (ctx && typeof ctx.effect === 'function') ctx.effect(() => () => engine.stop())
        return engine.stop
      },
    }
  },
})

// ---------------------------------------------------------------------------
// constantes y límites
// ---------------------------------------------------------------------------
const FENCE_LANG = 'dsh-chart'
const MAX_SERIES = 24
const MAX_POINTS = 10000
const MAX_LABELS = 1024
const MAX_TITLE_LEN = 200
const MAX_NAME_LEN = 120
const DEFAULT_HEIGHT = 360
const MIN_HEIGHT = 200
const MAX_HEIGHT = 800
const SCAN_DELAY_MS = 120

const SERIES_TYPES = new Set(['line', 'bar', 'area', 'scatter', 'pie'])
const VALUE_FORMATS = new Set(['int', 'decimal', 'percent', 'hours'])
const TOP_KEYS = new Set([
  'title', 'subtitle', 'labels', 'series', 'xTitle', 'yTitle', 'legend', 'height',
  'horizontal', 'yMin', 'yMax', 'target', 'showValues', 'valueFormat',
])
const SERIES_KEYS = new Set(['name', 'type', 'data', 'smooth', 'stack', 'color'])
const HEX_COLOR = /^#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/
const NUMERIC_STRING = /^-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$/

const PALETTE = ['#4f8ef7', '#22c1a4', '#f2a541', '#e06c75', '#8c6fe0', '#48b6e6', '#d879af', '#7fd06b']
const TARGET_COLOR = '#e06c75'
const AXIS_LABEL_MARGIN = 12
const FONT_FAMILY = "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
const MONO_FONT = "ui-monospace, SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace"

// DOM del host (DSH 0.2 web). El <code> no lleva clase de lenguaje: el
// lenguaje solo aparece en el banner, y para lenguajes sin resaltado (como
// dsh-chart) el banner muestra la etiqueta genérica traducida.
const CODE_BLOCK = '.md-code-block'
const BANNER = '[data-code-block-banner]'
const LEGACY_CODE = `pre > code.language-${FENCE_LANG}, pre > code[data-language="${FENCE_LANG}"]`
const GENERIC_CODE_LABELS = new Set(['Code', 'Code block', '代码块'])
const ASSISTANT_ROW = '[data-chat-flow-kind="assistant-step"]'
const EXCLUDED = '[data-chat-group-part="reasoning"], [data-tool], [data-sidebar-chat], [data-sidebar-right-session], [data-sidebar-right-panel], [data-panel-conversation], [data-plugin-panel]'
const STREAMING = '[data-streaming]'
const OWN_ATTR = 'data-dsh-chart-wrap'
const DARK_ATTR = 'data-ds-dark-theme'
const THEME_SOURCE_ATTR = 'data-ds-theme-source'
// Primera clave del JSON en streaming: basta para reservar el hueco del gráfico.
const CHART_PREFIX = new RegExp('^\\s*\\{\\s*"(?:' + Array.from(TOP_KEYS).join('|') + ')"')

// ---------------------------------------------------------------------------
// estado
// ---------------------------------------------------------------------------
// bloque del host -> { raw, streaming, kind: 'chart'|'error'|'placeholder'|'none', wrap?, chart?, ro?, spec? }
// Se registra SIEMPRE (también en errores) para no reprocesar el mismo texto.
const records = new Map()
let observer = null
let scanTimer = 0

// ---------------------------------------------------------------------------
// validación del schema (blanco sí / negro no; nunca pasar datos sin validar)
// ---------------------------------------------------------------------------
function str(value, max, what) {
  if (value === undefined || value === null) return undefined
  if (typeof value === 'number' && Number.isFinite(value)) value = String(value)
  if (typeof value !== 'string') throw new Error(`${what} debe ser un string`)
  const t = value.trim()
  if (!t) return undefined
  if (t.length > max) throw new Error(`${what} supera ${max} caracteres`)
  return t
}

function num(value, what) {
  if (value === undefined || value === null) return undefined
  if (typeof value !== 'number' || !Number.isFinite(value)) throw new Error(`${what} debe ser un número`)
  return value
}

function finiteOrNull(v) {
  const n = typeof v === 'number' ? v : typeof v === 'string' && NUMERIC_STRING.test(v.trim()) ? Number(v) : NaN
  return Number.isFinite(n) ? n : null
}

function parseData(data, i, type) {
  const pairs = data.some(Array.isArray)
  if (!pairs) return { pairs, values: data.map(finiteOrNull) }
  if (type !== 'scatter') throw new Error(`series[${i}].data: los pares [x, y] solo valen para scatter`)
  const values = data.map((p, j) => {
    if (!Array.isArray(p) || p.length !== 2) throw new Error(`series[${i}].data[${j}] debe ser un par [x, y]`)
    const x = finiteOrNull(p[0])
    const y = finiteOrNull(p[1])
    return x === null || y === null ? null : [x, y]
  })
  return { pairs, values }
}

function validate(json) {
  if (json === null || typeof json !== 'object' || Array.isArray(json)) {
    throw new Error('la raíz debe ser un objeto JSON')
  }
  for (const k of Object.keys(json)) {
    if (!TOP_KEYS.has(k)) throw new Error(`clave no permitida: "${k}"`)
  }

  const spec = {
    title: str(json.title, MAX_TITLE_LEN, 'title'),
    subtitle: str(json.subtitle, MAX_TITLE_LEN, 'subtitle'),
    xTitle: str(json.xTitle, MAX_NAME_LEN, 'xTitle'),
    yTitle: str(json.yTitle, MAX_NAME_LEN, 'yTitle'),
    legend: json.legend === undefined ? undefined : json.legend === true,
    horizontal: json.horizontal === true,
    showValues: json.showValues === true,
    yMin: num(json.yMin, 'yMin'),
    yMax: num(json.yMax, 'yMax'),
    target: num(json.target, 'target'),
    valueFormat: undefined,
    xy: false,
    labels: [],
    series: [],
  }
  if (spec.yMin !== undefined && spec.yMax !== undefined && spec.yMin >= spec.yMax) {
    throw new Error('yMin debe ser menor que yMax')
  }
  if (json.valueFormat !== undefined) {
    if (!VALUE_FORMATS.has(json.valueFormat)) throw new Error('valueFormat debe ser int|decimal|percent|hours')
    spec.valueFormat = json.valueFormat
  }

  spec.height = typeof json.height === 'number' && Number.isFinite(json.height)
    ? Math.min(MAX_HEIGHT, Math.max(MIN_HEIGHT, Math.round(json.height)))
    : DEFAULT_HEIGHT

  if (json.labels !== undefined) {
    if (!Array.isArray(json.labels) || json.labels.length > MAX_LABELS) {
      throw new Error(`labels debe ser un array de 0-${MAX_LABELS} elementos`)
    }
    spec.labels = json.labels.map((l, i) => {
      const s = str(l, MAX_NAME_LEN, `labels[${i}]`)
      return s === undefined ? '' : s
    })
  }

  if (!Array.isArray(json.series) || json.series.length === 0 || json.series.length > MAX_SERIES) {
    throw new Error('series debe ser un array con 1-' + MAX_SERIES + ' elementos')
  }

  for (const [i, s] of json.series.entries()) {
    if (s === null || typeof s !== 'object' || Array.isArray(s)) throw new Error(`series[${i}] debe ser un objeto`)
    for (const k of Object.keys(s)) {
      if (!SERIES_KEYS.has(k)) throw new Error(`series[${i}].${k} no está permitido`)
    }
    const type = s.type === undefined ? 'line' : String(s.type)
    if (!SERIES_TYPES.has(type)) throw new Error(`series[${i}].type "${type}" no está permitido`)
    if (!Array.isArray(s.data) || s.data.length === 0 || s.data.length > MAX_POINTS) {
      throw new Error(`series[${i}].data debe ser un array con 1-${MAX_POINTS} valores`)
    }
    const color = s.color === undefined ? undefined : String(s.color)
    if (color !== undefined && !HEX_COLOR.test(color)) throw new Error(`series[${i}].color debe ser #rgb, #rgba, #rrggbb o #rrggbbaa`)
    const { pairs, values } = parseData(s.data, i, type)
    spec.series.push({
      name: str(s.name, MAX_NAME_LEN, `series[${i}].name`),
      type,
      pairs,
      data: values,
      smooth: s.smooth === true,
      stack: str(s.stack, MAX_NAME_LEN, `series[${i}].stack`),
      color,
    })
  }

  const pieCount = spec.series.filter((s) => s.type === 'pie').length
  if (pieCount > 1 || (pieCount === 1 && spec.series.length > 1)) throw new Error('pie admite una única serie')
  if (pieCount === 1 && spec.series[0].data.some((v) => v !== null && v < 0)) throw new Error('pie no admite valores negativos')

  spec.xy = spec.series.some((s) => s.pairs)
  if (spec.xy && !spec.series.every((s) => s.pairs)) {
    throw new Error('si una serie usa pares [x, y], todas deben ser scatter con pares')
  }
  if (!spec.xy && spec.labels.length) {
    for (const [i, s] of spec.series.entries()) {
      if (s.data.length > spec.labels.length) {
        throw new Error(`series[${i}].data tiene ${s.data.length} valores pero labels solo ${spec.labels.length}`)
      }
    }
  }

  if (!spec.series.some((s) => s.data.some((d) => d !== null))) throw new Error('sin valores numéricos válidos')
  return spec
}

/** JSON completo → spec validado; JSON incompleto → null; spec inválido → throw. */
function parseSpec(raw) {
  let json
  try {
    json = JSON.parse(raw)
  } catch {
    return null
  }
  return validate(json)
}

function isFinalJson(text) {
  const t = text.trim()
  if (!t.startsWith('{') || !t.endsWith('}')) return false
  try { JSON.parse(t); return true } catch { return false }
}

// ---------------------------------------------------------------------------
// construcción del option (nunca se pasa el JSON del modelo directamente)
// ---------------------------------------------------------------------------
function isDark() {
  const body = document.body
  if (body && body.hasAttribute && body.hasAttribute(DARK_ATTR)) return true
  const el = document.documentElement
  // Tema de DSH activo y sin atributo oscuro → claro (aunque el SO sea oscuro).
  if (el && el.hasAttribute && el.hasAttribute(THEME_SOURCE_ATTR)) return false
  if (el && el.classList && (el.classList.contains('dark') || el.classList.contains('dsh-dark'))) return true
  if (el && el.getAttribute && el.getAttribute('data-theme') === 'dark') return true
  return Boolean(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches)
}

function makeFormatter(fmt) {
  if (!fmt) return undefined
  const digits = { int: 0, decimal: 2, percent: 1, hours: 1 }[fmt]
  const suffix = { int: '', decimal: '', percent: '%', hours: ' h' }[fmt]
  return (v) => {
    const n = Array.isArray(v) ? v[v.length - 1] : v
    return typeof n === 'number' && Number.isFinite(n)
      ? n.toLocaleString(undefined, { maximumFractionDigits: digits }) + suffix
      : '–'
  }
}

/** Redondeo "bonito" hacia arriba para que la línea objetivo quede dentro del eje. */
function niceCeil(x) {
  if (!(x > 0)) return x
  const mag = Math.pow(10, Math.floor(Math.log10(x)))
  const step = mag / 2
  return Math.ceil(x / step) * step
}

function valueExtent(spec) {
  let min = Infinity
  let max = -Infinity
  for (const s of spec.series) {
    for (const d of s.data) {
      const v = Array.isArray(d) ? d[1] : d
      if (v === null) continue
      if (v < min) min = v
      if (v > max) max = v
    }
  }
  return { min, max }
}

function buildOption(spec, dark = isDark()) {
  const axisText = dark ? '#9aa4b2' : '#64748b'
  const titleText = dark ? '#e5e9f0' : '#1e293b'
  const split = dark ? 'rgba(148,163,184,0.14)' : 'rgba(100,116,139,0.16)'
  const fmt = makeFormatter(spec.valueFormat)
  const hasTitle = Boolean(spec.title || spec.subtitle)

  const base = {
    backgroundColor: 'transparent',
    textStyle: { fontFamily: FONT_FAMILY },
    aria: { enabled: true },
    title: {
      show: hasTitle,
      text: spec.title || '',
      subtext: spec.subtitle || '',
      left: 8,
      top: 4,
      textStyle: { fontSize: 15, fontWeight: 600, color: titleText },
      subtextStyle: { fontSize: 12, color: axisText },
    },
    color: PALETTE,
    animationDuration: 500,
    animationEasing: 'cubicOut',
  }
  const tooltipBase = {
    confine: true,
    renderMode: 'richText',
    valueFormatter: fmt,
    backgroundColor: dark ? '#262d3d' : '#ffffff',
    borderColor: dark ? 'rgba(148,163,184,0.3)' : 'rgba(100,116,139,0.25)',
    textStyle: { color: titleText },
  }

  if (pieExists(spec.series)) {
    const s = spec.series[0]
    const names = spec.labels.length ? spec.labels : s.data.map((_, i) => `#${i + 1}`)
    return Object.assign(base, {
      tooltip: Object.assign({ trigger: 'item' }, tooltipBase),
      legend: { show: spec.legend !== false, bottom: 0, icon: 'circle', textStyle: { color: axisText } },
      series: [{
        type: 'pie',
        radius: spec.subtitle ? ['42%', '64%'] : ['46%', '70%'],
        center: ['50%', spec.subtitle ? '54%' : '48%'],
        avoidLabelOverlap: true,
        itemStyle: { borderRadius: 6, borderWidth: 2, borderColor: dark ? '#1b2130' : '#ffffff' },
        label: spec.showValues && fmt
          ? { color: axisText, formatter: (p) => `${p.name}: ${fmt(p.value)}` }
          : { color: axisText, formatter: spec.showValues ? '{b}: {c}' : '{b}' },
        data: s.data.map((v, i) => ({ name: names[i] !== undefined && names[i] !== '' ? names[i] : `#${i + 1}`, value: v })),
      }],
    })
  }

  const horizontal = spec.horizontal && !spec.xy
  const valueAxisKey = horizontal ? 'xAxis' : 'yAxis'

  const series = spec.series.map((s, i) => {
    const one = {
      type: s.type === 'area' ? 'line' : s.type,
      name: s.name || `serie ${i + 1}`,
      data: s.data,
      smooth: s.smooth,
      symbol: 'circle',
      symbolSize: 6,
      showSymbol: s.type === 'scatter' || s.data.length <= 60,
      sampling: 'lttb',
      lineStyle: { width: 2.2 },
      barMaxWidth: 26,
      emphasis: { focus: 'series' },
    }
    if (s.color) one.itemStyle = { color: s.color }
    if (s.type === 'area') one.areaStyle = { opacity: 0.16 }
    if (s.stack) one.stack = s.stack
    if (spec.showValues) {
      one.label = { show: true, color: axisText, position: horizontal ? 'right' : 'top' }
      if (fmt) one.label.formatter = (p) => fmt(p.value)
    }
    return one
  })

  if (spec.target !== undefined) {
    series[0].markLine = {
      silent: true,
      symbol: 'none',
      lineStyle: { type: 'dashed', width: 1.5, color: TARGET_COLOR },
      label: { color: TARGET_COLOR, position: horizontal ? 'end' : 'insideEndTop', formatter: fmt ? (p) => fmt(p.value) : '{c}' },
      data: [{ [valueAxisKey]: spec.target }],
    }
  }

  const ext = valueExtent(spec)
  let axisMin = spec.yMin
  let axisMax = spec.yMax
  if (spec.target !== undefined) {
    if (axisMax === undefined && spec.target > ext.max && spec.target > 0) axisMax = niceCeil(spec.target * 1.05)
    if (axisMin === undefined && spec.target < ext.min && spec.target < 0) axisMin = -niceCeil(-spec.target * 1.05)
  }

  const valueAxis = {
    type: 'value',
    name: spec.yTitle || '',
    nameTextStyle: { color: axisText, fontWeight: 'bold' },
    min: axisMin,
    max: axisMax,
    scale: spec.xy,
    // Margen para que los datos no toquen los bordes (ignorado si hay min/max).
    boundaryGap: spec.xy ? ['2.5%', '2.5%'] : [0, '5%'],
    axisLine: { show: false },
    axisTick: { show: false },
    axisLabel: { color: axisText, formatter: fmt, margin: AXIS_LABEL_MARGIN },
    splitLine: { lineStyle: { color: split } },
  }
  const categoryAxis = spec.xy
    ? {
        type: 'value',
        scale: true,
        boundaryGap: ['2.5%', '2.5%'],
        name: spec.xTitle || '',
        nameTextStyle: { color: axisText, fontWeight: 'bold' },
        axisLine: { lineStyle: { color: split } },
        axisTick: { show: false },
        axisLabel: { color: axisText, margin: AXIS_LABEL_MARGIN },
        splitLine: { lineStyle: { color: split } },
      }
    : {
        type: 'category',
        name: spec.xTitle || '',
        nameTextStyle: { color: axisText, fontWeight: 'bold' },
        data: spec.labels.slice(),
        inverse: horizontal,
        // Media banda de margen en ambos extremos (también en líneas/áreas).
        boundaryGap: true,
        axisLine: { lineStyle: { color: split } },
        axisTick: { show: false },
        axisLabel: { color: axisText, hideOverlap: true, margin: AXIS_LABEL_MARGIN },
      }

  // Títulos de eje centrados: el del eje vertical a la izquierda y girado 90°.
  // nameMoveOverlap (ECharts 6) los aparta de las etiquetas y outerBounds
  // 'same' + contain 'all' reserva sitio para etiquetas y títulos.
  const xAxis = horizontal ? valueAxis : categoryAxis
  const yAxis = horizontal ? categoryAxis : valueAxis
  Object.assign(xAxis, { nameLocation: 'middle', nameGap: 12, nameMoveOverlap: true })
  Object.assign(yAxis, { nameLocation: 'middle', nameGap: 12, nameRotate: 90, nameMoveOverlap: true })

  return Object.assign(base, {
    grid: { left: 8, right: 18, top: gridTop(spec), bottom: 6, outerBoundsMode: 'same', outerBoundsContain: 'all' },
    tooltip: Object.assign(
      { trigger: spec.xy ? 'item' : 'axis', axisPointer: { type: 'line', lineStyle: { color: split } } },
      tooltipBase,
    ),
    legend: {
      show: spec.legend !== undefined ? spec.legend : spec.series.length > 1,
      top: hasTitle ? 12 : 4,
      right: 8,
      icon: 'roundRect',
      itemWidth: 12,
      itemHeight: 4,
      textStyle: { color: axisText },
    },
    xAxis,
    yAxis,
    series,
  })
}

/** Margen superior del área de dibujo: deja sitio al título y al subtítulo. */
function gridTop(spec) {
  const titleBottom = spec.subtitle ? 50 : spec.title ? 26 : 0
  return Math.max(28, titleBottom + 14)
}

function pieExists(seriesList) {
  return seriesList.length === 1 && seriesList[0].type === 'pie'
}

// ---------------------------------------------------------------------------
// detección de bloques en el DOM del host
// ---------------------------------------------------------------------------
/** Texto de la primera hoja del banner (DSH lo encabeza siempre con el lenguaje). */
function labelOf(block) {
  const banner = block.querySelector(BANNER)
  if (!banner) return ''
  for (const el of banner.querySelectorAll('*')) {
    if (el.childElementCount === 0) return (el.textContent || '').trim()
  }
  return (banner.textContent || '').trim()
}

function inScope(el) {
  return el.closest(ASSISTANT_ROW) !== null && el.closest(EXCLUDED) === null && el.closest(`[${OWN_ATTR}]`) === null
}

function candidates() {
  const out = []
  const taken = new Set()
  for (const block of document.querySelectorAll(CODE_BLOCK)) {
    if (block.parentElement && block.parentElement.closest(CODE_BLOCK)) continue
    const pre = block.querySelector('pre')
    if (!pre || !inScope(block)) continue
    taken.add(block)
    out.push({ block, label: labelOf(block), raw: pre.textContent || '', legacy: false })
  }
  for (const code of document.querySelectorAll(LEGACY_CODE)) {
    const pre = code.closest('pre')
    const block = pre.closest(CODE_BLOCK) || pre
    if (taken.has(block) || !inScope(block)) continue
    taken.add(block)
    out.push({ block, label: FENCE_LANG, raw: code.textContent || '', legacy: true })
  }
  return out
}

/** ¿Es un chart sin etiqueta explícita? Solo si TODAS las claves raíz son nuestras. */
function looksLikeChart(json) {
  return json !== null && typeof json === 'object' && !Array.isArray(json)
    && Array.isArray(json.series) && Object.keys(json).every((k) => TOP_KEYS.has(k))
}

/**
 * Decide qué hacer con un bloque terminado.
 * @returns {{spec}|{error}|{wait:true}|null} null = no es nuestro, no tocar.
 */
function evaluate(label, raw, legacy) {
  const explicit = label === FENCE_LANG
  if (!explicit && label !== '' && !GENERIC_CODE_LABELS.has(label)) return null
  let json
  try {
    json = JSON.parse(raw)
  } catch {
    if (!explicit) return null
    // Hosts sin marcador de streaming: esperar a que el JSON se complete.
    return legacy ? { wait: true } : { error: 'JSON inválido o incompleto' }
  }
  if (!explicit && !looksLikeChart(json)) return null
  try {
    return { spec: validate(json) }
  } catch (e) {
    return { error: e && e.message ? e.message : String(e) }
  }
}

// ---------------------------------------------------------------------------
// montaje en el DOM (sin innerHTML: solo createElement + textContent + canvas)
// ---------------------------------------------------------------------------
function el(tag, css, text) {
  const node = document.createElement(tag)
  if (css) node.style.cssText = css
  if (text !== undefined) node.textContent = text
  return node
}

function button(text, onClick) {
  const b = el('button', 'font:12px ' + FONT_FAMILY + ';padding:2px 8px;border-radius:6px;cursor:pointer;background:transparent;color:inherit;border:1px solid rgba(148,163,184,0.35);', text)
  b.type = 'button'
  b.addEventListener('click', onClick)
  return b
}

function release(block) {
  const rec = records.get(block)
  if (!rec) return
  try { if (rec.ro) rec.ro.disconnect() } catch {}
  try { if (rec.chart) rec.chart.dispose() } catch {}
  try { if (rec.wrap) rec.wrap.remove() } catch {}
  if (rec.hid) block.style.display = ''
  records.delete(block)
}

function disposeAll() {
  for (const block of Array.from(records.keys())) release(block)
}

function remember(block, raw, streaming, rec) {
  records.set(block, Object.assign({ raw, streaming, kind: 'none' }, rec))
}

function insertWrap(block, wrap, hide) {
  wrap.setAttribute(OWN_ATTR, '')
  block.insertAdjacentElement('afterend', wrap)
  if (hide) block.style.display = 'none'
}

function prettyJson(raw) {
  try { return JSON.stringify(JSON.parse(raw), null, 2) } catch { return raw.trim() }
}

function slug(text) {
  const s = String(text || '').toLowerCase().normalize('NFD').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60)
  return s || FENCE_LANG
}

function mount(block, spec, raw) {
  release(block)
  const wrap = el('div', 'margin:10px 0;border-radius:12px;padding:6px;outline:1px solid rgba(148,163,184,0.22);')
  const bar = el('div', 'display:flex;justify-content:flex-end;gap:6px;padding:0 2px 4px;opacity:0.75;')
  const box = el('div', 'height:' + spec.height + 'px;')
  box.setAttribute('role', 'img')
  box.setAttribute('aria-label', spec.title || 'gráfico')
  wrap.appendChild(bar)
  wrap.appendChild(box)
  insertWrap(block, wrap, true)

  let chart
  try {
    chart = echarts.init(box, null, { renderer: 'canvas' })
    chart.setOption(buildOption(spec))
  } catch (e) {
    try { if (chart) chart.dispose() } catch {}
    wrap.remove()
    block.style.display = ''
    showError(block, e && e.message ? e.message : String(e), raw)
    return
  }
  const ro = new ResizeObserver(() => { try { chart.resize() } catch {} })
  ro.observe(wrap)

  // "Ver datos": JSON formateado dentro del propio wrap, bajo los botones
  // (el bloque del host sigue oculto; suele venir en una sola línea).
  const dataView = el('pre', 'display:none;box-sizing:border-box;margin:0;height:' + spec.height + 'px;overflow:auto;padding:10px 12px;border-radius:8px;background:rgba(148,163,184,0.10);white-space:pre;font:12px/1.5 ' + MONO_FONT + ';')
  dataView.textContent = prettyJson(raw)
  wrap.appendChild(dataView)

  let showingData = false
  const toggle = button('Ver datos', () => {
    showingData = !showingData
    dataView.style.display = showingData ? '' : 'none'
    box.style.display = showingData ? 'none' : ''
    copy.style.display = showingData ? '' : 'none'
    toggle.textContent = showingData ? 'Ver gráfico' : 'Ver datos'
    if (!showingData) { try { chart.resize() } catch {} }
  })
  const copy = button('Copiar', () => {
    const done = () => { copy.textContent = 'Copiado'; setTimeout(() => { copy.textContent = 'Copiar' }, 1000) }
    try {
      navigator.clipboard.writeText(dataView.textContent).then(done, () => {})
    } catch {}
  })
  copy.style.display = 'none'
  const png = button('PNG', () => {
    const a = document.createElement('a')
    a.href = chart.getDataURL({ type: 'png', pixelRatio: 2, backgroundColor: isDark() ? '#1b2130' : '#ffffff' })
    a.download = slug(spec.title) + '.png'
    a.click()
  })
  bar.appendChild(copy)
  bar.appendChild(toggle)
  bar.appendChild(png)
  remember(block, raw, false, { kind: 'chart', wrap, chart, ro, spec, hid: true })
}

function showError(block, message, raw) {
  release(block)
  const box = el('div', 'margin:6px 0 10px;padding:8px 12px;border-radius:10px;font:12px ' + FONT_FAMILY + ';color:#e5484d;background:rgba(239,68,68,0.08);border:1px solid rgba(239,68,68,0.35);', 'dsh-chart: ' + message)
  // El bloque de código queda visible: el usuario no pierde el JSON.
  insertWrap(block, box, false)
  remember(block, raw, false, { kind: 'error', wrap: box })
}

function showPlaceholder(block, raw) {
  const prev = records.get(block)
  if (prev && prev.kind === 'placeholder') { prev.raw = raw; return }
  release(block)
  const m = /"height"\s*:\s*(\d+)/.exec(raw)
  const height = m ? Math.min(MAX_HEIGHT, Math.max(MIN_HEIGHT, Number(m[1]))) : DEFAULT_HEIGHT
  const box = el('div', 'margin:10px 0;border-radius:12px;height:' + height + 'px;display:flex;align-items:center;justify-content:center;font:12px ' + FONT_FAMILY + ';opacity:0.6;outline:1px dashed rgba(148,163,184,0.45);', 'dsh-chart: generando gráfico…')
  insertWrap(block, box, true)
  remember(block, raw, true, { kind: 'placeholder', wrap: box, hid: true })
}

function retheme() {
  const dark = isDark()
  for (const rec of records.values()) {
    if (rec.kind !== 'chart') continue
    try { rec.chart.setOption(buildOption(rec.spec, dark), { notMerge: true }) } catch {}
  }
}

function processBlock(cand) {
  const { block, label, raw, legacy } = cand
  const streaming = block.closest(STREAMING) !== null
  const rec = records.get(block)
  // Nada cambió y lo que montamos sigue en su sitio → no tocar (sin bucles).
  if (rec && rec.raw === raw && rec.streaming === streaming && (!rec.wrap || rec.wrap.isConnected)) return

  if (streaming) {
    const explicit = label === FENCE_LANG
    if (explicit || ((label === '' || GENERIC_CODE_LABELS.has(label)) && CHART_PREFIX.test(raw))) {
      showPlaceholder(block, raw)
    } else {
      release(block)
      remember(block, raw, true, {})
    }
    return
  }

  const result = evaluate(label, raw, legacy)
  if (result && result.wait) return
  if (!result) {
    release(block)
    remember(block, raw, false, {})
  } else if (result.error) {
    showError(block, result.error, raw)
  } else {
    mount(block, result.spec, raw)
  }
}

function sweepDisconnected() {
  for (const block of Array.from(records.keys())) if (!block.isConnected) release(block)
}

function scan() {
  sweepDisconnected()
  for (const cand of candidates()) processBlock(cand)
}

function scheduleScan() {
  if (scanTimer) return
  scanTimer = setTimeout(() => { scanTimer = 0; scan() }, SCAN_DELAY_MS)
}

function start() {
  if (observer) return { stop: stopAll }
  observer = new MutationObserver((mutations) => {
    // Las bajas de bloques se limpian en scan() (sweepDisconnected).
    if (mutations.some((m) => m.type === 'attributes' && m.attributeName === DARK_ATTR)) retheme()
    scheduleScan()
  })
  observer.observe(document.body, {
    childList: true,
    subtree: true,
    characterData: true,
    attributes: true,
    attributeFilter: ['data-streaming', DARK_ATTR],
  })
  const media = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null
  if (media && media.addEventListener) media.addEventListener('change', retheme)
  const onUnload = () => stopAll()
  window.addEventListener('beforeunload', onUnload)
  scheduleScan()

  function stopAll() {
    if (observer) { observer.disconnect(); observer = null }
    if (scanTimer) { clearTimeout(scanTimer); scanTimer = 0 }
    if (media && media.removeEventListener) media.removeEventListener('change', retheme)
    window.removeEventListener('beforeunload', onUnload)
    disposeAll()
  }
  return { stop: stopAll }
}

// @dsh-chart:test-seam:start — build.mjs elimina este bloque de lib/client.js
window.__dshChartTest = { parseSpec, buildOption, isFinalJson, evaluate, labelOf, scan, retheme, records, TOP_KEYS, SERIES_KEYS }
// @dsh-chart:test-seam:end
