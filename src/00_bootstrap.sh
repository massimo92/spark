#!/usr/bin/env bash
set -euo pipefail

# spark — CLI tool for serving LLMs with vLLM on NVIDIA DGX Spark
# https://github.com/massimo92/spark

# Ensure common user bin paths are in PATH
for p in "$HOME/.local/bin" "$HOME/.cargo/bin"; do
  [[ -d "$p" && ":$PATH:" != *":$p:"* ]] && export PATH="$p:$PATH"
done

VERSION="0.1.90"

# --- Color Output ---
if [[ -t 1 ]]; then
  RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[0;33m'
  BLUE=$'\033[0;34m' BOLD=$'\033[1m' DIM=$'\033[2m' NC=$'\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' NC=''
fi

# --- Constants ---
SPARK_CONFIG_DIR="${HOME}/.config/spark"
PROFILES_DIR="${SPARK_CONFIG_DIR}/profiles"
ALIASES_FILE="${SPARK_CONFIG_DIR}/aliases.json"
ALIASES_BACKUP_FILE="${SPARK_CONFIG_DIR}/aliases.backup.json"
UPDATE_FILE="${SPARK_CONFIG_DIR}/update.json"
GITHUB_REPO="massimo92/spark"
DEFAULT_PORT=8000
HF_CACHE_DIR="${HOME}/.cache/huggingface"
CONTAINER_NAME="spark-vllm"          # name prefix; per-model containers are spark-vllm-<short>-<size>
GATEWAY_CONTAINER="spark-litellm"
WORKSPACE_HERMES_GATEWAY_PROXY_CONTAINER="spark-hermes-litellm-proxy"
WORKSPACE_HERMES_VIKUNJA_PROXY_CONTAINER="spark-hermes-vikunja-proxy"
WORKSPACE_HERMES_SUPER_PRODUCTIVITY_PROXY_CONTAINER="spark-hermes-super-productivity-proxy"
WORKSPACE_HERMES_VIKUNJA_PROVIDER="spark-vikunja"
WORKSPACE_HERMES_TODOIST_PROVIDER="spark-todoist"
WORKSPACE_TODOIST_API_URL="https://api.todoist.com/api/v1"
WORKSPACE_TODOIST_APP_URL="https://app.todoist.com/app"
GATEWAY_CONFIG="${SPARK_CONFIG_DIR}/gateway.json"
GATEWAY_PORT=4000
DASHBOARD_DIR="${SPARK_CONFIG_DIR}/dashboard"
DASHBOARD_PORT=8787
LITELLM_IMAGE="ghcr.io/berriai/litellm:main-latest"
WORKSPACE_CONFIG_DIR="${SPARK_CONFIG_DIR}/workspace"
WORKSPACE_DATA_DIR="${HOME}/.local/share/spark/workspace"
WORKSPACE_COMPOSE_FILE="${WORKSPACE_CONFIG_DIR}/docker-compose.yml"
WORKSPACE_ENV_FILE="${WORKSPACE_CONFIG_DIR}/secrets.env"
WORKSPACE_POSTGRES_ENV_FILE="${WORKSPACE_CONFIG_DIR}/postgres.env"
WORKSPACE_VIKUNJA_ENV_FILE="${WORKSPACE_CONFIG_DIR}/vikunja.env"
WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE="${WORKSPACE_CONFIG_DIR}/super-productivity.env"
WORKSPACE_SUPERSYNC_DIR="${WORKSPACE_CONFIG_DIR}/supersync"
WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_DIR="${WORKSPACE_CONFIG_DIR}/super-productivity-electron"
WORKSPACE_N8N_ENV_FILE="${WORKSPACE_CONFIG_DIR}/n8n.env"
WORKSPACE_PROJECT="workspace"
WORKSPACE_POSTGRES_CONTAINER="workspace-postgres"
WORKSPACE_VIKUNJA_CONTAINER="workspace-vikunja"
WORKSPACE_SUPERSYNC_CONTAINER="workspace-supersync"
WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_CONTAINER="workspace-super-productivity-electron"
WORKSPACE_N8N_CONTAINER="workspace-n8n"
WORKSPACE_HERMES_CONTAINER="workspace-hermes"
WORKSPACE_VIKUNJA_PORT=3456
WORKSPACE_TASK_MANAGER_PORT=3456
WORKSPACE_SUPER_PRODUCTIVITY_API_PORT=3877
WORKSPACE_N8N_PORT=5678
WORKSPACE_HERMES_PORT=18789
WORKSPACE_HERMES_LOCAL_PORT=8642
WORKSPACE_HERMES_TAILSCALE_PROXY_PORT=18790
WORKSPACE_HERMES_TAILSCALE_PROXY_CONTAINER="spark-hermes-dashboard-proxy"
WORKSPACE_HERMES_MIN_CONTEXT=65536
WORKSPACE_HERMES_MAX_TOKENS_DEFAULT=512
WORKSPACE_HERMES_REASONING_EFFORT_DEFAULT="none"
WORKSPACE_HERMES_CLI_TOOLSETS_DEFAULT="terminal file web skills memory todo cronjob delegation"
WORKSPACE_HERMES_CLI_TOOLSETS_DISABLED="browser code_execution vision video image_gen video_gen x_search tts context_engine session_search clarify homeassistant spotify yuanbao computer_use"
WORKSPACE_POSTGRES_IMAGE_DEFAULT="postgres:18"
WORKSPACE_VIKUNJA_IMAGE_DEFAULT="vikunja/vikunja:latest"
WORKSPACE_SUPERSYNC_IMAGE_DEFAULT="spark/supersync:18.15.1"
WORKSPACE_SUPER_PRODUCTIVITY_VERSION_DEFAULT="v18.15.1"
WORKSPACE_SUPER_PRODUCTIVITY_COMMIT_DEFAULT="014b789c22c9bf75fd7202845639569b61e7cd8e"
WORKSPACE_N8N_IMAGE_DEFAULT="docker.n8n.io/n8nio/n8n:latest"

# Detect total system memory in GiB. On the GB10 (unified memory) nvidia-smi reports
# N/A, so read the system memory instead: /proc/meminfo (Linux), sysctl (macOS).
# Overridable with SPARK_TOTAL_MEM_GB for testing or manual correction.
MEM_DETECT_FALLBACK=0
detect_total_mem_gb() {
  local gb=""
  if [[ -n "${SPARK_TOTAL_MEM_GB:-}" && "${SPARK_TOTAL_MEM_GB}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$SPARK_TOTAL_MEM_GB"; return 0
  fi
  # Discrete NVIDIA GPU: the memory pool vLLM reserves from is VRAM, not system RAM.
  if [[ "${ACCEL:-}" == "cuda-discrete" ]]; then
    local vram
    vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || true)
    if [[ "$vram" =~ ^[0-9]+$ && "$vram" -gt 0 ]]; then
      printf '%s\n' $(( vram / 1024 )); return 0
    fi
  fi
  if [[ -r /proc/meminfo ]]; then
    local kb
    kb=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo "")
    [[ "$kb" =~ ^[0-9]+$ ]] && gb=$(( kb / 1048576 ))
  fi
  if [[ -z "$gb" || "$gb" -le 0 ]]; then
    local bytes
    bytes=$(sysctl -n hw.memsize 2>/dev/null || echo "")
    [[ "$bytes" =~ ^[0-9]+$ ]] && gb=$(( bytes / 1073741824 ))
  fi
  if [[ ! "${gb:-0}" =~ ^[0-9]+$ || "${gb:-0}" -le 0 ]]; then
    gb=128
    MEM_DETECT_FALLBACK=1
  fi
  printf '%s\n' "$gb"
}

# --- Platform & accelerator detection ---
# ACCEL is one of:
#   cuda-unified   NVIDIA SoC with unified memory (GB10/GX10, Jetson, Thor, Grace) — arm64
#   cuda-discrete  NVIDIA GPU with its own VRAM — typically x86_64
#   metal          Apple Silicon (Metal GPU, unified memory)
#   cpu            no supported GPU (Intel Mac, Linux without NVIDIA, AMD)
_classify_accel() {
  # No usable NVIDIA GPU → Apple Silicon (metal) or plain CPU.
  if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi -L >/dev/null 2>&1; then
    [[ "$SPARK_OS" == "Darwin" && "$SPARK_ARCH" == "arm64" ]] && { printf 'metal\n'; return 0; }
    printf 'cpu\n'; return 0
  fi
  # NVIDIA present. arm64 NVIDIA == unified-memory SoC (GB10/Thor/Orin/Jetson/Grace).
  case "$SPARK_ARCH" in
    aarch64|arm64) printf 'cuda-unified\n'; return 0 ;;
  esac
  # x86_64 + NVIDIA: usually discrete, but confirm against SoC signals first.
  if [[ -r /proc/device-tree/model ]] && grep -qiE 'jetson|orin|thor|grace|gb10' /proc/device-tree/model 2>/dev/null; then
    printf 'cuda-unified\n'; return 0
  fi
  [[ -r /etc/nv_tegra_release ]] && { printf 'cuda-unified\n'; return 0; }
  local gname
  gname=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
  printf '%s' "$gname" | grep -qiE 'GB10|GB200|GH200|Orin|Thor|Grace' && { printf 'cuda-unified\n'; return 0; }
  # memory.total reported as N/A / [Not Supported] / blank → unified; a real number → discrete.
  local mt
  mt=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || true)
  [[ -z "$mt" || ! "$mt" =~ ^[0-9]+$ ]] && { printf 'cuda-unified\n'; return 0; }
  printf 'cuda-discrete\n'
}

# Detect OS, CPU arch, accelerator class and the inference backend to use.
# Override for tests / edge cases: SPARK_OS_OVERRIDE, SPARK_ARCH_OVERRIDE, SPARK_ACCEL, SPARK_BACKEND.
detect_platform() {
  SPARK_OS="${SPARK_OS_OVERRIDE:-$(uname -s)}"     # Darwin | Linux
  SPARK_ARCH="${SPARK_ARCH_OVERRIDE:-$(uname -m)}" # arm64/aarch64 | x86_64
  ACCEL="${SPARK_ACCEL:-$(_classify_accel)}"
  if [[ -n "${SPARK_BACKEND:-}" ]]; then
    BACKEND="$SPARK_BACKEND"
  else
    case "$ACCEL" in
      cuda-unified|cuda-discrete) BACKEND="vllm" ;;
      *)                          BACKEND="ollama" ;;
    esac
  fi
}
detect_platform

