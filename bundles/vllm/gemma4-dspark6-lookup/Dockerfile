FROM vllm/vllm-openai:nightly@sha256:2c7457a1e268828318ff0a3b60a1cfd9119b993a6013599635dd946d4e233784

COPY patches/dspark_lookup.py /usr/local/lib/python3.12/dist-packages/vllm/v1/worker/gpu/spec_decode/dspark/lookup.py

COPY patches/model-runner-req-states.patch /tmp/model-runner-req-states.patch
RUN patch -d /usr/local/lib/python3.12/dist-packages -p1 < /tmp/model-runner-req-states.patch

COPY patches/dspark-lookup.patch /tmp/dspark-lookup.patch
RUN patch -d /usr/local/lib/python3.12/dist-packages -p1 < /tmp/dspark-lookup.patch

ENV VLLM_MARLIN_USE_ATOMIC_ADD=1 \
    VLLM_USE_FLASHINFER_SAMPLER=0
