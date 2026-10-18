# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
# Credentials stay outside generated JSON/YAML and never enter status output.
gateway_secrets_path() { printf '%s/gateway.env\n' "$SPARK_CONFIG_DIR"; }
gateway_env_get() {
  local key="$1" file="${2:-$(gateway_secrets_path)}"
  [[ -f "$file" ]] || return 1
  awk -v key="$key" 'index($0,key "=")==1 {print substr($0,length(key)+2); exit}' "$file"
}
gateway_env_set() {
  local key="$1" value="$2" file="${3:-$(gateway_secrets_path)}" tmp
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  mkdir -p "$SPARK_CONFIG_DIR" && chmod 700 "$SPARK_CONFIG_DIR" || return 1
  tmp=$(umask 077; mktemp "${file}.tmp.XXXXXX") || return 1
  if [[ -f "$file" ]]; then awk -v key="$key" 'index($0,key "=")!=1' "$file" > "$tmp"; fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp" && mv "$tmp" "$file"
}
gateway_auth_terminal() { [[ -t 2 ]]; }
gateway_auth_present_new() {
  # Only receive freshly generated keys. Never reveal an existing stored key.
  if gateway_auth_terminal; then
    printf '\nNew LiteLLM token (shown once):\n%s\nSave it now in your password manager. Lost token? Run spark gateway auth reset.\n\n' "$1" >&2
  else
    printf 'New LiteLLM client key created; only its hash is saved, no token displayed without an interactive terminal. Run spark gateway auth reset in a terminal (ssh -t for a remote command) to generate a replacement.\n' >&2
  fi
}
gateway_auth_ensure() {
  local key p env_key config migrated=0 ollama_models
  # Provider secrets remain private; inference credentials live only as DB hashes.
  mkdir -p "$SPARK_CONFIG_DIR" && chmod 700 "$SPARK_CONFIG_DIR" || return 1
  if [[ ! -f "$(gateway_secrets_path)" ]]; then (umask 077; touch "$(gateway_secrets_path)") || return 1; fi
  config=$(gateway_load_config) || return 1
  [[ ! -L "$SPARK_CONFIG_DIR/gateway-migration" ]] || { err 'Recovery folder must not be a symlink'; return 1; }
  # Keep credentials recoverable until the new gateway or a rollback is verified.
  if [[ ! -d "$SPARK_CONFIG_DIR/gateway-migration" ]] && { [[ -f "$GATEWAY_CONFIG" ]] && grep -q '"api_key"' "$GATEWAY_CONFIG"; }; then
    (umask 077
      mkdir "$SPARK_CONFIG_DIR/gateway-migration" &&
      cp "$GATEWAY_CONFIG" "$SPARK_CONFIG_DIR/gateway-migration/gateway.json" &&
      cp "$(gateway_secrets_path)" "$SPARK_CONFIG_DIR/gateway-migration/gateway.env" &&
      { [[ ! -f "$SPARK_CONFIG_DIR/litellm_config.yaml" ]] || cp "$SPARK_CONFIG_DIR/litellm_config.yaml" "$SPARK_CONFIG_DIR/gateway-migration/litellm_config.yaml"; }
    ) || return 1
  fi
  # Migrate old provider keys without displaying or passing them to Docker argv.
  for p in openrouter zen together openai xai anthropic; do
    env_key=$(gateway_provider_env "$p")
    key=$(printf '%s\n' "$config" | jq -r --arg p "$p" '.providers[$p].api_key // ""')
    if [[ -n "$key" ]]; then gateway_env_set "$env_key" "$key" || return 1; migrated=1; fi
  done
  if [[ "$migrated" == 1 ]]; then
    config=$(printf '%s\n' "$config" | jq 'del(.providers[].api_key)') || return 1
    gateway_save_config "$config" || return 1
  fi
  # Adopt a legacy wildcard installation once; explicit stop registries stay empty.
  if [[ "$(printf '%s\n' "$config" | jq -r '.providers.ollama.enabled // false')" == true ]] && ! printf '%s\n' "$config" | jq -e '.providers.ollama | has("models")' >/dev/null; then
    ollama_models=$({ ollama ps 2>/dev/null | awk 'NR>1{print $1}' || true;
      printf '%s\n' "$config" | jq -r 'select(.main.provider=="ollama") | .main.model // empty';
    } | jq -Rn '[inputs | select(length>0)] | unique') || return 1
    config=$(printf '%s\n' "$config" | jq --argjson models "$ollama_models" '.providers.ollama.models=$models') || return 1
    gateway_save_config "$config" || return 1
  fi
  chmod 600 "$(gateway_secrets_path)"
}
gateway_with_lock() (
  local lock="${SPARK_CONFIG_DIR}/gateway.lock" attempt cleanup_command
  mkdir -p "$SPARK_CONFIG_DIR" && chmod 700 "$SPARK_CONFIG_DIR" || exit 1
  for ((attempt=0; attempt<30; attempt++)); do
    if mkdir "$lock" 2>/dev/null; then break; fi
    local owner
    owner=$(cat "$lock/pid" 2>/dev/null || true)
    if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
      rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null || true
    fi
    sleep 1
  done
  [[ "$attempt" -lt 30 ]] || { err 'Gateway busy; retry when the other command finishes'; exit 1; }
  printf '%s\n' "${BASHPID:-$$}" > "$lock/pid"
  # Capture the escaped path now: local variables can unwind before EXIT fires.
  # shellcheck disable=SC2064
  printf -v cleanup_command 'rm -f -- %q/pid; rmdir -- %q 2>/dev/null || true' "$lock" "$lock"
  # shellcheck disable=SC2064
  trap "$cleanup_command" EXIT
  "$@"
)
gateway_provider_env() {
  case "$1" in
    openrouter) printf OPENROUTER_API_KEY ;; zen) printf ZEN_API_KEY ;;
    together) printf TOGETHER_API_KEY ;; openai) printf OPENAI_API_KEY ;;
    xai) printf XAI_API_KEY ;; anthropic) printf ANTHROPIC_API_KEY ;;
    *) return 1 ;;
  esac
}
gateway_provider_valid() {
  case "$1" in vllm|ollama|openrouter|zen|together|openai|chatgpt|github_copilot|xai|anthropic) return 0 ;; *) return 1 ;; esac
}
gateway_curl() {
  local key
  key=$(gateway_auth_key) || return 1
  [[ "$key" =~ ^sk-[a-f0-9]{64}$ ]] || return 1
  # Read authorization via stdin config, so the token is absent from process argv.
  printf 'header = "Authorization: Bearer %s"\n' "$key" | curl --config - "$@"
}
gateway_wait_ready() {
  local attempt tries="${SPARK_GATEWAY_READY_ATTEMPTS:-30}"
  [[ "$tries" =~ ^[1-9][0-9]*$ ]] || return 1
  for ((attempt=0; attempt<tries; attempt++)); do
    if gateway_api_ready; then
      # A working token is insufficient: anonymous model enumeration must fail.
      local status
      status=$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$(gateway_configured_port)/v1/models") || status=000
      case "$status" in
        401|403) ;; 2??|3??) err 'Gateway accepts anonymous requests'; return 1 ;;
        *) sleep 1; continue ;; # Database/proxy may still be restarting.
      esac
      status=$(printf 'header = "Authorization: Bearer sk-invalid"\n' | curl --config - -sS --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$(gateway_configured_port)/v1/models") || status=000
      case "$status" in
        401|403) ;; 2??|3??) err 'Gateway accepts invalid tokens'; return 1 ;;
        *) sleep 1; continue ;;
      esac
      return 0
    fi
    sleep 1
  done
  err 'LiteLLM did not become ready with authentication'; return 1
}
gateway_prepare_runtime() { gateway_with_lock gateway_prepare_runtime_locked "$@"; }
gateway_prepare_runtime_locked() {
  local provider="$1" config
  config=$(gateway_load_config)
  [[ "$config" != '{}' ]] || config=$(jq -n --argjson port "$GATEWAY_PORT" '{enabled:true,port:$port,providers:{},protected:true}')
  config=$(printf '%s\n' "$config" | jq --arg p "$provider" '.enabled=true | .protected=(if has("protected") then .protected else true end) | .providers[$p].enabled=true') || return 1
  gateway_save_config "$config" && gateway_auth_ensure && gateway_preflight
}
gateway_publish_model() {
  local provider="$1" model="$2" supervised="${3:-1}"
  gateway_sync || { err "Backend active; gateway publication failed for ${model}"; return 1; }
  if [[ "$supervised" == 1 ]]; then
    gateway_model_routed "$provider" "$model" && gateway_route_smoke "$provider" "$model" || { err "Backend active; LiteLLM route missing for ${model}"; return 1; }
  fi
  printf '  Gateway: http://localhost:%s/v1\n  Model: %s/%s\n' "$(gateway_configured_port)" "$([[ "$provider" == ollama ]] && printf ollama_chat || printf vllm)" "$model"
  [[ "$supervised" == 1 ]] || printf '  State: pending backend readiness (spark status --json)\n'
  printf '  Authentication: Bearer token saved at creation; if lost, spark gateway auth reset\n'
}
gateway_protected() { gateway_load_config | jq -e '.protected != false' >/dev/null; }

