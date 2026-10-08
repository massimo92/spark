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

save_hermes_context_config() {
  local mode="$1" length="${2:-}" tmp
  command -v jq >/dev/null 2>&1 || die "jq is required to save Hermes settings"
  mkdir -p "$SPARK_CONFIG_DIR"
  chmod 700 "$SPARK_CONFIG_DIR" 2>/dev/null || true
  tmp="${HERMES_SETTINGS_FILE}.tmp"
  if [[ -n "$length" ]]; then
    jq -n --arg mode "$mode" --argjson length "$length" \
      '{mode: $mode, length: $length}' > "$tmp"
  else
    jq -n --arg mode "$mode" '{mode: $mode}' > "$tmp"
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$HERMES_SETTINGS_FILE"
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
  local tmp
  mkdir -p "$SPARK_CONFIG_DIR" && chmod 700 "$SPARK_CONFIG_DIR" || return 1
  printf '%s\n' "$1" | jq -e 'type == "object"' >/dev/null || return 1
  tmp=$(umask 077; mktemp "${GATEWAY_CONFIG}.tmp.XXXXXX") || return 1
  printf '%s\n' "$1" > "$tmp"
  chmod 600 "$tmp" && mv "$tmp" "$GATEWAY_CONFIG"
}

gateway_set_main_model() { gateway_with_lock gateway_set_main_model_locked "$@"; }
gateway_set_main_model_locked() {
  local provider="$1" model="$2" config updated
  config=$(gateway_load_config)
  updated=$(printf '%s\n' "$config" | jq --arg provider "$provider" --arg model "$model" \
    '.main = {provider: $provider, model: $model}') || return 1
  [[ "$updated" == "$config" ]] || gateway_save_config "$updated"
}

gateway_rendered_config_ready() {
  local path="${SPARK_CONFIG_DIR}/litellm_config.yaml" expected current
  [[ -f "$path" ]] || return 1
  expected=$(gateway_generate_litellm_yaml) || return 1
  current=$(cat "$path" 2>/dev/null || true)
  [[ -n "$expected" && "$current" == "$expected" ]]
}

gateway_provider_enabled() {
  local provider="$1"
  local config
  config=$(gateway_load_config)
  echo "$config" | jq -r --arg p "$provider" '.providers[$p].enabled // false' 2>/dev/null
}