TOTAL_MEM_GB=$(detect_total_mem_gb)
detect_gpu_field() {
  local field="$1"
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  nvidia-smi --query-gpu="$field" --format=csv,noheader 2>/dev/null | head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true
}
GPU_NAME=""
GPU_COMPUTE_CAPABILITY=""
GPU_DRIVER_VERSION=""
if [[ "$ACCEL" == cuda-* ]]; then
  GPU_NAME="$(detect_gpu_field name)"
  GPU_COMPUTE_CAPABILITY="$(detect_gpu_field compute_cap)"
  GPU_DRIVER_VERSION="$(detect_gpu_field driver_version)"
fi
if [[ "$ACCEL" == "cuda-discrete" ]]; then
  OS_RESERVE_GB="${SPARK_OS_RESERVE_GB:-2}"         # small VRAM headroom (OS runs in system RAM)
else
  OS_RESERVE_GB="${SPARK_OS_RESERVE_GB:-7}"         # OS working set (OS+sshd+gateway+docker+buffer)
fi
MEM_HEADROOM_PCT="${SPARK_MEM_HEADROOM_PCT:-8}"     # per-model cushion (activations/fragmentation)
# Admission budget = everything minus what the OS needs to stay responsive. The host stays safe via
# the per-container cgroup cap (below) + earlyoom + control-plane OOM protection (spark setup), not a
# separate arbitrary utilization cap. On a single 24/7 model you can use ~90%+ of RAM.
BUDGET_GB=$(( TOTAL_MEM_GB - OS_RESERVE_GB ))
# Per-container hard ceiling (Docker --memory / cgroup memory.max) = NEED + this, on unified memory
# only. Confines a model's STARTUP PEAK to its own cgroup so it self-OOMs cleanly instead of
# thrashing the host. The peak is torch.compile + CUDA-graph capture (pinned, non-swappable), not
# the weights — measured per model and cached in the profile; else this conservative default.
WARMUP_HEADROOM_GB="${SPARK_WARMUP_HEADROOM_GB:-20}"
# MTP/speculative decoding loads an extra drafter path and vLLM profiles it before
# allocating KV blocks. Keep the launch fraction high enough for that runtime shape.
MTP_GPU_MEM_UTIL_FLOOR="${SPARK_MTP_GPU_MEM_UTIL_FLOOR:-0.65}"
MTP_RUNTIME_HEADROOM_GB="${SPARK_MTP_RUNTIME_HEADROOM_GB:-30}"
# Calibration: a model that first loaded with --enforce-eager (a safe default for MoE) has only ever
# revealed its EAGER peak — not whether CUDA graphs would fit. When 1, spark tries CUDA graphs ONCE on
# a later run to measure the real peak; if it fits it "graduates" the model to CUDA graphs (faster),
# else it falls back to eager (cgroup cap + reactive retry make the attempt safe) and stops trying.
CALIBRATE_CUDAGRAPH="${SPARK_CALIBRATE_CUDAGRAPH:-1}"
# Default cap on concurrent requests. vLLM's own default is 256, which both bloats the warmup
# profiling/activation memory and can exceed the cache blocks a tight hybrid (Mamba) model allocates.
# On unified-memory boxes (GB10) a low cap is the documented sweet spot. Raise per-run with
# --max-num-seqs when you need more concurrency (uses more memory).
MAX_NUM_SEQS_DEFAULT="${SPARK_MAX_NUM_SEQS:-5}"
# Adaptive startup supervision: wait until the model serves; auto-retry recoverable startup failures
# (concurrency too high for the cache → lower --max-num-seqs; warmup OOM → --enforce-eager).
STARTUP_TIMEOUT="${SPARK_STARTUP_TIMEOUT:-600}"          # seconds to wait for the API to come up
STARTUP_MAX_RETRIES="${SPARK_STARTUP_MAX_RETRIES:-2}"    # auto-retries on a recoverable failure
# earlyoom's emergency floor: kill the hog when free RAM drops below this %. The last-resort backstop
# (the cgroup cap + admission keep normal operation far from it). spark setup configures earlyoom here.
EARLYOOM_MIN_FREE_PCT="${SPARK_EARLYOOM_MIN_FREE_PCT:-5}"
# earlyoom only fires when BOTH free RAM < -m AND free swap < -s. Keeping this LOW (not 100) is what
# lets a legitimate model LOAD borrow swap for its transient peak without being killed — earlyoom
# only acts when swap is also nearly exhausted (a real runaway, not a load spike).
EARLYOOM_MIN_SWAP_PCT="${SPARK_EARLYOOM_MIN_SWAP_PCT:-10}"
# Swap is KEPT ON (not disabled): it absorbs the one-time load-time peak of large models (the loader
# transiently needs ~2x the weights) and is a cushion before the OOM killer. Runtime thrash is avoided
# by a LOW swappiness + admission (one model fits in RAM), not by removing swap. If the box has no
# swap, spark provisions a swapfile of this size (GB). Set to 0 to skip provisioning.
SWAP_PROVISION_GB="${SPARK_SWAP_GB:-64}"
# vm.swappiness: low so the runtime working set stays in RAM (good latency), while swap remains
# available for load peaks and as an OOM cushion.
SWAPPINESS="${SPARK_SWAPPINESS:-10}"
# Profile cache schema. Bumped when new fields are added (e.g. is_moe). A cached profile older than
# this is auto-refreshed on the next `spark run` so new fields (and the decisions that depend on them,
# like auto enforce-eager) are populated — no user action needed.
PROFILE_SCHEMA_VERSION=8

# Detect the latest pulled NGC vLLM image
ngc_vllm_image_blocked() {
  local image="$1" blocked
  [[ "${SPARK_NGC_VLLM_ALLOW_BLOCKED:-0}" == "1" ]] && return 1
  for blocked in ${SPARK_NGC_VLLM_DENYLIST:-nvcr.io/nvidia/vllm:26.06-py3}; do
    [[ "$image" == "$blocked" ]] && return 0
  done
  return 1
}

detect_ngc_image() {
  local images
  if [[ -n "${SPARK_VLLM_IMAGE:-}" ]]; then
    printf '%s\n' "$SPARK_VLLM_IMAGE"
    return 0
  fi
  images=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | awk '/^nvcr\.io\/nvidia\/vllm:/ {print}' \
    | while IFS= read -r image; do
        ngc_vllm_image_blocked "$image" || printf '%s\n' "$image"
      done || true)

  [[ -z "$images" ]] && return 0

  if sort -V </dev/null >/dev/null 2>&1; then
    printf "%s\n" "$images" | sort -t: -k2 -rV | head -1
  else
    printf "%s\n" "$images" | sort -r | head -1
  fi
}

# --- Helpers ---
info()  { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
warn()  { printf "  ${YELLOW}⊘${NC} %s\n" "$*" >&2; }
err()   { printf "  ${RED}✗${NC} %s\n" "$*" >&2; }

die() {
  err "$1"
  [[ -n "${2:-}" ]] && printf "    %s\n" "$2" >&2
  exit 1
}

confirm() {
  local prompt="${1:-Continue?}"
  printf "  %s [y/N] " "$prompt"
  read -r ans
  [[ "$ans" =~ ^[Yy] ]]
}

model_cache_dir() {
  local model="$1"
  printf '%s/hub/models--%s\n' "$HF_CACHE_DIR" "${model//\//--}"
}

ensure_hf_cache_writable() {
  mkdir -p "$HF_CACHE_DIR" 2>/dev/null \
    || die "Cannot create HF cache at ${HF_CACHE_DIR}" "Fix the directory permissions, then retry."
  [[ -w "$HF_CACHE_DIR" ]] \
    || die "HF cache is not writable: ${HF_CACHE_DIR}" "Fix ownership/permissions, then retry."
}

hf_cache_first_unwritable() {
  local dir="${1:-$HF_CACHE_DIR}" p
  [[ -e "$dir" ]] || return 1
  if [[ ! -w "$dir" ]]; then
    printf '%s\n' "$dir"
    return 0
  fi
  while IFS= read -r -d '' p; do
    if [[ ! -w "$p" ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done < <(find "$dir" -mindepth 1 -print0 2>/dev/null)
  return 1
}

is_positive_int() {
  [[ "${1:-}" =~ ^[0-9]+$ && "$1" -gt 0 ]]
}

is_port() {
  [[ "${1:-}" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 65535 ]]
}

is_mem_util() {
  [[ "${1:-}" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]
}

is_safe_model_ref() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)+$ ]]
}

# An Ollama model ref: 'name', 'name:tag', 'namespace/name:tag', or 'hf.co/<repo>:QUANT'.
is_ollama_ref() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$ ]]
}

