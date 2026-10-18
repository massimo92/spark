# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
# Native OAuth beside the browser; session transfer uses ordinary authenticated SSH.
gateway_login() {
  local p="${1:-}"
  [[ $# -gt 0 ]] || return 1; shift
  if [[ $# == 0 ]]; then gateway_login_local "$p"; return $?; fi
  [[ $# == 2 && "$1" == --remote ]] || { err 'Usage: spark gateway login PROVIDER [--remote USER@HOST]'; return 1; }
  gateway_login_remote "$p" "$2"
}
gateway_login_remote() (
  local p="$1" target="$2" transfer cleanup file
  gateway_oauth_env "$p" >/dev/null || return 1
  # Keep SSH options and remote command syntax out of user-supplied hostnames.
  [[ "$target" =~ ^[A-Za-z0-9_][A-Za-z0-9_.@:-]*$ ]] || { err 'Use an SSH alias or USER@HOST'; return 1; }
  [[ -z "${SSH_CONNECTION:-}" || "$p" != xai ]] || { err 'Start this command on the computer with your browser'; return 1; }
  docker info >/dev/null 2>&1 || { err 'Local OAuth requires Docker on the computer with the browser'; return 1; }
  docker image inspect "$LITELLM_IMAGE" >/dev/null 2>&1 || docker pull "$LITELLM_IMAGE" >/dev/null || return 1
  mkdir -p "$SPARK_CONFIG_DIR" && chmod 700 "$SPARK_CONFIG_DIR" || return 1
  transfer=$(umask 077; mktemp -d "$SPARK_CONFIG_DIR/oauth-transfer.XXXXXX") || return 1
  printf -v cleanup 'rm -rf -- %q' "$transfer"
  # shellcheck disable=SC2064 # Capture the quoted private path before function scope ends.
  trap "$cleanup" EXIT
  SPARK_CONFIG_DIR="$transfer" gateway_login_local "$p" || return 1
  file="$transfer/oauth/$p/$(gateway_oauth_file "$p")"
  # Never place credentials in command arguments, stdout, or a controller backup.
  ssh -o BatchMode=yes -o ClearAllForwardings=yes -o ForwardAgent=no -o ConnectTimeout=10 "$target" "\"\$HOME/.local/bin/spark\" gateway import-session $p" < "$file" || return 1
  info "OAuth session installed on ${target}; temporary local credentials removed on exit"
)
gateway_import_session() {
  local p="${1:-}" file dir content old='' running=0 mode
  [[ $# == 1 ]] || return 1
  file=$(gateway_oauth_file "$p") || return 1
  content=$(head -c 65537) || return 1
  [[ -n "$content" && ${#content} -le 65536 ]] || { err 'Invalid or oversized OAuth session'; return 1; }
  if [[ "$p" == github_copilot ]]; then
    [[ "$content" =~ ^[A-Za-z0-9_.~+/=-]+$ ]] || return 1
  else
    printf '%s\n' "$content" | jq -e 'type=="object"' >/dev/null || return 1
    if [[ "$p" == xai ]]; then
      printf '%s\n' "$content" | jq -e '(.access_token|type=="string" and length>0) and (.refresh_token|type=="string" and length>0) and (.token_endpoint|type=="string" and startswith("https://auth.x.ai/"))' >/dev/null || return 1
    fi
  fi
  gateway_capabilities "$p" >/dev/null || { err 'Remote LiteLLM image does not support this OAuth provider'; return 1; }
  dir=$(gateway_oauth_dir "$p")
  mkdir -p "$dir" && chmod 700 "$SPARK_CONFIG_DIR" "$SPARK_CONFIG_DIR/oauth" "$dir" || return 1
  mode=$(gateway_load_config | jq -r --arg p "$p" 'if .providers[$p].enabled and .providers[$p].auth=="oauth" then "oauth" else "inactive" end') || return 1
  if [[ "$mode" == oauth ]] && gateway_running_state; then
    running=1
    # Stop refresh workers before reading/replacing credentials from another account.
    docker stop "$GATEWAY_CONTAINER" >/dev/null 2>&1 || { err 'Could not stop OAuth refresh; session left unchanged'; return 1; }
  fi
  [[ ! -f "$dir/$file" ]] || old=$(cat "$dir/$file")
  if ! gateway_session_write "$dir/$file" "$content"; then
    [[ "$running" == 0 ]] || gateway_sync_locked || err 'Could not restart the previous OAuth session'
    return 1
  fi
  [[ "$p" != github_copilot ]] || rm -f "$dir/api-key.json"
  if [[ "$running" == 1 ]] && ! gateway_sync_locked; then
    docker stop "$GATEWAY_CONTAINER" >/dev/null 2>&1 || { err 'Could not stop the replacement session; inspect gateway status'; return 1; }
    if [[ -n "$old" ]]; then gateway_session_write "$dir/$file" "$old" || return 1; else rm -f "$dir/$file"; fi
    gateway_sync_locked || err 'Previous OAuth session could not be restored'
    return 1
  fi
  [[ "$running" == 1 ]] || info "${p} OAuth session installed; enable its models with spark gateway add ${p}"
}
gateway_session_write() {
  local file="$1" content="$2" tmp
  tmp=$(umask 077; mktemp "${file}.tmp.XXXXXX") || return 1
  if printf '%s\n' "$content" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$file"; then return 0; fi
  rm -f "$tmp"; return 1
}
