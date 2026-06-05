#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARK="${ROOT_DIR}/spark"

# These tests target the vLLM/NVIDIA path; default detection to it so the no-GPU CI
# runners don't fall through to the Ollama backend. Backend-specific tests override
# SPARK_BACKEND/SPARK_ACCEL inline, or clear them per-invocation with `env -u`.
export SPARK_BACKEND="${SPARK_BACKEND:-vllm}"
export SPARK_ACCEL="${SPARK_ACCEL:-cuda-unified}"

passed=0
failed=0

make_fake_bin() {
  local dir="$1"
  mkdir -p "$dir"

  cat > "${dir}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
case "${1:-}" in
  --version)
    echo "Docker version 29.4.3, build fake"
    ;;
  info)
    exit "${FAKE_DOCKER_INFO_EXIT:-1}"
    ;;
  images)
    [[ -n "${FAKE_DOCKER_IMAGE:-}" ]] && echo "${FAKE_DOCKER_IMAGE}"
    ;;
  ps)
    # Managed-container listing (TSV rows via FAKE_MANAGED); plain name listing otherwise.
    if [[ "$args" == *"label=spark.managed=1"* ]]; then
      [[ -n "${FAKE_MANAGED:-}" ]] && printf '%b' "${FAKE_MANAGED}"
    elif [[ "$args" == *'{{.Names}}'* ]]; then
      [[ -n "${FAKE_NAMES:-}" ]] && printf '%b' "${FAKE_NAMES}"
    fi
    ;;
  run)
    [[ -n "${FAKE_DOCKER_ARGS_FILE:-}" ]] && printf '%s\n' "$args" >> "${FAKE_DOCKER_ARGS_FILE}"
    exit "${FAKE_DOCKER_RUN_EXIT:-0}"
    ;;
  inspect)
    # Adaptive-startup tests: vary by attempt (= number of `run` lines captured so far).
    _att=0
    [[ -n "${FAKE_DOCKER_ARGS_FILE:-}" && -f "${FAKE_DOCKER_ARGS_FILE}" ]] && _att=$(grep -c '^run ' "${FAKE_DOCKER_ARGS_FILE}" 2>/dev/null || echo 0)
    case "$args" in
      *State.Status*)
        if [[ -n "${FAKE_RETRY:-}" && "${_att}" -le 1 ]]; then echo "exited"
        else echo "${FAKE_STATE_STATUS:-running}"; fi ;;
      *State.OOMKilled*)
        if [[ "${FAKE_RETRY:-}" == "oom" && "${_att}" -le 1 ]]; then echo "true"
        else echo "${FAKE_OOMKILLED:-false}"; fi ;;
      *) [[ -n "${FAKE_DOCKER_INSPECT:-}" ]] && echo "${FAKE_DOCKER_INSPECT}" ;;
    esac
    ;;
  logs)
    _att=0
    [[ -n "${FAKE_DOCKER_ARGS_FILE:-}" && -f "${FAKE_DOCKER_ARGS_FILE}" ]] && _att=$(grep -c '^run ' "${FAKE_DOCKER_ARGS_FILE}" 2>/dev/null || echo 0)
    if [[ "${FAKE_RETRY:-}" == "mamba" && "${_att}" -le 1 ]]; then
      echo "ValueError: max_num_seqs (100) exceeds available Mamba cache blocks (${FAKE_MAMBA_N:-64}). Lower max_num_seqs to at most ${FAKE_MAMBA_N:-64} or increase gpu_memory_utilization."
    else
      [[ -n "${FAKE_DOCKER_LOGS:-}" ]] && echo "${FAKE_DOCKER_LOGS}"
    fi
    ;;
  manifest)
    exit 0
    ;;
  *)
    ;;
esac
EOF
  chmod +x "${dir}/docker"

  # nvidia-smi mock: FAKE_NVIDIA_SMI_EXIT=0 simulates a present GPU. FAKE_VRAM_MIB and
  # FAKE_GPU_NAME drive the discrete-vs-unified classification and the VRAM pool.
  cat > "${dir}/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *-L*)
    [[ "${FAKE_NVIDIA_SMI_EXIT:-1}" == "0" ]] && echo "GPU 0: ${FAKE_GPU_NAME:-NVIDIA Test} (UUID: GPU-0)"
    exit "${FAKE_NVIDIA_SMI_EXIT:-1}" ;;
  *memory.total*)
    [[ -n "${FAKE_VRAM_MIB:-}" ]] && echo "${FAKE_VRAM_MIB}"
    exit "${FAKE_NVIDIA_SMI_EXIT:-1}" ;;
  *--query-gpu=name*)
    [[ -n "${FAKE_GPU_NAME:-}" ]] && echo "${FAKE_GPU_NAME}"
    exit "${FAKE_NVIDIA_SMI_EXIT:-1}" ;;
  *)
    exit "${FAKE_NVIDIA_SMI_EXIT:-1}" ;;
esac
EOF
  chmod +x "${dir}/nvidia-smi"

  # ollama mock: list/ps from FAKE_OLLAMA_LIST/FAKE_OLLAMA_PS; pull records to a file.
  cat > "${dir}/ollama" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) printf '%b' "${FAKE_OLLAMA_LIST:-}" ;;
  ps)   printf '%b' "${FAKE_OLLAMA_PS:-}" ;;
  pull) [[ -n "${FAKE_OLLAMA_PULL_FILE:-}" ]] && echo "$2" >> "${FAKE_OLLAMA_PULL_FILE}"
        exit "${FAKE_OLLAMA_PULL_EXIT:-0}" ;;
  stop) exit "${FAKE_OLLAMA_STOP_EXIT:-0}" ;;
  show) printf '%b' "${FAKE_OLLAMA_SHOW:-}" ;;
  --version|version) echo "ollama version 0.19.0" ;;
  *)    exit 0 ;;
esac
EOF
  chmod +x "${dir}/ollama"

  # curl mock: probes Ollama's :11434 (FAKE_OLLAMA_UP) and vLLM readiness at /v1/models
  # (FAKE_VLLM_READY, default ready so supervised launches don't block in tests).
  cat > "${dir}/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  */v1/models*) [[ "${FAKE_VLLM_READY:-1}" == "1" ]] && exit 0; exit 7 ;;
  *)            [[ "${FAKE_OLLAMA_UP:-0}" == "1" ]] && exit 0; exit 7 ;;
