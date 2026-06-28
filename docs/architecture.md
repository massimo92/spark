# Architecture Audit

Project: spark by Massimo Angelini - https://github.com/massimo92/spark

## Current Shape

- One self-contained Bash executable, `spark`, is the product boundary.
- This constraint is real: `install.sh`, `spark update`, and remote setup copy or download one file.
- Main runtime domains are platform detection, model profiling, vLLM, Ollama, setup, workspace, gateway, and CLI dispatch.
- `tests/run.sh` is also monolithic, but it gives broad fake-bin integration coverage across Docker, Tailscale, Ollama, n8n, Vikunja, Hermes, and shell edge cases.
- CI already runs syntax, ShellCheck, and full tests on Linux and macOS.

## Assessment

Maintenance risk: medium-high.

- Strengths: strict Bash mode, quoted command arrays in key paths, broad regression tests, explicit security checks, JSON profiles through `jq`.
- Weaknesses: 6k+ line script, many globals, Bash dynamic scoping between functions, long workspace section, and docs that can drift from source.

Scalability risk: medium.

- Strengths: backend split exists conceptually (`vllm` vs `ollama`), setup uses `ctx_*` abstraction for local/remote parity, doctor tests encode production checks.
- Weaknesses: adding another backend/provider/workspace service currently expands the same file and same test script.

Onboarding risk: medium-high.

- Strengths: README and flow docs explain user behavior well.
- Weaknesses: new contributors need the hidden module map, dynamic-scope contracts, and packaging invariant before editing safely.

## Indispensable Improvements

1. Make architecture boundaries executable and visible.
   - Implemented with `spark architecture`.
   - Keeps the single-file packaging rule explicit.
   - Gives new contributors the domain map and boundary rules without reading 6k lines first.

2. Separate definition from execution.
   - Implemented with `main "$@"` plus a `BASH_SOURCE` guard.
   - Enables future function-level tests and shell loading without accidentally running dispatch.

3. Protect the new architecture contract with tests.
   - Implemented in `tests/run.sh`.
   - Tests verify `spark architecture` output and that sourcing `spark` loads functions without dispatch.

4. Keep docs as a navigation layer, not a second source of truth.
   - `docs/architecture.md` holds audit and invariants.
   - `docs/flow.md` remains behavior flow; use `spark architecture` for current source boundaries.

## Next Refactor Plan

Do this only after the current contract stays green in CI.

1. Split `tests/run.sh` first, not runtime code.
   - Move fake binaries into `tests/fixtures/fake-bin.sh`.
   - Group tests by domain: core, vllm, ollama, setup, workspace, gateway.
   - Keep `bash tests/run.sh` as the stable entrypoint.

2. Extract runtime modules only with installer support.
   - Add a packaging plan for `lib/` files.
   - Update `install.sh`, `spark update`, and remote deploy together.
   - Keep a single-file release artifact if curl-install remains required.

3. Reduce dynamic-scope coupling.
   - Pass explicit arguments into `run_backend_*` and `build_launch`.
   - Start with low-risk helpers that already return scalar values.
   - Keep current tests as behavior lock.

4. Add generated docs checks.
   - Prefer `spark architecture` as the contract.
   - Add CI smoke that fails if command/help/docs mention different top-level command names.
