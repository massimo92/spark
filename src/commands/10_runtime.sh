# --- Commands ---

cmd_run_help() {
  cat <<EOF

  ${BOLD}Usage:${NC} spark run <model> [flags]

  ${BOLD}Flags:${NC}
    --mem <float>          Force GPU memory fraction (0.0-1.0); bypasses auto-sizing.
    --no-mem-limit         Do not set a cgroup memory cap for unified-memory backends.
    --max-len <int>        Force context length; affects KV cache memory.
    --kv-cache-dtype fp8   Use fp8 KV cache to reduce memory.
    --max-num-seqs <int>   Max concurrent requests; higher uses more memory.
    --enforce-eager        Disable CUDA graphs; lower startup peak, slower inference.
    --no-enforce-eager     Force CUDA graphs on.
    --port <int>           Direct model API port; default auto-selects from 8000.
    --tools                Enable tool-calling parser when supported.
    --text-only            Disable vision input for multimodal models.
    --no-reasoning         Disable reasoning parser.
    --no-pull              Fail if model is missing; do not offer download.
    --dry-run              Print memory plan and Docker command; do not run.
    --explain              With --dry-run, show HF metadata, chosen flags and questions.
    --no-wait              Start container and return without health supervision.
    --tail                 Follow logs after launch.
    --force                Replace an already running instance of the model.
    --regen-profile        Recompute cached model memory profile.

EOF
}

cmd_run() {
  local model="" port="" mem="" max_len="" kv_dtype="" tools=0 text_only=0
  local no_reasoning=0 dry_run=0 explain=0 tail_logs=0 force=0 regen=0 no_pull=0 no_mem_limit=0
  local no_wait=0 max_num_seqs="" enforce_eager_flag="auto"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mem)       [[ $# -ge 2 ]] || die "Missing value for --mem"; mem="$2"; shift 2 ;;
      --no-mem-limit) no_mem_limit=1; shift ;;
      --enforce-eager)    enforce_eager_flag=1; shift ;;
      --no-enforce-eager) enforce_eager_flag=0; shift ;;
      --no-wait)   no_wait=1; shift ;;
      --max-num-seqs) [[ $# -ge 2 ]] || die "Missing value for --max-num-seqs"; max_num_seqs="$2"; shift 2 ;;
      --max-len)   [[ $# -ge 2 ]] || die "Missing value for --max-len"; max_len="$2"; shift 2 ;;
      --port)      [[ $# -ge 2 ]] || die "Missing value for --port"; port="$2"; shift 2 ;;
      --kv-cache-dtype) [[ $# -ge 2 ]] || die "Missing value for --kv-cache-dtype"; kv_dtype="$2"; shift 2 ;;
      --tools)     tools=1; shift ;;
      --text-only) text_only=1; shift ;;
      --no-reasoning) no_reasoning=1; shift ;;
      --no-pull)   no_pull=1; shift ;;
      --dry-run)   dry_run=1; shift ;;
      --explain)   explain=1; shift ;;
      --tail)      tail_logs=1; shift ;;
      --force)     force=1; shift ;;
      --regen-profile) regen=1; shift ;;
      -h|--help)   cmd_run_help; return 0 ;;
      -*)          die "Unknown flag: $1" "Run 'spark run --help' for usage" ;;
      *)           [[ -z "$model" ]] || die "Only one model can be specified"; model="$1"; shift ;;
    esac
  done

  [[ -z "$model" ]] && die "No model specified" "Usage: spark run <model> [flags]"
  validate_model_ref_for_backend "$model"

  # Pick the engine from the detected hardware (vLLM on NVIDIA, Ollama elsewhere).
  # cmd_run's flag locals are visible to the backend functions via dynamic scoping.
  case "$BACKEND" in
    vllm)   run_backend_vllm ;;
    ollama) run_backend_ollama ;;
    *)      die "Unknown backend: $BACKEND" "Set SPARK_BACKEND to 'vllm' or 'ollama'" ;;
  esac
}