gateway_oauth_dir() { printf '%s/oauth/%s\n' "$SPARK_CONFIG_DIR" "$1"; }
gateway_oauth_env() {
  case "$1" in chatgpt) printf CHATGPT_TOKEN_DIR ;; github_copilot) printf GITHUB_COPILOT_TOKEN_DIR ;; xai) printf XAI_OAUTH_TOKEN_DIR ;; *) return 1 ;; esac
}
gateway_oauth_file() {
  case "$1" in github_copilot) printf access-token ;; chatgpt|xai) printf auth.json ;; *) return 1 ;; esac
}
gateway_oauth_status() {
  local p="$1" dir file
  dir=$(gateway_oauth_dir "$p"); file=$(gateway_oauth_file "$p") || return 1
  if [[ -s "$dir/$file" ]]; then printf credentials-present; else printf login-required; fi
}
gateway_capabilities() {
  local p="${1:-base}" image="${2:-$LITELLM_IMAGE}" script
  case "$p" in
    keys) script='import prisma, litellm_proxy_extras; from litellm.proxy._types import GenerateKeyRequest; assert "allowed_routes" in GenerateKeyRequest.model_fields; assert "key" in GenerateKeyRequest.model_fields' ;;
    base) script='import importlib.metadata; print(importlib.metadata.version("litellm"))' ;;
    chatgpt) script='from litellm.llms.chatgpt.authenticator import Authenticator; assert callable(Authenticator().get_access_token)' ;;
    github_copilot) script='from litellm.llms.github_copilot.authenticator import Authenticator; assert callable(Authenticator().get_access_token)' ;;
    xai) script='import inspect; from litellm.llms.xai.oauth import XAIOAuthAuthenticator; from litellm.llms.xai.chat import transformation; assert callable(XAIOAuthAuthenticator().login); assert callable(XAIOAuthAuthenticator._start_callback_server); assert "use_xai_oauth" in inspect.getsource(transformation)' ;;
    *) return 1 ;;
  esac
  docker run --rm --entrypoint python "$image" -c "$script" 2>/dev/null
}
gateway_login_local() {
  local p="${1:-}" dir env_key script net_args=()
  if [[ "$p" == xai && -n "${SSH_CONNECTION:-}" ]]; then
    err 'Run xAI OAuth on the computer with your browser: spark gateway login xai --remote USER@SERVER (no tunnel)'; return 1
  fi
  env_key=$(gateway_oauth_env "$p") || { err 'Login providers: chatgpt, github_copilot, xai'; return 1; }
  gateway_capabilities "$p" >/dev/null || { err "Installed LiteLLM lacks ${p} login; run spark update --litellm"; return 1; }
  dir=$(gateway_oauth_dir "$p")
  mkdir -p "$dir" && chmod 700 "$SPARK_CONFIG_DIR" "${SPARK_CONFIG_DIR}/oauth" "$dir" || return 1
  if [[ "$p" == xai ]]; then
    if [[ "$SPARK_OS" == Linux ]]; then net_args=(--network host); else net_args=(-p 127.0.0.1:56121:56121); fi
  fi
  case "$p" in
    chatgpt) script='from litellm.llms.chatgpt.authenticator import Authenticator; Authenticator().get_access_token()' ;;
    github_copilot) script='from litellm.llms.github_copilot.authenticator import Authenticator; Authenticator().get_access_token()' ;;
    xai) script='from urllib.parse import urlparse
