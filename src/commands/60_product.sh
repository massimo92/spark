cmd_models_recommend() {
  local json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      -h|--help)
        printf "\n  ${BOLD}Usage:${NC} spark models recommend [--json]\n\n"
        return 0 ;;
      *) die "Unknown models recommend flag: $1" ;;
    esac
  done

  local pool="$TOTAL_MEM_GB" pool_label="system RAM"
  [[ "$ACCEL" == "cuda-discrete" ]] && pool_label="GPU VRAM"

  if [[ "$json" == "1" ]]; then
    if [[ "$BACKEND" == "ollama" ]]; then
      jq -n --arg backend "$BACKEND" --arg accel "$ACCEL" --arg mem "$pool" \
        '{backend:$backend, accelerator:$accel, memory_gb:($mem|tonumber), recommendations:[
          {model:"qwen3:8b", fit:"safe", command:"spark run qwen3:8b"},
          {model:"qwen3:14b", fit:"balanced", command:"spark run qwen3:14b"},
          {model:"qwen3:30b", fit:"large", command:"spark run qwen3:30b"}]}'
    else
      jq -n --arg backend "$BACKEND" --arg accel "$ACCEL" --arg mem "$pool" \
        '{backend:$backend, accelerator:$accel, memory_gb:($mem|tonumber), recommendations:[
          {model:"Qwen/Qwen3-14B", fit:"safe", command:"spark run Qwen/Qwen3-14B"},
          {model:"Qwen/Qwen3-30B-A3B", fit:"balanced", command:"spark run Qwen/Qwen3-30B-A3B"},
          {model:"RedHatAI/Qwen3.6-35B-A3B-NVFP4", fit:"large", command:"spark run RedHatAI/Qwen3.6-35B-A3B-NVFP4"}]}'
    fi
    return 0
  fi

  printf "\n  ${BOLD}Recommended models${NC}\n"
  printf "  Hardware: %s/%s · %s · %s GB %s\n\n" "$SPARK_OS" "$SPARK_ARCH" "$ACCEL" "$pool" "$pool_label"

  if [[ "$BACKEND" == "ollama" ]]; then
    printf "  ${DIM}%-32s %-10s %s${NC}\n" "MODEL" "FIT" "WHY"
    if [[ "$pool" -lt 16 ]]; then
      printf "  %-32s %-10s %s\n" "qwen3:4b" "safe" "small daily assistant"
      printf "  %-32s %-10s %s\n" "llama3.2:3b" "safe" "fast low-memory fallback"
    elif [[ "$pool" -lt 32 ]]; then
      printf "  %-32s %-10s %s\n" "qwen3:8b" "safe" "good default on modest RAM"
      printf "  %-32s %-10s %s\n" "qwen3:14b" "stretch" "better quality, more memory"
    else
      printf "  %-32s %-10s %s\n" "qwen3:14b" "safe" "balanced daily agent"
      printf "  %-32s %-10s %s\n" "qwen3:30b" "balanced" "stronger reasoning on 32GB+"
      printf "  %-32s %-10s %s\n" "deepseek-r1:14b" "task" "reasoning-heavy workflows"
    fi
    printf "\n  Start: ${BOLD}spark run qwen3:14b${NC}\n"
    printf "  API:   ${BOLD}ollama_chat/<model>${NC} through the gateway\n\n"
  else
    printf "  ${DIM}%-42s %-10s %s${NC}\n" "MODEL" "FIT" "WHY"
    if [[ "$pool" -lt 48 ]]; then
      printf "  %-42s %-10s %s\n" "Qwen/Qwen3-14B" "safe" "fits smaller NVIDIA pools"
      printf "  %-42s %-10s %s\n" "Qwen/Qwen2.5-Coder-14B-Instruct" "task" "coding-heavy agent work"
    elif [[ "$pool" -lt 96 ]]; then
      printf "  %-42s %-10s %s\n" "Qwen/Qwen3-30B-A3B" "balanced" "general agent default"
      printf "  %-42s %-10s %s\n" "Qwen/Qwen2.5-Coder-32B-Instruct" "task" "coding-heavy agent work"
    else
      printf "  %-42s %-10s %s\n" "RedHatAI/Qwen3.6-35B-A3B-NVFP4" "balanced" "NVFP4 path for NVIDIA"
      printf "  %-42s %-10s %s\n" "Qwen/Qwen3-30B-A3B" "safe" "strong general fallback"
      printf "  %-42s %-10s %s\n" "nvidia/Llama-4-Scout-17B-16E-Instruct-NVFP4" "large" "second high-end option"
    fi
    printf "\n  Start: ${BOLD}spark run Qwen/Qwen3-30B-A3B${NC}\n"
    printf "  If it does not fit, spark will suggest context/fp8 alternatives.\n\n"
  fi
}