# Block obviously-incompatible model/backend combinations (no catalog — just stop
# the impossible cases with an actionable hint). Called before the backend runs.
validate_model_ref_for_backend() {
  local ref="$1"
  case "$BACKEND" in
    ollama)
      # NVFP4/FP8/quantized vLLM-format HF repos cannot run on Ollama (GGUF/MLX/llama.cpp).
      if [[ "$ref" == */* && ! "$ref" =~ ^hf\.co/ ]] \
         && printf '%s' "$ref" | grep -qiE 'nvfp4|-fp4|-fp8|-awq|-gptq|w4a16|w8a16'; then
        die "'${ref}' looks like a vLLM-only (NVFP4/FP8/quantized) HuggingFace repo" \
            "This machine uses the Ollama backend — pass a GGUF/Ollama model like 'qwen3:30b' or 'hf.co/<repo>:Q4_K_M'"
      fi
      ;;
    vllm)
      # An Ollama-style tag (e.g. qwen3:30b, hf.co/...:Q4) is not a HuggingFace repo.
      if [[ "$ref" == *:* && ! "$ref" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        die "'${ref}' looks like an Ollama model tag" \
            "This machine uses the vLLM backend — pass a HuggingFace repo like 'org/name'"
      fi
      ;;
  esac
}

is_safe_ngc_tag() {
  [[ "${1:-}" =~ ^[A-Za-z0-9._+:-]+$ ]]
}

ngc_vllm_tag_newer_than() {
  local candidate="$1" current="$2" cand_num current_num
  [[ "$candidate" =~ ^([0-9]{2})\.([0-9]{2})-py3$ ]] || return 1
  cand_num=$((10#${BASH_REMATCH[1]} * 100 + 10#${BASH_REMATCH[2]}))
  [[ "$current" =~ ^([0-9]{2})\.([0-9]{2})-py3$ ]] || return 0
  current_num=$((10#${BASH_REMATCH[1]} * 100 + 10#${BASH_REMATCH[2]}))
  [[ "$cand_num" -gt "$current_num" ]]
}

shell_join() {
  local arg
  for arg in "$@"; do
    printf "%q " "$arg"
  done
  printf "\n"
}

setup_skip() {
  SETUP_SKIPPED+=("$1")
}

setup_fail() {
  SETUP_FAILED+=("$1")
  err "$1"
}

local_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    tailscale "$@"
  elif [[ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]]; then
    /Applications/Tailscale.app/Contents/MacOS/Tailscale "$@"
  else
    return 1
  fi
}

# --- Remote SSH ---
REMOTE_USER=""
REMOTE_HOST=""
REMOTE_CONTROL=""

# Run a command on the remote. `-n` redirects ssh's stdin from /dev/null so a command-run never
# drains the script's own stdin — critical when called from inside a pipeline (e.g. the sudo-probe
# inside ctx_sudo_write would otherwise eat the file content being piped to `tee`). Use remote_in()
# for the calls that DO need to stream stdin (password feed, `tee`, `cat > file`).
remote() {
  ssh -n -o ControlPath="$REMOTE_CONTROL" "${REMOTE_USER}@${REMOTE_HOST}" "$@"
}
# Same, but keeps stdin connected for commands that read it (sudo -S password, tee, cat > file).
remote_in() {
  ssh -o ControlPath="$REMOTE_CONTROL" "${REMOTE_USER}@${REMOTE_HOST}" "$@"
}

open_remote() {
  local user="$1" host="$2"
  REMOTE_USER="$user"
  REMOTE_HOST="$host"
  REMOTE_CONTROL="/tmp/spark-setup-${user}@${host}"

  printf "  Connecting to %s@%s...\n" "$user" "$host"
  ssh -o ControlMaster=yes \
      -o ControlPath="$REMOTE_CONTROL" \
      -o ControlPersist=600 \
      -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new \
      -fN "${user}@${host}" 2>/dev/null || return 1
  info "Connected to ${host}"
}

close_remote() {
  if [[ -n "$REMOTE_CONTROL" && -S "$REMOTE_CONTROL" ]]; then
    ssh -o ControlPath="$REMOTE_CONTROL" -O exit "${REMOTE_USER}@${REMOTE_HOST}" 2>/dev/null || true
  fi
}

# --- Execution context (local target | remote target) ---
# spark setup configures EITHER this machine (local) or a remote one over SSH.
# Every install step is written once and dispatched through ctx_* to the active target,
# so a server gets the exact same software whether configured locally or remotely.
SETUP_TARGET="local"     # "local" | "remote"
SETUP_USED_SSHPASS=0     # 1 while the SSH master is password-based (before the key is copied)
SUDO_PW=""               # target sudo password, asked once per run (empty if sudo is passwordless)
SUDO_READY=0             # 1 once sudo auth has been established (or confirmed passwordless)
TGT_OS=""                # target platform — mirrors SPARK_OS/ARCH/ACCEL/BACKEND for the TARGET
TGT_ARCH=""
TGT_ACCEL=""
TGT_BACKEND=""

# PATH prefix for user-installed tools (uv, hf, nvitop, spark). $HOME stays literal so it
# expands on the target, not on the controller.
TGT_PATH='export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH;'

# Run a command STRING on the active target. Caller owns quoting (single contract: target-side
# $HOME/$PATH in single quotes; controller values double-quoted only after validation; secrets
# never interpolated — piped via ctx_run_stdin).
ctx_run() {
  if [[ "$SETUP_TARGET" == "remote" ]]; then remote "$1"; else bash -c "$1"; fi
}

# Acquire sudo auth ONCE per run: detect passwordless sudo, else prompt a single time (over SSH the
# remote sudo can't open a TTY, so we feed the password via `sudo -S` on stdin everywhere).
_sudo_pw_ok() {
  if [[ "$SETUP_TARGET" == "remote" ]]; then
    printf '%s\n' "$SUDO_PW" | remote_in "sudo -S -p '' true" 2>/dev/null
  else
    printf '%s\n' "$SUDO_PW" | sudo -S -p '' true 2>/dev/null
  fi
}
ensure_sudo_pw() {
  [[ "$SUDO_READY" == "1" ]] && return 0
  if ctx_run 'sudo -n true 2>/dev/null'; then SUDO_PW=""; SUDO_READY=1; return 0; fi
  # Read from the controlling terminal, NOT stdin — this is often called inside a pipeline
  # (e.g. `printf config | ctx_sudo_write`), where stdin is the piped content, not the password.
  [[ -r /dev/tty ]] || die "sudo needs a password but no terminal is available" \
    "Configure passwordless sudo for non-interactive runs"
  local tries=0
  while [[ "$tries" -lt 3 ]]; do
    printf "  Enter the sudo password for %s (asked once): " "$(ctx_user)" >/dev/tty
    IFS= read -rs SUDO_PW </dev/tty; printf "\n" >/dev/tty
    if _sudo_pw_ok; then SUDO_READY=1; return 0; fi
    printf "  ${YELLOW}wrong sudo password — try again.${NC}\n" >/dev/tty
    tries=$((tries + 1))
  done
  SUDO_PW=""
  die "Could not authenticate sudo on the target"
}

# Run a command STRING as root on the target. Wrapped in `bash -c` so compound commands run under
# sudo. Uses the once-acquired password via `sudo -S` (no TTY needed) — or `sudo -n` if passwordless.
ctx_sudo() {
  ensure_sudo_pw
  local q; printf -v q '%q' "$1"
  if [[ -z "$SUDO_PW" ]]; then
    if [[ "$SETUP_TARGET" == "remote" ]]; then remote "sudo -n bash -c $q"; else sudo -n bash -c "$1"; fi
  elif [[ "$SETUP_TARGET" == "remote" ]]; then
    printf '%s\n' "$SUDO_PW" | remote_in "sudo -S -p '' bash -c $q"
  else
    printf '%s\n' "$SUDO_PW" | sudo -S -p '' bash -c "$1"
  fi
}

# Pipe controller stdin (e.g. a secret from `read -rs`) into a target command.
ctx_run_stdin() {
  if [[ "$SETUP_TARGET" == "remote" ]]; then remote_in "$1"; else bash -c "$1"; fi
}

# Write controller stdin to a file on the target.
ctx_write_file() {
  if [[ "$SETUP_TARGET" == "remote" ]]; then remote_in "cat > $1"; else cat > "$1"; fi
}

# The target's own username (for docker-group membership etc.).
ctx_user() {
  if [[ "$SETUP_TARGET" == "remote" ]]; then printf '%s' "$REMOTE_USER"; else whoami; fi
}

# True if a command exists on the target (system PATH).
ctx_has() {
  ctx_run "command -v $1 >/dev/null 2>&1"
}

# Populate TGT_* for the active target. Local copies the globals; remote probes over SSH.
detect_target_platform() {
  if [[ "$SETUP_TARGET" == "local" ]]; then
    TGT_OS="$SPARK_OS"; TGT_ARCH="$SPARK_ARCH"
    TGT_ACCEL="$ACCEL"; TGT_BACKEND="$BACKEND"
    return 0
  fi
  TGT_OS="$(remote 'uname -s' 2>/dev/null | tr -d '[:space:]')"
  TGT_ARCH="$(remote 'uname -m' 2>/dev/null | tr -d '[:space:]')"
  [[ -z "$TGT_OS" ]] && TGT_OS="Linux"
  [[ -z "$TGT_ARCH" ]] && TGT_ARCH="aarch64"
  if remote 'nvidia-smi -L' >/dev/null 2>&1; then
    TGT_ACCEL="cuda"; TGT_BACKEND="vllm"
  elif remote "${TGT_PATH} command -v ollama" >/dev/null 2>&1; then
    TGT_ACCEL="cpu"; TGT_BACKEND="ollama"
  else
    TGT_ACCEL="cuda"; TGT_BACKEND="vllm"   # DGX Spark default
  fi
}

# --- Model Path Resolution ---
resolve_model_path() {
  local model="$1"
  # HF cache uses models--Org--Name (double-dash separator)
  local cache_path="${HF_CACHE_DIR}/hub/models--${model//\//-}"

  local hf_path hf_path2
  hf_path="${HF_CACHE_DIR}/hub/models--$(echo "$model" | sed 's/\//-/g')"
  hf_path2="${HF_CACHE_DIR}/hub/models--$(echo "$model" | sed 's/\//--/g')"

  for p in "$hf_path2" "$hf_path" "$cache_path"; do
    if [[ -d "$p/snapshots" ]]; then
      local snapshot
      # shellcheck disable=SC2012
      snapshot=$(ls -t "$p/snapshots" 2>/dev/null | head -1)
      if [[ -n "$snapshot" ]]; then
        echo "$p/snapshots/$snapshot"
        return 0
      fi
    fi
  done

  return 1
}

spark_root_dir() {
  local self dir
  self="${BASH_SOURCE[0]}"
  [[ "$self" != */* ]] && self="$(command -v "$self" 2>/dev/null || printf '%s\n' "$self")"
  dir="$(cd "$(dirname "$self")" >/dev/null 2>&1 && pwd || pwd)"
  printf '%s\n' "$dir"
}

hf_model_inspect_path() {
  local root
  [[ -n "${SPARK_HF_MODEL_INSPECT:-}" && -x "${SPARK_HF_MODEL_INSPECT}" ]] && { printf '%s\n' "$SPARK_HF_MODEL_INSPECT"; return 0; }
  root="$(spark_root_dir)"
  if [[ -x "${root}/scripts/hf_model_inspect.py" ]]; then
    printf '%s\n' "${root}/scripts/hf_model_inspect.py"; return 0
  fi
  if [[ -x "${HOME}/.local/share/spark/scripts/hf_model_inspect.py" ]]; then
    printf '%s\n' "${HOME}/.local/share/spark/scripts/hf_model_inspect.py"; return 0
  fi
  return 1
}

