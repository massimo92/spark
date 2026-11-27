FROM vllm/vllm-openai@sha256:c2dc759f5984f69c1e2418c6af7c26eb756f5ed2a8934c768ae1253645d1449e

COPY patches/inkling-dflash2-adapter.patch /tmp/inkling-patches/

RUN set -eux; \
    VLLM=$(python3 -c 'import vllm, os; print(os.path.dirname(vllm.__file__))'); \
    patch --batch --forward -p1 -d "$VLLM" \
      < /tmp/inkling-patches/inkling-dflash2-adapter.patch; \
    python3 -m py_compile \
      "$VLLM/v1/worker/gpu/spec_decode/eagle/eagle3_utils.py" \
      "$VLLM/model_executor/models/qwen3_dflash2.py" \
      "$VLLM/v1/worker/gpu/spec_decode/dflash/utils.py"; \
    rm -rf /tmp/inkling-patches