cmd_models() {
  local subcmd="${1:-recommend}"
  [[ -n "$subcmd" ]] && shift || true
  case "$subcmd" in
    recommend) cmd_models_recommend "$@" ;;
    help|--help|-h)
      printf "\n  ${BOLD}Usage:${NC} spark models <recommend>\n\n"
      printf "  Commands:\n    recommend    Suggest models for this hardware/backend\n\n" ;;
    *) die "Unknown models command: $subcmd" "Run 'spark models help'" ;;
  esac
}

nemohermes_rebuild_with_workspace_env() {
  local compatible_api_key base_url model configured_model dashboard_port policy_tier chat_ui_url

  compatible_api_key="${COMPATIBLE_API_KEY:-}"
  [[ -n "$compatible_api_key" ]] || compatible_api_key=$(workspace_read_env COMPATIBLE_API_KEY 2>/dev/null || true)
  [[ -n "$compatible_api_key" ]] || compatible_api_key=dummy

  base_url="${NEMOCLAW_ENDPOINT_URL:-$(workspace_read_env HERMES_LITELLM_BASE_URL 2>/dev/null || true)}"
  [[ -n "$base_url" ]] || base_url="http://127.0.0.1:${GATEWAY_PORT}/v1"

  model="${NEMOCLAW_MODEL:-$(workspace_read_env HERMES_LITELLM_MODEL 2>/dev/null || true)}"
  if [[ -z "$model" ]]; then
    configured_model=$(workspace_read_env HERMES_MODEL 2>/dev/null || true)
    [[ -n "$configured_model" ]] && model=$(workspace_litellm_model_name "$configured_model")
  fi

  dashboard_port="${NEMOCLAW_DASHBOARD_PORT:-$(workspace_read_env HERMES_DASHBOARD_PORT 2>/dev/null || true)}"
  [[ -n "$dashboard_port" ]] || dashboard_port="$WORKSPACE_HERMES_PORT"
  policy_tier="${NEMOCLAW_POLICY_TIER:-$(workspace_read_env HERMES_POLICY_TIER 2>/dev/null || true)}"
  [[ -n "$policy_tier" ]] || policy_tier=restricted
  chat_ui_url="${CHAT_UI_URL:-$(workspace_read_env HERMES_URL 2>/dev/null || true)}"

  local env_args=(
    "NEMOCLAW_AGENT=${NEMOCLAW_AGENT:-hermes}"
    "NEMOCLAW_NON_INTERACTIVE=${NEMOCLAW_NON_INTERACTIVE:-1}"
    "NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=${NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE:-1}"
    "NEMOCLAW_YES=${NEMOCLAW_YES:-1}"
    "NEMOCLAW_SANDBOX_NAME=hermes"
    "NEMOCLAW_PROVIDER=${NEMOCLAW_PROVIDER:-custom}"
    "NEMOCLAW_ENDPOINT_URL=${base_url}"
    "NEMOCLAW_PREFERRED_API=${NEMOCLAW_PREFERRED_API:-openai-completions}"
    "NEMOCLAW_DASHBOARD_PORT=${dashboard_port}"
    "NEMOCLAW_POLICY_TIER=${policy_tier}"
    "NEMOCLAW_POLICY_MODE=${NEMOCLAW_POLICY_MODE:-suggested}"
    "NEMOCLAW_LOCAL_INFERENCE_TIMEOUT=${NEMOCLAW_LOCAL_INFERENCE_TIMEOUT:-300}"
    "NEMOCLAW_SANDBOX_READY_TIMEOUT=${NEMOCLAW_SANDBOX_READY_TIMEOUT:-600}"
    "NEMOCLAW_NO_GPU=${NEMOCLAW_NO_GPU:-1}"
    "NEMOCLAW_SANDBOX_GPU=${NEMOCLAW_SANDBOX_GPU:-0}"
    "COMPATIBLE_API_KEY=${compatible_api_key}"
  )
  [[ -n "$model" ]] && env_args+=("NEMOCLAW_MODEL=${model}")
  [[ -n "$chat_ui_url" ]] && env_args+=("CHAT_UI_URL=${chat_ui_url}")

  env "${env_args[@]}" nemohermes hermes rebuild
}