esac
EOF
  chmod +x "${dir}/curl"

  # systemctl mock for spark setup OS-hardening checks.
  cat > "${dir}/systemctl" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *is-active*earlyoom*)        exit "${FAKE_EARLYOOM_ACTIVE:-1}" ;;
  *list-unit-files*)           echo "ssh.service enabled enabled" ;;
  *"show -p MemoryMin"*)       echo "${FAKE_SSHD_MEMORYMIN:-}" ;;
  *"show -p OOMScoreAdjust"*)  echo "${FAKE_SSHD_OOMSCORE:-}" ;;
  *)                           exit 0 ;;
esac
EOF
  chmod +x "${dir}/systemctl"

  # swapon mock: prints active swap devices. FAKE_SWAP_ON=1 → one device (swap on); default off.
  cat > "${dir}/swapon" <<'EOF'
#!/usr/bin/env bash
[[ "${FAKE_SWAP_ON:-0}" == "1" ]] && echo "/swapfile"
exit 0
EOF
  chmod +x "${dir}/swapon"

  cat > "${dir}/tailscale" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${dir}/tailscale"

  # ssh mock for spark setup remote tests. Opening the ControlMaster (-fN) and closing it
  # (-O exit) succeed; otherwise the last arg is the remote command and we answer probes.
  # FAKE_SSH_NVIDIA=1 makes the fake remote look like an NVIDIA/vLLM box.
  cat > "${dir}/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  [[ "$a" == "-fN" || "$a" == "-O" ]] && exit 0
done
cmd="${@: -1}"
case "$cmd" in
  *"uname -s"*)            echo Linux ;;
  *"uname -m"*)            echo aarch64 ;;
  *"nvidia-smi -L"*)       [[ "${FAKE_SSH_NVIDIA:-0}" == "1" ]] && exit 0 || exit 1 ;;
  *"query-gpu"*)           echo "Remote GPU" ;;
  *"command -v ollama"*)   exit 1 ;;
  *"command -v systemctl"*) exit 0 ;;
  *is-active*earlyoom*)    exit 1 ;;
  *"list-unit-files"*)     echo "ssh.service enabled enabled" ;;
  *"show -p MemoryMin"*)   echo "" ;;
  *'grep -m1 "^VERSION="'*) echo "${FAKE_REMOTE_SPARK_VERSION:-0.0.0}" ;;
  *)                       exit 1 ;;
esac
exit 0
EOF
  chmod +x "${dir}/ssh"

  # hf mock: "downloads" by writing files into the HF cache. config.json carries known
  # KV dims; the index reports ~14 GB of weights (total_size).
  cat > "${dir}/hf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "download" ]] || exit 0
repo="$2"; file="${3:-}"
dir="${HOME}/.cache/huggingface/hub/models--${repo//\//--}/snapshots/1"
mkdir -p "$dir"
case "$file" in
  config.json)
    cat > "${dir}/config.json" <<JSON
{ "model_type":"qwen3","architectures":["Qwen3ForCausalLM"],"num_hidden_layers":48,
  "num_key_value_heads":4,"num_attention_heads":32,"head_dim":128,"hidden_size":2048,
  "max_position_embeddings":262144,"quantization_config":{"quant_method":"nvfp4"} }
JSON
    ;;
  model.safetensors.index.json)
    echo '{ "metadata": { "total_size": 15032385536 } }' > "${dir}/model.safetensors.index.json"
    ;;
  "")
    : > "${dir}/model-00001-of-00001.safetensors"
    ;;
esac
EOF
  chmod +x "${dir}/hf"
}

run_test() {
  local name="$1"
  shift

  if "$@"; then
    printf "ok - %s\n" "$name"
    passed=$((passed + 1))
  else
    printf "not ok - %s\n" "$name"
    failed=$((failed + 1))
  fi
}

test_doctor_reports_no_ngc_image() {
  local tmp fake_bin output
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" doctor 2>&1)
  rm -rf "$tmp"

  [[ "$output" == *"NGC container: vLLM image not pulled"* ]] &&
    [[ "$output" == *"checks passed"* ]]
}

test_setup_check_reports_incomplete() {
  local tmp fake_bin output status
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home"

  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" setup --check </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -ne 0 ]] &&
    [[ "$output" == *"Setup incomplete"* ]] &&
    [[ "$output" != *"Setup complete"* ]]
}

test_invalid_port_fails_before_side_effects() {
  local output status
  set +e
  output=$("$SPARK" run Org/Model --port abc --dry-run 2>&1)
  status=$?
  set -e

  [[ "$status" -ne 0 ]] &&
    [[ "$output" == *"Invalid --port value"* ]]
}

test_dry_run_uses_json_profile_safely() {
  if ! command -v jq >/dev/null 2>&1; then
    printf "skip - jq not installed\n"
    return 0
  fi

  local tmp fake_bin model_dir marker output
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  marker="${tmp}/profile-executed"
  model_dir="${tmp}/home/.cache/huggingface/hub/models--Org--Model/snapshots/1"
  make_fake_bin "$fake_bin"
  mkdir -p "$model_dir"

  cat > "${model_dir}/config.json" <<EOF
{
  "model_type": "qwen3",
  "architectures": ["Qwen3ForCausalLM"],
  "max_position_embeddings": "1; touch ${marker}"
}
EOF

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Model --dry-run 2>&1)
  local status=$?
  local marker_missing=0
  [[ ! -e "$marker" ]] && marker_missing=1
  rm -rf "$tmp"

  [[ "$status" -eq 0 ]] &&
    [[ "$output" == *"docker run"* ]] &&
    [[ "$output" == *"--max-model-len 32768"* ]] &&
    [[ "$marker_missing" -eq 1 ]]
}

test_docker_run_failure_shows_error() {
  if ! command -v jq >/dev/null 2>&1; then
    printf "skip - jq not installed\n"
    return 0
  fi

  local tmp fake_bin model_dir output status
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  model_dir="${tmp}/home/.cache/huggingface/hub/models--Org--Model/snapshots/1"
  make_fake_bin "$fake_bin"
  mkdir -p "$model_dir"

  cat > "${model_dir}/config.json" <<'EOF'
{"model_type": "qwen3", "architectures": ["Qwen3ForCausalLM"], "max_position_embeddings": 4096}
EOF

  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_RUN_EXIT=1 \
    "$SPARK" run Org/Model 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -ne 0 ]] &&
    [[ "$output" == *"docker run failed"* ]]
}

test_corrupt_profile_reports_error() {
  if ! command -v jq >/dev/null 2>&1; then
    printf "skip - jq not installed\n"
    return 0
  fi

  local tmp fake_bin output status
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark/profiles"
  mkdir -p "${tmp}/home/.cache/huggingface/hub/models--Org--Model/snapshots/1"

  printf "not valid json{{{" > "${tmp}/home/.config/spark/profiles/Org--Model.json"

  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Model --dry-run 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -ne 0 ]] &&
    [[ "$output" == *"Invalid profile JSON"* ]]
}