gateway_generate_litellm_yaml() {
  local config
  config=$(gateway_load_config)
  local vllm_port main_provider main_model main_added=0
  vllm_port=$(echo "$config" | jq -r '.providers.vllm.port // 8000' 2>/dev/null)
  main_provider=$(echo "$config" | jq -r '.main.provider // ""' 2>/dev/null)
  main_model=$(echo "$config" | jq -r '.main.model // ""' 2>/dev/null)

  local yaml="model_list:"
  local has_models=0

  # vLLM — one explicit entry per running model (routes to its own port),
  # no wildcard that could resurrect a stopped local model.
  if [[ "$(echo "$config" | jq -r '.providers.vllm.enabled // false')" == "true" ]]; then
    local primary_port="" primary_model="" main_match=0 name model port rest
    while IFS=$'\t' read -r name model port rest; do
      [[ -z "$model" ]] && continue
      yaml+="
  - model_name: \"vllm/${model}\"
    litellm_params:
      model: \"openai/${model}\"
      api_base: \"http://localhost:${port}/v1\"
      api_key: \"dummy\""
      has_models=1
      if [[ -z "$primary_port" ]]; then
        primary_port="$port"
        primary_model="$model"
      fi
      if [[ "$port" == "$vllm_port" && "$main_match" == "0" ]]; then
        primary_port="$port"
        primary_model="$model"
      fi
      if [[ "$main_provider" == "vllm" && "$model" == "$main_model" ]]; then
        primary_port="$port"
        primary_model="$model"
        main_match=1
      fi
    done < <(list_managed_containers)
    [[ -z "$primary_port" ]] && primary_port="$vllm_port"

    if [[ -n "$primary_model" && ( "$main_provider" == vllm && "$main_match" == 1 ) ]]; then
      yaml+="
  - model_name: \"main\"
    litellm_params:
      model: \"openai/${primary_model}\"
      api_base: \"http://localhost:${primary_port}/v1\"
      api_key: \"dummy\""
      main_added=1
    fi


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
    local ollama_model
    while IFS= read -r ollama_model; do
      [[ -n "$ollama_model" ]] || continue
      yaml+="
  - $(jq -nc --arg name "ollama_chat/$ollama_model" --arg base "http://${ollama_host}:11434" '{model_name:$name,litellm_params:{model:$name,api_base:$base}}')"
      has_models=1
      if [[ "$main_added" == 0 && "$main_provider" == ollama && "$main_model" == "$ollama_model" ]]; then
        yaml+="
  - $(jq -nc --arg model "ollama_chat/$ollama_model" --arg base "http://${ollama_host}:11434" '{model_name:"main",litellm_params:{model:$model,api_base:$base}}')"
        main_added=1
      fi
    done < <(printf '%s\n' "$config" | jq -r '.providers.ollama.models[]?')

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

  local provider cloud_model mode params
  for provider in openai anthropic xai chatgpt github_copilot; do
    [[ "$(printf '%s\n' "$config" | jq -r --arg p "$provider" '.providers[$p].enabled // false')" == true ]] || continue
    mode=$(printf '%s\n' "$config" | jq -r --arg p "$provider" '.providers[$p].auth // "api"')
    while IFS= read -r cloud_model; do
      [[ -n "$cloud_model" ]] || continue
      # JSON quoted scalars are valid YAML and prevent model names injecting settings.
      params=$(jq -nc --arg name "$provider/$cloud_model" --arg mode "$mode" --arg p "$provider" \
        '{model_name:$name,litellm_params:{model:$name}} |
        if $mode == "oauth" and $p == "xai" then .litellm_params.use_xai_oauth=true
        elif $mode == "api" then .litellm_params.api_key=("os.environ/" + ($p|ascii_upcase) + "_API_KEY")
        else . end |
        if $p == "chatgpt" then .model_info.mode="responses" else . end') || return 1
      yaml+="
  - ${params}"
      has_models=1
    done < <(printf '%s\n' "$config" | jq -r --arg p "$provider" '.providers[$p].models[]?')
  done

  [[ "$has_models" -gt 0 ]] || yaml='model_list: []'
  local port
  port=$(echo "$config" | jq -r '.port // 4000' 2>/dev/null)
  yaml+="

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY

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
    next_tag="${year}.${month}-py3"
    if ngc_vllm_tag_newer_than "$next_tag" "$current_tag"; then
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
    printf "    ${DIM}spark config --auto-update on${NC}\n\n"
  fi
}

cmd_config_hermes_context_tui() {
  local choice length
  is_interactive || die "Hermes settings require a terminal" "Use: spark config --hermes-ctx max|custom|<tokens>"
  printf "\n  Hermes context mode:\n"
  printf "    [1] max    vLLM effective context\n"
  printf "    [2] custom min(65536, vLLM) or an explicit value\n\n"
  printf "  Select [1/2]: "
  read -r choice || true
  case "$choice" in
    1)
      save_hermes_context_config max
      info "Hermes context: max (vLLM effective context)"
      ;;
    2)
      printf "  Custom tokens (blank = min(65536, vLLM)): "
      read -r length || true
      if [[ -n "$length" ]]; then
        [[ "$length" =~ ^[1-9][0-9]*$ ]] || die "Hermes custom context must be a positive integer"
        save_hermes_context_config custom "$length"
        info "Hermes context: custom (${length})"
      else
        save_hermes_context_config custom
        info "Hermes context: custom (min(65536, vLLM))"
      fi
      ;;
    *) die "Choose 1 or 2" ;;
  esac
}

