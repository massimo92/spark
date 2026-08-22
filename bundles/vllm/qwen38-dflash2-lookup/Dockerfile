FROM ghcr.io/krisitown/vllm-gb10-dflash@sha256:7a96612457bb8ccfb526f2203f2d982c1cf664b2613c67274630ec0c96d056de

COPY patches/qwen3-dflash-w4a16.patch patches/lookup-vllm-dev.patch /tmp/qwen38-patches/

RUN set -eux; \
    VLLM=/usr/local/lib/python3.12/dist-packages/vllm; \
    patch --batch --forward -p1 -d "$VLLM" \
      < /tmp/qwen38-patches/qwen3-dflash-w4a16.patch; \
    patch --batch --forward -p2 -d "$VLLM" \
      < /tmp/qwen38-patches/lookup-vllm-dev.patch; \
    /usr/bin/python3 -m py_compile \
      "$VLLM/model_executor/models/qwen3_dflash.py" \
      "$VLLM/model_executor/models/qwen3_dflash2.py" \
      "$VLLM/v1/worker/gpu/cudagraph_utils.py" \
      "$VLLM/v1/worker/gpu/model_runner.py" \
      "$VLLM/v1/worker/gpu/spec_decode/dflash/speculator.py" \
      "$VLLM/v1/worker/gpu/spec_decode/dflash2/lookup.py" \
      "$VLLM/v1/worker/gpu/spec_decode/dflash2/speculator.py" \
      "$VLLM/v1/worker/gpu/spec_decode/utils.py"; \
    rm -rf /tmp/qwen38-patches

ENV VLLM_DFLASH2_LOOKUP=1 \
    VLLM_DFLASH2_LOOKUP_ADAPTIVE=1 \
    VLLM_DFLASH2_GRAPH_BOTH=1 \
    VLLM_USE_FLASHINFER_SAMPLER=1