# Decide whether to launch with --enforce-eager (no CUDA-graph capture → no startup peak).
# Manual flag wins; otherwise: a cached profile that needed eager → eager; a large MoE with no
# measurement (vLLM under-profiles these → big peak) → eager; else off (CUDA graphs, faster).
# Decide --enforce-eager. Sets globals ENFORCE_EAGER (0/1) and EAGER_CALIBRATING (1 when it's
# speculatively trying CUDA graphs to measure the real peak). Sets globals rather than printing so the
# calibration flag propagates to the caller (a command substitution would run in a subshell).
resolve_enforce_eager() {
  EAGER_CALIBRATING=0
  case "${enforce_eager_flag:-auto}" in
    1|yes|on|true)  ENFORCE_EAGER=1; return 0 ;;
    0|no|off|false) ENFORCE_EAGER=0; return 0 ;;
  esac
  # CUDA graphs measured to FIT (a numeric peak on record) → use them (fastest).
  [[ "${WARMUP_PEAK_CUDAGRAPH_GB:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] && { ENFORCE_EAGER=0; return 0; }
  # CUDA graphs tried and didn't fit → stay eager.
  [[ "${WARMUP_PEAK_CUDAGRAPH_GB:-}" == "oom" ]] && { ENFORCE_EAGER=1; return 0; }
  # Only an EAGER peak on record (graphs never tried): calibrate once — try CUDA graphs to learn their
  # peak (cgroup cap + reactive fallback make it safe). If calibration is disabled, stick with eager.
  if [[ -n "${WARMUP_PEAK_EAGER_GB:-}" ]]; then
    if [[ "${CALIBRATE_CUDAGRAPH:-1}" == "1" ]]; then EAGER_CALIBRATING=1; ENFORCE_EAGER=0
    else ENFORCE_EAGER=1; fi
    return 0
  fi
  # No measurement at all + MoE (vLLM under-profiles its warmup) → conservative eager on first launch.
  [[ "${IS_MOE:-0}" == "1" ]] && { ENFORCE_EAGER=1; return 0; }
  ENFORCE_EAGER=0
}

vllm_arg_has_flag() {
  local flag="$1" arg
  for arg in "${vllm_args[@]}"; do
    [[ "$arg" == "$flag" ]] && return 0
  done
  return 1
}

add_vllm_flag_once() {
  local flag="$1"
  vllm_arg_has_flag "$flag" || vllm_args+=("$@")
}

hf_command_value() {
  local flag="$1" re
  re="(^|[[:space:]])${flag}[[:space:]]+([^[:space:]]+)"
  if [[ "${HF_RECOMMENDED_COMMAND:-}" =~ $re ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}

add_recommended_command_flags() {
  local value
  value="$(hf_command_value --load-format)"
  [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]] && add_vllm_flag_once --load-format "$value"

  value="$(hf_command_value --max-num-batched-tokens)"
  [[ "$value" =~ ^[0-9]+$ ]] && add_vllm_flag_once --max-num-batched-tokens "$value"

  [[ "${HF_RECOMMENDED_COMMAND:-}" == *"--async-scheduling"* ]] && add_vllm_flag_once --async-scheduling
  return 0
}

ask_runtime_tradeoffs() {
  MTP_ENABLED="${MTP_ENABLED:-0}"
  [[ "$dry_run" == "1" ]] && return 0
  is_interactive || return 0

  local ans
  if [[ -z "${mem:-}" && -z "${kv_dtype:-}" && "${HF_KV_CACHE_FP8_RECOMMENDED:-false}" != "true" ]]; then
    printf "  Use FP8 KV cache? Lower memory/faster; may affect quality without model card calibration. [y/N] "
    read -r ans || ans=""
    if [[ "$ans" =~ ^[Yy] ]]; then
      KV_CACHE_DTYPE="fp8"
      recompute_memory "${model_path}/config.json"
    fi
  fi

  if [[ "${HAS_MTP:-false}" == "true" ]]; then
    printf "  Enable MTP speculative decoding? More tok/s; runtime-dependent/less stable. [y/N] "
    read -r ans || ans=""
    [[ "$ans" =~ ^[Yy] ]] && MTP_ENABLED=1
  fi

  if [[ "${SUPPORTS_TOOLS:-false}" == "true" && "$tools" != "1" ]]; then
    printf "  Enable tool calling? Adds parser/tool protocol; only needed for agents. [y/N] "
    read -r ans || ans=""
    [[ "$ans" =~ ^[Yy] ]] && tools=1
  fi
}

print_launch_explain() {
  [[ "${explain:-0}" == "1" ]] || return 0
  printf "\n  ${BOLD}Explain${NC}\n"
  printf "    HF:        %s%s\n" "$model" "${HF_REVISION:+ @ ${HF_REVISION}}"
  printf "    Tags:      %s\n" "${HF_TAGS:-none}"
  printf "    Features:  family=%s arch=%s quant=%s moe=%s mtp=%s tools=%s\n" \
    "${MODEL_FAMILY:-unknown}" "${MODEL_ARCHITECTURE:-unknown}" "${MODEL_QUANTIZATION:-unknown}" \
    "${IS_MOE:-0}" "${HAS_MTP:-false}" "${SUPPORTS_TOOLS:-false}"
  printf "    Card:      runtime=%s context=%s kv_fp8=%s\n" \
    "${HF_RECOMMENDED_RUNTIME:-unknown}" "${HF_RECOMMENDED_CONTEXT:-none}" "${HF_KV_CACHE_FP8_RECOMMENDED:-false}"
  printf "    Hardware:  accel=%s gpu=%s cc=%s driver=%s image=%s\n" \
    "$ACCEL" "${GPU_NAME:-unknown}" "${GPU_COMPUTE_CAPABILITY:-unknown}" "${GPU_DRIVER_VERSION:-unknown}" "$ngc_image"
  [[ -n "${HF_RECOMMENDED_COMMAND:-}" ]] && printf "    Card cmd:  %s\n" "$HF_RECOMMENDED_COMMAND"
  printf "    vLLM:      "
  shell_join "${vllm_args[@]}"
  printf "    Questions:\n"
  local any=0
  if [[ -z "${mem:-}" && -z "${kv_dtype:-}" && "${HF_KV_CACHE_FP8_RECOMMENDED:-false}" != "true" ]]; then
    printf "      - KV cache FP8: ask, default no\n"; any=1
  fi
  if [[ "${HAS_MTP:-false}" == "true" ]]; then
    printf "      - MTP: ask, default no\n"; any=1
  fi
  if [[ "${SUPPORTS_TOOLS:-false}" == "true" && "$tools" != "1" ]]; then
    printf "      - Tool calling: ask, default no\n"; any=1
  fi
  [[ "$any" == "0" ]] && printf "      - none\n"
}

# (Re)build vllm_args + docker_cmd from the current $seqs (concurrency), $headroom_gb (cgroup cap
# above NEED) and $enforce_eager. Called once and again on each adaptive-startup retry. Reads/writes
# run_backend_vllm locals via dynamic scope (same pattern as the backend reading cmd_run's flags).
build_launch() {
  ensure_hf_cache_writable
  vllm_args=(vllm serve "$model"
    --trust-remote-code
    --gpu-memory-utilization "$GPU_MEM_UTIL"
    --max-model-len "$MAX_MODEL_LEN"
    --max-num-seqs "$seqs"
    --port "$port")
  local quant_lc use_marlin_atomic=0
  quant_lc=$(printf '%s' "${MODEL_QUANTIZATION:-}" | tr '[:upper:]' '[:lower:]')
  if [[ "$ACCEL" == cuda-* ]]; then
    add_vllm_flag_once --attention-backend flashinfer
    add_vllm_flag_once --enable-chunked-prefill
    add_vllm_flag_once --enable-prefix-caching
  fi
  if [[ "$ACCEL" == cuda-* && "${IS_MOE:-0}" == "1" && "$quant_lc" =~ (nvfp4|fp8|fp4|modelopt) ]]; then
    add_vllm_flag_once --moe-backend marlin
    use_marlin_atomic=1
  fi
  add_recommended_command_flags
  [[ "$KV_CACHE_DTYPE" == "fp8" ]] && vllm_args+=(--kv-cache-dtype fp8)
  [[ "$enforce_eager" == "1" ]] && vllm_args+=(--enforce-eager)
  [[ -n "$REASONING_PARSER" && "$no_reasoning" != "1" ]] && vllm_args+=(--reasoning-parser "$REASONING_PARSER")
  [[ "$tools" == "1" && -n "$TOOL_CALL_PARSER" ]] && vllm_args+=(--enable-auto-tool-choice --tool-call-parser "$TOOL_CALL_PARSER")
  [[ "${MTP_ENABLED:-0}" == "1" ]] && vllm_args+=(--speculative-config '{"method":"mtp","num_speculative_tokens":3,"moe_backend":"triton"}')
  [[ "$text_only" == "1" && "$IS_MULTIMODAL" == "true" ]] && vllm_args+=(--limit-mm-per-prompt image=0)

  # Per-container hard ceiling = NEED + warmup headroom (the startup peak's room). --memory-swap is
  # set higher (by the provisioned swap) so the LOAD-time peak — the loader transiently needs ~2x the
  # weights — can spill into host swap and complete, instead of the container cgroup-OOMing mid-load.
  # The steady state still lives inside --memory (RAM); admission guarantees it fits.
  mem_limit_mib=""
  mem_swap_mib=""
  if [[ "$ACCEL" != "cuda-discrete" && "$no_mem_limit" != "1" ]]; then
    mem_limit_mib=$(awk -v n="$NEED_GB" -v h="$headroom_gb" \
      'BEGIN{ v=(n+h)*1024; iv=int(v); if(v>iv) iv++; printf "%d", iv }')
    mem_swap_mib=$(awk -v m="$mem_limit_mib" -v s="$SWAP_PROVISION_GB" \
      'BEGIN{ printf "%d", m + (s>0 ? s : 0)*1024 }')
  fi
  docker_cmd=(docker run -d
    --gpus all
    --network host
    --ipc=host
    --user "$(id -u):$(id -g)"
    --workdir /tmp
    -e HOME=/tmp
    -e HF_HOME=/tmp/huggingface
    -e HF_HUB_CACHE=/tmp/huggingface/hub
    --ulimit memlock=-1
    --ulimit stack=67108864
    -v "${HF_CACHE_DIR}:/tmp/huggingface"
    --name "$cname"
    --label spark.managed=1
    --label "spark.model=${model}"
    --label "spark.port=${port}"
    --label "spark.need_gb=${NEED_GB}"
    --label "spark.weights_gb=${WEIGHTS_GB}"
    --label "spark.kv_gb=${KV_GB}"
    --label "spark.max_model_len=${MAX_MODEL_LEN}")
  [[ "$use_marlin_atomic" == "1" ]] && docker_cmd+=(-e VLLM_MARLIN_USE_ATOMIC_ADD=1)
  [[ -n "$mem_limit_mib" ]] && docker_cmd+=(--memory "${mem_limit_mib}m" --memory-swap "${mem_swap_mib}m" --label "spark.mem_limit_mib=${mem_limit_mib}")
  docker_cmd+=("$ngc_image")
}

# Watch a just-launched vLLM container until it serves or stops. Echoes one of:
#   ready | timeout | exit:oom | exit:mamba:<N> | exit:other
# Progress lines go to stderr so the caller can capture the verdict from stdout.
await_startup() {
  local cname="$1" port="$2" timeout="$3"
  local waited=0 interval=3 ticks=0 st oom logs n last
  while [[ "$waited" -lt "$timeout" ]]; do
    st=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo "")
    if [[ -n "$st" && "$st" != "running" && "$st" != "created" ]]; then
      oom=$(docker inspect -f '{{.State.OOMKilled}}' "$cname" 2>/dev/null || echo "false")
      logs=$(docker logs --tail 80 "$cname" 2>&1 || true)
      [[ "$oom" == "true" ]] && { printf 'exit:oom\n'; return 0; }
      n=$(printf '%s' "$logs" | grep -oiE 'max_num_seqs to at most [0-9]+' | grep -oE '[0-9]+' | head -1)
      if [[ -z "$n" ]] && printf '%s' "$logs" | grep -qiE 'mamba cache blocks|exceeds available .*cache blocks'; then
        n=64   # pattern matched but no number parsed — conservative fallback
      fi
      [[ -n "$n" ]] && { printf 'exit:mamba:%s\n' "$n"; return 0; }
      printf 'exit:other\n'; return 0
    fi
    if curl -fsS "http://localhost:${port}/v1/models" >/dev/null 2>&1; then
      printf 'ready\n'; return 0
    fi
    ticks=$((ticks + 1))
    if [[ $((ticks % 5)) -eq 0 ]]; then
      last=$(docker logs --tail 1 "$cname" 2>&1 | tail -1 | cut -c1-80)
      [[ -n "$last" ]] && printf "    ${DIM}%s${NC}\n" "$last" >&2
    fi
    sleep "$interval"
    waited=$((waited + interval))
  done
  printf 'timeout\n'
}

# vLLM in a Docker container with NVIDIA GPUs. Reads cmd_run's flag locals.
run_backend_vllm() {
  is_safe_model_ref "$model" || die "Invalid model reference: $model" "Use a HuggingFace model like org/name"
  [[ -z "$port" ]] || is_port "$port" || die "Invalid --port value: $port" "Expected an integer from 1 to 65535"
  [[ -z "$mem" ]] || is_mem_util "$mem" || die "Invalid --mem value: $mem" "Expected a number from 0.0 to 1.0"
  [[ -z "$max_len" ]] || is_positive_int "$max_len" || die "Invalid --max-len value: $max_len" "Expected a positive integer"
  [[ -z "$kv_dtype" || "$kv_dtype" =~ ^(auto|fp8)$ ]] || die "Invalid --kv-cache-dtype value: $kv_dtype" "Expected: auto or fp8"
  [[ -z "$max_num_seqs" ]] || is_positive_int "$max_num_seqs" || die "Invalid --max-num-seqs value: $max_num_seqs" "Expected a positive integer"

  local cname
  cname=$(container_name_for_model "$model")

  # Is this model already running? (matched by label, not just by name)
  local existing
  existing=$(container_for_ref "$model" 2>/dev/null || true)
  [[ -z "$existing" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$" && existing="$cname"
  if [[ -n "$existing" ]]; then
    if [[ "$force" == "1" ]]; then
      docker stop "$existing" >/dev/null 2>&1 || true
      docker rm "$existing" >/dev/null 2>&1 || true
    else
      err "Model '${model}' is already running (container '${existing}')"
      printf "    Stop it first with: spark stop %s\n" "$model"
      printf "    Or replace it with: spark run --force %s\n" "$model"
      exit 1
    fi
  fi

  # Remove stopped container with same name
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${cname}$"; then
    docker rm "$cname" >/dev/null 2>&1 || true
  fi

  # Resolve model path. If it is not downloaded, fetch just the metadata so we can
  # size it and decide whether to pull the full weights (capacity-first).
  local model_path needs_download=0
  if ! model_path=$(resolve_model_path "$model"); then
    # Only offer to download interactively (a TTY, or SPARK_ASSUME_INTERACTIVE).
    if [[ "$dry_run" == "1" || "$no_pull" == "1" || ( ! -t 0 && -z "${SPARK_ASSUME_INTERACTIVE:-}" ) ]]; then
      err "Model '${model}' not found in HF cache"
      printf "    Download it first: spark pull %s\n" "$model"
      exit 1
    fi
    warn "Model '${model}' is not downloaded — fetching metadata to check if it fits..."
    fetch_model_metadata "$model" || die "Could not fetch model metadata" "Check the model name and your connection"
    model_path=$(resolve_model_path "$model") || die "Metadata download did not produce a usable snapshot"
    needs_download=1
    REGEN_PROFILE=1   # no cached profile yet; size from the fetched metadata
  fi

  # Profile (sizes memory by the model's NEED: weights + KV + cushion)
  REGEN_PROFILE="${REGEN_PROFILE:-$regen}"
  KV_CACHE_DTYPE="${kv_dtype:-}"
  profile_model "$model" "$model_path"

  # Apply effective settings (these override whatever a cached profile baked in),
  # then always recompute memory so the reservation reflects this run's flags.
  [[ -n "$max_len" ]] && MAX_MODEL_LEN="$max_len"
  [[ -n "$kv_dtype" ]] && KV_CACHE_DTYPE="$kv_dtype"
  [[ -z "$KV_CACHE_DTYPE" ]] && KV_CACHE_DTYPE="auto"
  recompute_memory "${model_path}/config.json"
  if [[ -n "$mem" ]]; then
    # Manual fraction: derive need from it so budget accounting stays coherent.
    GPU_MEM_UTIL="$mem"
    NEED_GB=$(awk -v m="$mem" -v T="$TOTAL_MEM_GB" 'BEGIN{ printf "%.1f", m*T }')
  fi
  [[ "$no_reasoning" == "1" ]] && REASONING_PARSER=""

  validate_profile_values

  # Capacity check BEFORE touching anything (and before pulling weights).
  if [[ "$needs_download" == "1" ]]; then
    local reserved free
    reserved=$(reserved_budget_gb "$cname")
    free=$(awk -v b="$(usable_budget "$reserved")" -v r="$reserved" 'BEGIN{ printf "%.1f", b-r }')
    if awk -v n="$NEED_GB" -v f="$free" 'BEGIN{ exit !(n > f) }'; then
      # Does not fit at the requested context (sized from metadata, before downloading).
      err "Not enough memory to start this model"
      printf "    Needs:  %s GB    Free:  %s GB\n" "$NEED_GB" "$free"
      fit_options "$free"
      if [[ "$FIT_POSSIBLE" == "1" && -z "$mem" ]] && is_interactive; then
        printf "\n    Choose what to do:\n"
        local i=1 oa="" of="" choice dl ca
        [[ "$FIT_CTX_AUTO" -gt 0 ]] && { printf "      %d) download + start at %s tokens (KV auto)\n" "$i" "$FIT_CTX_AUTO"; oa="$i"; i=$((i+1)); }
        [[ "$FIT_CTX_FP8" -gt 0 ]] && { printf "      %d) download + start at %s tokens (KV fp8)\n" "$i" "$FIT_CTX_FP8"; of="$i"; i=$((i+1)); }
        printf "      %d) download only (don't start)\n" "$i"; dl="$i"; i=$((i+1))
        printf "      %d) cancel\n" "$i"; ca="$i"
        while true; do
          printf "    > "; read -r choice || choice="$ca"
          if [[ -n "$oa" && "$choice" == "$oa" ]]; then max_len="$FIT_CTX_AUTO"; kv_dtype="auto"; break
          elif [[ -n "$of" && "$choice" == "$of" ]]; then max_len="$FIT_CTX_FP8"; kv_dtype="fp8"; break
          elif [[ "$choice" == "$dl" ]]; then download_model_full "$model"; info "Downloaded ${model}. Free memory then: spark run ${model}"; exit 0
          elif [[ "$choice" == "$ca" ]]; then printf "    Aborted.\n"; exit 0
          else printf "    Enter a number from 1 to %s.\n" "$ca"; fi
        done
      else
        [[ -z "$mem" ]] && print_fit_suggestion "$model"
        if [[ -z "$mem" ]] && is_interactive && confirm "Download it anyway (without starting)?"; then
          download_model_full "$model"
          info "Downloaded ${model}. Free memory then: spark run ${model}"
          exit 0
        fi
        printf "    Aborted. Nothing downloaded beyond metadata.\n"
        exit 1
      fi
    else
      # Fits: confirm the (large) download, then continue to launch.
      if ! confirm "Model fits (needs ${NEED_GB} GB, ${free} GB free). Download and start?"; then
        printf "    Aborted.\n"
        exit 0
      fi
    fi

    # Download the full weights and re-profile at the effective context.
    download_model_full "$model"
    model_path=$(resolve_model_path "$model") || die "Download did not produce a usable snapshot"
    REGEN_PROFILE=1
    profile_model "$model" "$model_path"
    [[ -n "$max_len" ]] && MAX_MODEL_LEN="$max_len"
    [[ -n "$kv_dtype" ]] && KV_CACHE_DTYPE="$kv_dtype"
    [[ -z "$KV_CACHE_DTYPE" ]] && KV_CACHE_DTYPE="auto"
    recompute_memory "${model_path}/config.json"
    if [[ -n "$mem" ]]; then GPU_MEM_UTIL="$mem"; NEED_GB=$(awk -v m="$mem" -v T="$TOTAL_MEM_GB" 'BEGIN{ printf "%.1f", m*T }'); fi
    [[ "$no_reasoning" == "1" ]] && REASONING_PARSER=""
    validate_profile_values
  fi
  verify_capacity "$NEED_GB" "$cname" "$dry_run" "$mem" "$model" "${model_path}/config.json"
  ask_runtime_tradeoffs
  validate_profile_values

  # Assign a port (auto unless --port given). Reject collisions with live models.
  if [[ -z "$port" ]]; then
    port=$(next_free_port "$DEFAULT_PORT")
  elif list_managed_containers | awk -F'\t' -v p="$port" '$3 == p {exit 0} END {exit 1}'; then
    die "Port ${port} is already used by another model" "Pick a free port or omit --port to auto-assign"
  fi

  # Detect NGC image
  local ngc_image
  ngc_image=$(detect_ngc_image)
  [[ -z "$ngc_image" ]] && die "No NGC vLLM container found" "Run: spark setup"

  # Concurrency cap (raise with --max-num-seqs); cgroup headroom for the startup peak (cached per
  # model, else default); and enforce-eager (kills the torch.compile/CUDA-graph peak). The adaptive
  # loop below lowers $seqs for cache-block errors and flips $enforce_eager on a warmup OOM.
  local seqs="${max_num_seqs:-$MAX_NUM_SEQS_DEFAULT}"
  load_warmup_cache "$model"   # sets WARMUP_PEAK_EAGER_GB / WARMUP_PEAK_CUDAGRAPH_GB
  local enforce_eager
  resolve_enforce_eager   # sets ENFORCE_EAGER + EAGER_CALIBRATING (globals, propagate to here)
  enforce_eager="$ENFORCE_EAGER"
  # Cgroup headroom above NEED: from the measured peak of the mode we're about to run (eager peak for
  # an eager run, CUDA-graph peak for a graph run). A non-numeric value — "" (no measurement) or "oom",
  # or a calibration attempt with no graph peak yet — falls back to the generous default, so the cap
  # never OOMs an attempt before we've learned its real peak.
  local headroom_gb cudagraph_oomed=0 mode_peak=""
  if [[ "$enforce_eager" == "1" ]]; then mode_peak="${WARMUP_PEAK_EAGER_GB:-}"; else mode_peak="${WARMUP_PEAK_CUDAGRAPH_GB:-}"; fi
  headroom_gb=$(awk -v p="$mode_peak" -v n="$NEED_GB" -v d="$WARMUP_HEADROOM_GB" \
    'BEGIN{ if(p+0<=0){ printf "%d", d; exit } h=p-n; if(h<4)h=4; printf "%.0f", h }')
  [[ "${EAGER_CALIBRATING:-0}" == "1" ]] && info "Calibrating: trying CUDA graphs once to measure the real peak (auto-falls back to eager if it doesn't fit)."
  local vllm_args=() docker_cmd=() mem_limit_mib=""
  build_launch

  # Memory accounting breakdown (shown in dry-run and at launch).
  local reserved free
  reserved=$(reserved_budget_gb "$cname")
  free=$(awk -v b="$(usable_budget "$reserved")" -v r="$reserved" 'BEGIN{ printf "%.1f", b-r }')
  print_memory_plan "$model" "$cname" "$port" "$reserved" "$free"

  if [[ "$dry_run" == "1" ]]; then
    print_launch_explain
    printf "${DIM}# Docker command that would be executed:${NC}\n"
    shell_join "${docker_cmd[@]}" "${vllm_args[@]}"
    printf "\n"
    return 0
  fi

  info "Serving up to ${seqs} concurrent requests. Raise with --max-num-seqs N (uses more memory)."

  # Supervised adaptive launch: start the container, wait until it serves, and auto-retry
  # recoverable startup failures. Levers: lower $seqs (concurrency) for cache-block errors;
  # flip $enforce_eager (removes the torch.compile/CUDA-graph startup peak) on a warmup OOM.
  local attempt=0 serve_state="nowait"
  while : ; do
    docker rm -f "$cname" >/dev/null 2>&1 || true
    printf "\n"
    local run_log run_exit=0
    run_log=$(mktemp)
    "${docker_cmd[@]}" "${vllm_args[@]}" >"$run_log" 2>&1 || run_exit=$?
    if [[ "$run_exit" -ne 0 ]]; then
      err "docker run failed (exit $run_exit)"
      if docker logs "$cname" >/dev/null 2>&1; then
        printf "    ${DIM}Last logs:${NC}\n"
        docker logs --tail 10 "$cname" 2>&1 | sed 's/^/    /'
      elif [[ -s "$run_log" ]]; then
        printf "    ${DIM}Output:${NC}\n"
        tail -10 "$run_log" | sed 's/^/    /'
      fi
      rm -f "$run_log"
      exit 1
    fi
    rm -f "$run_log"

    if [[ "$no_wait" == "1" ]]; then
      serve_state="nowait"
      break
    fi

    printf "  Starting %s — waiting for it to serve (up to %ss)...\n" "$cname" "$STARTUP_TIMEOUT"
    local status
    status=$(await_startup "$cname" "$port" "$STARTUP_TIMEOUT")
    case "$status" in
      ready)
        serve_state="ready"; break ;;
      timeout)
        serve_state="timeout"; break ;;
      exit:mamba:*)
        local n="${status##*:}"
        if [[ "$attempt" -lt "$STARTUP_MAX_RETRIES" && "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -lt "$seqs" ]]; then
          attempt=$((attempt + 1)); seqs="$n"
          info "This size only fits ${n} concurrent requests — retrying with --max-num-seqs ${n}."
          build_launch
          continue
        fi
        err "vLLM couldn't start within the concurrency this size allows."
        docker logs --tail 15 "$cname" 2>&1 | sed 's/^/    /'
        exit 1 ;;
      exit:oom)
        # The startup peak (torch.compile + CUDA-graph capture) overflowed the container cap. The
        # principled fix is --enforce-eager: it removes that peak entirely (no graph capture).
        if [[ "$attempt" -lt "$STARTUP_MAX_RETRIES" && "$enforce_eager" != "1" ]]; then
          attempt=$((attempt + 1)); enforce_eager=1; cudagraph_oomed=1
          info "Startup peak too big — retrying with --enforce-eager (no CUDA graphs; ~10-20% slower)."
          build_launch
          continue
        fi
        err "Startup peak exceeds the memory budget for ${model}, even with --enforce-eager."
        printf "    Reduce context (--max-len), free memory (spark stop <model>), or use a smaller model.\n"
        exit 1 ;;
      *)
        err "vLLM failed to start."
        docker logs --tail 15 "$cname" 2>&1 | sed 's/^/    /'
        exit 1 ;;
    esac
  done

  # Learn the real startup peak (exact cgroup high-water mark) and cache it for next time, so future
  # launches size the headroom / enforce-eager from a measured fact instead of a guess.
  if [[ "$serve_state" == "ready" ]]; then
    local measured
    measured=$(container_peak_gb "$cname")
    [[ -n "$measured" ]] && save_warmup_peak "$model" "$measured" "$enforce_eager" "$cudagraph_oomed"
  fi

  printf "\n  Container '${BOLD}%s${NC}' started." "$cname"
  case "$serve_state" in
    ready)
      printf " ${GREEN}✓ serving${NC}\n  Test: ${DIM}curl localhost:%s/v1/models${NC}\n\n" "$port" ;;
    timeout)
      printf "\n  ${YELLOW}⊘${NC} Still warming up after ${STARTUP_TIMEOUT}s — it may still come up. Follow: ${BOLD}spark logs %s${NC}\n\n" "$model" ;;
    *)
      printf "\n  Logs: ${BOLD}spark logs %s${NC}  ·  Test: ${DIM}curl localhost:%s/v1/models${NC}\n\n" "$model" "$port" ;;
  esac

  # Auto-restart gateway if running so it picks up the new model
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${GATEWAY_CONTAINER}$"; then
    gateway_restart
  fi

  if [[ "$tail_logs" == "1" ]]; then
    docker logs -f "$cname"
  fi
}

