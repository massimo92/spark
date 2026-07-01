# --- Workspace setup: Vikunja + n8n + Hermes/NemoClaw behind Tailscale ---

WORKSPACE_VIKUNJA_HERMES_EMAIL="${WORKSPACE_VIKUNJA_HERMES_EMAIL:-hermes@spark.invalid}"

workspace_random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '\n'
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48
  fi
}

workspace_env_or_generated() {
  local key="$1" val=""
  val=$(workspace_read_env "$key" 2>/dev/null || true)
  if [[ -n "$val" ]]; then
    printf '%s\n' "$val"
  else
    workspace_random_secret
  fi
}

workspace_env_or_value() {
  local key="$1" fallback="$2" val=""
  val=$(workspace_read_env "$key" 2>/dev/null || true)
  if [[ -n "$val" ]]; then
    printf '%s\n' "$val"
  else
    printf '%s\n' "$fallback"
  fi
}

workspace_install_file() {
  local file="$1" mode="$2" tmp
  tmp="${file}.tmp"
  mkdir -p "$(dirname "$file")"
  cat > "$tmp"
  chmod "$mode" "$tmp"
  if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
  else
    mv "$tmp" "$file"
  fi
}

workspace_data_dir_has_content() {
  local dir
  for dir in "$@"; do
    [[ -d "$dir" ]] || continue
    find "$dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q . && return 0
  done
  return 1
}

workspace_backup_invalid_env_file() {
  local file="$1" suffix backup
  [[ -f "$file" ]] || return 0
  workspace_env_file_syntax_valid "$file" && return 0
  suffix="${SPARK_WORKSPACE_BACKUP_SUFFIX:-$(date +%Y%m%d%H%M%S)}"
  backup="${file}.bak.${suffix}"
  cp "$file" "$backup" 2>/dev/null || return 0
  chmod 600 "$backup" 2>/dev/null || true
  warn "Backed up invalid env file: ${backup}"
}

workspace_env_or_generated_guarded() {
  local key="$1" val=""
  shift
  val=$(workspace_read_env "$key" 2>/dev/null || true)
  if [[ -n "$val" ]]; then
    printf '%s\n' "$val"
    return 0
  fi
  if workspace_data_dir_has_content "$@"; then
    return 1
  fi
  workspace_random_secret
}

workspace_doctor_passes_quiet() {
  local model="$1" old_read_only="${SPARK_WORKSPACE_READ_ONLY:-}" rc
  SPARK_WORKSPACE_READ_ONLY=1 cmd_workspace_doctor --json --model "$model" >/dev/null 2>&1
  rc=$?
  if [[ -n "$old_read_only" ]]; then
    SPARK_WORKSPACE_READ_ONLY="$old_read_only"
  else
    unset SPARK_WORKSPACE_READ_ONLY
  fi
  return "$rc"
}

workspace_doctor_failed_ids_quiet() {
  local model="$1" old_read_only="${SPARK_WORKSPACE_READ_ONLY:-}" out
  SPARK_WORKSPACE_READ_ONLY=1
  out=$(cmd_workspace_doctor --json --model "$model" 2>/dev/null || true)
  if [[ -n "$old_read_only" ]]; then
    SPARK_WORKSPACE_READ_ONLY="$old_read_only"
  else
    unset SPARK_WORKSPACE_READ_ONLY
  fi
  printf '%s\n' "$out" | jq -r '[.checks[]? | select(.ok == false) | .id] | join(",")' 2>/dev/null || true
}

workspace_compose() {
  docker compose --env-file "$WORKSPACE_ENV_FILE" -p "$WORKSPACE_PROJECT" -f "$WORKSPACE_COMPOSE_FILE" "$@"
}

workspace_require_config() {
  [[ -f "$WORKSPACE_ENV_FILE" && -f "$WORKSPACE_COMPOSE_FILE" ]] || \
    die "Workspace not configured" "Run: spark ws setup"
}

workspace_preflight() {
  local check_only="$1" ok=0
  if ! command -v docker >/dev/null 2>&1; then
    if [[ "$check_only" == "1" ]]; then setup_fail "Docker is required for workspace services"; else die "Docker is required for workspace services" "Run: spark setup"; fi
    ok=1
  elif ! docker compose version >/dev/null 2>&1; then
    if [[ "$check_only" == "1" ]]; then setup_fail "Docker Compose plugin missing or unusable"; else die "Docker Compose plugin missing or unusable" "Install Docker Compose v2, then retry"; fi
    ok=1
  fi
  if ! command -v curl >/dev/null 2>&1; then
    if [[ "$check_only" == "1" ]]; then setup_fail "curl is required for workspace HTTP/API checks"; else die "curl is required for workspace HTTP/API checks"; fi
    ok=1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    if [[ "$check_only" == "1" ]]; then setup_fail "jq is required for workspace setup"; else die "jq is required for workspace setup" "Run: spark setup"; fi
    ok=1
  fi
  return "$ok"
}