cmd_config_tui() {
  local choice value
  is_interactive || die "Spark settings require a terminal" "Use spark config --help for non-interactive options"
  printf "\n  Spark configuration:\n"
  printf "    [1] auto-update (%s)\n" "$(get_update_config "auto_update" "false")"
  printf "    [2] Hermes context\n\n"
  printf "  Select [1/2]: "
  read -r choice || true
  case "$choice" in
    1)
      printf "  Auto-update [on/off]: "
      read -r value || true
      case "$value" in
        on|true) save_update_config "$(get_update_config "last_check" "")" true; info "Auto-update enabled" ;;
        off|false) save_update_config "$(get_update_config "last_check" "")" false; info "Auto-update disabled" ;;
        *) die "Choose on or off" ;;
      esac
      ;;
    2) cmd_config_hermes_context_tui ;;
    *) die "Choose 1 or 2" ;;
  esac
}

cmd_config_set_hermes_context() {
  local value="$1"
  case "$value" in
    max)
      save_hermes_context_config max
      info "Hermes context: max (vLLM effective context)"
      ;;
    custom)
      save_hermes_context_config custom
      info "Hermes context: custom (min(65536, vLLM))"
      ;;
    ''|*[!0-9]*) die "Usage: spark config --hermes-ctx max|custom|<tokens>" ;;
    0) die "Hermes custom context must be a positive integer" ;;
    *)
      save_hermes_context_config custom "$value"
      info "Hermes context: custom (${value})"
      ;;
  esac
}

cmd_config() {
  local key="${1:-}" value="${2:-}" extra="${3:-}"

  case "$key" in
    help|-h|--help)
      cat <<EOF

  ${BOLD}Usage:${NC} spark config [--show | --auto-update on|off | --hermes-ctx max|custom|<tokens>]

  With no arguments, open the interactive configuration menu.

  ${BOLD}Settings:${NC}
    --show               Show the current configuration.
    --auto-update on|off Enable or disable automatic Spark updates.
    --hermes-ctx max     Use the context actually configured in vLLM.
    --hermes-ctx custom  Use min(65536, vLLM context).
    --hermes-ctx <tokens> Use an explicit Hermes context.

EOF
      return 0
      ;;
  esac

  if [[ -z "$key" ]]; then
    cmd_config_tui
    return
  fi

  if [[ "$key" == "--show" ]]; then
    [[ -z "$value" ]] || die "Usage: spark config --show"
    printf "\n  ${BOLD}Configuration:${NC}\n"
    printf "    auto-update: %s\n\n" "$(get_update_config "auto_update" "false")"
    if [[ -f "$HERMES_SETTINGS_FILE" ]] && command -v jq >/dev/null 2>&1; then
      local hermes_mode hermes_length
      hermes_mode=$(jq -r '.mode // "custom"' "$HERMES_SETTINGS_FILE" 2>/dev/null || echo custom)
      if [[ "$hermes_mode" == "max" ]]; then
        printf "    hermes-context: max (vLLM effective context)\n\n"
      else
        hermes_length=$(jq -r 'if .length == null then "min(65536, vLLM)" else (.length|tostring) end' "$HERMES_SETTINGS_FILE" 2>/dev/null || echo 'min(65536, vLLM)')
        printf "    hermes-context: custom (%s)\n\n" "$hermes_length"
      fi
    else
      printf "    hermes-context: custom (min(65536, vLLM))\n\n"
    fi
    return 0
  fi

  case "$key" in
    --auto-update)
      [[ -z "$extra" ]] || die "Usage: spark config --auto-update on|off"
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
          die "Usage: spark config --auto-update on|off"
          ;;
      esac
      ;;
    --hermes-ctx)
      [[ -z "$extra" ]] || die "Usage: spark config --hermes-ctx max|custom|<tokens>"
      cmd_config_set_hermes_context "$value"
      ;;
    *)
      die "Unknown config option: $key" "Available: --auto-update, --hermes-ctx, --show"
      ;;
  esac
}

# --- Gateway ---
gateway_net_args() {
  local port="$1"
  if [[ "$SPARK_OS" == "Darwin" ]]; then
    printf '%s\n' "-p" "127.0.0.1:${port}:${port}"
  else
    printf '%s\n' "--network" "host"
  fi
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
