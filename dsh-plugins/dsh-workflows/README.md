# dsh-workflows

Workflows por fases para DeepSeek Harness (DSH 0.2). Un workflow es como una skill con varias fases; cada fase controla:

- **Instrucciones**: el modelo las recibe, ocultas, al empezar la fase; en el chat no aparecen.
- **Salida** (opcional): formato del archivo de resultado de la fase. Si una fase lo rellena, el modelo recibe, oculto, un bloque `<workflow_artifacts>` con la carpeta de la ejecución, los archivos de las fases anteriores (su fuente de verdad) y la ruta y formato de su propio archivo: `~/.dsh/scratch/workflows/<sesión>-<workflow>/NN-<fase>.md`. Fuera del repo; nada se escribe en el proyecto.
- **Inicio**: automático (en el chat solo sale una marca `▸ workflow · fase n/N · nombre`) o *espera tu mensaje* (tu mensaje se envía tal cual y arranca la fase).
- **Skills** que se cargan en esa fase (igual que escribir `/skill`).
- **Modelo y esfuerzo**: solo para las peticiones de esa fase; las fases que heredan y tus mensajes posteriores vuelven a la config de la sesión.
- **Al terminar**: pasar a la siguiente o *esperar tu OK* (Continuar, con instrucciones extra ocultas opcionales, o escribir un mensaje que arranca la fase siguiente).

Desde la fase 2 (en todos los workflows), el motor compacta el contexto con la compactación nativa de DSH antes de lanzar la fase: cada fase parte de un resumen más la información de los archivos de salida, no de la transcripción completa. Si la compactación falla, la fase arranca igual y queda un aviso en la barra.

Mientras una fase corre, escribir en el chat es el steer nativo de DSH. El botón Stop de DSH también detiene el workflow.

## Dónde está

- Barra lateral derecha → pestaña **Workflows** (guía o botón de ruta junto al input): biblioteca, editor (guardado manual con botón o ⌘S; aviso si sales con cambios), editor grande ⤢ en las cajas de texto, lanzar desde cualquier fase, ejecución.
- Burbuja sobre el input, apilada encima de los to-dos nativos. Clic en la burbuja: vista mínima ↔ ruta de fases. La barra de la fase activa se anima solo mientras corre y respeta movimiento reducido.
- Cada fase muestra **Ver N archivos / Ocultar archivos** y una lista vertical. Clic en un archivo abre el visor nativo de DSH, con sus acciones habituales de apertura en aplicaciones. Los botones de archivos no colapsan la burbuja.
- La ejecución completada o detenida conserva fases y archivos hasta cerrar su burbuja o iniciar otra. Continuar/Reintentar aparecen cuando hacen falta; Saltar/Detener y el panel siguen disponibles al expandir.

- Botón **Workflows** junto al input, también en sesiones vacías.
- Menú **/** → **Workflows**: lista y filtra los workflows guardados; elegir uno lo añade al input como comando. Escribe el primer mensaje y pulsa Enter para arrancar el workflow con ese texto visible en la primera fase.

## Datos

- Definiciones: `~/.dsh/storages/dsh-workflows.json`.
- Artefactos de las fases: `~/.dsh/scratch/workflows/<sesión>-<workflow>/`. La carpeta es por conversación y workflow, así que reanudar (o lanzar desde una fase tras reiniciar DSH) reutiliza los archivos existentes. Al arrancar cualquier workflow se borran (como mucho un barrido por día) las carpetas cuyo archivo más reciente lleve más de 15 días sin tocar; al volver a visitar una conversación su carpeta se mantiene viva.
- Las ejecuciones viven solo en memoria (una por conversación); reiniciar DSH las descarta, pero los artefactos siguen ahí y puedes relanzar desde la fase que quieras en la misma conversación.

Se registran archivos existentes tras operaciones satisfactorias `write`, `edit`, `str_replace_editor`, archivos presentados y salidas declaradas de las fases. Las salidas de ejecuciones anteriores no se cuentan hasta cambiar. Archivos creados solo mediante shell fuera de las salidas declaradas deben presentarse para aparecer. Las fases muestran el archivo actual, no una copia histórica de cada versión.

## Estructura

| Archivo | Qué hace |
|---|---|
| `index.js` | Mitad host: rutas `POST /api/workflows.<acción>` (misma autenticación que `/api`) y eventos del agente |
| `src/engine.js` | Motor de fases (pre-step, request, status, session/event) |
| `src/prompt.js` | Marca visible, instrucciones ocultas y skills |
| `src/store.js` | Validación y guardado |
| `lib/client.js` | Mitad cliente (JS plano, React de DSH) |

## Instalar / quitar

```sh
npx @deepseek-ai/dsh plugin --profile web add link:./dsh-plugins/dsh-workflows
npx @deepseek-ai/dsh plugin --profile web remove @local/dsh-workflows
```

Los cambios de `lib/client.js` se recargan solos en las pestañas abiertas; los de `index.js` y `src/` requieren reiniciar `dsh web`.

## Tests

```sh
npm test
```

## Límites conocidos (MVP)

- Sin transiciones condicionales entre fases (previsto: fase de decisión con modelo tipo System One).
- Sin vista previa del texto completo de la fase en el editor.
- Si cambias el modelo de la sesión a mano durante un workflow, las fases que heredan pueden tardar una petición en recogerlo.
