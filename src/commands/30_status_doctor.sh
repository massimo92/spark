
cmd_status_ollama() {
  local verbose="${1:-0}"
  printf "  ${BOLD}spark status${NC}\n\n"
  print_system_overview
  printf "  ${DIM}Engine: Ollama (%s) · %s GB unified memory${NC}\n" "$ACCEL" "$TOTAL_MEM_GB"
  print_setup_overview "$verbose"
  print_services_overview 1
  print_models_overview "Served models"
  print_next_steps 1
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
  local verbose=0 json_mode=0 quiet=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verbose) verbose=1 ;;
      --json) json_mode=1 ;;
      --quiet) quiet=1 ;;
      --help|-h)
        printf "Usage: spark status [--verbose] [--json|--quiet]\n"
        return 0 ;;
      *) die "Unknown status option: $1" "Usage: spark status [--verbose] [--json|--quiet]" ;;
    esac
    shift
  done
  [[ "$json_mode" == "1" && "$quiet" == "1" ]] && die "Choose either --json or --quiet"
  [[ "$json_mode" == "1" ]] && { cmd_status_json; return $?; }
  [[ "$quiet" == "1" ]] && { status_operational; return $?; }
  printf "\n"

  if [[ "$BACKEND" == "ollama" ]]; then
    cmd_status_ollama "$verbose"
    status_operational
    return $?
  fi

  printf "  ${BOLD}spark status${NC}\n\n"
  print_system_overview
  print_setup_overview "$verbose"
  print_services_overview 1
  print_models_overview "Served models"
  print_next_steps 1
  printf "\n"
  status_operational
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

# Doctor collects evidence first, then renders it for humans or automation.
DOCTOR_CATEGORIES=()
DOCTOR_LABELS=()
DOCTOR_RESULTS=()
DOCTOR_DETAILS=()
DOCTOR_ACTIONS=()

doctor_record() {
  DOCTOR_CATEGORIES+=("$1")
  DOCTOR_LABELS+=("$2")
  DOCTOR_RESULTS+=("$3")
  DOCTOR_DETAILS+=("${4:-}")
  DOCTOR_ACTIONS+=("${5:-}")
}

doctor_pass() { doctor_record "$1" "$2" ok "${3:-}"; }
doctor_fail() { doctor_record "$1" "$2" fail "${3:-}" "${4:-}"; }
doctor_skip() { doctor_record "$1" "$2" skipped "${3:-}"; }

doctor_id_from_label() {
  LC_ALL=C printf '%s\n' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]\{1,\}/_/g; s/^_//; s/_$//'
}

doctor_count() {
  local wanted="$1" result count=0
  for result in "${DOCTOR_RESULTS[@]}"; do
    [[ "$result" == "$wanted" ]] && count=$((count + 1))
  done
  printf '%d\n' "$count"
}

doctor_area_counts() {
  local area="$1" i result area_passed=0 area_failed=0
  for i in "${!DOCTOR_CATEGORIES[@]}"; do
    [[ "${DOCTOR_CATEGORIES[$i]}" == "$area" ]] || continue
    result="${DOCTOR_RESULTS[$i]}"
    [[ "$result" == "ok" ]] && area_passed=$((area_passed + 1))
    [[ "$result" == "fail" ]] && area_failed=$((area_failed + 1))
  done
  printf '%d %d\n' "$area_passed" "$area_failed"
}

doctor_print_json() {
  local passed failed total first=1 i area area_passed area_failed
  passed=$(doctor_count ok)
  failed=$(doctor_count fail)
  total=$((passed + failed))
  printf '{"ok":%s,"target":{"os":"%s","arch":"%s","accelerator":"%s","backend":"%s"},"passed":%d,"failed":%d,"total":%d,"areas":[' \
    "$( [[ "$failed" -eq 0 ]] && printf true || printf false )" \
    "$(status_json_escape "$SPARK_OS")" "$(status_json_escape "$SPARK_ARCH")" \
    "$(status_json_escape "$ACCEL")" "$(status_json_escape "$BACKEND")" \
    "$passed" "$failed" "$total"
  for area in "Runtime" "Model assets" "Host safety" "Exposure" "Gateway"; do
    read -r area_passed area_failed <<< "$(doctor_area_counts "$area")"
    [[ $((area_passed + area_failed)) -gt 0 ]] || continue
    [[ "$first" == "1" ]] || printf ','
    first=0
    printf '{"name":"%s","passed":%d,"failed":%d,"total":%d}' \
      "$(status_json_escape "$area")" "$area_passed" "$area_failed" "$((area_passed + area_failed))"
  done
  printf '],"checks":['
  first=1
  for i in "${!DOCTOR_LABELS[@]}"; do
    [[ "$first" == "1" ]] || printf ','
    first=0
    printf '{"id":"%s","area":"%s","label":"%s","state":"%s","detail":"%s","action":"%s"}' \
      "$(status_json_escape "$(doctor_id_from_label "${DOCTOR_LABELS[$i]}")")" \
      "$(status_json_escape "${DOCTOR_CATEGORIES[$i]}")" \
      "$(status_json_escape "${DOCTOR_LABELS[$i]}")" \
      "$(status_json_escape "${DOCTOR_RESULTS[$i]}")" \
      "$(status_json_escape "${DOCTOR_DETAILS[$i]}")" \
      "$(status_json_escape "${DOCTOR_ACTIONS[$i]}")"
  done
  printf ']}\n'
}

