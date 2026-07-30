# --- spark setup: configure a machine (local or remote) as a model server ---
#
# One wizard, one install set. `spark setup` asks WHERE to install (this machine, or a
# remote one over SSH); every step below runs against the chosen target via ctx_*, so a
# server receives the exact same software whether it is configured locally or remotely.

# Write controller stdin to a root-owned file on the target.
ctx_sudo_write() {  # $1 = path; reads file content from stdin
  ensure_sudo_pw
  if [[ -z "$SUDO_PW" ]]; then
    if [[ "$SETUP_TARGET" == "remote" ]]; then remote_in "sudo -n tee $1 >/dev/null"; else sudo -n tee "$1" >/dev/null; fi
  elif [[ "$SETUP_TARGET" == "remote" ]]; then
    # sudo -S eats the first stdin line (the password); tee gets the rest (the content).
    { printf '%s\n' "$SUDO_PW"; cat; } | remote_in "sudo -S -p '' tee $1 >/dev/null"
  else
    { printf '%s\n' "$SUDO_PW"; cat; } | sudo -S -p '' tee "$1" >/dev/null
  fi
}

# --- Install steps (shared across local/remote) ---

step_gpu_check() {
  if ctx_run 'nvidia-smi -L' >/dev/null 2>&1; then
    info "GPU: $(ctx_run 'nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1')"
  else
    setup_fail "No NVIDIA GPU detected (nvidia-smi)"
  fi
}

step_docker_check() {
  local check_only="$2"
  if ctx_run 'docker info >/dev/null 2>&1'; then
    info "Docker: running"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "Docker not installed or not running"
  elif [[ "$TGT_OS" == "Darwin" ]]; then
    setup_manual_step "Install Docker Desktop and start it: https://docs.docker.com/desktop/"
  else
    setup_manual_step "Install Docker and start it: https://docs.docker.com/engine/install/"
  fi
}

step_docker_group() {
  local auto_yes="$1" check_only="$2" u
  [[ "$TGT_OS" == "Linux" ]] || return 0
  u="$(ctx_user)"
  if ctx_run 'groups 2>/dev/null | grep -q docker'; then
    info "Docker group: ${u} in docker group"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "${u} not in the docker group"
  elif [[ "$auto_yes" == "1" ]] || confirm "Add ${u} to the docker group?"; then
    if ctx_sudo "usermod -aG docker ${u}"; then
      warn "Added to docker group — log out/in to apply"
    else
      setup_fail "Could not add to docker group"
    fi
  else
    setup_skip "docker group membership"
  fi
}

step_nvidia_ctk() {
  local auto_yes="$1" check_only="$2"
  [[ "$TGT_OS" == "Linux" ]] || return 0
  if ctx_run 'docker info 2>/dev/null | grep -qi nvidia || command -v nvidia-ctk >/dev/null 2>&1'; then
    info "NVIDIA Container Toolkit: present"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "NVIDIA Container Toolkit not detected"
  elif [[ "$auto_yes" == "1" ]] || confirm "Install the NVIDIA Container Toolkit (enables 'docker run --gpus')?"; then
    if ctx_sudo 'curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" > /etc/apt/sources.list.d/nvidia-container-toolkit.list && apt-get update && apt-get install -y nvidia-container-toolkit && nvidia-ctk runtime configure --runtime=docker && systemctl restart docker'; then
      info "Installed NVIDIA Container Toolkit"
    else
      setup_fail "NVIDIA Container Toolkit install failed"
    fi
  else
    setup_manual_step "Install the NVIDIA Container Toolkit (enables 'docker run --gpus'): https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html"
  fi
}

step_ngc_login() {
  local check_only="$2" key
  if ctx_run 'test -f $HOME/.docker/config.json && grep -q nvcr.io $HOME/.docker/config.json'; then
    info "NGC: authenticated"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "NGC not authenticated (docker login nvcr.io)"
  else
    printf "  ${DIM}NGC is NVIDIA's registry — needed to pull the vLLM serving image.${NC}\n"
    setup_manual_step "Create an NGC account + API key: ngc.nvidia.com -> Setup -> API Keys" ""
    printf "  Enter your NGC API key (blank to skip): "
    read -rs key; printf "\n"
    if [[ -n "$key" ]]; then
      if printf '%s' "$key" | ctx_run_stdin 'docker login nvcr.io -u \$oauthtoken --password-stdin'; then
        info "NGC Docker login successful"
      else
        setup_fail "NGC login failed"
      fi
    else
      setup_skip "NGC Docker login"
    fi
  fi
}

step_vllm_image() {
  local auto_yes="$1" check_only="$2" tag have
  have="$(ctx_run 'docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep "nvcr.io/nvidia/vllm" | head -1' 2>/dev/null || true)"
  if [[ -n "$have" ]]; then
    info "vLLM image: ${have}"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "vLLM NGC image not pulled"
  elif [[ "$auto_yes" == "1" ]]; then
    setup_skip "vLLM image pull"
  else
    printf "  Enter an NGC vLLM tag to pull (e.g. 26.04-py3), blank to skip: "
    read -r tag
    if [[ -n "$tag" ]]; then
      is_safe_ngc_tag "$tag" || die "Invalid NGC tag: $tag"
      if ctx_run "docker pull nvcr.io/nvidia/vllm:${tag}"; then info "Pulled vLLM image"; else setup_fail "Image pull failed"; fi
    else
      setup_skip "vLLM image pull"
    fi
  fi
}

step_uv() {
  local check_only="$2"
  if ctx_run "${TGT_PATH} command -v uv" >/dev/null 2>&1; then
    info "uv: installed"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "uv not installed"
  else
    if ctx_run 'curl -LsSf https://astral.sh/uv/install.sh | sh'; then info "Installed uv"; else setup_fail "uv install failed"; fi
  fi
}

step_hf_cli() {
  local check_only="$2"
  if ctx_run "${TGT_PATH} command -v hf" >/dev/null 2>&1; then
    info "HF CLI: installed"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "HuggingFace CLI not installed"
  elif ctx_run "${TGT_PATH} command -v uv" >/dev/null 2>&1; then
    if ctx_run "${TGT_PATH} uv tool install 'huggingface-hub[cli]'"; then info "Installed HF CLI"; else setup_fail "HF CLI install failed"; fi
  else
    setup_skip "HuggingFace CLI (needs uv)"
  fi

  if ctx_run '$HOME/.local/share/spark/hf-inspect-venv/bin/python -c "import huggingface_hub"'; then
    info "HF library: installed"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "HuggingFace library not installed"
  elif ctx_run "${TGT_PATH} command -v uv" >/dev/null 2>&1; then
    if ctx_run 'mkdir -p $HOME/.local/share/spark && uv venv $HOME/.local/share/spark/hf-inspect-venv >/dev/null && $HOME/.local/share/spark/hf-inspect-venv/bin/python -m pip install -q huggingface-hub'; then
      info "Installed HF library"
    else
      setup_fail "HF library install failed"
    fi
  else
    setup_skip "HuggingFace library (needs uv)"
  fi
}

step_nvitop() {
  local check_only="$2"
  if ctx_run "${TGT_PATH} command -v nvitop" >/dev/null 2>&1; then
    info "nvitop: installed"
  elif [[ "$check_only" == "1" ]]; then
    setup_skip "nvitop"
  elif ctx_run "${TGT_PATH} command -v uv" >/dev/null 2>&1; then
    if ctx_run "${TGT_PATH} uv tool install nvitop"; then info "Installed nvitop"; else setup_fail "nvitop install failed"; fi
  else
    setup_skip "nvitop (needs uv)"
  fi
}

