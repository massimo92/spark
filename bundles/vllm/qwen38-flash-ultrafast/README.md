# Qwen3.8 Flash UltraFast on GB10

Built with [spark](https://github.com/massimo92/spark) by Massimo Angelini.

Source: [dime-online UltraFast](https://github.com/dime-online/qwen3.8-Flash-DGX-UltraFast).
Vendored source retains its Apache-2.0 notices; see NOTICE for the pinned upstream commit.
The image reproduces the iter6c/iter6d patch chain and runs its CPU regression gates.

Run `spark run qwen38-flash-ultrafast`. The first launch builds the image,
downloads the two pinned public repositories (about 130 GB), and creates the
verified dense-MTP g32 directory (about 4.8 GiB additional storage). The initializer
runs on CPU with an 8 GiB cap. Subsequent launches reuse the prepared artifacts.
Model and PLE files remain in Spark's persistent Hugging Face storage, which must
be on NVMe. Unchanged model shards are hardlinked, not duplicated.

Defaults: integrated MTP depth 3, 65,536 draft tokens, eight concurrent requests,
262,144 configured context tokens, BF16 KV cache, prefix caching and piecewise
CUDA graphs. GB10-specific kernels and the PLE mmap implementation live in the
image, not the Spark runtime.

This integration initially uses 0.78 GPU memory utilization with automatically
sized KV cache instead of upstream's 0.01 plus explicit 16 GB KV. This is an
intentional variant requiring validation on the serving host. Context capacity
and throughput are measured after startup; the configured context is not a
promise that a given memory budget can serve it. Reduce `--max-len`, concurrency,
or choose a measured `--mem` value when sharing memory with other services.

`spark run qwen38-flash-ultrafast --dry-run` displays pending initialization
without downloading, converting or launching. `--no-pull` requires an already
prepared model. Initialization logs remain under the artifact directory.

The core estimates 71 GiB resident model weights; vLLM determines this hybrid
architecture's actual KV pool. Keep the logical served-model name stable when
using Spark's gateway. Capture a successful launch using `spark alias capture`.
