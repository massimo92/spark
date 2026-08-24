# Glosario

## Alias de lanzamiento

Nombre estable que identifica una configuración guardada por Spark para iniciar
un modelo.

Se gestiona con `spark alias`; al ejecutarlo, se usa `spark run <alias>`.

Se guarda localmente bajo `~/.config/spark/`; no es configuración del proyecto
ni se sube al repositorio.

Cuando nace de un bundle, guarda su nombre y todos los ajustes pasados. Se crea
con el flujo normal: `spark alias create <alias>` o
`spark alias capture <alias>`.

## Bundle

Definición versionada en Git que une un target, un drafter, un Dockerfile,
parches, valores vLLM y opciones configurables. Se ejecuta directamente con
`spark run <bundle>`; Spark construye o reutiliza su imagen Docker.

Un bundle no es un alias. El bundle es portable y compartido; el alias es una
configuración de lanzamiento local basada en él.

Se comparte con `spark bundle submit <nombre|directorio>`, que valida el
contenido, muestra los cambios y abre una pull request. `--dry-run` no publica
nada.

## Rollback de alias

Restauración de la configuración previa de un alias concreto mediante
`spark alias rollback <alias>`.

## Configuración efectiva

Valores concretos con los que el backend arrancó un proceso, incluidos valores
calculados automáticamente.

Es la representación que un alias capturado conserva para poder repetir el
lanzamiento.

## Configuración portable

Parte de una configuración que Spark puede interpretar antes de escoger el
backend. Puede coexistir con opciones específicas de un backend.