cmd_update() {
  printf "\n"
  command -v curl >/dev/null 2>&1 || die "curl is required for updates"

  local did_update=0
  local spark_update=0 spark_remote_version=""
  local ngc_update=0 current_ngc="" current_tag="" latest_tag=""
  local gateway_update=0 gateway_config=""
  local postgres_update=0 vikunja_update=0 n8n_update=0
  local postgres_image="" vikunja_image="" n8n_image=""
  local nemohermes_update=0 nemohermes_status="" nemohermes_update_line=""
  local update_count=0

  printf "  Checking updates...\n"

  # --- spark CLI ---
  spark_remote_version=$(curl -fsSL --max-time 5 \
    "https://raw.githubusercontent.com/${GITHUB_REPO}/main/spark" 2>/dev/null \
    | grep -m1 '^VERSION=' | sed 's/VERSION="//' | sed 's/"//' || true)

  if [[ -z "$spark_remote_version" ]]; then
    warn "Could not check latest spark version"
  elif [[ "$spark_remote_version" == "$VERSION" ]]; then
    info "spark CLI is up to date (v${VERSION})"
  else
    spark_update=1
  fi

  # --- NGC vLLM container ---
  current_ngc=$(detect_ngc_image)
  [[ -n "$current_ngc" ]] && current_tag="${current_ngc##*:}"

  local year month m candidate
  year=$(date +%y)
  month=$(date +%m)
  for m in "$month" "$(printf '%02d' $(( 10#$month - 1 )))"; do
    [[ "$m" == "00" ]] && continue
    candidate="${year}.${m}-py3"
    if { [[ -z "$current_tag" ]] || ngc_vllm_tag_newer_than "$candidate" "$current_tag"; } && \
       docker manifest inspect "nvcr.io/nvidia/vllm:${candidate}" >/dev/null 2>&1; then
      latest_tag="$candidate"
      break
    fi
  done

  if [[ -z "$current_ngc" && -z "$latest_tag" ]]; then
    warn "No vLLM container found and could not detect latest"
  elif [[ -z "$latest_tag" ]]; then
    info "NGC vLLM is up to date (${current_tag})"
  else
    ngc_update=1
  fi

  # --- LiteLLM gateway image ---
  if command -v docker >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    gateway_config=$(gateway_load_config 2>/dev/null || echo '{}')
    if [[ "$(printf '%s' "$gateway_config" | jq -r '.enabled // false' 2>/dev/null)" == "true" ]]; then
      gateway_update=1
    fi
  fi

  # --- Workspace Compose images ---
  if [[ -f "$WORKSPACE_ENV_FILE" && -f "$WORKSPACE_COMPOSE_FILE" ]] && command -v docker >/dev/null 2>&1; then
    postgres_image=$(workspace_read_env WORKSPACE_POSTGRES_IMAGE 2>/dev/null || true)
    vikunja_image=$(workspace_read_env WORKSPACE_VIKUNJA_IMAGE 2>/dev/null || true)
    n8n_image=$(workspace_read_env WORKSPACE_N8N_IMAGE 2>/dev/null || true)
    [[ -n "$postgres_image" ]] && postgres_update=1
    [[ -n "$vikunja_image" ]] && vikunja_update=1
    [[ -n "$n8n_image" ]] && n8n_update=1
  fi

  # --- NemoHermes sandbox ---
  if command -v nemohermes >/dev/null 2>&1; then
    nemohermes_status=$(NEMOCLAW_SANDBOX_NAME=hermes nemohermes hermes status 2>/dev/null || \
      NEMOCLAW_SANDBOX_NAME=hermes nemohermes status 2>/dev/null || true)
    nemohermes_update_line=$(printf '%s\n' "$nemohermes_status" | grep -i 'update:.*available' | head -1 || true)
    [[ -n "$nemohermes_update_line" ]] && nemohermes_update=1
  fi

  update_count=$(( spark_update + ngc_update + gateway_update + postgres_update + vikunja_update + n8n_update + nemohermes_update ))

  printf "\n  Available update actions:\n"
  if [[ "$update_count" -eq 0 ]]; then
    printf "    none\n"
    printf "  No updates applied.\n\n"
    return 0
  fi
  [[ "$spark_update" -eq 1 ]] && printf "    - spark CLI: v%s → v%s\n" "$VERSION" "$spark_remote_version"
  if [[ "$ngc_update" -eq 1 ]]; then
    if [[ -n "$current_tag" ]]; then
      printf "    - NGC vLLM: %s → %s\n" "$current_tag" "$latest_tag"
    else
      printf "    - NGC vLLM: %s available\n" "$latest_tag"
    fi
  fi
  [[ "$gateway_update" -eq 1 ]] && printf "    - LiteLLM gateway image: %s\n" "$LITELLM_IMAGE"
  [[ "$postgres_update" -eq 1 ]] && printf "    - Postgres image: %s\n" "$postgres_image"
  [[ "$vikunja_update" -eq 1 ]] && printf "    - Vikunja image: %s\n" "$vikunja_image"
  [[ "$n8n_update" -eq 1 ]] && printf "    - n8n image: %s\n" "$n8n_image"
  [[ "$nemohermes_update" -eq 1 ]] && printf "    - NemoHermes: %s\n" "$(workspace_trim "$nemohermes_update_line")"
  printf "\n"

  if [[ "$spark_update" -eq 1 ]] && confirm "Update spark CLI to v${spark_remote_version}?"; then
    local self
    self=$(command -v spark 2>/dev/null || echo "${BASH_SOURCE[0]}")
    curl -fsSL --max-time 10 \
      "https://raw.githubusercontent.com/${GITHUB_REPO}/main/spark" -o "${self}.tmp" 2>/dev/null
    if [[ -s "${self}.tmp" ]] && bash -n "${self}.tmp" 2>/dev/null; then
      chmod +x "${self}.tmp" && mv "${self}.tmp" "$self" \
        && info "Updated spark CLI to v${spark_remote_version}" \
        || { rm -f "${self}.tmp"; err "Failed to replace spark binary"; }
    else
      rm -f "${self}.tmp"
      err "Downloaded file is invalid, skipping"
    fi
    did_update=1
  fi

  if [[ "$ngc_update" -eq 1 ]] && confirm "Pull nvcr.io/nvidia/vllm:${latest_tag}?"; then
    docker pull "nvcr.io/nvidia/vllm:${latest_tag}" \
      && info "Pulled nvcr.io/nvidia/vllm:${latest_tag}" \
      || err "Failed to pull NGC container"
    did_update=1
  fi

  if [[ "$gateway_update" -eq 1 ]] && confirm "Update LiteLLM gateway image?"; then
    if docker pull "$LITELLM_IMAGE"; then
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$GATEWAY_CONTAINER"; then
        docker rm -f "$GATEWAY_CONTAINER" >/dev/null 2>&1 || true
        gateway_start >/dev/null 2>&1 && info "LiteLLM gateway restarted with updated image" || err "Failed to restart LiteLLM gateway"
      else
        info "Pulled ${LITELLM_IMAGE}"
      fi
      did_update=1
    else
      err "Failed to pull LiteLLM gateway image"
    fi
  fi

  local workspace_images_updated=0
  if [[ "$postgres_update" -eq 1 ]] && confirm "Update Postgres image (${postgres_image})?"; then
    workspace_compose pull postgres && workspace_images_updated=1 && did_update=1 || err "Failed to pull Postgres image"
  fi
  if [[ "$vikunja_update" -eq 1 ]] && confirm "Update Vikunja image (${vikunja_image})?"; then
    workspace_compose pull vikunja && workspace_images_updated=1 && did_update=1 || err "Failed to pull Vikunja image"
  fi
  if [[ "$n8n_update" -eq 1 ]] && confirm "Update n8n image (${n8n_image})?"; then
    workspace_compose pull n8n && workspace_images_updated=1 && did_update=1 || err "Failed to pull n8n image"
  fi
  if [[ "$workspace_images_updated" -eq 1 ]]; then
    workspace_compose up -d --remove-orphans \
      && info "Workspace compose reconciled with updated images" \
      || err "Failed to restart workspace compose"
  fi

  if [[ "$nemohermes_update" -eq 1 ]] && confirm "Update NemoHermes sandbox?"; then
    if nemohermes_rebuild_with_workspace_env; then
      info "NemoHermes sandbox updated"
    else
      err "Failed to update NemoHermes sandbox"
      warn "NemoHermes rebuild used workspace inference env; if this sandbox points to an external provider, export its provider key and rerun"
    fi
    did_update=1
  fi

  if [[ "$did_update" -eq 0 ]]; then
    printf "  No updates applied.\n"
  fi
  printf "\n"
}