doctor_print_human() {
  local verbose="$1" passed failed total i area area_passed area_failed detail action state
  passed=$(doctor_count ok)
  failed=$(doctor_count fail)
  total=$((passed + failed))
  printf "\n  ${BOLD}spark doctor${NC}\n\n"
  printf "  ${BOLD}Result${NC}\n"
  if [[ "$failed" -eq 0 ]]; then
    printf "  ${GREEN}ok${NC}         %d/%d checks passed\n" "$passed" "$total"
  else
    printf "  ${RED}attention${NC}  %d/%d checks passed · %d issue(s)\n" "$passed" "$total" "$failed"
  fi
  printf "  target     %s/%s · %s · backend %s\n\n" "$SPARK_OS" "$SPARK_ARCH" "$ACCEL" "$BACKEND"

  printf "  ${BOLD}Areas${NC}\n"
  for area in "Runtime" "Model assets" "Host safety" "Exposure" "Gateway"; do
    read -r area_passed area_failed <<< "$(doctor_area_counts "$area")"
    [[ $((area_passed + area_failed)) -gt 0 ]] || continue
    if [[ "$area_failed" -eq 0 ]]; then state="${GREEN}ok${NC}"; else state="${RED}issue${NC}"; fi
    printf "  %-16b %-24s %d/%d\n" "$state" "$area" "$area_passed" "$((area_passed + area_failed))"
  done

  if [[ "$failed" -gt 0 ]]; then
    printf "\n  ${BOLD}Issues${NC}\n"
    for i in "${!DOCTOR_LABELS[@]}"; do
      [[ "${DOCTOR_RESULTS[$i]}" == "fail" ]] || continue
      detail="${DOCTOR_DETAILS[$i]}"; action="${DOCTOR_ACTIONS[$i]}"
      printf "  ${RED}failed${NC}     %s > %s\n" "${DOCTOR_CATEGORIES[$i]}" "${DOCTOR_LABELS[$i]}"
      [[ -z "$detail" ]] || printf "             %s\n" "$detail"
      [[ -z "$action" ]] || printf "             Try: %s\n" "$action"
    done
  fi

  if [[ "$verbose" == "1" ]]; then
    printf "\n  ${BOLD}Checks${NC}\n"
    for i in "${!DOCTOR_LABELS[@]}"; do
      case "${DOCTOR_RESULTS[$i]}" in
        ok) state="${GREEN}✓${NC}" ;;
        fail) state="${RED}✗${NC}" ;;
        *) state="${DIM}–${NC}" ;;
      esac
      printf "  %b %-24s %s" "$state" "${DOCTOR_CATEGORIES[$i]}" "${DOCTOR_LABELS[$i]}"
      [[ -z "${DOCTOR_DETAILS[$i]}" ]] || printf " · %s" "${DOCTOR_DETAILS[$i]}"
      printf "\n"
    done
  fi
  printf "\n"
}

