
cmd_status_ollama() {
  printf "  ${BOLD}spark status${NC}\n\n"
  print_system_overview
  printf "  ${DIM}Engine: Ollama (%s) · %s GB unified memory${NC}\n" "$ACCEL" "$TOTAL_MEM_GB"
  print_setup_overview
  print_services_overview
  print_models_overview
  print_workspace_overview
  print_next_steps
  printf "\n"
  return 0
}

cmd_status_ollama_legacy() {
  local gw_running=0 gw_port="$GATEWAY_PORT"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${GATEWAY_CONTAINER}$"; then
    gw_running=1
    gw_port=$(gateway_load_config | jq -r '.port // 4000' 2>/dev/null)
  fi

  if ! command -v ollama >/dev/null 2>&1; then
    printf "  ${DIM}○${NC} Ollama not installed. Set up this machine: ${BOLD}spark setup${NC}\n\n"
    return 0
  fi

  local rows
  rows=$(ollama list 2>/dev/null | awk 'NR>1{printf "  %-32s %s %s\n", $1, $3, $4}')
  if [[ -z "$rows" ]]; then
    printf "  ${DIM}○${NC} No models pulled. Get one with: ${BOLD}spark run <model>${NC}\n"
  else
    printf "  ${DIM}%-32s %s${NC}\n" "MODEL" "SIZE"
    printf "%s\n" "$rows"
  fi

  local loaded
  loaded=$(ollama ps 2>/dev/null | awk 'NR>1{print $1}' | tr '\n' ' ')
  [[ -n "${loaded// /}" ]] && printf "\n  ${DIM}Loaded now: %s${NC}\n" "$loaded"

  printf "\n  ${DIM}Engine: Ollama (%s) · %s GB unified memory${NC}\n" "$ACCEL" "$TOTAL_MEM_GB"
  if [[ "$gw_running" -eq 1 ]]; then
    printf "  ${DIM}Gateway (✓): http://localhost:%s/v1 — call a model as ${NC}${BOLD}ollama_chat/<model>${NC}\n" "$gw_port"
  else
    printf "  ${DIM}Gateway: not running — start it with ${NC}${BOLD}spark gateway start${NC}\n"
  fi
  printf "\n"
}

cmd_status() {
  printf "\n"

  if [[ "$BACKEND" == "ollama" ]]; then
    cmd_status_ollama
    return
  fi

  printf "  ${BOLD}spark status${NC}\n\n"
  print_system_overview
  print_setup_overview
  print_services_overview
  print_models_overview
  print_workspace_overview
  print_next_steps
  printf "\n"
}

