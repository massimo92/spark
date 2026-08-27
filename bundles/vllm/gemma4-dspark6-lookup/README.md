# Gemma 4 DSpark + lookup

Experimental NVIDIA GB10 bundle. It keeps the measured Gemma 4 DSpark k=6,
128K context, and BF16 KV configuration, then complements its proposal with a
same-request suffix lookup.

Lookup is deliberately active only for greedy decoding. Sampled decoding keeps
the original DSpark proposal so rejection sampling remains distribution-correct.

The control run uses the same image and patches with lookup disabled:

```bash
spark run gemma4-dspark6-lookup --lookup false
```
