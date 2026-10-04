# UltraFast on GB10: measured serving configuration

Built and served with [Spark by Massimo Angelini](https://github.com/massimo92/spark).
Measurements taken on 2026-10-04 using the
[UltraFast source snapshot](https://github.com/dime-online/qwen3.8-Flash-DGX-UltraFast/tree/0c391a3e74b6a775cfe248691ca7fd855b1876a5).
Exact measurements and provenance are in [the JSON report](benchmarks/ultrafast-gb10-2026-10-04.json).

## Configuration

GB10 with 121 GiB reported system memory; Gemma and the previous Qwen 27B stopped.
The `qwen38-flash-ultrafast` bundle uses the pinned Saren W4A16/FP8 hybrid checkpoint,
the prepared T80 dense-MTP g32 head, a 65,536-token draft vocabulary, NVMe PLE,
integrated MTP depth 3, prefix caching and piecewise CUDA graphs.

GPU memory utilization is **0.78**, with automatically sized KV cache;
configured context is **262,144 tokens**, concurrency **8**, KV dtype `auto`.
The engine reported **69.11 GiB model weights**, **10.23 GiB KV cache**, and
**354,248 KV tokens**. The KV pool is shared: eight configured requests do not
mean eight independent 256k windows can fit simultaneously.

The prepared checkpoint verifier checked nine converted MTP modules and zero
target conversions, 340 copied tensors byte-identical to their source, and
zero degenerate quantization groups. This verifies preparation, not model quality.

## Public copy benchmark

Unmodified upstream `bench_copy_streams.py`: streams 1–8, three rounds per
level, 1,500 output tokens, low reasoning effort, a successful 120-second idle
gate, no foreign inference traffic. All **24 rounds / 108 measured requests**
completed; the benchmark warmup is excluded. Numbers below use its common
decode-window measurement, not whole-request speed including prefill.

| Streams | Measured median tokens/s | Published median tokens/s | Tokens/step |
| ---: | ---: | ---: | ---: |
| 1 | 74.95 | 69.61 | 3.968 |
| 2 | 112.73 | 108.52 | 3.967 |
| 3 | 139.96 | 130.93 | 3.958 |
| 4 | 171.59 | 152.93 | 3.974 |
| 5 | 201.80 | 168.98 | 3.970 |
| 6 | 219.79 | 190.83 | 3.969 |
| 7 | 226.74 | 201.80 | 3.965 |
| 8 | 255.56 | 211.49 | 3.966 |

The public generator produced **7,114-token prompts**. Upstream's original
private workload used a cached shared prefix of approximately 9.6k tokens.
These are different prompts and cache conditions: the comparison supports the
approximate decode-throughput range, not a strict claim of improvement. Our
median time to first token was **1.263 s** at one stream and **3.911 s** at eight;
upstream reported **0.61 s** at one stream. Copying is favorable to MTP; this
benchmark does not measure general coding-agent speed or output correctness.
Published numbers come from the snapshot's
[benchmark report](https://github.com/dime-online/qwen3.8-Flash-DGX-UltraFast/blob/0c391a3e74b6a775cfe248691ca7fd855b1876a5/docs/BENCHMARKS.md).

## Actual context capacity

Separate synthetic token-prompt requests, each producing 16 tokens, completed
with **zero cached input tokens**:

| Input tokens | Output tokens | Time to first token | Result |
| ---: | ---: | ---: | :--- |
| 131,072 | 16 | 61.030 s | Completed |
| 262,080 | 16 | 131.563 s | Completed |

These establish 128k and near-256k context admission on this solo configuration.
They do not establish retrieval quality, long-context reasoning accuracy, or
cold-prefill speed for arbitrary prompts.

## Save and repeat

```bash
spark run qwen38-flash-ultrafast
spark alias capture ultrafast-solo
spark run ultrafast-solo --main
spark run ultrafast-solo --force
```

Capture the running Saren model when prompted. The alias fixes the recipe
revision and immutable image. Prepared files are reused on restart; changing
port or concurrency does not require preparing another checkpoint. Main is
served through Spark's OpenAI-compatible gateway as model `main`.
