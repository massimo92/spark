# dsh-chart — plugin propio de gráficos para DeepSeek Harness

Renderiza bloques ` ```dsh-chart ` (JSON de **datos puros**) como gráficos
ECharts dentro del chat de DSH Web. Diseñado tras la auditoría de seguridad de
2026-10-05: **ningún dato del modelo se convierte jamás en código**.

Probado contra el markup de DSH **0.2.0-rc.2** (`@deepseek-ai/dsh-client-ui-primitives`).

## Estructura (todo lo que hay que revisar)

| Fichero | Qué es | Líneas |
|---|---|---|
| `index.js` | Mitad host: solo añade una sección **estática** al system prompt | 36 |
| `cordis.patch.yml` | Solo registra el plugin en el perfil | 5 |
| `package.json` | Manifest; sin dependencias; cero scripts | 21 |
| `src/client-renderer.js` | **100% del código cliente propio** (validador + option + detección DOM + montaje) | ~700 |
| `vendor/echarts.min.js` | ECharts 6.1.0 oficial UMD, sin modificar | binario fijado |
| `build.mjs` | Compone `lib/client.js`; verifica sha del vendor; aísla echarts; quita la costura de test | 65 |
| `test/unit.mjs` + `test/fake-dom.mjs` | 23 tests `node:test` (validador, option, DOM de DSH, host, artefacto) | ~430 |
| `test/harness.html` | Prueba visual en navegador del `lib/client.js` real | 85 |

## Cadena de confianza

- ECharts **6.1.0** del tarball oficial de npm:
  `sha512-q0yaFPggC9FUdsWH4blavRWFmxdrIodbkoKNAjJudAI6CA9gNPxHtV2RcZNEepZVlk4yvBYkOkbk6HIVpIyHZA==`
  - fichero extraído: `sha256 b66b25aeb4df84e33199dc21694014d336d222cbd9deb0e5a7c14bd6aa0d0fd0`
    (fijado en `build.mjs`: si no coincide, el build aborta).
  - corrige CVE-2026-45249 (XSS tooltip serie Lines, afecta a <6.1.0).
- `lib/client.js` generado: `sha256 dccd242fec36961f67f876fd79b9a8e5bb3b7f85d97a23cee9b296f89abc5d93`
  (reproducible con `node build.mjs`; un test falla si `lib/` no corresponde a `src/`).

## Invariantes de seguridad

1. **Sin `eval` ni `new Function`**: el schema no admite expresiones; el option se construye campo a campo. Los únicos callbacks del option (formatos de valor) son código propio, nunca texto del modelo.
2. **Sin `innerHTML`**: errores, botones y placeholder usan `textContent`; el gráfico va a canvas.
3. **Whitelist por capas**: claves raíz, claves de serie, tipos (`line|bar|area|scatter|pie`), `valueFormat` (enum), colores (`#rgb|#rgba|#rrggbb|#rrggbbaa`), límites (24 series, 10000 puntos, 1024 labels, longitudes). Cualquier desviación → caja de error; nada se renderiza a medias.
4. **Sin DOM HTML de terceros**: renderer `canvas` y tooltip `renderMode: 'richText'` forzados.
5. **echarts privado**: `build.mjs` lo encierra en un closure (rama CommonJS del UMD); no existe `window.echarts` ni choca con el echarts de otros plugins (p. ej. dsh-genui).
6. **Cero red, cero fs**: el host solo registra texto en el prompt; el cliente solo lee y observa el DOM de la página. ECharts vendorizado: sin CDN ni mapas remotos.
7. **Alcance acotado**: solo bloques dentro de filas de asistente (`[data-chat-flow-kind="assistant-step"]`); se ignoran razonamiento, tools, sidebars y paneles.
8. La costura de test (`window.__dshChartTest`) existe solo en `src/`; el build la elimina y verifica que no quede.

## Cómo encuentra los bloques (DSH 0.2)

DSH no pone `class="language-…"` en el `<code>`: el lenguaje solo aparece en el
banner del `.md-code-block`, y para lenguajes sin resaltado (como `dsh-chart`)
el banner muestra la etiqueta genérica traducida (`Code block` / `代码块`).
Por eso el plugin acepta un bloque si:

