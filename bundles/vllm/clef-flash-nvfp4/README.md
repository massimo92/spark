# Clef Flash NVFP4

Runs `alpha-x-ai/clef-flash-NVFP4` at the pinned revision in `bundle.json`.
This is a community quantization of Cloudflare's Clef Flash, not a chat model.
The upstream author tested this runtime on DGX Spark / GB10 with vLLM 0.30.0.

```sh
spark pull clef-flash-nvfp4
spark run clef-flash-nvfp4 --dry-run
spark run clef-flash-nvfp4
spark status --json
spark logs alpha-x-ai/clef-flash-NVFP4
spark stop alpha-x-ai/clef-flash-NVFP4
```

The direct service exposes `/health`, `/v1/models` and `POST /v1/systemone`.
Pulling the bundle downloads its immutable model revision, not the moving HF main.
Spark assigns a free port, preserves the existing chat `main`, and publishes
`systemone/alpha-x-ai/clef-flash-NVFP4` through LiteLLM's `/v1/systemone` and
`/v1/decisions` endpoints. An old LiteLLM image is rejected before launch;
update it with `spark update --litellm`.

```json
{
  "model": "systemone/alpha-x-ai/clef-flash-NVFP4",
  "state": {"phase": "validation", "tests": "passed", "pending": []},
  "questions": {
    "complete": {"type": "noul", "instructions": "Are all listed checks complete?"},
    "next": {"type": "choice", "criteria": {"continue": "Checks remain", "finish": "All checks complete"}},
    "progress": {"type": "score", "criteria": ["blocked", "partial", "complete"]}
  }
}
```

Send that body with your existing Bearer token to the gateway's
`/v1/systemone`. For the direct port use the underlying model id without the
`systemone/` prefix. These examples demonstrate routing, not a reliable
completion policy: calibrate the questions on your own agent traces.

Defaults: 8k input, one inference at a time, eager execution, fixed 1.5 GiB
KV pool and a 12% host-memory reservation. Spark checks the live memory
budget before launching. The reservation is a starting point, not a measured
co-residency guarantee. The process also needs the joint head and option
embeddings outside the backbone's vLLM allocation.

The runtime loads the pinned upstream `clef_vllm.py` and joint schema head
from the HF cache, offline. It must not fall back to generation or decompress
the checkpoint to BF16. The API rejects unknown models and malformed requests.
Inference is serialized because the upstream offline vLLM engine is shared.
Health requests remain responsive during inference.
Requests exceeding the configured token window are rejected; the adapter
disables the upstream encoder's silent state truncation.

Text and JSON work through LiteLLM's TypeSafe-compatible transport. The direct
API additionally accepts PNG/JPEG/WebP image data URLs; remote image URLs are
rejected. Image forwarding through the gateway is not configured by this bundle
and is rejected rather than silently dropped. Video is not exposed.

Sources: [quantization and runtime](https://huggingface.co/alpha-x-ai/clef-flash-NVFP4),
[original model](https://huggingface.co/Cloudflare/clef-flash),
[LiteLLM decision routes](https://docs.litellm.ai/docs/decisions).
Model weights and upstream model code: Apache-2.0; Spark's wrapper: MIT.