# Write a model snapshot with the given config.json contents; echoes HOME dir.
make_model() {
  local home="$1" ref="$2" config="$3"
  local dir="${home}/.cache/huggingface/hub/models--${ref//\//--}/snapshots/1"
  mkdir -p "$dir"
  printf '%s\n' "$config" > "${dir}/config.json"
}

# Shared config with known KV dims: KV at 128K = 2*48*4*128*2*131072/1024^3 = 12.0 GB,
# weights (nvfp4, 30B params) = 30e9*0.5/1024^3 = 14.0 GB.
KV_CONFIG='{ "model_type":"qwen3", "architectures":["Qwen3ForCausalLM"],
  "num_hidden_layers":48, "num_key_value_heads":4, "num_attention_heads":32,
  "head_dim":128, "hidden_size":2048, "max_position_embeddings":262144,
  "quantization_config":{"quant_method":"nvfp4"}, "num_parameters":30000000000 }'

test_total_mem_detection_positive() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output mem
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  # Bare config → need ~0, so it fits as long as detection yields a positive total.
  make_model "${tmp}/home" "Org/Bare" '{ "model_type":"qwen3", "max_position_embeddings":4096 }'

  # Do NOT pin SPARK_TOTAL_MEM_GB — this exercises real detection (/proc or sysctl).
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_OS_RESERVE_GB=0 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Bare --dry-run 2>&1)
  mem=$(printf '%s\n' "$output" | sed -n 's/.*Machine:[[:space:]]*\([0-9][0-9]*\) GB total.*/\1/p')
  rm -rf "$tmp"

  [[ "$mem" =~ ^[0-9]+$ ]] && [[ "$mem" -gt 0 ]]
}

test_need_based_fraction() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Qwen/Qwen3-30B --dry-run 2>&1)
  rm -rf "$tmp"

  [[ "$output" == *"KV cache:  12.0 GB"* ]] &&
    [[ "$output" == *"Weights:   14.0 GB"* ]] &&
    [[ "$output" == *"--gpu-memory-utilization 0.23"* ]] &&
    [[ "$output" == *"--max-model-len 131072"* ]]
}

test_fp8_halves_kv() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Qwen/Qwen3-30B --dry-run --kv-cache-dtype fp8 2>&1)
  rm -rf "$tmp"

  [[ "$output" == *"KV cache:  6.0 GB"* ]] &&
    [[ "$output" == *"--kv-cache-dtype fp8"* ]]
}

test_text_config_nested() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/MM" '{ "model_type":"llava", "architectures":["LlavaForConditionalGeneration"],
    "vision_config": {"hidden_size": 1024},
    "text_config": { "num_hidden_layers":32, "num_key_value_heads":8, "head_dim":128,
      "num_attention_heads":32, "hidden_size":4096, "max_position_embeddings":131072 } }'

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/MM --dry-run 2>&1)
  rm -rf "$tmp"

  # KV must be computed from text_config, not 0.
  [[ "$output" != *"KV cache:  0 GB"* ]] &&
    [[ "$output" == *"KV cache:"* ]] &&
    [[ "$output" != *"lacks KV cache fields"* ]]
}

test_missing_kv_fields_warns_not_aborts() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Bare" '{ "model_type":"qwen3", "architectures":["Qwen3ForCausalLM"], "max_position_embeddings":4096 }'

  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Bare --dry-run 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -eq 0 ]] && [[ "$output" == *"lacks KV cache fields"* ]]
}

test_capacity_verification_aborts() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"

  # A live model reserving 100 GB; budget is 121-10=111, so weights (14) alone don't fit
  # in the 11 GB free -> aborts non-interactively (no context helps).
  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED='spark-vllm-big\torg/big\t8000\t100.0\t80.0\t20.0\n' \
    "$SPARK" run Qwen/Qwen3-30B </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -ne 0 ]] &&
    [[ "$output" == *"Not enough memory"* ]] &&
    [[ "$output" == *"Needs:      28.1 GB"* ]] &&
    [[ "$output" == *"org/big"* ]] &&
    [[ "$output" == *"won't help"* ]]
}

test_port_auto_skips_busy() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED='spark-vllm-mini\torg/mini\t8000\t5.0\t3.0\t2.0\n' \
    "$SPARK" run Qwen/Qwen3-30B --dry-run 2>&1)
  rm -rf "$tmp"

  [[ "$output" == *"--port 8001"* ]]
}

test_gateway_yaml_per_model() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin yaml
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark"
  cat > "${tmp}/home/.config/spark/gateway.json" <<'EOF'
{ "enabled": true, "port": 4000, "providers": {
  "vllm": { "enabled": true, "port": 8000 }, "openrouter": { "enabled": false },
  "ollama": { "enabled": false }, "zen": { "enabled": false }, "together": { "enabled": false } } }
EOF

  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_MANAGED='spark-vllm-a\torg/A\t8000\t40.0\t30.0\t10.0\nspark-vllm-b\torg/B\t8001\t60.0\t55.0\t5.0\n' \
    "$SPARK" gateway start >/dev/null 2>&1 || true
  yaml=$(cat "${tmp}/home/.config/spark/litellm_config.yaml" 2>/dev/null || echo "")
  rm -rf "$tmp"

  [[ "$yaml" == *'model_name: "vllm/org/A"'* ]] &&
    [[ "$yaml" == *'model_name: "vllm/org/B"'* ]] &&
    [[ "$yaml" == *'model_name: "vllm/*"'* ]]
}

test_missing_model_no_pull_errors() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home"

  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Missing --no-pull </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -ne 0 ]] && [[ "$output" == *"not found in HF cache"* ]]
}

test_missing_model_dry_run_errors() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home"

  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Missing --dry-run </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -ne 0 ]] && [[ "$output" == *"not found in HF cache"* ]]
}

test_autopull_fits_downloads_and_starts() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status weights
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home"

  set +e
  output=$(printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_ASSUME_INTERACTIVE=1 SPARK_TOTAL_MEM_GB=121 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Qwen/Qwen3-30B 2>&1)
  status=$?
  weights="${tmp}/home/.cache/huggingface/hub/models--Qwen--Qwen3-30B/snapshots/1/model-00001-of-00001.safetensors"
  local downloaded=0; [[ -f "$weights" ]] && downloaded=1
  set -e
  rm -rf "$tmp"

  [[ "$status" -eq 0 ]] &&
    [[ "$output" == *"not downloaded"* ]] &&
    [[ "$output" == *"Model fits"* ]] &&
    [[ "$output" == *"started"* ]] &&
    [[ "$downloaded" -eq 1 ]]
}