inspect_hf_model() {
  local model="$1" model_path="$2" helper err_file status py
  helper="$(hf_model_inspect_path)" || die "Hugging Face inspector not found" "Run: spark setup, or set SPARK_HF_MODEL_INSPECT"
  py="${HOME}/.local/share/spark/hf-inspect-venv/bin/python"
  [[ -x "$py" ]] || py="python3"
  command -v "$py" >/dev/null 2>&1 || die "python3 is required for Hugging Face model inspection" "Run: spark setup"
  err_file="$(mktemp)"
  set +e
  HF_MODEL_INFO_JSON=$("$py" "$helper" --model-id "$model" --local-path "$model_path" 2>"$err_file")
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    local msg
    msg="$(cat "$err_file" 2>/dev/null || true)"
    rm -f "$err_file"
    die "Could not inspect Hugging Face metadata for ${model}" "${msg:-Check the model id and Hugging Face access}"
  fi
  rm -f "$err_file"
  printf '%s' "$HF_MODEL_INFO_JSON" | jq -e . >/dev/null 2>&1 || die "Hugging Face inspector returned invalid JSON"
}

hf_profile_value() {
  local expr="$1"
  printf '%s' "${HF_MODEL_INFO_JSON:-{}}" | jq -r "$expr" 2>/dev/null || true
}

