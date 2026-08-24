# Qwen3.8-27B inference experiments on NVIDIA GB10

This document records the Qwen3.8-27B experiments run on one NVIDIA GB10
(DGX Spark / ASUS Ascent GX10). It separates benchmark protocols because values
from different prompts, output lengths, cache states, or concurrency levels are
not directly comparable.

## Fixed artifacts

- NVFP4 target: `sakamakismile/Qwen3.8-27B-MTP-NVFP4`
- NVFP4 revision: `6d98dc1f1d5259c9582794014b73852baf20f805`
- FP8 target: `Qwen/Qwen3.8-27B-FP8`
- FP8 revision: `017b9c7af6b5689d5dd426a76e0bc077eb5ca20a`
- W4A16 drafter: `syvai/Qwen3.8-27B-DFlash2-W4A16`
- W4A16 revision: `4d30ec736ffc6b8688dc2ae2b502d9b48bdec279`
- BF16 drafter: `z-lab/Qwen3.8-27B-DFlash2`
- BF16 revision: `50307d4c4cde6860d4eee73e2547cd786fe8e8a4`
- vLLM development build: `0.1.dev20113+gc9f474540`
- Target attention backend: FlashAttention 2 on SM121

The W4A16 loading and lookup work was adapted from
[`syv-ai/qwen38-27b-rtx3090`](https://github.com/syv-ai/qwen38-27b-rtx3090),
published by Reddit user `u/iamMess`. DFlash 2 itself was released by Inco AI.

## 1. Drafter quantization and draft-depth sweep

Protocol: eight real prompts, 256 generated tokens, greedy decoding, one
warm-up and three measured passes. The target remained NVFP4 and only the
drafter changed.

| Experiment | Mean tok/s | Acceptance | Tokens/step | Decision |
|---|---:|---:|---:|---|
| BF16 DFlash2, k7 | 36.149 | 43.68% | 4.057 | Baseline drafter |
| W4A16 DFlash2, k7 | 39.408 | 41.71% | 3.920 | W4A16 helps despite slightly lower acceptance |
| W4A16 DFlash2, k6 | 40.381 | 50.00% | 4.000 | Good local point |
| W4A16 DFlash2, k5 | 36.427 | 51.90% | 3.595 | Rejected |
| W4A16 DFlash2, k4 | 34.498 | 59.58% | 3.383 | Rejected |
| W4A16 DFlash2, k8 | 39.128 | 37.07% | 3.965 | Rejected |
| **W4A16 DFlash2, k9** | **42.489** | **37.44%** | **4.369** | Best chat-only point |
| W4A16 DFlash2, k10 | 41.258 | 32.24% | 4.224 | Below k9; sweep stopped |

The curve is non-monotonic. Acceptance rate alone does not predict speed;
kernel shapes and accepted tokens per target verification step also matter.

## 2. Lookup-augmented k15

The patched engine lets DFlash2 draft its trained seven tokens while lookup
fills another eight positions from the request's own context. The target then
verifies 15 proposed tokens in one step.

### Full imported patch set

| Workload | Configuration | Decode tok/s | Tokens/step | TTFT |
|---|---|---:|---:|---:|
| Ordinary chat | lookup k15 | 38.851 | 3.848 | — |
| 23,386-token Markdown replay | lookup k15 | 128.621 | 14.333 | 12.076 s |
| Same replay control | DFlash2 k7 | 71.260 | 7.773 | 10.733 s |

The long block improved replay by 80.5%, but ordinary chat was 8.6% slower
than the k9 chat profile. This is a workload trade-off, not a universal gain.

### Minimal two-patch image

The final distributable bundle keeps only:

1. W4A16 packed-QKV loading for the DFlash2 drafter.
2. DFlash2 plus lookup with a seven-token draft and k15 verification.

It excludes split-KV, the custom sampler, speculative INT8 KV, hybrid KV group
patches, and recurrent-state bounds patches.

| Workload | Result |
|---|---:|
| Chat C1, three runs | 38.971 / 39.012 / 39.012 tok/s |
| Natural 23,386-token replay | approximately 106 tok/s |
| Replay acceptance | 12.829 tokens/step |
| C4, cached 49k-token prompts | 35.776 and 36.293 aggregate tok/s |

No OOM, traceback, CUDA error, or illegal-memory-access error occurred in the
four-round C4 stress test.

## 3. Attention, prefill chunk, and runtime sweep

Protocol: C1; three repetitions; a 33-token chat prompt with 256 forced output
tokens; a cold 30,251-token prompt with 64 forced output tokens. A nonce at the
start prevented prefix-cache hits. Fixed configuration: NVFP4 target, W4A16
DFlash2, lookup k15, KV `auto`, BF16 recurrent state, prefix caching, normal
FlashInfer sampler, and synchronous scheduling unless the row says otherwise.

| Experiment | Chat decode tok/s | Cold TTFT at 30k | Decision |
|---|---:|---:|---|
| Baseline: FA2, chunk 8192, O2 balanced | 38.134 | 14.633 s | Reference |
| Attention backend `auto` | 38.070 | 14.242 s | Selected FA2; equivalent |
| FlashInfer attention | 36.932 | 15.115 s | Rejected |
| Chunk 16384 | 38.939 | 18.439 s | Rejected: TTFT regression |
| Chunk 4096, O2 balanced | 37.712 | 13.023 s | Promising |
| Chunk 2048 | 38.167 | 21.286 s | Rejected: too many chunks |
| **Chunk 4096, O2 interactivity, sync** | **38.100** | **12.563 s** | **Winner** |
| Chunk 4096, O3 balanced | 38.044 | 12.708 s | No useful gain over O2 |
| Chunk 4096, O3 interactivity | 38.012 | 12.567 s | No useful gain over O2 |
| Chunk 4096, O2 interactivity, async | 37.437 | 12.592 s | Rejected |

The useful changes are the 4,096-token prefill chunk and the `interactivity`
profile. O2 and synchronous scheduling are pinned explicitly for stability.

## 4. Long-context and concurrency validation

### Cold 50,172-token C1

| Configuration | Short decode | Cold TTFT | Long decode |
|---|---:|---:|---:|
| Previous defaults: chunk 8192 | 37.956 tok/s | 29.941 s | 27.855 tok/s |
| **New defaults: chunk 4096, O2 interactivity** | **38.124 tok/s** | **23.463 s** | 26.507 tok/s |

The new defaults reduced TTFT by 21.6% without a meaningful short-decode loss.
Long decode values are secondary because small numerical changes altered the
generated trajectory.

### Four simultaneous cold 49k-token requests

Each request generated 256 forced tokens. This metric is output tokens divided
by complete wall time, including all four prefills. It is not decode-only
throughput.

| Configuration | Wall time | End-to-end aggregate output tok/s |
|---|---:|---:|
| Previous defaults | 149.476 s | 6.851 |
| **New defaults** | **135.377 s** | **7.564** |

The new defaults completed the workload 9.4% sooner and improved aggregate
end-to-end output throughput by 10.4%.

## 5. FP8 target experiments

### Same fixed prompt as the NVFP4 runtime sweep

| FP8 configuration | Short decode | Cold TTFT at 30k | Tokens/step |
|---|---:|---:|---:|
| W4A16 drafter, lookup k15, optimized runtime | 25.992 tok/s | 23.048 s | 3.737 |
| W4A16 drafter, k9 without lookup | 24.871 tok/s | 24.746 s | 3.693 |
| BF16 drafter, k7, Reddit server flags | 23.074 tok/s | 35.104 s | 3.716 |

FP8 did not match the 38.1 tok/s NVFP4 result on this prose-oriented prompt.
Similar speculative acceptance shows that target-weight bandwidth, rather than
a broken drafter, explains most of the gap.

### Reproduction of the reported ~32 tok/s FP8 result

Source post:
[`[DGX Spark] Qwen 3.8 27B (FP8) at ~32tok/s generation`](https://www.reddit.com/r/LocalLLM/comments/1vtbwtb/dgx_spark_qwen_38_27b_fp8_at_32toks_generation/).

Reproduction used the author's image, BF16 DFlash2 k7, 240k context,
`gpu-memory-utilization=0.88`, an 8,196-token batch limit, fastsafetensors, and
FA2. The public four-task harness ran three repetitions with temperature zero,
thinking disabled, and 512 output tokens.

| Task | Median decode tok/s |
|---|---:|
| Go code generation | 37.76 |
| Plain-language prose | 17.82 |
| Arithmetic | 37.59 |
| Python refactor | 31.61 |
| **Mean of task medians** | **31.20** |

Acceptance length was 4.618 tokens/step. The published ~32 tok/s result is
reproducible, but it is a workload average: it does not imply 32 tok/s on
ordinary prose.

The exact 240k/0.88 configuration did not fit Spark's normal 90.8 GiB container
cap during warm-up. Raising only the experimental cap to 112 GiB allowed it to
start. It allocated 651,590 KV-cache tokens and reported theoretical maximum
concurrency of 2.71 at 240k context.

`--load-format fastsafetensors` reduced measured model-plus-drafter weight load
to about 29 seconds. This is a cold-start improvement only; it does not improve
decode or TTFT after the server is ready.

### Transferring fastsafetensors to the NVFP4 winner

The same loader was tested with the final NVFP4/W4A16/lookup configuration.

| Loader | Short decode | Cold TTFT at 30k | Available KV | Max 57,344-token concurrency |
|---|---:|---:|---:|---:|
| Normal bundle loader | 38.100 tok/s | 12.563 s | 60.64 GiB | 9.97x |
| `fastsafetensors` | 37.912 tok/s | 12.532 s | 24.94 GiB | 4.10x |

The fast loader brought model loading down to 19.7 seconds but did not improve
inference. Its much smaller KV headroom leaves the intended C4 service too
close to the limit, so it was not adopted.

## Adopted bundle defaults

```text
--max-num-batched-tokens 4096
--optimization-level 2
--performance-mode interactivity
--no-async-scheduling
```

All model, drafter, precision, KV, lookup, context-length, concurrency, and
patch choices remain unchanged. The FP8 post contributed a reproducible
workload explanation, but no inference knob that beats the adopted NVFP4
configuration. Its fast loader was rejected because of the KV-capacity cost.