safe_rm_rf() {
  local path="$1" dry_run="${2:-0}"
  [[ -n "$path" && "$path" != "/" && "$path" == "$HOME"* ]] || {
    warn "Refusing to remove unsafe path: ${path:-empty}"
    return 1
  }
  if [[ "$dry_run" == "1" ]]; then
    printf "  would remove %s\n" "$path"
  else
    rm -rf "$path"
  fi
}

cmd_uninstall() {
  local auto_yes=0 purge=0 purge_models=0 keep_models=0 keep_binary=0 dry_run=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) auto_yes=1; shift ;;
      --purge) purge=1; purge_models=1; shift ;;
      --purge-models) purge_models=1; shift ;;
      --keep-models) keep_models=1; purge_models=0; shift ;;
      --keep-binary) keep_binary=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      -h|--help)
        cat <<EOF

  ${BOLD}Usage:${NC} spark uninstall [--yes] [--purge] [--purge-models] [--keep-models] [--keep-binary] [--dry-run]

  Removes spark-managed containers, gateway config, workspace config/data, and profiles.
  Shared system dependencies (Docker, Tailscale, system packages) are kept.

EOF
        return 0 ;;
      *) die "Unknown uninstall flag: $1" ;;
    esac
  done

  [[ "$keep_models" == "1" ]] && purge_models=0

  printf "\n  ${BOLD}spark uninstall${NC}\n\n"
  printf "  This removes spark-managed runtime state:\n"
  printf "    - vLLM containers and LiteLLM gateway container\n"
  printf "    - workspace Compose project, config, secrets, and data\n"
  printf "    - spark config/profiles under %s\n" "$SPARK_CONFIG_DIR"
  [[ "$purge_models" == "1" ]] && printf "    - model caches (HuggingFace/Ollama where available)\n"
  [[ "$keep_binary" != "1" ]] && printf "    - spark binary if installed under your user bin path\n"
  printf "  Kept: Docker, Tailscale, system packages, and other shared dependencies.\n\n"

  if [[ "$auto_yes" != "1" && "$dry_run" != "1" ]]; then
    confirm "Continue uninstall?" || { warn "Cancelled"; return 0; }
  fi

  local name model self
  if command -v docker >/dev/null 2>&1; then
    while IFS=$'\t' read -r name model _; do
      [[ -z "$name" ]] && continue
      if [[ "$dry_run" == "1" ]]; then printf "  would remove container %s (%s)\n" "$name" "$model"; else docker rm -f "$name" >/dev/null 2>&1 || true; fi
    done < <(list_managed_containers)
    if [[ "$dry_run" == "1" ]]; then
      printf "  would remove container %s\n" "$CONTAINER_NAME"
      printf "  would remove container %s\n" "$GATEWAY_CONTAINER"
    else
      docker rm -f "$CONTAINER_NAME" "$GATEWAY_CONTAINER" >/dev/null 2>&1 || true
    fi
    if workspace_configured; then
      if [[ "$dry_run" == "1" ]]; then
        printf "  would run docker compose down -v for workspace\n"
      else
        workspace_compose down -v >/dev/null 2>&1 || true
      fi
    fi
  fi

  if command -v ollama >/dev/null 2>&1; then
    while IFS= read -r model; do
      [[ -z "$model" ]] && continue
      if [[ "$dry_run" == "1" ]]; then printf "  would stop Ollama model %s\n" "$model"; else ollama stop "$model" >/dev/null 2>&1 || true; fi
    done < <(ollama ps 2>/dev/null | awk 'NR>1{print $1}')
    if [[ "$purge_models" == "1" ]]; then
      while IFS= read -r model; do
        [[ -z "$model" ]] && continue
        if [[ "$dry_run" == "1" ]]; then printf "  would remove Ollama model %s\n" "$model"; else ollama rm "$model" >/dev/null 2>&1 || true; fi
      done < <(ollama list 2>/dev/null | awk 'NR>1{print $1}')
    fi
  fi

  safe_rm_rf "$SPARK_CONFIG_DIR" "$dry_run" || true
  safe_rm_rf "$WORKSPACE_DATA_DIR" "$dry_run" || true
  [[ "$purge" == "1" ]] && safe_rm_rf "${HOME}/.local/share/spark" "$dry_run" || true
  if [[ "$purge_models" == "1" ]]; then
    local hf_model_dir
    for hf_model_dir in "${HF_CACHE_DIR}/hub"/models--*; do
      [[ -d "$hf_model_dir" ]] || continue
      safe_rm_rf "$hf_model_dir" "$dry_run" || true
    done
  fi

  if [[ "$keep_binary" != "1" ]]; then
    self=$(command -v spark 2>/dev/null || true)
    if [[ -n "$self" && "$self" == "$HOME/.local/bin/spark" ]]; then
      if [[ "$dry_run" == "1" ]]; then printf "  would remove %s\n" "$self"; else rm -f "$self"; fi
    elif [[ -n "$self" ]]; then
      warn "Leaving binary outside user install path: $self"
    fi
  fi

  if [[ "$dry_run" == "1" ]]; then
    info "Dry run complete"
  else
    info "spark-managed state removed"
  fi
  printf "\n"
}