step_jq() {
  local check_only="$2"
  [[ "$TGT_OS" == "Linux" ]] || return 0
  if ctx_has jq; then
    info "jq: installed"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "jq not installed"
  else
    if ctx_sudo 'apt-get install -y jq'; then info "Installed jq"; else setup_fail "jq install failed"; fi
  fi
}

step_apt_upgrade() {
  local auto_yes="$1" check_only="$2" upgradable
  [[ "$TGT_OS" == "Linux" ]] || return 0
  [[ "$check_only" == "1" ]] && return 0
  upgradable="$(ctx_run 'apt list --upgradable 2>/dev/null | grep -c upgradable' 2>/dev/null | tr -d '[:space:]' || echo 0)"
  [[ "$upgradable" =~ ^[0-9]+$ ]] || upgradable=0
  if [[ "$upgradable" -gt 0 ]]; then
    if [[ "$auto_yes" == "1" ]] || confirm "${upgradable} upgradable packages. Update the system?"; then
      if ctx_sudo 'apt-get update && apt-get full-upgrade -y'; then info "System updated"; else setup_fail "System update failed"; fi
    else
      setup_skip "System updates"
    fi
  else
    info "System is up to date"
  fi
}

step_snap_cleanup() {
  local check_only="$2"
  [[ "$TGT_OS" == "Linux" ]] || return 0
  if ctx_run 'snap list 2>/dev/null | grep -q firmware-updater'; then
    if [[ "$check_only" == "1" ]]; then
      warn "firmware-updater snap should be removed"
    else
      ctx_sudo 'snap remove firmware-updater' && info "Removed snap firmware-updater" || true
    fi
  fi
}

step_ollama() {
  local auto_yes="$1" check_only="$2"
  if ctx_has ollama; then
    info "Ollama: installed"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "Ollama not installed"
  elif [[ "$TGT_OS" == "Darwin" ]]; then
    if ctx_has brew && { [[ "$auto_yes" == "1" ]] || confirm "Install Ollama with Homebrew?"; }; then
      if ctx_run 'brew install ollama'; then info "Installed Ollama"; else setup_fail "Ollama install failed"; fi
    else
      setup_manual_step "Install Ollama from https://ollama.com/download, then open it once to start the service"
    fi
  elif [[ "$auto_yes" == "1" ]] || confirm "Install Ollama (curl https://ollama.com/install.sh | sh)?"; then
    if ctx_run 'curl -fsSL https://ollama.com/install.sh | sh'; then info "Installed Ollama"; else setup_fail "Ollama install failed"; fi
  else
    setup_skip "Ollama install"
  fi

  ctx_has ollama || return 0
  if [[ "$SETUP_TARGET" == "local" ]] && ollama_reachable; then
    info "Ollama service: reachable on :11434"
  elif [[ "$SETUP_TARGET" == "remote" ]] && remote 'curl -fsS http://localhost:11434/api/version >/dev/null 2>&1'; then
    info "Ollama service: reachable on :11434"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "Ollama service not running on :11434"
  elif [[ "$TGT_OS" == "Darwin" ]]; then
    setup_manual_step "Start Ollama (open the app; it lives in the menu bar)"
  else
    info "Ollama runs as a systemd service (started by the installer)"
  fi
}

# Optional: connect the target to a tailnet for secure remote access.
step_tailscale() {
  local auto_yes="$1" check_only="$2" tk="tailscale-connected"
  [[ "$SETUP_TARGET" == "remote" ]] && tk="remote-tailscale-connected"
  if ctx_run 'command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1'; then
    info "Tailscale: installed and connected"
    return 0
  fi
  [[ "$check_only" == "1" ]] && { info "Tailscale: not configured (optional)"; return 0; }
  if ctx_has tailscale; then
    setup_manual_step "Connect the target to your tailnet: sudo tailscale up" "$tk"
  elif [[ "$TGT_OS" == "Darwin" ]]; then
    setup_manual_step "Install Tailscale from the Mac App Store, then run it" "$tk"
  elif [[ "$auto_yes" == "1" ]] || confirm "Install Tailscale on the target (curl https://tailscale.com/install.sh | sh)?"; then
    ctx_run 'curl -fsSL https://tailscale.com/install.sh | sh' && info "Installed Tailscale" || setup_fail "Tailscale install failed"
    setup_manual_step "Connect: sudo tailscale up (open the printed URL to authenticate)" "$tk"
  else
    setup_skip "Tailscale"
  fi
}

tailscale_funnel_status_active() {
  command -v tailscale >/dev/null 2>&1 || return 1
  tailscale status >/dev/null 2>&1 || return 1
  tailscale funnel status 2>/dev/null | grep -qE 'https?://'
}

tailscale_funnel_show_status() {
  tailscale funnel status 2>/dev/null || true
}

tailscale_funnel_reset() {
  tailscale funnel reset
}

tailscale_funnel_action_valid() {
  case "${1:-}" in
    ""|reset|abort) return 0 ;;
    *) return 1 ;;
  esac
}

tailscale_funnel_resolve_or_fail() {
  local mode="${1:-setup}" action="${2:-}" auto_yes="${3:-0}" check_only="${4:-0}" choice
  tailscale_funnel_action_valid "$action" || die "--funnel-action must be reset or abort"
  tailscale_funnel_status_active || return 0
  if [[ "$check_only" == "1" ]]; then
    setup_fail "Tailscale Funnel is active; public internet exposure must be removed"
    return 1
  fi
  if [[ "$action" == "reset" ]]; then
    if tailscale_funnel_reset && ! tailscale_funnel_status_active; then
      info "Tailscale Funnel reset"
      return 0
    fi
    setup_fail "Tailscale Funnel reset failed or Funnel is still active"
    return 1
  fi
  if [[ "$action" == "abort" ]]; then
    setup_fail "Tailscale Funnel is active; aborted by --funnel-action abort"
    return 1
  fi
  if [[ "$auto_yes" == "1" ]] || ! is_interactive; then
    setup_fail "Tailscale Funnel is active; rerun with --funnel-action reset or run 'tailscale funnel reset'"
    return 1
  fi
  while true; do
    printf "\n  ${YELLOW}${BOLD}Tailscale Funnel is active.${NC} Funnel exposes services to the internet.\n"
    printf "    ${BOLD}[1]${NC} Reset Funnel\n"
    printf "    ${BOLD}[2]${NC} Show status\n"
    printf "    ${BOLD}[3]${NC} Abort\n\n"
    printf "  > "
    read -r choice || true
    case "$choice" in
      1)
        if tailscale_funnel_reset && ! tailscale_funnel_status_active; then
          info "Tailscale Funnel reset"
          return 0
        fi
        setup_fail "Tailscale Funnel reset failed or Funnel is still active"
        return 1
        ;;
      2) tailscale_funnel_show_status ;;
      3|"") setup_fail "Tailscale Funnel is active; aborted"; return 1 ;;
      *) printf "    Enter 1, 2, or 3\n" ;;
    esac
  done
}