# --- Auto-Profiler ---
validate_profile_values() {
  [[ -z "$REASONING_PARSER" || "$REASONING_PARSER" =~ ^[a-z0-9_]+$ ]] || die "Invalid profile value: reasoning_parser"
  [[ -z "$TOOL_CALL_PARSER" || "$TOOL_CALL_PARSER" =~ ^[a-z0-9_]+$ ]] || die "Invalid profile value: tool_call_parser"
  is_mem_util "$GPU_MEM_UTIL" || die "Invalid profile value: gpu_memory_utilization"
  is_positive_int "$MAX_MODEL_LEN" || die "Invalid profile value: max_model_len"
  [[ "$IS_MULTIMODAL" =~ ^(true|false)$ ]] || die "Invalid profile value: is_multimodal"
  [[ "$IS_MOE" =~ ^(0|1)$ ]] || die "Invalid profile value: is_moe"
  [[ -z "${MODEL_FAMILY:-}" || "$MODEL_FAMILY" =~ ^[a-z0-9_.-]+$ ]] || die "Invalid profile value: model_family"
  [[ -z "${MODEL_ARCHITECTURE:-}" || "$MODEL_ARCHITECTURE" =~ ^[a-z0-9_.-]+$ ]] || die "Invalid profile value: model_architecture"
  [[ -z "${MODEL_QUANTIZATION:-}" || "$MODEL_QUANTIZATION" =~ ^[a-z0-9_.+-]+$ ]] || die "Invalid profile value: model_quantization"
  [[ -z "${HF_RECOMMENDED_CONTEXT:-}" || "$HF_RECOMMENDED_CONTEXT" =~ ^[0-9]+$ ]] || die "Invalid profile value: hf_recommended_context"
  [[ "${HF_KV_CACHE_FP8_RECOMMENDED:-false}" =~ ^(true|false)$ ]] || die "Invalid profile value: hf_kv_cache_fp8_recommended"
  [[ "${HAS_MTP:-false}" =~ ^(true|false)$ ]] || die "Invalid profile value: has_mtp"
  [[ "${HAS_REASONING:-false}" =~ ^(true|false)$ ]] || die "Invalid profile value: has_reasoning"
  [[ "${SUPPORTS_TOOLS:-false}" =~ ^(true|false)$ ]] || die "Invalid profile value: supports_tools"
  [[ "$MODEL_SIZE_GB" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Invalid profile value: model_size_gb"
  [[ "$WEIGHTS_GB" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Invalid profile value: weights_gb"
  [[ "$KV_GB" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Invalid profile value: kv_gb"
  [[ "$NEED_GB" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Invalid profile value: need_gb"
  [[ -z "$KV_CACHE_DTYPE" || "$KV_CACHE_DTYPE" =~ ^(auto|fp8)$ ]] || die "Invalid profile value: kv_cache_dtype"
}

load_profile() {
  local profile_file="$1"

  jq -e . "$profile_file" >/dev/null 2>&1 || die "Invalid profile JSON: $profile_file" "Regenerate with: spark run --regen-profile <model>"

  REASONING_PARSER=$(jq -r '.reasoning_parser // ""' "$profile_file") || die "Could not read profile: $profile_file"
  TOOL_CALL_PARSER=$(jq -r '.tool_call_parser // ""' "$profile_file") || die "Could not read profile: $profile_file"
  GPU_MEM_UTIL=$(jq -r '.gpu_memory_utilization // ""' "$profile_file") || die "Could not read profile: $profile_file"
  MAX_MODEL_LEN=$(jq -r '.max_model_len // ""' "$profile_file") || die "Could not read profile: $profile_file"
  MODEL_MAX_LEN=$(jq -r '
    [
      (.hf.card.config_context // empty),
      (.hf.card.recommended_context // empty),
      (.max_model_len // empty)
    ] | map(select(type == "number" and . > 0)) | max // (.max_model_len // "")
  ' "$profile_file") || die "Could not read profile: $profile_file"
  IS_MULTIMODAL=$(jq -r '.is_multimodal // "false"' "$profile_file") || die "Could not read profile: $profile_file"
  IS_MOE=$(jq -r '.is_moe // "0"' "$profile_file") || die "Could not read profile: $profile_file"
  HF_MODEL_INFO_JSON=$(jq -c '.hf // {}' "$profile_file") || die "Could not read profile: $profile_file"
  HF_REVISION=$(jq -r '.hf.revision // ""' "$profile_file") || die "Could not read profile: $profile_file"
  HF_TAGS=$(jq -r '(.hf.tags // []) | join(",")' "$profile_file") || die "Could not read profile: $profile_file"
  MODEL_FAMILY=$(jq -r '.hf.features.family // ""' "$profile_file") || die "Could not read profile: $profile_file"
  MODEL_ARCHITECTURE=$(jq -r '.hf.features.architecture // ""' "$profile_file") || die "Could not read profile: $profile_file"
  MODEL_QUANTIZATION=$(jq -r '.hf.features.quantization // ""' "$profile_file") || die "Could not read profile: $profile_file"
  HF_RECOMMENDED_RUNTIME=$(jq -r '.hf.card.recommended_runtime // ""' "$profile_file") || die "Could not read profile: $profile_file"
  HF_RECOMMENDED_IMAGE=$(jq -r '.hf.card.recommended_image // ""' "$profile_file") || die "Could not read profile: $profile_file"
  HF_RECOMMENDED_COMMAND=$(jq -r '.hf.card.recommended_command // ""' "$profile_file") || die "Could not read profile: $profile_file"
  HF_RECOMMENDED_CONTEXT=$(jq -r '.hf.card.recommended_context // ""' "$profile_file") || die "Could not read profile: $profile_file"
  HF_KV_CACHE_FP8_RECOMMENDED=$(jq -r '.hf.card.kv_cache_fp8_recommended // false' "$profile_file") || die "Could not read profile: $profile_file"
  HAS_MTP=$(jq -r '.hf.features.has_mtp // false' "$profile_file") || die "Could not read profile: $profile_file"
  HAS_REASONING=$(jq -r '.hf.features.has_reasoning // false' "$profile_file") || die "Could not read profile: $profile_file"
  SUPPORTS_TOOLS=$(jq -r '.hf.features.supports_tools // false' "$profile_file") || die "Could not read profile: $profile_file"
  MODEL_SIZE_GB=$(jq -r '.model_size_gb // "0"' "$profile_file") || die "Could not read profile: $profile_file"
  WEIGHTS_GB=$(jq -r '.weights_gb // "0"' "$profile_file") || die "Could not read profile: $profile_file"
  KV_GB=$(jq -r '.kv_gb // "0"' "$profile_file") || die "Could not read profile: $profile_file"
  NEED_GB=$(jq -r '.need_gb // "0"' "$profile_file") || die "Could not read profile: $profile_file"
  KV_CACHE_DTYPE=$(jq -r '.kv_cache_dtype // "auto"' "$profile_file") || die "Could not read profile: $profile_file"

  validate_profile_values
}

# Estimate model weights in GB. Prefer the on-disk size (sum of safetensors);
# fall back to the safetensors index (total_size), then to params × bytes/param.
compute_weights_gb() {
  local config_json="$1" disk_gb="${2:-0}"

  if [[ "$disk_gb" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v d="$disk_gb" 'BEGIN{exit !(d>0)}'; then
    WEIGHTS_GB="$disk_gb"
    return 0
  fi

  # Weights not on disk yet: read the exact total from the safetensors index
  # (model.safetensors.index.json), which ships alongside config.json.
  local index_json total
  index_json="$(dirname "$config_json")/model.safetensors.index.json"
  if [[ -f "$index_json" ]]; then
    total=$(jq -r '.metadata.total_size // 0' "$index_json" 2>/dev/null || echo "0")
    if [[ "$total" =~ ^[0-9]+$ ]] && [[ "$total" -gt 0 ]]; then
      WEIGHTS_GB=$(awk -v t="$total" 'BEGIN{ printf "%.1f", t/1073741824 }')
      return 0
    fi
  fi

  # Fallback: params × bytes/param. Detect bytes/param from quantization.
  local quant params bytes
  quant=$(jq -r '(.quantization_config.quant_method // .quantization_config.quant_algo // .torch_dtype // "") | ascii_downcase' "$config_json" 2>/dev/null || echo "")
  params=$(jq -r '.num_parameters // .n_params // 0' "$config_json" 2>/dev/null || echo "0")

  case "$quant" in
    *nvfp4*|*fp4*|*int4*|*w4*) bytes="0.5" ;;
    *fp8*|*int8*|*w8*)         bytes="1" ;;
    *)                          bytes="2" ;;   # bf16/fp16 default
  esac

  if [[ "$params" =~ ^[0-9]+$ ]] && [[ "$params" -gt 0 ]]; then
    WEIGHTS_GB=$(awk -v p="$params" -v b="$bytes" 'BEGIN{ printf "%.1f", (p*b)/1073741824 }')
  else
    WEIGHTS_GB="0"
  fi
}

# Estimate KV cache memory in GB for the given context length.
# Formula: 2 (K+V) × layers × kv_heads × head_dim × bytes × max_model_len.
# bytes = 2 (auto/bf16) or 1 (fp8). Reads nested text_config for multimodal models.
KV_UNCERTAIN=0
compute_kv_gb() {
  local config_json="$1" max_len="$2" kv_dtype="${3:-auto}"
  KV_UNCERTAIN=0

  local base='(.text_config // .)'
  local layers kv_heads head_dim bytes
  layers=$(jq -r "${base}.num_hidden_layers // 0" "$config_json" 2>/dev/null || echo "0")
  kv_heads=$(jq -r "${base} | (.num_key_value_heads // .num_attention_heads // 0)" "$config_json" 2>/dev/null || echo "0")
  head_dim=$(jq -r "${base} | (.head_dim // (if (.hidden_size // 0) > 0 and (.num_attention_heads // 0) > 0 then ((.hidden_size) / (.num_attention_heads)) else 0 end)) | floor" "$config_json" 2>/dev/null || echo "0")

  # Validate every field is a positive integer before feeding awk (never trust metadata).
  if ! is_positive_int "$layers" || ! is_positive_int "$kv_heads" || ! is_positive_int "$head_dim"; then
    KV_GB="0"
    KV_UNCERTAIN=1
    return 0
  fi

  bytes=2
  [[ "$kv_dtype" == "fp8" ]] && bytes=1

  KV_GB=$(awk -v L="$layers" -v H="$kv_heads" -v D="$head_dim" -v B="$bytes" -v T="$max_len" \
    'BEGIN{ printf "%.1f", (2*L*H*D*B*T)/1073741824 }')
}

# Combine weights + KV + cushion into the absolute need (GB) and the vLLM fraction.
# The fraction is need / total_system_memory — it reflects what the model asks for,
# NOT the free space. Sets NEED_GB and GPU_MEM_UTIL.
compute_need_and_fraction() {
  local mm_extra=0
  [[ "${IS_MULTIMODAL:-false}" == "true" ]] && mm_extra="${SPARK_MM_ENCODER_OVERHEAD_GB:-8}"
  awk -v x="$mm_extra" 'BEGIN{exit !(x+0>=0)}' || mm_extra=8
  NEED_GB=$(awk -v w="$WEIGHTS_GB" -v k="$KV_GB" -v x="$mm_extra" -v h="$MEM_HEADROOM_PCT" \
    'BEGIN{ printf "%.1f", (w+k+x)*(1+h/100) }')
  GPU_MEM_UTIL=$(awk -v n="$NEED_GB" -v T="$TOTAL_MEM_GB" \
    'BEGIN{ if (T<=0) T=128; u=n/T; if(u>0.95)u=0.95; if(u<0.05)u=0.05; printf "%.2f", u }')
}

profile_model() {
  local model="$1"
  local model_path="$2"
  local profile_file
  profile_file="${PROFILES_DIR}/$(echo "$model" | sed 's/\//--/g').json"

  command -v jq >/dev/null 2>&1 || die "jq is required for model profiling" "Run: spark setup"

  # Return cached profile if it exists, is current-schema, and we're not forcing a regen. A profile
  # written by an older spark (missing fields like is_moe) would silently disable the decisions that
  # depend on them (e.g. auto enforce-eager), so an out-of-date schema is refreshed automatically —
  # unless the model's config.json is gone (then the stale cache is the best we have).
  if [[ -f "$profile_file" && "${REGEN_PROFILE:-0}" != "1" ]]; then
    local sv
    sv="$(jq -r '.schema_version // 0' "$profile_file" 2>/dev/null || echo 0)"
    [[ "$sv" =~ ^[0-9]+$ ]] || sv=0
    if [[ "$sv" -ge "$PROFILE_SCHEMA_VERSION" || ! -f "${model_path}/config.json" ]]; then
      load_profile "$profile_file"
      return 0
    fi
    info "Refreshing model profile (schema v${sv} → v${PROFILE_SCHEMA_VERSION})"
  fi

  local config_json="${model_path}/config.json"
  if [[ ! -f "$config_json" ]]; then
    err "No config.json found at ${model_path}"
    return 1
  fi

  inspect_hf_model "$model" "$model_path"

  local model_type model_max
  model_type=$(hf_profile_value '.raw.model_type // ""')
  HF_REVISION=$(hf_profile_value '.revision // ""')
  HF_TAGS=$(hf_profile_value '(.tags // []) | join(",")')
  MODEL_FAMILY=$(hf_profile_value '.features.family // ""')
  MODEL_ARCHITECTURE=$(hf_profile_value '.features.architecture // ""')
  MODEL_QUANTIZATION=$(hf_profile_value '.features.quantization // ""')
  HF_RECOMMENDED_RUNTIME=$(hf_profile_value '.card.recommended_runtime // ""')
  HF_RECOMMENDED_IMAGE=$(hf_profile_value '.card.recommended_image // ""')
  HF_RECOMMENDED_COMMAND=$(hf_profile_value '.card.recommended_command // ""')
  HF_RECOMMENDED_CONTEXT=$(hf_profile_value '.card.recommended_context // ""')
  HF_KV_CACHE_FP8_RECOMMENDED=$(hf_profile_value '.card.kv_cache_fp8_recommended // false')
  HAS_MTP=$(hf_profile_value '.features.has_mtp // false')
  HAS_REASONING=$(hf_profile_value '.features.has_reasoning // false')
  SUPPORTS_TOOLS=$(hf_profile_value '.features.supports_tools // false')

  REASONING_PARSER=""
  case "$MODEL_FAMILY:$model_type" in
    gemma:*|*:gemma4) REASONING_PARSER="gemma4" ;;
    qwen:*|*:qwen3*) REASONING_PARSER="qwen3" ;;
    deepseek:*|*:deepseek_v3) REASONING_PARSER="deepseek_r1" ;;
  esac

  TOOL_CALL_PARSER=""
  case "$MODEL_FAMILY:$model_type" in
    gemma:*|*:gemma4) TOOL_CALL_PARSER="gemma4" ;;
    *:qwen3_5) TOOL_CALL_PARSER="qwen3_coder" ;;
    qwen:*|*:qwen3*) TOOL_CALL_PARSER="qwen3_xml" ;;
  esac

  if [[ -n "$model_type" && -z "$REASONING_PARSER" && -z "$TOOL_CALL_PARSER" ]]; then
    warn "Unknown model_type '${model_type}' — reasoning and tool-call parsers not configured"
  fi

  model_max=$(hf_profile_value '[.card.config_context, .card.recommended_context] | map(select(type == "number" and . > 0)) | max // 32768')
  is_positive_int "$model_max" || model_max=32768
  MODEL_MAX_LEN="$model_max"
  MAX_MODEL_LEN="$MODEL_MAX_LEN"

  IS_MULTIMODAL=$(hf_profile_value '.features.is_multimodal // false')
  [[ "$IS_MULTIMODAL" =~ ^(true|false)$ ]] || IS_MULTIMODAL="false"

  IS_MOE="0"
  [[ "$(hf_profile_value '.features.is_moe // false')" == "true" ]] && IS_MOE="1"

  # Profiles describe the model baseline. Per-run KV overrides are applied by cmd_run
  # after profiling and must not become the future automatic default.
  KV_CACHE_DTYPE="auto"

  # Model size (sum of safetensors)
  # -L follows symlinks (HF cache uses symlinks in snapshots/)
  MODEL_SIZE_GB=$(find -L "$model_path" -name "*.safetensors" -exec stat -Lc%s {} + 2>/dev/null \
    | awk '{s+=$1} END {printf "%.1f", s/1073741824}' 2>/dev/null || echo "0")

  # macOS fallback: stat -f%z
  if [[ "$MODEL_SIZE_GB" == "0" || -z "$MODEL_SIZE_GB" ]]; then
    MODEL_SIZE_GB=$(find -L "$model_path" -name "*.safetensors" -exec stat -f%z {} + 2>/dev/null \
      | awk '{s+=$1} END {printf "%.1f", s/1073741824}' 2>/dev/null || echo "0")
  fi

  # Need-based memory: weights + KV cache + cushion → fraction of TOTAL system memory.
  # The free space does NOT enter here; it is only checked later (verify_capacity).
  KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-auto}"
  compute_weights_gb "$config_json" "$MODEL_SIZE_GB"
  if awk -v w="$WEIGHTS_GB" 'BEGIN{exit !(w<=0)}'; then
    warn "Could not determine model weights — memory calculation may be inaccurate"
  fi
  compute_kv_gb "$config_json" "$MAX_MODEL_LEN" "$KV_CACHE_DTYPE"
  [[ "$KV_UNCERTAIN" == "1" ]] && warn "config.json lacks KV cache fields — sizing from weights only"
  compute_need_and_fraction

  # Save profile
  mkdir -p "$PROFILES_DIR"
  validate_profile_values
  jq -n \
    --arg model "$model" \
    --arg generated "$(date +%Y-%m-%d)" \
    --arg reasoning_parser "$REASONING_PARSER" \
    --arg tool_call_parser "$TOOL_CALL_PARSER" \
    --arg gpu_memory_utilization "$GPU_MEM_UTIL" \
    --argjson max_model_len "$MAX_MODEL_LEN" \
    --argjson is_multimodal "$IS_MULTIMODAL" \
    --arg model_size_gb "$MODEL_SIZE_GB" \
    --arg weights_gb "$WEIGHTS_GB" \
    --arg kv_gb "$KV_GB" \
    --arg need_gb "$NEED_GB" \
    --arg kv_cache_dtype "$KV_CACHE_DTYPE" \
    --arg is_moe "$IS_MOE" \
    --argjson hf "$HF_MODEL_INFO_JSON" \
    --argjson schema_version "$PROFILE_SCHEMA_VERSION" \
    '{
      schema_version: $schema_version,
      model: $model,
      generated: $generated,
      hf: $hf,
      reasoning_parser: $reasoning_parser,
      tool_call_parser: $tool_call_parser,
      gpu_memory_utilization: $gpu_memory_utilization,
      max_model_len: $max_model_len,
      is_multimodal: $is_multimodal,
      is_moe: $is_moe,
      model_size_gb: $model_size_gb,
      weights_gb: $weights_gb,
      kv_gb: $kv_gb,
      need_gb: $need_gb,
      kv_cache_dtype: $kv_cache_dtype
    }' > "$profile_file"
}

profile_file_for() {
  printf '%s/%s.json' "$PROFILES_DIR" "$(printf '%s' "$1" | sed 's/\//--/g')"
}

# Load the cached startup peaks for THIS model at the final launch config (ctx/kv). Sets two globals:
#   WARMUP_PEAK_EAGER_GB      — peak measured with --enforce-eager (CUDA graphs OFF), or ""
#   WARMUP_PEAK_CUDAGRAPH_GB  — peak measured with CUDA graphs ON; the literal "oom" if they were
#                               tried and didn't fit; "" if never tried.
# Reads the new two-column shape and MIGRATES a legacy single-peak entry (peak_gb + enforce_eager
# [+ cudagraph_oom]) on the fly, so measurements taken by older spark versions aren't lost. The
# community DB (data/model_profiles.json) is consulted as a fallback hint when there's no local one.
load_warmup_cache() {
  local model="$1" pf key lp le lo
  WARMUP_PEAK_EAGER_GB=""; WARMUP_PEAK_CUDAGRAPH_GB=""
  key="${MAX_MODEL_LEN}/${KV_CACHE_DTYPE}"
  pf=$(profile_file_for "$model")
  if [[ -f "$pf" ]]; then
    WARMUP_PEAK_EAGER_GB=$(jq -r --arg k "$key" '(.warmup // {})[$k].eager_peak_gb // ""' "$pf" 2>/dev/null || echo "")
    WARMUP_PEAK_CUDAGRAPH_GB=$(jq -r --arg k "$key" '(.warmup // {})[$k].cudagraph_peak_gb // ""' "$pf" 2>/dev/null || echo "")
    if [[ -z "$WARMUP_PEAK_EAGER_GB" && -z "$WARMUP_PEAK_CUDAGRAPH_GB" ]]; then
      lp=$(jq -r --arg k "$key" '(.warmup // {})[$k].peak_gb // ""' "$pf" 2>/dev/null || echo "")
      le=$(jq -r --arg k "$key" '(.warmup // {})[$k].enforce_eager // ""' "$pf" 2>/dev/null || echo "")
      lo=$(jq -r --arg k "$key" '(.warmup // {})[$k].cudagraph_oom // ""' "$pf" 2>/dev/null || echo "")
      if [[ -n "$lp" ]]; then
        if [[ "$le" == "1" ]]; then
          WARMUP_PEAK_EAGER_GB="$lp"; [[ "$lo" == "1" ]] && WARMUP_PEAK_CUDAGRAPH_GB="oom"
        else
          WARMUP_PEAK_CUDAGRAPH_GB="$lp"
        fi
      fi
    fi
  fi
  [[ -n "$WARMUP_PEAK_EAGER_GB" || -n "$WARMUP_PEAK_CUDAGRAPH_GB" ]] && return 0
  community_warmup_hint "$model"   # may set the two globals as a hint
}

# Look up a shipped community profile (data/model_profiles.json) keyed by the dimensions that affect
# the peak: model · accel · vllm tag · ctx · kv. Match is a HINT (the cgroup cap + reactive retry
# still validate), never authoritative — hardware/version differences make it approximate.
community_warmup_hint() {
  local model="$1" db key ngc tag
  db="${SPARK_DIR:-$(dirname "$(command -v spark 2>/dev/null || echo "${BASH_SOURCE[0]}")")}/data/model_profiles.json"
  [[ -f "$db" ]] || return 0
  ngc=$(detect_ngc_image 2>/dev/null); tag="${ngc##*:}"
  key="${MAX_MODEL_LEN}/${KV_CACHE_DTYPE}"
  # New two-column shape (eager_peak_gb / cudagraph_peak_gb); falls back to the legacy single peak
  # (warmup_peak_gb + enforce_eager) so an older DB still gives a hint.
  WARMUP_PEAK_EAGER_GB=$(jq -r --arg m "$model" --arg a "$ACCEL" --arg t "$tag" --arg k "$key" \
    '([.[] | select(.model==$m and .accel==$a and .vllm_tag==$t and .config==$k)][0]) as $r
     | ($r.eager_peak_gb // (if ($r.enforce_eager)=="1" then $r.warmup_peak_gb else null end) // "")' \
    "$db" 2>/dev/null || echo "")
  WARMUP_PEAK_CUDAGRAPH_GB=$(jq -r --arg m "$model" --arg a "$ACCEL" --arg t "$tag" --arg k "$key" \
    '([.[] | select(.model==$m and .accel==$a and .vllm_tag==$t and .config==$k)][0]) as $r
     | ($r.cudagraph_peak_gb // (if ($r.enforce_eager)=="0" then $r.warmup_peak_gb else null end) // "")' \
    "$db" 2>/dev/null || echo "")
}

# Record a measured startup peak into THIS model's profile (keyed by ctx/kv), in the column for the
# mode that actually ran — eager_peak_gb (eager run) or cudagraph_peak_gb (CUDA-graph run, or "oom"
# if graphs were tried this run and didn't fit). Merges so the OTHER column is preserved, and strips
# any legacy single-peak fields. Args: model, measured_gb, enforce_eager(0/1), cudagraph_oomed(0/1).
save_warmup_peak() {
  local model="$1" measured="$2" eager="$3" cgoom="${4:-0}" pf tmp key eager_val="" cg_val=""
  pf=$(profile_file_for "$model")
  [[ -f "$pf" ]] || return 0
  key="${MAX_MODEL_LEN}/${KV_CACHE_DTYPE}"
  if [[ "$eager" == "0" ]]; then cg_val="$measured"          # CUDA graphs served → record their peak
  elif [[ "$cgoom" == "1" ]]; then eager_val="$measured"; cg_val="oom"  # graphs OOMed, eager served
  else eager_val="$measured"; fi                            # plain eager run
  tmp=$(mktemp)
  if jq --arg k "$key" --arg ev "$eager_val" --arg cv "$cg_val" --arg d "$(date +%Y-%m-%d)" \
      '.warmup[$k] = ((.warmup[$k] // {})
        + (if $ev != "" then {eager_peak_gb: $ev} else {} end)
        + (if $cv != "" then {cudagraph_peak_gb: $cv} else {} end)
        + {date: $d})
       | .warmup[$k] |= del(.peak_gb, .enforce_eager, .cudagraph_oom)' \
      "$pf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$pf"
  else
    rm -f "$tmp"
  fi
}

load_launch_calibration() {
  local model="$1" pf
  CALIBRATION_AVAILABLE=0
  CALIBRATED_MAX_NUM_SEQS=""
  CALIBRATED_MTP_ENABLED=""
  CALIBRATED_STREAM_INTERVAL=""
  CALIBRATED_MAX_NUM_BATCHED_TOKENS=""
  CALIBRATED_KV_CACHE_DTYPE=""
  CALIBRATED_TOKENS_PER_SECOND=""
  pf=$(profile_file_for "$model")
  [[ -f "$pf" ]] || return 0
  jq -e '.calibration.best' "$pf" >/dev/null 2>&1 || return 0
  CALIBRATION_AVAILABLE=1
  CALIBRATED_MAX_NUM_SEQS=$(jq -r '.calibration.best.max_num_seqs // ""' "$pf" 2>/dev/null || echo "")
  CALIBRATED_MTP_ENABLED=$(jq -r '.calibration.best.mtp_enabled // ""' "$pf" 2>/dev/null || echo "")
  CALIBRATED_STREAM_INTERVAL=$(jq -r '.calibration.best.stream_interval // ""' "$pf" 2>/dev/null || echo "")
  CALIBRATED_MAX_NUM_BATCHED_TOKENS=$(jq -r '.calibration.best.max_num_batched_tokens // ""' "$pf" 2>/dev/null || echo "")
  CALIBRATED_KV_CACHE_DTYPE=$(jq -r '.calibration.best.kv_cache_dtype // ""' "$pf" 2>/dev/null || echo "")
  CALIBRATED_TOKENS_PER_SECOND=$(jq -r '.calibration.best.tokens_per_second // ""' "$pf" 2>/dev/null || echo "")
  [[ "$CALIBRATED_MAX_NUM_SEQS" =~ ^[0-9]+$ ]] || CALIBRATED_MAX_NUM_SEQS=""
  [[ "$CALIBRATED_MTP_ENABLED" =~ ^(0|1)$ ]] || CALIBRATED_MTP_ENABLED=""
  [[ "$CALIBRATED_STREAM_INTERVAL" =~ ^[0-9]+$ ]] || CALIBRATED_STREAM_INTERVAL=""
  [[ "$CALIBRATED_MAX_NUM_BATCHED_TOKENS" =~ ^[0-9]+$ ]] || CALIBRATED_MAX_NUM_BATCHED_TOKENS=""
  [[ "$CALIBRATED_KV_CACHE_DTYPE" =~ ^(auto|fp8)$ ]] || CALIBRATED_KV_CACHE_DTYPE=""
  [[ "$CALIBRATED_TOKENS_PER_SECOND" =~ ^[0-9]+([.][0-9]+)?$ ]] || CALIBRATED_TOKENS_PER_SECOND=""
}

save_launch_calibration() {
  local model="$1" best_json="$2" results_json="$3" pf tmp
  pf=$(profile_file_for "$model")
  [[ -f "$pf" ]] || return 0
  printf '%s\n' "$best_json" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s\n' "$results_json" | jq -e . >/dev/null 2>&1 || return 1
  tmp=$(mktemp)
  if jq --arg d "$(date +%Y-%m-%d)" --argjson best "$best_json" --argjson results "$results_json" \
      '.calibration = {
        date: $d,
        best: $best,
        results: $results
      }' "$pf" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$pf"
  else
    rm -f "$tmp"
    return 1
  fi
}

# A container's cgroup v2 high-water mark (exact, no sampling) in GB. Empty if unavailable.
container_peak_gb() {
  local bytes
  bytes=$(docker exec "$1" cat /sys/fs/cgroup/memory.peak 2>/dev/null | tr -d '[:space:]')
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 0
  awk -v b="$bytes" 'BEGIN{ printf "%.1f", b/1073741824 }'
}

# A container's CURRENT cgroup v2 memory usage in GB (live). Empty if unavailable.
container_current_gb() {
  local bytes
  bytes=$(docker exec "$1" cat /sys/fs/cgroup/memory.current 2>/dev/null | tr -d '[:space:]')
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 0
  awk -v b="$bytes" 'BEGIN{ printf "%.1f", b/1073741824 }'
}

# Recompute KV + need + fraction from config.json using the current MAX_MODEL_LEN
# and KV_CACHE_DTYPE. Used after applying --max-len / --kv-cache-dtype overrides so
# a cached profile still reflects the requested settings. WEIGHTS_GB is reused as-is.
recompute_memory() {
  local config_json="$1"
  [[ -f "$config_json" ]] || return 0
  compute_kv_gb "$config_json" "$MAX_MODEL_LEN" "$KV_CACHE_DTYPE"
  [[ "$KV_UNCERTAIN" == "1" ]] && warn "config.json lacks KV cache fields — sizing from weights only"
  compute_need_and_fraction
}

# --- Multi-model helpers ---

# Short, human-readable slug from a model ref: last path segment + a size hint.
# RedHatAI/Qwen3.6-35B-A3B-NVFP4 -> qwen3.6-35b ; nvidia/Llama-4-Scout-17B-16E -> llama-4-scout-17b
slugify_model() {
  local model="$1"
  local tail size base
  tail="${model##*/}"                                   # last path segment
  size=$(printf '%s' "$tail" | grep -oiE '[0-9]+(\.[0-9]+)?b' | head -1 || true)
  base=$(printf '%s' "$tail" | sed -E 's/-?[0-9]+(\.[0-9]+)?[Bb].*$//')   # drop size and trailing tags
  [[ -z "$base" ]] && base="$tail"
  local slug="${base}"
  [[ -n "$size" ]] && slug="${base}-${size}"
  # Lowercase, keep [a-z0-9.-], collapse repeats, trim dashes
  slug=$(printf '%s' "$slug" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9.-]+/-/g; s/-+/-/g; s/^-//; s/-$//')
  [[ -z "$slug" ]] && slug="model"
  printf '%s\n' "$slug"
}

# Container name for a model: spark-vllm-<slug>.
container_name_for_model() {
  printf '%s-%s\n' "$CONTAINER_NAME" "$(slugify_model "$1")"
}

# List managed vLLM containers as TSV: name<TAB>model<TAB>port<TAB>need_gb<TAB>weights_gb<TAB>kv_gb.
# Source of truth = docker labels on running containers (no state file).
list_managed_containers() {
  docker ps --filter label=spark.managed=1 \
    --format '{{.Names}}	{{.Label "spark.model"}}	{{.Label "spark.port"}}	{{.Label "spark.need_gb"}}	{{.Label "spark.weights_gb"}}	{{.Label "spark.kv_gb"}}' \
    2>/dev/null || true
}

# Resolve a managed container name from a model ref (matches the spark.model label).
container_for_ref() {
  local ref="$1" name model rest
  while IFS=$'\t' read -r name model rest; do
    [[ "$model" == "$ref" ]] && { printf '%s\n' "$name"; return 0; }
  done < <(list_managed_containers)
  return 1
}

# Sum of reserved need (GB) across live managed containers, optionally excluding one name.
reserved_budget_gb() {
  local exclude="${1:-}"
  list_managed_containers | awk -F'\t' -v ex="$exclude" '
    $1 != ex && $4 ~ /^[0-9]+(\.[0-9]+)?$/ { s += $4 }
    END { printf "%.1f", s+0 }'
}

# True if a port is already in use (by a managed container or a host listener).
port_in_use() {
  local port="$1"
  list_managed_containers | awk -F'\t' -v p="$port" '$3 == p {found=1} END {exit !found}' && return 0
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$" && return 0
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && return 0
  fi
  return 1
}

# First free port at or above the given start (default 8000).
next_free_port() {
  local port="${1:-$DEFAULT_PORT}"
  while port_in_use "$port"; do
    port=$(( port + 1 ))
    [[ "$port" -gt 65535 ]] && die "No free port available"
  done
  printf '%s\n' "$port"
}

# Abort if the new model does not fit the remaining budget. Never touches live models.
# Format a token count as a short label: 32768 -> 32K.
fmt_ctx() { awk -v n="${1:-0}" 'BEGIN{ if (n>0 && n%1024==0) printf "%dK", n/1024; else printf "%d", n }'; }

state_word() {
  case "${1:-unknown}" in
    ok|running|ready|configured|yes|pass) printf "${GREEN}ok${NC}" ;;
    warn|partial|missing|stopped|no)      printf "${YELLOW}%s${NC}" "${1:-warn}" ;;
    fail|error|public)                    printf "${RED}%s${NC}" "${1:-fail}" ;;
    *)                                    printf "${DIM}%s${NC}" "${1:-unknown}" ;;
  esac
}