# vLLM/NVIDIA health checks.
doctor_checks_vllm() {
  local gpu_info hf_ver bad_cache_path ngc_image model_count=0
  if gpu_info=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null) && [[ -n "$gpu_info" ]]; then
    doctor_pass "Runtime" "GPU" "$gpu_info"
  else
    doctor_fail "Runtime" "GPU" "nvidia-smi unavailable or no GPU detected" "check the NVIDIA driver, then rerun spark doctor"
  fi

  if docker info 2>/dev/null | grep -qi nvidia || command -v nvidia-ctk >/dev/null 2>&1; then
    doctor_pass "Runtime" "NVIDIA Container Toolkit" "present"
  else
    doctor_fail "Runtime" "NVIDIA Container Toolkit" "not detected; Docker cannot use the GPU" "spark setup"
  fi

  if groups 2>/dev/null | grep -q docker; then
    doctor_pass "Runtime" "Docker access" "user $(whoami) belongs to the docker group"
  else
    doctor_fail "Runtime" "Docker access" "user $(whoami) is not in the docker group" "spark setup, then sign in again"
  fi

  if [[ -f "${HOME}/.docker/config.json" ]] && grep -q "nvcr.io" "${HOME}/.docker/config.json" 2>/dev/null; then
    doctor_pass "Model assets" "NGC authentication" "nvcr.io credentials present"
  else
    doctor_fail "Model assets" "NGC authentication" "nvcr.io credentials missing" "spark setup"
  fi

  if command -v hf >/dev/null 2>&1; then
    hf_ver=$(hf version 2>/dev/null || hf --version 2>/dev/null || printf 'unknown\n')
    hf_ver=$(printf '%s\n' "$hf_ver" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//')
    doctor_pass "Model assets" "Hugging Face CLI" "$hf_ver"
  else
    doctor_fail "Model assets" "Hugging Face CLI" "not installed" "uv tool install 'huggingface-hub[cli]'"
  fi

  bad_cache_path=$(hf_cache_first_unwritable "$HF_CACHE_DIR" || true)
  if [[ -n "$bad_cache_path" ]]; then
    doctor_fail "Model assets" "HF cache permissions" "not writable: ${bad_cache_path}" \
      "sudo chown -R $(id -u):$(id -g) ${HF_CACHE_DIR}"
  else
    doctor_pass "Model assets" "HF cache permissions" "writable"
  fi

  ngc_image=$(detect_ngc_image)
  if [[ -n "$ngc_image" ]]; then
    doctor_pass "Model assets" "NGC container" "$ngc_image"
  else
    doctor_fail "Model assets" "NGC container" "vLLM image not pulled" "spark setup"
  fi

  if [[ -d "${HF_CACHE_DIR}/hub" ]]; then
    model_count=$(find "${HF_CACHE_DIR}/hub" -maxdepth 1 -name "models--*" -type d 2>/dev/null | wc -l | tr -d ' ')
  fi
  if [[ "$model_count" -gt 0 ]]; then
    doctor_pass "Model assets" "Downloaded models" "${model_count} found"
  else
    if [[ -d "${HF_CACHE_DIR}/hub" ]]; then
      doctor_fail "Model assets" "Downloaded models" "none found" "spark pull <model>"
    else
      doctor_fail "Model assets" "Downloaded models" "HF cache not found at ${HF_CACHE_DIR}" "spark pull <model>"
    fi
  fi
}

# Ollama health checks. Updates cmd_doctor's passed/total via dynamic scope.
doctor_checks_ollama() {
  local ollama_ver n=0
  if command -v ollama >/dev/null 2>&1; then
    ollama_ver=$(ollama --version 2>/dev/null | head -1 || printf 'installed\n')
    doctor_pass "Runtime" "Ollama" "$ollama_ver"
  else
    doctor_fail "Runtime" "Ollama" "not installed" "spark setup"
  fi

  if ollama_reachable; then
    doctor_pass "Runtime" "Ollama API" "reachable on port 11434"
  else
    doctor_fail "Runtime" "Ollama API" "not reachable on port 11434" "start ollama serve or the Ollama app"
  fi

  command -v ollama >/dev/null 2>&1 && n=$(ollama list 2>/dev/null | awk 'NR>1 && NF>0' | wc -l | tr -d ' ')
  if [[ "${n:-0}" -gt 0 ]]; then
    doctor_pass "Model assets" "Pulled models" "${n} found"
  else
    doctor_fail "Model assets" "Pulled models" "none found" "spark run <model>"
  fi

  [[ "$ACCEL" == "metal" ]] && doctor_skip "Runtime" "Apple Silicon memory" "${TOTAL_MEM_GB} GB unified memory"
}

