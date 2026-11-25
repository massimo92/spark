FROM vllm/vllm-openai:v0.30.0@sha256:8a69ffad015f138d7170c4ddc429e230a3bc1c1719f67e14324749df200a4b90 AS build
USER root
RUN apt-get update && apt-get install -y --no-install-recommends git cmake build-essential ca-certificates && rm -rf /var/lib/apt/lists/*
RUN nvcc --version && git init /tmp/llama.cpp && git -C /tmp/llama.cpp remote add origin https://github.com/ggml-org/llama.cpp && git -C /tmp/llama.cpp fetch --depth 1 origin 23f7aabc16c72f6f707dba227251c35d7bd1ed96 && git -C /tmp/llama.cpp checkout FETCH_HEAD
COPY patches/long-input-b11700.patch /tmp/long-input-b11700.patch
RUN cd /tmp/llama.cpp && git apply /tmp/long-input-b11700.patch
RUN cmake -S /tmp/llama.cpp -B /tmp/llama.cpp/build -DGGML_CUDA=ON -DBUILD_SHARED_LIBS=ON -DCMAKE_CUDA_ARCHITECTURES=121 -DLLAMA_CURL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=OFF -DGGML_CUDA_FA_ALL_QUANTS=OFF -DCMAKE_BUILD_TYPE=Release && cmake --build /tmp/llama.cpp/build --target llama -j 2 && mkdir /runtime && find /tmp/llama.cpp/build -name 'lib*.so*' -exec cp -P {} /runtime/ \;

FROM vllm/vllm-openai:v0.30.0@sha256:8a69ffad015f138d7170c4ddc429e230a3bc1c1719f67e14324749df200a4b90
USER root
RUN python3 -m pip install --no-cache-dir 'transformers==5.5.0'
COPY --from=build /runtime /opt/mica/runtime
COPY mica /opt/mica/mica
COPY calibration.json LICENSE NOTICE /opt/mica/
COPY initialize.py serve_spark.py /opt/mica/
ENV PYTHONPATH=/opt/mica HF_HUB_DISABLE_XET=1 HF_HUB_DOWNLOAD_TIMEOUT=120
ENV LD_LIBRARY_PATH=/opt/mica/runtime:${LD_LIBRARY_PATH}
ENTRYPOINT ["python3", "/opt/mica/serve_spark.py"]
