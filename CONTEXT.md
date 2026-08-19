# Spark

Spark prepares and operates a local model-serving platform and an optional private agent workspace.

## Language

**Model server**:
The base environment that serves models and exposes them through the LiteLLM gateway. It is created by `spark setup` and repaired by `spark repair`.
_Avoid_: Workspace, Hermes stack

**Agent workspace**:
The optional task manager, n8n, Postgres, and Hermes environment built on top of the model server. It is created by `spark ws setup` and repaired by `spark ws repair`.
_Avoid_: Model server, base environment

**Repair**:
An explicit operator-triggered reconciliation that restores a context to its declared working state. Repair is never periodic or automatic.
_Avoid_: Self-healing, background recovery
