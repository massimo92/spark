# ADR 0001: Alias de lanzamiento

Estado: aceptado

## Contexto

Un usuario debe poder guardar una configuración de lanzamiento bajo un alias y
ejecutarla con `spark run <alias>`.

## Decisiones acordadas

- El alias pertenece a Spark, no a un motor concreto.
- Spark selecciona el backend habitual y comprueba si la configuración guardada
  es compatible con él.
- Una incompatibilidad no se ignora: Spark muestra un aviso claro y no lanza.
- La modificación posterior se hará mediante un comando específico de edición.
- Capturar una instancia guarda su configuración efectiva exacta, incluidos los
  valores calculados automáticamente por el backend, la imagen (referencia e ID)
  y solo las variables de entorno incluidas en una allowlist.
- La interfaz se agrupa bajo `spark alias`.
- `spark alias capture <alias>` muestra los lanzamientos vivos y deja escoger
  cuál capturar.
- La sustitución de un alias existente requiere `--force`.
- Los alias son configuración local del usuario y nunca forman parte del repo.
- No habrá esquema versionado. Antes de modificar un alias, Spark conserva una
  única copia anterior de ese alias para posible rollback.
- `spark alias rollback <alias>` restaura la copia previa de ese alias tras
  confirmación.
- El asistente de creación y edición lista modelos locales y permite introducir
  otro. Pregunta todas las opciones públicas de `spark run`; una respuesta vacía
  conserva el valor automático o por defecto.
- El asistente no expone opciones internas de Spark ni argumentos raw de vLLM.
- Al ejecutar un alias, los parámetros del modelo permanecen congelados. Solo se
  permiten overrides operativos: `--dry-run`, `--explain`, `--force`, `--port`,
  `--tail` y `--no-wait`.
- `--explain` implica `--dry-run`; ambos son no destructivos y nunca paran,
  eliminan ni arrancan contenedores.
- Si un alias existe, `spark run <nombre>` lo prioriza sobre un modelo con el
  mismo nombre. Los alias guiados se comprueban contra el backend actual; una
  captura vLLM solo se reproduce con vLLM y si no, Spark avisa y no lanza.

## Persistencia

- `~/.config/spark/aliases.json` contiene un objeto JSON por alias y se escribe
  de forma atómica con permisos `0600`.
- `~/.config/spark/aliases.backup.json` conserva una definición previa por
  alias. No es un historial ni incluye versión de esquema.
- Un alias guiado guarda backend, modelo y flags públicos elegidos.
- Una captura vLLM guarda el comando efectivo de vLLM leído del contenedor.
  Al reproducirlo, Spark conserva esos argumentos y la imagen exacta, pero
  vuelve a comprobar la capacidad y reconstruye las protecciones Docker para el
  host actual. El entorno capturado se limita actualmente a
  `VLLM_MARLIN_USE_ATOMIC_ADD`; nunca se persiste el entorno completo.

## Pendiente

- Evaluar validación ambiental profunda (imagen/modelo/puerto disponibles) sin
  mezclarla con la validación estructural del alias.