from litellm.llms.xai.oauth import XAIOAuthAuthenticator
original = XAIOAuthAuthenticator._start_callback_server
def fixed_callback(self, state):
    server, uri = original(self, state)
    if urlparse(uri).hostname != "127.0.0.1" or urlparse(uri).port != 56121:
        server.server_close()
        raise RuntimeError("xAI callback must use 127.0.0.1:56121; free the port and retry")
    return server, uri
XAIOAuthAuthenticator._start_callback_server = fixed_callback
XAIOAuthAuthenticator().login(no_browser=True)'
      printf 'OAuth opens a callback on this computer only (127.0.0.1:56121). Complete the login in your local browser.\n' ;;
  esac
  docker run --rm -i --user "$(id -u):$(id -g)" -e HOME=/tmp ${net_args[@]+"${net_args[@]}"} -v "${dir}:/tokens" -e "${env_key}=/tokens" --entrypoint python "$LITELLM_IMAGE" -c "$script" || return 1
  [[ "$(gateway_oauth_status "$p")" == credentials-present ]] || { err 'Login produced no credentials'; return 1; }
  chmod 600 "$dir"/*
  info "${p} credentials saved; enable models with spark gateway add ${p}"
}
gateway_logout() {
  local p="${1:-}" dir file config
  file=$(gateway_oauth_file "$p") || return 1
  config=$(gateway_load_config)
  # Disable before removing credentials; restore the previous route if sync fails.
  gateway_save_config "$(printf '%s\n' "$config" | jq --arg p "$p" '.providers[$p].enabled=false')" || return 1
  if gateway_running_state && ! gateway_sync_locked; then gateway_save_config "$config"; return 1; fi
  dir=$(gateway_oauth_dir "$p")
  rm -f "$dir/$file" "$dir/api-key.json"
  info "${p} logged out"
}

gateway_sync() { gateway_with_lock gateway_sync_locked; }
gateway_sync_locked() {
  local path="${SPARK_CONFIG_DIR}/litellm_config.yaml" previous="" yaml tmp running=0 previous_image=""
  if [[ "${SPARK_GATEWAY_DEFER_CLIENT:-0}" != 1 ]] && gateway_load_config | jq -e '.auth.recovery_required==true' >/dev/null; then
    err 'Recover the interrupted token change first: spark gateway auth reset'; return 1
  fi
  gateway_auth_ensure && gateway_preflight || return 1
  [[ -f "$path" ]] && previous=$(cat "$path")
  yaml=$(gateway_generate_litellm_yaml) || return 1
  previous_image=$(docker inspect "$GATEWAY_CONTAINER" --format '{{.Image}}' 2>/dev/null || true)
  if gateway_running_state; then
    running=1
    if [[ "$previous" == "$yaml" ]] && gateway_api_ready; then gateway_wait_ready && gateway_sync_clients && gateway_virtual_ensure && gateway_migration_cleanup; return $?; fi
  fi
  tmp=$(umask 077; mktemp "${path}.tmp.XXXXXX") || return 1
  printf '%s\n' "$yaml" > "$tmp"
  chmod 600 "$tmp" && mv "$tmp" "$path" || return 1
  if [[ "$running" == 1 ]]; then
    docker stop "$GATEWAY_CONTAINER" >/dev/null 2>&1 || return 1
  fi
  if gateway_start_container && gateway_wait_ready && gateway_sync_clients && gateway_virtual_ensure; then gateway_migration_cleanup; return $?; fi
  err 'Gateway update failed; restoring the previous rendered routes'
  docker stop "$GATEWAY_CONTAINER" >/dev/null 2>&1 || true
  # Never restore anonymous access during the first migration.
  if [[ -n "$previous" ]] && ! printf '%s\n' "$previous" | grep -Eq '^[[:space:]]*master_key: ("?os.environ/LITELLM_MASTER_KEY"?)$'; then
    err 'Legacy anonymous gateway left stopped; fix the failure and run spark gateway start'
    return 1
  fi
  if [[ -n "$previous" ]]; then
    tmp=$(umask 077; mktemp "${path}.tmp.XXXXXX") || return 1
    printf '%s\n' "$previous" > "$tmp"
    chmod 600 "$tmp" && mv "$tmp" "$path" || return 1
    docker stop "$GATEWAY_CONTAINER" >/dev/null 2>&1 || true
    if gateway_migration_restore_config && GATEWAY_RESTORE_IMAGE="$previous_image" gateway_start_container && gateway_wait_ready && gateway_sync_clients && gateway_virtual_ensure; then
      gateway_migration_cleanup || return 1
    else
      err 'Previous gateway routes could not be verified; private recovery backup retained'
    fi
  fi
  return 1
}
gateway_restart() { gateway_sync; }
gateway_start() {
  gateway_configured || { err 'Gateway not configured; run spark setup'; return 1; }
  gateway_sync
}
gateway_start_container() {
  local port net_args=() run_args=() p dir env_key mode config runtime_script env_file rc=0
  config=$(gateway_load_config)
  port=$(gateway_configured_port)
  [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 && "$port" -le 65535 ]] || return 1
  while IFS= read -r p; do net_args+=("$p"); done < <(gateway_net_args "$port")
  gateway_database_prepare && gateway_database_migrate || return 1
  run_args=()
  for p in chatgpt github_copilot xai; do
    mode=$(printf '%s\n' "$config" | jq -r --arg p "$p" '.providers[$p].auth // "api"')
    if gateway_provider_enabled "$p" | grep -qx true && { [[ "$p" != xai ]] || [[ "$mode" == oauth ]]; }; then
      gateway_capabilities "$p" >/dev/null || { err "LiteLLM image lacks ${p} authentication"; return 1; }
      [[ "$(gateway_oauth_status "$p")" == credentials-present ]] || { err "Run spark gateway login ${p} first"; return 1; }
      dir=$(gateway_oauth_dir "$p"); env_key=$(gateway_oauth_env "$p")
      run_args+=(-v "${dir}:/tokens/${p}" -e "${env_key}=/tokens/${p}")
      [[ "$p" != xai ]] || run_args+=(-e XAI_API_KEY=)
    fi
  done
  # Strip the legacy administrative key before passing provider env to Docker.
  env_file=$(umask 077; mktemp "$SPARK_CONFIG_DIR/gateway-runtime.env.XXXXXX") || return 1
  awk 'index($0,"LITELLM_MASTER_KEY=")!=1 && index($0,"DATABASE_URL=")!=1' "$(gateway_secrets_path)" > "$env_file"
  runtime_script='import os, secrets, sys
os.umask(0o077)
key = "sk-" + secrets.token_hex(32)
with open("/run/spark/master-key", "w") as f:
    f.write(key)
os.environ["LITELLM_MASTER_KEY"] = key
os.environ.pop("LITELLM_SALT_KEY", None)
os.execvp("litellm", ["litellm"] + sys.argv[1:])'
  run_args=(docker run -d "${net_args[@]}" --user "$(id -u):$(id -g)" -e HOME=/tmp --env-file "$env_file"
    --ulimit core=0:0 --tmpfs "/run/spark:rw,noexec,nosuid,size=1m,mode=0700,uid=$(id -u),gid=$(id -g)"
    -e 'DATABASE_URL=postgresql://spark@localhost/litellm?host=/var/run/postgresql'
    -e DISABLE_SCHEMA_UPDATE=true
    -v "$(gateway_database_name)-socket:/var/run/postgresql"
    -v "${SPARK_CONFIG_DIR}/litellm_config.yaml:/app/config.yaml:ro" "${run_args[@]}")
  docker rm "$GATEWAY_CONTAINER" >/dev/null 2>&1 || true
  run_args+=(--name "$GATEWAY_CONTAINER" --label io.spark.auth-mode=virtual-keys --restart unless-stopped --entrypoint python "${GATEWAY_RESTORE_IMAGE:-$LITELLM_IMAGE}" -c "$runtime_script" --config /app/config.yaml)
  [[ "$SPARK_OS" != Linux ]] || run_args+=(--host 127.0.0.1)
  run_args+=(--port "$port")
  "${run_args[@]}" >/dev/null 2>&1 || rc=$?
  rm -f "$env_file"
  [[ "$rc" == 0 ]] || { err 'LiteLLM container failed to start; inspect spark gateway logs'; return 1; }
}
gateway_sync_clients() {
  local key
  [[ -f "${WORKSPACE_ENV_FILE:-/nonexistent}" ]] || return 0
  gateway_managed_client_endpoint "${NEMOCLAW_ENDPOINT_URL:-$(workspace_read_env HERMES_LITELLM_BASE_URL 2>/dev/null || true)}" || return 0
  key=$(gateway_managed_client_key) || return 1
  # Rebuild only a running managed sandbox whose token is stale. Rebuild reads
  # the private workspace env; arbitrary external endpoints are not changed.
  if command -v nemohermes >/dev/null 2>&1 && workspace_hermes_running; then
    local digest marker="${SPARK_CONFIG_DIR}/hermes-gateway-token.sha256"
    digest=$(printf '%s' "$key" | shasum -a 256 | awk '{print $1}')
    if [[ ! -f "$marker" || "$(cat "$marker")" != "$digest" ]]; then
      nemohermes_rebuild_with_workspace_env >/dev/null 2>&1 || { err 'Could not update Hermes gateway authentication'; return 1; }
      printf '%s\n' "$digest" > "$marker"; chmod 600 "$marker"
    fi
  fi
}
gateway_auth_command() {
  case "${1:-status}" in
    status) gateway_auth_ready && printf 'authentication: configured\n' || { printf 'authentication: migration-required\n'; return 1; } ;;
    rotate) [[ $# == 1 ]] || return 1; gateway_auth_rotate ;;
    reset) [[ $# == 1 ]] || return 1; gateway_with_lock gateway_auth_reset_locked ;;
    *) err 'Usage: spark gateway auth <status|rotate|reset>'; return 1 ;;
  esac
}
gateway_add() { gateway_with_lock gateway_add_locked "$@"; }
gateway_add_locked() {
  local p="${1:-}" mode=api models_json='' key='' env_key config old model
  [[ -n "$p" ]] || { printf 'Providers: ollama, openrouter, zen, together, openai, chatgpt, github_copilot, xai, anthropic\n'; return 0; }
  gateway_provider_valid "$p" && [[ "$p" != vllm ]] || { err "Unknown provider: ${p}"; return 1; }
  shift
  case "$p" in chatgpt|github_copilot) mode=oauth ;; esac
  local names=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auth) [[ $# -ge 2 ]] || return 1; mode="$2"; shift 2 ;;
      --model) [[ $# -ge 2 && -n "$2" ]] || return 1; names+=("$2"); shift 2 ;;
      *) err "Unknown provider option: $1"; return 1 ;;
    esac
  done
  case "$mode" in api) [[ "$p" != chatgpt && "$p" != github_copilot ]] || return 1 ;; oauth) gateway_oauth_env "$p" >/dev/null || return 1 ;; *) return 1 ;; esac
  gateway_prepare_runtime_locked "$BACKEND" || return 1
  config=$(gateway_load_config); old="$config"
  if [[ "$mode" == oauth ]]; then
    gateway_capabilities "$p" >/dev/null || { err "Image lacks ${p} OAuth support"; return 1; }
    [[ "$(gateway_oauth_status "$p")" == credentials-present ]] || { err "Run spark gateway login ${p} first"; return 1; }
  elif env_key=$(gateway_provider_env "$p"); then
    key=$(gateway_env_get "$env_key" 2>/dev/null || true)
    if [[ -z "$key" && -n "${!env_key:-}" ]]; then
      key="${!env_key}"; gateway_env_set "$env_key" "$key" || return 1
    fi
    if [[ -z "$key" ]]; then
      printf '  %s API key: ' "$p" >&2; IFS= read -rs key || return 1; printf '\n' >&2
      [[ -n "$key" ]] && gateway_env_set "$env_key" "$key" || return 1
    fi
  fi
  case "$p" in
    openai|xai|anthropic|chatgpt|github_copilot)
      if [[ ${#names[@]} == 0 ]]; then
        printf '  Model ID (available in your account): ' >&2; IFS= read -r model || return 1
        [[ -n "$model" ]] || return 1; names+=("$model")
      fi ;;
  esac
  models_json=$(printf '%s\n' "$old" | jq -c --arg p "$p" '.providers[$p].models // []') || return 1
  for model in ${names[@]+"${names[@]}"}; do
    [[ "$model" != *$'\n'* && "$model" != *$'\r'* && "$model" != '*' && "$model" != */'*' ]] || return 1
    models_json=$(printf '%s\n' "$models_json" | jq --arg model "${model#"$p"/}" '. + [$model] | unique') || return 1
  done
  config=$(printf '%s\n' "$config" | jq --arg p "$p" --arg auth "$mode" --argjson models "$models_json" '.providers[$p]={enabled:true,auth:$auth,models:$models}') || return 1
  gateway_save_config "$config" || return 1
  if gateway_running_state && ! gateway_sync_locked; then gateway_save_config "$old"; return 1; fi
  info "Enabled ${p} (${mode}); start with spark gateway start"
}
gateway_remove() { gateway_with_lock gateway_remove_locked "$@"; }
gateway_remove_locked() {
  local p="${1:-}" old config
  gateway_provider_valid "$p" && [[ "$p" != vllm ]] || { err 'Cannot remove this provider'; return 1; }
  old=$(gateway_load_config)
  config=$(printf '%s\n' "$old" | jq --arg p "$p" '.providers[$p].enabled=false') || return 1
  gateway_save_config "$config" || return 1
  if gateway_running_state && ! gateway_sync_locked; then gateway_save_config "$old"; return 1; fi
  info "Disabled ${p}"
}
gateway_status() {
  local config state=stopped
  config=$(gateway_load_config)
  gateway_api_ready && state=ready || { gateway_running_state && state=not-ready || true; }
  printf 'LiteLLM: %s\nAPI: http://localhost:%s/v1\n' "$state" "$(gateway_configured_port)"
  printf 'Authentication: %s\n' "$(gateway_auth_ready && printf configured || printf migration-required)"
  printf '%s\n' "$config" | jq -r '.providers // {} | to_entries[] | select(.value.enabled) | "Provider: \(.key) (\(.value.auth // "local"))"'
  local p
  for p in chatgpt github_copilot xai; do
    if gateway_provider_enabled "$p" | grep -qx true && { [[ "$p" != xai ]] || [[ "$(printf '%s\n' "$config" | jq -r '.providers.xai.auth')" == oauth ]]; }; then printf '%s OAuth: %s\n' "$p" "$(gateway_oauth_status "$p")"; fi
  done
  gateway_access_status
}
cmd_gateway() {
  local cmd="${1:-help}"; [[ $# == 0 ]] || shift
  case "$cmd" in
    setup) gateway_setup_local "$@" ;; start) gateway_start ;; stop) gateway_with_lock gateway_stop ;; status) gateway_status ;; logs) gateway_logs "$@" ;;
    add) gateway_add "$@" ;; remove) gateway_remove "$@" ;; auth) gateway_auth_command "$@" ;;
    login) gateway_with_lock gateway_login "$@" ;; import-session) gateway_with_lock gateway_import_session "$@" ;; logout) gateway_with_lock gateway_logout "$@" ;;
    capabilities) gateway_capabilities "${1:-base}" "$(gateway_runtime_image)" ;; access) gateway_access_command "$@" ;;
    help|--help|-h)
      cat <<'HELP'