- el banner dice `dsh-chart` (variante sin toolbar), o
- el banner es genérico **y** el contenido es un objeto JSON con `series` y
  **solo** claves del schema (el JSON ajeno no se toca);
- fallback para otros hosts: `pre > code.language-dsh-chart`.

Durante el streaming (`[data-streaming]`) se muestra un hueco "generando
gráfico…" con la altura final; al terminar se pinta el gráfico o, si no era
un chart, se devuelve el bloque tal cual.

### Límites conocidos (honestidad de diseño)

- La detección depende del markup de DSH (selectores arriba). Un cambio mayor del chat puede requerir adaptarlos; los tests de `test/unit.mjs` documentan el markup esperado.
- Un bloque sin etiqueta cuyo JSON cumpla exactamente el schema se pintará como gráfico (es la intención en DSH 0.2, donde no se puede leer el lenguaje).
- El tema se lee de `body[data-ds-dark-theme]` (DSH) y se re-aplica en vivo; fuera de DSH se usa `prefers-color-scheme`.

## Contrato del fence

El modelo lo aprende por la sección de prompt `dsh-chart:fence` (texto íntegro en `index.js`, `FENCE_PROMPT`).

~~~text
```dsh-chart
{
  "title": "Horas Mespack por semana ISO",
  "labels": ["W01", "W02", "W03"],
  "yTitle": "horas",
  "valueFormat": "hours",
  "target": 38,
  "series": [
    { "name": "horas", "type": "bar", "data": [17.9, 27, 13.5] }
  ]
}
```
~~~

Claves raíz: `title, subtitle, labels, series, xTitle, yTitle, legend, height,
horizontal, yMin, yMax, target, showValues, valueFormat`.
Serie: `name, type(line|bar|area|scatter|pie), data, smooth, stack, color`. Nada más.

- `labels` admite strings o números; `data` no puede tener más valores que `labels`.
- `scatter` admite pares `[x, y]` (eje X numérico); entonces todas las series deben ser scatter con pares.
- `pie`: una sola serie, sin negativos; `legend: false` la oculta.
- `target`: línea discontinua de objetivo (el eje se amplía para que se vea).
- `valueFormat`: `int | decimal | percent | hours` (ejes, tooltip y etiquetas).
- Cada gráfico trae botones **Ver datos** (JSON formateado dentro de la misma caja, con **Copiar**) y **PNG** (descarga local vía `getDataURL`).

### `inject` en `package.json` vs en el módulo

No es una incoherencia: `dsh.client.inject` en `package.json` son **paquetes
cliente** que deben cargarse antes (orden de carga: el chat de
`dsh-client-ui-conversation`); `inject: []` en el factory son **servicios cordis**
que el módulo necesita (ninguno). El host sí declara `inject = ['systemPrompt']`.

## Instalar / quitar *(con tu aprobación — no se hace solo)*

```sh
npx @deepseek-ai/dsh plugin --profile web add link:./dsh-plugins/dsh-chart
# reiniciar dsh web y abrir sesión nueva; para quitar:
npx @deepseek-ai/dsh plugin --profile web remove dsh-chart
```

Con el plugin instalado, los cambios de `lib/client.js` se aplican solos en las pestañas abiertas de DSH (recarga en caliente); los de `index.js` (prompt) requieren reiniciar `dsh web` y abrir sesión nueva.

## Antes de cada commit

Nada que hacer a mano: el hook `.githooks/pre-commit` valida **exactamente lo añadido con `git add`** (lo copia a una carpeta temporal), recompila `lib/client.js` y, si el del commit está desfasado, lo sustituye en el commit automáticamente; después pasa los tests sobre esa copia y cancela el commit si fallan. Los cambios sin añadir no influyen.
Se activa **una vez por clon**, solo para este repo: `git config core.hooksPath .githooks`.
Sin hook, a mano: `node build.mjs && node test/unit.mjs && git add lib/client.js`.

## Verificar por tu cuenta

```sh
cd ~/.dsh/plugins/dsh-chart
node build.mjs            # aborta si el vendor no coincide con el sha fijado
node test/unit.mjs        # 23 tests: payloads hostiles, DOM de DSH, host, artefacto
node --check lib/client.js
python3 -m http.server 8765   # y abrir http://localhost:8765/test/harness.html
```