step_tailscale_funnel() {
  local auto_yes="$1" check_only="$2" action="${3:-}" choice
  tailscale_funnel_action_valid "$action" || die "--funnel-action must be reset or abort"
  ctx_run 'command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1' >/dev/null 2>&1 || return 0
  ctx_run "tailscale funnel status 2>/dev/null | grep -qE 'https?://'" >/dev/null 2>&1 || return 0
  if [[ "$check_only" == "1" ]]; then
    setup_fail "Tailscale Funnel is active; public internet exposure must be removed"
    return 1
  fi
  if [[ "$action" == "reset" ]]; then
    if ctx_run 'tailscale funnel reset' && ! ctx_run "tailscale funnel status 2>/dev/null | grep -qE 'https?://'" >/dev/null 2>&1; then
      info "Tailscale Funnel reset"
      return 0
    fi
    setup_fail "Tailscale Funnel reset failed or Funnel is still active"
    return 1
  fi
  if [[ "$action" == "abort" ]]; then
    setup_fail "Tailscale Funnel is active; aborted by --funnel-action abort"
    return 1
  fi
  if [[ "$auto_yes" == "1" ]] || ! is_interactive; then
    setup_fail "Tailscale Funnel is active; rerun with --funnel-action reset or run 'tailscale funnel reset'"
    return 1
  fi
  while true; do
    printf "\n  ${YELLOW}${BOLD}Tailscale Funnel is active.${NC} Funnel exposes services to the internet.\n"
    printf "    ${BOLD}[1]${NC} Reset Funnel\n"
    printf "    ${BOLD}[2]${NC} Show status\n"
    printf "    ${BOLD}[3]${NC} Abort\n\n"
    printf "  > "
    read -r choice || true
    case "$choice" in
      1)
        if ctx_run 'tailscale funnel reset' && ! ctx_run "tailscale funnel status 2>/dev/null | grep -qE 'https?://'" >/dev/null 2>&1; then
          info "Tailscale Funnel reset"
          return 0
        fi
        setup_fail "Tailscale Funnel reset failed or Funnel is still active"
        return 1
        ;;
      2) ctx_run 'tailscale funnel status 2>/dev/null || true' || true ;;
      3|"") setup_fail "Tailscale Funnel is active; aborted"; return 1 ;;
      *) printf "    Enter 1, 2, or 3\n" ;;
    esac
  done
}

# The LiteLLM gateway runs in Docker on both backends. In --check we only verify Docker;
# otherwise we enable this backend's provider (plus optional cloud providers) and start it.
step_gateway() {
  local auto_yes="$1" check_only="$2"
  if ctx_run 'docker info >/dev/null 2>&1'; then
    info "Docker: available for the gateway"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "Docker not available — the LiteLLM gateway needs it"; return 0
  elif [[ "$TGT_OS" == "Darwin" ]]; then
    setup_manual_step "Install Docker Desktop (the gateway runs in a container): https://docs.docker.com/desktop/"; return 0
  else
    setup_fail "Docker not running — needed for the gateway"; return 0
  fi
  [[ "$check_only" == "1" ]] && return 0

  if [[ "$auto_yes" != "1" ]] && ! confirm "Set up the LiteLLM gateway (unified API for local + cloud models)?"; then
    setup_skip "LiteLLM gateway"; return 0
  fi

  if ctx_run "docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q 'ghcr.io/berriai/litellm'"; then
    info "LiteLLM image present"
  elif ctx_run "docker pull ${LITELLM_IMAGE}"; then
    info "Pulled ${LITELLM_IMAGE}"
  else
    setup_fail "LiteLLM image pull failed"; return 0
  fi

  local prov="vllm"; [[ "$TGT_BACKEND" == "ollama" ]] && prov="ollama"
  local gw_or=0 gw_zen=0 gw_tg=0 or_key="" zen_key="" tg_key=""
  if [[ "$auto_yes" != "1" ]]; then
    if confirm "Enable OpenRouter? (cloud, needs API key)"; then
      printf "  OpenRouter API key (blank to skip): "; read -rs or_key; printf "\n"; [[ -n "$or_key" ]] && gw_or=1
    fi
    if confirm "Enable Zen / OpenCode? (cloud, needs API key)"; then
      printf "  Zen API key (blank to skip): "; read -rs zen_key; printf "\n"; [[ -n "$zen_key" ]] && gw_zen=1
    fi
    if confirm "Enable Together AI? (cloud, needs API key)"; then
      printf "  Together AI API key (blank to skip): "; read -rs tg_key; printf "\n"; [[ -n "$tg_key" ]] && gw_tg=1
    fi
  fi

  local gw_json
  gw_json=$(jq -n \
    --argjson port "$GATEWAY_PORT" \
    --argjson vllm_en "$( [[ "$prov" == "vllm" ]] && echo true || echo false )" \
    --argjson ollama_en "$( [[ "$prov" == "ollama" ]] && echo true || echo false )" \
    --argjson or_en "$( [[ "$gw_or" == "1" ]] && echo true || echo false )" --arg or_key "$or_key" \
    --argjson zen_en "$( [[ "$gw_zen" == "1" ]] && echo true || echo false )" --arg zen_key "$zen_key" \
    --argjson tg_en "$( [[ "$gw_tg" == "1" ]] && echo true || echo false )" --arg tg_key "$tg_key" \
    '{enabled:true, port:$port, providers:{
        vllm:{enabled:$vllm_en, port:8000},
        ollama:{enabled:$ollama_en},
        openrouter:{enabled:$or_en, api_key:$or_key},
        zen:{enabled:$zen_en, api_key:$zen_key},
        together:{enabled:$tg_en, api_key:$tg_key}
      }}')

  # gateway_save_config writes the controller copy used by gateway_generate_litellm_yaml.
  gateway_save_config "$gw_json"

  if [[ "$SETUP_TARGET" == "remote" ]]; then
    ctx_run 'mkdir -p $HOME/.config/spark && chmod 700 $HOME/.config/spark'
    printf '%s\n' "$gw_json" | ctx_write_file '$HOME/.config/spark/gateway.json'
    ctx_run 'chmod 600 $HOME/.config/spark/gateway.json'
    local yaml; yaml="$(gateway_generate_litellm_yaml)"
    if [[ -n "$yaml" ]]; then
      printf '%s\n' "$yaml" | ctx_write_file '$HOME/.config/spark/litellm_config.yaml'
      ctx_run 'chmod 600 $HOME/.config/spark/litellm_config.yaml'
    fi
    local env_flags=""
    [[ -n "$or_key" ]] && env_flags+=" -e OPENROUTER_API_KEY='${or_key}'"
    [[ -n "$zen_key" ]] && env_flags+=" -e ZEN_API_KEY='${zen_key}'"
    [[ -n "$tg_key" ]] && env_flags+=" -e TOGETHER_API_KEY='${tg_key}'"
    ctx_run "docker rm -f ${GATEWAY_CONTAINER} 2>/dev/null || true"
    if ctx_run "docker run -d --network host -v ~/.config/spark/litellm_config.yaml:/app/config.yaml ${env_flags} --name ${GATEWAY_CONTAINER} --restart unless-stopped ${LITELLM_IMAGE} --config /app/config.yaml --host 127.0.0.1 --port ${GATEWAY_PORT}"; then
      info "LiteLLM gateway started on :${GATEWAY_PORT}"
    else
      setup_fail "Gateway failed to start"
    fi
  else
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${GATEWAY_CONTAINER}$"; then
      ( gateway_restart ) >/dev/null 2>&1 && info "Gateway restarted" || warn "Could not restart the gateway"
    else
      ( gateway_start ) && info "LiteLLM gateway started on :${GATEWAY_PORT}" || warn "Start it later: spark gateway start"
    fi
  fi
}

