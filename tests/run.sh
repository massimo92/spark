#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARK="${ROOT_DIR}/spark"

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
    exit "${FAKE_DOCKER_RUN_EXIT:-0}"
    ;;
  inspect)
    [[ -n "${FAKE_DOCKER_INSPECT:-}" ]] && echo "${FAKE_DOCKER_INSPECT}"
    ;;
  logs)
    [[ -n "${FAKE_DOCKER_LOGS:-}" ]] && echo "${FAKE_DOCKER_LOGS}"
    ;;
  manifest)
    exit 0
    ;;
  *)
    ;;
esac
EOF
  chmod +x "${dir}/docker"

  cat > "${dir}/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
exit "${FAKE_NVIDIA_SMI_EXIT:-1}"
EOF
  chmod +x "${dir}/nvidia-smi"

  cat > "${dir}/tailscale" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${dir}/tailscale"

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

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
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
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
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

  # A live model reserving 100 GB; budget is 121-10=111, so 28.1 more does not fit.
  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED='spark-vllm-big\torg/big\t8000\t100.0\t80.0\t20.0\n' \
    "$SPARK" run Qwen/Qwen3-30B --dry-run 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -ne 0 ]] &&
    [[ "$output" == *"Not enough memory"* ]] &&
    [[ "$output" == *"Requested:  28.1 GB"* ]] &&
    [[ "$output" == *"org/big"* ]]
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
    [[ "$output" == *"will not start now"* ]] &&
    [[ "$output" == *"Downloaded Qwen/Qwen3-30B"* ]] &&
    [[ "$output" != *"started"* ]]
}

run_test "doctor reports missing NGC image without aborting" test_doctor_reports_no_ngc_image
run_test "setup --check reports incomplete setup" test_setup_check_reports_incomplete
run_test "invalid --port fails during validation" test_invalid_port_fails_before_side_effects
run_test "dry-run uses JSON profiles without executing model data" test_dry_run_uses_json_profile_safely
run_test "docker run failure shows actionable error" test_docker_run_failure_shows_error
run_test "corrupt profile JSON reports error" test_corrupt_profile_reports_error
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

printf "\n%d passed, %d failed\n" "$passed" "$failed"
[[ "$failed" -eq 0 ]]