test_autopull_no_fit_download_only() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home"

  # A live 100 GB model leaves no room; answer "y" to download anyway (without starting).
  set +e
  output=$(printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_ASSUME_INTERACTIVE=1 SPARK_TOTAL_MEM_GB=121 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED='spark-vllm-big\torg/big\t8000\t100.0\t80.0\t20.0\n' \
    "$SPARK" run Qwen/Qwen3-30B 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -eq 0 ]] &&
    [[ "$output" == *"Not enough memory"* ]] &&
    [[ "$output" == *"won't help"* ]] &&
    [[ "$output" == *"Downloaded Qwen/Qwen3-30B"* ]] &&
    [[ "$output" != *"started"* ]]
}

TWO_MODELS='spark-vllm-a\torg/Alpha\t8000\t40.0\t30.0\t10.0\nspark-vllm-b\torg/Beta\t8001\t60.0\t55.0\t5.0\n'

test_stop_specific_model() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; mkdir -p "${tmp}/home"
  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_MANAGED="$TWO_MODELS" \
    "$SPARK" stop org/Beta 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] && [[ "$output" == *"Stopped spark-vllm-b"* ]] && [[ "$output" != *"spark-vllm-a"* ]]
}

test_stop_all() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; mkdir -p "${tmp}/home"
  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_MANAGED="$TWO_MODELS" \
    "$SPARK" stop --all 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] && [[ "$output" == *"spark-vllm-a"* ]] && [[ "$output" == *"spark-vllm-b"* ]]
}

test_stop_ambiguous_requires_target() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; mkdir -p "${tmp}/home"
  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_MANAGED="$TWO_MODELS" \
    "$SPARK" stop 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] && [[ "$output" == *"Multiple models running"* ]]
}

test_status_renders_table() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; mkdir -p "${tmp}/home"
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 FAKE_MANAGED="$TWO_MODELS" \
    "$SPARK" status 2>&1)
  rm -rf "$tmp"
  [[ "$output" == *"MODEL"* ]] && [[ "$output" == *"NEED"* ]] && [[ "$output" == *"WEIGHTS"* ]] &&
    [[ "$output" == *"org/Alpha"* ]] && [[ "$output" == *"Memory (GB):"* ]]
}

test_gateway_add_remove_provider() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin add_out rm_out enabled disabled
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark"
  cat > "${tmp}/home/.config/spark/gateway.json" <<'EOF'
{ "enabled": true, "port": 4000, "providers": {
  "vllm": { "enabled": true, "port": 8000 }, "openrouter": { "enabled": false },
  "ollama": { "enabled": false }, "zen": { "enabled": false }, "together": { "enabled": false } } }
EOF
  # ollama needs no API key, so add/remove are non-interactive.
  add_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" gateway add ollama 2>&1)
  enabled=$(jq -r '.providers.ollama.enabled' "${tmp}/home/.config/spark/gateway.json")
  rm_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" gateway remove ollama 2>&1)
  disabled=$(jq -r '.providers.ollama.enabled' "${tmp}/home/.config/spark/gateway.json")
  rm -rf "$tmp"
  [[ "$add_out" == *"Enabled ollama"* ]] && [[ "$enabled" == "true" ]] &&
    [[ "$rm_out" == *"Disabled ollama"* ]] && [[ "$disabled" == "false" ]]
}

# --- Platform / accelerator detection ---
test_detect_metal_on_apple_silicon() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(env -u SPARK_ACCEL -u SPARK_BACKEND HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_OS_OVERRIDE=Darwin SPARK_ARCH_OVERRIDE=arm64 FAKE_NVIDIA_SMI_EXIT=1 \
    "$SPARK" __detect 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"accel=metal"* ]] && [[ "$out" == *"backend=ollama"* ]]
}

test_detect_cuda_unified_on_arm_nvidia() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(env -u SPARK_ACCEL -u SPARK_BACKEND HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 FAKE_NVIDIA_SMI_EXIT=0 \
    "$SPARK" __detect 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"accel=cuda-unified"* ]] && [[ "$out" == *"backend=vllm"* ]]
}

test_detect_cuda_discrete_on_x86_nvidia() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(env -u SPARK_ACCEL -u SPARK_BACKEND HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=x86_64 FAKE_NVIDIA_SMI_EXIT=0 FAKE_VRAM_MIB=24576 \
    "$SPARK" __detect 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"accel=cuda-discrete"* ]] && [[ "$out" == *"backend=vllm"* ]]
}

test_detect_cpu_without_gpu() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(env -u SPARK_ACCEL -u SPARK_BACKEND HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=x86_64 FAKE_NVIDIA_SMI_EXIT=1 \
    "$SPARK" __detect 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"accel=cpu"* ]] && [[ "$out" == *"backend=ollama"* ]]
}

test_discrete_uses_vram_pool() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Small" '{ "model_type":"qwen3", "max_position_embeddings":4096 }'
  # Discrete GPU: pool is VRAM (24576 MiB → 24 GB), reserve is a small headroom.
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ACCEL=cuda-discrete \
    FAKE_NVIDIA_SMI_EXIT=0 FAKE_VRAM_MIB=24576 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Small --dry-run 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"24 GB VRAM"* ]] && [[ "$out" == *"headroom"* ]]
}

# --- Ollama backend ---
test_ollama_dry_run_plans_pull() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    "$SPARK" run qwen3:30b --dry-run 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"ollama pull qwen3:30b"* ]] &&
    [[ "$out" == *"ollama_chat/qwen3:30b"* ]] &&
    [[ "$out" == *"(ollama)"* ]] &&
    [[ "$out" != *"docker run"* ]]
}

test_ollama_run_pulls_and_enables_gateway() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out pulls cfg
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama SPARK_TOTAL_MEM_GB=121 \
    FAKE_OLLAMA_UP=1 FAKE_OLLAMA_PULL_FILE="${tmp}/pulls.txt" \
    "$SPARK" run qwen3:30b 2>&1)
  pulls=$(cat "${tmp}/pulls.txt" 2>/dev/null || echo "")
  cfg=$(jq -r '.providers.ollama.enabled' "${tmp}/home/.config/spark/gateway.json" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$pulls" == *"qwen3:30b"* ]] && [[ "$cfg" == "true" ]] && [[ "$out" == *"ready via Ollama"* ]]
}

# --- spark setup --host (local setup; --check goes straight to local in non-TTY) ---
test_host_check_ollama_ready() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama SPARK_ACCEL=metal \
    SPARK_OS_OVERRIDE=Darwin FAKE_OLLAMA_UP=1 FAKE_DOCKER_INFO_EXIT=0 \
    "$SPARK" setup --check </dev/null 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"backend ollama"* ]] && [[ "$out" == *"Ollama: installed"* ]] &&
    [[ "$out" == *"ready to serve"* ]]
}

