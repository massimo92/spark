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
    ;;
  run)
    exit "${FAKE_DOCKER_RUN_EXIT:-0}"
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

run_test "doctor reports missing NGC image without aborting" test_doctor_reports_no_ngc_image
run_test "setup --check reports incomplete setup" test_setup_check_reports_incomplete
run_test "invalid --port fails during validation" test_invalid_port_fails_before_side_effects
run_test "dry-run uses JSON profiles without executing model data" test_dry_run_uses_json_profile_safely
run_test "docker run failure shows actionable error" test_docker_run_failure_shows_error
run_test "corrupt profile JSON reports error" test_corrupt_profile_reports_error

printf "\n%d passed, %d failed\n" "$passed" "$failed"
[[ "$failed" -eq 0 ]]