Usage: spark gateway <setup|start|stop|status|logs|add|remove|auth|login|logout|capabilities|access>
  setup [--yes]             Configure local providers, authentication and access
  auth status|rotate         Check authentication or rotate the private token
  auth reset                 Replace a lost/leaked inference token (shown once)
  login PROVIDER [--remote USER@HOST]
                             OAuth login on this computer, optionally install remotely
  logout PROVIDER            Disable the provider and remove its session
  add PROVIDER [--auth api|oauth] [--model ID ...]
                             openai, chatgpt, github_copilot, xai, anthropic,
                             openrouter, ollama, zen, together
  capabilities [PROVIDER]    Inspect installed LiteLLM version/login capability
  access nodes|allow|policy|enable|disable|status|protect|probe|verify
                             HTTPS access and Tailscale policy workflow
Provider API keys are read with hidden input; subscriptions use a separate login.
New gateway tokens appear once in an interactive terminal; save them immediately.
Stored tokens cannot be displayed by the CLI. Lost token? Use auth reset.
Claude Pro/Max is not offered as a general gateway API.
HELP
      ;;
    *) err "Unknown gateway command: $cmd"; return 1 ;;
  esac
}

# Validate the proposed configuration before interrupting a working proxy.
gateway_preflight() {
  local config p mode env_key key
  config=$(gateway_load_config) || return 1
  gateway_capabilities keys >/dev/null || { err 'LiteLLM image lacks PostgreSQL virtual-key support'; return 1; }
  printf '%s\n' "$config" | jq -e '.port // 4000 | type=="number" and .>0 and .<=65535' >/dev/null || return 1
  for p in openrouter zen together openai anthropic xai chatgpt github_copilot; do
    [[ "$(gateway_provider_enabled "$p")" == true ]] || continue
    mode=$(printf '%s\n' "$config" | jq -r --arg p "$p" '.providers[$p].auth // (if $p=="chatgpt" or $p=="github_copilot" then "oauth" else "api" end)')
    if [[ "$mode" == oauth ]]; then
      gateway_capabilities "$p" >/dev/null && [[ "$(gateway_oauth_status "$p")" == credentials-present ]] || { err "Provider ${p} requires supported login: spark gateway login ${p}"; return 1; }
    else
      env_key=$(gateway_provider_env "$p") || return 1
      key=$(gateway_env_get "$env_key" 2>/dev/null || true)
      [[ -n "$key" ]] || { err "Provider ${p} needs an API key: spark gateway add ${p}"; return 1; }
    fi
  done
}
gateway_register_ollama() { gateway_with_lock gateway_register_ollama_locked "$@"; }
gateway_register_ollama_locked() {
  local config
  config=$(gateway_load_config) || return 1
  gateway_save_config "$(printf '%s\n' "$config" | jq --arg m "$1" '.providers.ollama.enabled=true | .providers.ollama.models=((.providers.ollama.models // []) + [$m] | unique)')"
}
gateway_forget_ollama() { gateway_with_lock gateway_forget_ollama_locked "$@"; }
gateway_forget_ollama_locked() {
  gateway_configured || return 0
  local target="$1" loaded="$2" config
  [[ -n "$target" ]] || target="$loaded"
  config=$(gateway_load_config) || return 1
  if [[ "$target" == --all ]]; then
    config=$(printf '%s\n' "$config" | jq '.providers.ollama.models=[]') || return 1
  else
    config=$(printf '%s\n' "$config" | jq --arg m "$target" '.providers.ollama.models=((.providers.ollama.models // []) | map(select(.!=$m)))') || return 1
  fi
  gateway_save_config "$config"
}
gateway_route_smoke() {
  local provider="$1" model="$2" id payload out
  [[ "$provider" == ollama ]] && id="ollama_chat/$model" || id="vllm/$model"
  payload=$(jq -nc --arg id "$id" '{model:$id,messages:[{role:"user",content:"Reply OK"}],max_tokens:1,stream:false}') || return 1
  out=$(gateway_curl -fsS --max-time "${SPARK_GATEWAY_SMOKE_TIMEOUT:-60}" -H 'Content-Type: application/json' --data "$payload" "http://127.0.0.1:$(gateway_configured_port)/v1/chat/completions" 2>/dev/null) || return 1
  printf '%s\n' "$out" | jq -e '(.choices | type)=="array" and (.choices|length)>0' >/dev/null
}
gateway_setup_local() {
  local auto=0 p mode nodes
  [[ $# == 0 ]] || { [[ $# == 1 && "$1" == --yes ]] || return 1; auto=1; }
  gateway_prepare_runtime "$BACKEND" || return 1
  # Adopt existing Ollama models on first migration; preserve an explicit registry.
  if [[ "$BACKEND" == ollama ]] && ! gateway_load_config | jq -e '.providers.ollama | has("models")' >/dev/null; then
    while IFS= read -r p; do [[ -z "$p" ]] || gateway_register_ollama "$p" || return 1; done < <(ollama ps 2>/dev/null | awk 'NR>1{print $1}')
  fi
  if [[ "$auto" == 0 ]]; then
    printf 'API accounts and subscriptions use separate credentials. Models depend on your account.\n'
    for p in openai chatgpt github_copilot xai anthropic openrouter zen together; do
      mode=api
      case "$p" in
        chatgpt|github_copilot) mode=oauth ;;
        xai) if confirm 'Use xAI / SuperGrok subscription login instead of an API key?'; then mode=oauth; fi ;;
      esac
      confirm "Configure ${p} (${mode})?" || continue
      if [[ "$mode" == oauth && "$(gateway_oauth_status "$p")" != credentials-present ]]; then gateway_with_lock gateway_login "$p" || return 1; fi
      gateway_add "$p" --auth "$mode" || return 1
    done
  fi
  gateway_start || return 1
  gateway_status
  if [[ "$auto" == 0 ]] && confirm 'Select Tailscale nodes for private HTTPS access?'; then
    gateway_access_nodes || return 1
    printf 'Node names/IPs (space separated): ' >&2; IFS= read -r nodes || return 1
    local selected=()
    read -ra selected <<< "$nodes"
    gateway_with_lock gateway_access_allow ${selected[@]+"${selected[@]}"} || return 1
    printf 'Apply the generated policy, then: spark gateway access enable\n'
  fi
}