cmd_reinstall() {
  local auto_yes=0 purge=1 purge_models=1 dry_run=0 funnel_action="" setup_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) auto_yes=1; setup_args+=("--yes"); shift ;;
      --purge) purge=1; shift ;;
      --purge-models) purge_models=1; shift ;;
      --keep-models) purge_models=0; shift ;;
      --dry-run) dry_run=1; shift ;;
      --funnel-action)
        funnel_action="${2:-}"
        tailscale_funnel_action_valid "$funnel_action" || die "--funnel-action must be reset or abort"
        setup_args+=("--funnel-action" "$funnel_action")
        shift 2 ;;
      -h|--help)
        printf "\n  ${BOLD}Usage:${NC} spark reinstall [--yes] [--keep-models] [--funnel-action reset|abort] [--dry-run]\n\n"
        return 0 ;;
      *) die "Unknown reinstall flag: $1" ;;
    esac
  done

  if [[ "$dry_run" == "1" ]]; then
    printf "\n  ${BOLD}spark reinstall dry run${NC}\n"
    printf "  would run: spark uninstall --yes --keep-binary"
    [[ "$purge" == "1" ]] && printf " --purge"
    [[ "$purge_models" == "1" ]] && printf " --purge-models"
    printf "\n  would run: spark setup"
    [[ ${#setup_args[@]} -gt 0 ]] && printf " %s" "${setup_args[*]}"
    printf "\n\n"
    return 0
  fi

  local uninstall_args=(--yes --keep-binary)
  [[ "$purge" == "1" ]] && uninstall_args+=(--purge)
  [[ "$purge_models" == "1" ]] && uninstall_args+=(--purge-models)
  if [[ "$auto_yes" != "1" ]]; then
    confirm "Reinstall spark-managed environment from clean state?" || { warn "Cancelled"; return 0; }
  fi
  cmd_uninstall "${uninstall_args[@]}"
  cmd_setup "${setup_args[@]}"
}

cmd_architecture() {
  cat <<EOF

  ${BOLD}spark architecture${NC}

  ${BOLD}Packaging invariant:${NC}
    src/ is the editable source. spark is the generated single-file release
    artifact used by install.sh, spark update, and remote setup.
    After editing src modules, run scripts/build-single-file.sh.

  ${BOLD}Runtime domains:${NC}
    platform      detect OS/arch/accelerator/backend and memory pool
    profile       read model metadata, compute weights/KV/need, cache JSON
    vllm          Docker launch, capacity admission, startup supervision
    ollama        native Ollama launch/pull/status path
    setup         local/remote install through ctx_* target abstraction
    workspace     Vikunja+n8n+Postgres+Hermes compose lifecycle and doctor
    gateway       LiteLLM provider config, YAML generation, container runtime
    product       dashboard, status, recommendations, uninstall/reinstall
    cli           command parsing, help, config, update, dispatch

  ${BOLD}Boundary rules:${NC}
    run_backend_* reads cmd_run locals via Bash dynamic scope.
    build_launch reads run_backend_vllm locals and rebuilds docker args.
    setup steps must use ctx_* helpers so local and remote stay equivalent.
    workspace setup --check and doctor must stay read-only.
    gateway config is JSON; generated LiteLLM YAML is derived state.

  ${BOLD}Developer map:${NC}
    src/00_bootstrap.sh        constants, platform detection, shared helpers
    src/commands/*.sh          command implementations by product domain
    src/lib/*.sh               lower-level shared subsystems
    src/90_main.sh             CLI dispatch and source guard
    scripts/build-single-file.sh builds/checks the generated spark artifact
    docs/architecture.md        audit, module map, maintenance plan
    docs/flow.md                execution flows
    tests/run.sh                fake-bin integration tests
    .github/workflows/ci.yml    syntax, shellcheck, full test suite

EOF
}

cmd_help() {
  cat <<EOF

  ${BOLD}spark${NC} v${VERSION} — Private local agent workspace, from clean OS to daily use

  ${BOLD}Usage:${NC}
    spark <command> [options]

  ${BOLD}Commands:${NC}
    setup            Set up a model server — this machine or a remote one over SSH
    dashboard        Terminal UI for setup, services, models, gateway, workspace
    status           Excellent one-shot health and runtime snapshot
    ws               Set up a private agent workspace (Vikunja + n8n + Hermes)
    doctor           Check all prerequisites (read-only)
    models           Recommend models for this hardware
    run <model>      Start serving a model (can run several at once)
    stop [<model>]   Stop a model (no arg: the only one; --all: every one)
    pull <model>     Download a model from HuggingFace
    list             List downloaded models
    rm <model> [...] Remove downloaded model(s)
    logs [<model>]   Show container logs (-f to follow)
    gateway          Manage LiteLLM gateway (start|stop|status|logs)
    reinstall        Remove spark state and run setup again
    uninstall        Remove spark-managed runtime/config/data
    update           Check and apply Spark, model, gateway, workspace, and NemoHermes updates
    config           Configure spark settings (e.g. auto-update)
    architecture     Show developer architecture map and invariants

  ${BOLD}Run flags:${NC}
    --mem <float>          GPU memory utilization (0.0-1.0), overrides auto-sizing
    --max-len <int>        Context length (default: 128K, capped to model max)
    --kv-cache-dtype fp8   Halve KV cache memory
    --max-num-seqs <int>   Max concurrent requests (default: 5; raise for more throughput)
    --enforce-eager        Disable CUDA graphs (smaller startup peak; ~10-20% slower). Auto for big MoE.
    --no-enforce-eager     Force CUDA graphs on
    --port <int>           API port (default: auto from 8000)
    --tools                Enable tool calling
    --text-only            Skip vision encoder
    --no-reasoning         Disable reasoning parser
    --no-pull              Don't offer to download a missing model; just error
    --dry-run              Print the memory plan and Docker command only
    --no-wait              Don't supervise startup (launch and return immediately)
    --tail                 Follow logs after launch
    --force                Replace this model if already running
    --regen-profile        Regenerate model profile

  ${BOLD}Setup flags:${NC}
    --check                Read-only validation
    --yes                  Accept safe defaults
    --funnel-action reset  Reset active Tailscale Funnel, then continue
    --funnel-action abort  Fail if Tailscale Funnel is active

  ${BOLD}Help:${NC}
    spark run --help
    spark setup --help
    spark doctor --help
    spark ws --help
    spark ws setup --help
    spark ws doctor --help

  ${BOLD}Examples:${NC}
    spark setup                                            # interactive: this machine or a remote one
    spark dashboard --watch                                # observe the whole environment
    spark models recommend                                 # pick a model for this machine
    spark ws setup                                         # private Vikunja + n8n + Hermes workspace
    spark setup --check                                    # just report what's missing
    spark pull RedHatAI/Qwen3.6-35B-A3B-NVFP4
    spark run RedHatAI/Qwen3.6-35B-A3B-NVFP4
    spark run nvidia/Llama-4-Scout-17B-16E-Instruct-NVFP4   # second model, co-resident
    spark run --dry-run Qwen/Qwen3-30B-A3B
    spark status
    spark stop RedHatAI/Qwen3.6-35B-A3B-NVFP4
    spark gateway start
    spark reinstall --yes
    spark architecture

EOF
}
