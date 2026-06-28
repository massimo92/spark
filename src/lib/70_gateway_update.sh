# --- Update Check ---
get_update_config() {
  local key="$1" default="${2:-}"
  if [[ -f "$UPDATE_FILE" ]] && command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" --arg d "$default" '.[$k] // $d' "$UPDATE_FILE" 2>/dev/null || echo "$default"
  else
    echo "$default"
  fi
}

save_update_config() {
  mkdir -p "$SPARK_CONFIG_DIR"
  local last_check="$1" auto_update="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg lc "$last_check" --argjson au "$auto_update" \
      '{last_check: $lc, auto_update: $au}' > "$UPDATE_FILE"
  fi
}

# --- Gateway Config ---
gateway_load_config() {
  if [[ -f "$GATEWAY_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
    jq -r '.' "$GATEWAY_CONFIG" 2>/dev/null
  else
    echo '{}'
  fi
}

gateway_save_config() {
  mkdir -p "$SPARK_CONFIG_DIR"
  chmod 700 "$SPARK_CONFIG_DIR" 2>/dev/null || true
  local old_umask
  old_umask=$(umask)
  umask 077
  printf '%s\n' "$1" > "$GATEWAY_CONFIG"
  chmod 600 "$GATEWAY_CONFIG"
  umask "$old_umask"
}

gateway_provider_enabled() {
  local provider="$1"
  local config
  config=$(gateway_load_config)
  echo "$config" | jq -r --arg p "$provider" '.providers[$p].enabled // false' 2>/dev/null
}

gateway_get_api_key() {
  local provider="$1"
  local config
  config=$(gateway_load_config)
  echo "$config" | jq -r --arg p "$provider" '.providers[$p].api_key // ""' 2>/dev/null
}

gateway_generate_litellm_yaml() {
  local config
  config=$(gateway_load_config)
  local vllm_port
  vllm_port=$(echo "$config" | jq -r '.providers.vllm.port // 8000' 2>/dev/null)

  local yaml="model_list:"
  local has_models=0

  # vLLM — one explicit entry per running model (routes to its own port),
  # plus the wildcard passthrough for backwards compatibility.
  if [[ "$(echo "$config" | jq -r '.providers.vllm.enabled // false')" == "true" ]]; then
    local primary_port="" name model port rest
    while IFS=$'\t' read -r name model port rest; do
      [[ -z "$model" ]] && continue
      yaml+="
  - model_name: \"vllm/${model}\"
    litellm_params:
      model: \"openai/${model}\"
      api_base: \"http://localhost:${port}/v1\"
      api_key: \"dummy\""
      has_models=1
      [[ -z "$primary_port" ]] && primary_port="$port"   # first model
      [[ "$port" == "$vllm_port" ]] && primary_port="$port"  # prefer the default port
    done < <(list_managed_containers)
    [[ -z "$primary_port" ]] && primary_port="$vllm_port"

    yaml+="
  - model_name: \"vllm/*\"
    litellm_params:
      model: \"openai/*\"
      api_base: \"http://localhost:${primary_port}/v1\"
      api_key: \"dummy\""
    has_models=1
  fi

  # OpenRouter
  if [[ "$(echo "$config" | jq -r '.providers.openrouter.enabled // false')" == "true" ]]; then
    yaml+="
  - model_name: \"openrouter/*\"
    litellm_params:
      model: \"openrouter/*\"
      api_key: \"os.environ/OPENROUTER_API_KEY\""
    has_models=1
  fi

  # Ollama — use the chat endpoint (LiteLLM-recommended). The gateway runs in Docker:
  # on macOS it reaches the host's native Ollama via host.docker.internal; on Linux it
  # shares the host network, so localhost works.
  if [[ "$(echo "$config" | jq -r '.providers.ollama.enabled // false')" == "true" ]]; then
    local ollama_host="localhost"
    [[ "$SPARK_OS" == "Darwin" ]] && ollama_host="host.docker.internal"
    yaml+="
  - model_name: \"ollama_chat/*\"
    litellm_params:
      model: \"ollama_chat/*\"
      api_base: \"http://${ollama_host}:11434\""
    has_models=1
  fi

  # Zen (OpenCode)
  if [[ "$(echo "$config" | jq -r '.providers.zen.enabled // false')" == "true" ]]; then
    yaml+="
  - model_name: \"zen/*\"
    litellm_params:
      model: \"openai/*\"
      api_base: \"https://opencode.ai/zen/v1\"
      api_key: \"os.environ/ZEN_API_KEY\""
    has_models=1
  fi

  # Together AI
  if [[ "$(echo "$config" | jq -r '.providers.together.enabled // false')" == "true" ]]; then
    yaml+="
  - model_name: \"together/*\"
    litellm_params:
      model: \"together_ai/*\"
      api_key: \"os.environ/TOGETHER_API_KEY\""
    has_models=1
  fi

  if [[ "$has_models" -eq 0 ]]; then
    return 1
  fi

  local port
  port=$(echo "$config" | jq -r '.port // 4000' 2>/dev/null)
  yaml+="

general_settings:
  master_key: null

litellm_settings:
  drop_params: true
  num_retries: 2"

  printf '%s\n' "$yaml"
}

check_for_updates() {
  # Skip in non-interactive or if jq/curl missing
  [[ ! -t 1 ]] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  command -v curl >/dev/null 2>&1 || return 0

  # Check at most once per day
  local today
  today=$(date +%Y-%m-%d)
  local last_check
  last_check=$(get_update_config "last_check" "")
  [[ "$last_check" == "$today" ]] && return 0

  local auto_update
  auto_update=$(get_update_config "auto_update" "false")

  local updates=()

  # Check spark CLI version
  local remote_version
  remote_version=$(curl -fsSL --max-time 3 \
    "https://raw.githubusercontent.com/${GITHUB_REPO}/main/spark" 2>/dev/null \
    | grep -m1 '^VERSION=' | sed 's/VERSION="//' | sed 's/"//' || true)
  if [[ -n "$remote_version" && "$remote_version" != "$VERSION" ]]; then
    updates+=("spark CLI: ${VERSION} → ${remote_version}")
  fi

  # Check NGC container
  local current_ngc
  current_ngc=$(detect_ngc_image)
  if [[ -n "$current_ngc" ]]; then
    local current_tag="${current_ngc##*:}"
    # Check a few common next tags (monthly releases: YY.MM-py3)
    local year month next_tag
    year=$(date +%y)
    month=$(date +%m)
    next_tag="${year}.$(printf '%02d' "$month")-py3"
    if [[ "$next_tag" != "$current_tag" ]]; then
      if docker manifest inspect "nvcr.io/nvidia/vllm:${next_tag}" >/dev/null 2>&1; then
        updates+=("NGC vLLM: ${current_tag} → ${next_tag}")
      fi
    fi
  fi

  # Save check timestamp
  save_update_config "$today" "$auto_update"

  [[ ${#updates[@]} -eq 0 ]] && return 0

  if [[ "$auto_update" == "true" ]]; then
    printf "\n  ${BLUE}${BOLD}Auto-updating...${NC}\n"
    for u in "${updates[@]}"; do
      if [[ "$u" == spark* ]]; then
        local self
        self=$(command -v spark 2>/dev/null || echo "${BASH_SOURCE[0]}")
        curl -fsSL --max-time 10 \
          "https://raw.githubusercontent.com/${GITHUB_REPO}/main/spark" -o "${self}.tmp" 2>/dev/null
        if [[ -s "${self}.tmp" ]] && bash -n "${self}.tmp" 2>/dev/null; then
          chmod +x "${self}.tmp" && mv "${self}.tmp" "$self" \
            && info "Updated $u" || { rm -f "${self}.tmp"; warn "Failed to update spark CLI"; }
        else
          rm -f "${self}.tmp"
          warn "Failed to update spark CLI (invalid download)"
        fi
      elif [[ "$u" == NGC* ]]; then
        local tag="${u##*→ }"
        docker pull "nvcr.io/nvidia/vllm:${tag}" >/dev/null 2>&1 \
          && info "Updated $u" || warn "Failed to update NGC container"
      fi
    done
    printf "\n"
  else
    printf "\n  ${YELLOW}${BOLD}Updates available:${NC}\n"
    for u in "${updates[@]}"; do
      printf "    ${YELLOW}⊘${NC} %s\n" "$u"
    done
    printf "\n  Run ${BOLD}spark update${NC} to update, or enable auto-update:\n"
    printf "    ${DIM}spark config auto-update on${NC}\n\n"
  fi
}

cmd_config() {
  local key="${1:-}" value="${2:-}"

  if [[ -z "$key" ]]; then
    printf "\n  ${BOLD}Configuration:${NC}\n"
    printf "    auto-update: %s\n\n" "$(get_update_config "auto_update" "false")"
    return 0
  fi

  case "$key" in
    auto-update)
      case "$value" in
        on|true)
          save_update_config "$(get_update_config "last_check" "")" "true"
          info "Auto-update enabled"
          ;;
        off|false)
          save_update_config "$(get_update_config "last_check" "")" "false"
          info "Auto-update disabled"
          ;;
        *)
          die "Usage: spark config auto-update on|off"
          ;;
      esac
      ;;
    *)
      die "Unknown config key: $key" "Available: auto-update"
      ;;
  esac
}

