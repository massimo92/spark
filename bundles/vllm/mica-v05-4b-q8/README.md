# Mica v0.5 4B Q8 for TailGX

External Spark System One bundle. Official Q8_0 weights from
`sky7350/Mica-v0.5-4B`, pinned to `5ea7aafe324defec353494417ba723195c119b59`.
Official Mica runtime source: `akivet/Mica` commit
`5529ffa1b04441e8a60bcbfb67cfedf70af2eecd`, Apache-2.0 (vendored `mica/`).
llama.cpp b11700 commit `23f7aabc16c72f6f707dba227251c35d7bd1ed96`, MIT,
with Mica's official long-input patch, compiled for CUDA SM121 (GB10).

Import with `spark bundle import <directory>`, then `spark run mica-v05-4b-q8`.
Run and stop only through Spark. Port 8001 is reserved for this decision
model, leaving the chat model's port 8000 available even while it is stopped.
Initialization downloads Q8 and tokenizer
files, not BF16, INT8, or demonstration videos. The underlying runtime uses
llama.cpp's CUDA library, not vLLM generation; Spark manages its lifecycle.

The API is `POST /v1/systemone`; model `sky7350/Mica-v0.5-4B` directly,
or `systemone/sky7350/Mica-v0.5-4B` on LiteLLM. Qwen remains the chat main.
Inputs are text/JSON; up to 16 named noul/choice/score questions per request.
Context is 32768 tokens per question including schema, with no truncation.
One HTTP request runs at a time (429 when busy), one question sequence at a
time, and one additional sequence caches the most recent state.
Memory admission reserves 10% of unified memory. CUDA is mandatory.

Sources: https://huggingface.co/sky7350/Mica-v0.5-4B and
https://github.com/akivet/Mica/tree/5529ffa1b04441e8a60bcbfb67cfedf70af2eecd.
