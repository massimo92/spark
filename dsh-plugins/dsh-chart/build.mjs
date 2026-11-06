/**
 * build.mjs — compone lib/client.js = cabecera de procedencia + echarts.min.js
 * (vendorizado, sin modificar) + src/client-renderer.js (código propio).
 *
 * - Verifica el sha256 del vendor contra el valor fijado: si no coincide, aborta.
 * - Encierra echarts en un closure con module/exports locales: el UMD toma la
 *   rama CommonJS y NO crea window.echarts (sin choque con otros plugins).
 * - Elimina la costura de test (window.__dshChartTest) del artefacto.
 * Reproducible: misma entrada → mismo sha256 de salida.
 */
import { createHash } from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const ECHARTS_VERSION = '6.1.0'
const ECHARTS_SHA256 = 'b66b25aeb4df84e33199dc21694014d336d222cbd9deb0e5a7c14bd6aa0d0fd0'
const ECHARTS_NPM_SHA512 = 'sha512-q0yaFPggC9FUdsWH4blavRWFmxdrIodbkoKNAjJudAI6CA9gNPxHtV2RcZNEepZVlk4yvBYkOkbk6HIVpIyHZA=='
const SEAM = /\n\/\/ @dsh-chart:test-seam:start[^\n]*\n[\s\S]*?\n\/\/ @dsh-chart:test-seam:end\n/g

const root = dirname(fileURLToPath(import.meta.url))
const sha = (b) => createHash('sha256').update(b).digest('hex')

const echarts = readFileSync(join(root, 'vendor', 'echarts.min.js'))
const echartsSha = sha(echarts)
if (echartsSha !== ECHARTS_SHA256) {
  console.error(`ERROR vendor/echarts.min.js sha256=${echartsSha}\n  esperado ${ECHARTS_SHA256} (echarts ${ECHARTS_VERSION}). Abortado.`)
  process.exit(1)
}

const source = readFileSync(join(root, 'src', 'client-renderer.js'), 'utf8')
const seams = source.match(SEAM) || []
if (seams.length !== 1) {
  console.error(`ERROR se esperaba 1 bloque test-seam en src/client-renderer.js, hay ${seams.length}. Abortado.`)
  process.exit(1)
}
const renderer = source.replace(SEAM, '\n')
if (renderer.includes('__dshChartTest')) {
  console.error('ERROR quedan referencias a __dshChartTest tras quitar la costura. Abortado.')
  process.exit(1)
}

const header = [
  '/*!',
  ' * dsh-chart lib/client.js — GENERADO por build.mjs, no editar a mano.',
  ' * Composición: esta cabecera + vendor/echarts.min.js + src/client-renderer.js (sin costura de test)',
  ` * echarts ${ECHARTS_VERSION} (UMD minificado, oficial, sin modificar) sha256=${echartsSha}`,
  ` *   tarball npm verificado: ${ECHARTS_NPM_SHA512}`,
  ' *   (fix de CVE-2026-45249; sin rutas de red propias — no carga mapas ni themes remotos en este uso)',
  ' * echarts vive en un closure (module/exports locales): no se publica window.echarts.',
  ' */',
  '',
].join('\n')

const out = header
  + ';(function () {\n'
  + 'var module = { exports: {} }; var exports = module.exports;\n'
  + echarts.toString('utf8')
  + '\n;(function (echarts) {\n'
  + renderer
  + '\n})(module.exports);\n'
  + '})();\n'

writeFileSync(join(root, 'lib', 'client.js'), out)
console.log('OK lib/client.js  echarts-sha256=' + echartsSha + '  out-sha256=' + sha(readFileSync(join(root, 'lib', 'client.js'))))