# OS hardening (Linux + systemd) so you can ALWAYS reach + operate the box even if a model exhausts
# RAM (real cause of the original wedge — see git history / docs):
#   1) swap kept ON + low swappiness: absorbs the one-time load peak; runtime stays in RAM.
#   2) early-OOM (earlyoom) kills the offending model early, before the kernel OOM-cascade.
#   3) control-plane protection: MemoryMin + OOMScoreAdjust=-1000 on sshd/dbus/tailscaled/logind/
#      resolved so the OOM killer can only hit the model, never the services you need to recover.
# earlyoom is the emergency backstop. Declarative: reconciles to '-m $EARLYOOM_MIN_FREE_PCT
# -s $EARLYOOM_MIN_SWAP_PCT' regardless of any old/divergent config (e.g. a -m 8 / -s 100 left from
# experiments). The -s threshold is LOW on purpose: earlyoom kills only when free RAM AND free swap
# are both nearly gone — so a legitimate load can borrow swap for its peak without being killed,
# while a true runaway (RAM + swap exhausted) still gets killed early.
step_earlyoom() {
  local auto_yes="$1" check_only="$2" want="$EARLYOOM_MIN_FREE_PCT" wsw="$EARLYOOM_MIN_SWAP_PCT" installed=0 active=0 cur_m cur_s
  local ef="${EARLYOOM_DEFAULT_FILE:-/etc/default/earlyoom}"
  ctx_run 'command -v earlyoom >/dev/null 2>&1' && installed=1
  ctx_run 'systemctl is-active --quiet earlyoom' && active=1
  cur_m="$(ctx_run "grep -oE -- '-m[ =][0-9]+' '$ef' 2>/dev/null | grep -oE '[0-9]+' | head -1")"
  cur_s="$(ctx_run "grep -oE -- '-s[ =][0-9]+' '$ef' 2>/dev/null | grep -oE '[0-9]+' | head -1")"
  if [[ "$installed" == "1" && "$active" == "1" && "$cur_m" == "$want" && "$cur_s" == "$wsw" ]]; then
    info "early-OOM: earlyoom active (-m ${want}% -s ${wsw}%, reclaim-protected backstop)"
    return 0
  fi
  if [[ "$check_only" == "1" ]]; then
    if [[ "$installed" != "1" ]]; then setup_fail "early-OOM not active — install earlyoom so a runaway model is killed before the box freezes"
    else setup_fail "earlyoom not at -m ${want}% -s ${wsw}% (found '-m ${cur_m:-none} -s ${cur_s:-none}') — re-run spark setup to reconcile"; fi
    return 0
  fi
  printf "    ${DIM}What: install/configure 'earlyoom' (-m ${want}%% -s ${wsw}%%): kill the memory hog when RAM is low.\n"
  printf "    Why: it kills the offending model EARLY, before the machine bogs down and locks you out.\n"
  printf "    The low -s lets a legitimate model LOAD borrow swap for its peak without being killed; it\n"
  printf "    only fires when RAM and swap are both nearly gone (a real runaway).${NC}\n"
  if [[ "$auto_yes" == "1" ]] || confirm "Install/repair earlyoom at -m ${want}% -s ${wsw}%?"; then
    if [[ "$installed" != "1" ]] && ! ctx_sudo 'apt-get update >/dev/null 2>&1 && apt-get install -y earlyoom >/dev/null 2>&1'; then
      setup_fail "Could not install earlyoom (apt)"; return 0
    fi
    printf 'EARLYOOM_ARGS="-m %s -s %s --avoid '\''(^|/)(systemd|sshd?|ssh|dbus)$'\'' --prefer '\''(^|/)(vllm|python|pt_main_thread)$'\''"\n' "$want" "$wsw" | ctx_sudo_write "$ef"
    if ctx_sudo 'systemctl enable --now earlyoom >/dev/null 2>&1; systemctl restart earlyoom'; then
      info "early-OOM: earlyoom set to -m ${want}% -s ${wsw}%"
    else
      setup_fail "Could not enable earlyoom"
    fi
  else
    setup_skip "early-OOM (earlyoom)"
  fi
}

