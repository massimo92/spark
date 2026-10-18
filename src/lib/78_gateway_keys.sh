# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
# Native LiteLLM virtual keys: persistent hashes, runtime-only administrative key.
gateway_key_hash() { printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; }
gateway_auth_key() {
  # Internal administration only. Never export this to an inference client.
  docker exec "$GATEWAY_CONTAINER" cat /run/spark/master-key 2>/dev/null
}
gateway_auth_ready() {
  gateway_load_config | jq -e '.auth.storage=="virtual-keys" and (.auth.client_hash | type=="string" and test("^[a-f0-9]{64}$")) and (.auth.recovery_required!=true)' >/dev/null
}
gateway_database_name() { printf '%s-db\n' "$GATEWAY_CONTAINER"; }
gateway_database_owner() { printf '%s' "$SPARK_CONFIG_DIR" | shasum -a 256 | awk '{print $1}'; }
gateway_database_remove() {
  local purge="${1:-0}" dry_run="${2:-0}" name owner existing volume
  name=$(gateway_database_name); owner=$(gateway_database_owner)
  if existing=$(docker inspect "$name" --format '{{json .Config.Labels}}' 2>/dev/null); then
    printf '%s' "$existing" | jq -e --arg owner "$owner" '.["io.spark.gateway-owner"]==$owner' >/dev/null || {
      warn 'Leaving a database container owned by another configuration'; return 1;
    }
    if [[ "$dry_run" == 1 ]]; then
      printf '  would remove container %s (database volumes retained unless --purge)\n' "$name"
    else
      docker rm -f "$name" >/dev/null 2>&1 || return 1
    fi
  fi
  [[ "$purge" == 1 ]] || return 0
  for volume in "$name-data" "$name-socket"; do
    existing=$(docker volume inspect "$volume" --format '{{json .Labels}}' 2>/dev/null) || continue
    printf '%s' "$existing" | jq -e --arg owner "$owner" '.["io.spark.gateway-owner"]==$owner' >/dev/null || return 1
    if [[ "$dry_run" == 1 ]]; then printf '  would remove volume %s\n' "$volume"; else docker volume rm "$volume" >/dev/null || return 1; fi
  done
}
gateway_database_prepare() {
  local name owner existing attempt volume
  name=$(gateway_database_name); owner=$(gateway_database_owner)
  if existing=$(docker inspect "$name" --format '{{json .}}' 2>/dev/null); then
    printf '%s\n' "$existing" | jq -e --arg owner "$owner" --arg name "$name" '
      .Config.Labels["io.spark.gateway-owner"]==$owner and .HostConfig.NetworkMode=="none" and
      (.HostConfig.PortBindings // {} | length)==0 and
      any(.Mounts[]; .Name==($name+"-data") and .Destination=="/var/lib/postgresql/data") and
      any(.Mounts[]; .Name==($name+"-socket") and .Destination=="/var/run/postgresql")' >/dev/null || {
      err 'Gateway database container is not privately owned by this configuration'; return 1;
    }
    docker start "$name" >/dev/null 2>&1 || return 1
  else
    for volume in "$name-data" "$name-socket"; do
      if existing=$(docker volume inspect "$volume" --format '{{json .Labels}}' 2>/dev/null); then
        printf '%s\n' "$existing" | jq -e --arg owner "$owner" '.["io.spark.gateway-owner"]==$owner' >/dev/null || { err 'Database volume belongs to another configuration'; return 1; }
      else
        docker volume create --label "io.spark.gateway-owner=$owner" "$volume" >/dev/null || return 1
      fi
    done
    # No TCP listener/network/password file: only the explicitly mounted Unix socket.
    docker run -d --name "$name" --label "io.spark.gateway-owner=$owner" --restart unless-stopped --network none \
      -e POSTGRES_DB=litellm -e POSTGRES_USER=spark -e POSTGRES_HOST_AUTH_METHOD=trust \
      -e 'POSTGRES_INITDB_ARGS=--auth-local=trust --auth-host=reject' \
      -v "$name-data:/var/lib/postgresql/data" -v "$name-socket:/var/run/postgresql" \
      "${SPARK_GATEWAY_POSTGRES_IMAGE:-postgres:17-alpine}" postgres -c 'listen_addresses=' >/dev/null 2>&1 || { err 'Could not start private LiteLLM PostgreSQL'; return 1; }
  fi
  for ((attempt=0; attempt<30; attempt++)); do
    docker exec "$name" pg_isready -q -h /var/run/postgresql -U spark -d litellm >/dev/null 2>&1 && return 0
    sleep 1
  done
  err 'Private LiteLLM PostgreSQL did not become ready'; return 1
}
gateway_database_client_hashes() {
  local hashes
  hashes=$(docker exec "$(gateway_database_name)" psql -X -A -t -v ON_ERROR_STOP=1 -U spark -d litellm -c \
    'SELECT token FROM "LiteLLM_VerificationToken" WHERE user_id = '\''spark-clients'\'' ORDER BY token') || return 1
  printf '%s\n' "$hashes" | jq -Rn '[inputs | select(length>0)] | if all(.[]; test("^[a-f0-9]{64}$")) then . else error("Invalid virtual-key hash") end'
}
gateway_database_migrate() {
  local script
  # Use Prisma's own migrator and socket URL. Some LiteLLM migration coordinators
  # strip libpq's host query parameter and would incorrectly attempt TCP.
  script='import pathlib, subprocess
import litellm_proxy_extras
schema = pathlib.Path(litellm_proxy_extras.__file__).parent / "schema.prisma"
subprocess.run(["prisma", "migrate", "deploy", "--schema", str(schema)], check=True)'
  docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/tmp \
    -e 'DATABASE_URL=postgresql://spark@localhost/litellm?host=/var/run/postgresql' \
    -v "$(gateway_database_name)-socket:/var/run/postgresql" --entrypoint python \
    "${GATEWAY_RESTORE_IMAGE:-$LITELLM_IMAGE}" -c "$script" >/dev/null 2>&1 || {
    err 'LiteLLM schema migration over the private PostgreSQL socket failed'; return 1;
  }
}
gateway_admin_post() {
  local path="$1" key payload
  payload=$(cat) || return 1
  key=$(gateway_auth_key) || return 1
  [[ "$key" =~ ^sk-[a-f0-9]{64}$ ]] || return 1
  # Curl reads both authorization and secret JSON from stdin, never argv/files.
  { printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$key"
    printf 'data = %s\n' "$(printf '%s' "$payload" | jq -Rs .)"
  } | curl --config - -fsS --max-time 60 "http://127.0.0.1:$(gateway_configured_port)$path" 2>/dev/null
}
gateway_virtual_owner_ensure() {
  local user="$1" body info
  case "$user" in spark-clients|spark-managed) ;; *) return 1 ;; esac
  info=$(gateway_curl -fsS --max-time 10 "http://127.0.0.1:$(gateway_configured_port)/user/info?user_id=$user" 2>/dev/null) || info='{}'
  if ! printf '%s\n' "$info" | jq -e --arg user "$user" '.user_info.user_id==$user' >/dev/null; then
    body=$(printf '{"user_id":"%s","user_role":"internal_user","auto_create_key":false}' "$user")
    printf '%s' "$body" | gateway_admin_post /user/new >/dev/null || return 1
    info=$(gateway_curl -fsS --max-time 10 "http://127.0.0.1:$(gateway_configured_port)/user/info?user_id=$user" 2>/dev/null) || return 1
  fi
  printf '%s\n' "$info" | jq -e '.user_info.user_role=="internal_user"' >/dev/null || { err 'Inference key owner must not be a proxy administrator'; return 1; }
}
gateway_virtual_create() {
  local user="$1" key="$2" duration="${3:-}" response body alias_hash
  [[ "$key" =~ ^sk-[a-f0-9]{64}$ ]] || return 1
  gateway_virtual_owner_ensure "$user" || return 1
  alias_hash=$(gateway_key_hash "$key") || return 1
  body=$(printf '{"key":"%s","user_id":"%s","key_alias":"%s-%s","allowed_routes":["llm_api_routes"],"models":[]}' "$key" "$user" "$user" "${alias_hash:0:12}")
  if [[ -n "$duration" ]]; then
    [[ "$duration" == 5m ]] || return 1
    body="${body%\}},\"duration\":\"5m\"}"
  fi
  response=$(printf '%s' "$body" | gateway_admin_post /key/generate) || return 1
  [[ "$(printf '%s' "$response" | jq -r '.key // empty')" == "$key" ]]
}
gateway_virtual_validate() {
  local key="$1" code
  [[ "$key" =~ ^sk-[a-f0-9]{64}$ ]] || return 1
  printf 'header = "Authorization: Bearer %s"\n' "$key" | curl --config - -fsS --max-time 5 \
    "http://127.0.0.1:$(gateway_configured_port)/v1/models" >/dev/null 2>&1 || return 1
  # Even a valid inference key must not enumerate or administer other keys.
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$key" | curl --config - -sS --max-time 5 -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$(gateway_configured_port)/key/list" 2>/dev/null) || return 1
  [[ "$code" == 401 || "$code" == 403 ]]
}
gateway_virtual_record() {
  local config
  [[ "$1" =~ ^[a-f0-9]{64}$ ]] || return 1
  config=$(gateway_load_config | jq --arg hash "$1" '.auth={storage:"virtual-keys",client_hash:$hash}') || return 1
  gateway_save_config "$config"
}
gateway_legacy_token_cleanup() {
  local path tmp
  path=$(gateway_secrets_path)
  [[ -f "$path" ]] || return 0
  tmp=$(umask 077; mktemp "$path.tmp.XXXXXX") || return 1
  awk 'index($0,"LITELLM_MASTER_KEY=")!=1' "$path" > "$tmp"
  chmod 600 "$tmp" && mv "$tmp" "$path"
}
gateway_virtual_ensure() {
  [[ "${SPARK_GATEWAY_DEFER_CLIENT:-0}" != 1 ]] || return 0
  local config hash hashes key fresh=0
  config=$(gateway_load_config) || return 1
  [[ "$(printf '%s' "$config" | jq -r '.auth.recovery_required // false')" != true ]] || { err 'Token recovery required: spark gateway auth rotate'; return 1; }
  hashes=$(gateway_database_client_hashes) || return 1
  hash=$(printf '%s' "$config" | jq -r '.auth.client_hash // empty')
  if [[ -n "$hash" ]]; then
    printf '%s' "$hashes" | jq -e --arg hash "$hash" '.==[$hash]' >/dev/null || { err 'Client key state differs from PostgreSQL; run spark gateway auth rotate'; return 1; }
  elif [[ "$(printf '%s' "$hashes" | jq length)" == 1 ]]; then
    hash=$(printf '%s' "$hashes" | jq -r '.[0]')
    gateway_virtual_record "$hash" || return 1
  elif [[ "$hashes" == '[]' || "$(printf '%s' "$hashes" | jq length)" == 0 ]]; then
    # Adopt a known legacy key as an inference-only key; never redisplay it.
    key=$(gateway_env_get LITELLM_MASTER_KEY 2>/dev/null || true)
    if [[ -z "$key" ]]; then key="sk-$(openssl rand -hex 32)" || return 1; fresh=1; fi
    gateway_virtual_create spark-clients "$key" && gateway_virtual_validate "$key" || return 1
    hash=$(gateway_key_hash "$key")
    gateway_virtual_record "$hash" || return 1
    [[ "$fresh" == 0 ]] || gateway_auth_present_new "$key"
  else
    err 'Multiple client keys found; run spark gateway auth rotate'; return 1
  fi
  gateway_legacy_token_cleanup
}
gateway_managed_client_key() {
  local key
  key=$(workspace_read_env COMPATIBLE_API_KEY 2>/dev/null || true)
  if [[ -n "$key" ]] && gateway_virtual_validate "$key"; then printf '%s\n' "$key"; return 0; fi
  key="sk-$(openssl rand -hex 32)" || return 1
  gateway_virtual_create spark-managed "$key" && gateway_virtual_validate "$key" || return 1
  # This is the client's own restricted credential, never the user/admin token.
  workspace_set_env_key COMPATIBLE_API_KEY "$key" || return 1
  printf '%s\n' "$key"
}
gateway_auth_replace_locked() {
  local hashes count key hash config
  gateway_auth_terminal || { err 'Token rotation requires an interactive terminal (ssh -t for a remote command)'; return 1; }
  docker info >/dev/null 2>&1 || { err 'Cannot inspect LiteLLM; no revocation confirmed'; return 1; }
  if ! gateway_running_state || [[ "$(docker inspect "$GATEWAY_CONTAINER" --format '{{index .Config.Labels "io.spark.auth-mode"}}' 2>/dev/null)" != virtual-keys ]]; then
    SPARK_GATEWAY_DEFER_CLIENT=1 gateway_sync_locked || { gateway_auth_recovery_stop; return 1; }
  fi
  gateway_wait_ready || { gateway_auth_recovery_stop; return 1; }
  hashes=$(gateway_database_client_hashes) || { gateway_auth_recovery_stop; return 1; }
  count=$(printf '%s' "$hashes" | jq length)
  key="sk-$(openssl rand -hex 32)" || return 1
  hash=$(gateway_key_hash "$key")
  # Mark uncertain transactions before calling the server. Never silently revert
  # a revoked key or automatically generate a replacement after an I/O failure.
  config=$(gateway_load_config | jq '.auth.recovery_required=true') || return 1
  gateway_save_config "$config" || return 1
  # Native regenerate is license-gated in some releases. Generate + delete uses
  # standard virtual-key APIs and never allows a grace period for the old key.
  gateway_virtual_create spark-clients "$key" && gateway_virtual_validate "$key" || { gateway_auth_recovery_stop; return 1; }
  if [[ "$count" != 0 ]]; then
    printf '{"keys":%s}' "$hashes" | gateway_admin_post /key/delete >/dev/null || { gateway_auth_recovery_stop; return 1; }
  fi
  hashes=$(gateway_database_client_hashes) || { gateway_auth_recovery_stop; return 1; }
  if ! printf '%s' "$hashes" | jq -e --arg hash "$hash" '.==[$hash]' >/dev/null || ! gateway_virtual_validate "$key" || ! gateway_virtual_record "$hash"; then
    gateway_auth_recovery_stop; return 1
  fi
  gateway_legacy_token_cleanup || return 1
  gateway_auth_present_new "$key"
  info 'Inference token replaced; the previous token is revoked. Update your clients'
}
gateway_auth_recovery_stop() {
  local config
  if ! config=$(gateway_load_config | jq '.auth.recovery_required=true') || ! gateway_save_config "$config"; then
    warn 'Could not record recovery state; keep the gateway stopped until auth rotate succeeds'
  fi
  if ! docker stop "$GATEWAY_CONTAINER" >/dev/null 2>&1; then
    err 'Could not stop LiteLLM after an unverified token change; revocation is NOT confirmed. Repair Docker access and run spark gateway auth rotate'; return 1
  fi
  err 'Token change could not be verified; gateway stopped. Run spark gateway auth rotate to recover; no old token will be restored'
}
gateway_auth_rotate() { gateway_with_lock gateway_auth_replace_locked; }