# spark logs [<model>] [-f] — logs of a model, or the only one running.
cmd_logs() {
  local follow=0 target=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f) follow=1; shift ;;
      *)  target="$1"; shift ;;
    esac
  done

  if [[ "$BACKEND" == "ollama" ]]; then
    warn "Ollama runs as a shared service — spark has no per-model logs for it."
    printf "    macOS: open the Ollama app, or run ${BOLD}ollama serve${NC} in a terminal.\n"
    printf "    Linux: ${BOLD}journalctl -u ollama -f${NC}\n"
    return 0
  fi

  local name=""
  if [[ -n "$target" ]]; then
    name=$(container_for_ref "$target" 2>/dev/null || true)
    [[ -z "$name" ]] && name=$(container_name_for_model "$target")
  else
    # No model given: pick the only running managed container, or the legacy name.
    local names=()
    while IFS=$'\t' read -r n _; do [[ -n "$n" ]] && names+=("$n"); done < <(list_managed_containers)
    if [[ ${#names[@]} -eq 1 ]]; then
      name="${names[0]}"
    elif [[ ${#names[@]} -gt 1 ]]; then
      err "Multiple models running — specify which"
      printf "    %s\n" "$(IFS=', '; echo "${names[*]}")"
      exit 1
    else
      name="$CONTAINER_NAME"
    fi
  fi

  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
    die "No container found for '${target:-$name}'"
  fi

  if [[ "$follow" == "1" ]]; then
    docker logs -f "$name"
  else
    docker logs "$name"
  fi
}

# vLLM/NVIDIA health checks. Updates cmd_doctor's passed/total via dynamic scope.
doctor_checks_vllm() {
  # GPU
  total=$((total + 1))
  local gpu_info
  if gpu_info=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null) && [[ -n "$gpu_info" ]]; then
    info "GPU: ${gpu_info}"
    passed=$((passed + 1))
  else
    err "GPU: nvidia-smi not available or no GPU detected"
  fi

  # NVIDIA Container Toolkit (lets Docker use the GPU with --gpus all)
  total=$((total + 1))
  if docker info 2>/dev/null | grep -qi nvidia || command -v nvidia-ctk >/dev/null 2>&1; then
    info "NVIDIA Container Toolkit: present"
    passed=$((passed + 1))
  else
    err "NVIDIA Container Toolkit: not detected — needed for 'docker run --gpus all'"
  fi

  # Docker group
  total=$((total + 1))
  if groups 2>/dev/null | grep -q docker; then
    info "Docker group: user $(whoami) in docker group"
    passed=$((passed + 1))
  else
    err "Docker group: user $(whoami) not in docker group"
  fi

  # NGC
  total=$((total + 1))
  if [[ -f "${HOME}/.docker/config.json" ]] && grep -q "nvcr.io" "${HOME}/.docker/config.json" 2>/dev/null; then
    info "NGC: authenticated (nvcr.io)"
    passed=$((passed + 1))
  else
    err "NGC: not authenticated — run 'spark setup' phase 3"
  fi

  # HF CLI
  total=$((total + 1))
  if command -v hf >/dev/null 2>&1; then
    local hf_ver
    hf_ver=$(hf version 2>/dev/null || hf --version 2>/dev/null || echo "unknown")
    info "HF CLI: ${hf_ver}"
    passed=$((passed + 1))
  else
    err "HF CLI: not installed — run 'uv tool install huggingface-hub[cli]'"
  fi

  # HF cache permissions
  total=$((total + 1))
  local bad_cache_path=""
  bad_cache_path=$(hf_cache_first_unwritable "$HF_CACHE_DIR" || true)
  if [[ -n "$bad_cache_path" ]]; then
    err "HF cache permissions: not writable at ${bad_cache_path}"
    printf "    Fix manually, then retry. Example: sudo chown -R %s:%s %s\n" "$(id -u)" "$(id -g)" "$HF_CACHE_DIR"
  else
    info "HF cache permissions: writable"
    passed=$((passed + 1))
  fi

  # NGC container
  total=$((total + 1))
  local ngc_image
  ngc_image=$(detect_ngc_image)
  if [[ -n "$ngc_image" ]]; then
    info "NGC container: ${ngc_image}"
    passed=$((passed + 1))
  else
    err "NGC container: vLLM image not pulled"
  fi

  # Models
  total=$((total + 1))
  local model_count=0
  if [[ -d "${HF_CACHE_DIR}/hub" ]]; then
    model_count=$(find "${HF_CACHE_DIR}/hub" -maxdepth 1 -name "models--*" -type d 2>/dev/null | wc -l | tr -d ' ')
  fi
  if [[ "$model_count" -gt 0 ]]; then
    info "Models: ${model_count} downloaded"
    passed=$((passed + 1))
  else
    if [[ -d "${HF_CACHE_DIR}/hub" ]]; then
      err "No model downloaded yet — run 'spark pull <model>'"
    else
      err "HF cache not found at ${HF_CACHE_DIR} — run 'spark pull <model>' to initialize"
    fi
  fi
}

# Ollama health checks. Updates cmd_doctor's passed/total via dynamic scope.
doctor_checks_ollama() {
  # Ollama installed
  total=$((total + 1))
  if command -v ollama >/dev/null 2>&1; then
    info "Ollama: $(ollama --version 2>/dev/null | head -1 || echo installed)"
    passed=$((passed + 1))
  else
    err "Ollama: not installed — run 'spark setup' to set it up"
  fi

  # Ollama service reachable
  total=$((total + 1))
  if ollama_reachable; then
    info "Ollama service: reachable on :11434"
    passed=$((passed + 1))
  else
    err "Ollama service: not reachable on :11434 — start it (ollama serve / Ollama app)"
  fi

  # Models pulled
  total=$((total + 1))
  local n=0
  command -v ollama >/dev/null 2>&1 && n=$(ollama list 2>/dev/null | awk 'NR>1 && NF>0' | wc -l | tr -d ' ')
  if [[ "${n:-0}" -gt 0 ]]; then
    info "Models: ${n} pulled"
    passed=$((passed + 1))
  else
    err "No models pulled yet — run 'spark run <model>'"
  fi

  # Apple Silicon advisory (MLX engages on 32 GB+ unified memory).
  [[ "$ACCEL" == "metal" ]] && info "Apple Silicon: Ollama uses MLX on 32 GB+ unified memory (have ${TOTAL_MEM_GB} GB)"
}

# Report host hardening drift (Linux + systemd). Shares cmd_doctor's passed/total via dynamic scope.
doctor_checks_hardening() {
  { [[ "$SPARK_OS" == "Linux" ]] && command -v systemctl >/dev/null 2>&1; } || return 0
  local sw_mib swp target_mib oom_ssh oom_dbus
  total=$((total + 1))
  sw_mib="$(free -m 2>/dev/null | awk '/^Swap:/{print $2}' || true)"
  sw_mib="${sw_mib//[!0-9]/}"
  [[ "$sw_mib" =~ ^[0-9]+$ ]] || sw_mib=0
  target_mib=$(( SWAP_PROVISION_GB * 1024 ))
  swp="$(sysctl -n vm.swappiness 2>/dev/null || true)"
  if { [[ "$target_mib" -le 0 && "$sw_mib" -gt 0 ]] || [[ "$target_mib" -gt 0 && "$sw_mib" -ge "$target_mib" ]]; } && [[ "$swp" == "$SWAPPINESS" ]]; then
    info "Swap: on (${sw_mib}MiB total) + swappiness=${swp} (absorbs load peaks)"; passed=$((passed + 1))
  else
    err "Swap/swappiness not configured (swap=${sw_mib}MiB, target≥${target_mib}MiB, swappiness='${swp:-?}') — run 'spark setup'"
  fi
  total=$((total + 1))
  if systemctl is-active --quiet earlyoom 2>/dev/null; then
    info "early-OOM: earlyoom active (runaway backstop)"; passed=$((passed + 1))
  else
    err "early-OOM: earlyoom not active — run 'spark setup'"
  fi
  total=$((total + 1))
  oom_ssh="$(systemctl show -p OOMScoreAdjust --value ssh.service 2>/dev/null)"
  oom_dbus="$(systemctl show -p OOMScoreAdjust --value dbus.service 2>/dev/null)"
  if [[ "$oom_ssh" == "-1000" && "$oom_dbus" == "-1000" ]]; then
    info "control-plane: sshd + dbus OOM-protected"; passed=$((passed + 1))
  else
    err "control-plane not fully OOM-protected (sshd='${oom_ssh:-?}', dbus='${oom_dbus:-?}') — run 'spark setup'"
  fi
}

cmd_doctor_help() {
  cat <<EOF

  ${BOLD}Usage:${NC} spark doctor [--help]

  Read-only check for the model server: Docker, backend prerequisites, OS hardening,
  LiteLLM gateway, and global Tailscale Funnel exposure.

EOF
}

cmd_doctor() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      -h|--help) cmd_doctor_help; return 0 ;;
      *) die "Unknown doctor flag: $1" ;;
    esac
  fi
  printf "\n"
  local passed=0 total=0

  # Detected hardware (informational).
  info "Detected: ${SPARK_OS}/${SPARK_ARCH} · accelerator ${ACCEL} · backend ${BACKEND}"

  # Docker — the LiteLLM gateway runs in a container on both backends.
  total=$((total + 1))
  local docker_ver
  if docker_ver=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1); then
    if docker info >/dev/null 2>&1; then
      info "Docker: ${docker_ver}, running"
      passed=$((passed + 1))
    else
      err "Docker: ${docker_ver} installed but not running"
    fi
  else
    err "Docker: not installed"
  fi

  if [[ "$BACKEND" == "ollama" ]]; then
    doctor_checks_ollama
  else
    doctor_checks_vllm
  fi

  doctor_checks_hardening

  if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
    total=$((total + 1))
    if tailscale_funnel_status_active; then
      err "Tailscale Funnel: active public exposure — run 'tailscale funnel reset'"
    else
      info "Tailscale Funnel: disabled"
      passed=$((passed + 1))
    fi
  else
    info "Tailscale Funnel: skipped (Tailscale not connected)"
  fi

  # Gateway
  if [[ -f "$GATEWAY_CONFIG" ]]; then
    local gw_enabled
    gw_enabled=$(jq -r '.enabled // false' "$GATEWAY_CONFIG" 2>/dev/null || echo "false")
    if [[ "$gw_enabled" == "true" ]]; then
      total=$((total + 1))
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${GATEWAY_CONTAINER}$"; then
        info "Gateway: LiteLLM running (${GATEWAY_CONTAINER})"
        passed=$((passed + 1))
      else
        err "Gateway: LiteLLM configured but not running — run 'spark gateway start'"
      fi
    fi
  fi

  printf "\n  %d/%d checks passed." "$passed" "$total"
  if [[ "$passed" -lt "$total" ]]; then
    printf " Run '${BOLD}spark setup${NC}' to fix issues."
  fi
  printf "\n\n"
}