# --- Gateway ---
cmd_gateway() {
  local subcmd="${1:-}"
  [[ -z "$subcmd" ]] && {
    printf "\n  ${BOLD}Usage:${NC} spark gateway <start|stop|status|logs>\n\n"
    printf "  ${BOLD}Subcommands:${NC}\n"
    printf "    start     Start LiteLLM gateway container\n"
    printf "    stop      Stop LiteLLM gateway container\n"
    printf "    status    Show gateway status and providers\n"
    printf "    logs      Show gateway logs (-f to follow)\n"
    printf "    add       Enable a provider (openrouter|ollama|zen|together)\n"
    printf "    remove    Disable a provider\n"
    printf "\n"
    return 0
  }
  shift

  case "$subcmd" in
    start)  gateway_start ;;
    stop)   gateway_stop ;;
    status) gateway_status ;;
    logs)   gateway_logs "$@" ;;
    add)    gateway_add "$@" ;;
    remove) gateway_remove "$@" ;;
    *)      die "Unknown gateway command: $subcmd" "Run 'spark gateway' for usage" ;;
  esac
}

gateway_restart() {
  docker stop "$GATEWAY_CONTAINER" >/dev/null 2>&1
  docker rm "$GATEWAY_CONTAINER" >/dev/null 2>&1 || true
  gateway_start
}