gateway_managed_client_endpoint() {
  case "$1" in
    ''|"http://127.0.0.1:$(gateway_configured_port)/v1"|"http://localhost:$(gateway_configured_port)/v1"|"http://host.openshell.internal:$(gateway_configured_port)/v1") return 0 ;;
    *) return 1 ;;
  esac
}

gateway_runtime_image() {
  local image=''
  if gateway_running_state; then image=$(docker inspect "$GATEWAY_CONTAINER" --format '{{.Image}}' 2>/dev/null || true); fi
  printf '%s\n' "${image:-$LITELLM_IMAGE}"
}
gateway_provider_status_json() {
  local providers='{}' p mode session entry
  while IFS=$'\t' read -r p mode; do
    [[ -n "$p" ]] || continue
    session=not-applicable
    [[ "$mode" != oauth ]] || session=$(gateway_oauth_status "$p") || return 1
    entry=$(jq -nc --arg auth "$mode" --arg session "$session" '{enabled:true,auth:$auth,session:$session}') || return 1
    providers=$(printf '%s\n' "$providers" | jq -c --arg p "$p" --argjson entry "$entry" '.[$p]=$entry') || return 1
  done < <(gateway_load_config | jq -r '.providers // {} | to_entries[] | select(.value.enabled) | [.key,(.value.auth // "local")] | @tsv')
  printf '%s\n' "$providers"
}

# Delete only Spark-owned recovery files after authenticated runtime/client checks.
gateway_migration_cleanup() {
  local backup="$SPARK_CONFIG_DIR/gateway-migration"
  [[ -d "$backup" && ! -L "$backup" ]] || return 0
  rm -f "$backup/gateway.json" "$backup/gateway.env" "$backup/litellm_config.yaml" || return 1
  rmdir "$backup" || { err 'Recovery folder contains unexpected files; inspect it manually'; return 1; }
}
gateway_migration_restore_config() {
  local backup="$SPARK_CONFIG_DIR/gateway-migration/gateway.json" restored p key env_key
  [[ -f "$backup" ]] || return 0
  restored=$(jq '.' "$backup") || return 1
  for p in openrouter zen together openai xai anthropic; do
    key=$(printf '%s\n' "$restored" | jq -r --arg p "$p" '.providers[$p].api_key // ""') || return 1
    if [[ -n "$key" ]]; then
      env_key=$(gateway_provider_env "$p") || return 1
      gateway_env_set "$env_key" "$key" || return 1
    fi
  done
  restored=$(printf '%s\n' "$restored" | jq 'if .providers then del(.providers[].api_key) else . end') || return 1
  gateway_save_config "$restored"
}
