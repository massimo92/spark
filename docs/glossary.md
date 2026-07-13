# Glosario

## Alias de lanzamiento

Nombre estable que identifica una configuración guardada por Spark para iniciar
un modelo.

Se gestiona con `spark alias`; al ejecutarlo, se usa `spark run <alias>`.

Se guarda localmente bajo `~/.config/spark/`; no es configuración del proyecto
ni se sube al repositorio.

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