workspace_tailnet_suffix() {
  local json magic dns
  if [[ -n "${SPARK_WORKSPACE_TAILNET:-}" ]]; then
    printf '%s\n' "${SPARK_WORKSPACE_TAILNET%.}"
    return 0
  fi
  command -v tailscale >/dev/null 2>&1 || return 1
  json=$(tailscale status --json 2>/dev/null) || return 1
  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$json" | jq -r '
      if (.MagicDNSSuffix // "") != "" then
        .MagicDNSSuffix
      else
        (.Self.DNSName // "" | sub("^[^.]+[.]"; ""))
      end
    ' | sed 's/[.]$//'
  else
    magic=$(printf '%s\n' "$json" | sed -n 's/.*"MagicDNSSuffix"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/[.]$//')
    if [[ -n "$magic" ]]; then
      printf '%s\n' "$magic"
      return 0
    fi
    dns=$(printf '%s\n' "$json" | sed -n 's/.*"DNSName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/^[^.]*[.]//; s/[.]$//')
    [[ -n "$dns" ]] && printf '%s\n' "$dns"
  fi
}

workspace_tailscale_dns_name() {
  local json dns
  command -v tailscale >/dev/null 2>&1 || return 1
  json=$(tailscale status --json 2>/dev/null) || return 1
  if command -v jq >/dev/null 2>&1; then
    dns=$(printf '%s\n' "$json" | jq -r '.Self.DNSName // ""' | sed 's/[.]$//')
  else
    dns=$(printf '%s\n' "$json" | sed -n 's/.*"DNSName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/[.]$//')
  fi
  [[ -n "$dns" && "$dns" != "null" ]] || return 1
  printf '%s\n' "$dns"
}

workspace_tailscale_ipv4() {
  local json ip
  command -v tailscale >/dev/null 2>&1 || return 1
  if ip=$(tailscale ip -4 2>/dev/null | head -1) && [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  json=$(tailscale status --json 2>/dev/null) || return 1
  if command -v jq >/dev/null 2>&1; then
    ip=$(printf '%s\n' "$json" | jq -r '.Self.TailscaleIPs[]? | select(test("^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$"))' | head -1)
  else
    ip=$(printf '%s\n' "$json" | grep -Eo '"[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+"' | tr -d '"' | head -1)
  fi
  [[ -n "$ip" && "$ip" != "null" ]] || return 1
  printf '%s\n' "$ip"
}

workspace_url_for() {
  local service="$1" tailnet="$2"
  if [[ -n "$tailnet" ]]; then
    printf 'https://%s.%s\n' "$service" "$tailnet"
  else
    printf '%s' ""
  fi
}

workspace_model_state() {
  local model="$1" name m rest running=0 route_ok=0
  while IFS=$'\t' read -r name m rest; do
    [[ "$m" == "$model" ]] && running=1
  done < <(list_managed_containers)
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${GATEWAY_CONTAINER}$"; then
    route_ok=1
  fi
  if [[ "$running" == "1" && "$route_ok" == "1" ]]; then printf 'running+routed'
  elif [[ "$running" == "1" ]]; then printf 'running'
  else printf 'downloaded'; fi
}

workspace_litellm_model_name() {
  local model="$1"
  if [[ "$BACKEND" == "ollama" ]]; then
    printf 'ollama_chat/%s\n' "$model"
  else
    printf 'vllm/%s\n' "$model"
  fi
}

workspace_model_in_list() {
  local model="$1" m
  collect_downloaded_models
  for m in "${MODEL_LIST_MODELS[@]}"; do
    [[ "$m" == "$model" ]] && return 0
  done
  return 1
}

workspace_select_model() {
  local requested="$1" choice i state
  collect_downloaded_models
  [[ ${#MODEL_LIST_MODELS[@]} -gt 0 ]] || die "No downloaded models found" "Run: spark pull <model>"
  if [[ -n "$requested" ]]; then
    workspace_model_in_list "$requested" || die "Model not found in spark list: $requested"
    printf '%s\n' "$requested"
    return 0
  fi
  is_interactive || die "Choose a model with --model in non-interactive mode"
  printf "\n  ${BOLD}Choose the model Hermes will use:${NC}\n\n" >&2
  for i in "${!MODEL_LIST_MODELS[@]}"; do
    state=$(workspace_model_state "${MODEL_LIST_MODELS[$i]}")
    printf "    [%d] %-45s %-10s %s\n" "$((i + 1))" "${MODEL_LIST_MODELS[$i]}" "${MODEL_LIST_SIZES[$i]}" "$state" >&2
  done
  while true; do
    printf "\n  > " >&2
    read -r choice || true
    [[ "$choice" =~ ^[0-9]+$ ]] || { printf "  Enter a number.\n" >&2; continue; }
    [[ "$choice" -ge 1 && "$choice" -le ${#MODEL_LIST_MODELS[@]} ]] || { printf "  Enter 1-%d.\n" "${#MODEL_LIST_MODELS[@]}" >&2; continue; }
    printf '%s\n' "${MODEL_LIST_MODELS[$((choice - 1))]}"
    return 0
  done
}

workspace_ensure_gateway() {
  local check_only="$1" auto_yes="$2" model="$3" prov="vllm"
  [[ "$BACKEND" == "ollama" ]] && prov="ollama"
  if [[ ! -f "$GATEWAY_CONFIG" ]]; then
    if [[ "$check_only" == "1" ]]; then
      setup_fail "LiteLLM gateway not configured"; return 0
    fi
    local gw_json
    gw_json=$(jq -n --argjson port "$GATEWAY_PORT" \
      --argjson vllm_en "$( [[ "$prov" == "vllm" ]] && echo true || echo false )" \
      --argjson ollama_en "$( [[ "$prov" == "ollama" ]] && echo true || echo false )" \
      '{enabled:true, port:$port, providers:{
        vllm:{enabled:$vllm_en, port:8000},
        ollama:{enabled:$ollama_en},
        openrouter:{enabled:false, api_key:""},
        zen:{enabled:false, api_key:""},
        together:{enabled:false, api_key:""}
      }}')
    gateway_save_config "$gw_json"
    info "Configured LiteLLM gateway"
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${GATEWAY_CONTAINER}$"; then
    info "LiteLLM gateway: running"
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "LiteLLM gateway not running"
  elif [[ "$auto_yes" == "1" ]] || confirm "Start the LiteLLM gateway now?"; then
    gateway_start || setup_fail "Could not start LiteLLM gateway"
  else
    setup_fail "LiteLLM gateway required for Hermes"
  fi
  if [[ -n "$model" && "$(workspace_model_state "$model")" != *"running"* ]]; then
    if [[ "$check_only" == "1" ]]; then
      setup_fail "Model not running for Hermes: $model"
    elif [[ "$auto_yes" == "1" ]] || confirm "Start ${model} now with spark run?"; then
      cmd_run "$model" --no-wait
    else
      setup_fail "Hermes model not started: $model"
    fi
  fi
}

workspace_prepare_data_dirs() {
  local dir os owner group
  os=$(uname -s 2>/dev/null || true)
  if [[ "$os" == "Darwin" ]]; then
    return 0
  fi
  for dir in "${WORKSPACE_DATA_DIR}/vikunja-files" "${WORKSPACE_DATA_DIR}/n8n"; do
    [[ -d "$dir" ]] || continue
    owner=$(stat -c '%u' "$dir" 2>/dev/null || true)
    group=$(stat -c '%g' "$dir" 2>/dev/null || true)
    [[ "$owner" == "1000" && "$group" == "1000" ]] && continue
    if [[ "$(id -u)" == "0" ]]; then
      chown -R 1000:1000 "$dir" 2>/dev/null || warn "Could not chown ${dir} to 1000:1000"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo chown -R 1000:1000 "$dir" 2>/dev/null || warn "Could not sudo chown ${dir} to 1000:1000"
    else
      warn "Vikunja/n8n data dir may need permissions: sudo chown -R 1000:1000 ${dir}"
    fi
  done
}

workspace_require_single_line_value() {
  local label="$1" value="${2-}"
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
    || die "${label} must be a single line"
}

workspace_env_value_valid() {
  local value="${1-}"
  case "$value" in
    *$'\n'*|*$'\r'*|*[[:space:]]*|*\"*|*"'"*|*\\*|*'$'*|*'`'*) return 1 ;;
    *) return 0 ;;
  esac
}

workspace_env_value_hint() {
  printf "use one line with no spaces, quotes, backslashes, dollar signs, or backticks"
}

workspace_require_env_value() {
  local label="$1" value="${2-}"
  workspace_require_single_line_value "$label" "$value"
  workspace_env_value_valid "$value" || die "${label} is not safe for Docker env files; $(workspace_env_value_hint)"
}

workspace_value_looks_like_spark_error() {
  local value="${1-}"
  [[ "$value" == *"✗"* || "$value" == *" is required"* || "$value" == *" must be "* ]]
}

workspace_required_prompt_value_valid() {
  local kind="$1" value="${2-}"
  [[ -n "$value" ]] || return 1
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  workspace_value_looks_like_spark_error "$value" && return 1
  workspace_env_value_valid "$value" || return 1
  case "$kind" in
    username) [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]] ;;
    email) [[ "$value" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] ;;
    *) return 0 ;;
  esac
}

workspace_require_prompt_value() {
  local label="$1" value="${2-}" kind="${3:-text}"
  workspace_required_prompt_value_valid "$kind" "$value" || die "${label} is invalid or missing"
}

workspace_existing_prompt_value() {
  local key="$1" label="$2" kind="$3" value
  value=$(workspace_read_env "$key" 2>/dev/null || true)
  [[ -n "$value" ]] || return 0
  if workspace_required_prompt_value_valid "$kind" "$value"; then
    printf '%s\n' "$value"
    return 0
  fi
  warn "Ignoring invalid stored ${label}; setup will ask again"
  workspace_set_env_key "$key" ""
}

workspace_validate_image_ref() {
  local label="$1" value="$2"
  workspace_require_single_line_value "$label" "$value"
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]] \
    || die "Invalid ${label}: ${value}" "Use a plain Docker image reference like postgres:18 or registry/name:tag"
}

workspace_write_files() {
  local tailnet="$1" human_user="$2" human_email="$3" human_pass="$4" n8n_email="$5" n8n_pass="$6" hermes_pass="$7" model="$8"
  local vikunja_url n8n_url hermes_url n8n_host n8n_protocol n8n_secure_cookie litellm_model
  local tailscale_bind_addr tailscale_dns_name
  local postgres_pass vikunja_db_pass vikunja_secret n8n_db_pass n8n_key mention_secret
  local n8n_owner_status vikunja_token tailscale_mode
  local vikunja_api_status
  local vikunja_human_status vikunja_hermes_status vikunja_human_admin_status
  local postgres_image vikunja_image n8n_image old_umask
  tailscale_mode="${SPARK_WORKSPACE_TAILSCALE_MODE:-$(workspace_env_or_value WORKSPACE_TAILSCALE_MODE pending)}"
  tailscale_bind_addr=$(workspace_env_or_value WORKSPACE_TAILSCALE_BIND_ADDR 127.0.0.1)
  tailscale_dns_name=$(workspace_read_env WORKSPACE_TAILSCALE_DNS_NAME 2>/dev/null || true)
  if [[ "$tailscale_mode" == "ports" ]]; then
    tailscale_dns_name=$(workspace_tailscale_dns_name 2>/dev/null || true)
    tailscale_bind_addr=$(workspace_tailscale_ipv4 2>/dev/null || true)
    if [[ -n "$tailscale_dns_name" && -n "$tailscale_bind_addr" ]]; then
      vikunja_url="http://${tailscale_dns_name}:${WORKSPACE_VIKUNJA_PORT}"
      n8n_url="http://${tailscale_dns_name}:${WORKSPACE_N8N_PORT}"
      hermes_url="http://${tailscale_dns_name}:${WORKSPACE_HERMES_PORT}"
    else
      tailscale_mode=manual
      tailscale_bind_addr=127.0.0.1
      setup_fail "Tailscale MagicDNS/IPv4 not detected for ports fallback"
      vikunja_url=
      n8n_url=
      hermes_url=
    fi
  else
    if [[ -n "$tailnet" ]]; then
      tailscale_bind_addr=127.0.0.1
      vikunja_url=$(workspace_url_for vikunja "$tailnet" "$WORKSPACE_VIKUNJA_PORT")
      n8n_url=$(workspace_url_for n8n "$tailnet" "$WORKSPACE_N8N_PORT")
      hermes_url=$(workspace_url_for hermes "$tailnet" "$WORKSPACE_HERMES_PORT")
    else
      tailscale_mode=manual
      tailscale_bind_addr=127.0.0.1
      setup_fail "Tailscale tailnet DNS suffix not detected; workspace requires Tailscale Services or ports mode"
      vikunja_url=
      n8n_url=
      hermes_url=
    fi
  fi
  litellm_model=$(workspace_litellm_model_name "$model")
  workspace_backup_invalid_env_file "$WORKSPACE_ENV_FILE"
  workspace_backup_invalid_env_file "$WORKSPACE_POSTGRES_ENV_FILE"
  workspace_backup_invalid_env_file "$WORKSPACE_VIKUNJA_ENV_FILE"
  workspace_backup_invalid_env_file "$WORKSPACE_N8N_ENV_FILE"
  postgres_pass=$(workspace_env_or_generated_guarded POSTGRES_PASSWORD "${WORKSPACE_DATA_DIR}/postgres") \
    || { setup_fail "Missing Postgres password (POSTGRES_PASSWORD) while existing workspace data is present; restore it before rerun"; return 1; }
  vikunja_db_pass=$(workspace_env_or_generated VIKUNJA_DATABASE_PASSWORD)
  vikunja_secret=$(workspace_env_or_generated_guarded VIKUNJA_SERVICE_SECRET "${WORKSPACE_DATA_DIR}/postgres" "${WORKSPACE_DATA_DIR}/vikunja-files") \
    || { setup_fail "Missing Vikunja service secret (VIKUNJA_SERVICE_SECRET) while existing workspace data is present; restore it before rerun"; return 1; }
  hermes_pass=$(workspace_env_or_value VIKUNJA_HERMES_PASSWORD "$hermes_pass")
  n8n_db_pass=$(workspace_env_or_generated DB_POSTGRESDB_PASSWORD)
  n8n_key=$(workspace_env_or_generated_guarded N8N_ENCRYPTION_KEY "${WORKSPACE_DATA_DIR}/postgres" "${WORKSPACE_DATA_DIR}/n8n") \
    || { setup_fail "Missing n8n encryption key (N8N_ENCRYPTION_KEY) while existing workspace data is present; restore it before rerun"; return 1; }
  n8n_owner_status=$(workspace_env_or_value N8N_OWNER_SETUP_STATUS pending)
  mention_secret=$(workspace_env_or_generated WORKSPACE_MENTION_SECRET)
  if [[ -n "${SPARK_WORKSPACE_VIKUNJA_TOKEN:-}" ]]; then
    vikunja_token="$SPARK_WORKSPACE_VIKUNJA_TOKEN"
  else
    vikunja_token=$(workspace_read_env VIKUNJA_HERMES_API_TOKEN 2>/dev/null || true)
  fi
  vikunja_api_status=$(workspace_env_or_value VIKUNJA_HERMES_API_STATUS pending)
  vikunja_human_status=$(workspace_env_or_value VIKUNJA_HUMAN_USER_STATUS pending)
  vikunja_hermes_status=$(workspace_env_or_value VIKUNJA_HERMES_USER_STATUS pending)
  vikunja_human_admin_status=$(workspace_env_or_value VIKUNJA_HUMAN_ADMIN_STATUS pending)
  postgres_image="${SPARK_WORKSPACE_POSTGRES_IMAGE:-$(workspace_env_or_value WORKSPACE_POSTGRES_IMAGE "$WORKSPACE_POSTGRES_IMAGE_DEFAULT")}"
  vikunja_image="${SPARK_WORKSPACE_VIKUNJA_IMAGE:-$(workspace_env_or_value WORKSPACE_VIKUNJA_IMAGE "$WORKSPACE_VIKUNJA_IMAGE_DEFAULT")}"
  n8n_image="${SPARK_WORKSPACE_N8N_IMAGE:-$(workspace_env_or_value WORKSPACE_N8N_IMAGE "$WORKSPACE_N8N_IMAGE_DEFAULT")}"
  workspace_validate_image_ref "Postgres image" "$postgres_image"
  workspace_validate_image_ref "Vikunja image" "$vikunja_image"
  workspace_validate_image_ref "n8n image" "$n8n_image"
  if [[ "$tailscale_mode" == "ports" && -n "$tailscale_dns_name" ]]; then
    n8n_host="${tailscale_dns_name}"
    n8n_protocol="http"
    n8n_secure_cookie=false
  elif [[ -n "$tailnet" ]]; then
    n8n_host="n8n.${tailnet}"
    n8n_protocol="https"
    n8n_secure_cookie=true
  else
    n8n_host=""
    n8n_protocol="http"
    n8n_secure_cookie=false
  fi
  workspace_require_env_value "Vikunja human username" "$human_user"
  workspace_require_env_value "Vikunja human email" "$human_email"
  workspace_require_env_value "Vikunja human recovery password" "$human_pass"
  workspace_require_env_value "Vikunja Hermes password" "$hermes_pass"
  workspace_require_env_value "n8n admin email" "$n8n_email"
  workspace_require_env_value "n8n admin/basic-auth password" "$n8n_pass"
  workspace_require_env_value "Hermes model" "$model"
  workspace_require_env_value "Postgres password" "$postgres_pass"
  workspace_require_env_value "Vikunja database password" "$vikunja_db_pass"
  workspace_require_env_value "Vikunja service secret" "$vikunja_secret"
  workspace_require_env_value "n8n database password" "$n8n_db_pass"
  workspace_require_env_value "n8n encryption key" "$n8n_key"
  workspace_require_env_value "workspace mention secret" "$mention_secret"
  workspace_require_env_value "Vikunja Hermes API token" "$vikunja_token"
  workspace_require_env_value "workspace Tailscale mode" "$tailscale_mode"
  workspace_require_env_value "workspace Tailscale bind address" "$tailscale_bind_addr"
  workspace_require_env_value "workspace Tailscale DNS name" "$tailscale_dns_name"
  workspace_require_env_value "workspace Postgres image" "$postgres_image"
  workspace_require_env_value "workspace Vikunja image" "$vikunja_image"
  workspace_require_env_value "workspace n8n image" "$n8n_image"
  mkdir -p "$WORKSPACE_CONFIG_DIR" "$WORKSPACE_DATA_DIR"/{vikunja-files,postgres,n8n,backups}
  chmod 700 "$WORKSPACE_CONFIG_DIR"
  workspace_prepare_data_dirs
  old_umask=$(umask)
  umask 077
  workspace_install_file "$WORKSPACE_ENV_FILE" 600 <<EOF
POSTGRES_DB=workspace
POSTGRES_USER=workspace
POSTGRES_PASSWORD=${postgres_pass}
VIKUNJA_DATABASE_PASSWORD=${vikunja_db_pass}
VIKUNJA_SERVICE_SECRET=${vikunja_secret}
VIKUNJA_HUMAN_USERNAME=${human_user}
VIKUNJA_HUMAN_EMAIL=${human_email}
VIKUNJA_HUMAN_RECOVERY_PASSWORD=${human_pass}
VIKUNJA_HUMAN_PASSWORD=
VIKUNJA_HUMAN_USER_STATUS=${vikunja_human_status}
VIKUNJA_HUMAN_ADMIN_STATUS=${vikunja_human_admin_status}
VIKUNJA_HERMES_USERNAME=hermes
VIKUNJA_HERMES_PASSWORD=${hermes_pass}
VIKUNJA_HERMES_USER_STATUS=${vikunja_hermes_status}
DB_POSTGRESDB_PASSWORD=${n8n_db_pass}
N8N_ENCRYPTION_KEY=${n8n_key}
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=${n8n_email}
N8N_BASIC_AUTH_PASSWORD=${n8n_pass}
N8N_OWNER_FIRST_NAME=${human_user}
N8N_OWNER_LAST_NAME=Spark
N8N_OWNER_SETUP_STATUS=${n8n_owner_status}
N8N_HOST=${n8n_host}
N8N_PROTOCOL=${n8n_protocol}
N8N_SECURE_COOKIE=${n8n_secure_cookie}
N8N_EDITOR_BASE_URL=${n8n_url}
WEBHOOK_URL=${n8n_url}
N8N_RUNNERS_ENABLED=true
N8N_BLOCK_ENV_ACCESS_IN_NODE=true
N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES=true
N8N_RESTRICT_FILE_ACCESS_TO=/home/node/.n8n
N8N_GIT_NODE_DISABLE_BARE_REPOS=true
N8N_GIT_NODE_ENABLE_HOOKS=false
N8N_SECURITY_POLICY_MANAGED_BY_ENV=true
N8N_PERSONAL_SPACE_PUBLISHING_ENABLED=false
N8N_PERSONAL_SPACE_SHARING_ENABLED=false
N8N_COMMUNITY_PACKAGES_ENABLED=false
N8N_UNVERIFIED_PACKAGES_ENABLED=false
N8N_VERIFIED_PACKAGES_ENABLED=false
N8N_COMMUNITY_PACKAGES_MANAGED_BY_ENV=true
N8N_COMMUNITY_PACKAGES=[]
VIKUNJA_SERVICE_PUBLICURL=${vikunja_url}
VIKUNJA_URL=${vikunja_url}
N8N_URL=${n8n_url}
HERMES_URL=${hermes_url}
HERMES_DASHBOARD_PORT=${WORKSPACE_HERMES_PORT}
HERMES_MODEL=${model}
HERMES_LITELLM_MODEL=${litellm_model}
HERMES_LITELLM_BASE_URL=http://127.0.0.1:${GATEWAY_PORT}/v1
HERMES_POLICY_TIER=restricted
HERMES_ONBOARD_STATUS=$(workspace_env_or_value HERMES_ONBOARD_STATUS pending)
WORKSPACE_MENTION_SECRET=${mention_secret}
VIKUNJA_HERMES_API_TOKEN=${vikunja_token}
VIKUNJA_HERMES_API_STATUS=${vikunja_api_status}
WORKSPACE_TAILSCALE_MODE=${tailscale_mode}
WORKSPACE_TAILSCALE_BIND_ADDR=${tailscale_bind_addr}
WORKSPACE_TAILSCALE_DNS_NAME=${tailscale_dns_name}
WORKSPACE_POSTGRES_IMAGE=${postgres_image}
WORKSPACE_VIKUNJA_IMAGE=${vikunja_image}
WORKSPACE_N8N_IMAGE=${n8n_image}
EOF
  workspace_install_file "$WORKSPACE_POSTGRES_ENV_FILE" 600 <<EOF
POSTGRES_DB=workspace
POSTGRES_USER=workspace
POSTGRES_PASSWORD=${postgres_pass}
VIKUNJA_DATABASE_PASSWORD=${vikunja_db_pass}
DB_POSTGRESDB_PASSWORD=${n8n_db_pass}
EOF
  workspace_install_file "$WORKSPACE_VIKUNJA_ENV_FILE" 600 <<EOF
VIKUNJA_DATABASE_TYPE=postgres
VIKUNJA_DATABASE_HOST=postgres
VIKUNJA_DATABASE_DATABASE=vikunja
VIKUNJA_DATABASE_USER=vikunja
VIKUNJA_DATABASE_PASSWORD=${vikunja_db_pass}
VIKUNJA_SERVICE_SECRET=${vikunja_secret}
VIKUNJA_SERVICE_PUBLICURL=${vikunja_url}
VIKUNJA_SERVICE_ENABLEREGISTRATION=false
VIKUNJA_SERVICE_ENABLELINKSHARING=false
VIKUNJA_SERVICE_INTERFACE=:3456
EOF
  workspace_install_file "$WORKSPACE_N8N_ENV_FILE" 600 <<EOF
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=${n8n_db_pass}
N8N_ENCRYPTION_KEY=${n8n_key}
N8N_BASIC_AUTH_ACTIVE=true
N8N_BASIC_AUTH_USER=${n8n_email}
N8N_BASIC_AUTH_PASSWORD=${n8n_pass}
N8N_HOST=${n8n_host}
N8N_PROTOCOL=${n8n_protocol}
N8N_SECURE_COOKIE=${n8n_secure_cookie}
N8N_EDITOR_BASE_URL=${n8n_url}
WEBHOOK_URL=${n8n_url}
N8N_RUNNERS_ENABLED=true
N8N_BLOCK_ENV_ACCESS_IN_NODE=true
N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES=true
N8N_RESTRICT_FILE_ACCESS_TO=/home/node/.n8n
N8N_GIT_NODE_DISABLE_BARE_REPOS=true
N8N_GIT_NODE_ENABLE_HOOKS=false
N8N_SECURITY_POLICY_MANAGED_BY_ENV=true
N8N_PERSONAL_SPACE_PUBLISHING_ENABLED=false
N8N_PERSONAL_SPACE_SHARING_ENABLED=false
N8N_COMMUNITY_PACKAGES_ENABLED=false
N8N_UNVERIFIED_PACKAGES_ENABLED=false
N8N_VERIFIED_PACKAGES_ENABLED=false
N8N_COMMUNITY_PACKAGES_MANAGED_BY_ENV=true
N8N_COMMUNITY_PACKAGES=[]
N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true
NODES_EXCLUDE=["n8n-nodes-base.executeCommand","n8n-nodes-base.readWriteFile"]
EOF
  workspace_install_file "${WORKSPACE_CONFIG_DIR}/init-db.sh" 700 <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

psql -v ON_ERROR_STOP=1 \
  -v vikunja_password="${VIKUNJA_DATABASE_PASSWORD}" \
  -v n8n_password="${DB_POSTGRESDB_PASSWORD}" \
  --username "${POSTGRES_USER}" \
  --dbname "${POSTGRES_DB}" <<'SQL'
SELECT format('CREATE USER vikunja WITH PASSWORD %L', :'vikunja_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vikunja')\gexec
SELECT format('ALTER USER vikunja WITH PASSWORD %L', :'vikunja_password')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vikunja')\gexec
SELECT format('CREATE USER n8n WITH PASSWORD %L', :'n8n_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n')\gexec
SELECT format('ALTER USER n8n WITH PASSWORD %L', :'n8n_password')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n')\gexec
SELECT 'CREATE DATABASE vikunja OWNER vikunja'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'vikunja')\gexec
SELECT 'CREATE DATABASE n8n OWNER n8n'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'n8n')\gexec
ALTER DATABASE vikunja OWNER TO vikunja;
ALTER DATABASE n8n OWNER TO n8n;
SQL
EOF
  umask 022
  workspace_install_file "$WORKSPACE_COMPOSE_FILE" 644 <<EOF
services:
  postgres:
    image: ${postgres_image}
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    pids_limit: 512
    security_opt:
      - no-new-privileges:true
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"
    env_file:
      - ${WORKSPACE_POSTGRES_ENV_FILE}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U workspace -d workspace"]
      interval: 10s
      timeout: 5s
      retries: 10
    volumes:
      - ${WORKSPACE_DATA_DIR}/postgres:/var/lib/postgresql/data
      - ${WORKSPACE_CONFIG_DIR}/init-db.sh:/docker-entrypoint-initdb.d/init-db.sh:ro

  vikunja:
    image: ${vikunja_image}
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    pids_limit: 512
    security_opt:
      - no-new-privileges:true
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"
    depends_on:
      postgres:
        condition: service_healthy
    env_file:
      - ${WORKSPACE_VIKUNJA_ENV_FILE}
    ports:
      - "${tailscale_bind_addr}:${WORKSPACE_VIKUNJA_PORT}:3456"
    volumes:
      - ${WORKSPACE_DATA_DIR}/vikunja-files:/app/vikunja/files

  n8n:
    image: ${n8n_image}
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    pids_limit: 512
    security_opt:
      - no-new-privileges:true
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"
    depends_on:
      postgres:
        condition: service_healthy
    env_file:
      - ${WORKSPACE_N8N_ENV_FILE}
    ports:
      - "${tailscale_bind_addr}:${WORKSPACE_N8N_PORT}:5678"
    volumes:
      - ${WORKSPACE_DATA_DIR}/n8n:/home/node/.n8n
EOF
  umask "$old_umask"
  info "Workspace files reconciled"
  info "Generated secure workspace credentials"
  info "Stored workspace credentials locally with 0600 permissions"
  info "Workspace access restricted to Tailscale/private bindings"
}

workspace_read_env() {
  local key="$1"
  [[ -f "$WORKSPACE_ENV_FILE" ]] || return 1
  sed -n "s/^${key}=//p" "$WORKSPACE_ENV_FILE" | head -1
}

workspace_postgres_psql() {
  local user db rc
  user=$(workspace_read_env POSTGRES_USER 2>/dev/null || true)
  db=$(workspace_read_env POSTGRES_DB 2>/dev/null || true)
  [[ -n "$user" ]] || user=workspace
  [[ -n "$db" ]] || db=workspace
  set +e
  workspace_compose exec -T postgres psql -v ON_ERROR_STOP=1 --username "$user" --dbname "$db" "$@"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 && "$db" != "postgres" ]]; then
    set +e
    workspace_compose exec -T postgres psql -v ON_ERROR_STOP=1 --username "$user" --dbname postgres "$@"
    rc=$?
    set -e
    return "$rc"
  fi
  return "$rc"
}

workspace_postgres_role_exists() {
  local role="$1" out
  out=$(workspace_postgres_psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${role}'" 2>/dev/null || true)
  [[ "$out" == *"1"* ]]
}

workspace_postgres_db_exists() {
  local db="$1" out
  out=$(workspace_postgres_psql -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'" 2>/dev/null || true)
  [[ "$out" == *"1"* ]]
}

workspace_postgres_ensure_role_db() {
  local role="$1" db="$2" password_key="$3" pass
  [[ "$role" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$db" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || die "Invalid Postgres role/database name"
  pass=$(workspace_read_env "$password_key")
  if workspace_postgres_role_exists "$role"; then
    if ! workspace_postgres_psql -v password="$pass" >/dev/null 2>&1 <<SQL
ALTER USER ${role} WITH PASSWORD :'password';
SQL
    then
      setup_fail "Could not update Postgres role: ${role}"
      return 1
    fi
  else
    if ! workspace_postgres_psql -v password="$pass" >/dev/null 2>&1 <<SQL
CREATE USER ${role} WITH PASSWORD :'password';
SQL
    then
      setup_fail "Could not create Postgres role: ${role}"
      return 1
    fi
  fi
  if workspace_postgres_db_exists "$db"; then
    workspace_postgres_psql -c "ALTER DATABASE ${db} OWNER TO ${role};" >/dev/null 2>&1 \
      || { setup_fail "Could not set owner for Postgres database: ${db}"; return 1; }
  else
    workspace_postgres_psql -c "CREATE DATABASE ${db} OWNER ${role};" >/dev/null 2>&1 \
      || { setup_fail "Could not create Postgres database: ${db}"; return 1; }
  fi
}

workspace_ensure_postgres_databases() {
  workspace_postgres_ensure_role_db vikunja vikunja VIKUNJA_DATABASE_PASSWORD || true
  workspace_postgres_ensure_role_db n8n n8n DB_POSTGRESDB_PASSWORD || true
}

workspace_vikunja_cli() {
  workspace_compose exec -T vikunja /app/vikunja/vikunja "$@"
}

workspace_wait_for_vikunja_cli() {
  local i
  for i in {1..30}; do
    workspace_vikunja_cli user list >/dev/null 2>&1 && return 0
    sleep "${SPARK_WORKSPACE_WAIT_SLEEP:-1}"
  done
  setup_fail "Vikunja CLI not ready; re-run spark ws setup after the service starts"
  return 1
}

workspace_vikunja_user_exists() {
  local username="$1" email="$2" out
  out=$(workspace_vikunja_cli user list 2>/dev/null) || return 2
  printf '%s\n' "$out" | awk -v username="$username" -v email="$email" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /\|/ {
      n = split($0, cols, "|")
      if (n >= 5 && trim(cols[3]) == username && trim(cols[4]) == email) { found=1 }
      next
    }
    index($0, username) && index($0, email) { found=1 }
    END { exit !found }
  '
}

workspace_ensure_vikunja_user() {
  local username="$1" email="$2" password="$3" status_key="$4"
  if workspace_vikunja_user_exists "$username" "$email"; then
    workspace_set_env_key "$status_key" exists
    info "Vikunja user exists: ${username}"
    return 0
  fi
  workspace_vikunja_cli user create -u "$username" -e "$email" -p "$password" >/dev/null 2>&1 || true
  if workspace_vikunja_user_exists "$username" "$email"; then
    workspace_set_env_key "$status_key" created
    info "Vikunja user created: ${username}"
    return 0
  fi
  workspace_set_env_key "$status_key" manual
  setup_fail "Vikunja user not verified: ${username}"
  return 1
}

workspace_create_vikunja_users() {
  local human_pass="${1:-}" human_user human_email hermes_pass
  workspace_wait_for_vikunja_cli || return 1
  human_user=$(workspace_read_env VIKUNJA_HUMAN_USERNAME)
  human_email=$(workspace_read_env VIKUNJA_HUMAN_EMAIL)
  hermes_pass=$(workspace_read_env VIKUNJA_HERMES_PASSWORD)
  [[ -n "$human_pass" ]] || human_pass=$(workspace_read_env VIKUNJA_HUMAN_RECOVERY_PASSWORD 2>/dev/null || true)
  [[ -n "$human_pass" ]] || human_pass=$(workspace_read_env VIKUNJA_HUMAN_PASSWORD 2>/dev/null || true)
  workspace_ensure_vikunja_user "$human_user" "$human_email" "$human_pass" VIKUNJA_HUMAN_USER_STATUS || true
  [[ "$(workspace_read_env VIKUNJA_HUMAN_USER_STATUS 2>/dev/null || true)" =~ ^(created|exists)$ ]] \
    && workspace_set_env_key VIKUNJA_HUMAN_PASSWORD ""
  workspace_vikunja_cli user set-admin "$human_user" --admin >/dev/null 2>&1 \
    && { workspace_set_env_key VIKUNJA_HUMAN_ADMIN_STATUS enabled; info "Vikunja admin set: ${human_user}"; } \
    || { workspace_set_env_key VIKUNJA_HUMAN_ADMIN_STATUS manual; warn "Could not promote ${human_user}; set admin manually if needed"; }
  workspace_ensure_vikunja_user hermes "$WORKSPACE_VIKUNJA_HERMES_EMAIL" "$hermes_pass" VIKUNJA_HERMES_USER_STATUS || true
  workspace_create_vikunja_hermes_token \
    || warn "Create a Vikunja API token for user 'hermes' in the UI, then rerun: spark ws setup --vikunja-token TOKEN"
}

workspace_set_env_key() {
  local key="$1" value="$2" tmp count current
  [[ "${SPARK_WORKSPACE_READ_ONLY:-0}" == "1" ]] && return 0
  [[ -n "$key" ]] || die "Empty env key"
  [[ "$key" =~ ^[A-Z0-9_]+$ ]] || die "Invalid env key: ${key}"
  workspace_require_env_value "$key" "$value"
  mkdir -p "$WORKSPACE_CONFIG_DIR"
  touch "$WORKSPACE_ENV_FILE"
  chmod 600 "$WORKSPACE_ENV_FILE"
  count=$(grep -c "^${key}=" "$WORKSPACE_ENV_FILE" 2>/dev/null || true)
  current=$(workspace_read_env "$key" 2>/dev/null || true)
  if [[ "$count" == "1" && "$current" == "$value" ]]; then
    return 0
  fi
  tmp="${WORKSPACE_ENV_FILE}.tmp"
  grep -v "^${key}=" "$WORKSPACE_ENV_FILE" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$WORKSPACE_ENV_FILE"
}

workspace_set_env_file_key() {
  local file="$1" key="$2" value="$3" tmp
  [[ "${SPARK_WORKSPACE_READ_ONLY:-0}" == "1" ]] && return 0
  [[ -f "$file" ]] || return 0
  [[ -n "$key" ]] || die "Empty env key"
  [[ "$key" =~ ^[A-Z0-9_]+$ ]] || die "Invalid env key: ${key}"
  workspace_require_env_value "$key" "$value"
  tmp="${file}.tmp"
  grep -v "^${key}=" "$file" > "$tmp" || true
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$file"
}

workspace_clear_public_urls() {
  workspace_set_env_key WORKSPACE_TAILSCALE_MODE manual
  workspace_set_env_key VIKUNJA_URL ""
  workspace_set_env_key N8N_URL ""
  workspace_set_env_key HERMES_URL ""
  workspace_set_env_key WORKSPACE_TAILSCALE_BIND_ADDR 127.0.0.1
  workspace_set_env_file_key "$WORKSPACE_VIKUNJA_ENV_FILE" VIKUNJA_SERVICE_PUBLICURL ""
  workspace_set_env_file_key "$WORKSPACE_N8N_ENV_FILE" N8N_HOST ""
  workspace_set_env_file_key "$WORKSPACE_N8N_ENV_FILE" N8N_PROTOCOL http
  workspace_set_env_file_key "$WORKSPACE_N8N_ENV_FILE" N8N_SECURE_COOKIE false
  workspace_set_env_file_key "$WORKSPACE_N8N_ENV_FILE" N8N_EDITOR_BASE_URL ""
  workspace_set_env_file_key "$WORKSPACE_N8N_ENV_FILE" WEBHOOK_URL ""
}

workspace_store_vikunja_token() {
  local token="$1"
  [[ -n "$token" ]] || die "Empty token"
  workspace_set_env_key VIKUNJA_HERMES_API_TOKEN "$token"
}

workspace_vikunja_api_base_url() {
  local mode url
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  if [[ "$mode" == "ports" ]]; then
    url=$(workspace_read_env VIKUNJA_URL 2>/dev/null || true)
    [[ -n "$url" ]] || return 1
    printf '%s\n' "${url%/}"
  else
    printf 'http://127.0.0.1:%s\n' "$WORKSPACE_VIKUNJA_PORT"
  fi
}

workspace_json_string_field() {
  local field="$1"
  sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

workspace_vikunja_login_jwt() {
  local username="$1" password="$2" payload out token base_url
  [[ -n "$username" && -n "$password" ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  base_url=$(workspace_vikunja_api_base_url) || return 1
  payload=$(printf '{"username":"%s","password":"%s","long_token":true}' \
    "$(workspace_json_escape "$username")" "$(workspace_json_escape "$password")")
  out=$(curl -fsS --max-time 10 \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -X POST "${base_url}/api/v1/login" \
    --data "$payload" 2>/dev/null) || return 1
  token=$(printf '%s\n' "$out" | workspace_json_string_field token)
  [[ -n "$token" ]] || return 1
  printf '%s\n' "$token"
}

workspace_vikunja_api_permissions_json() {
  local jwt="$1" routes perms base_url
  base_url=$(workspace_vikunja_api_base_url 2>/dev/null || true)
  if command -v jq >/dev/null 2>&1; then
    routes=$(curl -fsS --max-time 10 \
      -H "Authorization: Bearer ${jwt}" \
      -H 'Accept: application/json' \
      "${base_url:-http://127.0.0.1:${WORKSPACE_VIKUNJA_PORT}}/api/v1/routes" 2>/dev/null || true)
    if [[ -n "$routes" ]]; then
      perms=$(printf '%s\n' "$routes" | jq -c '
        with_entries(.value =
          if (.value | type) == "object" then (.value | keys)
          elif (.value | type) == "array" then
            [.value[] | if type == "string" then . elif type == "object" and has("name") then .name elif type == "object" and has("action") then .action else empty end]
          else [] end
        )
      ' 2>/dev/null || true)
      if [[ -n "$perms" && "$perms" != "{}" ]]; then
        printf '%s\n' "$perms"
        return 0
      fi
    fi
  fi
  printf '%s\n' '{"tasks":["read_all","create","update","delete"],"projects":["read_all","create","update","delete"],"comments":["read_all","create","update","delete"],"labels":["read_all","create","update","delete"],"webhooks":["read_all","create","update","delete"]}'
}

workspace_create_vikunja_hermes_token() {
  local existing hermes_pass jwt perms payload out token base_url
  existing=$(workspace_read_env VIKUNJA_HERMES_API_TOKEN 2>/dev/null || true)
  if [[ -n "$existing" ]] && workspace_check_vikunja_token "$existing" >/dev/null 2>&1; then
    info "Vikunja API token already works for hermes"
    return 0
  fi
  hermes_pass=$(workspace_read_env VIKUNJA_HERMES_PASSWORD 2>/dev/null || true)
  jwt=$(workspace_vikunja_login_jwt hermes "$hermes_pass") || {
    workspace_set_env_key VIKUNJA_HERMES_API_STATUS manual
    return 1
  }
  perms=$(workspace_vikunja_api_permissions_json "$jwt")
  base_url=$(workspace_vikunja_api_base_url) || return 1
  payload=$(printf '{"title":"spark-hermes","expires_at":"2099-12-31T23:59:59Z","permissions":%s}' "$perms")
  out=$(curl -fsS --max-time 10 \
    -H "Authorization: Bearer ${jwt}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -X PUT "${base_url}/api/v1/tokens" \
    --data "$payload" 2>/dev/null) || {
      workspace_set_env_key VIKUNJA_HERMES_API_STATUS manual
      return 1
    }
  token=$(printf '%s\n' "$out" | workspace_json_string_field token)
  if [[ -z "$token" ]]; then
    workspace_set_env_key VIKUNJA_HERMES_API_STATUS manual
    return 1
  fi
  workspace_store_vikunja_token "$token"
  workspace_check_vikunja_token "$token" >/dev/null 2>&1 || return 1
  info "Vikunja API token created for hermes"
}

workspace_check_vikunja_token() {
  local token="${1:-}" out base_url
  [[ -n "$token" ]] || token=$(workspace_read_env VIKUNJA_HERMES_API_TOKEN 2>/dev/null || true)
  [[ -n "$token" ]] || die "No Vikunja Hermes API token stored" "Create it in Vikunja UI, then rerun: spark ws setup --vikunja-token TOKEN"
  command -v curl >/dev/null 2>&1 || die "curl missing"
  base_url=$(workspace_vikunja_api_base_url) || return 1
  out=$(curl -fsS --max-time 5 \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/json' \
    "${base_url}/api/v1/user" 2>/dev/null) || {
      workspace_set_env_key VIKUNJA_HERMES_API_STATUS failed
      return 1
    }
  if printf '%s\n' "$out" | grep -Eq '"username"[[:space:]]*:[[:space:]]*"hermes"'; then
    workspace_set_env_key VIKUNJA_HERMES_API_STATUS verified
    info "Vikunja API token verified for hermes"
    return 0
  fi
  workspace_set_env_key VIKUNJA_HERMES_API_STATUS wrong-user
  warn "Vikunja API token works, but does not appear to belong to user 'hermes'"
  return 1
}

workspace_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

workspace_n8n_base_url() {
  local mode url
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  if [[ "$mode" == "ports" ]]; then
    url=$(workspace_read_env N8N_URL 2>/dev/null || true)
    [[ -n "$url" ]] || return 1
    printf '%s\n' "${url%/}"
  else
    printf 'http://127.0.0.1:%s\n' "$WORKSPACE_N8N_PORT"
  fi
}

workspace_n8n_post_json() {
  local path="$1" payload="$2" email pass base_url
  local auth_args=()
  base_url=$(workspace_n8n_base_url) || return 1
  email=$(workspace_read_env N8N_BASIC_AUTH_USER 2>/dev/null || true)
  pass=$(workspace_read_env N8N_BASIC_AUTH_PASSWORD 2>/dev/null || true)
  [[ -n "$email" ]] && auth_args=(-u "${email}:${pass}")
  curl -fsS --max-time 10 \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    "${auth_args[@]}" \
    -X POST "${base_url}${path}" \
    --data "$payload" >/dev/null
}

workspace_n8n_login() {
  local email pass payload
  email=$(workspace_read_env N8N_BASIC_AUTH_USER 2>/dev/null || true)
  pass=$(workspace_read_env N8N_BASIC_AUTH_PASSWORD 2>/dev/null || true)
  [[ -n "$email" && -n "$pass" ]] || return 1
  payload=$(printf '{"email":"%s","password":"%s"}' "$(workspace_json_escape "$email")" "$(workspace_json_escape "$pass")")
  workspace_n8n_post_json /rest/login "$payload"
}

workspace_create_n8n_owner() {
  local email pass first last payload i
  command -v curl >/dev/null 2>&1 || { workspace_set_env_key N8N_OWNER_SETUP_STATUS manual; warn "curl missing; create n8n owner manually"; return 1; }
  email=$(workspace_read_env N8N_BASIC_AUTH_USER 2>/dev/null || true)
  pass=$(workspace_read_env N8N_BASIC_AUTH_PASSWORD 2>/dev/null || true)
  first=$(workspace_read_env N8N_OWNER_FIRST_NAME 2>/dev/null || true)
  last=$(workspace_read_env N8N_OWNER_LAST_NAME 2>/dev/null || true)
  [[ -n "$email" && -n "$pass" ]] || { workspace_set_env_key N8N_OWNER_SETUP_STATUS manual; warn "n8n owner credentials missing"; return 1; }
  [[ -n "$first" ]] || first="Spark"
  [[ -n "$last" ]] || last="Admin"

  for i in {1..30}; do
    curl -fsS --max-time 2 "$(workspace_n8n_base_url)/healthz" >/dev/null 2>&1 && break
    sleep 1
  done
  if workspace_n8n_login; then
    workspace_set_env_key N8N_OWNER_SETUP_STATUS exists
    info "n8n owner already works: ${email}"
    return 0
  fi

  payload=$(printf '{"email":"%s","firstName":"%s","lastName":"%s","password":"%s"}' \
    "$(workspace_json_escape "$email")" "$(workspace_json_escape "$first")" \
    "$(workspace_json_escape "$last")" "$(workspace_json_escape "$pass")")
  if workspace_n8n_post_json /rest/owner/setup "$payload"; then
    if workspace_n8n_login; then
      workspace_set_env_key N8N_OWNER_SETUP_STATUS created
      info "n8n owner bootstrapped: ${email}"
      return 0
    fi
    warn "n8n owner setup endpoint returned success, but login is not verified yet"
  fi
  if workspace_n8n_login; then
    workspace_set_env_key N8N_OWNER_SETUP_STATUS exists
    info "n8n owner login verified: ${email}"
    return 0
  fi
  workspace_set_env_key N8N_OWNER_SETUP_STATUS manual
  warn "Could not bootstrap n8n owner automatically; finish first-run setup in the n8n UI"
  return 1
}

workspace_reset_n8n_user_management() {
  workspace_compose_service_running n8n || return 1
  workspace_compose exec -T n8n n8n user-management:reset >/dev/null 2>&1
}

workspace_configure_tailscale() {
  local tailnet="$1" check_only="$2" funnel_action="${3:-}" auto_yes="${4:-0}" requested_mode bind_addr dns_name
  requested_mode="${SPARK_WORKSPACE_TAILSCALE_MODE:-$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)}"
  if [[ -z "$tailnet" ]]; then
    [[ "$check_only" == "1" ]] || workspace_clear_public_urls
    setup_fail "Tailscale tailnet DNS suffix not detected; workspace requires Tailscale Services or ports mode"
    return 0
  fi
  if ! command -v tailscale >/dev/null 2>&1 || ! tailscale status >/dev/null 2>&1; then
    [[ "$check_only" == "1" ]] || workspace_clear_public_urls
    setup_fail "Tailscale not connected"
    return 0
  fi
  if ! tailscale_funnel_resolve_or_fail workspace "$funnel_action" "$auto_yes" "$check_only"; then
    [[ "$check_only" == "1" ]] || workspace_clear_public_urls
    return 0
  fi
  if [[ "$requested_mode" == "ports" ]]; then
    bind_addr=$(workspace_tailscale_ipv4 2>/dev/null || true)
    dns_name=$(workspace_tailscale_dns_name 2>/dev/null || true)
    if [[ -n "$bind_addr" && -n "$dns_name" ]]; then
      [[ "$check_only" == "1" ]] || {
        workspace_set_env_key WORKSPACE_TAILSCALE_MODE ports
        workspace_set_env_key WORKSPACE_TAILSCALE_BIND_ADDR "$bind_addr"
        workspace_set_env_key WORKSPACE_TAILSCALE_DNS_NAME "$dns_name"
      }
      info "Tailscale MagicDNS port fallback configured"
    else
      [[ "$check_only" == "1" ]] || workspace_clear_public_urls
      setup_fail "Tailscale MagicDNS/IPv4 not detected for ports fallback"
    fi
    return 0
  fi
  if ! workspace_tailscale_version_ok; then
    if [[ "$check_only" == "1" ]]; then
      setup_fail "Tailscale Services require Tailscale 1.86+; setup will attempt to update Tailscale"
      return 0
    fi
    if ! workspace_update_tailscale; then
      workspace_clear_public_urls
      setup_fail "Could not update Tailscale to 1.86+ for Services"
      return 0
    fi
  fi
  [[ "$check_only" == "1" ]] && return 0
  local ok=1
  tailscale serve --service="svc:vikunja" --https=443 --yes "http://127.0.0.1:${WORKSPACE_VIKUNJA_PORT}" >/dev/null 2>&1 || ok=0
  tailscale serve --service="svc:n8n" --https=443 --yes "http://127.0.0.1:${WORKSPACE_N8N_PORT}" >/dev/null 2>&1 || ok=0
  tailscale serve --service="svc:hermes" --https=443 --yes "http://127.0.0.1:${WORKSPACE_HERMES_PORT}" >/dev/null 2>&1 || ok=0
  if [[ "$ok" == "1" ]]; then
    workspace_set_env_key WORKSPACE_TAILSCALE_MODE services
    info "Tailscale Services configured"
  else
    workspace_clear_public_urls
    warn "Could not configure Tailscale Services automatically"
    printf "    Configure manually:\n"
    printf "    tailscale serve --service=svc:vikunja --https=443 --yes http://127.0.0.1:%s\n" "$WORKSPACE_VIKUNJA_PORT"
    printf "    tailscale serve --service=svc:n8n --https=443 --yes http://127.0.0.1:%s\n" "$WORKSPACE_N8N_PORT"
    printf "    tailscale serve --service=svc:hermes --https=443 --yes http://127.0.0.1:%s\n" "$WORKSPACE_HERMES_PORT"
    printf "    The host may need tag-based identity and admin approval in Tailscale Services.\n"
  fi
}

workspace_hermes_config_ready() {
  local litellm_model="$1" configured_model="" onboard_status=""
  configured_model=$(workspace_read_env HERMES_LITELLM_MODEL 2>/dev/null || true)
  onboard_status=$(workspace_read_env HERMES_ONBOARD_STATUS 2>/dev/null || true)
  [[ "$configured_model" == "$litellm_model" ]] || return 1
  [[ "$onboard_status" == "configured" || "$onboard_status" == "manual" ]] || return 1
  workspace_hermes_running || return 1
  workspace_start_hermes_private_proxy || return 1
  workspace_hermes_nemoclaw_configured || return 1
  workspace_hermes_doctor_ready || return 1
  workspace_hermes_inference_route_ready || return 1
  workspace_hermes_dashboard_url_ready || return 1
}

workspace_setup_hermes() {
  local model="$1" tailnet="$2" check_only="$3" hermes_url litellm_model
  hermes_url=$(workspace_read_env HERMES_URL 2>/dev/null || true)
  [[ -n "$hermes_url" ]] || hermes_url=$(workspace_url_for hermes "$tailnet" "$WORKSPACE_HERMES_PORT")
  if [[ -z "$hermes_url" && "$check_only" != "1" ]]; then
    setup_fail "Hermes URL is not configured; fix Tailscale workspace access first"
    return 0
  fi
  litellm_model=$(workspace_litellm_model_name "$model")
  if command -v nemohermes >/dev/null 2>&1; then
    info "NemoHermes: installed"
    [[ "$check_only" == "1" ]] && return 0
    if workspace_hermes_config_ready "$litellm_model"; then
      workspace_set_env_key HERMES_ONBOARD_STATUS configured
      info "Hermes already configured with ${litellm_model}"
      return 0
    fi
    NEMOCLAW_AGENT=hermes \
      NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
      NEMOCLAW_NON_INTERACTIVE=1 \
      NEMOCLAW_YES=1 \
      NEMOCLAW_SANDBOX_NAME=hermes \
      NEMOCLAW_LOCAL_INFERENCE_TIMEOUT=300 \
      NEMOCLAW_SANDBOX_READY_TIMEOUT=600 \
      NEMOCLAW_NO_GPU=1 \
      NEMOCLAW_SANDBOX_GPU=0 \
      NEMOCLAW_PROVIDER=custom \
      NEMOCLAW_ENDPOINT_URL="http://127.0.0.1:${GATEWAY_PORT}/v1" \
      NEMOCLAW_MODEL="$litellm_model" \
      NEMOCLAW_PREFERRED_API=openai-completions \
      NEMOCLAW_DASHBOARD_PORT="$WORKSPACE_HERMES_PORT" \
      NEMOCLAW_POLICY_TIER=restricted \
      NEMOCLAW_POLICY_MODE=suggested \
      COMPATIBLE_API_KEY=dummy \
      CHAT_UI_URL="$hermes_url" \
      nemohermes onboard --non-interactive --yes-i-accept-third-party-software \
        --yes \
        --no-gpu \
        --control-ui-port "$WORKSPACE_HERMES_PORT" >/dev/null 2>&1 \
      && workspace_start_hermes_private_proxy \
      && { workspace_set_env_key HERMES_ONBOARD_STATUS configured; info "Hermes onboarded with ${litellm_model}"; } \
      || { workspace_set_env_key HERMES_ONBOARD_STATUS manual; setup_fail "Hermes onboarding failed; run nemohermes onboard manually"; }
  elif [[ "$check_only" == "1" ]]; then
    setup_fail "NemoHermes not installed"
  else
    warn "Installing NemoClaw/Hermes"
    NEMOCLAW_AGENT=hermes \
      NEMOCLAW_NON_INTERACTIVE=1 \
      NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
      NEMOCLAW_YES=1 \
      NEMOCLAW_SANDBOX_NAME=hermes \
      NEMOCLAW_LOCAL_INFERENCE_TIMEOUT=300 \
      NEMOCLAW_SANDBOX_READY_TIMEOUT=600 \
      NEMOCLAW_NO_GPU=1 \
      NEMOCLAW_SANDBOX_GPU=0 \
      NEMOCLAW_PROVIDER=custom \
      NEMOCLAW_ENDPOINT_URL="http://127.0.0.1:${GATEWAY_PORT}/v1" \
      NEMOCLAW_MODEL="$litellm_model" \
      NEMOCLAW_PREFERRED_API=openai-completions \
      NEMOCLAW_DASHBOARD_PORT="$WORKSPACE_HERMES_PORT" \
      NEMOCLAW_POLICY_TIER=restricted \
      NEMOCLAW_POLICY_MODE=suggested \
      COMPATIBLE_API_KEY=dummy \
      CHAT_UI_URL="$hermes_url" \
      bash -c 'curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash' \
      && workspace_start_hermes_private_proxy \
      && { workspace_set_env_key HERMES_ONBOARD_STATUS configured; info "Installed Hermes with NemoClaw"; } \
      || { workspace_set_env_key HERMES_ONBOARD_STATUS manual; setup_fail "Hermes/NemoClaw install failed"; }
  fi
}

workspace_prompt() {
  local var="$1" prompt="$2" default="${3:-}" secret="${4:-0}" kind="${5:-text}" value
  value="${!var:-}"
  if [[ -n "$value" ]]; then
    if ! workspace_required_prompt_value_valid "$kind" "$value"; then
      warn "Ignoring invalid ${prompt}; setup will ask again"
      value=""
    else
      printf '%s\n' "$value"
      return 0
    fi
  fi
  is_interactive || die "$prompt is required"
  while true; do
    if [[ -n "$default" ]]; then
      printf "  %s [%s]: " "$prompt" "$default" >&2
    else
      printf "  %s: " "$prompt" >&2
    fi
    if [[ "$secret" == "1" ]]; then
      read -rs value || die "$prompt is required"
      printf "\n" >&2
    else
      read -r value || die "$prompt is required"
    fi
    [[ -z "$value" ]] && value="$default"
    if workspace_required_prompt_value_valid "$kind" "$value"; then
      printf '%s\n' "$value"
      return 0
    fi
    warn "${prompt} is invalid; $(workspace_env_value_hint)"
  done
}

workspace_prompt_username_choice() {
  local var="$1" prompt="$2" default="${3:-}" value choice
  value="${!var:-}"
  if [[ -n "$value" ]]; then
    workspace_prompt "$var" "$prompt" "$default" 0 username
    return 0
  fi
  is_interactive || die "$prompt is required"
  while true; do
    printf "  %s [%s] (y to accept): " "$prompt" "$default" >&2
    read -r choice || die "$prompt is required"
    case "$choice" in
      ""|y|Y|yes|YES|Yes) value="$default" ;;
      *) value="$choice" ;;
    esac
    if workspace_required_prompt_value_valid username "$value"; then
      printf '%s\n' "$value"
      return 0
    fi
    warn "${prompt} is invalid; use letters, numbers, dot, dash, or underscore"
  done
}

workspace_prompt_secret_confirm() {
  local var="$1" prompt="$2" value confirm
  value="${!var:-}"
  if [[ -n "$value" ]]; then
    if workspace_required_prompt_value_valid text "$value"; then
      printf '%s\n' "$value"
      return 0
    fi
    warn "Ignoring invalid ${prompt}; setup will ask again"
    value=""
  fi
  is_interactive || die "$prompt is required"
  while true; do
    printf "  %s: " "$prompt" >&2
    read -rs value || die "$prompt is required"
    printf "\n" >&2
    printf "  Confirm %s: " "$prompt" >&2
    read -rs confirm || die "$prompt is required"
    printf "\n" >&2
    if [[ "$value" != "$confirm" ]]; then
      warn "${prompt} did not match; try again"
      continue
    fi
    if workspace_required_prompt_value_valid text "$value"; then
      printf '%s\n' "$value"
      return 0
    fi
    warn "${prompt} is invalid; $(workspace_env_value_hint)"
  done
}

workspace_reconcile_identity_overrides() {
  if [[ -n "${SPARK_WORKSPACE_VIKUNJA_EMAIL:-}" && -n "${SPARK_WORKSPACE_N8N_EMAIL:-}" \
    && "$SPARK_WORKSPACE_VIKUNJA_EMAIL" != "$SPARK_WORKSPACE_N8N_EMAIL" ]]; then
    warn "Using Workspace email for both Vikunja and n8n"
    SPARK_WORKSPACE_N8N_EMAIL="$SPARK_WORKSPACE_VIKUNJA_EMAIL"
  fi
  [[ -z "${SPARK_WORKSPACE_VIKUNJA_EMAIL:-}" && -n "${SPARK_WORKSPACE_N8N_EMAIL:-}" ]] \
    && SPARK_WORKSPACE_VIKUNJA_EMAIL="$SPARK_WORKSPACE_N8N_EMAIL"
  [[ -z "${SPARK_WORKSPACE_N8N_EMAIL:-}" && -n "${SPARK_WORKSPACE_VIKUNJA_EMAIL:-}" ]] \
    && SPARK_WORKSPACE_N8N_EMAIL="$SPARK_WORKSPACE_VIKUNJA_EMAIL"
  return 0
}

workspace_remote_workspace_cmd() {
  local spec="$1" cmd q arg rc
  local script key value send_workspace_env=0
  shift
  [[ "$spec" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ ]] || die "Invalid remote target: $spec" "Use user@host"
  REMOTE_USER="${spec%@*}"
  REMOTE_HOST="${spec#*@}"
  open_remote "$REMOTE_USER" "$REMOTE_HOST" || die "Could not connect to ${spec}" "Run spark setup first if SSH keys are not installed"
  deploy_spark_binary
  script=""
  if [[ "${1:-}" == "setup" ]]; then
    send_workspace_env=1
    for arg in "$@"; do
      [[ "$arg" == "--check" ]] && send_workspace_env=0
    done
  fi
  if [[ "$send_workspace_env" == "1" ]]; then
    for key in \
      SPARK_WORKSPACE_VIKUNJA_USERNAME SPARK_WORKSPACE_VIKUNJA_EMAIL SPARK_WORKSPACE_VIKUNJA_TOKEN \
      SPARK_WORKSPACE_N8N_EMAIL; do
      value="${!key:-}"
      if [[ -n "$value" ]]; then
        printf -v q '%q' "$value"
        script+="export ${key}=${q}"$'\n'
      fi
    done
  fi
  cmd="${TGT_PATH} spark ws"
  for arg in "$@"; do
    printf -v q '%q' "$arg"
    cmd+=" ${q}"
  done
  script+="$cmd"
  set +e
  printf '%s\n' "$script" | remote_in "bash -s"
  rc=$?
  set -e
  close_remote
  return "$rc"
}

workspace_setup_remote() {
  local spec="$1" check_only="$2" auto_yes="$3" requested_model="$4" requested_tail_mode="${5:-}"
  local postgres_image="${6:-}" vikunja_image="${7:-}" n8n_image="${8:-}" funnel_action="${9:-}" args=()
  args=(setup)
  [[ "$check_only" == "1" ]] && args+=(--check)
  [[ "$auto_yes" == "1" ]] && args+=(--yes)
  [[ -n "$requested_model" ]] && args+=(--model "$requested_model")
  [[ -n "$requested_tail_mode" ]] && args+=(--tailscale-mode "$requested_tail_mode")
  [[ -n "$postgres_image" ]] && args+=(--postgres-image "$postgres_image")
  [[ -n "$vikunja_image" ]] && args+=(--vikunja-image "$vikunja_image")
  [[ -n "$n8n_image" ]] && args+=(--n8n-image "$n8n_image")
  [[ -n "$funnel_action" ]] && args+=(--funnel-action "$funnel_action")
  workspace_remote_workspace_cmd "$spec" "${args[@]}"
}

workspace_setup() {
  local auto_yes=0 check_only=0 requested_model="" remote_spec="" requested_tail_mode=""
  local postgres_image="" vikunja_image="" n8n_image="" model tailnet
  local vikunja_username="" vikunja_email="" vikunja_password="" vikunja_token="" n8n_email_arg="" n8n_password_arg="" funnel_action=""
  local existing_model="" setup_overrides=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) auto_yes=1; shift ;;
      --check) check_only=1; shift ;;
      --model) requested_model="${2:-}"; [[ -n "$requested_model" ]] || die "--model requires a value"; shift 2 ;;
      --remote) remote_spec="${2:-}"; [[ -n "$remote_spec" ]] || die "--remote requires user@host"; shift 2 ;;
      --tailscale-mode)
        requested_tail_mode="${2:-}"
        [[ -n "$requested_tail_mode" ]] || die "--tailscale-mode requires services or ports"
        case "$requested_tail_mode" in
          services|ports) ;;
          *) die "--tailscale-mode must be 'services' or 'ports'" ;;
        esac
        shift 2
        ;;
      --postgres-image) postgres_image="${2:-}"; [[ -n "$postgres_image" ]] || die "--postgres-image requires a value"; shift 2 ;;
      --vikunja-image) vikunja_image="${2:-}"; [[ -n "$vikunja_image" ]] || die "--vikunja-image requires a value"; shift 2 ;;
      --n8n-image) n8n_image="${2:-}"; [[ -n "$n8n_image" ]] || die "--n8n-image requires a value"; shift 2 ;;
      --vikunja-username) vikunja_username="${2:-}"; [[ -n "$vikunja_username" ]] || die "--vikunja-username requires a value"; shift 2 ;;
      --vikunja-email) vikunja_email="${2:-}"; [[ -n "$vikunja_email" ]] || die "--vikunja-email requires a value"; shift 2 ;;
      --vikunja-password) vikunja_password="${2:-}"; [[ -n "$vikunja_password" ]] || die "--vikunja-password requires a value"; shift 2 ;;
      --vikunja-token) vikunja_token="${2:-}"; [[ -n "$vikunja_token" ]] || die "--vikunja-token requires a value"; shift 2 ;;
      --n8n-email) n8n_email_arg="${2:-}"; [[ -n "$n8n_email_arg" ]] || die "--n8n-email requires a value"; shift 2 ;;
      --n8n-password) n8n_password_arg="${2:-}"; [[ -n "$n8n_password_arg" ]] || die "--n8n-password requires a value"; shift 2 ;;
      --funnel-action)
        funnel_action="${2:-}"
        tailscale_funnel_action_valid "$funnel_action" || die "--funnel-action must be reset or abort"
        shift 2
        ;;
      -h|--help) cmd_workspace_setup_help; return 0 ;;
      *) die "Unknown ws setup flag: $1" ;;
    esac
  done
  [[ -n "$vikunja_username" ]] && SPARK_WORKSPACE_VIKUNJA_USERNAME="$vikunja_username"
  [[ -n "$vikunja_email" ]] && SPARK_WORKSPACE_VIKUNJA_EMAIL="$vikunja_email"
  [[ -n "$vikunja_password" ]] && warn "--vikunja-password is ignored; spark generates a recovery secret"
  [[ -n "$vikunja_token" ]] && SPARK_WORKSPACE_VIKUNJA_TOKEN="$vikunja_token"
  [[ -n "$n8n_email_arg" ]] && SPARK_WORKSPACE_N8N_EMAIL="$n8n_email_arg"
  [[ -n "$n8n_password_arg" ]] && warn "--n8n-password is ignored; spark generates a recovery secret"
  if [[ -n "${SPARK_WORKSPACE_VIKUNJA_PASSWORD:-}" ]]; then
    warn "SPARK_WORKSPACE_VIKUNJA_PASSWORD is ignored; spark generates a recovery secret"
    unset SPARK_WORKSPACE_VIKUNJA_PASSWORD
  fi
  if [[ -n "${SPARK_WORKSPACE_N8N_PASSWORD:-}" ]]; then
    warn "SPARK_WORKSPACE_N8N_PASSWORD is ignored; spark generates a recovery secret"
    unset SPARK_WORKSPACE_N8N_PASSWORD
  fi
  workspace_reconcile_identity_overrides
  [[ -n "${SPARK_WORKSPACE_VIKUNJA_TOKEN:-}" ]] && workspace_require_env_value "Vikunja Hermes API token" "$SPARK_WORKSPACE_VIKUNJA_TOKEN"
  [[ -n "$postgres_image" ]] && workspace_validate_image_ref "Postgres image" "$postgres_image"
  [[ -n "$vikunja_image" ]] && workspace_validate_image_ref "Vikunja image" "$vikunja_image"
  [[ -n "$n8n_image" ]] && workspace_validate_image_ref "n8n image" "$n8n_image"
  [[ -z "$remote_spec" ]] || {
    if [[ "$check_only" != "1" ]]; then
      [[ -n "$requested_model" ]] || die "--model is required with --remote ws setup"
      SPARK_WORKSPACE_VIKUNJA_USERNAME=$(workspace_prompt_username_choice SPARK_WORKSPACE_VIKUNJA_USERNAME "Workspace username" "$(whoami)")
      SPARK_WORKSPACE_VIKUNJA_EMAIL=$(workspace_prompt SPARK_WORKSPACE_VIKUNJA_EMAIL "Workspace email" "" 0 email)
      SPARK_WORKSPACE_N8N_EMAIL="$SPARK_WORKSPACE_VIKUNJA_EMAIL"
      workspace_require_prompt_value "Vikunja human username" "$SPARK_WORKSPACE_VIKUNJA_USERNAME" username
      workspace_require_prompt_value "Vikunja human email" "$SPARK_WORKSPACE_VIKUNJA_EMAIL" email
      workspace_require_prompt_value "n8n admin email" "$SPARK_WORKSPACE_N8N_EMAIL" email
      export SPARK_WORKSPACE_VIKUNJA_USERNAME SPARK_WORKSPACE_VIKUNJA_EMAIL
      [[ -n "${SPARK_WORKSPACE_VIKUNJA_TOKEN:-}" ]] && export SPARK_WORKSPACE_VIKUNJA_TOKEN
      export SPARK_WORKSPACE_N8N_EMAIL
    fi
    workspace_setup_remote "$remote_spec" "$check_only" "$auto_yes" "$requested_model" \
      "$requested_tail_mode" "$postgres_image" "$vikunja_image" "$n8n_image" "$funnel_action"
    return $?
  }
  [[ -n "$requested_tail_mode" ]] && SPARK_WORKSPACE_TAILSCALE_MODE="$requested_tail_mode"
  [[ -n "$postgres_image" ]] && SPARK_WORKSPACE_POSTGRES_IMAGE="$postgres_image"
  [[ -n "$vikunja_image" ]] && SPARK_WORKSPACE_VIKUNJA_IMAGE="$vikunja_image"
  [[ -n "$n8n_image" ]] && SPARK_WORKSPACE_N8N_IMAGE="$n8n_image"
  SETUP_FAILED=()
  SETUP_SKIPPED=()
  printf "\n  ${BOLD}spark ws setup${NC} — Vikunja + n8n + Hermes\n\n"
  workspace_preflight "$check_only" || true
  existing_model=$(workspace_read_env HERMES_MODEL 2>/dev/null || true)
  if [[ -n "$requested_model" || -n "$requested_tail_mode" || -n "$postgres_image" || -n "$vikunja_image" || -n "$n8n_image" || -n "$funnel_action" || -n "$vikunja_username" || -n "$vikunja_email" || -n "$vikunja_password" || -n "$vikunja_token" || -n "$n8n_email_arg" || -n "$n8n_password_arg" ]]; then
    setup_overrides=1
  fi
  if [[ -n "${SPARK_WORKSPACE_POSTGRES_IMAGE:-}" || -n "${SPARK_WORKSPACE_VIKUNJA_IMAGE:-}" || -n "${SPARK_WORKSPACE_N8N_IMAGE:-}" || -n "${SPARK_WORKSPACE_TAILSCALE_MODE:-}" ]]; then
    setup_overrides=1
  fi
  if [[ "$check_only" != "1" && "$setup_overrides" == "0" && -n "$existing_model" ]] && workspace_configured; then
    if workspace_doctor_passes_quiet "$existing_model"; then
      info "Workspace already configured"
      return 0
    fi
    local failed_ids
    failed_ids=$(workspace_doctor_failed_ids_quiet "$existing_model")
    if [[ -n "$failed_ids" ]]; then
      info "Workspace drift detected; reconciling: ${failed_ids}"
    else
      info "Workspace drift detected; reconciling"
    fi
  fi
  if [[ -n "$requested_model" ]]; then
    model=$(workspace_select_model "$requested_model")
  elif [[ -n "$existing_model" ]]; then
    model="$existing_model"
    info "Hermes model: ${model} (configured)"
  elif [[ "$check_only" == "1" ]] && ! is_interactive; then
    collect_downloaded_models
    if [[ ${#MODEL_LIST_MODELS[@]} -eq 0 ]]; then
      setup_fail "No downloaded models found for Hermes"
      model=""
    else
      model="${MODEL_LIST_MODELS[0]}"
      info "Model candidate: ${model}"
    fi
  else
    model=$(workspace_select_model "$requested_model")
  fi
  tailnet=$(workspace_tailnet_suffix || true)
  if [[ "$check_only" != "1" ]]; then
    tailscale_funnel_resolve_or_fail workspace "$funnel_action" "$auto_yes" "$check_only" || {
      workspace_summary
      return $?
    }
  fi
  workspace_ensure_gateway "$check_only" "$auto_yes" "$model"
  [[ "$check_only" == "1" ]] && workspace_configure_tailscale "$tailnet" "$check_only" "$funnel_action" "$auto_yes"
  if [[ "$check_only" == "1" ]]; then
    if [[ -n "$model" ]]; then
      workspace_setup_hermes "$model" "$tailnet" "$check_only"
      SPARK_WORKSPACE_READ_ONLY=1 cmd_workspace_doctor --model "$model" || setup_fail "Workspace doctor reported issues"
    else
      setup_fail "Workspace doctor skipped because no Hermes model is selected"
    fi
    workspace_summary
    return $?
  fi
  local human_user human_email human_pass n8n_email n8n_pass hermes_pass
  local existing_human_user existing_human_email existing_human_pass existing_n8n_email existing_n8n_pass
  existing_human_user=$(workspace_existing_prompt_value VIKUNJA_HUMAN_USERNAME "Vikunja human username" username || true)
  existing_human_email=$(workspace_existing_prompt_value VIKUNJA_HUMAN_EMAIL "Vikunja human email" email || true)
  existing_human_pass=$(workspace_existing_prompt_value VIKUNJA_HUMAN_RECOVERY_PASSWORD "Vikunja human recovery password" text || true)
  existing_n8n_email=$(workspace_existing_prompt_value N8N_BASIC_AUTH_USER "n8n admin email" email || true)
  existing_n8n_pass=$(workspace_existing_prompt_value N8N_BASIC_AUTH_PASSWORD "n8n admin/basic-auth password" text || true)
  workspace_existing_prompt_value N8N_OWNER_FIRST_NAME "n8n owner first name" username >/dev/null || true
  [[ -z "${SPARK_WORKSPACE_VIKUNJA_USERNAME:-}" && -n "$existing_human_user" ]] && SPARK_WORKSPACE_VIKUNJA_USERNAME="$existing_human_user"
  [[ -z "${SPARK_WORKSPACE_VIKUNJA_EMAIL:-}" && -n "$existing_human_email" ]] && SPARK_WORKSPACE_VIKUNJA_EMAIL="$existing_human_email"
  [[ -z "${SPARK_WORKSPACE_VIKUNJA_EMAIL:-}" && -n "$existing_n8n_email" ]] && SPARK_WORKSPACE_VIKUNJA_EMAIL="$existing_n8n_email"
  [[ -z "${SPARK_WORKSPACE_N8N_EMAIL:-}" && -n "${SPARK_WORKSPACE_VIKUNJA_EMAIL:-}" ]] && SPARK_WORKSPACE_N8N_EMAIL="$SPARK_WORKSPACE_VIKUNJA_EMAIL"
  workspace_reconcile_identity_overrides
  human_user=$(workspace_prompt_username_choice SPARK_WORKSPACE_VIKUNJA_USERNAME "Workspace username" "${existing_human_user:-$(whoami)}")
  human_email=$(workspace_prompt SPARK_WORKSPACE_VIKUNJA_EMAIL "Workspace email" "$existing_human_email" 0 email)
  n8n_email="$human_email"
  SPARK_WORKSPACE_N8N_EMAIL="$n8n_email"
  human_pass="${existing_human_pass:-$(workspace_random_secret)}"
  n8n_pass="${existing_n8n_pass:-$(workspace_random_secret)}"
  workspace_require_prompt_value "Vikunja human username" "$human_user" username
  workspace_require_prompt_value "Vikunja human email" "$human_email" email
  workspace_require_prompt_value "n8n admin email" "$n8n_email" email
  hermes_pass=$(workspace_random_secret)
  workspace_write_files "$tailnet" "$human_user" "$human_email" "$human_pass" "$n8n_email" "$n8n_pass" "$hermes_pass" "$model" || {
    workspace_summary
    return $?
  }
  workspace_compose up -d --remove-orphans && info "Compose project ${WORKSPACE_PROJECT} started" || setup_fail "Could not start workspace compose"
  workspace_ensure_postgres_databases
  workspace_configure_tailscale "$tailnet" "$check_only" "$funnel_action" "$auto_yes"
  if workspace_tailscale_services_mode; then
    workspace_setup_hermes "$model" "$tailnet" "$check_only"
  else
    workspace_set_env_key HERMES_ONBOARD_STATUS manual
    setup_fail "Hermes onboarding skipped until Tailscale private access is configured"
  fi
  workspace_create_vikunja_users "$human_pass"
  workspace_create_n8n_owner || true
  workspace_summary
}

cmd_workspace_credentials_help() {
  cat <<EOF

  ${BOLD}Usage:${NC} spark ws credentials <show|rotate|reset> [target]

  Shows or rotates local recovery credentials generated by spark.
  These are technical recovery secrets stored on the server, not human passwords.

  ${BOLD}Commands:${NC}
    show              Show workspace URLs and recovery credentials
    rotate            Rotate all supported recovery credentials
    reset vikunja     Rotate Vikunja human recovery secret
    reset n8n         Rotate n8n recovery/basic-auth secret

EOF
}

workspace_credentials_require_config() {
  [[ -f "$WORKSPACE_ENV_FILE" ]] || die "Workspace is not configured" "Run 'spark ws setup' first"
}

workspace_credentials_read() {
  workspace_read_env "$1" 2>/dev/null || true
}

cmd_workspace_credentials_show() {
  workspace_credentials_require_config
  local vikunja_url n8n_url hermes_url human_user human_email human_pass n8n_user n8n_pass hermes_user hermes_pass token
  vikunja_url=$(workspace_credentials_read VIKUNJA_URL)
  n8n_url=$(workspace_credentials_read N8N_URL)
  hermes_url=$(workspace_credentials_read HERMES_URL)
  human_user=$(workspace_credentials_read VIKUNJA_HUMAN_USERNAME)
  human_email=$(workspace_credentials_read VIKUNJA_HUMAN_EMAIL)
  human_pass=$(workspace_credentials_read VIKUNJA_HUMAN_RECOVERY_PASSWORD)
  n8n_user=$(workspace_credentials_read N8N_BASIC_AUTH_USER)
  n8n_pass=$(workspace_credentials_read N8N_BASIC_AUTH_PASSWORD)
  hermes_user=$(workspace_credentials_read VIKUNJA_HERMES_USERNAME)
  hermes_pass=$(workspace_credentials_read VIKUNJA_HERMES_PASSWORD)
  token=$(workspace_credentials_read VIKUNJA_HERMES_API_TOKEN)
  cat <<EOF

  ${BOLD}spark ws credentials${NC}

  Vikunja
    URL:               ${vikunja_url:-n/a}
    username:          ${human_user:-n/a}
    email:             ${human_email:-n/a}
    recovery password: ${human_pass:-n/a}

  n8n
    URL:               ${n8n_url:-n/a}
    email:             ${n8n_user:-n/a}
    recovery password: ${n8n_pass:-n/a}

  Hermes/Vikunja
    API URL:           ${hermes_url:-n/a}
    username:          ${hermes_user:-hermes}
    password:          ${hermes_pass:-n/a}
    API token:         ${token:-n/a}

EOF
}

cmd_workspace_credentials_reset() {
  local target="${1:-}" secret
  workspace_credentials_require_config
  [[ -n "$target" ]] || die "credentials reset requires a target" "Use vikunja, n8n, or all"
  case "$target" in
    all)
      cmd_workspace_credentials_reset vikunja
      cmd_workspace_credentials_reset n8n
      return 0
      ;;
    vikunja)
      secret=$(workspace_random_secret)
      workspace_set_env_key VIKUNJA_HUMAN_RECOVERY_PASSWORD "$secret"
      workspace_set_env_key VIKUNJA_HUMAN_USER_STATUS manual
      info "Vikunja human recovery secret rotated locally"
      warn "If the Vikunja user already exists, update that user's password in Vikunja or recreate it, then rerun spark ws setup"
      ;;
    n8n)
      secret=$(workspace_random_secret)
      workspace_set_env_key N8N_BASIC_AUTH_PASSWORD "$secret"
      workspace_set_env_file_key "$WORKSPACE_N8N_ENV_FILE" N8N_BASIC_AUTH_PASSWORD "$secret"
      workspace_set_env_key N8N_OWNER_SETUP_STATUS manual
      info "n8n recovery/basic-auth secret rotated locally"
      workspace_compose up -d n8n >/dev/null 2>&1 || true
      if workspace_reset_n8n_user_management && workspace_create_n8n_owner; then
        info "n8n owner reset to generated recovery credential"
      else
        warn "Could not reset n8n owner automatically; finish first-run setup in n8n or rerun spark ws setup"
      fi
      ;;
    *)
      die "Unknown credentials target: $target" "Use vikunja, n8n, or all"
      ;;
  esac
}

cmd_workspace_credentials() {
  local subcmd="${1:-show}" target
  [[ -n "${1:-}" ]] && shift || true
  case "$subcmd" in
    show) cmd_workspace_credentials_show "$@" ;;
    rotate)
      [[ $# -eq 0 ]] || die "credentials rotate does not take extra arguments"
      cmd_workspace_credentials_reset all
      ;;
    reset)
      target="${1:-}"
      [[ $# -le 1 ]] || die "credentials reset accepts one target"
      cmd_workspace_credentials_reset "$target"
      ;;
    help|--help|-h) cmd_workspace_credentials_help ;;
    *) die "Unknown ws credentials command: $subcmd" "Run 'spark ws credentials help'" ;;
  esac
}

cmd_workspace_status() {
  local vikunja_url="" n8n_url="" hermes_url="" tailscale_mode=""
  printf "\n  ${BOLD}spark ws status${NC}\n\n"
  if [[ -f "$WORKSPACE_COMPOSE_FILE" ]]; then
    workspace_compose ps 2>/dev/null || warn "Compose project ${WORKSPACE_PROJECT} not reachable"
  else
    warn "Workspace not configured"
  fi
  if [[ -f "$WORKSPACE_ENV_FILE" ]]; then
    vikunja_url=$(workspace_read_env VIKUNJA_URL 2>/dev/null || true)
    n8n_url=$(workspace_read_env N8N_URL 2>/dev/null || true)
    hermes_url=$(workspace_read_env HERMES_URL 2>/dev/null || true)
    tailscale_mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
    printf "\n  URLs: Vikunja=%s n8n=%s Hermes=%s\n" "${vikunja_url:-unset}" "${n8n_url:-unset}" "${hermes_url:-unset}"
    printf "  Tailscale: %s\n" "${tailscale_mode:-unset}"
  fi
  cmd_workspace_health
  printf "\n"
  gateway_status
  if command -v nemohermes >/dev/null 2>&1; then
    nemohermes hermes status 2>/dev/null || nemohermes status 2>/dev/null || true
  else
    warn "NemoHermes not installed"
  fi
  if command -v tailscale >/dev/null 2>&1; then
    tailscale serve status 2>/dev/null || warn "No Tailscale Serve status"
  fi
  printf "\n"
}

workspace_status_item() {
  local label="$1"
  shift
  if "$@"; then
    printf "  [x] %s\n" "$label"
  else
    printf "  [ ] %s\n" "$label"
  fi
}

cmd_workspace_health() {
  local model
  model=$(workspace_read_env HERMES_MODEL 2>/dev/null || true)
  printf "\n  ${BOLD}Workspace health${NC}\n"
  workspace_status_item "Compose postgres" workspace_compose_service_running postgres
  workspace_status_item "Compose vikunja" workspace_compose_service_running vikunja
  workspace_status_item "Compose n8n" workspace_compose_service_running n8n
  workspace_status_item "Vikunja HTTP local" workspace_vikunja_http_ready
  workspace_status_item "n8n HTTP local" workspace_n8n_http_ready
  workspace_status_item "Tailscale URLs" workspace_tailscale_https_urls_ready
  workspace_status_item "No public listeners" workspace_host_listeners_loopback_only
  workspace_status_item "LiteLLM gateway" workspace_gateway_running
  workspace_status_item "LiteLLM Hermes route" workspace_litellm_model_routed
  workspace_status_item "Hermes model" workspace_model_running "$model"
  workspace_status_item "Hermes/NemoClaw" workspace_hermes_running
  workspace_status_item "NemoHermes inference route" workspace_hermes_inference_route_ready
}

cmd_workspace_logs() {
  local target="${1:-}"
  case "$target" in
    ""|-h|--help)
      printf "\n  Usage: spark ws logs [vikunja|n8n|postgres|hermes|gateway]\n\n" ;;
    vikunja|n8n|postgres)
      workspace_require_config
      workspace_compose logs -f "$target" ;;
    gateway)
      gateway_logs -f ;;
    hermes)
      nemohermes hermes logs 2>/dev/null || nemohermes logs 2>/dev/null || die "Could not read Hermes logs" ;;
    *)
      die "Unknown workspace log target: $target" ;;
  esac
}

workspace_sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    return 1
  fi
}

workspace_backup_payload_files() {
  printf '%s\n' \
    workspace-config.tgz \
    vikunja.zip \
    vikunja.sql \
    n8n.sql \
    hermes-snapshot.status \
    nemoclaw-backup.status
}

workspace_backup_write_checksums() {
  local dir="$1" file hash checksums
  checksums="${dir}/checksums.sha256"
  : > "$checksums"
  while IFS= read -r file; do
    [[ -s "${dir}/${file}" ]] || return 1
    hash=$(workspace_sha256_file "${dir}/${file}") || return 1
    printf '%s  %s\n' "$hash" "$file" >> "$checksums"
  done < <(workspace_backup_payload_files)
  chmod 600 "$checksums"
}

workspace_backup_verify_checksums() {
  local dir="$1" checksums expected file actual required failures=0
  checksums="${dir}/checksums.sha256"
  [[ -f "$checksums" ]] || { warn "checksums.sha256 missing"; return 1; }
  while IFS= read -r required; do
    awk -v file="$required" '
      $1 ~ /^[0-9a-fA-F]{64}$/ && $2 == file && NF == 2 { found=1 }
      END { exit !found }
    ' "$checksums" \
      || { warn "Checksum entry missing: ${required}"; failures=$((failures + 1)); }
  done < <(workspace_backup_payload_files)
  while read -r expected file; do
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ && "$file" =~ ^[A-Za-z0-9._-]+$ ]] \
      || { warn "Invalid checksum entry: ${file:-missing-file}"; failures=$((failures + 1)); continue; }
    workspace_backup_payload_files | grep -Fxq "$file" \
      || { warn "Unexpected checksum entry: ${file}"; failures=$((failures + 1)); continue; }
    [[ -f "${dir}/${file}" ]] \
      || { warn "Checksum target missing: ${file}"; failures=$((failures + 1)); continue; }
    actual=$(workspace_sha256_file "${dir}/${file}") \
      || { warn "Could not hash backup file: ${file}"; failures=$((failures + 1)); continue; }
    [[ "$actual" == "$expected" ]] \
      || { warn "Backup checksum mismatch: ${file}"; failures=$((failures + 1)); }
  done < "$checksums"
  [[ "$failures" -eq 0 ]]
}

workspace_backup_verify() {
  local dir="$1" manifest failures=0 key file
  [[ -n "$dir" ]] || die "backup --verify requires a backup directory"
  manifest="${dir}/manifest.env"
  [[ -d "$dir" ]] || { err "Backup directory missing: $dir"; return 1; }
  [[ -f "$manifest" ]] || { err "Backup manifest missing: $manifest"; return 1; }
  workspace_file_mode_is "$dir" 700 || { warn "Backup directory mode must be 0700"; failures=$((failures + 1)); }
  for key in WORKSPACE_CONFIG_STATUS VIKUNJA_DUMP_STATUS VIKUNJA_DB_STATUS N8N_DB_STATUS HERMES_SNAPSHOT_STATUS NEMOCLAW_BACKUP_ALL_STATUS CHECKSUMS_STATUS; do
    grep -q "^${key}=ok$" "$manifest" || { warn "Backup manifest not ok: ${key}"; failures=$((failures + 1)); }
  done
  [[ -s "${dir}/workspace-config.tgz" ]] && tar -tzf "${dir}/workspace-config.tgz" >/dev/null 2>&1 \
    || { warn "workspace-config.tgz missing or unreadable"; failures=$((failures + 1)); }
  [[ -s "${dir}/vikunja.zip" ]] || { warn "vikunja.zip missing or empty"; failures=$((failures + 1)); }
  [[ -s "${dir}/vikunja.sql" ]] || { warn "vikunja.sql missing or empty"; failures=$((failures + 1)); }
  [[ -s "${dir}/n8n.sql" ]] || { warn "n8n.sql missing or empty"; failures=$((failures + 1)); }
  [[ -s "${dir}/hermes-snapshot.status" ]] || { warn "hermes-snapshot.status missing or empty"; failures=$((failures + 1)); }
  [[ -s "${dir}/nemoclaw-backup.status" ]] || { warn "nemoclaw-backup.status missing or empty"; failures=$((failures + 1)); }
  [[ -s "${dir}/checksums.sha256" ]] || { warn "checksums.sha256 missing or empty"; failures=$((failures + 1)); }
  for file in manifest.env workspace-config.tgz vikunja.zip vikunja.sql n8n.sql hermes-snapshot.status nemoclaw-backup.status checksums.sha256; do
    [[ -e "${dir}/${file}" ]] && workspace_file_mode_is "${dir}/${file}" 600 \
      || { warn "${file} mode must be 0600"; failures=$((failures + 1)); }
  done
  workspace_backup_verify_checksums "$dir" || failures=$((failures + 1))
  if [[ "$failures" -eq 0 ]]; then
    info "Backup verified: ${dir}"
    return 0
  fi
  return 1
}

cmd_workspace_backup() {
  if [[ "${1:-}" == "--verify" ]]; then
    [[ $# -eq 2 ]] || die "Usage: spark ws backup --verify BACKUP_DIR"
    workspace_backup_verify "${2:-}"
    return $?
  fi
  [[ $# -eq 0 ]] || { [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { printf "\n  Usage: spark ws backup [--verify BACKUP_DIR]\n\n"; return 0; }; die "Unknown ws backup flag: $1"; }
  workspace_require_config
  local ts dir manifest failures=0 old_umask
  ts=$(date +%Y%m%d-%H%M%S)
  dir="${WORKSPACE_DATA_DIR}/backups/${ts}"
  mkdir -p "$dir"
  chmod 700 "$dir"
  manifest="${dir}/manifest.env"
  old_umask=$(umask)
  umask 077
  : > "$manifest"
  printf 'CREATED_AT=%s\n' "$ts" >> "$manifest"
  tar -C "$WORKSPACE_CONFIG_DIR" -czf "$dir/workspace-config.tgz" . >/dev/null 2>&1 \
    && { printf 'WORKSPACE_CONFIG_STATUS=ok\n' >> "$manifest"; info "Backed up workspace config"; } \
    || { printf 'WORKSPACE_CONFIG_STATUS=failed\n' >> "$manifest"; warn "Could not back up workspace config"; failures=$((failures + 1)); }
  workspace_compose exec -T vikunja /app/vikunja/vikunja dump -p /tmp -f vikunja.zip >/dev/null 2>&1 \
    && workspace_compose cp vikunja:/tmp/vikunja.zip "$dir/vikunja.zip" >/dev/null 2>&1 \
    && { printf 'VIKUNJA_DUMP_STATUS=ok\n' >> "$manifest"; info "Backed up Vikunja dump"; } \
    || { printf 'VIKUNJA_DUMP_STATUS=failed\n' >> "$manifest"; warn "Could not create Vikunja dump"; failures=$((failures + 1)); }
  workspace_compose exec -T -e "PGPASSWORD=$(workspace_read_env VIKUNJA_DATABASE_PASSWORD)" postgres pg_dump -U vikunja vikunja > "$dir/vikunja.sql" 2>/dev/null \
    && { printf 'VIKUNJA_DB_STATUS=ok\n' >> "$manifest"; info "Backed up Vikunja Postgres"; } \
    || { printf 'VIKUNJA_DB_STATUS=failed\n' >> "$manifest"; warn "Could not dump Vikunja Postgres"; failures=$((failures + 1)); }
  workspace_compose exec -T -e "PGPASSWORD=$(workspace_read_env DB_POSTGRESDB_PASSWORD)" postgres pg_dump -U n8n n8n > "$dir/n8n.sql" 2>/dev/null \
    && { printf 'N8N_DB_STATUS=ok\n' >> "$manifest"; info "Backed up n8n Postgres"; } \
    || { printf 'N8N_DB_STATUS=failed\n' >> "$manifest"; warn "Could not dump n8n Postgres"; failures=$((failures + 1)); }
  if command -v nemohermes >/dev/null 2>&1; then
    nemohermes hermes snapshot create >/dev/null 2>&1 \
      && { printf 'HERMES_SNAPSHOT_STATUS=ok\n' >> "$manifest"; printf 'ok\n' > "$dir/hermes-snapshot.status"; info "Created Hermes snapshot"; } \
      || { printf 'HERMES_SNAPSHOT_STATUS=failed\n' >> "$manifest"; warn "Could not create Hermes snapshot"; failures=$((failures + 1)); }
    nemohermes backup-all >/dev/null 2>&1 \
      && { printf 'NEMOCLAW_BACKUP_ALL_STATUS=ok\n' >> "$manifest"; printf 'ok\n' > "$dir/nemoclaw-backup.status"; info "Backed up NemoClaw registry"; } \
      || { printf 'NEMOCLAW_BACKUP_ALL_STATUS=failed\n' >> "$manifest"; warn "Could not run nemohermes backup-all"; failures=$((failures + 1)); }
  else
    printf 'HERMES_SNAPSHOT_STATUS=missing-nemohermes\n' >> "$manifest"
    printf 'NEMOCLAW_BACKUP_ALL_STATUS=missing-nemohermes\n' >> "$manifest"
    warn "NemoHermes not installed; Hermes backup skipped"
    failures=$((failures + 1))
  fi
  workspace_backup_write_checksums "$dir" \
    && { printf 'CHECKSUMS_STATUS=ok\n' >> "$manifest"; info "Wrote backup checksums"; } \
    || { printf 'CHECKSUMS_STATUS=failed\n' >> "$manifest"; warn "Could not write backup checksums"; failures=$((failures + 1)); }
  chmod 600 "$manifest" "$dir"/workspace-config.tgz "$dir"/vikunja.zip "$dir"/vikunja.sql "$dir"/n8n.sql \
    "$dir"/hermes-snapshot.status "$dir"/nemoclaw-backup.status "$dir"/checksums.sha256 2>/dev/null || true
  umask "$old_umask"
  printf "\n  Backup: %s\n\n" "$dir"
  [[ "$failures" -eq 0 ]] || return 1
}

workspace_require_nemohermes() {
  command -v nemohermes >/dev/null 2>&1 || die "NemoHermes not installed" "Run: spark ws setup"
}

workspace_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

WORKSPACE_DOCTOR_FAILED=0
WORKSPACE_DOCTOR_JSON=0
WORKSPACE_DOCTOR_JSON_ITEMS=()

workspace_doctor_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

workspace_doctor_pass() {
  printf "  [x] %s\n" "$1"
}

workspace_doctor_fail() {
  printf "  [ ] %s\n" "$1"
  WORKSPACE_DOCTOR_FAILED=$((WORKSPACE_DOCTOR_FAILED + 1))
}

workspace_doctor_id_from_label() {
  LC_ALL=C printf '%s\n' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]\{1,\}/_/g; s/^_//; s/_$//'
}

workspace_doctor_check() {
  local label="$1" id
  shift
  id=$(workspace_doctor_id_from_label "$label")
  if "$@"; then
    if [[ "$WORKSPACE_DOCTOR_JSON" == "1" ]]; then
      WORKSPACE_DOCTOR_JSON_ITEMS+=("{\"id\":\"$(workspace_doctor_json_escape "$id")\",\"label\":\"$(workspace_doctor_json_escape "$label")\",\"ok\":true}")
    else
      workspace_doctor_pass "$label"
    fi
  else
    if [[ "$WORKSPACE_DOCTOR_JSON" == "1" ]]; then
      WORKSPACE_DOCTOR_JSON_ITEMS+=("{\"id\":\"$(workspace_doctor_json_escape "$id")\",\"label\":\"$(workspace_doctor_json_escape "$label")\",\"ok\":false}")
      WORKSPACE_DOCTOR_FAILED=$((WORKSPACE_DOCTOR_FAILED + 1))
    else
      workspace_doctor_fail "$label"
    fi
  fi
}

workspace_doctor_print_json() {
  local model="$1" items=""
  if [[ ${#WORKSPACE_DOCTOR_JSON_ITEMS[@]} -gt 0 ]]; then
    local IFS=,
    items="${WORKSPACE_DOCTOR_JSON_ITEMS[*]}"
  fi
  printf '{"ok":%s,"failed":%d,"model":"%s","checks":[%s]}\n' \
    "$( [[ "$WORKSPACE_DOCTOR_FAILED" -eq 0 ]] && printf true || printf false )" \
    "$WORKSPACE_DOCTOR_FAILED" \
    "$(workspace_doctor_json_escape "$model")" \
    "$items"
}

workspace_env_has() {
  local key val
  for key in "$@"; do
    val=$(workspace_read_env "$key" || true)
    [[ -n "$val" ]] || return 1
  done
}

workspace_human_password_not_stored() {
  [[ -f "$WORKSPACE_ENV_FILE" ]] || return 1
  ! grep -Eq '^VIKUNJA_HUMAN_PASSWORD=.+$' "$WORKSPACE_ENV_FILE"
}

workspace_credentials_are_distinct() {
  local key val seen
  seen=""
  for key in \
    POSTGRES_PASSWORD VIKUNJA_DATABASE_PASSWORD DB_POSTGRESDB_PASSWORD VIKUNJA_SERVICE_SECRET \
    N8N_ENCRYPTION_KEY WORKSPACE_MENTION_SECRET VIKUNJA_HUMAN_RECOVERY_PASSWORD \
    VIKUNJA_HERMES_PASSWORD N8N_BASIC_AUTH_PASSWORD VIKUNJA_HERMES_API_TOKEN; do
    val=$(workspace_read_env "$key" || true)
    [[ -n "$val" ]] || return 1
    if printf '%s\n' "$seen" | grep -Fqx -- "$val"; then
      return 1
    fi
    seen="${seen}${val}"$'\n'
  done
  return 0
}

workspace_env_file_syntax_valid() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  awk -F= '
    BEGIN { sq=sprintf("%c",39) }
    /^[[:space:]]*$/ { next }
    index($0, "\r") { bad=1; next }
    /^[A-Z0-9_]+=/{
      if (seen[$1]++) bad=1
      value=$0
      sub(/^[^=]*=/, "", value)
      double_value=value
      single_value=value
      if (gsub(/"/, "", double_value) % 2) bad=1
      if (gsub(sq, "", single_value) % 2) bad=1
      next
    }
    { bad=1 }
    END { exit bad }
  ' "$file"
}

workspace_service_env_files_syntax_valid() {
  workspace_env_file_syntax_valid "$WORKSPACE_POSTGRES_ENV_FILE" &&
    workspace_env_file_syntax_valid "$WORKSPACE_VIKUNJA_ENV_FILE" &&
    workspace_env_file_syntax_valid "$WORKSPACE_N8N_ENV_FILE"
}

workspace_file_mode_is() {
  local file="$1" want="$2" mode=""
  [[ -e "$file" ]] || return 1
  mode=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || true)
  [[ "$mode" == "$want" ]]
}

workspace_compose_service_running() {
  local service="$1"
  [[ -f "$WORKSPACE_COMPOSE_FILE" && -f "$WORKSPACE_ENV_FILE" ]] || return 1
  workspace_compose ps --services --status running 2>/dev/null | grep -qx "$service"
}

workspace_compose_mentions_service() {
  local service="$1"
  [[ -f "$WORKSPACE_COMPOSE_FILE" ]] || return 1
  grep -qE "^[[:space:]]{2}${service}:" "$WORKSPACE_COMPOSE_FILE"
}

workspace_compose_config_valid() {
  [[ -f "$WORKSPACE_COMPOSE_FILE" && -f "$WORKSPACE_ENV_FILE" ]] || return 1
  workspace_compose config --quiet >/dev/null 2>&1
}

workspace_compose_shared_postgres() {
  [[ -f "$WORKSPACE_COMPOSE_FILE" && -f "${WORKSPACE_CONFIG_DIR}/init-db.sh" ]] || return 1
  workspace_compose_mentions_service postgres &&
    ! workspace_compose_mentions_service vikunja-db &&
    ! workspace_compose_mentions_service n8n-db &&
    grep -q 'CREATE DATABASE vikunja' "${WORKSPACE_CONFIG_DIR}/init-db.sh" &&
    grep -q 'CREATE DATABASE n8n' "${WORKSPACE_CONFIG_DIR}/init-db.sh" &&
    grep -q 'WHERE NOT EXISTS' "${WORKSPACE_CONFIG_DIR}/init-db.sh" &&
    grep -q 'ALTER USER vikunja' "${WORKSPACE_CONFIG_DIR}/init-db.sh" &&
    grep -q 'ALTER USER n8n' "${WORKSPACE_CONFIG_DIR}/init-db.sh"
}

workspace_postgres_shared_runtime_ready() {
  workspace_postgres_role_exists vikunja &&
    workspace_postgres_role_exists n8n &&
    workspace_postgres_db_exists vikunja &&
    workspace_postgres_db_exists n8n
}

workspace_private_bind_addr_ok() {
  local addr=${1:-}
  case "$addr" in
    ""|0.0.0.0|::|'[::]'|'*') return 1 ;;
  esac
  return 0
}

workspace_tailscale_bind_addr_ok() {
  local addr="${1:-}" current
  workspace_private_bind_addr_ok "$addr" || return 1
  current=$(workspace_tailscale_ipv4 2>/dev/null || true)
  [[ -n "$current" && "$addr" == "$current" ]]
}

workspace_tailscale_dns_name_ok() {
  local dns="${1:-}" current
  dns="${dns%.}"
  [[ -n "$dns" ]] || return 1
  current=$(workspace_tailscale_dns_name 2>/dev/null || true)
  [[ -n "$current" && "$dns" == "$current" ]]
}

workspace_compose_uses_loopback_ports() {
  local mode bind_addr
  [[ -f "$WORKSPACE_COMPOSE_FILE" ]] || return 1
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  bind_addr=127.0.0.1
  [[ "$mode" == "ports" ]] && bind_addr=$(workspace_read_env WORKSPACE_TAILSCALE_BIND_ADDR 2>/dev/null || true)
  if [[ "$mode" == "ports" ]]; then
    workspace_tailscale_bind_addr_ok "$bind_addr" || return 1
  else
    workspace_private_bind_addr_ok "$bind_addr" || return 1
  fi
  grep -Fq "${bind_addr}:${WORKSPACE_VIKUNJA_PORT}:3456" "$WORKSPACE_COMPOSE_FILE" &&
    grep -Fq "${bind_addr}:${WORKSPACE_N8N_PORT}:5678" "$WORKSPACE_COMPOSE_FILE" &&
    ! grep -qE '0[.]0[.]0[.]0:|:::[0-9]+|[[]::[]]:' "$WORKSPACE_COMPOSE_FILE"
}

workspace_vikunja_locked_down() {
  [[ -f "$WORKSPACE_VIKUNJA_ENV_FILE" ]] || return 1
  grep -q '^VIKUNJA_SERVICE_ENABLEREGISTRATION=false$' "$WORKSPACE_VIKUNJA_ENV_FILE" &&
    grep -q '^VIKUNJA_SERVICE_ENABLELINKSHARING=false$' "$WORKSPACE_VIKUNJA_ENV_FILE"
}

workspace_vikunja_doctor_ok() {
  workspace_vikunja_cli doctor >/dev/null 2>&1
}

workspace_n8n_hardened() {
  local protocol secure_cookie
  [[ -f "$WORKSPACE_N8N_ENV_FILE" ]] || return 1
  protocol=$(sed -n 's/^N8N_PROTOCOL=//p' "$WORKSPACE_N8N_ENV_FILE" | head -1)
  secure_cookie=$(sed -n 's/^N8N_SECURE_COOKIE=//p' "$WORKSPACE_N8N_ENV_FILE" | head -1)
  case "$protocol" in
    https) [[ "$secure_cookie" == "true" ]] || return 1 ;;
    http) [[ "$secure_cookie" == "false" ]] || return 1 ;;
    *) return 1 ;;
  esac
  grep -q '^NODES_EXCLUDE=.*n8n-nodes-base.executeCommand' "$WORKSPACE_N8N_ENV_FILE" &&
    grep -q '^N8N_RUNNERS_ENABLED=true$' "$WORKSPACE_N8N_ENV_FILE" &&
    grep -q '^N8N_BLOCK_ENV_ACCESS_IN_NODE=true$' "$WORKSPACE_N8N_ENV_FILE" &&
    grep -q '^N8N_BLOCK_FILE_ACCESS_TO_N8N_FILES=true$' "$WORKSPACE_N8N_ENV_FILE" &&
    grep -q '^N8N_RESTRICT_FILE_ACCESS_TO=' "$WORKSPACE_N8N_ENV_FILE" &&
    grep -q '^N8N_GIT_NODE_DISABLE_BARE_REPOS=true$' "$WORKSPACE_N8N_ENV_FILE" &&
    grep -q '^N8N_GIT_NODE_ENABLE_HOOKS=false$' "$WORKSPACE_N8N_ENV_FILE" &&
    grep -q '^N8N_SECURITY_POLICY_MANAGED_BY_ENV=true$' "$WORKSPACE_N8N_ENV_FILE" &&
    grep -q '^N8N_PERSONAL_SPACE_PUBLISHING_ENABLED=false$' "$WORKSPACE_N8N_ENV_FILE" &&
    grep -q '^N8N_PERSONAL_SPACE_SHARING_ENABLED=false$' "$WORKSPACE_N8N_ENV_FILE" &&
    grep -q '^N8N_COMMUNITY_PACKAGES_ENABLED=false$' "$WORKSPACE_N8N_ENV_FILE" &&
    grep -q '^N8N_UNVERIFIED_PACKAGES_ENABLED=false$' "$WORKSPACE_N8N_ENV_FILE" &&
    grep -q '^N8N_VERIFIED_PACKAGES_ENABLED=false$' "$WORKSPACE_N8N_ENV_FILE" &&
    grep -q '^N8N_COMMUNITY_PACKAGES_MANAGED_BY_ENV=true$' "$WORKSPACE_N8N_ENV_FILE" &&
    grep -q '^N8N_COMMUNITY_PACKAGES=\[\]$' "$WORKSPACE_N8N_ENV_FILE" &&
    grep -q '^N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true$' "$WORKSPACE_N8N_ENV_FILE"
}

workspace_service_env_files_ready() {
  [[ -f "$WORKSPACE_POSTGRES_ENV_FILE" && -f "$WORKSPACE_VIKUNJA_ENV_FILE" && -f "$WORKSPACE_N8N_ENV_FILE" ]] &&
    workspace_file_mode_is "$WORKSPACE_POSTGRES_ENV_FILE" 600 &&
    workspace_file_mode_is "$WORKSPACE_VIKUNJA_ENV_FILE" 600 &&
    workspace_file_mode_is "$WORKSPACE_N8N_ENV_FILE" 600
}

workspace_compose_uses_scoped_env_files() {
  [[ -f "$WORKSPACE_COMPOSE_FILE" ]] || return 1
  grep -Fq "$WORKSPACE_POSTGRES_ENV_FILE" "$WORKSPACE_COMPOSE_FILE" &&
    grep -Fq "$WORKSPACE_VIKUNJA_ENV_FILE" "$WORKSPACE_COMPOSE_FILE" &&
    grep -Fq "$WORKSPACE_N8N_ENV_FILE" "$WORKSPACE_COMPOSE_FILE" &&
    ! grep -Fq "$WORKSPACE_ENV_FILE" "$WORKSPACE_COMPOSE_FILE"
}

workspace_compose_images_configured() {
  local postgres_image vikunja_image n8n_image
  [[ -f "$WORKSPACE_COMPOSE_FILE" ]] || return 1
  postgres_image=$(workspace_read_env WORKSPACE_POSTGRES_IMAGE 2>/dev/null || true)
  vikunja_image=$(workspace_read_env WORKSPACE_VIKUNJA_IMAGE 2>/dev/null || true)
  n8n_image=$(workspace_read_env WORKSPACE_N8N_IMAGE 2>/dev/null || true)
  [[ -n "$postgres_image" && -n "$vikunja_image" && -n "$n8n_image" ]] &&
    grep -Fq "image: ${postgres_image}" "$WORKSPACE_COMPOSE_FILE" &&
    grep -Fq "image: ${vikunja_image}" "$WORKSPACE_COMPOSE_FILE" &&
    grep -Fq "image: ${n8n_image}" "$WORKSPACE_COMPOSE_FILE"
}

workspace_image_ref_pinned() {
  local ref="$1"
  [[ "$ref" == *@sha256:* ]] || [[ "$ref" == *:* && "$ref" != *:latest && "$ref" != *:main-latest ]]
}

workspace_compose_images_pinned() {
  local postgres_image vikunja_image n8n_image
  postgres_image=$(workspace_read_env WORKSPACE_POSTGRES_IMAGE 2>/dev/null || true)
  vikunja_image=$(workspace_read_env WORKSPACE_VIKUNJA_IMAGE 2>/dev/null || true)
  n8n_image=$(workspace_read_env WORKSPACE_N8N_IMAGE 2>/dev/null || true)
  workspace_image_ref_pinned "$postgres_image" &&
    workspace_image_ref_pinned "$vikunja_image" &&
    workspace_image_ref_pinned "$n8n_image"
}

workspace_compose_runtime_hardened() {
  [[ -f "$WORKSPACE_COMPOSE_FILE" ]] || return 1
  [[ "$(grep -c 'no-new-privileges:true' "$WORKSPACE_COMPOSE_FILE" 2>/dev/null || true)" -ge 3 ]] &&
    [[ "$(grep -c 'init: true' "$WORKSPACE_COMPOSE_FILE" 2>/dev/null || true)" -ge 3 ]] &&
    [[ "$(grep -c 'stop_grace_period: 30s' "$WORKSPACE_COMPOSE_FILE" 2>/dev/null || true)" -ge 3 ]] &&
    [[ "$(grep -c 'pids_limit: 512' "$WORKSPACE_COMPOSE_FILE" 2>/dev/null || true)" -ge 3 ]] &&
    [[ "$(grep -c 'max-size: "10m"' "$WORKSPACE_COMPOSE_FILE" 2>/dev/null || true)" -ge 3 ]] &&
    [[ "$(grep -c 'max-file: "5"' "$WORKSPACE_COMPOSE_FILE" 2>/dev/null || true)" -ge 3 ]]
}

workspace_n8n_owner_ready() {
  workspace_n8n_login >/dev/null 2>&1
}

workspace_vikunja_user_ready() {
  local username="$1" email="$2" status_key="$3" status rc
  workspace_vikunja_user_exists "$username" "$email" >/dev/null 2>&1 && return 0
  rc=$?
  [[ "$rc" -eq 2 ]] || return 1
  status=$(workspace_read_env "$status_key" 2>/dev/null || true)
  [[ "$status" == "created" || "$status" == "exists" ]]
}

workspace_vikunja_human_ready() {
  local username email
  username=$(workspace_read_env VIKUNJA_HUMAN_USERNAME 2>/dev/null || true)
  email=$(workspace_read_env VIKUNJA_HUMAN_EMAIL 2>/dev/null || true)
  [[ -n "$username" && -n "$email" ]] || return 1
  workspace_vikunja_user_ready "$username" "$email" VIKUNJA_HUMAN_USER_STATUS
}

workspace_vikunja_hermes_ready() {
  workspace_vikunja_user_ready hermes "$WORKSPACE_VIKUNJA_HERMES_EMAIL" VIKUNJA_HERMES_USER_STATUS
}

workspace_vikunja_hermes_api_ready() {
  local token
  token=$(workspace_read_env VIKUNJA_HERMES_API_TOKEN 2>/dev/null || true)
  [[ -n "$token" ]] || return 1
  workspace_check_vikunja_token "$token" >/dev/null 2>&1
}

workspace_urls_configured() {
  local vikunja n8n hermes mode dns tailnet vikunja_public n8n_host n8n_protocol n8n_cookie n8n_editor n8n_webhook expected_host
  vikunja=$(workspace_read_env VIKUNJA_URL 2>/dev/null || true)
  n8n=$(workspace_read_env N8N_URL 2>/dev/null || true)
  hermes=$(workspace_read_env HERMES_URL 2>/dev/null || true)
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  dns=$(workspace_read_env WORKSPACE_TAILSCALE_DNS_NAME 2>/dev/null || true)
  tailnet=$(workspace_tailnet_suffix 2>/dev/null || true)
  vikunja_public=$(sed -n 's/^VIKUNJA_SERVICE_PUBLICURL=//p' "$WORKSPACE_VIKUNJA_ENV_FILE" 2>/dev/null | head -1)
  n8n_host=$(sed -n 's/^N8N_HOST=//p' "$WORKSPACE_N8N_ENV_FILE" 2>/dev/null | head -1)
  n8n_protocol=$(sed -n 's/^N8N_PROTOCOL=//p' "$WORKSPACE_N8N_ENV_FILE" 2>/dev/null | head -1)
  n8n_cookie=$(sed -n 's/^N8N_SECURE_COOKIE=//p' "$WORKSPACE_N8N_ENV_FILE" 2>/dev/null | head -1)
  n8n_editor=$(sed -n 's/^N8N_EDITOR_BASE_URL=//p' "$WORKSPACE_N8N_ENV_FILE" 2>/dev/null | head -1)
  n8n_webhook=$(sed -n 's/^WEBHOOK_URL=//p' "$WORKSPACE_N8N_ENV_FILE" 2>/dev/null | head -1)
  [[ -n "$vikunja" && -n "$n8n" && -n "$hermes" ]] || return 1
  if [[ "$mode" == "services" ]]; then
    [[ -n "$tailnet" ]] || return 1
    expected_host="${n8n#https://}"
    [[ "$vikunja" == "https://vikunja.${tailnet}" && "$n8n" == "https://n8n.${tailnet}" && "$hermes" == "https://hermes.${tailnet}" ]] &&
      [[ "$vikunja_public" == "$vikunja" && "$n8n_host" == "$expected_host" ]] &&
      [[ "$n8n_protocol" == "https" && "$n8n_cookie" == "true" ]] &&
      [[ "$n8n_editor" == "$n8n" && "$n8n_webhook" == "$n8n" ]]
  elif [[ "$mode" == "ports" ]]; then
    workspace_tailscale_dns_name_ok "$dns" &&
      [[ "$vikunja" == "http://${dns}:${WORKSPACE_VIKUNJA_PORT}" ]] &&
      [[ "$n8n" == "http://${dns}:${WORKSPACE_N8N_PORT}" ]] &&
      [[ "$hermes" == "http://${dns}:${WORKSPACE_HERMES_PORT}" ]] &&
      [[ "$vikunja_public" == "$vikunja" && "$n8n_host" == "$dns" ]] &&
      [[ "$n8n_protocol" == "http" && "$n8n_cookie" == "false" ]] &&
      [[ "$n8n_editor" == "$n8n" && "$n8n_webhook" == "$n8n" ]]
  else
    return 1
  fi
}

workspace_http_ready() {
  local url="$1"
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsS --max-time 3 "$url" >/dev/null 2>&1
}

workspace_vikunja_http_ready() {
  local mode url
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  if [[ "$mode" == "ports" ]]; then
    url=$(workspace_read_env VIKUNJA_URL 2>/dev/null || true)
    [[ -n "$url" ]] || return 1
    workspace_http_ready "${url%/}/api/v1/info"
    return $?
  fi
  workspace_http_ready "http://127.0.0.1:${WORKSPACE_VIKUNJA_PORT}/api/v1/info"
}

workspace_n8n_http_ready() {
  local mode url
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  if [[ "$mode" == "ports" ]]; then
    url=$(workspace_read_env N8N_URL 2>/dev/null || true)
    [[ -n "$url" ]] || return 1
    workspace_http_ready "${url%/}/healthz"
    return $?
  fi
  workspace_http_ready "http://127.0.0.1:${WORKSPACE_N8N_PORT}/healthz"
}

workspace_litellm_model_routed() {
  local litellm_model out
  litellm_model=$(workspace_read_env HERMES_LITELLM_MODEL 2>/dev/null || true)
  [[ -n "$litellm_model" ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  out=$(curl -fsS --max-time 5 "http://127.0.0.1:${GATEWAY_PORT}/v1/models" 2>/dev/null) || return 1
  printf '%s\n' "$out" | grep -Fq "\"${litellm_model}\""
}

workspace_tailscale_https_urls_ready() {
  local vikunja n8n hermes mode tailnet dns
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  [[ "$mode" == "services" || "$mode" == "ports" ]] || return 1
  vikunja=$(workspace_read_env VIKUNJA_URL 2>/dev/null || true)
  n8n=$(workspace_read_env N8N_URL 2>/dev/null || true)
  hermes=$(workspace_read_env HERMES_URL 2>/dev/null || true)
  if [[ "$mode" == "services" ]]; then
    tailnet=$(workspace_tailnet_suffix 2>/dev/null || true)
    [[ -n "$tailnet" ]] || return 1
    [[ "$vikunja" == "https://vikunja.${tailnet}" && "$n8n" == "https://n8n.${tailnet}" && "$hermes" == "https://hermes.${tailnet}" ]] || return 1
  else
    dns=$(workspace_read_env WORKSPACE_TAILSCALE_DNS_NAME 2>/dev/null || true)
    workspace_tailscale_dns_name_ok "$dns" || return 1
    [[ "$vikunja" == "http://${dns}:${WORKSPACE_VIKUNJA_PORT}" && "$n8n" == "http://${dns}:${WORKSPACE_N8N_PORT}" && "$hermes" == "http://${dns}:${WORKSPACE_HERMES_PORT}" ]] || return 1
  fi
  workspace_http_ready "${vikunja%/}/api/v1/info" &&
    workspace_http_ready "${n8n%/}/healthz" &&
    workspace_hermes_api_ready_at "$hermes"
}

workspace_runtime_ports_not_public() {
  local ports out
  ports="${WORKSPACE_VIKUNJA_PORT}|${WORKSPACE_N8N_PORT}|${WORKSPACE_HERMES_PORT}|${GATEWAY_PORT}"
  out=$(docker ps --format '{{.Ports}}' 2>/dev/null | grep -E "(${ports})->" || true)
  [[ "$out" != *"0.0.0.0:"* && "$out" != *":::"* && "$out" != *"[::]:"* ]]
}

workspace_host_listeners_loopback_only() {
  local ports bind_addr mode
  ports="${WORKSPACE_VIKUNJA_PORT}|${WORKSPACE_N8N_PORT}|${WORKSPACE_HERMES_PORT}|${GATEWAY_PORT}"
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  bind_addr=""
  if [[ "$mode" == "ports" ]]; then
    bind_addr=$(workspace_read_env WORKSPACE_TAILSCALE_BIND_ADDR 2>/dev/null || true)
    workspace_tailscale_bind_addr_ok "$bind_addr" || bind_addr=""
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH 2>/dev/null | awk -v ports="$ports" -v bind_addr="$bind_addr" '
      BEGIN { split(ports, p, "|"); for (i in p) wanted[p[i]]=1 }
      {
        local_addr=$4
        port=local_addr
        sub(/^.*:/, "", port)
        allowed = (local_addr ~ /(^|[^0-9])127[.]0[.]0[.]1:/ || local_addr ~ /\[::1\]:/ || local_addr ~ /(^|[^:])::1:/ || local_addr ~ /localhost:/)
        if (bind_addr != "" && index(local_addr, bind_addr ":") > 0) allowed=1
        if (wanted[port] && ! allowed) bad=1
      }
      END { exit bad }
    '
    return $?
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk -v ports="$ports" -v bind_addr="$bind_addr" '
      BEGIN { split(ports, p, "|"); for (i in p) wanted[p[i]]=1 }
      {
        line=$0
        for (port in wanted) {
          allowed = (line ~ /127[.]0[.]1:/ || line ~ /\[::1\]:/ || line ~ /localhost:/)
          if (bind_addr != "" && index(line, bind_addr ":" port) > 0) allowed=1
          if (line ~ ":" port "([[:space:]]|$|[)])" && ! allowed) bad=1
        }
      }
      END { exit bad }
    '
    return $?
  fi
  return 0
}

workspace_tailscale_connected() {
  command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1
}

workspace_tailscale_version_ok() {
  local version major minor
  command -v tailscale >/dev/null 2>&1 || return 1
  version=$(tailscale version 2>/dev/null | awk 'NR==1 {print $1}')
  [[ "$version" =~ ^([0-9]+)[.]([0-9]+) ]] || return 1
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  (( major > 1 || (major == 1 && minor >= 86) ))
}

workspace_run_root() {
  if [[ "$(id -u 2>/dev/null || echo 1)" == "0" ]]; then
    "$@"
    return $?
  fi
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && sudo -n "$@"
}

workspace_update_tailscale() {
  command -v tailscale >/dev/null 2>&1 || return 1
  info "Tailscale is older than 1.86; attempting update"
  if tailscale update >/dev/null 2>&1 && workspace_tailscale_version_ok; then
    info "Tailscale updated"
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    workspace_run_root bash -c 'apt-get update >/dev/null 2>&1 && apt-get install -y tailscale >/dev/null 2>&1' || return 1
  elif command -v dnf >/dev/null 2>&1; then
    workspace_run_root dnf update -y tailscale >/dev/null 2>&1 || return 1
  elif command -v yum >/dev/null 2>&1; then
    workspace_run_root yum update -y tailscale >/dev/null 2>&1 || return 1
  elif command -v zypper >/dev/null 2>&1; then
    workspace_run_root zypper --non-interactive update tailscale >/dev/null 2>&1 || return 1
  else
    return 1
  fi
  workspace_tailscale_version_ok && { info "Tailscale updated"; return 0; }
  return 1
}

workspace_tailscale_requested_version_ok() {
  [[ "$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)" == "ports" ]] && return 0
  workspace_tailscale_version_ok
}

workspace_tailscale_funnel_disabled() {
  ! tailscale_funnel_status_active
}

workspace_tailscale_serve_present() {
  [[ "$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)" == "ports" ]] && return 0
  command -v tailscale >/dev/null 2>&1 && tailscale serve status >/dev/null 2>&1
}

workspace_tailscale_service_target_private() {
  local out="$1" service="$2" port="$3" block
  if command -v jq >/dev/null 2>&1 && printf '%s\n' "$out" | jq -e . >/dev/null 2>&1; then
    printf '%s\n' "$out" | jq -e --arg svc "svc:${service}" --arg port "$port" '
      def private_target($p):
        test("(https?://)?(127[.]0[.]0[.]1|localhost|\\[::1\\]):" + $p + "|(^|[^:])::1:" + $p);
      [paths(scalars) as $p
        | select(($p | map(tostring) | join(" ")) | contains($svc))
        | getpath($p)
        | tostring
        | select(private_target($port))]
      | length > 0
    ' >/dev/null 2>&1 && return 0
  fi
  block=$(printf '%s\n' "$out" | awk '{ gsub(/\\n/, "\n"); gsub(/svc:/, "\nsvc:"); print }' | awk -v svc="svc:${service}" '
    index($0, svc) { capture=1; print; next }
    capture && /svc:[A-Za-z0-9_-]+/ { exit }
    capture { print }
  ')
  printf '%s\n' "$block" | grep -Eq "(https?://)?(127[.]0[.]0[.]1|localhost|[[]::1[]]):${port}|(^|[^:])::1:${port}"
}

workspace_hermes_api_ready_at() {
  local base_url="$1"
  [[ -n "$base_url" ]] || return 1
  workspace_http_ready "${base_url%/}/v1/models"
}

workspace_hermes_local_api_ready() {
  workspace_hermes_api_ready_at "http://127.0.0.1:${WORKSPACE_HERMES_LOCAL_PORT}"
}

workspace_hermes_private_url_ready() {
  local url
  url=$(workspace_read_env HERMES_URL 2>/dev/null || true)
  workspace_hermes_api_ready_at "$url"
}

workspace_hermes_proxy_pid_file() {
  printf '%s/hermes-proxy.pid\n' "$WORKSPACE_CONFIG_DIR"
}

workspace_hermes_proxy_log_file() {
  printf '%s/hermes-proxy.log\n' "$WORKSPACE_CONFIG_DIR"
}

workspace_hermes_proxy_bind_addr() {
  local mode bind_addr
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  if [[ "$mode" == "ports" ]]; then
    bind_addr=$(workspace_read_env WORKSPACE_TAILSCALE_BIND_ADDR 2>/dev/null || true)
    workspace_tailscale_bind_addr_ok "$bind_addr" || return 1
    printf '%s\n' "$bind_addr"
    return 0
  fi
  printf '127.0.0.1\n'
}

workspace_start_hermes_private_proxy() {
  local bind_addr pid_file log_file py pid
  workspace_hermes_private_url_ready && return 0
  workspace_hermes_local_api_ready || return 1
  bind_addr=$(workspace_hermes_proxy_bind_addr) || return 1
  pid_file=$(workspace_hermes_proxy_pid_file)
  log_file=$(workspace_hermes_proxy_log_file)
  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
  fi
  py=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
  [[ -n "$py" ]] || return 1
  mkdir -p "$WORKSPACE_CONFIG_DIR"
  nohup "$py" -c '
import socket, sys, threading
bind_addr, listen_port, target_port = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
def relay(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind((bind_addr, listen_port))
srv.listen(64)
while True:
    client, _ = srv.accept()
    upstream = socket.create_connection(("127.0.0.1", target_port), timeout=10)
    threading.Thread(target=relay, args=(client, upstream), daemon=True).start()
    threading.Thread(target=relay, args=(upstream, client), daemon=True).start()
' "$bind_addr" "$WORKSPACE_HERMES_PORT" "$WORKSPACE_HERMES_LOCAL_PORT" >>"$log_file" 2>&1 &
  printf '%s\n' "$!" >"$pid_file"
  sleep 1
  workspace_hermes_private_url_ready
}

workspace_tailscale_services_configured() {
  local out mode bind_addr dns_name
  command -v tailscale >/dev/null 2>&1 || return 1
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  if [[ "$mode" == "ports" ]]; then
    bind_addr=$(workspace_read_env WORKSPACE_TAILSCALE_BIND_ADDR 2>/dev/null || true)
    dns_name=$(workspace_read_env WORKSPACE_TAILSCALE_DNS_NAME 2>/dev/null || true)
    workspace_tailscale_dns_name_ok "$dns_name" && workspace_tailscale_bind_addr_ok "$bind_addr"
    return $?
  fi
  out=$(tailscale serve get-config --all 2>/dev/null || tailscale serve status --json 2>/dev/null || tailscale serve status 2>/dev/null || true)
  [[ "$out" == *"svc:vikunja"* && "$out" == *"svc:n8n"* && "$out" == *"svc:hermes"* ]] &&
    workspace_tailscale_service_target_private "$out" vikunja "$WORKSPACE_VIKUNJA_PORT" &&
    workspace_tailscale_service_target_private "$out" n8n "$WORKSPACE_N8N_PORT" &&
    workspace_tailscale_service_target_private "$out" hermes "$WORKSPACE_HERMES_PORT" &&
    ! printf '%s\n' "$out" | grep -Eq "0[.]0[.]0[.]0:(${WORKSPACE_VIKUNJA_PORT}|${WORKSPACE_N8N_PORT}|${WORKSPACE_HERMES_PORT})|[[]::[]]:(${WORKSPACE_VIKUNJA_PORT}|${WORKSPACE_N8N_PORT}|${WORKSPACE_HERMES_PORT})"
}

workspace_tailscale_services_mode() {
  case "$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)" in
    services|ports) return 0 ;;
    *) return 1 ;;
  esac
}

workspace_gateway_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$GATEWAY_CONTAINER"
}

workspace_model_running() {
  local model="$1"
  [[ -n "$model" ]] || return 1
  [[ "$(workspace_model_state "$model")" == *"running"* ]]
}

workspace_hermes_running() {
  command -v nemohermes >/dev/null 2>&1 || return 1
  nemohermes hermes status >/dev/null 2>&1 || nemohermes status >/dev/null 2>&1
}

workspace_hermes_nemoclaw_configured() {
  command -v nemohermes >/dev/null 2>&1 || return 1
  [[ "$(workspace_read_env HERMES_DASHBOARD_PORT 2>/dev/null || true)" == "$WORKSPACE_HERMES_PORT" ]] &&
    [[ "$(workspace_read_env HERMES_POLICY_TIER 2>/dev/null || true)" == "restricted" ]] &&
    workspace_hermes_local_api_ready &&
    workspace_hermes_private_url_ready
}

workspace_hermes_doctor_ready() {
  command -v nemohermes >/dev/null 2>&1 || return 1
  workspace_hermes_running &&
    workspace_hermes_local_api_ready &&
    workspace_hermes_inference_route_ready
}

workspace_hermes_inference_route_ready() {
  local litellm_model out
  command -v nemohermes >/dev/null 2>&1 || return 1
  litellm_model=$(workspace_read_env HERMES_LITELLM_MODEL 2>/dev/null || true)
  [[ -n "$litellm_model" ]] || return 1
  out=$(NEMOCLAW_SANDBOX_NAME=hermes nemohermes inference get --json 2>/dev/null || \
    NEMOCLAW_SANDBOX_NAME=hermes nemohermes inference get 2>/dev/null || true)
  [[ "$out" == *"$litellm_model"* ]] &&
    [[ "$out" == *"compatible"* || "$out" == *"custom"* || "$out" == *"OpenAI"* ]]
}

workspace_hermes_dashboard_url_ready() {
  local out expected
  command -v nemohermes >/dev/null 2>&1 || return 1
  workspace_hermes_private_url_ready && return 0
  expected=$(workspace_read_env HERMES_URL 2>/dev/null || true)
  out=$(nemohermes hermes dashboard-url 2>/dev/null || true)
  [[ -n "$out" ]] || return 1
  [[ -n "$expected" && "$out" == *"$expected"* ]] && return 0
  printf '%s\n' "$out" | grep -Eq "https?://(127[.]0[.]0[.]1|localhost|\[::1\]):${WORKSPACE_HERMES_PORT}(/|[[:space:]]|$)"
}

cmd_workspace_doctor_help() {
  cat <<EOF

  ${BOLD}Usage:${NC} spark ws doctor [--strict] [--json] [--model MODEL] [--remote user@host]

  Read-only workspace diagnosis. Checks config, secrets, Compose, Postgres, Vikunja,
  n8n, Tailscale private access, LiteLLM, Hermes/NemoClaw, and public exposure risks.

  ${BOLD}Flags:${NC}
    --json              Machine-readable output for CI/automation.
    --strict            Adds production checks, currently pinned image refs.
    --model MODEL       Validate Hermes route/model when it cannot be inferred from config.
    --remote user@host  Run the doctor on a configured remote host.

EOF
}

cmd_workspace_doctor() {
  local requested_model="" remote_spec="" model json_mode=0 strict_mode=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_mode=1; shift ;;
      --strict) strict_mode=1; shift ;;
      --model) requested_model="${2:-}"; [[ -n "$requested_model" ]] || die "--model requires a value"; shift 2 ;;
      --remote) remote_spec="${2:-}"; [[ -n "$remote_spec" ]] || die "--remote requires user@host"; shift 2 ;;
      -h|--help) cmd_workspace_doctor_help; return 0 ;;
      *) die "Unknown ws doctor flag: $1" ;;
    esac
  done
  if [[ -n "$remote_spec" ]]; then
    local args=(doctor)
    [[ "$strict_mode" == "1" ]] && args+=(--strict)
    [[ "$json_mode" == "1" ]] && args+=(--json)
    [[ -n "$requested_model" ]] && args+=(--model "$requested_model")
    workspace_remote_workspace_cmd "$remote_spec" "${args[@]}"
    return $?
  fi

  WORKSPACE_DOCTOR_FAILED=0
  WORKSPACE_DOCTOR_JSON="$json_mode"
  WORKSPACE_DOCTOR_JSON_ITEMS=()
  model="$requested_model"
  [[ -n "$model" ]] || model=$(workspace_read_env HERMES_MODEL 2>/dev/null || true)

  [[ "$json_mode" == "1" ]] || printf "\n  ${BOLD}spark ws doctor${NC}\n\n"
  workspace_doctor_check "Config directory exists" test -d "$WORKSPACE_CONFIG_DIR"
  workspace_doctor_check "Config directory mode is 0700" workspace_file_mode_is "$WORKSPACE_CONFIG_DIR" 700
  workspace_doctor_check "Data directory exists" test -d "$WORKSPACE_DATA_DIR"
  workspace_doctor_check "Secrets file exists" test -f "$WORKSPACE_ENV_FILE"
  workspace_doctor_check "Secrets file mode is 0600" workspace_file_mode_is "$WORKSPACE_ENV_FILE" 600
  workspace_doctor_check "Secrets env syntax is valid" workspace_env_file_syntax_valid "$WORKSPACE_ENV_FILE"
  workspace_doctor_check "Human Vikunja password is not stored" workspace_human_password_not_stored
  workspace_doctor_check "Compose file exists" test -f "$WORKSPACE_COMPOSE_FILE"
  workspace_doctor_check "Scoped service env files exist and are 0600" workspace_service_env_files_ready
  workspace_doctor_check "Scoped service env syntax is valid" workspace_service_env_files_syntax_valid
  workspace_doctor_check "Compose service exists: postgres" workspace_compose_mentions_service postgres
  workspace_doctor_check "Compose service exists: vikunja" workspace_compose_mentions_service vikunja
  workspace_doctor_check "Compose service exists: n8n" workspace_compose_mentions_service n8n
  workspace_doctor_check "Docker Compose config is valid" workspace_compose_config_valid
  workspace_doctor_check "Compose uses scoped env files, not full secrets.env" workspace_compose_uses_scoped_env_files
  workspace_doctor_check "Compose image refs are recorded and used" workspace_compose_images_configured
  workspace_doctor_check "Compose applies runtime hardening and log rotation" workspace_compose_runtime_hardened
  workspace_doctor_check "Shared Postgres initializes Vikunja and n8n DBs" workspace_compose_shared_postgres
  workspace_doctor_check "Compose uses private host bindings only" workspace_compose_uses_loopback_ports
  workspace_doctor_check "Vikunja registration/link sharing disabled" workspace_vikunja_locked_down
  workspace_doctor_check "Vikunja internal doctor passes" workspace_vikunja_doctor_ok
  workspace_doctor_check "Vikunja human user exists" workspace_vikunja_human_ready
  workspace_doctor_check "Vikunja hermes user exists" workspace_vikunja_hermes_ready
  workspace_doctor_check "Vikunja hermes API token works" workspace_vikunja_hermes_api_ready
  workspace_doctor_check "n8n hardened for private agent workflows" workspace_n8n_hardened
  workspace_doctor_check "n8n owner/admin login ready" workspace_n8n_owner_ready
  workspace_doctor_check "Workspace URLs configured" workspace_urls_configured
  workspace_doctor_check "Workspace secrets include human recovery, hermes, n8n, token, Hermes model" workspace_env_has \
    POSTGRES_PASSWORD VIKUNJA_DATABASE_PASSWORD VIKUNJA_SERVICE_SECRET DB_POSTGRESDB_PASSWORD \
    N8N_ENCRYPTION_KEY WORKSPACE_MENTION_SECRET VIKUNJA_HUMAN_USERNAME VIKUNJA_HUMAN_EMAIL VIKUNJA_HUMAN_RECOVERY_PASSWORD VIKUNJA_HERMES_PASSWORD N8N_BASIC_AUTH_USER \
    N8N_BASIC_AUTH_PASSWORD N8N_OWNER_SETUP_STATUS VIKUNJA_HERMES_API_TOKEN VIKUNJA_HERMES_API_STATUS HERMES_MODEL HERMES_LITELLM_MODEL \
    HERMES_LITELLM_BASE_URL VIKUNJA_URL N8N_URL HERMES_URL WORKSPACE_TAILSCALE_MODE \
    VIKUNJA_HUMAN_USER_STATUS VIKUNJA_HERMES_USER_STATUS
  workspace_doctor_check "Workspace credentials are unique per service" workspace_credentials_are_distinct
  workspace_doctor_check "Compose service running: postgres" workspace_compose_service_running postgres
  workspace_doctor_check "Shared Postgres runtime has Vikunja and n8n roles/databases" workspace_postgres_shared_runtime_ready
  workspace_doctor_check "Compose service running: vikunja" workspace_compose_service_running vikunja
  workspace_doctor_check "Compose service running: n8n" workspace_compose_service_running n8n
  workspace_doctor_check "Vikunja HTTP endpoint ready" workspace_vikunja_http_ready
  workspace_doctor_check "n8n HTTP endpoint ready" workspace_n8n_http_ready
  workspace_doctor_check "No workspace/gateway port is published on 0.0.0.0" workspace_runtime_ports_not_public
  workspace_doctor_check "Host listeners for workspace/gateway are loopback-only" workspace_host_listeners_loopback_only
  workspace_doctor_check "Tailscale connected" workspace_tailscale_connected
  workspace_doctor_check "Tailscale supports selected private access mode" workspace_tailscale_requested_version_ok
  workspace_doctor_check "Tailscale Funnel disabled" workspace_tailscale_funnel_disabled
  workspace_doctor_check "Tailscale Serve/ports access reachable" workspace_tailscale_serve_present
  workspace_doctor_check "Tailscale private access configured for vikunja, n8n, hermes" workspace_tailscale_services_configured
  workspace_doctor_check "Tailscale mode is Services or ports" workspace_tailscale_services_mode
  workspace_doctor_check "Tailscale workspace URLs respond" workspace_tailscale_https_urls_ready
  workspace_doctor_check "LiteLLM gateway running" workspace_gateway_running
  workspace_doctor_check "LiteLLM exposes Hermes model route" workspace_litellm_model_routed
  workspace_doctor_check "Hermes model running: ${model:-none}" workspace_model_running "$model"
  workspace_doctor_check "Hermes/NemoClaw running" workspace_hermes_running
  workspace_doctor_check "Hermes NemoClaw uses restricted policy and private API port" workspace_hermes_nemoclaw_configured
  workspace_doctor_check "NemoHermes sandbox doctor passes" workspace_hermes_doctor_ready
  workspace_doctor_check "NemoHermes inference route uses selected LiteLLM model" workspace_hermes_inference_route_ready
  workspace_doctor_check "Hermes private API URL is reachable" workspace_hermes_dashboard_url_ready
  if [[ "$strict_mode" == "1" ]]; then
    workspace_doctor_check "Compose image refs are pinned for production" workspace_compose_images_pinned
  fi

  if [[ "$json_mode" == "1" ]]; then
    workspace_doctor_print_json "$model"
    [[ "$WORKSPACE_DOCTOR_FAILED" -eq 0 ]] || return 1
    return 0
  fi

  if [[ "$WORKSPACE_DOCTOR_FAILED" -gt 0 ]]; then
    printf "\n  ${RED}${BOLD}Workspace doctor failed:${NC} %d check(s)\n\n" "$WORKSPACE_DOCTOR_FAILED"
    return 1
  fi
  printf "\n  ${GREEN}${BOLD}Workspace doctor passed${NC}\n\n"
}

workspace_summary() {
  printf "\n"
  if [[ ${#SETUP_FAILED[@]} -gt 0 ]]; then
    printf "  ${RED}${BOLD}Workspace incomplete:${NC} %d issue(s)\n" "${#SETUP_FAILED[@]}"
    local step
    for step in "${SETUP_FAILED[@]}"; do printf "    ${RED}✗${NC} %s\n" "$step"; done
    printf "\n  Fix them and re-run: ${BOLD}spark ws setup${NC}\n\n"
    return 1
  elif [[ ${#SETUP_SKIPPED[@]} -gt 0 ]]; then
    printf "  ${YELLOW}${BOLD}Skipped steps:${NC}\n"
    local step
    for step in "${SETUP_SKIPPED[@]}"; do printf "    ${YELLOW}⊘${NC} %s\n" "$step"; done
    printf "\n  Re-run ${BOLD}spark ws setup${NC} to complete them later.\n\n"
  else
    printf "  ${GREEN}${BOLD}Workspace complete!${NC}\n"
    printf "  Status: ${BOLD}spark ws status${NC}\n\n"
  fi
}

cmd_workspace_setup_help() {
  cat <<EOF

  ${BOLD}Usage:${NC} spark ws setup [flags]

  Installs/reconciles the private workspace: Vikunja, n8n, shared Postgres, and
  Hermes/NemoClaw using the selected LiteLLM model.

  ${BOLD}Flags:${NC}
    --check                     Read-only validation; no files, containers, or Funnel changes.
    --yes                       Accept safe defaults. Does not reset Funnel by itself.
    --remote user@host          Run setup on a configured remote host.
    --model MODEL               Hermes model; selected from spark list data when omitted.
    --tailscale-mode services   Prefer HTTPS names: vikunja/n8n/hermes.<tailnet>.ts.net.
    --tailscale-mode ports      Fallback: MagicDNS host + separate ports bound to Tailscale IP.
    --funnel-action reset       Reset active public Funnel and re-check before setup continues.
    --funnel-action abort       Fail if Funnel is active; no Funnel changes.
    --postgres-image IMAGE      Override Postgres image ref.
    --vikunja-image IMAGE       Override Vikunja image ref.
    --n8n-image IMAGE           Override n8n image ref.
    --vikunja-username NAME     Human Vikunja username.
    --vikunja-email EMAIL       Human Vikunja email.
    --vikunja-token TOKEN       Store/verify Hermes' Vikunja API token.
    --n8n-email EMAIL           n8n owner/admin email.
    --vikunja-password PASS     Deprecated: ignored; spark generates recovery secrets.
    --n8n-password PASS         Deprecated: ignored; spark generates recovery secrets.

  ${BOLD}Funnel rule:${NC}
    reset = this host should have no public Funnel exposure.
    abort = stop and inspect because Funnel might belong to something else.

EOF
}

cmd_workspace_help() {
  cat <<EOF

  ${BOLD}Usage:${NC} spark ws <command> [options]

  ${BOLD}Commands:${NC}
    setup      Install/check Vikunja + n8n + Hermes
    status     Show workspace health
    logs       Follow logs for vikunja, n8n, postgres, hermes, or gateway
    doctor     Read-only workspace check
    backup     Back up Vikunja, n8n, and Hermes state
    credentials
              Show or rotate local workspace recovery credentials

  Run ${BOLD}spark ws <command> --help${NC} for command-specific flags.

  ${BOLD}Setup flags:${NC}
    --check                     Read-only validation
    --yes                       Accept safe defaults
    --remote user@host          Run workspace setup on a configured remote host
    --model MODEL               Hermes model; must match spark list data
    --tailscale-mode services|ports
                                services = friendly HTTPS names; ports = MagicDNS + ports
    --funnel-action reset|abort Handle active Tailscale Funnel explicitly
    --postgres-image IMAGE      Override Postgres image ref
    --vikunja-image IMAGE       Override Vikunja image ref
    --n8n-image IMAGE           Override n8n image ref
    --vikunja-username NAME     Human Vikunja username
    --vikunja-email EMAIL       Human Vikunja email
    --vikunja-token TOKEN       Store/verify Hermes' Vikunja API token
    --n8n-email EMAIL           n8n owner/admin email
    --vikunja-password PASS     Deprecated: ignored; spark generates recovery secrets
    --n8n-password PASS         Deprecated: ignored; spark generates recovery secrets

EOF
}

cmd_workspace() {
  local subcmd="${1:-}"
  [[ -n "$subcmd" ]] && shift || true
  case "$subcmd" in
    setup)  workspace_setup "$@" ;;
    status) cmd_workspace_status ;;
    logs)   cmd_workspace_logs "$@" ;;
    doctor) cmd_workspace_doctor "$@" ;;
    backup) cmd_workspace_backup "$@" ;;
    credentials) cmd_workspace_credentials "$@" ;;
    help|--help|-h|"") cmd_workspace_help ;;
    *) die "Unknown ws command: $subcmd" "Run 'spark ws help'" ;;
  esac
}