test_host_check_vllm_no_gpu() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_ACCEL=cuda-unified \
    SPARK_OS_OVERRIDE=Linux FAKE_NVIDIA_SMI_EXIT=1 \
    "$SPARK" setup --check </dev/null 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"backend vllm"* ]] && [[ "$out" == *"No NVIDIA GPU detected"* ]] &&
    [[ "$out" == *"incomplete"* ]]
}

# --- Host OS hardening (swap-off + earlyoom -m5 + sshd MemoryMin/OOMScoreAdjust) ---
test_host_check_hardening_missing() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_ACCEL=cuda-unified \
    SPARK_OS_OVERRIDE=Linux "$SPARK" setup --check </dev/null 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"early-OOM not active"* ]] && [[ "$out" == *"not fully protected"* ]]
}

test_host_check_hardening_present() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  printf 'EARLYOOM_ARGS="-m 5 -s 100"\n' > "${tmp}/earlyoom.conf"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${fake_bin}/earlyoom"; chmod +x "${fake_bin}/earlyoom"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_ACCEL=cuda-unified \
    SPARK_OS_OVERRIDE=Linux FAKE_EARLYOOM_ACTIVE=0 FAKE_SSHD_MEMORYMIN=536870912 FAKE_SSHD_OOMSCORE=-1000 \
    EARLYOOM_DEFAULT_FILE="${tmp}/earlyoom.conf" \
    "$SPARK" setup --check </dev/null 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"earlyoom active (-m 5%"* ]] && [[ "$out" == *"OOMScoreAdjust=-1000"* ]] &&
    [[ "$out" != *"early-OOM not active"* ]]
}

# --- Unified setup wizard (host vs server picker, parity, bootstrap) ---
test_setup_picker_routes_to_host() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  # Pick [1] this machine; --check short-circuits the install prompts.
  out=$(printf '1\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    SPARK_ACCEL=metal SPARK_OS_OVERRIDE=Darwin FAKE_OLLAMA_UP=1 FAKE_DOCKER_INFO_EXIT=0 \
    "$SPARK" setup --check 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"what do you want to set up"* ]] && [[ "$out" == *"set up this machine"* ]] &&
    [[ "$out" == *"backend ollama"* ]]
}

test_setup_host_no_disable_password() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_ACCEL=cuda-unified \
    SPARK_OS_OVERRIDE=Linux "$SPARK" setup --check </dev/null 2>&1) || true
  rm -rf "$tmp"
  # Host mode (--check) must never claim to disable password SSH.
  [[ "$out" != *"Disabled password SSH login"* ]]
}

test_setup_server_check_parity() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  # Drive the wizard: [2] remote, target, "no key" -> bootstrap. ssh/sshpass are mocked so
  # the install set runs against a fake "remote" that mirrors the local checks.
  out=$(printf '2\nme@10.0.0.5\nn\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_OS_OVERRIDE=Linux FAKE_SSH_NVIDIA=1 \
    "$SPARK" setup --check 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"Phase 2: Remote install"* ]] && [[ "$out" == *"NVIDIA Container Toolkit"* ]]
}

test_setup_unknown_flag_fails() {
  local out status
  set +e
  out=$("$SPARK" setup --bogus </dev/null 2>&1); status=$?
  set -e
  [[ "$status" -ne 0 ]] && [[ "$out" == *"Unknown flag"* ]]
}

# --- Doctor per backend ---
test_doctor_ollama_backend() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama SPARK_ACCEL=metal \
    FAKE_OLLAMA_UP=1 FAKE_OLLAMA_LIST="NAME\tID\tSIZE\tMOD\nqwen3:30b\tabc\t18\tGB\n" \
    "$SPARK" doctor 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"backend ollama"* ]] && [[ "$out" == *"Ollama service: reachable"* ]] &&
    [[ "$out" == *"Models: 1 pulled"* ]] && [[ "$out" != *"NGC"* ]]
}

# --- Ollama advisory (estimate at default ctx + warn/confirm) ---
test_ollama_oversized_warns_aborts() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(printf 'n\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    SPARK_TOTAL_MEM_GB=121 SPARK_ASSUME_INTERACTIVE=1 FAKE_OLLAMA_UP=1 \
    FAKE_OLLAMA_LIST="NAME\tID\tSIZE\tMODIFIED\nbig:latest\tabc123\t200\tGB\n" \
    "$SPARK" run big:latest 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"offload layers to CPU"* ]] && [[ "$out" == *"Aborted"* ]] && [[ "$out" != *"ready via Ollama"* ]]
}

test_ollama_oversized_continue_yes() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    SPARK_TOTAL_MEM_GB=121 SPARK_ASSUME_INTERACTIVE=1 FAKE_OLLAMA_UP=1 \
    FAKE_OLLAMA_LIST="NAME\tID\tSIZE\tMODIFIED\nbig:latest\tabc123\t200\tGB\n" \
    FAKE_OLLAMA_SHOW="block_count 80\nattention.head_count_kv 8\nattention.key_length 128\n" \
    "$SPARK" run big:latest 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"offload layers to CPU"* ]] && [[ "$out" == *"ready via Ollama"* ]]
}

# --- Gateway networking per OS ---
# Write a minimal gateway config with the Ollama provider enabled.
write_ollama_gateway_config() {
  local home="$1"
  mkdir -p "${home}/.config/spark"
  printf '%s\n' '{"enabled":true,"port":4000,"providers":{"ollama":{"enabled":true}}}' \
    > "${home}/.config/spark/gateway.json"
}