# Report host hardening drift (Linux + systemd).
doctor_checks_hardening() {
  { [[ "$SPARK_OS" == "Linux" ]] && command -v systemctl >/dev/null 2>&1; } || return 0
  local sw_mib sw_source sw_diag swp target_mib oom_ssh oom_dbus
  swap_read_total sw_mib sw_source sw_diag
  target_mib=$(( SWAP_PROVISION_GB * 1024 ))
  swp="$(sysctl -n vm.swappiness 2>/dev/null || true)"
  if { [[ "$target_mib" -le 0 && "$sw_mib" -gt 0 ]] || [[ "$target_mib" -gt 0 && "$sw_mib" -ge "$target_mib" ]]; } && [[ "$swp" == "$SWAPPINESS" ]]; then
    doctor_pass "Host safety" "Swap and swappiness" \
      "${sw_mib} MiB $(swap_total_context "$sw_source" "$sw_diag") · swappiness ${swp}"
  else
    doctor_fail "Host safety" "Swap and swappiness" \
      "${sw_mib} MiB $(swap_total_context "$sw_source" "$sw_diag"); target ≥${target_mib} MiB; swappiness ${swp:-unknown}" "spark setup"
  fi
  if systemctl is-active --quiet earlyoom 2>/dev/null; then
    doctor_pass "Host safety" "early-OOM" "active"
  else
    doctor_fail "Host safety" "early-OOM" "not active" "spark setup"
  fi
  oom_ssh="$(systemctl show -p OOMScoreAdjust --value ssh.service 2>/dev/null)"
  oom_dbus="$(systemctl show -p OOMScoreAdjust --value dbus.service 2>/dev/null)"
  if [[ "$oom_ssh" == "-1000" && "$oom_dbus" == "-1000" ]]; then
    doctor_pass "Host safety" "Control-plane OOM protection" "sshd and dbus protected"
  else
    doctor_fail "Host safety" "Control-plane OOM protection" \
      "sshd ${oom_ssh:-unknown}; dbus ${oom_dbus:-unknown}" "spark setup"
  fi
}

cmd_doctor_help() {
  cat <<EOF

  ${BOLD}Usage:${NC} spark doctor [--verbose] [--json|--quiet]

  Read-only check for the model server: Docker, backend prerequisites, OS hardening,
  LiteLLM gateway, and global Tailscale Funnel exposure.

  ${BOLD}Flags:${NC}
    --verbose  Show every check and its evidence.
    --json     Machine-readable result.
    --quiet    Print nothing; use only the exit code.

EOF
}

cmd_doctor() {
  local verbose=0 json_mode=0 quiet=0 failed docker_ver gw_enabled
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verbose) verbose=1 ;;
      --json) json_mode=1 ;;
      --quiet) quiet=1 ;;
      -h|--help) cmd_doctor_help; return 0 ;;
      *) die "Unknown doctor flag: $1" ;;
    esac
    shift
  done
  [[ "$json_mode" == "1" && "$quiet" == "1" ]] && die "Choose either --json or --quiet"

  DOCTOR_CATEGORIES=()
  DOCTOR_LABELS=()
  DOCTOR_RESULTS=()
  DOCTOR_DETAILS=()
  DOCTOR_ACTIONS=()

  if docker_ver=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1); then
    if docker info >/dev/null 2>&1; then
      doctor_pass "Runtime" "Docker" "${docker_ver}, running"
    else
      doctor_fail "Runtime" "Docker" "${docker_ver} installed but not running" "start Docker"
    fi
  else
    doctor_fail "Runtime" "Docker" "not installed" "spark setup"
  fi

  if [[ "$BACKEND" == "ollama" ]]; then
    doctor_checks_ollama
  else
    doctor_checks_vllm
  fi

  doctor_checks_hardening

  if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
    if tailscale_funnel_status_active; then
      doctor_fail "Exposure" "Tailscale Funnel" "active public exposure" "tailscale funnel reset"
    else
      doctor_pass "Exposure" "Tailscale Funnel" "disabled"
    fi
  else
    doctor_skip "Exposure" "Tailscale Funnel" "skipped; Tailscale not connected"
  fi

  if [[ -f "$GATEWAY_CONFIG" ]]; then
    gw_enabled=$(jq -r '.enabled // false' "$GATEWAY_CONFIG" 2>/dev/null || echo "false")
    if [[ "$gw_enabled" == "true" ]]; then
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${GATEWAY_CONTAINER}$"; then
        doctor_pass "Gateway" "LiteLLM" "running as ${GATEWAY_CONTAINER}"
      else
        doctor_fail "Gateway" "LiteLLM" "configured but not running" "spark gateway start"
      fi
    else
      doctor_skip "Gateway" "LiteLLM" "disabled"
    fi
  else
    doctor_skip "Gateway" "LiteLLM" "not configured"
  fi

  failed=$(doctor_count fail)
  if [[ "$json_mode" == "1" ]]; then
    doctor_print_json
  elif [[ "$quiet" == "0" ]]; then
    doctor_print_human "$verbose"
  fi
  [[ "$failed" -eq 0 ]]
}
