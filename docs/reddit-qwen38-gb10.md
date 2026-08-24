# Suggested title

Qwen3.8-27B at ~38 tok/s chat and ~106 tok/s context replay on one GB10 (DGX Spark / ASUS Ascent GX10)

# Post body

I have been tuning Qwen3.8-27B on a single NVIDIA GB10, specifically the DGX
Spark / ASUS Ascent GX10. The configuration I ended up keeping reaches about
38-39 tok/s on ordinary chat, approximately 106 tok/s when the answer can reuse
the request context, and cuts cold TTFT at 50k tokens by 21.6%.

First, credit where it is due: the difficult parts came from the work by
**u/iamMess / syv-ai** in this post and repository:

- https://www.reddit.com/r/LocalLLaMA/comments/1vtup5s/i_pushed_qwen3827b_to_381_tps_for_a_single/
- https://github.com/syv-ai/qwen38-27b-rtx3090

I adapted the relevant patches to GB10 rather than treating the RTX 3090
numbers as directly transferable. The 3090 has much more memory bandwidth and
is a discrete GPU; GB10 is a bandwidth-constrained SoC. DFlash 2 itself comes
from Inco AI.

## The configuration

- Target: `sakamakismile/Qwen3.8-27B-MTP-NVFP4`
- Drafter: `syvai/Qwen3.8-27B-DFlash2-W4A16`
- DFlash2 drafts seven tokens; lookup fills the verification block to k15
- FlashAttention 2
- KV cache: `auto`
- Mamba/DeltaNet recurrent state: BF16
- Prefix caching enabled
- Chunked prefill: 4,096 tokens
- vLLM optimization level 2
- vLLM `interactivity` performance profile
- Synchronous scheduling
- Maximum context: 57,344
- Maximum sequences: 4
- Normal FlashInfer sampler
- No split-KV patch

The distributable image is intentionally minimal. It applies only two patches:

1. Load the packed W4A16 QKV weights when DFlash2 builds its fused KV projection.
2. Keep DFlash2's trained seven-token draft block separate from a k15 verify
   block, filling the remaining positions with matches from the request context.

I excluded the custom sampler, split-KV, speculative INT8 KV, hybrid KV-group
patches, and recurrent-state bounds patches. They were not required for the
measured 57k/C4 workload.

## Results

### Ordinary chat

The unified k15+lookup profile measured 38.97, 39.01, and 39.01 tok/s over
three runs on the original eight-prompt suite. A chat-only k9 profile reached
42.49 tok/s, but I prefer the unified profile because it can exploit RAG and
code-editing steps without switching servers.

### Context reuse

On a natural 23,386-token Markdown replay workload:

- Minimal k15+lookup image: approximately 106 tok/s
- Full experimental patch set: 128.62 tok/s
- k7 control: 71.26 tok/s

This is not a universal 100+ tok/s claim. Lookup helps when the output quotes,
replays, or edits material already present in the prompt. It does little for
unpredictable prose.

### Long-context TTFT

I then changed only vLLM runtime scheduling:

| Configuration | Short decode | Cold TTFT at 50k |
|---|---:|---:|
| 8,192-token chunks, O2 balanced | 37.96 tok/s | 29.94 s |
| 4,096-token chunks, O2 interactivity | 38.12 tok/s | 23.46 s |

The smaller chunk reduced TTFT by 21.6% without reducing short-prompt decode.
Chunks of 2,048 and 16,384 were both worse, so 4,096 was the measured local
optimum on this GB10.

With four simultaneous cold prompts of about 49k tokens, total wall time fell
from 149.48 to 135.38 seconds. Aggregate output throughput including all four
prefills improved from 6.85 to 7.56 tok/s. That 7.56 figure is end-to-end under
four cold prefills, not decode-only throughput.

## What about FP8?

I also reproduced this separate report:

https://www.reddit.com/r/LocalLLM/comments/1vtbwtb/dgx_spark_qwen_38_27b_fp8_at_32toks_generation/

Using the author's image and BF16 DFlash2 k7 configuration, the public
four-task harness produced:

- Code: 37.76 tok/s
- Prose: 17.82 tok/s
- Arithmetic: 37.59 tok/s
- Refactor: 31.61 tok/s
- Mean: 31.20 tok/s

So the ~32 tok/s claim is reproducible, but strongly workload-dependent. On my
fixed prose-oriented comparison, FP8 reached 23.07-25.99 tok/s depending on
the drafter setup, versus about 38.1 tok/s for NVFP4. Acceptance was similar;
the remaining difference is consistent with the GB10 reading larger FP8 target
weights over its 273 GB/s shared-memory interface.

The FP8 recipe also suggested `--load-format fastsafetensors`. It reduced FP8
weight loading to about 29 seconds. On the NVFP4 winner it loaded in 19.7
seconds and preserved 37.91 tok/s, but available KV fell from 60.64 to 24.94
GiB. That left only 4.10x theoretical concurrency at the configured 57,344
tokens, too little safety margin for a C4 service, so I did not keep it.

## Reproducing it with Spark

The bundle is named:

```bash
spark run qwen38-dflash2-lookup
```

The bundle pins both model revisions, builds the minimal patched vLLM image,
and stores all runtime arguments and patch-controlled options. Full experiment
tables and caveats are in `docs/qwen38-gb10-experiments.md` in the Spark repo.

I would be interested in comparable results using the same prompts and metric
definitions, especially decode-only C4 after all prefixes are warm.