# Is the local Ollama service answering on :11434?
ollama_reachable() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 http://localhost:11434/api/version >/dev/null 2>&1
  else
    ollama list >/dev/null 2>&1
  fi
}

# Best-effort human-readable size of a pulled Ollama model (advisory only).
ollama_model_size() {
  ollama list 2>/dev/null | awk -v m="$1" 'NR>1 && $1==m {print $3" "$4; exit}'
}

# Model weights size in GiB, parsed from `ollama list` (e.g. "18 GB" -> 18.0).
ollama_weights_gb() {
  local s; s=$(ollama_model_size "$1")
  awk -v s="$s" 'BEGIN{ n=s+0; if (s ~ /[Mm]B/) n=n/1024; else if (s ~ /[Tt]B/) n=n*1024; printf "%.1f", n }'
}

# Estimate KV cache (GiB) for an Ollama model at `ctx` tokens, parsing the GGUF metadata
# that `ollama show` prints. Echoes a number, or nothing if the fields aren't available.
ollama_arch_kv() {
  local m="$1" ctx="$2" info layers kvh kdim
  info=$(ollama show "$m" 2>/dev/null) || return 0
  layers=$(printf '%s\n' "$info" | grep -iE 'block_count'   | grep -oE '[0-9]+' | head -1)
  kvh=$(printf '%s\n' "$info"    | grep -iE 'head_count_kv' | grep -oE '[0-9]+' | head -1)
  kdim=$(printf '%s\n' "$info"   | grep -iE 'key_length|head_dim' | grep -oE '[0-9]+' | head -1)
  is_positive_int "$layers" && is_positive_int "$kvh" && is_positive_int "$kdim" || return 0
  awk -v L="$layers" -v H="$kvh" -v D="$kdim" -v T="$ctx" 'BEGIN{ printf "%.1f", (2*L*H*D*2*T)/1073741824 }'
}

