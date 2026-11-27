# Inkling 2 Mini DFlash2

Official Thinking Machines checkpoint served with Inco AI's external DFlash2
drafter (`incoai/Inkling-2-Mini-DFlash2`), seven probabilistic draft tokens.

The adapter patch is the diff produced by
[Kaushalya/spark-vllm-docker#11](https://github.com/Kaushalya/spark-vllm-docker/pull/11)
(`mods/inkling2-dflash2/patch_inkling_dflash2.py`) on the pinned vLLM image
`0.1.dev25855+g7cb5dae22.cu130`. It only applies to that exact build.

It replaces the checkpoint's bundled DSpark speculator.

```bash
spark run inkling2-mini-dflash2 --tools -- --kv-cache-memory-bytes 16G
```