test_gateway_ollama_route_mac() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin yaml dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  write_ollama_gateway_config "${tmp}/home"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_OS_OVERRIDE=Darwin \
    FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" gateway start >/dev/null 2>&1 || true
  yaml=$(cat "${tmp}/home/.config/spark/litellm_config.yaml" 2>/dev/null || echo "")
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$yaml" == *"ollama_chat/*"* ]] && [[ "$yaml" == *"host.docker.internal:11434"* ]] &&
    [[ "$dargs" == *"-p 4000:4000"* ]]
}

test_gateway_ollama_route_linux() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin yaml dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  write_ollama_gateway_config "${tmp}/home"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_OS_OVERRIDE=Linux \
    FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" gateway start >/dev/null 2>&1 || true
  yaml=$(cat "${tmp}/home/.config/spark/litellm_config.yaml" 2>/dev/null || echo "")
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$yaml" == *"ollama_chat/*"* ]] && [[ "$yaml" == *"http://localhost:11434"* ]] &&
    [[ "$dargs" == *"--network host"* ]]
}

# --- Compatibility validation ---
test_ollama_blocks_vllm_only_model() {
  local tmp fake_bin out rc
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    "$SPARK" run RedHatAI/Qwen3-NVFP4 --dry-run 2>&1) && rc=0 || rc=$?
  rm -rf "$tmp"
  [[ "${rc:-0}" -ne 0 ]] && [[ "$out" == *"vLLM-only"* ]]
}

test_vllm_blocks_ollama_tag() {
  local tmp fake_bin out rc
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    "$SPARK" run qwen3:30b --dry-run 2>&1) && rc=0 || rc=$?
  rm -rf "$tmp"
  [[ "${rc:-0}" -ne 0 ]] && [[ "$out" == *"Ollama model tag"* ]]
}

# --- Capacity: context menu (auto vs fp8) when a model doesn't fit ---
# 30B: weights 14, KV@128K 12, need 28.1. Reserve 85 -> free 26: doesn't fit at 128K,
# but fits at 64K auto (need 21.6) or 128K fp8 (need 21.6).
# Reserved so the 30B doesn't fit at full context (budget 114 − 88 = 26 GB free), to exercise the
# fit menu — same free as before (when budget was 111 − 85).
RESERVE_85='spark-vllm-big\torg/big\t8000\t88.0\t73.0\t15.0\n'

test_dryrun_shows_fit_options() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_MANAGED="$RESERVE_85" \
    "$SPARK" run Qwen/Qwen3-30B --dry-run </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] &&
    [[ "$out" == *"Not enough memory"* ]] &&
    [[ "$out" == *"Fits at up to 64K"* ]] &&
    [[ "$out" == *"up to 128K with fp8"* ]] &&
    [[ "$out" == *"docker run"* ]]
}

test_menu_choose_fp8_relaunches() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  printf '2\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_ASSUME_INTERACTIVE=1 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED="$RESERVE_85" FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" run Qwen/Qwen3-30B >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"--max-model-len 131072"* ]] && [[ "$dargs" == *"--kv-cache-dtype fp8"* ]]
}

test_menu_choose_auto_relaunches() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  printf '1\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_ASSUME_INTERACTIVE=1 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED="$RESERVE_85" FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" run Qwen/Qwen3-30B >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"--max-model-len 65536"* ]] && [[ "$dargs" != *"--kv-cache-dtype fp8"* ]]
}

test_menu_cancel_aborts() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  out=$(printf '3\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_ASSUME_INTERACTIVE=1 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED="$RESERVE_85" FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" run Qwen/Qwen3-30B 2>&1 || true)
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"Aborted"* ]] && [[ -z "$dargs" ]]
}

test_autopull_menu_downloads_at_choice() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs weights downloaded
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; mkdir -p "${tmp}/home"
  # Not downloaded; sized from metadata. Reserve 85 -> doesn't fit at 128K. Pick option 2 (fp8 128K).
  printf '2\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ASSUME_INTERACTIVE=1 \
    SPARK_TOTAL_MEM_GB=121 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED="$RESERVE_85" FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" run Qwen/Qwen3-30B >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  weights="${tmp}/home/.cache/huggingface/hub/models--Qwen--Qwen3-30B/snapshots/1/model-00001-of-00001.safetensors"
  downloaded=0; [[ -f "$weights" ]] && downloaded=1
  rm -rf "$tmp"
  [[ "$downloaded" -eq 1 ]] && [[ "$dargs" == *"--max-model-len 131072"* ]] && [[ "$dargs" == *"--kv-cache-dtype fp8"* ]]
}

test_mem_override_suggests_mem() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_MANAGED="$RESERVE_85" \
    "$SPARK" run Qwen/Qwen3-30B --mem 0.9 </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] && [[ "$out" == *"Fits with --mem ≤ 0.21"* ]] && [[ "$out" != *"--max-len"* ]]
}

# --- Per-container hard memory limit (--memory) ---
# 30B NEED 28.1 → 28.1×1.25×1024 = ceil(35968) = 35968 MiB.
test_mem_limit_present_unified() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    "$SPARK" run Qwen/Qwen3-30B </dev/null >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  # cgroup cap = NEED + WARMUP_HEADROOM (default 20): (28.1+20)×1024 = ceil(49254.4) = 49255 MiB.
  [[ "$dargs" == *"--memory 49255m"* ]] && [[ "$dargs" == *"--memory-swap 49255m"* ]]
}

test_mem_limit_absent_discrete() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-discrete \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    "$SPARK" run Qwen/Qwen3-30B </dev/null >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"vllm serve"* ]] && [[ "$dargs" != *"--memory"* ]]
}

test_mem_limit_absent_with_flag() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    "$SPARK" run Qwen/Qwen3-30B --no-mem-limit </dev/null >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"vllm serve"* ]] && [[ "$dargs" != *"--memory"* ]]
}

test_mem_limit_headroom_env() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  # SPARK_WARMUP_HEADROOM_GB=30: (28.1+30)×1024 = ceil(59494.4) = 59495 MiB.
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    SPARK_WARMUP_HEADROOM_GB=30 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" "$SPARK" run Qwen/Qwen3-30B </dev/null >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"--memory 59495m"* ]] && [[ "$dargs" != *"49255m"* ]]
}

# --- Adaptive supervised startup ---
# Default concurrency cap is 100 (replacing vLLM's 256) and is announced.
test_max_num_seqs_default() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    "$SPARK" run Qwen/Qwen3-30B </dev/null 2>&1 || true)
  dargs=$(cat "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"--max-num-seqs 100"* ]] && [[ "$out" == *"up to 100 concurrent"* ]]
}

test_max_num_seqs_override() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    "$SPARK" run Qwen/Qwen3-30B --max-num-seqs 200 </dev/null >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"--max-num-seqs 200"* ]] && [[ "$dargs" != *"--max-num-seqs 100"* ]]
}

# Hybrid/Mamba cache-block failure → auto-lower --max-num-seqs and retry, then serve.
test_startup_retry_mamba() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out last
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    FAKE_RETRY=mamba FAKE_MAMBA_N=64 \
    "$SPARK" run Qwen/Qwen3-30B </dev/null 2>&1 || true)
  last=$(tail -1 "${tmp}/d.txt" 2>/dev/null || echo "")
  local nruns; nruns=$(grep -c '^run ' "${tmp}/d.txt" 2>/dev/null || echo 0)
  rm -rf "$tmp"
  [[ "$nruns" -eq 2 ]] && [[ "$last" == *"--max-num-seqs 64"* ]] &&
    [[ "$out" == *"retrying with --max-num-seqs 64"* ]] && [[ "$out" == *"serving"* ]]
}

# Warmup OOM → raise the cgroup margin (25%→50%) within the cap and retry.
test_startup_retry_oom() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out last
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    FAKE_RETRY=oom \
    "$SPARK" run Qwen/Qwen3-30B </dev/null 2>&1 || true)
  last=$(tail -1 "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  # The warmup-OOM lever is now --enforce-eager (removes the CUDA-graph peak), not a margin bump.
  [[ "$last" == *"--enforce-eager"* ]] && [[ "$out" == *"--enforce-eager"* ]] && [[ "$out" == *"serving"* ]]
}

# An unrecognized startup crash aborts without retrying.
test_startup_unrecoverable_aborts() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out nruns
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    FAKE_STATE_STATUS=exited FAKE_DOCKER_LOGS="RuntimeError: unrelated fatal error" \
    "$SPARK" run Qwen/Qwen3-30B </dev/null 2>&1)
  set -e
  nruns=$(grep -c '^run ' "${tmp}/d.txt" 2>/dev/null || echo 0)
  rm -rf "$tmp"
  [[ "$nruns" -eq 1 ]] && [[ "$out" == *"failed to start"* ]]
}

# --no-wait launches and returns without supervising.
test_startup_no_wait() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Qwen/Qwen3-30B --no-wait </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"started"* ]] && [[ "$out" != *"waiting for it to serve"* ]]
}

# A MoE model (vLLM under-profiles these → big startup peak) gets --enforce-eager auto on the first
# launch (no measured peak yet); a dense model does not.
MOE_CONFIG='{ "model_type":"qwen3_moe", "architectures":["Qwen3MoeForCausalLM"],
  "num_hidden_layers":48, "num_key_value_heads":4, "num_attention_heads":32,
  "head_dim":128, "hidden_size":2048, "max_position_embeddings":262144, "num_experts":128,
  "quantization_config":{"quant_method":"nvfp4"}, "num_parameters":30000000000 }'
test_enforce_eager_auto_for_moe() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin moe dense
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Moe" "$MOE_CONFIG"
  make_model "${tmp}/home" "Org/Dense" "$KV_CONFIG"
  moe=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" "$SPARK" run Org/Moe --dry-run </dev/null 2>&1 || true)
  dense=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" "$SPARK" run Org/Dense --dry-run </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$moe" == *"--enforce-eager"* ]] && [[ "$dense" != *"--enforce-eager"* ]]
}

# --- Admission budget (TOTAL − OS reserve) ---
# Admission budget = TOTAL − OS_RESERVE (unified default 7 → 114 GB). 30B need 28 + reserved 90 =
# 118 > 114 → blocked by the budget. Proves the budget binds when stacking models.
test_budget_blocks_when_stacking() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED='spark-vllm-big\torg/big\t8000\t90.0\t75.0\t15.0\n' \
    "$SPARK" run Qwen/Qwen3-30B --dry-run </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] && [[ "$out" == *"Not enough memory"* ]] && [[ "$out" == *"OS-reserved"* ]]
}

# The budget applies to a single model too: --mem 0.97 (117.4 GB) exceeds the budget (114) and is
# blocked, suggesting the largest --mem that fits.
test_budget_blocks_single_model() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Qwen/Qwen3-30B --mem 0.97 --dry-run </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] && [[ "$out" == *"Not enough memory"* ]] && [[ "$out" == *"Fits with --mem"* ]]
}

# Discrete GPUs get a smaller OS reserve (2 → budget 119): the stacking case (108) fits.
test_budget_larger_on_discrete() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-discrete \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED='spark-vllm-big\torg/big\t8000\t80.0\t65.0\t15.0\n' \
    "$SPARK" run Qwen/Qwen3-30B --dry-run </dev/null 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"vllm serve"* ]] && [[ "$out" != *"Not enough memory"* ]]
}

# --- Command coverage: spark's own logic per command (not the external tools) ---
test_pull_vllm_ready() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm "$SPARK" pull Org/Model </dev/null 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"Ready. Run: spark run Org/Model"* ]]
}

test_pull_ollama_routes() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama "$SPARK" pull qwen3:30b </dev/null 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"with Ollama"* ]] && [[ "$out" == *"Ready"* ]]
}

test_list_shows_models() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.cache/huggingface/hub/models--Org--Alpha/snapshots/1"
  mkdir -p "${tmp}/home/.cache/huggingface/hub/models--Org--Beta/snapshots/1"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" list 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"MODEL"* ]] && [[ "$out" == *"Org/Alpha"* ]] && [[ "$out" == *"Org/Beta"* ]]
}

test_list_empty() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" list 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"No models downloaded"* ]]
}

test_rm_removes_the_right_dir() {
  local tmp fake_bin out d
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  d="${tmp}/home/.cache/huggingface/hub/models--Org--Gone"; mkdir -p "${d}/snapshots/1"
  out=$(printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ASSUME_INTERACTIVE=1 "$SPARK" rm Org/Gone 2>&1)
  local gone=1; [[ -d "$d" ]] && gone=0
  rm -rf "$tmp"
  [[ "$out" == *"Removed Org/Gone"* ]] && [[ "$gone" -eq 1 ]]
}

test_rm_not_found() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" rm Org/Missing </dev/null 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"not found in cache"* ]]
}

test_logs_ollama_message() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama "$SPARK" logs 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"shared service"* ]] && [[ "$out" == *"journalctl"* ]]
}

test_logs_vllm_no_container() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm "$SPARK" logs Org/Model </dev/null 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"No container found"* ]]
}

test_config_set_and_show() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin set_out show_out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  set_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" config auto-update on 2>&1)
  show_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" config 2>&1)
  rm -rf "$tmp"
  [[ "$set_out" == *"Auto-update enabled"* ]] && [[ "$show_out" == *"auto-update: true"* ]]
}

test_gateway_stop_when_none() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" gateway stop 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"No running gateway"* ]]
}

test_gateway_status_running() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark"
  printf '%s\n' '{"enabled":true,"port":4000,"providers":{"vllm":{"enabled":true}}}' > "${tmp}/home/.config/spark/gateway.json"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_NAMES='spark-litellm\n' "$SPARK" gateway status 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"gateway running"* ]] && [[ "$out" == *"vLLM"* ]]
}

test_status_ollama_lists() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    FAKE_OLLAMA_LIST="NAME\tID\tSIZE\tMOD\nqwen3:30b\tabc\t18\tGB\n" "$SPARK" status 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"qwen3:30b"* ]] && [[ "$out" == *"Engine: Ollama"* ]]
}

test_stop_ollama_unloads() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    FAKE_OLLAMA_PS="NAME\tID\nqwen3:30b\tabc\n" "$SPARK" stop qwen3:30b 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"Unloaded qwen3:30b"* ]]
}

run_test "doctor reports missing NGC image without aborting" test_doctor_reports_no_ngc_image
run_test "setup --check reports incomplete setup" test_setup_check_reports_incomplete
run_test "invalid --port fails during validation" test_invalid_port_fails_before_side_effects
run_test "dry-run uses JSON profiles without executing model data" test_dry_run_uses_json_profile_safely
run_test "docker run failure shows actionable error" test_docker_run_failure_shows_error
run_test "corrupt profile JSON reports error" test_corrupt_profile_reports_error
run_test "total memory detection returns a positive value" test_total_mem_detection_positive
run_test "memory reserved by need (weights + KV) → fraction" test_need_based_fraction
run_test "kv-cache-dtype fp8 halves KV cache" test_fp8_halves_kv
run_test "KV cache read from nested text_config" test_text_config_nested
run_test "missing KV fields warns without aborting" test_missing_kv_fields_warns_not_aborts
run_test "capacity verification aborts when it does not fit" test_capacity_verification_aborts
run_test "port auto-assignment skips a busy port" test_port_auto_skips_busy
run_test "gateway YAML has per-model entries plus wildcard" test_gateway_yaml_per_model
run_test "missing model with --no-pull errors clearly" test_missing_model_no_pull_errors
run_test "missing model with --dry-run errors clearly" test_missing_model_dry_run_errors
run_test "auto-pull: fits → downloads and starts" test_autopull_fits_downloads_and_starts
run_test "auto-pull: does not fit → downloads without starting" test_autopull_no_fit_download_only
run_test "stop <model> stops only that model" test_stop_specific_model
run_test "stop --all stops every model" test_stop_all
run_test "stop with no arg and many models asks which" test_stop_ambiguous_requires_target
run_test "status renders a table" test_status_renders_table
run_test "gateway add/remove toggles a provider" test_gateway_add_remove_provider
run_test "pull (vllm) reports ready" test_pull_vllm_ready
run_test "pull routes to Ollama on the ollama backend" test_pull_ollama_routes
run_test "list shows downloaded models" test_list_shows_models
run_test "list reports empty cache" test_list_empty
run_test "rm removes the right model dir" test_rm_removes_the_right_dir
run_test "rm errors on a model not in cache" test_rm_not_found
run_test "logs on ollama points to the service logs" test_logs_ollama_message
run_test "logs errors when no container exists" test_logs_vllm_no_container
run_test "config sets and shows auto-update" test_config_set_and_show
run_test "gateway stop reports when none running" test_gateway_stop_when_none
run_test "gateway status shows running + providers" test_gateway_status_running
run_test "status (ollama) lists pulled models" test_status_ollama_lists
run_test "stop (ollama) unloads a model" test_stop_ollama_unloads
run_test "detect: Apple Silicon → metal/ollama" test_detect_metal_on_apple_silicon
run_test "detect: arm64 NVIDIA → cuda-unified/vllm" test_detect_cuda_unified_on_arm_nvidia
run_test "detect: x86_64 NVIDIA → cuda-discrete/vllm" test_detect_cuda_discrete_on_x86_nvidia
run_test "detect: no GPU → cpu/ollama" test_detect_cpu_without_gpu
run_test "discrete GPU reserves from VRAM pool" test_discrete_uses_vram_pool
run_test "ollama run (dry) plans pull + gateway route" test_ollama_dry_run_plans_pull
run_test "ollama run pulls and enables gateway" test_ollama_run_pulls_and_enables_gateway
run_test "ollama oversized model warns and aborts on no" test_ollama_oversized_warns_aborts
run_test "ollama oversized model continues on yes" test_ollama_oversized_continue_yes
run_test "ollama backend blocks vLLM-only model" test_ollama_blocks_vllm_only_model
run_test "vllm backend blocks ollama-style tag" test_vllm_blocks_ollama_tag
run_test "dry-run shows fit options without aborting" test_dryrun_shows_fit_options
run_test "menu: choosing fp8 relaunches at 2x context" test_menu_choose_fp8_relaunches
run_test "menu: choosing auto relaunches at the auto context" test_menu_choose_auto_relaunches
run_test "menu: cancel aborts without starting" test_menu_cancel_aborts
run_test "auto-pull menu downloads + starts at chosen context" test_autopull_menu_downloads_at_choice
run_test "--mem too high suggests a smaller --mem" test_mem_override_suggests_mem
run_test "per-container --memory limit present on unified" test_mem_limit_present_unified
run_test "per-container --memory limit absent on discrete" test_mem_limit_absent_discrete
run_test "per-container --memory limit absent with --no-mem-limit" test_mem_limit_absent_with_flag
run_test "per-container --memory limit honors warmup headroom env" test_mem_limit_headroom_env
run_test "default max-num-seqs cap is 100 (announced)" test_max_num_seqs_default
run_test "--max-num-seqs overrides the default" test_max_num_seqs_override
run_test "startup retries Mamba failure with lower --max-num-seqs" test_startup_retry_mamba
run_test "startup retries warmup OOM with more headroom" test_startup_retry_oom
run_test "unrecoverable startup aborts without retry" test_startup_unrecoverable_aborts
run_test "--no-wait launches without supervising" test_startup_no_wait
run_test "enforce-eager auto for MoE, not for dense" test_enforce_eager_auto_for_moe
run_test "budget blocks stacking past total − OS reserve" test_budget_blocks_when_stacking
run_test "budget blocks a single model over the limit" test_budget_blocks_single_model
run_test "budget is larger on discrete (smaller OS reserve)" test_budget_larger_on_discrete
run_test "gateway routes Ollama via host.docker.internal on macOS" test_gateway_ollama_route_mac
run_test "gateway routes Ollama via localhost on Linux" test_gateway_ollama_route_linux
run_test "doctor runs Ollama checks on the ollama backend" test_doctor_ollama_backend
run_test "setup --host (ollama) reports ready" test_host_check_ollama_ready
run_test "setup --host (vllm) flags a missing GPU" test_host_check_vllm_no_gpu
run_test "setup --host flags missing OS hardening" test_host_check_hardening_missing
run_test "setup --host passes with hardening present" test_host_check_hardening_present
run_test "setup picker [1] routes to this machine" test_setup_picker_routes_to_host
run_test "setup --host never disables password SSH" test_setup_host_no_disable_password
run_test "setup --server installs the same set (parity)" test_setup_server_check_parity
run_test "setup rejects unknown flags" test_setup_unknown_flag_fails

printf "\n%d passed, %d failed\n" "$passed" "$failed"
[[ "$failed" -eq 0 ]]
