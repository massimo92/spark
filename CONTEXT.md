# Spark

Spark serves local models through reproducible launch configurations while
keeping distributable definitions separate from machine-local executions.

## Language

**Bundle**:
A Git-versioned definition that fixes one target model, one drafter, its vLLM
Docker build, patches, defaults, and configurable options.
_Avoid_: Image, preset, recipe, acceleration

**Built image**:
The immutable Docker artifact produced by building a bundle.
_Avoid_: Bundle

**Launch alias**:
A machine-local snapshot of an effective Spark launch configuration.
_Avoid_: Bundle, model alias