dashboard_row() {
  local state="$1" label="$2" detail="${3:-}"
  printf "  %-10b %-24s %s\n" "$(state_word "$state")" "$label" "$detail"
}

docker_running() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

container_running() {
  local name="$1"
  command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"
}

gateway_configured() {
  [[ -f "$GATEWAY_CONFIG" ]] && command -v jq >/dev/null 2>&1 && \
    [[ "$(gateway_load_config | jq -r '.enabled // false' 2>/dev/null)" == "true" ]]
}

gateway_running_state() {
  container_running "$GATEWAY_CONTAINER"
}

gateway_configured_port() {
  local config port
  config=$(gateway_load_config 2>/dev/null || echo '{}')
  port=$(echo "$config" | jq -r '.port // 4000' 2>/dev/null || echo "$GATEWAY_PORT")
  printf '%s\n' "${port:-$GATEWAY_PORT}"
}

gateway_provider_list() {
  local config providers=()
  config=$(gateway_load_config 2>/dev/null || echo '{}')
  command -v jq >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  [[ "$(echo "$config" | jq -r '.providers.vllm.enabled // false' 2>/dev/null)" == "true" ]] && providers+=("vLLM")
  [[ "$(echo "$config" | jq -r '.providers.ollama.enabled // false' 2>/dev/null)" == "true" ]] && providers+=("Ollama")
  [[ "$(echo "$config" | jq -r '.providers.openrouter.enabled // false' 2>/dev/null)" == "true" ]] && providers+=("OpenRouter")
  [[ "$(echo "$config" | jq -r '.providers.zen.enabled // false' 2>/dev/null)" == "true" ]] && providers+=("Zen")
  [[ "$(echo "$config" | jq -r '.providers.together.enabled // false' 2>/dev/null)" == "true" ]] && providers+=("Together")
  if [[ ${#providers[@]} -eq 0 ]]; then printf 'none\n'; else (IFS=', '; printf '%s\n' "${providers[*]}"); fi
}

count_running_vllm_models() {
  list_managed_containers 2>/dev/null | awk 'NF>0{n++} END{print n+0}'
}

count_downloaded_hf_models() {
  local n=0
  [[ -d "${HF_CACHE_DIR}/hub" ]] && n=$(find "${HF_CACHE_DIR}/hub" -maxdepth 1 -name "models--*" -type d 2>/dev/null | wc -l | tr -d ' ')
  printf '%s\n' "${n:-0}"
}

count_ollama_models() {
  local n
  command -v ollama >/dev/null 2>&1 || { printf '0\n'; return 0; }
  n=$(ollama list 2>/dev/null | awk 'NR>1 && NF>0{n++} END{print n+0}' || true)
  printf '%s\n' "${n:-0}"
}

count_loaded_ollama_models() {
  local n
  command -v ollama >/dev/null 2>&1 || { printf '0\n'; return 0; }
  n=$(ollama ps 2>/dev/null | awk 'NR>1 && NF>0{n++} END{print n+0}' || true)
  printf '%s\n' "${n:-0}"
}

workspace_configured() {
  [[ -f "$WORKSPACE_ENV_FILE" && -f "$WORKSPACE_COMPOSE_FILE" ]]
}

workspace_service_count() {
  workspace_configured || { printf '0\n'; return 0; }
  workspace_compose ps --services --status running 2>/dev/null | awk 'NF>0{n++} END{print n+0}'
}

setup_status_summary() {
  local ready=0 total=0 missing=()
  total=$((total + 1)); if command -v jq >/dev/null 2>&1; then ready=$((ready + 1)); else missing+=("jq"); fi
  total=$((total + 1)); if docker_running; then ready=$((ready + 1)); else missing+=("docker"); fi
  if [[ "$BACKEND" == "vllm" ]]; then
    total=$((total + 1)); if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then ready=$((ready + 1)); else missing+=("gpu"); fi
    total=$((total + 1)); if [[ -n "$(detect_ngc_image)" ]]; then ready=$((ready + 1)); else missing+=("vllm-image"); fi
    total=$((total + 1)); if command -v hf >/dev/null 2>&1; then ready=$((ready + 1)); else missing+=("hf"); fi
  else
    total=$((total + 1)); if command -v ollama >/dev/null 2>&1; then ready=$((ready + 1)); else missing+=("ollama"); fi
    total=$((total + 1)); if ollama_reachable; then ready=$((ready + 1)); else missing+=("ollama-api"); fi
  fi
  total=$((total + 1)); if gateway_configured; then ready=$((ready + 1)); else missing+=("gateway-config"); fi
  printf '%s/%s' "$ready" "$total"
  if [[ ${#missing[@]} -gt 0 ]]; then (IFS=', '; printf ' missing: %s' "${missing[*]}"); fi
}

print_next_steps() {
  local inference_only="${1:-0}" any=0 lines=()
  if ! gateway_configured; then
    lines+=("Run spark setup to configure the gateway and backend."); any=1
  elif ! gateway_running_state; then
    lines+=("Run spark gateway start to expose the OpenAI-compatible API."); any=1
  fi
  if [[ "$BACKEND" == "vllm" && "$(count_running_vllm_models)" -eq 0 ]]; then
    lines+=("Run spark models recommend, then spark run <model>."); any=1
  elif [[ "$BACKEND" == "ollama" && "$(count_loaded_ollama_models)" -eq 0 ]]; then
    lines+=("Run spark models recommend, then spark run <model>."); any=1
  fi
  if [[ "$inference_only" != "1" ]] && ! workspace_configured; then
    lines+=("Run spark ws setup for the daily agent workspace."); any=1
  fi
  [[ "$any" -eq 0 ]] && return 0
  printf "\n  ${BOLD}Next steps${NC}\n"
  local line
  for line in "${lines[@]}"; do printf "  - %s\n" "$line"; done
  return 0
}

# Given free GB, compute the two largest context windows that would fit:
#   FIT_CTX_AUTO (KV in auto, 2 bytes) and FIT_CTX_FP8 (KV in fp8, 1 byte -> double the tokens).
# Capped at the model's HF max and rounded down to a 1024-token boundary.
fit_options() {
  local free="$1"
  FIT_POSSIBLE=0; FIT_CTX_AUTO=0; FIT_CTX_FP8=0
  [[ "${KV_UNCERTAIN:-0}" == "1" ]] && return 0
  is_positive_int "${MAX_MODEL_LEN:-0}" || return 0
  awk -v k="${KV_GB:-0}" 'BEGIN{ exit !(k>0) }' || return 0

  local cap="${MODEL_MAX_LEN:-131072}"
  [[ "$cap" =~ ^[0-9]+$ ]] || cap=131072

  read -r FIT_POSSIBLE FIT_CTX_AUTO FIT_CTX_FP8 < <(awk \
    -v free="$free" -v w="${WEIGHTS_GB:-0}" -v h="${MEM_HEADROOM_PCT:-8}" \
    -v kv="${KV_GB:-0}" -v cur="${MAX_MODEL_LEN}" -v dt="${KV_CACHE_DTYPE:-auto}" -v cap="$cap" '
    BEGIN{
      kv_budget = free/(1+h/100) - w;
      if (kv_budget <= 0) { print 0, 0, 0; exit }
      per_tok_cur  = kv / cur;
      per_tok_auto = (dt=="fp8") ? per_tok_cur*2 : per_tok_cur;
      per_tok_fp8  = per_tok_auto/2;
      max_auto = kv_budget/per_tok_auto;
      max_fp8  = kv_budget/per_tok_fp8;
      ca = int((max_auto < cap ? max_auto : cap) / 1024) * 1024;
      cf = int((max_fp8  < cap ? max_fp8  : cap) / 1024) * 1024;
      if (ca < 1024) ca=0;
      if (cf < 1024) cf=0;
      print ((ca>0||cf>0)?1:0), ca, cf;
    }')
  return 0
}

# Print the fitting options as text + the command to use (non-interactive / dry-run).
print_fit_suggestion() {
  local model="$1"
  if [[ "${FIT_POSSIBLE:-0}" != "1" ]]; then
    printf "    Reducing context won't help — free memory: ${BOLD}spark stop <model>${NC}\n"
    return 0
  fi
  [[ "${FIT_CTX_AUTO:-0}" -gt 0 ]] && printf "    → Fits at up to %s ctx:  ${BOLD}spark run %s --max-len %s${NC}\n" "$(fmt_ctx "$FIT_CTX_AUTO")" "$model" "$FIT_CTX_AUTO"
  [[ "${FIT_CTX_FP8:-0}" -gt 0 ]] && printf "    → or up to %s with fp8:  ${BOLD}spark run %s --max-len %s --kv-cache-dtype fp8${NC}\n" "$(fmt_ctx "$FIT_CTX_FP8")" "$model" "$FIT_CTX_FP8"
  return 0
}

# True when we can prompt the user (a TTY, or the test/interactive override).
is_interactive() { [[ -t 0 || -n "${SPARK_ASSUME_INTERACTIVE:-}" ]]; }

# Check the model fits in the free budget. If it does not:
#  - --mem set: suggest the largest --mem that fits, then abort (context can't help a fixed --mem).
#  - interactive: offer a context menu (auto vs fp8); the choice updates MAX_MODEL_LEN/KV_CACHE_DTYPE
#    and memory, and the launch continues.
#  - non-interactive: print the fitting options + command, then abort.
#  - dry-run: print the verdict/options and continue (never prompts, never aborts).
# Admission budget for the sum of model reservations = TOTAL − OS reserve. The host is protected by
# the per-container cgroup cap + earlyoom + control-plane OOM protection, so there's no separate util cap.
usable_budget() {
  printf '%s\n' "$BUDGET_GB"
}

budget_free_gb() {
  local reserved="${1:-0}"
  awk -v b="$(usable_budget "$reserved")" -v r="$reserved" 'BEGIN{ printf "%.1f", b-r }'
}

live_available_gb() {
  free -m 2>/dev/null | awk '/^Mem:/ { printf "%.1f", $7/1024; found=1 } END { exit !found }'
}

effective_free_gb() {
  local reserved="${1:-0}" budget_free live_free
  budget_free=$(budget_free_gb "$reserved")
  if [[ "$ACCEL" == "cuda-unified" ]] && live_free=$(live_available_gb 2>/dev/null) \
      && [[ "$live_free" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    awk -v b="$budget_free" -v l="$live_free" 'BEGIN{ printf "%.1f", (l<b ? l : b) }'
    return 0
  fi
  printf '%s\n' "$budget_free"
}

verify_capacity() {
  local new_need="$1" exclude="${2:-}" dry_run="${3:-0}" mem="${4:-}" model="${5:-}" config_json="${6:-}"
  local reserved free budget_free live_free
  reserved=$(reserved_budget_gb "$exclude")
  budget_free=$(budget_free_gb "$reserved")
  free=$(effective_free_gb "$reserved")

  awk -v n="$new_need" -v f="$free" 'BEGIN{ exit !(n > f) }' || return 0   # fits

  err "Not enough memory to start this model"
  printf "    Needs:      %s GB\n" "$new_need"
  if [[ "$ACCEL" == "cuda-unified" ]] && live_free=$(live_available_gb 2>/dev/null) \
      && [[ "$live_free" =~ ^[0-9]+([.][0-9]+)?$ ]] \
      && awk -v l="$live_free" -v b="$budget_free" 'BEGIN{ exit !(l < b) }'; then
    printf "    Free:       %s GB  (live available; budget free %s GB)\n" "$free" "$budget_free"
  else
    printf "    Free:       %s GB  (budget %s GB = %s total − %s OS-reserved)\n" \
      "$free" "$BUDGET_GB" "$TOTAL_MEM_GB" "$OS_RESERVE_GB"
  fi
  local any=0 name m port need _
  while IFS=$'\t' read -r name m port need _; do
    [[ -z "$m" ]] && continue
    [[ "$name" == "$exclude" ]] && continue
    [[ "$any" -eq 0 ]] && { printf "    In use:\n"; any=1; }
    printf "      %-32s %s GB  (port %s)\n" "$m" "${need:-?}" "${port:-?}"
  done < <(list_managed_containers)

  # Manual --mem: reducing context won't change a fixed reservation; suggest a smaller --mem.
  if [[ -n "$mem" ]]; then
    local maxmem
    maxmem=$(awk -v f="$free" -v T="$TOTAL_MEM_GB" 'BEGIN{ x=f/T; if(x<0)x=0; printf "%.2f", x }')
    printf "    → Fits with --mem ≤ %s:  ${BOLD}spark run %s --mem %s${NC}\n" "$maxmem" "$model" "$maxmem"
    printf "    Or free memory:  ${BOLD}spark stop <model>${NC}\n"
    [[ "$dry_run" == "1" ]] && return 0
    exit 1
  fi

  fit_options "$free"

  if [[ "$FIT_POSSIBLE" != "1" ]]; then
    print_fit_suggestion "$model"   # already prints the "free memory" hint
    [[ "$dry_run" == "1" ]] && return 0
    exit 1
  fi

  if [[ "$dry_run" == "1" ]]; then
    print_fit_suggestion "$model"
    return 0
  fi

  if ! is_interactive; then
    print_fit_suggestion "$model"
    printf "    Or free memory:  ${BOLD}spark stop <model>${NC}\n"
    exit 1
  fi

  # Interactive: offer the fitting contexts and apply the choice.
  printf "\n    Choose a context that fits:\n"
  local i=1 opt_auto="" opt_fp8="" choice cancel
  if [[ "$FIT_CTX_AUTO" -gt 0 ]]; then printf "      %d) %s tokens   (KV auto)\n" "$i" "$FIT_CTX_AUTO"; opt_auto="$i"; i=$((i+1)); fi
  if [[ "$FIT_CTX_FP8" -gt 0 ]]; then printf "      %d) %s tokens   (KV fp8 — slightly less precision)\n" "$i" "$FIT_CTX_FP8"; opt_fp8="$i"; i=$((i+1)); fi
  printf "      %d) cancel\n" "$i"
  cancel="$i"
  while true; do
    printf "    > "
    read -r choice || choice="$cancel"
    if [[ -n "$opt_auto" && "$choice" == "$opt_auto" ]]; then
      MAX_MODEL_LEN="$FIT_CTX_AUTO"; KV_CACHE_DTYPE="auto"; break
    elif [[ -n "$opt_fp8" && "$choice" == "$opt_fp8" ]]; then
      MAX_MODEL_LEN="$FIT_CTX_FP8"; KV_CACHE_DTYPE="fp8"; break
    elif [[ "$choice" == "$cancel" ]]; then
      printf "    Aborted.\n"; exit 0
    else
      printf "    Enter a number from 1 to %s.\n" "$cancel"
    fi
  done

  [[ -n "$config_json" ]] && recompute_memory "$config_json"
  info "Using ${MAX_MODEL_LEN} ctx (KV ${KV_CACHE_DTYPE}) — needs ${NEED_GB} GB"
  awk -v n="${NEED_GB}" -v f="$free" 'BEGIN{ exit !(n > f) }' && { err "Still doesn't fit after adjustment"; exit 1; }
  return 0
}

# Download just the metadata (config.json + safetensors index) so we can size the
# model and check it fits BEFORE pulling tens of GB of weights. Returns 0 on success.
fetch_model_metadata() {
  local model="$1"
  command -v hf >/dev/null 2>&1 || { err "hf CLI not found" ; printf "    Install it with: spark setup\n"; return 1; }
  hf download "$model" config.json >/dev/null 2>&1 || return 1
  # Index is best-effort: single-file models won't have it (weights then fall back to params).
  hf download "$model" model.safetensors.index.json >/dev/null 2>&1 || true
  return 0
}

# Download the full model weights.
download_model_full() {
  local model="$1"
  printf "\n  Downloading %s...\n\n" "$model"
  hf download "$model"
  printf "\n"
}