# Protect the whole CONTROL PLANE so the OOM killer can only hit the model, never the services you
# need to reach + operate the box. The 2026-06-03 incident OOM-killed dbus and tailscaled (not just
# sshd), wedging the machine. Apply MemoryMin (reclaim-protected) + OOMScoreAdjust=-1000 (OOM-immune)
# to every critical unit that's installed. Declarative single drop-in per unit, idempotent.
step_control_plane_protect() {
  local auto_yes="$1" check_only="$2" u state mm oom
  local candidates=(ssh.service sshd.service dbus.service dbus-broker.service tailscaled.service systemd-logind.service systemd-resolved.service)
  local -a present=() unprotected=()
  for u in "${candidates[@]}"; do
    state="$(ctx_run "systemctl list-unit-files --no-legend $u 2>/dev/null | awk 'NR==1{print \$1}'")"
    [[ -z "$state" ]] && continue
    present+=("$u")
    mm="$(ctx_run "systemctl show -p MemoryMin --value $u 2>/dev/null")"
    oom="$(ctx_run "systemctl show -p OOMScoreAdjust --value $u 2>/dev/null")"
    [[ "$mm" == "536870912" && "$oom" == "-1000" ]] || unprotected+=("$u")
  done
  if [[ ${#present[@]} -eq 0 ]]; then
    info "control-plane: no systemd units to protect"
    return 0
  fi
  if [[ ${#unprotected[@]} -eq 0 ]]; then
    info "control-plane: OOM-protected (${present[*]})"
    return 0
  fi
  if [[ "$check_only" == "1" ]]; then
    setup_fail "control-plane not fully protected (${unprotected[*]}) — these can be OOM-killed and wedge the box"
    return 0
  fi
  printf "    ${DIM}What: reserve memory + make OOM-immune (OOMScoreAdjust=-1000) for the control plane\n"
  printf "    (sshd, dbus, tailscaled, logind, resolved) via drop-ins.\n"
  printf "    Why: when a model overruns memory the OOM killer must hit the MODEL, never the services you\n"
  printf "    need to reach and run the box. Last incident it killed dbus + tailscaled and the machine\n"
  printf "    became unusable. Protected, they stay alive so you can always connect and recover.${NC}\n"
  if [[ "$auto_yes" == "1" ]] || confirm "Protect control-plane services (${unprotected[*]})?"; then
    for u in "${unprotected[@]}"; do
      ctx_sudo "mkdir -p /etc/systemd/system/${u}.d"
      printf '[Service]\nMemoryAccounting=yes\nMemoryMin=512M\nOOMScoreAdjust=-1000\n' | ctx_sudo_write "/etc/systemd/system/${u}.d/10-spark-protect.conf"
    done
    ctx_sudo 'systemctl daemon-reload'
    for u in "${unprotected[@]}"; do
      ctx_sudo "systemctl reload ${u} 2>/dev/null || systemctl try-restart ${u} 2>/dev/null || true"
    done
    info "control-plane: protected (${unprotected[*]})"
  else
    setup_skip "control-plane protection"
  fi
}

# Keep swap ON (with a low swappiness), not off. A large model's LOAD transiently needs ~2x its
# weights; swap absorbs that one-time peak so the load completes, then the steady state fits in RAM
# (admission guarantees it) and swap goes idle — no runtime thrash. Removing swap was the wrong fix:
# it blocked large-model loads while doing nothing the earlyoom + control-plane protection don't.
# Declarative + idempotent: if the box already has enough active swap and the requested swappiness,
# it is a no-op. If not, it only manages /swapfile.spark as a top-up and never swapoffs an in-use file.
swap_clean_mib() {
  local value="$1"
  value="${value//[!0-9]/}"
  [[ "$value" =~ ^[0-9]+$ ]] || value=0
  printf "%s\n" "$value"
}

swap_swapon_total_mib() {
  local total
  total="$(ctx_run "swapon --show=SIZE --bytes --noheadings 2>/dev/null | awk 'BEGIN{seen=0; sum=0} /^[0-9]+$/ {seen=1; sum+=\$1} END{if (seen) printf \"%d\", int((sum + 1048575) / 1048576); else exit 1}'" 2>/dev/null)" || return 1
  swap_clean_mib "$total"
}

swap_proc_total_mib() {
  local total proc_file="${SPARK_PROC_SWAPS_FILE:-/proc/swaps}"
  total="$(ctx_run "awk 'NR > 1 && \$3 ~ /^[0-9]+$/ {seen=1; sum+=\$3} END{if (seen) printf \"%d\", int((sum + 1023) / 1024); else exit 1}' '$proc_file' 2>/dev/null" 2>/dev/null)" || return 1
  swap_clean_mib "$total"
}

swap_free_total_mib() {
  local total
  total="$(ctx_run "free -m 2>/dev/null | awk '/^Swap:/{print \$2}'" 2>/dev/null || true)"
  swap_clean_mib "$total"
}

swap_total_probe() {
  local total source free_total diag=""
  if total="$(swap_swapon_total_mib)"; then
    source="swapon"
  elif total="$(swap_proc_total_mib)"; then
    source="/proc/swaps"
  else
    total="$(swap_free_total_mib)"
    source="free"
  fi
  free_total="$(swap_free_total_mib)"
  if [[ "$source" != "free" && "$total" -gt 0 && "$free_total" -ne "$total" ]]; then
    diag="free=${free_total}MiB"
  fi
  printf "%s\t%s\t%s\n" "$total" "$source" "$diag"
}

swap_read_total() {
  local __mib="$1" __source="$2" __diag="$3" probe mib source diag
  probe="$(swap_total_probe)"
  IFS=$'\t' read -r mib source diag <<< "$probe"
  printf -v "$__mib" "%s" "${mib:-0}"
  printf -v "$__source" "%s" "${source:-unknown}"
  printf -v "$__diag" "%s" "${diag:-}"
}

swap_total_context() {
  local source="$1" diag="${2:-}"
  printf "via %s" "$source"
  [[ -n "$diag" ]] && printf " (%s)" "$diag"
}

swap_total_mib() {
  local total source diag
  swap_read_total total source diag
  printf "%s\n" "$total"
}

swap_cur_swappiness() {
  ctx_run 'sysctl -n vm.swappiness 2>/dev/null' 2>/dev/null | tr -d '[:space:]' || true
}

swap_target_mib() {
  printf "%s\n" $(( SWAP_PROVISION_GB * 1024 ))
}

swap_total_satisfies_target() {
  local total_mib="$1" target_mib="$2"
  if [[ "$target_mib" -le 0 ]]; then
    [[ "$total_mib" -gt 0 ]]
  else
    [[ "$total_mib" -ge "$target_mib" ]]
  fi
}

swap_file_size_mib() {
  local sf="$1" bytes
  bytes="$(ctx_run "stat -c%s '$sf' 2>/dev/null || stat -f%z '$sf' 2>/dev/null" 2>/dev/null | head -1 || true)"
  bytes="${bytes//[!0-9]/}"
  if [[ "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]]; then
    printf "%s\n" $(( (bytes + 1048575) / 1048576 ))
  else
    printf "0\n"
  fi
}

swap_file_active() {
  local sf="$1"
  ctx_run "swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq '$sf'" >/dev/null 2>&1
}

swap_file_used_mib() {
  local sf="$1" bytes
  bytes="$(ctx_run "swapon --show=NAME,USED --bytes --noheadings 2>/dev/null | awk -v sf='$sf' '\$1 == sf {print \$2; found=1} END {if (!found) print 0}'" 2>/dev/null | head -1 || true)"
  bytes="${bytes//[!0-9]/}"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  printf "%s\n" $(( (bytes + 1048575) / 1048576 ))
}

swap_file_state() {
  local sf="$1" size_mib active used_mib
  size_mib="$(swap_file_size_mib "$sf")"
  active="inactive"
  swap_file_active "$sf" && active="active"
  used_mib="$(swap_file_used_mib "$sf")"
  if [[ "$size_mib" -gt 0 ]]; then
    printf "%s, %sMiB, used %sMiB\n" "$active" "$size_mib" "$used_mib"
  else
    printf "missing\n"
  fi
}

swap_fail_reconcile() {
  local total_mib="$1" target_mib="$2" cur_sw="$3" sf="$4" next_action_msg="$5" total_source="$6" diag="${7:-}" state
  state="$(swap_file_state "$sf")"
  setup_fail "Could not reconcile swap: total=${total_mib}MiB $(swap_total_context "$total_source" "$diag"), target≥${target_mib}MiB, swappiness=${cur_sw:-?}/${SWAPPINESS}, ${sf} state=${state}; next: ${next_action_msg}"
}

swap_ensure_fstab_entry() {
  local sf="$1"
  ctx_sudo "set -e; tmp=\$(mktemp); if [ -f /etc/fstab ]; then awk -v sf='$sf' '\$1 != sf {print}' /etc/fstab > \"\$tmp\"; else : > \"\$tmp\"; fi; printf '%s none swap sw 0 0\n' '$sf' >> \"\$tmp\"; cat \"\$tmp\" > /etc/fstab; rm -f \"\$tmp\""
}

swap_recreate_and_activate_file() {
  local sf="$1" desired_mib="$2" was_active="$3"
  ctx_sudo "set -e; if [ '$was_active' = '1' ]; then swapoff '$sf'; fi; rm -f '$sf'; fallocate -l ${desired_mib}M '$sf' || dd if=/dev/zero of='$sf' bs=1M count=${desired_mib} status=none; chmod 600 '$sf'; mkswap '$sf' >/dev/null; swapon '$sf'"
}

swap_activate_existing_file() {
  local sf="$1"
  ctx_sudo "set -e; chmod 600 '$sf'; mkswap '$sf' >/dev/null 2>&1 || true; swapon '$sf'"
}

step_swap_ensure() {
  local auto_yes="$1" check_only="$2" sf="/swapfile.spark"
  local cur_sw total_mib total_source total_diag target_mib size_mib used_mib active gap_mib desired_mib next_action
  cur_sw="$(swap_cur_swappiness)"
  swap_read_total total_mib total_source total_diag
  target_mib="$(swap_target_mib)"
  if swap_total_satisfies_target "$total_mib" "$target_mib" && [[ "$cur_sw" == "$SWAPPINESS" ]]; then
    info "Swap: on (${total_mib}MiB total) $(swap_total_context "$total_source" "$total_diag") + swappiness=${SWAPPINESS} (absorbs load peaks; runtime stays in RAM)"
    return 0
  fi
  if [[ "$check_only" == "1" ]]; then
    if ! swap_total_satisfies_target "$total_mib" "$target_mib"; then
      setup_fail "Swap too small (${total_mib}MiB $(swap_total_context "$total_source" "$total_diag"), want ≥${target_mib}MiB) — large-model loads need it for their transient peak"
    fi
    [[ "$cur_sw" != "$SWAPPINESS" ]] && setup_fail "vm.swappiness=${cur_sw:-?} (want ${SWAPPINESS}) — runtime may swap the working set"
    return 0
  fi
  printf "    ${DIM}What: ensure ≥${SWAP_PROVISION_GB}G of swap (top up with ${sf} if needed) + vm.swappiness=${SWAPPINESS}.\n"
  printf "    Why: loading a big model briefly needs about twice its weights; swap absorbs that one-time\n"
  printf "    peak so the load finishes. The steady model fits in RAM (admission ensures it) and a low\n"
  printf "    swappiness keeps it there, so swap stays idle at runtime — no thrash. earlyoom + protected\n"
  printf "    system services handle a genuine runaway. (Complements any existing swap — never replaces it.)${NC}\n"
  if [[ "$auto_yes" == "1" ]] || confirm "Ensure ≥${SWAP_PROVISION_GB}G swap + swappiness=${SWAPPINESS}?"; then
    if ! swap_total_satisfies_target "$total_mib" "$target_mib" && [[ "$target_mib" -gt 0 ]]; then
      gap_mib=$(( target_mib - total_mib ))
      [[ "$gap_mib" -lt 0 ]] && gap_mib=0
      size_mib="$(swap_file_size_mib "$sf")"
      used_mib="$(swap_file_used_mib "$sf")"
      active=0
      swap_file_active "$sf" && active=1
      desired_mib="$gap_mib"
      [[ "$active" == "1" ]] && desired_mib=$(( size_mib + gap_mib ))
      if [[ "$active" == "1" && "$used_mib" -gt 0 ]]; then
        swap_fail_reconcile "$total_mib" "$target_mib" "$cur_sw" "$sf" "stop memory pressure or reboot, then rerun spark setup so ${sf} can be resized safely" "$total_source" "$total_diag"
        return 0
      elif [[ "$size_mib" -le 0 || "$size_mib" -ne "$desired_mib" ]]; then
        next_action="create ${sf} at ${desired_mib}MiB and activate it"
        [[ "$active" == "1" ]] && next_action="recreate ${sf} at ${desired_mib}MiB and reactivate it"
        if ! swap_recreate_and_activate_file "$sf" "$desired_mib" "$active"; then
          swap_fail_reconcile "$total_mib" "$target_mib" "$cur_sw" "$sf" "$next_action" "$total_source" "$total_diag"
          return 0
        fi
      elif [[ "$active" != "1" ]]; then
        if ! swap_activate_existing_file "$sf"; then
          swap_fail_reconcile "$total_mib" "$target_mib" "$cur_sw" "$sf" "activate existing ${sf}" "$total_source" "$total_diag"
          return 0
        fi
      fi
      if ! swap_ensure_fstab_entry "$sf"; then
        swap_fail_reconcile "$total_mib" "$target_mib" "$cur_sw" "$sf" "ensure one ${sf} entry in /etc/fstab" "$total_source" "$total_diag"
        return 0
      fi
    fi
    if [[ "$cur_sw" != "$SWAPPINESS" ]]; then
      printf 'vm.swappiness=%s\n' "$SWAPPINESS" | ctx_sudo_write /etc/sysctl.d/99-spark.conf
      if ! ctx_sudo "sysctl --system >/dev/null 2>&1 || sysctl -w vm.swappiness=${SWAPPINESS} >/dev/null"; then
        swap_fail_reconcile "$total_mib" "$target_mib" "$cur_sw" "$sf" "apply vm.swappiness=${SWAPPINESS}" "$total_source" "$total_diag"
        return 0
      fi
    fi
    swap_read_total total_mib total_source total_diag
    cur_sw="$(swap_cur_swappiness)"
    if swap_total_satisfies_target "$total_mib" "$target_mib" && [[ "$cur_sw" == "$SWAPPINESS" ]]; then
      info "Swap: on (${total_mib}MiB total) $(swap_total_context "$total_source" "$total_diag") + swappiness=${SWAPPINESS}"
    else
      swap_fail_reconcile "$total_mib" "$target_mib" "$cur_sw" "$sf" "inspect sudo command output above and rerun spark setup" "$total_source" "$total_diag"
    fi
  else
    setup_skip "Swap configuration"
  fi
}

# The one install set — identical software whether the target is local or remote.
run_install_set() {
  local auto_yes="$1" check_only="$2"
  step_apt_upgrade "$auto_yes" "$check_only"
  if [[ "$TGT_BACKEND" == "ollama" ]]; then
    step_ollama "$auto_yes" "$check_only"
  else
    step_gpu_check "$auto_yes" "$check_only"
    step_docker_check "$auto_yes" "$check_only"
    step_docker_group "$auto_yes" "$check_only"
    step_nvidia_ctk "$auto_yes" "$check_only"
    step_ngc_login "$auto_yes" "$check_only"
    step_vllm_image "$auto_yes" "$check_only"
    step_uv "$auto_yes" "$check_only"
    step_hf_cli "$auto_yes" "$check_only"
    step_nvitop "$auto_yes" "$check_only"
  fi
  step_jq "$auto_yes" "$check_only"
  step_gateway "$auto_yes" "$check_only"
  if [[ "$TGT_OS" == "Linux" ]] && ctx_has systemctl; then
    step_swap_ensure "$auto_yes" "$check_only"
    step_earlyoom "$auto_yes" "$check_only"
    step_control_plane_protect "$auto_yes" "$check_only"
  fi
}

# --- Client-side helpers (run on the controller in remote mode) ---

ensure_local_ssh_key() {
  local auto_yes="$1" check_only="$2"
  if [[ -f "${HOME}/.ssh/id_ed25519.pub" || -f "${HOME}/.ssh/id_rsa.pub" ]]; then
    info "SSH key pair exists"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "No SSH key pair found"
  elif [[ "$auto_yes" == "1" ]] || confirm "No SSH key found. Generate one?"; then
    mkdir -p "${HOME}/.ssh"
    ssh-keygen -t ed25519 -f "${HOME}/.ssh/id_ed25519" -N "" -q
    info "Generated SSH key: ~/.ssh/id_ed25519"
  else
    setup_skip "SSH key generation"
  fi
}

ensure_local_tailscale() {
  local auto_yes="$1" check_only="$2"
  if local_tailscale status >/dev/null 2>&1; then
    info "Tailscale: installed and connected (this machine)"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "Tailscale not installed/connected (this machine)"
  elif [[ "$SPARK_OS" == "Darwin" ]]; then
    setup_manual_step "Install Tailscale from the Mac App Store or https://tailscale.com/download" "tailscale-installed"
    local_tailscale status >/dev/null 2>&1 || setup_manual_step "Connect Tailscale: open the app and sign in" "tailscale-connected"
  elif [[ "$auto_yes" == "1" ]] || confirm "Install Tailscale?"; then
    curl -fsSL https://tailscale.com/install.sh | sh && info "Installed Tailscale" || setup_fail "Tailscale install failed"
    local_tailscale status >/dev/null 2>&1 || setup_manual_step "Connect: sudo tailscale up" "tailscale-connected"
  else
    setup_skip "Tailscale (this machine)"
  fi
}

# Copy this CLI to the remote so `spark` is available there too.
deploy_spark_binary() {
  local self helper rv
  self=$(command -v spark 2>/dev/null || echo "${BASH_SOURCE[0]}")
  helper="$(hf_model_inspect_path 2>/dev/null || true)"
  # Always overwrite the remote binary with this controller's copy, so the server runs the exact
  # same spark version every setup run (no stale CLI lingering on the server).
  remote 'mkdir -p ~/.local/bin'
  remote_in 'cat > ~/.local/bin/spark && chmod +x ~/.local/bin/spark' < "$self"
  if [[ -n "$helper" ]]; then
    remote 'mkdir -p ~/.local/share/spark/scripts'
    remote_in 'cat > ~/.local/share/spark/scripts/hf_model_inspect.py && chmod +x ~/.local/share/spark/scripts/hf_model_inspect.py' < "$helper"
  else
    setup_fail "Hugging Face inspector not found locally; cannot deploy spark runtime helper"
  fi
  remote 'grep -q "local/bin" ~/.bashrc 2>/dev/null' || remote 'echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.bashrc'
  # Verify the deployed version matches this controller's — surfaces a botched copy immediately.
  rv="$(remote 'grep -m1 "^VERSION=" ~/.local/bin/spark 2>/dev/null | cut -d\" -f2')"
  if [[ "$rv" == "$VERSION" ]]; then
    info "Installed spark CLI v${VERSION} to ~/.local/bin/spark (remote, matches controller)"
  else
    setup_fail "spark CLI copy mismatch (remote '${rv:-none}' vs controller '${VERSION}') — re-run setup"
  fi
}

# --- Remote-only secure phase ---

step_copy_pubkey() {
  local check_only="$2" pub=""
  if [[ "$check_only" == "1" ]]; then
    remote 'test -s ~/.ssh/authorized_keys' 2>/dev/null && info "SSH authorized_keys present on remote" || setup_fail "No SSH authorized_keys on remote"
    return 0
  fi
  if [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
    pub=$(cat "${HOME}/.ssh/id_ed25519.pub")
  elif [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
    pub=$(cat "${HOME}/.ssh/id_rsa.pub")
  fi
  if [[ -n "$pub" ]]; then
    remote 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'
    printf '%s\n' "$pub" | remote_in 'cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
    info "Copied SSH public key to remote"
  else
    setup_skip "SSH key copy (no local key found)"
  fi
}

step_disable_password_ssh() {
  local auto_yes="$1" check_only="$2"
  if remote "grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config" 2>/dev/null; then
    info "Password SSH login disabled"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "Password SSH login not disabled"
  elif [[ "$auto_yes" == "1" ]] || confirm "Disable password SSH login on the remote (key-only auth)?"; then
    ctx_sudo "sed -i 's/.*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config"
    ctx_sudo 'systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true'
    info "Disabled password SSH login"
  else
    setup_skip "Disable password SSH"
  fi
}

# Host mode never disables password auth automatically (you could lock yourself out if your
# key isn't installed). Warn and let the user decide.
setup_local_secure_warn() {
  [[ "$TGT_OS" == "Linux" ]] || return 0
  if grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config 2>/dev/null; then
    info "Password SSH login already disabled"
  else
    warn "Password SSH auth is still enabled on this machine."
    printf "    ${DIM}spark won't disable it automatically in host mode — you could lock yourself out\n"
    printf "    if your key isn't installed. To harden manually once key auth works:\n"
    printf "    sudo sed -i 's/.*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && sudo systemctl reload ssh${NC}\n"
  fi
}

# --- SSH bootstrap (first login to a brand-new server) ---

# Use sshpass for the very first connection when the user has no key yet, then switch to the
# key after it's installed. Falls back to interactive SSH if sshpass isn't available.
ensure_sshpass() {
  command -v sshpass >/dev/null 2>&1 && return 0
  if [[ "$SPARK_OS" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
    warn "sshpass isn't installed (needed for password bootstrap)."
    if confirm "Install sshpass via Homebrew (tap hudochenkov/sshpass)?"; then
      brew install hudochenkov/sshpass/sshpass >/dev/null 2>&1 && command -v sshpass >/dev/null 2>&1 && return 0
    fi
  fi
  warn "Proceeding without sshpass — SSH will prompt for the password interactively."
  return 1
}

open_remote_bootstrap() {
  local want_pw="$1" pw=""
  REMOTE_CONTROL="/tmp/spark-setup-${REMOTE_USER}@${REMOTE_HOST}"
  if [[ "$want_pw" == "1" ]]; then
    printf "  Enter the SSH password for %s@%s: " "$REMOTE_USER" "$REMOTE_HOST"
    read -rs pw; printf "\n"
    if [[ -n "$pw" ]] && ensure_sshpass; then
      SETUP_USED_SSHPASS=1
      printf "  Connecting to %s@%s...\n" "$REMOTE_USER" "$REMOTE_HOST"
      SSHPASS="$pw" sshpass -e ssh \
        -o ControlMaster=yes -o ControlPath="$REMOTE_CONTROL" \
        -o ControlPersist=600 -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -fN "${REMOTE_USER}@${REMOTE_HOST}" || { pw=""; return 1; }
      pw=""
      info "Connected to ${REMOTE_HOST} (password bootstrap)"
      return 0
    fi
    pw=""
  fi
  open_remote "$REMOTE_USER" "$REMOTE_HOST"
}

# After the key is installed, drop sshpass and reconnect by key. Proving the key works BEFORE
# disabling password auth guarantees we never lock the user out.
reopen_remote_keybased() {
  [[ "$SETUP_USED_SSHPASS" == "1" ]] || return 0
  close_remote
  if open_remote "$REMOTE_USER" "$REMOTE_HOST"; then
    SETUP_USED_SSHPASS=0
    info "Switched to key-based SSH"
    return 0
  fi
  die "Key-based reconnect failed — leaving password auth ON for safety" \
      "Your key may not have installed correctly; fix it before disabling password auth"
}

# --- Orchestrators ---

setup_local() {
  local auto_yes="$1" check_only="$2" funnel_action="${3:-}"
  SETUP_TARGET="local"
  detect_target_platform

  printf "\n  ${BOLD}spark setup${NC} — set up this machine as a model server\n\n"
  info "Detected: ${TGT_OS}/${TGT_ARCH} · accelerator ${TGT_ACCEL} · backend ${TGT_BACKEND}"
  printf "\n"

  run_install_set "$auto_yes" "$check_only"

  if [[ "$check_only" != "1" ]]; then
    step_tailscale "$auto_yes" "$check_only"
    step_tailscale_funnel "$auto_yes" "$check_only" "$funnel_action" || true
    setup_local_secure_warn
    printf "\n  ${DIM}Running doctor...${NC}\n"
    cmd_doctor || true
  else
    step_tailscale_funnel "$auto_yes" "$check_only" "$funnel_action" || true
  fi
}

setup_remote() {
  local auto_yes="$1" check_only="$2" funnel_action="${3:-}" spec want_pw=0
  SETUP_TARGET="remote"

  printf "\n  ${BOLD}spark setup${NC} — configure a remote machine over SSH\n\n"
  printf "  ${BLUE}${BOLD}Phase 0: Connect${NC}\n\n"
  printf "  Enter the target as ${BOLD}user@host${NC} (e.g. me@10.0.0.5): "
  read -r spec || true
  [[ -z "$spec" ]] && die "A target user@host is required"
  [[ "$spec" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ ]] || die "Invalid target: $spec" "Use the form user@host"
  REMOTE_USER="${spec%@*}"
  REMOTE_HOST="${spec#*@}"

  if confirm "Do you already have public-key SSH access to ${REMOTE_HOST}?"; then
    want_pw=0
  else
    want_pw=1
  fi

  trap close_remote EXIT
  open_remote_bootstrap "$want_pw" || die "Could not connect to ${spec}" "Check the address, SSH access, and password"
  detect_target_platform
  info "Remote: ${TGT_OS}/${TGT_ARCH} · backend ${TGT_BACKEND}"
  printf "\n"

  printf "  ${BLUE}${BOLD}Phase 1: Client${NC}\n"
  printf "  ${DIM}Prepares this machine to talk to the remote over a private network.${NC}\n\n"
  ensure_local_tailscale "$auto_yes" "$check_only"
  ensure_local_ssh_key "$auto_yes" "$check_only"
  [[ "$check_only" != "1" ]] && deploy_spark_binary
  printf "\n"

  printf "  ${BLUE}${BOLD}Phase 2: Remote install${NC}\n"
  printf "  ${DIM}Installs the same model-serving stack used in host mode.${NC}\n\n"
  step_snap_cleanup "$auto_yes" "$check_only"
  run_install_set "$auto_yes" "$check_only"
  step_tailscale "$auto_yes" "$check_only"
  step_tailscale_funnel "$auto_yes" "$check_only" "$funnel_action" || true
  printf "\n"

  printf "  ${BLUE}${BOLD}Phase 3: Secure connection${NC}\n"
  printf "  ${DIM}Installs your key, then locks SSH to key-only auth.${NC}\n\n"
  step_copy_pubkey "$auto_yes" "$check_only"
  if [[ "$check_only" != "1" ]]; then
    reopen_remote_keybased
    step_disable_password_ssh "$auto_yes" "$check_only"
    [[ "$SPARK_OS" == "Darwin" ]] && setup_manual_step "Install NVIDIA Sync from nvidia.com/sync (optional file sync)" ""
  else
    step_disable_password_ssh "$auto_yes" "$check_only"
  fi

  close_remote
  trap - EXIT
}

run_setup_wizard() {
  local auto_yes="$1" check_only="$2" funnel_action="${3:-}" pick=""
  printf "\n  ${BOLD}spark setup${NC} — what do you want to set up?\n\n"
  printf "    ${BOLD}[1]${NC} This machine\n"
  printf "    ${BOLD}[2]${NC} Another machine over SSH\n\n"
  printf "  > "
  read -r pick || true
  case "$pick" in
    1) setup_local "$auto_yes" "$check_only" "$funnel_action" ;;
    2) setup_remote "$auto_yes" "$check_only" "$funnel_action" ;;
    "")
      # No input (e.g. `spark setup --check </dev/null` in CI) → check THIS machine.
      if [[ "$check_only" == "1" ]]; then
        setup_local "$auto_yes" "$check_only" "$funnel_action"
      else
        die "Enter 1 (this machine) or 2 (another machine)"
      fi
      ;;
    *) die "Enter 1 (this machine) or 2 (another machine)" ;;
  esac
}

setup_summary() {
  printf "\n"
  if [[ ${#SETUP_FAILED[@]} -gt 0 ]]; then
    printf "  ${RED}${BOLD}Setup incomplete:${NC} %d issue(s)\n" "${#SETUP_FAILED[@]}"
    for step in "${SETUP_FAILED[@]}"; do printf "    ${RED}✗${NC} %s\n" "$step"; done
    printf "\n  Fix them and re-run: ${BOLD}spark setup${NC}\n\n"
    return 1
  elif [[ ${#SETUP_SKIPPED[@]} -gt 0 ]]; then
    printf "  ${YELLOW}${BOLD}Skipped steps:${NC}\n"
    for step in "${SETUP_SKIPPED[@]}"; do printf "    ${YELLOW}⊘${NC} %s\n" "$step"; done
    printf "\n  Re-run ${BOLD}spark setup${NC} to complete them later.\n\n"
  elif [[ "$SETUP_TARGET" == "remote" ]]; then
    printf "  ${GREEN}${BOLD}Setup complete!${NC}\n"
    printf "  Connect: ${BOLD}ssh %s@%s${NC}\n" "$REMOTE_USER" "$REMOTE_HOST"
    printf "  Then:    ${BOLD}spark run <model>${NC}\n\n"
  else
    printf "  ${GREEN}${BOLD}Setup complete!${NC} This machine is ready to serve models.\n"
    printf "  Start one:  ${BOLD}spark run <model>${NC}\n"
    printf "  Gateway:    ${BOLD}http://localhost:%s/v1${NC}\n\n" "$GATEWAY_PORT"
  fi
}

cmd_setup_help() {
  cat <<EOF

  ${BOLD}Usage:${NC} spark setup [--check] [--yes] [--full] [--model MODEL] [--tailscale-mode services|ports] [--funnel-action reset|abort]

  Sets up this machine, or a remote machine over SSH, as a model server.
  With --full, also sets up the private agent workspace.

  ${BOLD}Flags:${NC}
    --check                 Read-only validation. Does not install, write config, or reset Funnel.
    --yes                   Accept safe defaults. Does not reset Funnel by itself.
    --full                  Set up model server + agent workspace.
    --model MODEL           Workspace/Hermes model. Required for remote --full unless --check.
    --tailscale-mode MODE   Workspace private access mode: default services; use ports to keep port URLs.
    --funnel-action reset   If Funnel is active, run 'tailscale funnel reset' and re-check.
    --funnel-action abort   If Funnel is active, fail without changing Funnel.

  ${BOLD}Funnel rule:${NC}
    Use reset only when this host should not expose anything to the public internet through Funnel.
    Use abort when Funnel may be intentionally configured for another service and you want to inspect it first.

EOF
}

cmd_setup_full_workspace() {
  local auto_yes="$1" check_only="$2" funnel_action="$3" model="$4" tail_mode="$5" args=()
  printf "\n  ${BOLD}spark setup --full${NC} — agent workspace\n"
  if [[ "$SETUP_TARGET" == "remote" ]]; then
    if [[ "$check_only" != "1" && -z "$model" ]]; then
      die "--model is required with remote spark setup --full" \
          "Example: spark setup --full --model Org/Model"
    fi
    args+=(--remote "${REMOTE_USER}@${REMOTE_HOST}")
  fi
  [[ "$auto_yes" == "1" ]] && args+=(--yes)
  [[ "$check_only" == "1" ]] && args+=(--check)
  [[ -n "$model" ]] && args+=(--model "$model")
  [[ -n "$tail_mode" ]] && args+=(--tailscale-mode "$tail_mode")
  [[ -n "$funnel_action" ]] && args+=(--funnel-action "$funnel_action")
  workspace_setup "${args[@]}"
}

cmd_setup() {
  local auto_yes=0 check_only=0 full=0 funnel_action="" full_model="" full_tail_mode="" setup_rc=0 workspace_rc=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes)     auto_yes=1; shift ;;
      --check)   check_only=1; shift ;;
      --full)    full=1; shift ;;
      --model)   full_model="${2:-}"; [[ -n "$full_model" ]] || die "--model requires a value"; shift 2 ;;
      --tailscale-mode)
        full_tail_mode="${2:-}"
        case "$full_tail_mode" in
          services|ports) ;;
          "") die "--tailscale-mode requires services or ports" ;;
          *)  die "--tailscale-mode must be 'services' or 'ports'" ;;
        esac
        shift 2
        ;;
      --funnel-action)
        funnel_action="${2:-}"
        tailscale_funnel_action_valid "$funnel_action" || die "--funnel-action must be reset or abort"
        shift 2
        ;;
      -h|--help) cmd_setup_help; return 0 ;;
      *)         die "Unknown flag: $1" "Usage: spark setup [--check] [--yes] [--full] [--model MODEL] [--tailscale-mode services|ports] [--funnel-action reset|abort]" ;;
    esac
  done

  SETUP_SKIPPED=()
  SETUP_FAILED=()
  SUDO_PW=""; SUDO_READY=0

  run_setup_wizard "$auto_yes" "$check_only" "$funnel_action"
  SUDO_PW=""   # don't keep the password resident after setup
  setup_summary || setup_rc=$?
  if [[ "$full" == "1" ]]; then
    if [[ "$setup_rc" -ne 0 && "$check_only" != "1" ]]; then
      printf "  ${YELLOW}Workspace setup skipped because base setup still has unresolved issue(s).${NC}\n\n"
      return "$setup_rc"
    fi
    cmd_setup_full_workspace "$auto_yes" "$check_only" "$funnel_action" "$full_model" "$full_tail_mode" || workspace_rc=$?
  fi
  [[ "$setup_rc" -ne 0 ]] && return "$setup_rc"
  return "$workspace_rc"
}

manual_check_passed() {
  case "${1:-}" in
    "") return 0 ;;
    tailscale-connected) local_tailscale status >/dev/null 2>&1 ;;
    tailscale-installed) local_tailscale status >/dev/null 2>&1 || command -v tailscale >/dev/null 2>&1 ;;
    remote-tailscale-connected) remote "tailscale status" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

setup_manual_step() {
  local instruction="$1"
  local check_key="${2:-}"

  printf "\n  ${YELLOW}⊘${NC} %s\n" "$instruction"
  printf "\n    [d] Done  [s] Skip  [?] More info\n"

  while true; do
    printf "    > "
    read -r choice
    case "$choice" in
      d|D)
        if [[ -n "$check_key" ]]; then
          if manual_check_passed "$check_key"; then
            info "Verified"
            return 0
          else
            printf "    ${RED}Doesn't seem configured yet. Try again?${NC}\n"
            continue
          fi
        else
          info "Marked as done"
          return 0
        fi
        ;;
      s|S)
        setup_skip "$instruction"
        warn "Skipped"
        return 0
        ;;
      \?)
        printf "    ${DIM}See README for detailed instructions on this step.${NC}\n"
        continue
        ;;
      *)
        printf "    Enter d (done), s (skip), or ? (more info)\n"
        ;;
    esac
  done
}