# Enable the Ollama provider in the gateway config and refresh it if running.
gateway_enable_ollama() {
  local config
  config=$(gateway_load_config)
  config=$(printf '%s' "$config" | jq '.providers.ollama.enabled = true' 2>/dev/null) || return 0
  gateway_save_config "$config"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${GATEWAY_CONTAINER}$"; then
    gateway_restart
  fi
}

# Ollama (native) — used on Apple Silicon and CPU hosts. Reads cmd_run's flag locals.
# Ollama multiplexes models on one port (11434) and loads them on demand, so there is
# no per-model container, port, or GPU-memory fraction; it manages memory itself.
run_backend_ollama() {
  is_ollama_ref "$model" || die "Invalid model reference: $model" "Use an Ollama model like 'qwen3:30b' or 'hf.co/<repo>:Q4_K_M'"

  # vLLM-only flags don't apply here — warn instead of silently ignoring them.
  local ignored=()
  [[ -n "$mem" ]]      && ignored+=(--mem)
  [[ -n "$max_len" ]]  && ignored+=(--max-len)
  [[ -n "$kv_dtype" ]] && ignored+=(--kv-cache-dtype)
  [[ -n "$port" ]]     && ignored+=(--port)
  [[ ${#ignored[@]} -gt 0 ]] && warn "Ignoring vLLM-only flag(s) on the Ollama backend: ${ignored[*]}"

  if [[ "$dry_run" == "1" ]]; then
    printf "\n  ${BOLD}%s${NC}  ${DIM}(ollama)${NC}\n" "$model"
    printf "    Engine:    Ollama (manages memory automatically; %s GB total)\n" "$TOTAL_MEM_GB"
    printf "    Route:     gateway ${BOLD}ollama_chat/%s${NC} → http://localhost:11434\n" "$model"
    printf "${DIM}# Commands that would run:${NC}\n"
    printf "ollama pull %s\n" "$model"
    printf "spark gateway add ollama\n\n"
    return 0
  fi

  command -v ollama >/dev/null 2>&1 || die "Ollama is not installed" "Set up this machine first: spark setup"
  ollama_reachable || warn "Ollama service not reachable on :11434 — is it running? (try: ollama serve)"

  # Pull unless already present (or --no-pull).
  if ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$model"; then
    info "Model '${model}' already pulled"
  elif [[ "$no_pull" == "1" ]]; then
    die "Model '${model}' is not pulled" "Remove --no-pull, or run: ollama pull ${model}"
  else
    printf "  Pulling ${BOLD}%s${NC} with Ollama...\n" "$model"
    ollama pull "$model" || die "ollama pull failed for ${model}"
  fi

  local osize
  osize=$(ollama_model_size "$model")
  [[ -n "$osize" ]] && printf "  ${DIM}Size: %s (Ollama loads on demand)${NC}\n" "$osize"

  # Advisory capacity estimate at Ollama's default context (num_ctx 4096). Ollama offloads
  # layers to CPU if it doesn't fit (it doesn't fail), so this warns + confirms, not blocks.
  local ow okv oest
  ow=$(ollama_weights_gb "$model")
  okv=$(ollama_arch_kv "$model" 4096)
  if [[ -n "$okv" ]]; then
    oest=$(awk -v w="$ow" -v k="$okv" 'BEGIN{ printf "%.1f", (w+k)*1.05 }')
  else
    oest=$(awk -v w="$ow" 'BEGIN{ printf "%.1f", w*1.15 }')   # KV unknown — weights + cushion
  fi
  if awk -v e="$oest" -v b="$BUDGET_GB" 'BEGIN{ exit !(b > 0 && e > b) }'; then
    warn "Estimated ~${oest} GB at 4096 ctx, above ~${BUDGET_GB} GB usable — Ollama will offload layers to CPU (slower)."
    if ! confirm "Continue anyway?"; then
      printf "    Aborted. Model stays downloaded; free memory or use a smaller model.\n"
      exit 0
    fi
  fi

  # Route it through the gateway (enable provider + refresh if running).
  gateway_enable_ollama

  printf "\n"
  printf "  Model ${BOLD}%s${NC} ready via Ollama.\n" "$model"
  printf "  Gateway: ${DIM}call it as ${NC}${BOLD}ollama_chat/%s${NC}${DIM} on http://localhost:%s/v1${NC}\n\n" "$model" "$GATEWAY_PORT"

  [[ "$tail_logs" == "1" ]] && warn "--tail has no effect on the Ollama backend (Ollama runs as a shared service)"
  return 0
}

# Print the per-model memory accounting + machine-level totals.
print_memory_plan() {
  local model="$1" cname="$2" port="$3" reserved="$4" free="$5"
  local type_desc="Text"
  [[ "${IS_MULTIMODAL:-false}" == "true" ]] && type_desc="Multimodal"

  printf "\n  ${BOLD}%s${NC}  ${DIM}(%s)${NC}\n" "$model" "$cname"
  printf "    Type:      %s\n" "$type_desc"
  printf "    Context:   %s tokens" "$MAX_MODEL_LEN"
  [[ "$KV_CACHE_DTYPE" == "fp8" ]] && printf "  (KV cache: fp8)"
  printf "\n"
  printf "    Weights:   %s GB\n" "$WEIGHTS_GB"
  printf "    KV cache:  %s GB\n" "$KV_GB"
  printf "    ${BOLD}Need:${NC}      %s GB  →  --gpu-memory-utilization %s\n" "$NEED_GB" "$GPU_MEM_UTIL"
  [[ -n "${mem_limit_mib:-}" ]] && printf "    Limit:     %s MiB  (cgroup cap = NEED + %s GB warmup headroom)\n" "$mem_limit_mib" "${headroom_gb:-?}"
  [[ -n "${seqs:-}" ]] && printf "    Concur.:   %s requests  (max-num-seqs)\n" "$seqs"
  [[ "${enforce_eager:-0}" == "1" ]] && printf "    Eager:     on  (CUDA graphs disabled — smaller startup peak)\n"
  printf "    API:       http://localhost:%s/v1\n" "$port"
  [[ -n "$REASONING_PARSER" ]] && printf "    Reasoning: %s parser\n" "$REASONING_PARSER"
  if [[ "$ACCEL" == "cuda-discrete" ]]; then
    printf "    ${DIM}GPU:       %s GB VRAM · %s headroom · %s reserved by models · %s free${NC}\n" \
      "$TOTAL_MEM_GB" "$OS_RESERVE_GB" "$reserved" "$free"
  else
    printf "    ${DIM}Machine:   %s GB total · %s OS-reserved · %s reserved by models · %s free${NC}\n" \
      "$TOTAL_MEM_GB" "$OS_RESERVE_GB" "$reserved" "$free"
  fi
  if [[ "$MEM_DETECT_FALLBACK" == "1" ]]; then
    warn "Could not read system memory — using fallback ${TOTAL_MEM_GB} GB (set SPARK_TOTAL_MEM_GB to correct)"
  fi
  return 0
}

# Stop one managed container by name; print the freed reservation.
stop_one_container() {
  local name="$1"
  local need
  need=$(docker inspect "$name" --format '{{ index .Config.Labels "spark.need_gb" }}' 2>/dev/null || echo "")
  docker stop "$name" >/dev/null 2>&1
  docker rm "$name" >/dev/null 2>&1 || true
  if [[ "$need" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    info "Stopped ${name} (freed ${need} GB)"
  else
    info "Stopped ${name}"
  fi
}

# spark stop [<model>|--all] — no arg stops the only running model (legacy behavior).
# spark stop on the Ollama backend: unload models from memory (Ollama keeps them on disk).
cmd_stop_ollama() {
  local target="$1" m loaded=()
  command -v ollama >/dev/null 2>&1 || die "Ollama is not installed"
  while read -r m; do [[ -n "$m" ]] && loaded+=("$m"); done < <(ollama ps 2>/dev/null | awk 'NR>1{print $1}')

  if [[ "$target" == "--all" ]]; then
    [[ ${#loaded[@]} -eq 0 ]] && { warn "No models loaded"; return 0; }
    for m in "${loaded[@]}"; do ollama stop "$m" >/dev/null 2>&1 && info "Unloaded ${m}"; done
  elif [[ -n "$target" ]]; then
    if ollama stop "$target" >/dev/null 2>&1; then info "Unloaded ${target}"; else warn "Model '${target}' was not loaded"; fi
  elif [[ ${#loaded[@]} -eq 0 ]]; then
    warn "No models loaded"
  elif [[ ${#loaded[@]} -gt 1 ]]; then
    err "Multiple models loaded — specify which to stop"
    printf "    %s\n" "$(IFS=', '; echo "${loaded[*]}")"
    exit 1
  else
    ollama stop "${loaded[0]}" >/dev/null 2>&1 && info "Unloaded ${loaded[0]}"
  fi
}

cmd_stop() {
  local target="${1:-}"

  if [[ "$BACKEND" == "ollama" ]]; then
    cmd_stop_ollama "$target"
    return
  fi

  # Collect running managed containers.
  local names=()
  while IFS=$'\t' read -r name _; do
    [[ -n "$name" ]] && names+=("$name")
  done < <(list_managed_containers)
  # Include a legacy/unlabelled spark-vllm container if present.
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    local seen=0 n
    for n in "${names[@]:-}"; do [[ "$n" == "$CONTAINER_NAME" ]] && seen=1; done
    [[ "$seen" -eq 0 ]] && names+=("$CONTAINER_NAME")
  fi

  if [[ ${#names[@]} -eq 0 ]]; then
    warn "No running models"
    return 0
  fi

  if [[ "$target" == "--all" ]]; then
    local n
    for n in "${names[@]}"; do stop_one_container "$n"; done
  elif [[ -n "$target" ]]; then
    local name cand n
    name=$(container_for_ref "$target" 2>/dev/null || true)
    if [[ -z "$name" ]]; then
      # Fall back to matching the derived container name.
      cand=$(container_name_for_model "$target")
      for n in "${names[@]}"; do [[ "$n" == "$cand" || "$n" == "$target" ]] && name="$n"; done
    fi
    if [[ -z "$name" ]]; then
      err "No running model matches '${target}'"
      printf "    Running: %s\n" "$(IFS=', '; echo "${names[*]}")"
      exit 1
    fi
    stop_one_container "$name"
  else
    # No argument: only safe when exactly one model is running.
    if [[ ${#names[@]} -gt 1 ]]; then
      err "Multiple models running — specify which to stop"
      printf "    %s\n" "$(IFS=', '; echo "${names[*]}")"
      printf "    Stop one: ${BOLD}spark stop <model>${NC}   ·   Stop all: ${BOLD}spark stop --all${NC}\n"
      exit 1
    fi
    stop_one_container "${names[0]}"
  fi

  # Refresh the gateway so its routing reflects the remaining models.
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${GATEWAY_CONTAINER}$"; then
    gateway_restart
  fi
}

cmd_pull() {
  local model="${1:-}"
  [[ -z "$model" ]] && die "No model specified" "Usage: spark pull <model>"
  validate_model_ref_for_backend "$model"

  if [[ "$BACKEND" == "ollama" ]]; then
    is_ollama_ref "$model" || die "Invalid model reference: $model" "Use an Ollama model like 'qwen3:30b'"
    command -v ollama >/dev/null 2>&1 || die "Ollama is not installed" "Set up this machine first: spark setup"
    printf "\n  Pulling %s with Ollama...\n\n" "$model"
    ollama pull "$model"
    printf "\n"
    info "Ready. Run: spark run ${model}"
    printf "\n"
    return 0
  fi

  is_safe_model_ref "$model" || die "Invalid model reference: $model" "Use a HuggingFace model like org/name"
  printf "\n  Downloading %s...\n\n" "$model"
  hf download "$model"
  printf "\n"
  info "Ready. Run: spark run ${model}"
  printf "\n"
}

MODEL_LIST_MODELS=()
MODEL_LIST_SIZES=()
MODEL_LIST_AGES=()
MODEL_LIST_BYTES=()
MODEL_LIST_STATUS=()

model_cache_complete() {
  local model_dir="$1"
  [[ -d "${model_dir}/snapshots" ]] || return 1
  find "${model_dir}/snapshots" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -q . || return 1
  ! find "$model_dir" \( -name '*.incomplete' -o -name '*.lock' \) -print -quit 2>/dev/null | grep -q .
}

collect_downloaded_models() {
  MODEL_LIST_MODELS=()
  MODEL_LIST_SIZES=()
  MODEL_LIST_AGES=()
  MODEL_LIST_BYTES=()
  MODEL_LIST_STATUS=()
  local cache_dir="${HF_CACHE_DIR}/hub"
  [[ -d "$cache_dir" ]] || return 0

  local model_dir dirname model_name size_bytes size_gb mod_time age now diff status
  for model_dir in "$cache_dir"/models--*; do
    [[ -d "$model_dir" ]] || continue
    dirname=$(basename "$model_dir")
    model_name=$(echo "$dirname" | sed 's/^models--//' | sed 's/--/\//g')
    size_bytes=$(du -sb "$model_dir" 2>/dev/null | awk '{print $1}' || \
                 du -sk "$model_dir" 2>/dev/null | awk '{print $1 * 1024}')
    size_gb=$(awk "BEGIN {printf \"%.1f GB\", ${size_bytes:-0}/1073741824}")
    mod_time=$(find "$model_dir" -maxdepth 2 -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1 || \
               stat -f%m "$model_dir" 2>/dev/null || echo "0")
    age="unknown"
    if [[ -n "$mod_time" && "$mod_time" != "0" ]]; then
      now=$(date +%s)
      diff=$(( now - ${mod_time%.*} ))
      if (( diff < 86400 )); then
        age="today"
      elif (( diff < 172800 )); then
        age="yesterday"
      elif (( diff < 604800 )); then
        age="$(( diff / 86400 )) days ago"
      else
        age="$(( diff / 604800 )) weeks ago"
      fi
    fi
    if model_cache_complete "$model_dir"; then status="complete"; else status="partial"; fi
    MODEL_LIST_MODELS+=("$model_name")
    MODEL_LIST_SIZES+=("$size_gb")
    MODEL_LIST_AGES+=("$age")
    MODEL_LIST_BYTES+=("${size_bytes:-0}")
    MODEL_LIST_STATUS+=("$status")
  done
}

cmd_list() {
  printf "\n"
  collect_downloaded_models
  if [[ ${#MODEL_LIST_MODELS[@]} -eq 0 ]]; then
    warn "No models downloaded yet"
    printf "    Download one with: spark pull <model>\n\n"
    return 0
  fi

  printf "  ${BOLD}%-45s %-10s %-10s %s${NC}\n" "MODEL" "SIZE" "STATUS" "UPDATED"
  local total_size=0 i
  for i in "${!MODEL_LIST_MODELS[@]}"; do
    printf "  %-45s %-10s %-10s %s\n" "${MODEL_LIST_MODELS[$i]}" "${MODEL_LIST_SIZES[$i]}" "${MODEL_LIST_STATUS[$i]}" "${MODEL_LIST_AGES[$i]}"
    total_size=$(( total_size + ${MODEL_LIST_BYTES[$i]:-0} ))
  done
  local total_gb
  total_gb=$(awk "BEGIN {printf \"%.1f\", ${total_size}/1073741824}")
  printf "\n  Total: %s GB in %d model(s)\n" "$total_gb" "${#MODEL_LIST_MODELS[@]}"
  printf "\n"
}

cmd_rm() {
  [[ "$#" -eq 0 ]] && die "No model specified" "Usage: spark rm <model> [model...]"

  local model model_dir size i
  local models=("$@")
  local model_dirs=()
  local sizes=()

  for model in "${models[@]}"; do
    is_safe_model_ref "$model" || die "Invalid model reference: $model" "Use a HuggingFace model like org/name"
    model_dir="$(model_cache_dir "$model")"
    if [[ ! -d "$model_dir" ]]; then
      die "Model '${model}' not found in cache"
    fi
    size=$(du -sh "$model_dir" 2>/dev/null | awk '{print $1}')
    model_dirs+=("$model_dir")
    sizes+=("${size:-unknown size}")
  done

  if [[ "${#models[@]}" -eq 1 ]]; then
    if ! confirm "Remove ${models[0]} (${sizes[0]})? This cannot be undone."; then
      warn "Cancelled"
      return 0
    fi
  else
    printf "\n  Models to remove:\n"
    for i in "${!models[@]}"; do
      printf "    - %s (%s)\n" "${models[$i]}" "${sizes[$i]}"
    done
    if ! confirm "Remove ${#models[@]} models? This cannot be undone."; then
      warn "Cancelled"
      return 0
    fi
  fi

  local failed=0 rm_out
  for i in "${!models[@]}"; do
    rm_out=""
    if rm_out=$(rm -rf "${model_dirs[$i]}" 2>&1); then
      info "Removed ${models[$i]}"
    else
      failed=1
      err "Failed to remove ${models[$i]}"
      [[ -n "$rm_out" ]] && printf "    %s\n" "$rm_out"
      printf "    Cache path: %s\n" "${model_dirs[$i]}"
      printf "    Fix ownership/permissions manually, then retry.\n"
    fi
  done
  return "$failed"
}

# Human uptime for a running container.
container_uptime() {
  local name="$1" started_at
  started_at=$(docker inspect "$name" --format '{{.State.StartedAt}}' 2>/dev/null || echo "")
  if [[ -n "$started_at" ]]; then
    local start_epoch now_epoch diff_s
    start_epoch=$(date -d "$started_at" +%s 2>/dev/null || date -jf "%Y-%m-%dT%H:%M:%S" "${started_at%%.*}" +%s 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    diff_s=$(( now_epoch - start_epoch ))
    printf '%dh %dm' "$(( diff_s / 3600 ))" "$(( (diff_s % 3600) / 60 ))"
  else
    printf 'unknown'
  fi
}

# spark status on the Ollama backend: list pulled + loaded models and the gateway route.
print_system_overview() {
  printf "  ${BOLD}System${NC}\n"
  dashboard_row ok "spark" "v${VERSION}"
  dashboard_row ok "platform" "${SPARK_OS}/${SPARK_ARCH} · ${ACCEL} · backend ${BACKEND}"
  dashboard_row ok "memory budget" "${TOTAL_MEM_GB} GB total · ${OS_RESERVE_GB} reserved · ${BUDGET_GB} usable"
  return 0
}

print_setup_overview() {
  local summary state="partial"
  summary=$(setup_status_summary)
  [[ "$summary" == */* && "$summary" != *"missing:"* ]] && state="ok"
  printf "\n  ${BOLD}Setup${NC}\n"
  dashboard_row "$state" "prerequisites" "$summary"
  if [[ "$BACKEND" == "vllm" ]]; then
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
      dashboard_row ok "GPU" "$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1 || echo detected)"
    else
      dashboard_row missing "GPU" "not detected"
    fi
    if [[ -n "$(detect_ngc_image)" ]]; then dashboard_row ok "vLLM image" "$(detect_ngc_image)"; else dashboard_row missing "vLLM image" "run spark setup"; fi
  else
    if command -v ollama >/dev/null 2>&1; then dashboard_row ok "Ollama" "$(ollama --version 2>/dev/null | head -1 || echo installed)"; else dashboard_row missing "Ollama" "run spark setup"; fi
    if ollama_reachable; then dashboard_row ok "Ollama API" "http://localhost:11434"; else dashboard_row missing "Ollama API" "not reachable"; fi
  fi
  return 0
}

print_services_overview() {
  local gw_state="stopped" gw_detail ws_count
  printf "\n  ${BOLD}Services${NC}\n"
  if gateway_running_state; then gw_state="running"; fi
  gw_detail="port $(gateway_configured_port) · providers $(gateway_provider_list)"
  dashboard_row "$gw_state" "LiteLLM gateway" "$gw_detail"
  if docker_running; then dashboard_row ok "Docker" "running"; else dashboard_row missing "Docker" "not running"; fi
  if workspace_configured; then
    ws_count=$(workspace_service_count)
    if [[ "$ws_count" -gt 0 ]]; then dashboard_row running "Workspace compose" "${ws_count} service(s) running"; else dashboard_row stopped "Workspace compose" "configured, no running services"; fi
  else
    dashboard_row missing "Workspace compose" "not configured"
  fi
  if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
    dashboard_row ok "Tailscale" "connected"
  elif command -v tailscale >/dev/null 2>&1; then
    dashboard_row warn "Tailscale" "installed, not connected"
  else
    dashboard_row missing "Tailscale" "not installed"
  fi
  return 0
}

print_vllm_model_table() {
  local models=() needs=() wts=() kvs=() ports=() ups=() cnames=()
  local reserved=0 maxw=5 name model port need wt kv
  while IFS=$'\t' read -r name model port need wt kv; do
    [[ -z "$name" ]] && continue
    model="${model:-unknown}"
    models+=("$model"); needs+=("${need:-?}"); wts+=("${wt:-?}"); kvs+=("${kv:-?}")
    ports+=("${port:-?}"); ups+=("$(container_uptime "$name")"); cnames+=("$name")
    [[ "${need:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] && reserved=$(awk -v a="$reserved" -v b="$need" 'BEGIN{printf "%.1f", a+b}')
    [[ ${#model} -gt $maxw ]] && maxw=${#model}
  done < <(list_managed_containers)

  if [[ ${#models[@]} -eq 0 ]]; then
    dashboard_row missing "vLLM models" "none running"
    return 0
  fi

  printf "  ${DIM}%-${maxw}s  %6s  %7s  %6s  %5s  %-8s${NC}\n" "MODEL" "NEED" "WEIGHTS" "KV" "PORT" "UP"
  local i
  for i in "${!models[@]}"; do
    printf "  %-${maxw}s  %6s  %7s  %6s  %5s  %-8s\n" \
      "${models[$i]}" "${needs[$i]}" "${wts[$i]}" "${kvs[$i]}" "${ports[$i]}" "${ups[$i]}"
  done
  local free
  free=$(awk -v b="$BUDGET_GB" -v r="$reserved" 'BEGIN{printf "%.1f", b-r}')
  printf "  ${DIM}Memory (GB): %s total · %s OS · %s reserved · %s free${NC}\n" "$TOTAL_MEM_GB" "$OS_RESERVE_GB" "$reserved" "$free"

  local host_line now pk
  host_line=$(free -g 2>/dev/null | awk '
    /^Mem:/  { m=sprintf("RAM %d/%d GB used · %d avail", $3, $2, $7) }
    /^Swap:/ { if ($2+0>0) s=sprintf("swap %d/%d GB", $3, $2) }
    END      { if (m!="") printf "%s%s", m, (s!="" ? " · " s : "") }')
  [[ -n "$host_line" ]] && printf "  ${DIM}Live:        %s${NC}\n" "$host_line"
  for i in "${!models[@]}"; do
    now=$(container_current_gb "${cnames[$i]}"); pk=$(container_peak_gb "${cnames[$i]}")
    [[ -z "$now" && -z "$pk" ]] && continue
    printf "  ${DIM}  %-${maxw}s  reserved %s · now %s · peak %s GB${NC}\n" \
      "${models[$i]}" "${needs[$i]}" "${now:-—}" "${pk:-—}"
  done
  return 0
}

print_ollama_model_table() {
  if ! command -v ollama >/dev/null 2>&1; then
    dashboard_row missing "Ollama models" "Ollama not installed"
    return 0
  fi
  local rows loaded
  rows=$(ollama list 2>/dev/null | awk 'NR>1{printf "  %-32s %s %s\n", $1, $3, $4}' || true)
  if [[ -z "$rows" ]]; then
    dashboard_row missing "Ollama models" "none pulled"
  else
    printf "  ${DIM}%-32s %s${NC}\n" "MODEL" "SIZE"
    printf "%s\n" "$rows"
  fi
  loaded=$(ollama ps 2>/dev/null | awk 'NR>1{print $1}' | tr '\n' ' ' || true)
  [[ -n "${loaded// /}" ]] && printf "  ${DIM}Loaded now: %s${NC}\n" "$loaded"
  return 0
}

print_models_overview() {
  printf "\n  ${BOLD}Models${NC}\n"
  if [[ "$BACKEND" == "ollama" ]]; then
    print_ollama_model_table
  else
    print_vllm_model_table
    dashboard_row ok "HF cache" "$(count_downloaded_hf_models) downloaded model(s)"
  fi
  return 0
}

print_workspace_overview() {
  local vikunja_url="" n8n_url="" hermes_url="" mode="" model=""
  printf "\n  ${BOLD}Agent workspace${NC}\n"
  if ! workspace_configured; then
    dashboard_row missing "workspace" "not configured"
    return 0
  fi
  vikunja_url=$(workspace_read_env VIKUNJA_URL 2>/dev/null || true)
  n8n_url=$(workspace_read_env N8N_URL 2>/dev/null || true)
  hermes_url=$(workspace_read_env HERMES_URL 2>/dev/null || true)
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  model=$(workspace_read_env HERMES_MODEL 2>/dev/null || true)
  dashboard_row ok "workspace" "configured (${mode:-unknown} mode)"
  dashboard_row ok "Hermes model" "${model:-unset}"
  dashboard_row ok "Vikunja" "${vikunja_url:-unset}"
  dashboard_row ok "n8n" "${n8n_url:-unset}"
  dashboard_row ok "Hermes" "${hermes_url:-unset}"
  return 0
}