# Docker network flags for the gateway. Linux shares the host network (localhost reaches
# local backends); macOS Docker Desktop can't, so publish the port and let the gateway
# reach host backends via host.docker.internal.
gateway_net_args() {
  local port="$1"
  if [[ "$SPARK_OS" == "Darwin" ]]; then
    printf '%s\n' "-p" "127.0.0.1:${port}:${port}"
  else
    printf '%s\n' "--network" "host"
  fi
}

gateway_start() {
  local config
  config=$(gateway_load_config)

  if [[ "$config" == "{}" || "$(echo "$config" | jq -r '.enabled // false')" != "true" ]]; then
    die "Gateway not configured" "Run 'spark setup' to configure LiteLLM gateway"
  fi

  # Check if already running
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${GATEWAY_CONTAINER}$"; then
    warn "Gateway already running"
    printf "    Stop first: ${BOLD}spark gateway stop${NC}\n"
    return 0
  fi

  # Remove stopped container
  docker rm -f "$GATEWAY_CONTAINER" 2>/dev/null || true

  # Generate config
  local litellm_yaml
  litellm_yaml=$(gateway_generate_litellm_yaml)
  if [[ -z "$litellm_yaml" ]]; then
    die "No providers enabled" "Run 'spark setup' to configure providers"
  fi

  local litellm_config_path="${SPARK_CONFIG_DIR}/litellm_config.yaml"
  mkdir -p "$SPARK_CONFIG_DIR"
  chmod 700 "$SPARK_CONFIG_DIR" 2>/dev/null || true
  local old_umask
  old_umask=$(umask)
  umask 077
  printf '%s\n' "$litellm_yaml" > "$litellm_config_path"
  chmod 600 "$litellm_config_path"
  umask "$old_umask"

  # Build env flags
  local env_args=()
  local key
  key=$(gateway_get_api_key "openrouter")
  [[ -n "$key" ]] && env_args+=("-e" "OPENROUTER_API_KEY=${key}")
  key=$(gateway_get_api_key "zen")
  [[ -n "$key" ]] && env_args+=("-e" "ZEN_API_KEY=${key}")
  key=$(gateway_get_api_key "together")
  [[ -n "$key" ]] && env_args+=("-e" "TOGETHER_API_KEY=${key}")

  local port
  port=$(echo "$config" | jq -r '.port // 4000' 2>/dev/null)

  local net_args=()
  while IFS= read -r _na; do net_args+=("$_na"); done < <(gateway_net_args "$port")

  # Assemble one args array (bash 3.2 on macOS errors on "${empty[@]}" under set -u,
  # so only splice env_args in when it is non-empty).
  local run_args=(docker run -d "${net_args[@]}" -v "${litellm_config_path}:/app/config.yaml")
  [[ ${#env_args[@]} -gt 0 ]] && run_args+=("${env_args[@]}")
  run_args+=(--name "$GATEWAY_CONTAINER" --restart unless-stopped "$LITELLM_IMAGE"
    --config /app/config.yaml)
  [[ "$SPARK_OS" == "Linux" ]] && run_args+=(--host 127.0.0.1)
  run_args+=(--port "$port")

  printf "\n"
  "${run_args[@]}" >/dev/null 2>&1 || die "Failed to start gateway container"

  info "LiteLLM gateway started on port ${port}"
  printf "    Test: ${DIM}curl localhost:${port}/v1/models${NC}\n\n"
}

gateway_stop() {
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${GATEWAY_CONTAINER}$"; then
    warn "No running gateway container"
    return 0
  fi

  docker stop "$GATEWAY_CONTAINER" >/dev/null 2>&1
  docker rm "$GATEWAY_CONTAINER" >/dev/null 2>&1 || true
  info "Stopped gateway"
}

gateway_status() {
  printf "\n"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${GATEWAY_CONTAINER}$"; then
    local config
    config=$(gateway_load_config)
    local port
    port=$(echo "$config" | jq -r '.port // 4000' 2>/dev/null)

    printf "  ${GREEN}●${NC} LiteLLM gateway running (${GATEWAY_CONTAINER})\n"
    printf "    Port:     %s\n" "$port"
    printf "    API:      http://localhost:%s/v1\n" "$port"

    printf "    Providers:"
    local providers=()
    [[ "$(echo "$config" | jq -r '.providers.vllm.enabled // false')" == "true" ]] && providers+=("vLLM")
    [[ "$(echo "$config" | jq -r '.providers.openrouter.enabled // false')" == "true" ]] && providers+=("OpenRouter")
    [[ "$(echo "$config" | jq -r '.providers.ollama.enabled // false')" == "true" ]] && providers+=("Ollama")
    [[ "$(echo "$config" | jq -r '.providers.zen.enabled // false')" == "true" ]] && providers+=("Zen")
    [[ "$(echo "$config" | jq -r '.providers.together.enabled // false')" == "true" ]] && providers+=("Together")

    if [[ ${#providers[@]} -gt 0 ]]; then
      printf " %s\n" "$(IFS=', '; echo "${providers[*]}")"
    else
      printf " none\n"
    fi
  else
    printf "  ${DIM}○${NC} Gateway not running. Start with: ${BOLD}spark gateway start${NC}\n"
  fi
  printf "\n"
}

gateway_logs() {
  local follow=0
  [[ "${1:-}" == "-f" ]] && follow=1

  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${GATEWAY_CONTAINER}$"; then
    die "No gateway container found"
  fi

  if [[ "$follow" == "1" ]]; then
    docker logs -f "$GATEWAY_CONTAINER"
  else
    docker logs "$GATEWAY_CONTAINER"
  fi
}

gateway_add() {
  local provider="${1:-}"
  local valid_providers="openrouter ollama zen together"

  if [[ -z "$provider" ]]; then
    printf "\n  ${BOLD}Usage:${NC} spark gateway add <provider>\n\n"
    printf "  ${BOLD}Available providers:${NC}\n"
    printf "    openrouter   Cloud LLM gateway (requires API key)\n"
    printf "    ollama       Local model runner (requires ollama on DGX)\n"
    printf "    zen          OpenCode Zen cloud gateway (requires API key)\n"
    printf "    together     Together AI cloud inference (requires API key)\n"
    printf "\n"
    return 0
  fi

  # shellcheck disable=SC2076
  [[ " $valid_providers " =~ " $provider " ]] || die "Unknown provider: $provider" "Available: ${valid_providers// /, }"

  local config
  config=$(gateway_load_config)
  if [[ "$config" == "{}" ]]; then
    die "Gateway not configured" "Run 'spark setup' first to install the gateway"
  fi

  local already_enabled
  already_enabled=$(echo "$config" | jq -r --arg p "$provider" '.providers[$p].enabled // false' 2>/dev/null)
  if [[ "$already_enabled" == "true" ]]; then
    warn "${provider} is already enabled"
    return 0
  fi

  local api_key=""
  if [[ "$provider" == "openrouter" || "$provider" == "zen" || "$provider" == "together" ]]; then
    printf "  Enter %s API key: " "$provider"
    read -rs api_key; printf "\n"
    [[ -z "$api_key" ]] && die "API key is required for ${provider}"
  fi

  if [[ -n "$api_key" ]]; then
    config=$(echo "$config" | jq --arg p "$provider" --arg k "$api_key" \
      '.providers[$p].enabled = true | .providers[$p].api_key = $k')
  else
    config=$(echo "$config" | jq --arg p "$provider" '.providers[$p].enabled = true')
  fi

  gateway_save_config "$config"
  info "Enabled ${provider}"

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${GATEWAY_CONTAINER}$"; then
    printf "  Restart gateway to apply: ${BOLD}spark gateway stop && spark gateway start${NC}\n"
  fi
}

gateway_remove() {
  local provider="${1:-}"
  local valid_providers="openrouter ollama zen together"

  if [[ -z "$provider" ]]; then
    printf "\n  ${BOLD}Usage:${NC} spark gateway remove <provider>\n\n"
    return 0
  fi

  # shellcheck disable=SC2076
  [[ " $valid_providers " =~ " $provider " ]] || die "Unknown provider: $provider" "Available: ${valid_providers// /, }"
  [[ "$provider" == "vllm" ]] && die "Cannot remove vLLM — it is the core local provider"

  local config
  config=$(gateway_load_config)
  if [[ "$config" == "{}" ]]; then
    die "Gateway not configured"
  fi

  config=$(echo "$config" | jq --arg p "$provider" \
    '.providers[$p].enabled = false | .providers[$p].api_key = ""')

  gateway_save_config "$config"
  info "Disabled ${provider}"

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${GATEWAY_CONTAINER}$"; then
    printf "  Restart gateway to apply: ${BOLD}spark gateway stop && spark gateway start${NC}\n"
  fi
}

