# Qwen3.8 DFlash2 lookup

Minimal unified bundle tested on NVIDIA GB10. It serves the pinned Qwen3.8-27B
NVFP4 target with the pinned DFlash2 W4A16 drafter, verifies k15, and enables
lookup. It deliberately excludes split-KV, the custom sampler, speculative KV
INT8, hybrid KV grouping, and recurrent-state bounds patches.

The runtime defaults use 4,096-token prefill chunks, optimization level 2,
the `interactivity` performance profile, and synchronous scheduling. Against
the previous 8,192-token `balanced` defaults, this kept short-prompt decode at
about 38.1 tok/s while reducing cold TTFT at 50k tokens from 29.94 to 23.46
seconds. Four simultaneous cold 49k-token requests completed 9.4% sooner.

Measured on the DGX Spark used for development:

- Chat C1: 38.998 tok/s mean over three runs.
- Natural replay: approximately 106 tok/s.
- C4 with approximately 49k-token prompts: completed without OOM; cached rounds
  reached 35.776 and 36.293 aggregate tok/s.

Run with defaults:

```bash
spark run qwen38-dflash2-lookup
```

Create an alias from this bundle and choose its adjustments in the existing
alias guide:

```bash
spark alias create qwen38-unified
```
