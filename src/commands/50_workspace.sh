# --- Workspace setup: task manager + n8n + Hermes/NemoClaw behind Tailscale ---

WORKSPACE_VIKUNJA_HERMES_BOT_USERNAME="${WORKSPACE_VIKUNJA_HERMES_BOT_USERNAME:-bot-hermes}"
WORKSPACE_TASK_MANAGER_SERVICE="${WORKSPACE_TASK_MANAGER_SERVICE:-tasks}"
WORKSPACE_HERMES_VIKUNJA_API_URL="${WORKSPACE_HERMES_VIKUNJA_API_URL:-http://host.openshell.internal:3456/api/v1}"
WORKSPACE_HERMES_SUPER_PRODUCTIVITY_API_URL="${WORKSPACE_HERMES_SUPER_PRODUCTIVITY_API_URL:-http://host.openshell.internal:3877}"

workspace_task_manager_valid() {
  case "${1:-}" in
    vikunja|super-productivity|todoist) return 0 ;;
    *) return 1 ;;
  esac
}

workspace_task_manager_hosted() {
  [[ "$(workspace_task_manager)" != "todoist" ]]
}

workspace_persisted_task_manager() {
  local configured compose="${WORKSPACE_COMPOSE_FILE:-}"
  configured=$(workspace_read_env WORKSPACE_TASK_MANAGER 2>/dev/null || true)
  if workspace_task_manager_valid "$configured"; then
    printf '%s\n' "$configured"
    return 0
  fi
  [[ -f "$compose" ]] || return 1
  if grep -qE '^[[:space:]]{2}(supersync|super-productivity-electron):' "$compose"; then
    printf 'super-productivity\n'
    return 0
  fi
  if grep -qE '^[[:space:]]{2}vikunja:' "$compose"; then
    printf 'vikunja\n'
    return 0
  fi
  return 1
}

workspace_task_manager() {
  local configured="${SPARK_WORKSPACE_TASK_MANAGER:-}"
  if workspace_task_manager_valid "$configured"; then
    printf '%s\n' "$configured"
    return 0
  fi
  workspace_persisted_task_manager 2>/dev/null || printf 'vikunja\n'
}

workspace_task_manager_label() {
  case "${1:-$(workspace_task_manager)}" in
    super-productivity) printf 'Super Productivity\n' ;;
    todoist) printf 'Todoist\n' ;;
    *) printf 'Vikunja\n' ;;
  esac
}

workspace_task_manager_url() {
  local url
  url=$(workspace_read_env TASK_MANAGER_URL 2>/dev/null || true)
  [[ -n "$url" ]] || url=$(workspace_read_env VIKUNJA_URL 2>/dev/null || true)
  [[ -n "$url" ]] || url=$(workspace_read_env SUPER_PRODUCTIVITY_URL 2>/dev/null || true)
  [[ -n "$url" ]] || url=$(workspace_read_env TODOIST_URL 2>/dev/null || true)
  printf '%s\n' "$url"
}

workspace_random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '\n'
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48
  fi
}

workspace_random_hex_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

workspace_random_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 24
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48
  fi
}

workspace_read_secret_file() {
  local label="$1" file="$2" value
  [[ -f "$file" ]] || die "${label} file not found: ${file}"
  value=$(sed -n '1p' "$file")
  workspace_require_prompt_value "$label" "$value" text
  printf '%s\n' "$value"
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

workspace_env_or_random_password() {
  local key="$1" val=""
  val=$(workspace_read_env "$key" 2>/dev/null || true)
  if [[ -n "$val" ]]; then
    printf '%s\n' "$val"
  else
    workspace_random_password
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

workspace_vikunja_service_secret() {
  local val="" persisted=""

  val=$(workspace_read_env VIKUNJA_SERVICE_SECRET 2>/dev/null || true)
  if [[ -z "$val" && -f "$WORKSPACE_VIKUNJA_ENV_FILE" ]]; then
    val=$(sed -n 's/^VIKUNJA_SERVICE_SECRET=//p' "$WORKSPACE_VIKUNJA_ENV_FILE" | head -1)
  fi
  if [[ -n "$val" ]]; then
    printf '%s\n' "$val"
    return 0
  fi

  if workspace_data_dir_has_content "${WORKSPACE_DATA_DIR}/vikunja-files"; then
    return 1
  fi
  persisted=$(workspace_persisted_task_manager 2>/dev/null || true)
  if [[ "$persisted" == "vikunja" ]] && workspace_data_dir_has_content "${WORKSPACE_DATA_DIR}/postgres"; then
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

workspace_model_tool_calling_ready() {
  local model="$1" container args parser profile_file expected=""
  [[ "$BACKEND" == "vllm" ]] || return 0
  [[ -n "$model" ]] || return 1
  container=$(container_for_ref "$model" 2>/dev/null || true)
  [[ -n "$container" ]] || return 1
  args=$(docker inspect -f '{{json .Config.Cmd}}' "$container" 2>/dev/null || true)
  parser=$(printf '%s\n' "$args" | jq -er '
    if type == "array" and index("--enable-auto-tool-choice") != null then
      index("--tool-call-parser") as $i |
      if $i != null and ($i + 1) < length then .[$i + 1] else empty end
    else empty end
  ' 2>/dev/null) || return 1
  [[ -n "$parser" ]] || return 1
  profile_file="${PROFILES_DIR}/$(printf '%s' "$model" | sed 's/\//--/g').json"
  if [[ -f "$profile_file" ]]; then
    expected=$(jq -r '
      if .hf.raw.model_type == "qwen3_5" then "qwen3_coder"
      else (.tool_call_parser // "") end
    ' "$profile_file" 2>/dev/null || true)
  fi
  [[ -z "$expected" || "$parser" == "$expected" ]]
}

workspace_model_context_ready() {
  local model="$1" container max_len
  [[ "$BACKEND" == "vllm" ]] || return 0
  container=$(container_for_ref "$model" 2>/dev/null || true)
  [[ -n "$container" ]] || return 1
  max_len=$(docker inspect -f '{{index .Config.Labels "spark.max_model_len"}}' "$container" 2>/dev/null || true)
  [[ "$max_len" =~ ^[0-9]+$ && "$max_len" -ge "$WORKSPACE_HERMES_MIN_CONTEXT" ]]
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
  local model="$1" i
  collect_downloaded_models
  for i in "${!MODEL_LIST_MODELS[@]}"; do
    [[ "${MODEL_LIST_MODELS[$i]}" == "$model" && "${MODEL_LIST_STATUS[$i]:-complete}" == "complete" ]] && return 0
  done
  return 1
}

workspace_select_model() {
  local requested="$1" choice i state
  collect_downloaded_models
  if [[ -n "$requested" ]]; then
    workspace_model_in_list "$requested" || die "Model not found or not fully downloaded in spark list: $requested"
    printf '%s\n' "$requested"
    return 0
  fi
  local complete_count=0
  for i in "${!MODEL_LIST_MODELS[@]}"; do
    [[ "${MODEL_LIST_STATUS[$i]:-complete}" == "complete" ]] && complete_count=$((complete_count + 1))
  done
  [[ "$complete_count" -gt 0 ]] || die "No fully downloaded models found" "Wait for 'spark pull <model>' to finish."
  is_interactive || die "Choose a model with --model in non-interactive mode"
  printf "\n  ${BOLD}Choose the model Hermes will use:${NC}\n\n" >&2
  for i in "${!MODEL_LIST_MODELS[@]}"; do
    state=$(workspace_model_state "${MODEL_LIST_MODELS[$i]}")
    [[ "${MODEL_LIST_STATUS[$i]:-complete}" == "partial" ]] && state="partial"
    printf "    [%d] %-45s %-10s %s\n" "$((i + 1))" "${MODEL_LIST_MODELS[$i]}" "${MODEL_LIST_SIZES[$i]}" "$state" >&2
  done
  while true; do
    printf "\n  > " >&2
    read -r choice || true
    [[ "$choice" =~ ^[0-9]+$ ]] || { printf "  Enter a number.\n" >&2; continue; }
    [[ "$choice" -ge 1 && "$choice" -le ${#MODEL_LIST_MODELS[@]} ]] || { printf "  Enter 1-%d.\n" "${#MODEL_LIST_MODELS[@]}" >&2; continue; }
    [[ "${MODEL_LIST_STATUS[$((choice - 1))]:-complete}" == "complete" ]] || { printf "  That model is still downloading.\n" >&2; continue; }
    printf '%s\n' "${MODEL_LIST_MODELS[$((choice - 1))]}"
    return 0
  done
}

workspace_ensure_gateway() {
  local check_only="$1" auto_yes="$2" model="$3" prov="vllm" model_state=""
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
  if [[ -n "$model" ]]; then
    model_state=$(workspace_model_state "$model")
    if [[ "$model_state" == *"running"* ]] \
        && { ! workspace_model_tool_calling_ready "$model" || ! workspace_model_context_ready "$model"; }; then
      if [[ "$check_only" == "1" ]]; then
        setup_fail "Hermes model needs automatic tool calling and at least ${WORKSPACE_HERMES_MIN_CONTEXT} context: $model"
      else
        info "Restarting ${model} with Hermes tool calling and ${WORKSPACE_HERMES_MIN_CONTEXT} context"
        cmd_run "$model" --no-mtp --tools --max-len "$WORKSPACE_HERMES_MIN_CONTEXT" --force
      fi
    elif [[ "$model_state" != *"running"* ]]; then
      if [[ "$check_only" == "1" ]]; then
        setup_fail "Model not running for Hermes: $model"
      elif [[ "$auto_yes" == "1" ]] || confirm "Start ${model} now with spark run?"; then
        # Workspace recovery favors a reliable full-context launch. MTP can add enough
        # runtime headroom to exceed unified-memory hosts even when the base model fits.
        cmd_run "$model" --no-mtp --tools --max-len "$WORKSPACE_HERMES_MIN_CONTEXT"
      else
        setup_fail "Hermes model not started: $model"
      fi
    fi
  fi
}

workspace_prepare_data_dirs() {
  local dir os owner group
  os=$(uname -s 2>/dev/null || true)
  if [[ "$os" == "Darwin" ]]; then
    return 0
  fi
  for dir in "${WORKSPACE_DATA_DIR}/vikunja-files" "${WORKSPACE_DATA_DIR}/super-productivity-electron" "${WORKSPACE_DATA_DIR}/n8n"; do
    [[ -d "$dir" ]] || continue
    owner=$(stat -c '%u' "$dir" 2>/dev/null || true)
    group=$(stat -c '%g' "$dir" 2>/dev/null || true)
    [[ "$owner" == "1000" && "$group" == "1000" ]] && continue
    if [[ "$(id -u)" == "0" ]]; then
      chown -R 1000:1000 "$dir" 2>/dev/null || warn "Could not chown ${dir} to 1000:1000"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo chown -R 1000:1000 "$dir" 2>/dev/null || warn "Could not sudo chown ${dir} to 1000:1000"
    else
      warn "Workspace data dir may need permissions: sudo chown -R 1000:1000 ${dir}"
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

workspace_url_host() {
  local url="${1:-}"
  url="${url#*://}"
  url="${url%%/*}"
  printf '%s\n' "${url%%:*}"
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

workspace_write_supersync_build() {
  mkdir -p "$WORKSPACE_SUPERSYNC_DIR"
  workspace_install_file "${WORKSPACE_SUPERSYNC_DIR}/spark-initial-passkey.patch" 600 <<'PATCH'
diff --git a/packages/super-sync-server/src/passkey.ts b/packages/super-sync-server/src/passkey.ts
--- a/packages/super-sync-server/src/passkey.ts
+++ b/packages/super-sync-server/src/passkey.ts
@@ -591,0 +592,3 @@ export const completePasskeyRecovery = async (
+    const existingPasskeyCount = await tx.passkey.count({
+      where: { userId: user.id },
+    });
@@ -604 +607,6 @@ export const completePasskeyRecovery = async (
-        tokenVersion: { increment: 1 },
+        // Spark provisions the first access token before passkey enrollment.
+        // Preserve it only for the initial zero-passkey enrollment; real recovery
+        // still invalidates every existing session.
+        ...(existingPasskeyCount === 0
+          ? {}
+          : { tokenVersion: { increment: 1 } }),
PATCH
  workspace_install_file "${WORKSPACE_SUPERSYNC_DIR}/Dockerfile" 600 <<'EOF'
FROM node:24-alpine AS builder

ARG SUPER_PRODUCTIVITY_VERSION=v18.15.1
ARG SUPER_PRODUCTIVITY_COMMIT=014b789c22c9bf75fd7202845639569b61e7cd8e
WORKDIR /repo
RUN apk add --no-cache git openssl libc6-compat \
    && git config --global url."https://github.com/".insteadOf ssh://git@github.com/ \
    && git clone --depth 1 --branch "${SUPER_PRODUCTIVITY_VERSION}" \
      https://github.com/super-productivity/super-productivity.git . \
    && test "$(git rev-parse HEAD)" = "${SUPER_PRODUCTIVITY_COMMIT}"
COPY spark-initial-passkey.patch /tmp/spark-initial-passkey.patch
RUN git apply --check --unidiff-zero /tmp/spark-initial-passkey.patch \
    && git apply --unidiff-zero /tmp/spark-initial-passkey.patch
RUN (npm ci --ignore-scripts || npm install --ignore-scripts)
WORKDIR /repo/packages/sync-core
RUN npm run build && npm pack
WORKDIR /repo/packages/shared-schema
RUN npm run build && npm pack
WORKDIR /repo/packages/super-sync-server
RUN npx prisma generate && rm -rf dist && npm run build

FROM node:24-alpine
ARG SUPER_PRODUCTIVITY_COMMIT=014b789c22c9bf75fd7202845639569b61e7cd8e
LABEL org.opencontainers.image.revision="${SUPER_PRODUCTIVITY_COMMIT}"
RUN apk add --no-cache openssl libc6-compat wget \
    && addgroup -g 1001 -S nodejs \
    && adduser -S supersync -u 1001 -G nodejs \
    && mkdir -p /app/data && chown supersync:nodejs /app /app/data
WORKDIR /app
COPY --from=builder --chown=supersync:nodejs /repo/packages/super-sync-server/dist ./dist
COPY --from=builder --chown=supersync:nodejs /repo/packages/super-sync-server/public ./public
COPY --from=builder --chown=supersync:nodejs /repo/packages/super-sync-server/prisma ./prisma
COPY --from=builder --chown=supersync:nodejs /repo/packages/super-sync-server/scripts ./scripts
COPY --from=builder --chown=supersync:nodejs /repo/packages/super-sync-server/src ./src
COPY --from=builder --chown=supersync:nodejs /repo/packages/super-sync-server/package.json ./package.json
COPY --from=builder --chown=supersync:nodejs /repo/packages/sync-core/sp-sync-core-*.tgz ./sync-core.tgz
COPY --from=builder --chown=supersync:nodejs /repo/packages/shared-schema/sp-shared-schema-*.tgz ./shared-schema.tgz
RUN npm install ./sync-core.tgz ./shared-schema.tgz --ignore-scripts --omit=dev \
    && npm install --ignore-scripts --omit=dev \
    && npm install prisma@5.22.0 --ignore-scripts --omit=dev \
    && npx prisma generate \
    && rm -f sync-core.tgz shared-schema.tgz \
    && npm cache clean --force
USER supersync
EXPOSE 1900
ENV NODE_ENV=production PORT=1900 DATA_DIR=/app/data \
    RUN_MIGRATIONS_ON_STARTUP=false NODE_OPTIONS=--max-old-space-size=576
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:${PORT}/health || exit 1
CMD ["sh", "-c", "if [ \"${RUN_MIGRATIONS_ON_STARTUP:-false}\" = \"true\" ]; then sh scripts/migrate-deploy.sh || exit 1; fi; exec node dist/src/index.js"]
EOF
}

workspace_write_super_productivity_electron_build() {
  mkdir -p "$WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_DIR"
  workspace_install_file "${WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_DIR}/Dockerfile" 600 <<'EOF'
FROM node:22-bookworm AS build

ARG SUPER_PRODUCTIVITY_VERSION=v18.15.1
ARG SUPER_PRODUCTIVITY_COMMIT=014b789c22c9bf75fd7202845639569b61e7cd8e
ARG TARGETARCH
ENV SP_SKIP_WAYLAND_IDLE_HELPER_BUILD=1
WORKDIR /src

RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && git config --global url."https://github.com/".insteadOf ssh://git@github.com/ \
    && git clone --depth 1 --branch "${SUPER_PRODUCTIVITY_VERSION}" \
      https://github.com/super-productivity/super-productivity.git app \
    && test "$(git -C app rev-parse HEAD)" = "${SUPER_PRODUCTIVITY_COMMIT}"
WORKDIR /src/app
COPY spark-headless.patch /tmp/spark-headless.patch
RUN git apply --unidiff-zero --check /tmp/spark-headless.patch \
    && git apply --unidiff-zero /tmp/spark-headless.patch
RUN (npm ci --ignore-scripts || npm install --ignore-scripts) \
    && npm run prepare
RUN npm run buildFrontend:prod:es6 && npm run electron:build \
    && case "${TARGETARCH}" in arm64) arch=arm64 ;; amd64) arch=x64 ;; *) exit 1 ;; esac \
    && npx electron-builder --linux dir --publish never "--${arch}"

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl dumb-init xvfb xauth socat \
      libasound2 libatk-bridge2.0-0 libatk1.0-0 libcairo2 libcups2 libdbus-1-3 \
      libdrm2 libgbm1 libglib2.0-0 libgtk-3-0 libnss3 libpango-1.0-0 \
      libx11-6 libx11-xcb1 libxcb1 libxcomposite1 libxdamage1 libxext6 \
      libxfixes3 libxkbcommon0 libxrandr2 libxshmfence1 libxss1 libxtst6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --uid 1000 --create-home --shell /bin/sh spark
COPY --from=build /src/app/.tmp/app-builds/linux-*unpacked /opt/super-productivity
COPY entrypoint.sh /usr/local/bin/super-productivity-headless
RUN chmod 755 /usr/local/bin/super-productivity-headless \
    && mkdir -p /data && chown -R spark:spark /data
USER spark
VOLUME ["/data"]
EXPOSE 3877
ENTRYPOINT ["/usr/bin/dumb-init", "--", "/usr/local/bin/super-productivity-headless"]
EOF
  workspace_install_file "${WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_DIR}/entrypoint.sh" 700 <<'EOF'
#!/bin/sh
set -eu

socat TCP-LISTEN:3877,reuseaddr,fork TCP:127.0.0.1:3876 &
socat_pid=$!

xvfb-run --auto-servernum --server-args="-screen 0 1280x720x24" \
  /opt/super-productivity/superproductivity \
  --user-data-dir=/data \
  --no-sandbox \
  --disable-gpu \
  --disable-dev-shm-usage &
app_pid=$!

stop() {
  kill "$app_pid" "$socat_pid" 2>/dev/null || true
}
trap stop INT TERM EXIT
wait "$app_pid"
EOF
  workspace_install_file "${WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_DIR}/spark-headless.patch" 600 <<'EOF'
diff --git a/electron/electronAPI.d.ts b/electron/electronAPI.d.ts
--- a/electron/electronAPI.d.ts
+++ b/electron/electronAPI.d.ts
@@ -27,0 +28,7 @@ export interface ElectronAPI {
+  getSparkBootstrapConfig(): {
+    enabled: boolean;
+    baseUrl: string;
+    accessToken: string;
+    encryptionPassword: string;
+  };
+
diff --git a/electron/preload.ts b/electron/preload.ts
--- a/electron/preload.ts
+++ b/electron/preload.ts
@@ -34,0 +35,6 @@ const ea: ElectronAPI = {
+  getSparkBootstrapConfig: () => ({
+    enabled: process.env.SPARK_HEADLESS === '1',
+    baseUrl: process.env.SUPERSYNC_INTERNAL_URL || '',
+    accessToken: process.env.SUPERSYNC_ACCESS_TOKEN || '',
+    encryptionPassword: process.env.SUPERSYNC_ENCRYPTION_PASSWORD || '',
+  }),
diff --git a/src/app/core/startup/startup.service.ts b/src/app/core/startup/startup.service.ts
--- a/src/app/core/startup/startup.service.ts
+++ b/src/app/core/startup/startup.service.ts
@@ -24 +24 @@ import { LS } from '../persistence/storage-keys.const';
-import { combineLatest } from 'rxjs';
+import { combineLatest, firstValueFrom } from 'rxjs';
@@ -39,0 +40 @@ import { JiraElectronBridgeService } from '../../features/issue/providers/jira/jira-electron-bridge.service';
+import { SyncProviderManager } from '../../op-log/sync-providers/provider-manager.service';
@@ -80,0 +82 @@ export class StartupService {
+  private _syncProviderManager = inject(SyncProviderManager);
@@ -188,0 +191 @@ export class StartupService {
+      this._applySparkBootstrapAfterDataLoad();
@@ -219,0 +223,51 @@ export class StartupService {
+  private _applySparkBootstrapAfterDataLoad(): void {
+    const bootstrap = window.ea.getSparkBootstrapConfig();
+    if (
+      !bootstrap.enabled ||
+      !bootstrap.baseUrl ||
+      !bootstrap.accessToken ||
+      !bootstrap.encryptionPassword
+    ) {
+      return;
+    }
+
+    this._dataInitStateService.isAllDataLoadedInitially$.pipe(take(1)).subscribe({
+      next: async () => {
+        try {
+          const providerId = SyncProviderId.SuperSync;
+          const existingProviderCfg =
+            (await this._syncProviderManager.getProviderConfig(providerId)) ?? {};
+          await this._syncProviderManager.setProviderConfig(providerId, {
+            ...existingProviderCfg,
+            baseUrl: bootstrap.baseUrl,
+            accessToken: bootstrap.accessToken,
+            encryptKey: bootstrap.encryptionPassword,
+            isEncryptionEnabled: true,
+          });
+
+          const currentSyncCfg = await firstValueFrom(
+            this._globalConfigService.sync$.pipe(take(1)),
+          );
+          this._globalConfigService.updateSection(
+            'misc',
+            { isLocalRestApiEnabled: true },
+            true,
+          );
+          this._globalConfigService.updateSection(
+            'sync',
+            {
+              ...currentSyncCfg,
+              isEnabled: true,
+              syncProvider: providerId,
+              isEncryptionEnabled: true,
+            },
+            true,
+          );
+          window.setTimeout(() => void this._syncWrapperService.sync(), 1500);
+        } catch (error) {
+          Log.err({ stage: 'spark-headless-bootstrap', error });
+        }
+      },
+    });
+  }
+
diff --git a/src/app/core/electron/local-rest-api-handler.service.ts b/src/app/core/electron/local-rest-api-handler.service.ts
--- a/src/app/core/electron/local-rest-api-handler.service.ts
+++ b/src/app/core/electron/local-rest-api-handler.service.ts
@@ -10,0 +11 @@ import { DateService } from '../date/date.service';
+import { SyncWrapperService } from '../../imex/sync/sync-wrapper.service';
@@ -180,0 +182 @@ export class LocalRestApiHandlerService {
+  private readonly _syncWrapperService = inject(SyncWrapperService);
@@ -219,0 +222,4 @@ export class LocalRestApiHandlerService {
+
+    if (method === 'POST' && path === '/sync') {
+      return this._handleSync(requestId);
+    }
@@ -269,0 +276,10 @@ export class LocalRestApiHandlerService {
+
+  private async _handleSync(
+    requestId: string,
+  ): Promise<LocalRestApiResponsePayload> {
+    const syncResult = await this._syncWrapperService.sync(true);
+    return createSuccessResponse(requestId, 200, {
+      synced: syncResult !== 'HANDLED_ERROR',
+      result: syncResult,
+    });
+  }

EOF
}

workspace_postgres_volume_target() {
  if [[ -f "${WORKSPACE_DATA_DIR}/postgres/PG_VERSION" ]]; then
    printf '%s\n' /var/lib/postgresql/data
  else
    printf '%s\n' /var/lib/postgresql
  fi
}

workspace_write_files_vikunja() {
  local tailnet="$1" human_user="$2" human_email="$3" human_pass="$4" n8n_email="$5" n8n_pass="$6" model="$7"
  local vikunja_url n8n_url hermes_url n8n_host n8n_protocol n8n_secure_cookie litellm_model
  local tailscale_bind_addr tailscale_dns_name
  local postgres_pass vikunja_db_pass vikunja_secret n8n_db_pass n8n_key mention_secret
  local n8n_owner_status n8n_hermes_folder_id n8n_hermes_folder_status vikunja_token tailscale_mode
  local vikunja_api_status vikunja_human_id vikunja_bot_id vikunja_project_access_status
  local vikunja_human_status vikunja_bot_status vikunja_human_admin_status
  local postgres_image postgres_volume_target vikunja_image n8n_image old_umask
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
      vikunja_url=$(workspace_url_for "$WORKSPACE_TASK_MANAGER_SERVICE" "$tailnet" "$WORKSPACE_VIKUNJA_PORT")
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
  vikunja_secret=$(workspace_vikunja_service_secret) \
    || { setup_fail "Missing Vikunja service secret (VIKUNJA_SERVICE_SECRET) while existing workspace data is present; restore it before rerun"; return 1; }
  n8n_db_pass=$(workspace_env_or_generated DB_POSTGRESDB_PASSWORD)
  n8n_key=$(workspace_env_or_generated_guarded N8N_ENCRYPTION_KEY "${WORKSPACE_DATA_DIR}/postgres" "${WORKSPACE_DATA_DIR}/n8n") \
    || { setup_fail "Missing n8n encryption key (N8N_ENCRYPTION_KEY) while existing workspace data is present; restore it before rerun"; return 1; }
  n8n_owner_status=$(workspace_env_or_value N8N_OWNER_SETUP_STATUS pending)
  n8n_hermes_folder_id=$(workspace_read_env N8N_HERMES_FOLDER_ID 2>/dev/null || true)
  n8n_hermes_folder_status=$(workspace_env_or_value N8N_HERMES_FOLDER_STATUS pending)
  mention_secret=$(workspace_env_or_generated WORKSPACE_MENTION_SECRET)
  vikunja_token=$(workspace_read_env VIKUNJA_HERMES_API_TOKEN 2>/dev/null || true)
  vikunja_api_status=$(workspace_env_or_value VIKUNJA_HERMES_API_STATUS pending)
  vikunja_human_id=$(workspace_read_env VIKUNJA_HUMAN_USER_ID 2>/dev/null || true)
  vikunja_bot_id=$(workspace_read_env VIKUNJA_HERMES_BOT_ID 2>/dev/null || true)
  vikunja_project_access_status=$(workspace_env_or_value VIKUNJA_HERMES_PROJECT_ACCESS_STATUS pending)
  vikunja_human_status=$(workspace_env_or_value VIKUNJA_HUMAN_USER_STATUS pending)
  vikunja_bot_status=$(workspace_env_or_value VIKUNJA_HERMES_BOT_STATUS pending)
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
  workspace_require_env_value "n8n admin email" "$n8n_email"
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
  postgres_volume_target=$(workspace_postgres_volume_target)
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
WORKSPACE_TASK_MANAGER=vikunja
POSTGRES_DB=workspace
POSTGRES_USER=workspace
POSTGRES_PASSWORD=${postgres_pass}
VIKUNJA_DATABASE_PASSWORD=${vikunja_db_pass}
VIKUNJA_SERVICE_SECRET=${vikunja_secret}
VIKUNJA_HUMAN_USERNAME=${human_user}
VIKUNJA_HUMAN_EMAIL=${human_email}
VIKUNJA_HUMAN_USER_ID=${vikunja_human_id}
VIKUNJA_HUMAN_USER_STATUS=${vikunja_human_status}
VIKUNJA_HUMAN_ADMIN_STATUS=${vikunja_human_admin_status}
VIKUNJA_HERMES_BOT_USERNAME=${WORKSPACE_VIKUNJA_HERMES_BOT_USERNAME}
VIKUNJA_HERMES_BOT_ID=${vikunja_bot_id}
VIKUNJA_HERMES_BOT_STATUS=${vikunja_bot_status}
VIKUNJA_HERMES_PROJECT_ACCESS_STATUS=${vikunja_project_access_status}
DB_POSTGRESDB_PASSWORD=${n8n_db_pass}
N8N_ENCRYPTION_KEY=${n8n_key}
N8N_BASIC_AUTH_USER=${n8n_email}
N8N_OWNER_FIRST_NAME=${human_user}
N8N_OWNER_LAST_NAME=Spark
N8N_OWNER_SETUP_STATUS=${n8n_owner_status}
N8N_HERMES_FOLDER_ID=${n8n_hermes_folder_id}
N8N_HERMES_FOLDER_STATUS=${n8n_hermes_folder_status}
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
TASK_MANAGER_URL=${vikunja_url}
N8N_URL=${n8n_url}
HERMES_URL=${hermes_url}
HERMES_DASHBOARD_PORT=${WORKSPACE_HERMES_PORT}
HERMES_MODEL=${model}
HERMES_LITELLM_MODEL=${litellm_model}
HERMES_LITELLM_BASE_URL=http://host.openshell.internal:${GATEWAY_PORT}/v1
HERMES_CONTEXT_LENGTH=${WORKSPACE_HERMES_MIN_CONTEXT}
HERMES_MAX_TOKENS=${WORKSPACE_HERMES_MAX_TOKENS_DEFAULT}
HERMES_REASONING_EFFORT=${WORKSPACE_HERMES_REASONING_EFFORT_DEFAULT}
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
  workspace_install_file "${WORKSPACE_CONFIG_DIR}/init-db.sh" 644 <<'EOF'
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
    container_name: ${WORKSPACE_POSTGRES_CONTAINER}
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
      - ${WORKSPACE_DATA_DIR}/postgres:${postgres_volume_target}
      - ${WORKSPACE_CONFIG_DIR}/init-db.sh:/docker-entrypoint-initdb.d/init-db.sh:ro

  vikunja:
    image: ${vikunja_image}
    container_name: ${WORKSPACE_VIKUNJA_CONTAINER}
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
    container_name: ${WORKSPACE_N8N_CONTAINER}
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
  info "Stored technical workspace secrets locally with 0600 permissions"
  info "Workspace access restricted to Tailscale/private bindings"
}

workspace_write_files_super_productivity() {
  local tailnet="$1" human_user="$2" human_email="$3" _human_pass="$4" n8n_email="$5" n8n_pass="$6" model="$7"
  local task_url n8n_url hermes_url n8n_host n8n_protocol n8n_secure_cookie litellm_model
  local tailscale_bind_addr tailscale_dns_name tailscale_mode
  local postgres_pass postgres_volume_target supersync_db_pass supersync_jwt supersync_token supersync_encryption n8n_db_pass n8n_key mention_secret
  local n8n_owner_status n8n_hermes_folder_id n8n_hermes_folder_status browser_sync_status browser_sync_url postgres_image supersync_image electron_version electron_commit electron_image n8n_image rp_id old_umask

  tailscale_mode="${SPARK_WORKSPACE_TAILSCALE_MODE:-$(workspace_env_or_value WORKSPACE_TAILSCALE_MODE pending)}"
  tailscale_bind_addr=$(workspace_env_or_value WORKSPACE_TAILSCALE_BIND_ADDR 127.0.0.1)
  tailscale_dns_name=$(workspace_read_env WORKSPACE_TAILSCALE_DNS_NAME 2>/dev/null || true)
  if [[ "$tailscale_mode" == "ports" ]]; then
    tailscale_dns_name=$(workspace_tailscale_dns_name 2>/dev/null || true)
    tailscale_bind_addr=$(workspace_tailscale_ipv4 2>/dev/null || true)
    if [[ -n "$tailscale_dns_name" && -n "$tailscale_bind_addr" ]]; then
      task_url="http://${tailscale_dns_name}:${WORKSPACE_TASK_MANAGER_PORT}"
      n8n_url="http://${tailscale_dns_name}:${WORKSPACE_N8N_PORT}"
      hermes_url="http://${tailscale_dns_name}:${WORKSPACE_HERMES_PORT}"
    else
      tailscale_mode=manual
      tailscale_bind_addr=127.0.0.1
      setup_fail "Tailscale MagicDNS/IPv4 not detected for ports fallback"
      task_url=""
      n8n_url=""
      hermes_url=""
    fi
  elif [[ -n "$tailnet" ]]; then
    tailscale_bind_addr=127.0.0.1
    task_url=$(workspace_url_for "$WORKSPACE_TASK_MANAGER_SERVICE" "$tailnet")
    n8n_url=$(workspace_url_for n8n "$tailnet")
    hermes_url=$(workspace_url_for hermes "$tailnet")
  else
    tailscale_mode=manual
    tailscale_bind_addr=127.0.0.1
    setup_fail "Tailscale tailnet DNS suffix not detected; workspace requires Tailscale Services or ports mode"
    task_url=""
    n8n_url=""
    hermes_url=""
  fi

  litellm_model=$(workspace_litellm_model_name "$model")
  workspace_backup_invalid_env_file "$WORKSPACE_ENV_FILE"
  workspace_backup_invalid_env_file "$WORKSPACE_POSTGRES_ENV_FILE"
  workspace_backup_invalid_env_file "$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE"
  workspace_backup_invalid_env_file "$WORKSPACE_N8N_ENV_FILE"
  postgres_pass=$(workspace_env_or_generated_guarded POSTGRES_PASSWORD "${WORKSPACE_DATA_DIR}/postgres") \
    || { setup_fail "Missing Postgres password while existing workspace data is present; restore it before rerun"; return 1; }
  supersync_db_pass=$(workspace_env_or_random_password SUPERSYNC_DATABASE_PASSWORD)
  supersync_jwt=$(workspace_env_or_generated_guarded SUPERSYNC_JWT_SECRET "${WORKSPACE_DATA_DIR}/super-productivity-electron") \
    || { setup_fail "Missing SuperSync JWT secret while Electron data exists; restore it before rerun"; return 1; }
  supersync_token=$(workspace_read_env SUPERSYNC_ACCESS_TOKEN 2>/dev/null || true)
  supersync_encryption=$(workspace_read_env SUPERSYNC_ENCRYPTION_PASSWORD 2>/dev/null || true)
  [[ -n "$supersync_encryption" ]] || supersync_encryption=$(workspace_random_password)
  n8n_db_pass=$(workspace_env_or_generated DB_POSTGRESDB_PASSWORD)
  n8n_key=$(workspace_env_or_generated_guarded N8N_ENCRYPTION_KEY "${WORKSPACE_DATA_DIR}/postgres" "${WORKSPACE_DATA_DIR}/n8n") \
    || { setup_fail "Missing n8n encryption key while existing workspace data is present; restore it before rerun"; return 1; }
  n8n_owner_status=$(workspace_env_or_value N8N_OWNER_SETUP_STATUS pending)
  n8n_hermes_folder_id=$(workspace_read_env N8N_HERMES_FOLDER_ID 2>/dev/null || true)
  n8n_hermes_folder_status=$(workspace_env_or_value N8N_HERMES_FOLDER_STATUS pending)
  browser_sync_status=$(workspace_env_or_value SUPER_PRODUCTIVITY_BROWSER_SYNC_STATUS pending)
  browser_sync_url=$(workspace_env_or_value SUPER_PRODUCTIVITY_BROWSER_SYNC_URL "")
  mention_secret=$(workspace_env_or_generated WORKSPACE_MENTION_SECRET)
  postgres_image="${SPARK_WORKSPACE_POSTGRES_IMAGE:-$(workspace_env_or_value WORKSPACE_POSTGRES_IMAGE "$WORKSPACE_POSTGRES_IMAGE_DEFAULT")}"
  supersync_image="${SPARK_WORKSPACE_SUPERSYNC_IMAGE:-$(workspace_env_or_value WORKSPACE_SUPERSYNC_IMAGE "$WORKSPACE_SUPERSYNC_IMAGE_DEFAULT")}"
  electron_version="${SPARK_WORKSPACE_SUPER_PRODUCTIVITY_VERSION:-$(workspace_env_or_value WORKSPACE_SUPER_PRODUCTIVITY_VERSION "$WORKSPACE_SUPER_PRODUCTIVITY_VERSION_DEFAULT")}"
  electron_commit="${SPARK_WORKSPACE_SUPER_PRODUCTIVITY_COMMIT:-$(workspace_env_or_value WORKSPACE_SUPER_PRODUCTIVITY_COMMIT "$WORKSPACE_SUPER_PRODUCTIVITY_COMMIT_DEFAULT")}"
  electron_image="${SPARK_WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_IMAGE:-$(workspace_env_or_value WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_IMAGE "spark/super-productivity-electron:${electron_version#v}")}"
  if [[ -z "${SPARK_WORKSPACE_SUPERSYNC_IMAGE:-}" &&
        -z "${SPARK_WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_IMAGE:-}" &&
        -z "${SPARK_WORKSPACE_SUPER_PRODUCTIVITY_VERSION:-}" &&
        -z "${SPARK_WORKSPACE_SUPER_PRODUCTIVITY_COMMIT:-}" &&
        "$supersync_image" == "spark/supersync:18.7.0" &&
        "$electron_image" == "spark/super-productivity-electron:18.7.0" &&
        "$electron_version" == "v18.7.0" &&
        "$electron_commit" == "4212ed4b0d95b3610f565d077966274fd1294831" ]]; then
    supersync_image="$WORKSPACE_SUPERSYNC_IMAGE_DEFAULT"
    electron_version="$WORKSPACE_SUPER_PRODUCTIVITY_VERSION_DEFAULT"
    electron_commit="$WORKSPACE_SUPER_PRODUCTIVITY_COMMIT_DEFAULT"
    electron_image="spark/super-productivity-electron:${electron_version#v}"
    info "Upgraded Spark-managed Super Productivity pins to ${electron_version}"
  fi
  n8n_image="${SPARK_WORKSPACE_N8N_IMAGE:-$(workspace_env_or_value WORKSPACE_N8N_IMAGE "$WORKSPACE_N8N_IMAGE_DEFAULT")}"
  rp_id=$(workspace_url_host "$task_url")

  workspace_validate_image_ref "Postgres image" "$postgres_image"
  workspace_validate_image_ref "SuperSync image" "$supersync_image"
  workspace_validate_image_ref "Super Productivity Electron image" "$electron_image"
  workspace_validate_image_ref "n8n image" "$n8n_image"
  [[ "$electron_version" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || die "Invalid Super Productivity version: ${electron_version}"
  [[ "$electron_commit" =~ ^[0-9a-f]{40}$ ]] || die "Invalid Super Productivity commit: ${electron_commit}"

  if [[ "$tailscale_mode" == "ports" && -n "$tailscale_dns_name" ]]; then
    n8n_host="$tailscale_dns_name"; n8n_protocol=http; n8n_secure_cookie=false
  elif [[ -n "$tailnet" ]]; then
    n8n_host="n8n.${tailnet}"; n8n_protocol=https; n8n_secure_cookie=true
  else
    n8n_host=""; n8n_protocol=http; n8n_secure_cookie=false
  fi

  workspace_require_env_value "Workspace username" "$human_user"
  workspace_require_env_value "Workspace email" "$human_email"
  [[ "$human_email" != *,* ]] || die "Super Productivity user email cannot contain commas"
  workspace_require_env_value "n8n admin email" "$n8n_email"
  workspace_require_env_value "Hermes model" "$model"
  workspace_require_env_value "SuperSync database password" "$supersync_db_pass"
  workspace_require_env_value "SuperSync JWT secret" "$supersync_jwt"
  workspace_require_env_value "SuperSync encryption password" "$supersync_encryption"
  workspace_require_env_value "workspace Tailscale mode" "$tailscale_mode"
  workspace_require_env_value "workspace Tailscale bind address" "$tailscale_bind_addr"
  postgres_volume_target=$(workspace_postgres_volume_target)

  mkdir -p "$WORKSPACE_CONFIG_DIR" "$WORKSPACE_DATA_DIR"/{postgres,n8n,super-productivity-electron,backups}
  chmod 700 "$WORKSPACE_CONFIG_DIR"
  workspace_prepare_data_dirs
  workspace_write_supersync_build
  workspace_write_super_productivity_electron_build
  old_umask=$(umask)
  umask 077
  workspace_install_file "$WORKSPACE_ENV_FILE" 600 <<EOF
WORKSPACE_TASK_MANAGER=super-productivity
POSTGRES_DB=workspace
POSTGRES_USER=workspace
POSTGRES_PASSWORD=${postgres_pass}
SUPERSYNC_DATABASE_PASSWORD=${supersync_db_pass}
SUPERSYNC_JWT_SECRET=${supersync_jwt}
SUPERSYNC_ACCESS_TOKEN=${supersync_token}
SUPERSYNC_ENCRYPTION_PASSWORD=${supersync_encryption}
SUPER_PRODUCTIVITY_BROWSER_SYNC_STATUS=${browser_sync_status}
SUPER_PRODUCTIVITY_BROWSER_SYNC_URL=${browser_sync_url}
SUPER_PRODUCTIVITY_USER_EMAIL=${human_email}
DB_POSTGRESDB_PASSWORD=${n8n_db_pass}
N8N_ENCRYPTION_KEY=${n8n_key}
N8N_BASIC_AUTH_USER=${n8n_email}
N8N_OWNER_FIRST_NAME=${human_user}
N8N_OWNER_LAST_NAME=Spark
N8N_OWNER_SETUP_STATUS=${n8n_owner_status}
N8N_HERMES_FOLDER_ID=${n8n_hermes_folder_id}
N8N_HERMES_FOLDER_STATUS=${n8n_hermes_folder_status}
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
TASK_MANAGER_URL=${task_url}
SUPER_PRODUCTIVITY_URL=${task_url}
N8N_URL=${n8n_url}
HERMES_URL=${hermes_url}
HERMES_DASHBOARD_PORT=${WORKSPACE_HERMES_PORT}
HERMES_MODEL=${model}
HERMES_LITELLM_MODEL=${litellm_model}
HERMES_LITELLM_BASE_URL=http://host.openshell.internal:${GATEWAY_PORT}/v1
HERMES_CONTEXT_LENGTH=${WORKSPACE_HERMES_MIN_CONTEXT}
HERMES_MAX_TOKENS=${WORKSPACE_HERMES_MAX_TOKENS_DEFAULT}
HERMES_REASONING_EFFORT=${WORKSPACE_HERMES_REASONING_EFFORT_DEFAULT}
HERMES_POLICY_TIER=restricted
HERMES_ONBOARD_STATUS=$(workspace_env_or_value HERMES_ONBOARD_STATUS pending)
WORKSPACE_MENTION_SECRET=${mention_secret}
WORKSPACE_TAILSCALE_MODE=${tailscale_mode}
WORKSPACE_TAILSCALE_BIND_ADDR=${tailscale_bind_addr}
WORKSPACE_TAILSCALE_DNS_NAME=${tailscale_dns_name}
WORKSPACE_POSTGRES_IMAGE=${postgres_image}
WORKSPACE_SUPERSYNC_IMAGE=${supersync_image}
WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_IMAGE=${electron_image}
WORKSPACE_SUPER_PRODUCTIVITY_VERSION=${electron_version}
WORKSPACE_SUPER_PRODUCTIVITY_COMMIT=${electron_commit}
WORKSPACE_N8N_IMAGE=${n8n_image}
EOF
  workspace_install_file "$WORKSPACE_POSTGRES_ENV_FILE" 600 <<EOF
POSTGRES_DB=workspace
POSTGRES_USER=workspace
POSTGRES_PASSWORD=${postgres_pass}
SUPERSYNC_DATABASE_PASSWORD=${supersync_db_pass}
DB_POSTGRESDB_PASSWORD=${n8n_db_pass}
EOF
  workspace_install_file "$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE" 600 <<EOF
NODE_ENV=production
PORT=1900
DATABASE_URL=postgresql://supersync:${supersync_db_pass}@postgres:5432/supersync?connection_limit=20&pool_timeout=20
RUN_MIGRATIONS_ON_STARTUP=false
JWT_SECRET=${supersync_jwt}
PUBLIC_URL=${task_url}
CORS_ORIGINS=${task_url},https://app.super-productivity.com
ALLOWED_EMAILS=${human_email}
WEBAUTHN_RP_ID=${rp_id}
WEBAUTHN_RP_NAME=Spark SuperSync
WEBAUTHN_ORIGIN=${task_url}
SPARK_HEADLESS=1
SUPERSYNC_INTERNAL_URL=http://supersync:1900
SUPERSYNC_ACCESS_TOKEN=${supersync_token}
SUPERSYNC_ENCRYPTION_PASSWORD=${supersync_encryption}
EOF
  workspace_install_file "$WORKSPACE_N8N_ENV_FILE" 600 <<EOF
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=${n8n_db_pass}
N8N_ENCRYPTION_KEY=${n8n_key}
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
  workspace_install_file "${WORKSPACE_CONFIG_DIR}/init-db.sh" 644 <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
psql -v ON_ERROR_STOP=1 \
  -v supersync_password="${SUPERSYNC_DATABASE_PASSWORD}" \
  -v n8n_password="${DB_POSTGRESDB_PASSWORD}" \
  --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<'SQL'
SELECT format('CREATE USER supersync WITH PASSWORD %L', :'supersync_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supersync')\gexec
SELECT format('ALTER USER supersync WITH PASSWORD %L', :'supersync_password')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supersync')\gexec
SELECT format('CREATE USER n8n WITH PASSWORD %L', :'n8n_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n')\gexec
SELECT format('ALTER USER n8n WITH PASSWORD %L', :'n8n_password')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n')\gexec
SELECT 'CREATE DATABASE supersync OWNER supersync'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'supersync')\gexec
SELECT 'CREATE DATABASE n8n OWNER n8n'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'n8n')\gexec
ALTER DATABASE supersync OWNER TO supersync;
ALTER DATABASE n8n OWNER TO n8n;
SQL
EOF
  rm -f "${WORKSPACE_CONFIG_DIR}/super-productivity-gateway.conf"
  umask 022
  workspace_install_file "$WORKSPACE_COMPOSE_FILE" 644 <<EOF
services:
  postgres:
    image: ${postgres_image}
    container_name: ${WORKSPACE_POSTGRES_CONTAINER}
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    pids_limit: 512
    security_opt: ["no-new-privileges:true"]
    logging: {driver: json-file, options: {max-size: "10m", max-file: "5"}}
    env_file: [${WORKSPACE_POSTGRES_ENV_FILE}]
    healthcheck:
      test: [CMD-SHELL, "pg_isready -U workspace -d workspace"]
      interval: 10s
      timeout: 5s
      retries: 10
    volumes:
      - ${WORKSPACE_DATA_DIR}/postgres:${postgres_volume_target}
      - ${WORKSPACE_CONFIG_DIR}/init-db.sh:/docker-entrypoint-initdb.d/init-db.sh:ro

  supersync-migrate:
    image: ${supersync_image}
    build:
      context: ${WORKSPACE_SUPERSYNC_DIR}
      args:
        SUPER_PRODUCTIVITY_VERSION: ${electron_version}
        SUPER_PRODUCTIVITY_COMMIT: ${electron_commit}
    profiles: [tools]
    env_file: [${WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE}]
    depends_on:
      postgres: {condition: service_healthy}
    command: [sh, scripts/migrate-deploy.sh]

  supersync:
    image: ${supersync_image}
    build:
      context: ${WORKSPACE_SUPERSYNC_DIR}
      args:
        SUPER_PRODUCTIVITY_VERSION: ${electron_version}
        SUPER_PRODUCTIVITY_COMMIT: ${electron_commit}
    container_name: ${WORKSPACE_SUPERSYNC_CONTAINER}
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    pids_limit: 512
    security_opt: ["no-new-privileges:true"]
    logging: {driver: json-file, options: {max-size: "10m", max-file: "5"}}
    env_file: [${WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE}]
    depends_on:
      postgres: {condition: service_healthy}
    healthcheck:
      test: [CMD, wget, --no-verbose, --tries=1, --spider, "http://localhost:1900/health"]
      interval: 15s
      timeout: 5s
      retries: 10
    ports:
      - "${tailscale_bind_addr}:${WORKSPACE_TASK_MANAGER_PORT}:1900"

  super-productivity-electron:
    image: ${electron_image}
    build:
      context: ${WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_DIR}
      args:
        SUPER_PRODUCTIVITY_VERSION: ${electron_version}
        SUPER_PRODUCTIVITY_COMMIT: ${electron_commit}
    container_name: ${WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_CONTAINER}
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    pids_limit: 1024
    security_opt: ["no-new-privileges:true"]
    logging: {driver: json-file, options: {max-size: "10m", max-file: "5"}}
    env_file: [${WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE}]
    depends_on:
      supersync: {condition: service_healthy}
    ports:
      - "127.0.0.1:${WORKSPACE_SUPER_PRODUCTIVITY_API_PORT}:3877"
    volumes:
      - ${WORKSPACE_DATA_DIR}/super-productivity-electron:/data

  n8n:
    image: ${n8n_image}
    container_name: ${WORKSPACE_N8N_CONTAINER}
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    pids_limit: 512
    security_opt: ["no-new-privileges:true"]
    logging: {driver: json-file, options: {max-size: "10m", max-file: "5"}}
    depends_on:
      postgres: {condition: service_healthy}
    env_file: [${WORKSPACE_N8N_ENV_FILE}]
    ports:
      - "${tailscale_bind_addr}:${WORKSPACE_N8N_PORT}:5678"
    volumes:
      - ${WORKSPACE_DATA_DIR}/n8n:/home/node/.n8n
EOF
  umask "$old_umask"
  info "Super Productivity + SuperSync files reconciled"
  info "Stored technical workspace secrets locally with 0600 permissions"
  info "Task API restricted to localhost and the Hermes private bridge"
}

workspace_write_files_todoist() {
  local tailnet="$1" human_user="$2" human_email="$3" _human_pass="$4" n8n_email="$5" n8n_pass="$6" model="$7"
  local task_url="$WORKSPACE_TODOIST_APP_URL" n8n_url hermes_url n8n_host n8n_protocol n8n_secure_cookie litellm_model
  local tailscale_bind_addr tailscale_dns_name tailscale_mode
  local postgres_pass postgres_volume_target n8n_db_pass n8n_key n8n_owner_status n8n_hermes_folder_id n8n_hermes_folder_status mention_secret
  local postgres_image n8n_image todoist_token old_todoist_token todoist_status old_umask

  tailscale_mode="${SPARK_WORKSPACE_TAILSCALE_MODE:-$(workspace_env_or_value WORKSPACE_TAILSCALE_MODE pending)}"
  tailscale_bind_addr=$(workspace_env_or_value WORKSPACE_TAILSCALE_BIND_ADDR 127.0.0.1)
  tailscale_dns_name=$(workspace_read_env WORKSPACE_TAILSCALE_DNS_NAME 2>/dev/null || true)
  if [[ "$tailscale_mode" == "ports" ]]; then
    tailscale_dns_name=$(workspace_tailscale_dns_name 2>/dev/null || true)
    tailscale_bind_addr=$(workspace_tailscale_ipv4 2>/dev/null || true)
    if [[ -n "$tailscale_dns_name" && -n "$tailscale_bind_addr" ]]; then
      n8n_url="http://${tailscale_dns_name}:${WORKSPACE_N8N_PORT}"
      hermes_url="http://${tailscale_dns_name}:${WORKSPACE_HERMES_PORT}"
    else
      tailscale_mode=manual
      tailscale_bind_addr=127.0.0.1
      setup_fail "Tailscale MagicDNS/IPv4 not detected for ports fallback"
      n8n_url=""
      hermes_url=""
    fi
  elif [[ -n "$tailnet" ]]; then
    tailscale_bind_addr=127.0.0.1
    n8n_url=$(workspace_url_for n8n "$tailnet")
    hermes_url=$(workspace_url_for hermes "$tailnet")
  else
    tailscale_mode=manual
    tailscale_bind_addr=127.0.0.1
    setup_fail "Tailscale tailnet DNS suffix not detected; workspace requires Tailscale Services or ports mode"
    n8n_url=""
    hermes_url=""
  fi

  litellm_model=$(workspace_litellm_model_name "$model")
  workspace_backup_invalid_env_file "$WORKSPACE_ENV_FILE"
  workspace_backup_invalid_env_file "$WORKSPACE_POSTGRES_ENV_FILE"
  workspace_backup_invalid_env_file "$WORKSPACE_N8N_ENV_FILE"
  postgres_pass=$(workspace_env_or_generated_guarded POSTGRES_PASSWORD "${WORKSPACE_DATA_DIR}/postgres") \
    || { setup_fail "Missing Postgres password while existing workspace data is present; restore it before rerun"; return 1; }
  n8n_db_pass=$(workspace_env_or_generated DB_POSTGRESDB_PASSWORD)
  n8n_key=$(workspace_env_or_generated_guarded N8N_ENCRYPTION_KEY "${WORKSPACE_DATA_DIR}/postgres" "${WORKSPACE_DATA_DIR}/n8n") \
    || { setup_fail "Missing n8n encryption key while existing workspace data is present; restore it before rerun"; return 1; }
  n8n_owner_status=$(workspace_env_or_value N8N_OWNER_SETUP_STATUS pending)
  n8n_hermes_folder_id=$(workspace_read_env N8N_HERMES_FOLDER_ID 2>/dev/null || true)
  n8n_hermes_folder_status=$(workspace_env_or_value N8N_HERMES_FOLDER_STATUS pending)
  mention_secret=$(workspace_env_or_generated WORKSPACE_MENTION_SECRET)
  postgres_image="${SPARK_WORKSPACE_POSTGRES_IMAGE:-$(workspace_env_or_value WORKSPACE_POSTGRES_IMAGE "$WORKSPACE_POSTGRES_IMAGE_DEFAULT")}"
  n8n_image="${SPARK_WORKSPACE_N8N_IMAGE:-$(workspace_env_or_value WORKSPACE_N8N_IMAGE "$WORKSPACE_N8N_IMAGE_DEFAULT")}"
  old_todoist_token=$(workspace_read_env TODOIST_API_TOKEN 2>/dev/null || true)
  todoist_token="${SPARK_WORKSPACE_TODOIST_TOKEN:-$old_todoist_token}"
  todoist_status=$(workspace_env_or_value TODOIST_API_STATUS pending)
  [[ -n "$old_todoist_token" && "$todoist_token" == "$old_todoist_token" ]] || todoist_status=pending

  workspace_validate_image_ref "Postgres image" "$postgres_image"
  workspace_validate_image_ref "n8n image" "$n8n_image"
  workspace_require_env_value "Workspace username" "$human_user"
  workspace_require_env_value "Workspace email" "$human_email"
  workspace_require_env_value "n8n admin email" "$n8n_email"
  workspace_require_env_value "Hermes model" "$model"
  workspace_require_env_value "Todoist API token" "$todoist_token"
  workspace_require_env_value "workspace Tailscale mode" "$tailscale_mode"
  workspace_require_env_value "workspace Tailscale bind address" "$tailscale_bind_addr"

  if [[ "$tailscale_mode" == "ports" && -n "$tailscale_dns_name" ]]; then
    n8n_host="$tailscale_dns_name"; n8n_protocol=http; n8n_secure_cookie=false
  elif [[ -n "$tailnet" ]]; then
    n8n_host="n8n.${tailnet}"; n8n_protocol=https; n8n_secure_cookie=true
  else
    n8n_host=""; n8n_protocol=http; n8n_secure_cookie=false
  fi
  postgres_volume_target=$(workspace_postgres_volume_target)

  mkdir -p "$WORKSPACE_CONFIG_DIR" "$WORKSPACE_DATA_DIR"/{postgres,n8n,backups}
  chmod 700 "$WORKSPACE_CONFIG_DIR"
  workspace_prepare_data_dirs
  old_umask=$(umask)
  umask 077
  workspace_install_file "$WORKSPACE_ENV_FILE" 600 <<EOF
WORKSPACE_TASK_MANAGER=todoist
POSTGRES_DB=workspace
POSTGRES_USER=workspace
POSTGRES_PASSWORD=${postgres_pass}
TODOIST_API_URL=${WORKSPACE_TODOIST_API_URL}
TODOIST_URL=${task_url}
TODOIST_API_TOKEN=${todoist_token}
TODOIST_API_STATUS=${todoist_status}
DB_POSTGRESDB_PASSWORD=${n8n_db_pass}
N8N_ENCRYPTION_KEY=${n8n_key}
N8N_BASIC_AUTH_USER=${n8n_email}
N8N_OWNER_FIRST_NAME=${human_user}
N8N_OWNER_LAST_NAME=Spark
N8N_OWNER_SETUP_STATUS=${n8n_owner_status}
N8N_HERMES_FOLDER_ID=${n8n_hermes_folder_id}
N8N_HERMES_FOLDER_STATUS=${n8n_hermes_folder_status}
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
TASK_MANAGER_URL=${task_url}
N8N_URL=${n8n_url}
HERMES_URL=${hermes_url}
HERMES_DASHBOARD_PORT=${WORKSPACE_HERMES_PORT}
HERMES_MODEL=${model}
HERMES_LITELLM_MODEL=${litellm_model}
HERMES_LITELLM_BASE_URL=http://host.openshell.internal:${GATEWAY_PORT}/v1
HERMES_CONTEXT_LENGTH=${WORKSPACE_HERMES_MIN_CONTEXT}
HERMES_MAX_TOKENS=${WORKSPACE_HERMES_MAX_TOKENS_DEFAULT}
HERMES_REASONING_EFFORT=${WORKSPACE_HERMES_REASONING_EFFORT_DEFAULT}
HERMES_POLICY_TIER=restricted
HERMES_ONBOARD_STATUS=$(workspace_env_or_value HERMES_ONBOARD_STATUS pending)
WORKSPACE_MENTION_SECRET=${mention_secret}
WORKSPACE_TAILSCALE_MODE=${tailscale_mode}
WORKSPACE_TAILSCALE_BIND_ADDR=${tailscale_bind_addr}
WORKSPACE_TAILSCALE_DNS_NAME=${tailscale_dns_name}
WORKSPACE_POSTGRES_IMAGE=${postgres_image}
WORKSPACE_N8N_IMAGE=${n8n_image}
EOF
  workspace_install_file "$WORKSPACE_POSTGRES_ENV_FILE" 600 <<EOF
POSTGRES_DB=workspace
POSTGRES_USER=workspace
POSTGRES_PASSWORD=${postgres_pass}
DB_POSTGRESDB_PASSWORD=${n8n_db_pass}
EOF
  workspace_install_file "$WORKSPACE_N8N_ENV_FILE" 600 <<EOF
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=${n8n_db_pass}
N8N_ENCRYPTION_KEY=${n8n_key}
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
  workspace_install_file "${WORKSPACE_CONFIG_DIR}/init-db.sh" 644 <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
psql -v ON_ERROR_STOP=1 \
  -v n8n_password="${DB_POSTGRESDB_PASSWORD}" \
  --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<'SQL'
SELECT format('CREATE USER n8n WITH PASSWORD %L', :'n8n_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n')\gexec
SELECT format('ALTER USER n8n WITH PASSWORD %L', :'n8n_password')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n')\gexec
SELECT 'CREATE DATABASE n8n OWNER n8n'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'n8n')\gexec
ALTER DATABASE n8n OWNER TO n8n;
SQL
EOF
  umask 022
  workspace_install_file "$WORKSPACE_COMPOSE_FILE" 644 <<EOF
services:
  postgres:
    image: ${postgres_image}
    container_name: ${WORKSPACE_POSTGRES_CONTAINER}
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    pids_limit: 512
    security_opt: ["no-new-privileges:true"]
    logging: {driver: json-file, options: {max-size: "10m", max-file: "5"}}
    env_file: [${WORKSPACE_POSTGRES_ENV_FILE}]
    healthcheck:
      test: [CMD-SHELL, "pg_isready -U workspace -d workspace"]
      interval: 10s
      timeout: 5s
      retries: 10
    volumes:
      - ${WORKSPACE_DATA_DIR}/postgres:${postgres_volume_target}
      - ${WORKSPACE_CONFIG_DIR}/init-db.sh:/docker-entrypoint-initdb.d/init-db.sh:ro

  n8n:
    image: ${n8n_image}
    container_name: ${WORKSPACE_N8N_CONTAINER}
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    pids_limit: 512
    security_opt: ["no-new-privileges:true"]
    logging: {driver: json-file, options: {max-size: "10m", max-file: "5"}}
    depends_on:
      postgres: {condition: service_healthy}
    env_file: [${WORKSPACE_N8N_ENV_FILE}]
    ports:
      - "${tailscale_bind_addr}:${WORKSPACE_N8N_PORT}:5678"
    volumes:
      - ${WORKSPACE_DATA_DIR}/n8n:/home/node/.n8n
EOF
  umask "$old_umask"
  info "Todoist + n8n files reconciled"
  info "Stored Todoist token locally with 0600 permissions"
  info "Todoist credential is restricted to the Hermes OpenShell provider"
}

workspace_write_files() {
  case "$(workspace_task_manager)" in
    super-productivity) workspace_write_files_super_productivity "$@" ;;
    todoist) workspace_write_files_todoist "$@" ;;
    *) workspace_write_files_vikunja "$@" ;;
  esac
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

workspace_wait_for_postgres() {
  local i
  for i in {1..60}; do
    workspace_postgres_psql -tAc 'SELECT 1' >/dev/null 2>&1 && return 0
    sleep "${SPARK_WORKSPACE_WAIT_SLEEP:-1}"
  done
  setup_fail "Postgres did not become ready"
  return 1
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
  case "$(workspace_task_manager)" in
    super-productivity) workspace_postgres_ensure_role_db supersync supersync SUPERSYNC_DATABASE_PASSWORD || true ;;
    vikunja) workspace_postgres_ensure_role_db vikunja vikunja VIKUNJA_DATABASE_PASSWORD || true ;;
  esac
  workspace_postgres_ensure_role_db n8n n8n DB_POSTGRESDB_PASSWORD || true
}

workspace_set_env_key_in_file() {
  local file="$1" key="$2" value="$3" tmp old_umask
  workspace_require_env_value "$key" "$value"
  [[ -f "$file" ]] || return 1
  old_umask=$(umask)
  umask 077
  tmp="${file}.tmp"
  awk -v key="$key" -v value="$value" '
    BEGIN { done=0 }
    index($0, key "=") == 1 { if (!done) print key "=" value; done=1; next }
    { print }
    END { if (!done) print key "=" value }
  ' "$file" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$file"
  umask "$old_umask"
}

workspace_supersync_user_record() {
  local email="$1" pass
  pass=$(workspace_read_env SUPERSYNC_DATABASE_PASSWORD 2>/dev/null || true)
  [[ -n "$pass" ]] || return 1
  workspace_compose exec -T -e PGPASSWORD="$pass" postgres \
    psql -v ON_ERROR_STOP=1 -q -U supersync -d supersync -At -F: -v email="$email" <<'SQL'
INSERT INTO users (email, is_verified, terms_accepted_at)
VALUES (lower(:'email'), 1, (extract(epoch from clock_timestamp()) * 1000)::bigint)
ON CONFLICT (email) DO UPDATE SET
  is_verified = 1,
  terms_accepted_at = COALESCE(users.terms_accepted_at, EXCLUDED.terms_accepted_at)
RETURNING id, token_version;
SQL
}

workspace_supersync_passkey_count() {
  local email="$1" pass
  pass=$(workspace_read_env SUPERSYNC_DATABASE_PASSWORD 2>/dev/null || true)
  [[ -n "$email" && -n "$pass" ]] || return 1
  workspace_compose exec -T -e PGPASSWORD="$pass" postgres \
    psql -v ON_ERROR_STOP=1 -q -U supersync -d supersync -At -v email="$email" <<'SQL'
SELECT count(*)
FROM passkeys
WHERE user_id = (
  SELECT id FROM users WHERE email=lower(:'email') AND is_verified=1
);
SQL
}

workspace_supersync_passkey_ready() {
  local email count
  email=$(workspace_read_env SUPER_PRODUCTIVITY_USER_EMAIL 2>/dev/null || true)
  [[ -n "$email" ]] || return 1
  count=$(workspace_supersync_passkey_count "$email" 2>/dev/null || true)
  [[ "$count" =~ ^[1-9][0-9]*$ ]]
}

workspace_supersync_create_passkey_enrollment_url() {
  local email="$1" pass token claimed url
  pass=$(workspace_read_env SUPERSYNC_DATABASE_PASSWORD 2>/dev/null || true)
  [[ -n "$email" && -n "$pass" ]] || return 1
  token=$(workspace_random_hex_token) || return 1
  [[ "$token" =~ ^[0-9a-f]{64}$ ]] || return 1
  claimed=$(
    workspace_compose exec -T -e PGPASSWORD="$pass" postgres \
      psql -v ON_ERROR_STOP=1 -q -U supersync -d supersync -At \
      -v email="$email" -v token="$token" <<'SQL'
WITH claimed AS (
  UPDATE users
  SET passkey_recovery_token=:'token',
      passkey_recovery_token_expires_at=(extract(epoch from clock_timestamp()) * 1000)::bigint + 900000
  WHERE email=lower(:'email')
    AND is_verified=1
    AND NOT EXISTS (SELECT 1 FROM passkeys WHERE user_id=users.id)
  RETURNING id
)
SELECT count(*) FROM claimed;
SQL
  ) || return 1
  [[ "$claimed" == "1" ]] || return 1
  url=$(workspace_task_manager_url)
  [[ "$url" == https://* ]] || return 1
  printf '%s/recover-passkey?token=%s\n' "${url%/}" "$token"
}

workspace_supersync_stored_token_valid() {
  local token="$1" user_id="$2" email="$3" token_version="$4"
  [[ -n "$token" ]] || return 1
  workspace_compose run --rm --no-deps -T \
    -e "SPARK_SUPERSYNC_TOKEN=${token}" \
    -e "SPARK_SUPERSYNC_USER_ID=${user_id}" \
    -e "SPARK_SUPERSYNC_USER_EMAIL=${email}" \
    -e "SPARK_SUPERSYNC_TOKEN_VERSION=${token_version}" \
    supersync node -e '
      const jwt = require("jsonwebtoken");
      const p = jwt.verify(process.env.SPARK_SUPERSYNC_TOKEN, process.env.JWT_SECRET);
      if (Number(p.userId) !== Number(process.env.SPARK_SUPERSYNC_USER_ID) ||
          p.email !== process.env.SPARK_SUPERSYNC_USER_EMAIL ||
          Number(p.tokenVersion) !== Number(process.env.SPARK_SUPERSYNC_TOKEN_VERSION)) process.exit(1);
    ' >/dev/null 2>&1
}

workspace_supersync_mint_token() {
  local user_id="$1" email="$2" token_version="$3"
  workspace_compose run --rm --no-deps -T \
    -e "SPARK_SUPERSYNC_USER_ID=${user_id}" \
    -e "SPARK_SUPERSYNC_USER_EMAIL=${email}" \
    -e "SPARK_SUPERSYNC_TOKEN_VERSION=${token_version}" \
    supersync node -e '
      const jwt = require("jsonwebtoken");
      process.stdout.write(jwt.sign({
        userId: Number(process.env.SPARK_SUPERSYNC_USER_ID),
        email: process.env.SPARK_SUPERSYNC_USER_EMAIL,
        tokenVersion: Number(process.env.SPARK_SUPERSYNC_TOKEN_VERSION),
      }, process.env.JWT_SECRET, { expiresIn: "365d" }));
    ' 2>/dev/null
}

workspace_supersync_schema_exists() {
  local pass out
  pass=$(workspace_read_env SUPERSYNC_DATABASE_PASSWORD 2>/dev/null || true)
  [[ -n "$pass" ]] || return 1
  out=$(workspace_compose exec -T -e PGPASSWORD="$pass" postgres \
    psql -qAt -U supersync -d supersync \
      -c "SELECT COALESCE(to_regclass('public.users')::text, '');" 2>/dev/null || true)
  [[ "$out" == "users" ]]
}

workspace_supersync_bootstrap_schema() {
  workspace_supersync_schema_exists && return 0
  workspace_compose run --rm --no-deps -T supersync \
    npx prisma db push --skip-generate >/dev/null 2>&1 || return 1
  workspace_compose run --rm --no-deps -T supersync sh -c '
    set -eu
    for dir in prisma/migrations/*; do
      [ -d "$dir" ] || continue
      name=${dir##*/}
      npx prisma migrate resolve --rolled-back "$name" >/dev/null 2>&1 || true
      npx prisma migrate resolve --applied "$name" >/dev/null
    done
  ' >/dev/null 2>&1
}

workspace_supersync_reconcile_baseline_migration() {
  local pass state
  workspace_supersync_schema_exists || return 0
  workspace_compose run --rm --no-deps -T supersync \
    test -d prisma/migrations/0_init >/dev/null 2>&1 || return 0
  pass=$(workspace_read_env SUPERSYNC_DATABASE_PASSWORD 2>/dev/null || true)
  [[ -n "$pass" ]] || return 1
  state=$(
    workspace_compose exec -T -e PGPASSWORD="$pass" postgres \
      psql -v ON_ERROR_STOP=1 -qAt -U supersync -d supersync <<'SQL'
SELECT CASE
  WHEN EXISTS (
    SELECT 1 FROM _prisma_migrations
    WHERE migration_name = '0_init'
      AND finished_at IS NOT NULL
      AND rolled_back_at IS NULL
  ) THEN 'applied'
  WHEN EXISTS (
    SELECT 1 FROM _prisma_migrations
    WHERE migration_name <> '0_init'
      AND finished_at IS NOT NULL
      AND rolled_back_at IS NULL
  ) THEN 'legacy'
  ELSE 'unknown'
END;
SQL
  ) || return 1
  case "$state" in
    applied) return 0 ;;
    legacy)
      workspace_compose run --rm --no-deps -T supersync \
        npx prisma migrate resolve --rolled-back 0_init >/dev/null 2>&1 || true
      workspace_compose run --rm --no-deps -T supersync \
        npx prisma migrate resolve --applied 0_init >/dev/null 2>&1 || return 1
      info "Registered the existing SuperSync schema against the 0_init baseline"
      ;;
    *) return 1 ;;
  esac
}

workspace_prepare_super_productivity_runtime() {
  local email record user_id token_version token
  [[ "$(workspace_task_manager)" == "super-productivity" ]] || return 0
  email=$(workspace_read_env SUPER_PRODUCTIVITY_USER_EMAIL 2>/dev/null || true)
  [[ -n "$email" ]] || return 1
  workspace_compose up -d postgres >/dev/null 2>&1 || return 1
  workspace_wait_for_postgres || return 1
  workspace_ensure_postgres_databases
  workspace_compose build supersync >/dev/null 2>&1 \
    || { setup_fail "Could not build the pinned SuperSync image"; return 1; }
  workspace_supersync_bootstrap_schema \
    || { setup_fail "Could not initialize the SuperSync database schema"; return 1; }
  workspace_supersync_reconcile_baseline_migration \
    || { setup_fail "Could not reconcile the SuperSync migration baseline"; return 1; }
  workspace_compose run --rm supersync-migrate >/dev/null 2>&1 \
    || { setup_fail "Could not apply SuperSync database migrations"; return 1; }
  record=$(workspace_supersync_user_record "$email" 2>/dev/null | grep -E '^[1-9][0-9]*:[0-9]+$' | head -1) || {
    setup_fail "Could not provision the SuperSync user"
    return 1
  }
  IFS=: read -r user_id token_version <<EOF
${record}
EOF
  [[ "$user_id" =~ ^[1-9][0-9]*$ && "$token_version" =~ ^[0-9]+$ ]] || {
    setup_fail "Could not resolve the SuperSync user identity"
    return 1
  }
  token=$(workspace_read_env SUPERSYNC_ACCESS_TOKEN 2>/dev/null || true)
  if ! workspace_supersync_stored_token_valid "$token" "$user_id" "$email" "$token_version"; then
    token=$(workspace_supersync_mint_token "$user_id" "$email" "$token_version") || {
      setup_fail "Could not mint the SuperSync access token"
      return 1
    }
    workspace_set_env_key_in_file "$WORKSPACE_ENV_FILE" SUPERSYNC_ACCESS_TOKEN "$token"
    workspace_set_env_key_in_file "$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE" SUPERSYNC_ACCESS_TOKEN "$token"
    workspace_set_env_key_in_file "$WORKSPACE_ENV_FILE" SUPER_PRODUCTIVITY_BROWSER_SYNC_STATUS pending
    workspace_set_env_key_in_file "$WORKSPACE_ENV_FILE" SUPER_PRODUCTIVITY_BROWSER_SYNC_URL ""
    info "SuperSync user and access token provisioned"
  else
    info "SuperSync user already provisioned"
  fi
  if workspace_supersync_passkey_ready; then
    info "SuperSync passkey already enrolled"
  else
    WORKSPACE_SUPERSYNC_PASSKEY_ENROLLMENT_URL=$(workspace_supersync_create_passkey_enrollment_url "$email") || {
      setup_fail "Could not create the initial SuperSync passkey enrollment link"
      return 1
    }
    info "SuperSync passkey enrollment link prepared (valid for 15 minutes)"
  fi
}

workspace_super_productivity_browser_sync_ready() {
  local status verified_url current_url
  status=$(workspace_read_env SUPER_PRODUCTIVITY_BROWSER_SYNC_STATUS 2>/dev/null || true)
  verified_url=$(workspace_read_env SUPER_PRODUCTIVITY_BROWSER_SYNC_URL 2>/dev/null || true)
  current_url=$(workspace_task_manager_url)
  [[ "$status" == "verified" && -n "$current_url" && "$verified_url" == "$current_url" ]]
}

workspace_super_productivity_local_api() {
  local method="$1" path="$2"
  curl -fsS --max-time 15 -X "$method" \
    -H 'Host: 127.0.0.1:3876' \
    "http://127.0.0.1:${WORKSPACE_SUPER_PRODUCTIVITY_API_PORT}${path}"
}

workspace_super_productivity_sync_task_id() {
  local title="$1" response
  response=$(workspace_super_productivity_local_api GET '/tasks?includeDone=true&source=all') || return 1
  jq -r --arg title "$title" '.data[]? | select(.title == $title) | .id' <<< "$response" | head -n 1
}

workspace_wait_for_super_productivity_sync_task() {
  local title="$1" attempt task_id
  for ((attempt = 0; attempt < 15; attempt++)); do
    task_id=$(workspace_super_productivity_sync_task_id "$title" 2>/dev/null || true)
    if [[ -n "$task_id" ]]; then
      printf '%s\n' "$task_id"
      return 0
    fi
    sleep 2
  done
  return 1
}

workspace_delete_super_productivity_sync_task() {
  local task_id="$1"
  workspace_super_productivity_local_api DELETE "/tasks/${task_id}" \
    | jq -e '.ok == true' >/dev/null
}

workspace_trigger_super_productivity_sync() {
  workspace_super_productivity_local_api POST "/sync" \
    | jq -e '.ok == true and .data.synced == true' >/dev/null
}

workspace_wait_for_super_productivity_sync_ready() {
  local attempt
  for ((attempt = 0; attempt < 15; attempt++)); do
    workspace_trigger_super_productivity_sync && return 0
    sleep 2
  done
  return 1
}

workspace_supersync_task_delete_recorded() {
  local task_id="$1" out
  [[ "$task_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  out=$(workspace_compose exec -T \
    -e "PGPASSWORD=$(workspace_read_env SUPERSYNC_DATABASE_PASSWORD)" \
    postgres psql -qAt -U supersync -d supersync \
    -c "SELECT 1 FROM operations WHERE entity_id='${task_id}' AND op_type='DEL' LIMIT 1" \
    2>/dev/null || true)
  [[ "$out" == "1" ]]
}

workspace_wait_for_supersync_task_delete() {
  local task_id="$1" attempt
  for ((attempt = 0; attempt < 15; attempt++)); do
    workspace_supersync_task_delete_recorded "$task_id" && return 0
    workspace_trigger_super_productivity_sync || return 1
    workspace_supersync_task_delete_recorded "$task_id" && return 0
    sleep 2
  done
  return 1
}

workspace_wait_for_supersync_passkey() {
  local attempt
  for ((attempt = 0; attempt < 15; attempt++)); do
    workspace_supersync_passkey_ready && return 0
    sleep 2
  done
  return 1
}

workspace_show_super_productivity_sync_access() {
  local task_url email token encryption link output
  task_url=$(workspace_task_manager_url)
  email=$(workspace_read_env SUPER_PRODUCTIVITY_USER_EMAIL 2>/dev/null || true)
  token=$(workspace_read_env SUPERSYNC_ACCESS_TOKEN 2>/dev/null || true)
  encryption=$(workspace_read_env SUPERSYNC_ENCRYPTION_PASSWORD 2>/dev/null || true)
  link="${WORKSPACE_SUPERSYNC_PASSKEY_ENROLLMENT_URL:-}"
  [[ -n "$task_url" && -n "$email" && -n "$token" && -n "$encryption" ]] || return 1
  command -v less >/dev/null 2>&1 || {
    warn "less is required to show SuperSync secrets without leaving them in terminal history"
    return 1
  }
  output=$(printf "\n  ${YELLOW}${BOLD}Temporary Super Productivity sync access${NC}\n\n  Copy these values now. Press q to close and remove them from the terminal.\n\n  SuperSync\n    server URL:         %s\n    email:              %s\n    access token:       %s\n    encryption key:     %s\n" \
    "$task_url" "$email" "$token" "$encryption")
  if [[ -n "$link" ]]; then
    output+=$(printf "\n  Passkey enrollment link (valid for 15 minutes):\n    %s\n" "$link")
  fi
  output+=$'\n  Use this access token. Do not replace it with a token from a later SuperSync login.\n'
  LESS='' LESSOPEN='' LESSHISTFILE=- less -R <<< "$output"
  unset output token encryption link
}

workspace_complete_super_productivity_browser_sync() {
  local task_url email marker task_id confirmation retry_choice failure
  local needs_passkey=0 needs_sync=0
  [[ "$(workspace_task_manager)" == "super-productivity" ]] || return 0
  workspace_supersync_passkey_ready || needs_passkey=1
  workspace_super_productivity_browser_sync_ready || needs_sync=1
  if [[ "$needs_passkey" == "0" && "$needs_sync" == "0" ]]; then
    info "Super Productivity browser sync already verified"
    return 0
  fi
  if ! is_interactive; then
    setup_fail "Super Productivity browser sync onboarding requires an interactive terminal"
    return 1
  fi
  task_url=$(workspace_task_manager_url)
  email=$(workspace_read_env SUPER_PRODUCTIVITY_USER_EMAIL 2>/dev/null || true)
  if [[ "$needs_passkey" == "1" ]]; then
    WORKSPACE_SUPERSYNC_PASSKEY_ENROLLMENT_URL=$(workspace_supersync_create_passkey_enrollment_url "$email") || {
      setup_fail "Could not refresh the SuperSync passkey enrollment link"
      return 1
    }
  else
    WORKSPACE_SUPERSYNC_PASSKEY_ENROLLMENT_URL=""
  fi
  workspace_show_super_productivity_sync_access || {
    setup_fail "Could not show temporary SuperSync access securely"
    return 1
  }
  if [[ "$needs_passkey" == "1" ]]; then
    printf "\n  Open the passkey enrollment link from the temporary page and create the passkey.\n"
    printf "  Press Enter after SuperSync confirms that the passkey was created: "
    read -r confirmation || {
      setup_fail "SuperSync passkey enrollment was not confirmed"
      return 1
    }
    workspace_wait_for_supersync_passkey || {
      setup_fail "SuperSync passkey was not detected"
      return 1
    }
    info "SuperSync passkey enrolled"
  fi
  if [[ "$needs_sync" == "0" ]]; then
    WORKSPACE_SUPERSYNC_PASSKEY_ENROLLMENT_URL=""
    return 0
  fi

  while true; do
    marker="spark-sync-check-$(workspace_random_hex_token | cut -c1-10)"
    failure=""
    printf "\n  ${BOLD}Connect the browser app to this workspace${NC}\n\n"
    printf "    1. Keep Tailscale connected and open https://app.super-productivity.com.\n"
    printf "    2. Open Settings > Sync and enable syncing.\n"
    printf "    3. Select SuperSync; under Advanced set server URL to:\n       %s\n" "$task_url"
    printf "    4. Paste the access token from the temporary page and save.\n"
    printf "    5. Enter the same encryption key when the mandatory encryption dialog opens.\n"
    printf "    6. If asked which data to keep, choose the browser/local copy only when it contains\n"
    printf "       the tasks you want to upload; otherwise choose the remote copy.\n"
    printf "    7. Run Sync Now, then create this temporary Inbox task exactly:\n\n"
    printf "       ${BOLD}%s${NC}\n\n" "$marker"
    printf "  Press Enter after the browser reports a successful sync: "
    if ! read -r confirmation; then
      failure="Super Productivity browser sync was not confirmed"
    else
      task_id=$(workspace_wait_for_super_productivity_sync_task "$marker" 2>/dev/null || true)
      if [[ -z "$task_id" ]]; then
        failure="The browser verification task did not reach Electron through SuperSync"
      else
        info "Browser-to-Electron SuperSync verified"
        if ! workspace_wait_for_super_productivity_sync_ready; then
          failure="Electron did not finish the inbound SuperSync cycle before verification"
        elif ! workspace_delete_super_productivity_sync_task "$task_id"; then
          failure="Could not remove the temporary sync verification task through Electron"
        elif ! workspace_wait_for_supersync_task_delete "$task_id"; then
          failure="Electron deleted the verification task locally but did not publish the deletion to SuperSync"
          warn "Delete ${marker} manually in the browser if it remains there."
        else
          info "Electron-to-SuperSync deletion verified"
          printf "\n  Run Sync Now in the browser. When the task disappears, type SYNCED.\n"
          printf "  Type RETRY to repeat only this verification: "
          if read -r confirmation && [[ "$confirmation" == "SYNCED" ]]; then
            workspace_set_env_key SUPER_PRODUCTIVITY_BROWSER_SYNC_STATUS verified
            workspace_set_env_key SUPER_PRODUCTIVITY_BROWSER_SYNC_URL "$task_url"
            WORKSPACE_SUPERSYNC_PASSKEY_ENROLLMENT_URL=""
            info "Super Productivity browser sync verified in both directions"
            return 0
          fi
          failure="Electron-to-browser SuperSync was not confirmed"
          if [[ "$confirmation" == "RETRY" ]]; then
            info "Retrying only the browser sync verification"
            continue
          fi
        fi
      fi
    fi

    warn "$failure"
    printf "\n    [1] Retry only the browser sync verification\n"
    printf "    [2] Exit and resume it later\n\n"
    printf "  > "
    read -r retry_choice || retry_choice=2
    case "$retry_choice" in
      1)
        info "Retrying only the browser sync verification"
        ;;
      *)
        WORKSPACE_SETUP_RESUME_HINT="Rerun spark ws setup to resume the Super Productivity browser sync verification; existing services and credentials will be reused."
        setup_fail "$failure"
        WORKSPACE_SUPERSYNC_PASSKEY_ENROLLMENT_URL=""
        return 1
        ;;
    esac
  done
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

workspace_vikunja_user_id() {
  local username="$1" email="$2" out user_id
  out=$(workspace_vikunja_cli user list 2>/dev/null) || return 2
  user_id=$(printf '%s\n' "$out" | sed 's/│/|/g' | awk -v username="$username" -v email="$email" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /\|/ {
      n = split($0, cols, "|")
      if (n >= 5 && trim(cols[3]) == username && trim(cols[4]) == email) {
        id = trim(cols[2])
        if (id ~ /^[0-9]+$/) { print id; exit }
      }
    }
  ')
  [[ "$user_id" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$user_id"
}

workspace_ensure_vikunja_user() {
  local username="$1" email="$2" password="$3" status_key="$4"
  if workspace_vikunja_user_exists "$username" "$email"; then
    workspace_set_env_key "$status_key" exists
    info "Vikunja user exists: ${username}"
    return 0
  fi
  if [[ -z "$password" ]]; then
    workspace_set_env_key "$status_key" manual
    return 1
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
  local human_pass="${1:-}" human_user human_email human_id jwt token bot_id
  workspace_wait_for_vikunja_cli || return 1
  human_user=$(workspace_read_env VIKUNJA_HUMAN_USERNAME)
  human_email=$(workspace_read_env VIKUNJA_HUMAN_EMAIL)
  workspace_ensure_vikunja_user "$human_user" "$human_email" "$human_pass" VIKUNJA_HUMAN_USER_STATUS || true
  human_id=$(workspace_vikunja_user_id "$human_user" "$human_email" 2>/dev/null || true)
  if [[ "$human_id" =~ ^[1-9][0-9]*$ ]]; then
    workspace_set_env_key VIKUNJA_HUMAN_USER_ID "$human_id"
  else
    setup_fail "Could not resolve Vikunja human user ID for ${human_user}"
    return 1
  fi
  workspace_vikunja_cli user set-admin "$human_user" --admin >/dev/null 2>&1 \
    && { workspace_set_env_key VIKUNJA_HUMAN_ADMIN_STATUS enabled; info "Vikunja admin set: ${human_user}"; } \
    || { workspace_set_env_key VIKUNJA_HUMAN_ADMIN_STATUS manual; warn "Could not promote ${human_user}; set admin manually if needed"; }
  if [[ -z "$human_pass" ]]; then
    token=$(workspace_read_env VIKUNJA_HERMES_API_TOKEN 2>/dev/null || true)
    bot_id=$(workspace_read_env VIKUNJA_HERMES_BOT_ID 2>/dev/null || true)
    if [[ -n "$token" ]] \
      && workspace_check_vikunja_token "$token" "$bot_id" >/dev/null 2>&1 \
      && [[ "$(workspace_read_env VIKUNJA_HERMES_BOT_STATUS 2>/dev/null || true)" =~ ^(created|exists)$ ]] \
      && [[ "$(workspace_read_env VIKUNJA_HERMES_PROJECT_ACCESS_STATUS 2>/dev/null || true)" == "verified" ]]; then
      info "Vikunja bot-hermes access already configured"
      return 0
    fi
    if ! is_interactive; then
      warn "Current Vikunja password required; rerun interactively or with --vikunja-password-file"
      return 0
    fi
    human_pass=$(workspace_prompt SPARK_WORKSPACE_VIKUNJA_PASSWORD \
      "Current Vikunja password for ${human_user}" "" 1 text)
  fi
  jwt=$(workspace_vikunja_login_jwt "$human_user" "$human_pass") || {
    token=$(workspace_read_env VIKUNJA_HERMES_API_TOKEN 2>/dev/null || true)
    if [[ -n "$token" ]] && workspace_check_vikunja_token "$token" >/dev/null 2>&1; then
      workspace_set_env_key VIKUNJA_HERMES_BOT_STATUS exists
      workspace_set_env_key VIKUNJA_HERMES_PROJECT_ACCESS_STATUS manual
      warn "Hermes bot token works, but the human password is needed to sync project access"
      return 0
    fi
    workspace_set_env_key VIKUNJA_HERMES_BOT_STATUS manual
    workspace_set_env_key VIKUNJA_HERMES_API_STATUS manual
    warn "Could not authenticate the Vikunja human user; rerun interactively or with --vikunja-password-file"
    return 1
  }
  workspace_ensure_vikunja_hermes_bot "$jwt" || {
    warn "Could not create bot-hermes; Vikunja 2.4.0 or newer is required"
    return 1
  }
  workspace_create_vikunja_hermes_token "$jwt" "$WORKSPACE_VIKUNJA_HERMES_BOT_ID_RESULT" || {
    warn "Could not create the bot-hermes token automatically; check the Vikunja API v2 and rerun setup"
    return 1
  }
  token=$(workspace_read_env VIKUNJA_HERMES_API_TOKEN 2>/dev/null || true)
  workspace_sync_vikunja_hermes_project_access "$jwt" "$token" \
    || warn "Some Vikunja projects could not be shared with bot-hermes"
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

workspace_remove_env_file_key() {
  local file="$1" key="$2" tmp
  [[ -f "$file" ]] || return 0
  tmp="${file}.tmp"
  grep -v "^${key}=" "$file" > "$tmp" || true
  chmod 600 "$tmp"
  mv "$tmp" "$file"
}

workspace_remove_legacy_human_passwords() {
  local file key removed=0
  for file in "$WORKSPACE_ENV_FILE" "$WORKSPACE_VIKUNJA_ENV_FILE" "$WORKSPACE_N8N_ENV_FILE"; do
    [[ -f "$file" ]] || continue
    for key in VIKUNJA_HUMAN_PASSWORD VIKUNJA_HUMAN_RECOVERY_PASSWORD \
      VIKUNJA_HERMES_USERNAME VIKUNJA_HERMES_PASSWORD VIKUNJA_HERMES_USER_STATUS \
      N8N_BASIC_AUTH_PASSWORD; do
      if grep -q "^${key}=" "$file" 2>/dev/null; then
        workspace_remove_env_file_key "$file" "$key"
        removed=1
      fi
    done
  done
  [[ "$removed" == "0" ]] || info "Removed legacy stored interactive-user credentials"
}

workspace_remove_legacy_smtp() {
  local file tmp removed=0
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    if grep -Eq '^(WORKSPACE_SMTP_|VIKUNJA_MAILER_|N8N_SMTP_|N8N_EMAIL_MODE=)' "$file" 2>/dev/null; then
      tmp="${file}.tmp"
      grep -Ev '^(WORKSPACE_SMTP_|VIKUNJA_MAILER_|N8N_SMTP_|N8N_EMAIL_MODE=)' "$file" > "$tmp" || true
      chmod 600 "$tmp"
      mv "$tmp" "$file"
      removed=1
    fi
  done < <(find "$WORKSPACE_CONFIG_DIR" -maxdepth 1 -type f \
    \( -name 'secrets.env' -o -name 'vikunja.env' -o -name 'n8n.env' -o -name '*.env.bak.*' \) \
    -print 2>/dev/null)
  [[ "$removed" == "0" ]] || info "Removed legacy SMTP configuration and credentials"
}

workspace_remove_transient_n8n_owner_config() {
  local key removed=0
  [[ -f "$WORKSPACE_N8N_ENV_FILE" ]] || return 0
  for key in \
    N8N_INSTANCE_OWNER_MANAGED_BY_ENV N8N_INSTANCE_OWNER_EMAIL \
    N8N_INSTANCE_OWNER_FIRST_NAME N8N_INSTANCE_OWNER_LAST_NAME \
    N8N_INSTANCE_OWNER_PASSWORD_HASH; do
    if grep -q "^${key}=" "$WORKSPACE_N8N_ENV_FILE" 2>/dev/null; then
      workspace_remove_env_file_key "$WORKSPACE_N8N_ENV_FILE" "$key"
      removed=1
    fi
  done
  [[ "$removed" == "0" ]] || info "Removed interrupted n8n recovery configuration"
}

workspace_clear_public_urls() {
  workspace_set_env_key WORKSPACE_TAILSCALE_MODE manual
  workspace_set_env_key N8N_URL ""
  workspace_set_env_key HERMES_URL ""
  workspace_set_env_key WORKSPACE_TAILSCALE_BIND_ADDR 127.0.0.1
  if [[ "$(workspace_task_manager)" == "vikunja" ]]; then
    workspace_set_env_key VIKUNJA_URL ""
    workspace_set_env_file_key "$WORKSPACE_VIKUNJA_ENV_FILE" VIKUNJA_SERVICE_PUBLICURL ""
  fi
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
  out=$(printf '%s' "$payload" | curl -fsS --max-time 10 \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -X POST "${base_url}/api/v1/login" \
    --data-binary @- 2>/dev/null) || return 1
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

workspace_vikunja_api_json() {
  local bearer="$1" method="$2" path="$3" payload="${4:-}" base_url
  [[ -n "$bearer" && -n "$method" && -n "$path" ]] || return 1
  base_url=$(workspace_vikunja_api_base_url) || return 1
  if [[ -n "$payload" ]]; then
    printf '%s' "$payload" | curl -fsS --max-time 10 \
      -H "Authorization: Bearer ${bearer}" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json' \
      -X "$method" "${base_url}${path}" \
      --data-binary @- 2>/dev/null
  else
    curl -fsS --max-time 10 \
      -H "Authorization: Bearer ${bearer}" \
      -H 'Accept: application/json' \
      -X "$method" "${base_url}${path}" 2>/dev/null
  fi
}

workspace_ensure_vikunja_hermes_bot() {
  local jwt="$1" out bot_id payload created=0
  command -v jq >/dev/null 2>&1 || return 1
  out=$(workspace_vikunja_api_json "$jwt" GET '/api/v2/user/bots?per_page=1000') || {
    workspace_set_env_key VIKUNJA_HERMES_BOT_STATUS manual
    return 1
  }
  bot_id=$(printf '%s\n' "$out" | jq -r --arg username "$WORKSPACE_VIKUNJA_HERMES_BOT_USERNAME" \
    '.items[]? | select(.username == $username) | .id' 2>/dev/null | head -1)
  if [[ ! "$bot_id" =~ ^[1-9][0-9]*$ ]]; then
    payload=$(printf '{"username":"%s","name":"Hermes"}' \
      "$(workspace_json_escape "$WORKSPACE_VIKUNJA_HERMES_BOT_USERNAME")")
    out=$(workspace_vikunja_api_json "$jwt" POST '/api/v2/user/bots' "$payload") || {
      workspace_set_env_key VIKUNJA_HERMES_BOT_STATUS manual
      return 1
    }
    bot_id=$(printf '%s\n' "$out" | jq -r '.id // empty' 2>/dev/null | head -1)
    [[ "$bot_id" =~ ^[1-9][0-9]*$ ]] || return 1
    created=1
  fi
  workspace_set_env_key VIKUNJA_HERMES_BOT_ID "$bot_id"
  if [[ "$created" == "1" ]]; then
    workspace_set_env_key VIKUNJA_HERMES_BOT_STATUS created
    info "Vikunja bot created: ${WORKSPACE_VIKUNJA_HERMES_BOT_USERNAME}"
  else
    workspace_set_env_key VIKUNJA_HERMES_BOT_STATUS exists
    info "Vikunja bot exists: ${WORKSPACE_VIKUNJA_HERMES_BOT_USERNAME}"
  fi
  WORKSPACE_VIKUNJA_HERMES_BOT_ID_RESULT="$bot_id"
}

workspace_create_vikunja_hermes_token() {
  local jwt="$1" bot_id="$2" existing perms payload out token
  existing=$(workspace_read_env VIKUNJA_HERMES_API_TOKEN 2>/dev/null || true)
  if [[ -n "$existing" ]] && workspace_check_vikunja_token "$existing" "$bot_id" >/dev/null 2>&1; then
    info "Vikunja API token already works for bot-hermes"
    return 0
  fi
  perms=$(workspace_vikunja_api_permissions_json "$jwt")
  payload=$(printf '{"title":"spark-hermes","expires_at":"2099-12-31T23:59:59Z","owner_id":%s,"permissions":%s}' "$bot_id" "$perms")
  out=$(workspace_vikunja_api_json "$jwt" POST '/api/v2/tokens' "$payload") || {
      workspace_set_env_key VIKUNJA_HERMES_API_STATUS manual
      return 1
    }
  token=$(printf '%s\n' "$out" | workspace_json_string_field token)
  if [[ -z "$token" ]]; then
    workspace_set_env_key VIKUNJA_HERMES_API_STATUS manual
    return 1
  fi
  workspace_store_vikunja_token "$token"
  workspace_check_vikunja_token "$token" "$bot_id" >/dev/null 2>&1 || return 1
  info "Vikunja API token created for bot-hermes"
}

workspace_check_vikunja_token() {
  local token="${1:-}" expected_id="${2:-}" expected_owner_id out base_url username user_id owner_id
  [[ -n "$token" ]] || token=$(workspace_read_env VIKUNJA_HERMES_API_TOKEN 2>/dev/null || true)
  [[ -n "$token" ]] || die "No Vikunja Hermes API token stored" "Create it in Vikunja UI, then rerun spark ws setup"
  command -v curl >/dev/null 2>&1 || die "curl missing"
  base_url=$(workspace_vikunja_api_base_url) || return 1
  out=$(curl -fsS --max-time 5 \
    -H "Authorization: Bearer ${token}" \
    -H 'Accept: application/json' \
    "${base_url}/api/v1/user" 2>/dev/null) || {
      workspace_set_env_key VIKUNJA_HERMES_API_STATUS failed
      return 1
    }
  if command -v jq >/dev/null 2>&1; then
    username=$(printf '%s\n' "$out" | jq -r '.username // empty' 2>/dev/null)
    user_id=$(printf '%s\n' "$out" | jq -r '.id // empty' 2>/dev/null)
    owner_id=$(printf '%s\n' "$out" | jq -r '.bot_owner_id // empty' 2>/dev/null)
  else
    username=$(printf '%s\n' "$out" | workspace_json_string_field username)
    user_id=$(printf '%s\n' "$out" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
    owner_id=$(printf '%s\n' "$out" | sed -n 's/.*"bot_owner_id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
  fi
  expected_owner_id=$(workspace_read_env VIKUNJA_HUMAN_USER_ID 2>/dev/null || true)
  if [[ "$username" == "$WORKSPACE_VIKUNJA_HERMES_BOT_USERNAME" && "$user_id" =~ ^[1-9][0-9]*$ && "$owner_id" =~ ^[1-9][0-9]*$ ]] \
    && { [[ -z "$expected_id" ]] || [[ "$user_id" == "$expected_id" ]]; } \
    && { [[ -z "$expected_owner_id" ]] || [[ "$owner_id" == "$expected_owner_id" ]]; }; then
    workspace_set_env_key VIKUNJA_HERMES_BOT_ID "$user_id"
    workspace_set_env_key VIKUNJA_HERMES_API_STATUS verified
    info "Vikunja API token verified for bot-hermes"
    return 0
  fi
  workspace_set_env_key VIKUNJA_HERMES_API_STATUS wrong-user
  warn "Vikunja API token works, but does not belong to bot-hermes"
  return 1
}

workspace_share_vikunja_project_with_hermes() {
  local jwt="$1" project_id="$2" out permission payload path
  path="/api/v2/projects/${project_id}/users"
  out=$(workspace_vikunja_api_json "$jwt" GET "${path}?per_page=1000") || return 1
  permission=$(printf '%s\n' "$out" | jq -r --arg username "$WORKSPACE_VIKUNJA_HERMES_BOT_USERNAME" \
    '.items[]? | select(.username == $username) | .permission' 2>/dev/null | head -1)
  payload=$(printf '{"username":"%s","permission":1}' \
    "$(workspace_json_escape "$WORKSPACE_VIKUNJA_HERMES_BOT_USERNAME")")
  if [[ "$permission" =~ ^[0-9]+$ ]]; then
    [[ "$permission" -ge 1 ]] && return 0
    workspace_vikunja_api_json "$jwt" PUT "${path}/${WORKSPACE_VIKUNJA_HERMES_BOT_USERNAME}" "$payload" >/dev/null
    return $?
  fi
  workspace_vikunja_api_json "$jwt" POST "$path" "$payload" >/dev/null
}

workspace_vikunja_accessible_project_ids() {
  local bearer="$1" out
  out=$(workspace_vikunja_api_json "$bearer" GET '/api/v2/projects?per_page=1000&expand=permissions&is_archived=true') || return 1
  printf '%s\n' "$out" | jq -r '.items[]?.id' 2>/dev/null | sort -u
}

workspace_sync_vikunja_hermes_project_access() {
  local jwt="$1" token="$2" out project_id failed=0 human_ids bot_ids missing
  command -v jq >/dev/null 2>&1 || return 1
  out=$(workspace_vikunja_api_json "$jwt" GET '/api/v2/projects?per_page=1000&expand=permissions&is_archived=true') || {
    workspace_set_env_key VIKUNJA_HERMES_PROJECT_ACCESS_STATUS manual
    return 1
  }
  while IFS= read -r project_id; do
    [[ "$project_id" =~ ^[1-9][0-9]*$ ]] || continue
    workspace_share_vikunja_project_with_hermes "$jwt" "$project_id" || failed=1
  done < <(printf '%s\n' "$out" | jq -r '.items[]? | select(.max_permission == 2) | .id' 2>/dev/null)
  human_ids=$(printf '%s\n' "$out" | jq -r '.items[]?.id' 2>/dev/null | sort -u)
  bot_ids=$(workspace_vikunja_accessible_project_ids "$token") || failed=1
  missing=$(comm -23 <(printf '%s\n' "$human_ids") <(printf '%s\n' "$bot_ids") | sed '/^$/d')
  if [[ "$failed" == "0" && -z "$missing" ]]; then
    workspace_set_env_key VIKUNJA_HERMES_PROJECT_ACCESS_STATUS verified
    info "Vikunja project access synchronized for bot-hermes"
    return 0
  fi
  workspace_set_env_key VIKUNJA_HERMES_PROJECT_ACCESS_STATUS partial
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
  local path="$1" payload="$2" base_url
  base_url=$(workspace_n8n_base_url) || return 1
  printf '%s' "$payload" | curl -fsS --max-time 10 \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    -X POST "${base_url}${path}" \
    --data-binary @- >/dev/null
}

workspace_n8n_login() {
  local email="${1:-}" pass="${2:-}" payload
  [[ -n "$email" && -n "$pass" ]] || return 1
  payload=$(printf '{"emailOrLdapLoginId":"%s","password":"%s"}' "$(workspace_json_escape "$email")" "$(workspace_json_escape "$pass")")
  workspace_n8n_post_json /rest/login "$payload"
}

workspace_create_n8n_owner() {
  local email="${1:-}" pass="${2:-}" first last payload i
  command -v curl >/dev/null 2>&1 || { workspace_set_env_key N8N_OWNER_SETUP_STATUS manual; warn "curl missing; create n8n owner manually"; return 1; }
  first=$(workspace_read_env N8N_OWNER_FIRST_NAME 2>/dev/null || true)
  last=$(workspace_read_env N8N_OWNER_LAST_NAME 2>/dev/null || true)
  [[ -n "$email" && -n "$pass" ]] || { workspace_set_env_key N8N_OWNER_SETUP_STATUS manual; warn "n8n owner credentials missing"; return 1; }
  [[ -n "$first" ]] || first="Spark"
  [[ -n "$last" ]] || last="Admin"

  for i in {1..30}; do
    curl -fsS --max-time 2 "$(workspace_n8n_base_url)/healthz" >/dev/null 2>&1 && break
    sleep 1
  done
  if workspace_n8n_login "$email" "$pass"; then
    workspace_set_env_key N8N_OWNER_SETUP_STATUS exists
    info "n8n owner already works: ${email}"
    return 0
  fi

  payload=$(printf '{"email":"%s","firstName":"%s","lastName":"%s","password":"%s"}' \
    "$(workspace_json_escape "$email")" "$(workspace_json_escape "$first")" \
    "$(workspace_json_escape "$last")" "$(workspace_json_escape "$pass")")
  if workspace_n8n_post_json /rest/owner/setup "$payload"; then
    if workspace_n8n_login "$email" "$pass"; then
      workspace_set_env_key N8N_OWNER_SETUP_STATUS created
      info "n8n owner bootstrapped: ${email}"
      return 0
    fi
    warn "n8n owner setup endpoint returned success, but login is not verified yet"
  fi
  if workspace_n8n_login "$email" "$pass"; then
    workspace_set_env_key N8N_OWNER_SETUP_STATUS exists
    info "n8n owner login verified: ${email}"
    return 0
  fi
  workspace_set_env_key N8N_OWNER_SETUP_STATUS manual
  warn "Could not bootstrap n8n owner automatically; finish first-run setup in the n8n UI"
  return 1
}

workspace_n8n_folders_supported() {
  local license_info
  license_info=$(workspace_compose exec -T n8n n8n license:info 2>/dev/null) || return 2
  grep -Eq '"feat:folders"[[:space:]]*:[[:space:]]*true' <<< "$license_info"
}

workspace_n8n_login_session() {
  local email="$1" pass="$2" cookie_jar="$3" payload base_url
  [[ -n "$email" && -n "$pass" && -n "$cookie_jar" ]] || return 1
  base_url=$(workspace_n8n_base_url) || return 1
  payload=$(printf '{"emailOrLdapLoginId":"%s","password":"%s"}' \
    "$(workspace_json_escape "$email")" "$(workspace_json_escape "$pass")")
  printf '%s' "$payload" | curl -fsS --max-time 10 \
    --cookie-jar "$cookie_jar" --cookie "$cookie_jar" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -X POST "${base_url}/rest/login" --data-binary @- >/dev/null 2>&1
}

workspace_n8n_session_request() {
  local cookie_jar="$1" method="$2" path="$3" response_file="$4" payload="${5:-}" base_url
  base_url=$(workspace_n8n_base_url) || return 1
  if [[ -n "$payload" ]]; then
    printf '%s' "$payload" | curl -sS --max-time 10 \
      --cookie "$cookie_jar" --cookie-jar "$cookie_jar" \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      -X "$method" "${base_url}${path}" --data-binary @- \
      -o "$response_file" -w '%{http_code}' 2>/dev/null
  else
    curl -sS --max-time 10 \
      --cookie "$cookie_jar" --cookie-jar "$cookie_jar" \
      -H 'Accept: application/json' -X "$method" "${base_url}${path}" \
      -o "$response_file" -w '%{http_code}' 2>/dev/null
  fi
}

workspace_n8n_personal_project_id() {
  jq -r 'if ((.data.type // .type) == "personal") then (.data.id // .id // empty) else empty end' "$1" 2>/dev/null
}

workspace_n8n_folder_matches() {
  jq -r --arg name "$WORKSPACE_N8N_HERMES_FOLDER_NAME" '
    (if (.data | type) == "array" then .data
     elif (.data.data | type) == "array" then .data.data
     elif type == "array" then .
     else [] end)
    | [.[] | select(.name == $name and ((.parentFolderId // .parentFolder.id // null) == null))]
    | "\(length)\t\(.[0].id // "")"
  ' "$1" 2>/dev/null
}

workspace_ensure_n8n_hermes_folder() {
  local email="$1" pass="$2" support_rc cookie_jar response_file http personal_project_id matches count folder_id payload
  command -v jq >/dev/null 2>&1 || {
    workspace_set_env_key N8N_HERMES_FOLDER_STATUS manual
    warn "jq missing; cannot reconcile the n8n Hermes folder"
    return 1
  }
  if workspace_n8n_folders_supported; then
    :
  else
    support_rc=$?
    if [[ "$support_rc" -eq 1 ]]; then
      workspace_set_env_key N8N_HERMES_FOLDER_ID ""
      workspace_set_env_key N8N_HERMES_FOLDER_STATUS unsupported
      warn "n8n folders are not available with the active license"
      return 1
    fi
    workspace_set_env_key N8N_HERMES_FOLDER_STATUS manual
    warn "Could not inspect n8n folder capabilities"
    return 1
  fi

  if workspace_n8n_hermes_folder_ready; then
    info "n8n folder exists: Personal / ${WORKSPACE_N8N_HERMES_FOLDER_NAME}"
    return 0
  fi
  [[ -n "$email" && -n "$pass" ]] || {
    workspace_set_env_key N8N_HERMES_FOLDER_STATUS manual
    warn "n8n owner password required to create the Hermes folder; rerun with --n8n-password-file"
    return 1
  }

  cookie_jar=$(mktemp "${TMPDIR:-/tmp}/spark-n8n-cookie.XXXXXX") || return 1
  response_file=$(mktemp "${TMPDIR:-/tmp}/spark-n8n-response.XXXXXX") || {
    rm -f "$cookie_jar"
    return 1
  }
  chmod 600 "$cookie_jar" "$response_file"
  if ! workspace_n8n_login_session "$email" "$pass" "$cookie_jar"; then
    rm -f "$cookie_jar" "$response_file"
    workspace_set_env_key N8N_HERMES_FOLDER_STATUS manual
    warn "Could not authenticate the n8n owner to reconcile the Hermes folder"
    return 1
  fi
  http=$(workspace_n8n_session_request "$cookie_jar" GET '/rest/projects/personal' "$response_file") || http=000
  if [[ "$http" != "200" ]]; then
    rm -f "$cookie_jar" "$response_file"
    workspace_set_env_key N8N_HERMES_FOLDER_STATUS manual
    warn "Could not read the n8n Personal project (HTTP ${http})"
    return 1
  fi
  personal_project_id=$(workspace_n8n_personal_project_id "$response_file") || personal_project_id=""
  if [[ ! "$personal_project_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
    rm -f "$cookie_jar" "$response_file"
    workspace_set_env_key N8N_HERMES_FOLDER_STATUS manual
    warn "Could not identify the n8n Personal project"
    return 1
  fi
  http=$(workspace_n8n_session_request "$cookie_jar" GET "/rest/projects/${personal_project_id}/folders/" "$response_file") || http=000
  if [[ "$http" != "200" ]]; then
    rm -f "$cookie_jar" "$response_file"
    workspace_set_env_key N8N_HERMES_FOLDER_STATUS manual
    warn "Could not list folders in the n8n Personal project (HTTP ${http})"
    return 1
  fi
  matches=$(workspace_n8n_folder_matches "$response_file") || matches=""
  IFS=$'\t' read -r count folder_id <<< "$matches"
  if [[ "$count" == "1" && "$folder_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
    rm -f "$cookie_jar" "$response_file"
    workspace_set_env_key N8N_HERMES_FOLDER_ID "$folder_id"
    workspace_set_env_key N8N_HERMES_FOLDER_STATUS exists
    info "n8n folder exists: Personal / ${WORKSPACE_N8N_HERMES_FOLDER_NAME}"
    return 0
  fi
  if [[ "$count" =~ ^[2-9][0-9]*$ ]]; then
    rm -f "$cookie_jar" "$response_file"
    workspace_set_env_key N8N_HERMES_FOLDER_ID ""
    workspace_set_env_key N8N_HERMES_FOLDER_STATUS duplicate
    warn "Multiple root folders named Hermes exist in n8n Personal; refusing to choose or create another"
    return 1
  fi
  [[ "$count" == "0" ]] || {
    rm -f "$cookie_jar" "$response_file"
    workspace_set_env_key N8N_HERMES_FOLDER_STATUS manual
    warn "Unexpected n8n folder-list response"
    return 1
  }

  payload=$(printf '{"name":"%s"}' "$(workspace_json_escape "$WORKSPACE_N8N_HERMES_FOLDER_NAME")")
  http=$(workspace_n8n_session_request "$cookie_jar" POST "/rest/projects/${personal_project_id}/folders/" "$response_file" "$payload") || http=000
  if [[ "$http" == "200" || "$http" == "201" ]]; then
    folder_id=$(jq -r '.data.id // .id // empty' "$response_file" 2>/dev/null | head -1)
    rm -f "$cookie_jar" "$response_file"
    if [[ "$folder_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
      workspace_set_env_key N8N_HERMES_FOLDER_ID "$folder_id"
      workspace_set_env_key N8N_HERMES_FOLDER_STATUS created
      info "n8n folder created: Personal / ${WORKSPACE_N8N_HERMES_FOLDER_NAME}"
      return 0
    fi
    workspace_set_env_key N8N_HERMES_FOLDER_STATUS manual
    warn "n8n created the Hermes folder but returned no valid folder ID"
    return 1
  fi
  rm -f "$cookie_jar" "$response_file"
  workspace_set_env_key N8N_HERMES_FOLDER_STATUS manual
  warn "Could not create the n8n Hermes folder (HTTP ${http})"
  return 1
}

workspace_configure_tailscale() {
  local tailnet="$1" check_only="$2" funnel_action="${3:-}" auto_yes="${4:-0}" requested_mode bind_addr dns_name json missing missing_summary
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
  json=$(workspace_tailscale_status_json 2>/dev/null || true)
  if [[ -n "$json" ]] && workspace_tailscale_capmap_available "$json"; then
    missing=$(workspace_tailscale_missing_services "$json" || true)
    if [[ -n "$missing" ]]; then
      [[ "$check_only" == "1" ]] || workspace_tailscale_mark_error missing-service
      if [[ "$check_only" != "1" ]] && workspace_tailscale_verify_services_after_hitl "$tailnet" "$missing" "$auto_yes"; then
        workspace_tailscale_clear_error
        json=$(workspace_tailscale_status_json 2>/dev/null || true)
      else
        missing_summary=$(workspace_tailscale_missing_services_summary "$missing")
        [[ "$check_only" == "1" ]] && workspace_tailscale_print_services_hitl "$missing" "$tailnet"
        if [[ "$check_only" != "1" ]] && workspace_tailscale_offer_ports_fallback "$tailnet" "$auto_yes"; then
          return 0
        fi
        [[ "$check_only" == "1" ]] || workspace_clear_public_urls
        setup_fail "Tailscale Services not registered/authorized: ${missing_summary}"
        return 0
      fi
    fi
    if [[ -n "$json" ]] && workspace_tailscale_tag_required_but_missing "$json"; then
      [[ "$check_only" == "1" ]] || workspace_tailscale_mark_error missing-tag
      if [[ "$check_only" != "1" ]] && workspace_tailscale_verify_tag_after_hitl "$auto_yes"; then
        workspace_tailscale_clear_error
      else
        [[ "$check_only" == "1" ]] && workspace_tailscale_print_tag_hitl
        if [[ "$check_only" != "1" ]] && workspace_tailscale_offer_ports_fallback "$tailnet" "$auto_yes"; then
          return 0
        fi
        [[ "$check_only" == "1" ]] || workspace_clear_public_urls
        setup_fail "Tailscale machine is not tagged for Services"
        return 0
      fi
    fi
  fi
  [[ "$check_only" == "1" ]] && return 0
  local status_dir="" vikunja_status="" n8n_status="" hermes_status="" vikunja_log="" n8n_log="" hermes_log="" vikunja_rc="" n8n_rc="" hermes_rc="" out="" ready=0 enable_url="" previous_tail_error=""
  previous_tail_error=$(workspace_read_env WORKSPACE_TAILSCALE_LAST_ERROR 2>/dev/null || true)
  if [[ -n "$previous_tail_error" ]]; then
    out=$(tailscale serve get-config --all 2>/dev/null || tailscale serve status --json 2>/dev/null || tailscale serve status 2>/dev/null || true)
    if workspace_tailscale_services_local_configured_from_output "$out"; then
      workspace_set_env_key WORKSPACE_TAILSCALE_MODE services
      if workspace_tailscale_service_host_advertised; then
        workspace_tailscale_clear_error
        info "Tailscale Services configured"
      else
        workspace_tailscale_mark_error pending-approval
        info "Tailscale Services configured locally"
        workspace_tailscale_print_pending_approval_hitl
        if workspace_tailscale_confirm_step "I approved this host for the Services; verify now?" "$auto_yes"; then
          if workspace_tailscale_wait_for_service_host_advertised; then
            workspace_tailscale_clear_error
            info "Tailscale Service host approval verified"
          else
            setup_fail "Tailscale Service host pending admin approval"
          fi
        else
          setup_fail "Tailscale Service host pending admin approval"
        fi
      fi
      return 0
    fi
  fi
  status_dir=$(mktemp -d)
  vikunja_status="${status_dir}/vikunja.rc"
  n8n_status="${status_dir}/n8n.rc"
  hermes_status="${status_dir}/hermes.rc"
  vikunja_log="${status_dir}/vikunja.log"
  n8n_log="${status_dir}/n8n.log"
  hermes_log="${status_dir}/hermes.log"
  if workspace_task_manager_hosted; then
    workspace_tailscale_serve_launch_bg "svc:${WORKSPACE_TASK_MANAGER_SERVICE}" "http://127.0.0.1:${WORKSPACE_VIKUNJA_PORT}" "$vikunja_status" "$vikunja_log"
  else
    printf '0\n' > "$vikunja_status"
    : > "$vikunja_log"
  fi
  workspace_tailscale_serve_launch_bg "svc:n8n" "http://127.0.0.1:${WORKSPACE_N8N_PORT}" "$n8n_status" "$n8n_log"
  workspace_tailscale_serve_launch_bg "svc:hermes" "http://127.0.0.1:${WORKSPACE_HERMES_TAILSCALE_PROXY_PORT}" "$hermes_status" "$hermes_log"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    if [[ -s "$vikunja_status" && -s "$n8n_status" && -s "$hermes_status" ]]; then
      vikunja_rc=$(cat "$vikunja_status" 2>/dev/null || echo 1)
      n8n_rc=$(cat "$n8n_status" 2>/dev/null || echo 1)
      hermes_rc=$(cat "$hermes_status" 2>/dev/null || echo 1)
      if [[ "$vikunja_rc" != "0" || "$n8n_rc" != "0" || "$hermes_rc" != "0" ]]; then
        if workspace_tailscale_serve_disabled_error "$vikunja_log" "$n8n_log" "$hermes_log"; then
          enable_url=$(workspace_tailscale_serve_enable_url "$vikunja_log" "$n8n_log" "$hermes_log" || true)
          rm -rf "$status_dir"
          workspace_tailscale_mark_error serve-disabled "$enable_url"
          workspace_tailscale_print_serve_disabled_hitl "$enable_url"
          if workspace_tailscale_retry_after_hitl "$tailnet" "$check_only" "$funnel_action" "$auto_yes" "I enabled Tailscale Serve; retry now?"; then
            return 0
          fi
          if workspace_tailscale_offer_ports_fallback "$tailnet" "$auto_yes"; then
            return 0
          fi
          workspace_clear_public_urls
          setup_fail "Tailscale Serve is not enabled"
          return 0
        fi
        if workspace_tailscale_operator_error "$vikunja_log" "$n8n_log" "$hermes_log"; then
          rm -rf "$status_dir"
          workspace_tailscale_mark_error operator-missing
          workspace_tailscale_print_operator_hitl
          if workspace_tailscale_retry_after_hitl "$tailnet" "$check_only" "$funnel_action" "$auto_yes" "I ran sudo tailscale set --operator=\$USER; retry now?"; then
            return 0
          fi
          if workspace_tailscale_offer_ports_fallback "$tailnet" "$auto_yes"; then
            return 0
          fi
          workspace_clear_public_urls
          setup_fail "Tailscale operator permission is not configured"
          return 0
        fi
        if workspace_tailscale_tagged_node_error "$vikunja_log" "$n8n_log" "$hermes_log"; then
          rm -rf "$status_dir"
          workspace_tailscale_mark_error missing-tag
          workspace_tailscale_print_tag_hitl
          if workspace_tailscale_retry_after_hitl "$tailnet" "$check_only" "$funnel_action" "$auto_yes" "I assigned tag:spark to this machine; retry now?"; then
            return 0
          fi
          if workspace_tailscale_offer_ports_fallback "$tailnet" "$auto_yes"; then
            return 0
          fi
          workspace_clear_public_urls
          setup_fail "Tailscale machine is not tagged for Services"
          return 0
        fi
        rm -rf "$status_dir"
        workspace_tailscale_mark_error service-host-failed
        if workspace_tailscale_offer_ports_fallback "$tailnet" "$auto_yes"; then
          return 0
        fi
        workspace_clear_public_urls
        setup_fail "Could not configure Tailscale Services automatically"
        printf "    Configure manually:\n"
        workspace_task_manager_hosted && printf "    tailscale serve --bg --service=svc:%s --https=443 --yes http://127.0.0.1:%s\n" "$WORKSPACE_TASK_MANAGER_SERVICE" "$WORKSPACE_VIKUNJA_PORT"
        printf "    tailscale serve --bg --service=svc:n8n --https=443 --yes http://127.0.0.1:%s\n" "$WORKSPACE_N8N_PORT"
        printf "    tailscale serve --bg --service=svc:hermes --https=443 --yes http://127.0.0.1:%s\n" "$WORKSPACE_HERMES_TAILSCALE_PROXY_PORT"
        printf "    The host may need tag-based identity and admin approval in Tailscale Services.\n"
        return 0
      fi
    fi
    out=$(tailscale serve get-config --all 2>/dev/null || tailscale serve status --json 2>/dev/null || tailscale serve status 2>/dev/null || true)
    if workspace_tailscale_services_local_configured_from_output "$out"; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "$ready" != "1" ]] && workspace_tailscale_serve_disabled_error "$vikunja_log" "$n8n_log" "$hermes_log"; then
    enable_url=$(workspace_tailscale_serve_enable_url "$vikunja_log" "$n8n_log" "$hermes_log" || true)
    rm -rf "$status_dir"
    workspace_tailscale_mark_error serve-disabled "$enable_url"
    workspace_tailscale_print_serve_disabled_hitl "$enable_url"
    if workspace_tailscale_retry_after_hitl "$tailnet" "$check_only" "$funnel_action" "$auto_yes" "I enabled Tailscale Serve; retry now?"; then
      return 0
    fi
    if workspace_tailscale_offer_ports_fallback "$tailnet" "$auto_yes"; then
      return 0
    fi
    workspace_clear_public_urls
    setup_fail "Tailscale Serve is not enabled"
    return 0
  fi
  rm -rf "$status_dir"
  if [[ "$ready" == "1" ]]; then
    workspace_set_env_key WORKSPACE_TAILSCALE_MODE services
    if workspace_tailscale_service_host_advertised; then
      workspace_tailscale_clear_error
      info "Tailscale Services configured"
    else
      workspace_tailscale_mark_error pending-approval
      info "Tailscale Services configured locally"
      workspace_tailscale_print_pending_approval_hitl
      if workspace_tailscale_confirm_step "I approved this host for the Services; verify now?" "$auto_yes"; then
        if workspace_tailscale_wait_for_service_host_advertised; then
          workspace_tailscale_clear_error
          info "Tailscale Service host approval verified"
        else
          setup_fail "Tailscale Service host pending admin approval"
        fi
      else
        setup_fail "Tailscale Service host pending admin approval"
      fi
    fi
  else
    workspace_tailscale_mark_error not-advertised
    if workspace_tailscale_offer_ports_fallback "$tailnet" "$auto_yes"; then
      return 0
    fi
    workspace_clear_public_urls
    setup_fail "Could not configure Tailscale Services automatically"
    printf "    Configure manually:\n"
    workspace_task_manager_hosted && printf "    tailscale serve --bg --service=svc:%s --https=443 --yes http://127.0.0.1:%s\n" "$WORKSPACE_TASK_MANAGER_SERVICE" "$WORKSPACE_VIKUNJA_PORT"
    printf "    tailscale serve --bg --service=svc:n8n --https=443 --yes http://127.0.0.1:%s\n" "$WORKSPACE_N8N_PORT"
    printf "    tailscale serve --bg --service=svc:hermes --https=443 --yes http://127.0.0.1:%s\n" "$WORKSPACE_HERMES_TAILSCALE_PROXY_PORT"
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
  workspace_hermes_runtime_config_ready || return 1
  workspace_hermes_cli_toolsets_ready || return 1
}

workspace_hermes_runtime_config_ready() {
  local max_tokens context reasoning
  command -v nemohermes >/dev/null 2>&1 || return 1
  max_tokens=$(workspace_read_env HERMES_MAX_TOKENS 2>/dev/null || true)
  context=$(workspace_read_env HERMES_CONTEXT_LENGTH 2>/dev/null || true)
  reasoning=$(workspace_read_env HERMES_REASONING_EFFORT 2>/dev/null || true)
  [[ "$max_tokens" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$context" =~ ^[0-9]+$ && "$context" -ge "$WORKSPACE_HERMES_MIN_CONTEXT" ]] || return 1
  [[ "$reasoning" == "none" ]] || return 1
  nemohermes hermes exec --no-tty --timeout 20 -- sh -lc '
    file=/sandbox/.hermes/config.yaml max="$1" context="$2" reasoning="$3"
    grep -Eq "^[[:space:]]+max_tokens: ${max}$" "$file" &&
      grep -Eq "^[[:space:]]+context_length: ${context}$" "$file" &&
      grep -Eq "^[[:space:]]+reasoning_effort: ${reasoning}$" "$file"
  ' spark-hermes-config "$max_tokens" "$context" "$reasoning" >/dev/null 2>&1
}

workspace_configure_hermes_runtime() {
  local max_tokens context reasoning
  max_tokens=$(workspace_read_env HERMES_MAX_TOKENS 2>/dev/null || true)
  context=$(workspace_read_env HERMES_CONTEXT_LENGTH 2>/dev/null || true)
  reasoning=$(workspace_read_env HERMES_REASONING_EFFORT 2>/dev/null || true)
  [[ "$max_tokens" =~ ^[1-9][0-9]*$ ]] || max_tokens="$WORKSPACE_HERMES_MAX_TOKENS_DEFAULT"
  [[ "$context" =~ ^[0-9]+$ && "$context" -ge "$WORKSPACE_HERMES_MIN_CONTEXT" ]] || context="$WORKSPACE_HERMES_MIN_CONTEXT"
  [[ "$reasoning" == "none" ]] || reasoning="$WORKSPACE_HERMES_REASONING_EFFORT_DEFAULT"
  nemohermes hermes exec --no-tty --timeout 30 -- hermes config set model.max_tokens "$max_tokens" >/dev/null 2>&1 &&
    nemohermes hermes exec --no-tty --timeout 30 -- hermes config set model.context_length "$context" >/dev/null 2>&1 &&
    nemohermes hermes exec --no-tty --timeout 30 -- hermes config set agent.reasoning_effort "$reasoning" >/dev/null 2>&1 &&
    workspace_configure_hermes_cli_toolsets
}

workspace_configure_hermes_cli_toolsets() {
  local -a enabled disabled
  read -r -a enabled <<< "$WORKSPACE_HERMES_CLI_TOOLSETS_DEFAULT"
  read -r -a disabled <<< "$WORKSPACE_HERMES_CLI_TOOLSETS_DISABLED"
  nemohermes hermes exec --no-tty --timeout 30 -- hermes tools enable --platform cli "${enabled[@]}" >/dev/null 2>&1 &&
    nemohermes hermes exec --no-tty --timeout 30 -- hermes tools disable --platform cli "${disabled[@]}" >/dev/null 2>&1
}

workspace_hermes_cli_toolsets_ready() {
  local out tool
  command -v nemohermes >/dev/null 2>&1 || return 1
  out=$(nemohermes hermes exec --no-tty --timeout 20 -- env NO_COLOR=1 hermes tools list --platform cli 2>/dev/null) || return 1
  for tool in $WORKSPACE_HERMES_CLI_TOOLSETS_DEFAULT; do
    grep -Eq "enabled[[:space:]]+${tool}([[:space:]]|$)" <<< "$out" || return 1
  done
  for tool in $WORKSPACE_HERMES_CLI_TOOLSETS_DISABLED; do
    grep -Eq "disabled[[:space:]]+${tool}([[:space:]]|$)" <<< "$out" || return 1
  done
}

workspace_nemohermes_update_available() {
  local out
  command -v nemohermes >/dev/null 2>&1 || return 1
  out=$(nemohermes update --check 2>/dev/null || true)
  [[ "$out" == *"Update available:"*"yes"* || "$out" == *"Update available:         yes"* ]]
}

workspace_update_nemohermes_if_needed() {
  command -v nemohermes >/dev/null 2>&1 || return 1
  workspace_nemohermes_update_available || return 0
  warn "Updating NemoHermes to the maintained release"
  NEMOCLAW_AGENT=hermes \
    NEMOCLAW_NON_INTERACTIVE=1 \
    NEMOCLAW_YES=1 \
    NEMOCLAW_CONFIRM_LEGACY_MANAGED_RECREATE="${NEMOCLAW_CONFIRM_LEGACY_MANAGED_RECREATE:-[\"hermes\"]}" \
    nemohermes update --yes >/dev/null 2>&1
}

workspace_nemohermes_maintained_release() {
  command -v nemohermes >/dev/null 2>&1 || return 1
  ! workspace_nemohermes_update_available
}

workspace_openshell_bridge_ip() {
  local bridge_ip
  bridge_ip=$(docker network inspect openshell-docker \
    --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null | head -n 1)
  [[ "$bridge_ip" =~ ^[0-9]+([.][0-9]+){3}$ ]] || return 1
  printf '%s\n' "$bridge_ip"
}

workspace_start_hermes_host_proxy() {
  local container="$1" listen_port="$2" target_port="$3" health_path="$4" host_header="${5:-}" attempts="${6:-30}"
  local bridge_ip proxy_script attempt curl_args=(-fsS --max-time 2)
  [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=30
  bridge_ip=$(workspace_openshell_bridge_ip) || return 1
  proxy_script="${WORKSPACE_CONFIG_DIR}/hermes-host-proxy.py"
  mkdir -p "$WORKSPACE_CONFIG_DIR"
  cat > "$proxy_script" <<'PY'
import asyncio
import sys


async def relay(reader, writer, host_header=None):
    pending = b""
    try:
        while data := await reader.read(65536):
            if host_header is not None:
                pending += data
                marker = pending.find(b"\r\n\r\n")
                if marker < 0:
                    if len(pending) > 1048576:
                        pending = b""
                        return
                    continue
                head, tail = pending[:marker], pending[marker:]
                lines = head.split(b"\r\n")
                lines = [
                    b"Host: " + host_header.encode() if line.lower().startswith(b"host:") else line
                    for line in lines
                ]
                data = b"\r\n".join(lines) + tail
                pending = b""
                host_header = None
            writer.write(data)
            await writer.drain()
    finally:
        if pending:
            writer.write(pending)
            await writer.drain()
        writer.close()


async def handle(client_reader, client_writer):
    try:
        server_reader, server_writer = await asyncio.open_connection(sys.argv[3], int(sys.argv[4]))
        host_header = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else None
        await asyncio.gather(
            relay(client_reader, server_writer, host_header),
            relay(server_reader, client_writer),
        )
    except Exception:
        client_writer.close()


async def main():
    server = await asyncio.start_server(handle, sys.argv[1], int(sys.argv[2]))
    async with server:
        await server.serve_forever()


asyncio.run(main())
PY
  chmod 600 "$proxy_script"
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker run -d --network host \
    --name "$container" \
    --restart unless-stopped \
    -v "${proxy_script}:/app/hermes-host-proxy.py:ro" \
    --entrypoint python "$LITELLM_IMAGE" \
    /app/hermes-host-proxy.py "$bridge_ip" "$listen_port" 127.0.0.1 "$target_port" "$host_header" \
    >/dev/null 2>&1 || return 1
  [[ -z "$host_header" ]] || curl_args+=(-H "Host: ${host_header}")
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    curl "${curl_args[@]}" "http://${bridge_ip}:${listen_port}${health_path}" >/dev/null 2>&1 && return 0
    [[ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" == "true" ]] || return 1
    sleep 1
  done
  return 1
}

workspace_start_hermes_gateway_proxy() {
  workspace_start_hermes_host_proxy "$WORKSPACE_HERMES_GATEWAY_PROXY_CONTAINER" \
    "$GATEWAY_PORT" "$GATEWAY_PORT" /v1/models
}

workspace_start_hermes_vikunja_proxy() {
  workspace_start_hermes_host_proxy "$WORKSPACE_HERMES_VIKUNJA_PROXY_CONTAINER" \
    "$WORKSPACE_VIKUNJA_PORT" "$WORKSPACE_VIKUNJA_PORT" /api/v1/info
}

workspace_start_hermes_dashboard_proxy() {
  local proxy_script
  proxy_script="${WORKSPACE_CONFIG_DIR}/hermes-dashboard-proxy.py"
  mkdir -p "$WORKSPACE_CONFIG_DIR"
  cat > "$proxy_script" <<'PY'
import asyncio
import sys


async def relay(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    finally:
        writer.close()


async def handle(client_reader, client_writer):
    try:
        header = await client_reader.readuntil(b"\r\n\r\n")
        lines = header.split(b"\r\n")
        websocket = any(line.lower().startswith(b"upgrade: websocket") for line in lines)
        rewritten = []
        saw_connection = False
        for line in lines:
            lower = line.lower()
            if lower.startswith(b"host:"):
                line = f"Host: 127.0.0.1:{sys.argv[2]}".encode()
            elif lower.startswith(b"connection:"):
                saw_connection = True
                if not websocket:
                    line = b"Connection: close"
            rewritten.append(line)
        if not websocket and not saw_connection:
            rewritten.insert(-2, b"Connection: close")
        upstream_reader, upstream_writer = await asyncio.open_connection("127.0.0.1", int(sys.argv[2]))
        upstream_writer.write(b"\r\n".join(rewritten))
        await upstream_writer.drain()
        await asyncio.gather(relay(client_reader, upstream_writer), relay(upstream_reader, client_writer))
    except Exception:
        client_writer.close()


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", int(sys.argv[1]))
    async with server:
        await server.serve_forever()


asyncio.run(main())
PY
  chmod 600 "$proxy_script"
  docker rm -f "$WORKSPACE_HERMES_TAILSCALE_PROXY_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --network host \
    --name "$WORKSPACE_HERMES_TAILSCALE_PROXY_CONTAINER" \
    --restart unless-stopped \
    -v "${proxy_script}:/app/hermes-dashboard-proxy.py:ro" \
    --entrypoint python "$LITELLM_IMAGE" \
    /app/hermes-dashboard-proxy.py "$WORKSPACE_HERMES_TAILSCALE_PROXY_PORT" "$WORKSPACE_HERMES_PORT" \
    >/dev/null 2>&1
}

workspace_stop_hermes_dashboard_proxy() {
  docker rm -f "$WORKSPACE_HERMES_TAILSCALE_PROXY_CONTAINER" >/dev/null 2>&1 || true
}

workspace_hermes_dashboard_proxy_running() {
  [[ "$(docker inspect --format '{{.State.Running}}' "$WORKSPACE_HERMES_TAILSCALE_PROXY_CONTAINER" 2>/dev/null)" == "true" ]]
}

workspace_stop_hermes_gateway_proxy() {
  docker rm -f "$WORKSPACE_HERMES_GATEWAY_PROXY_CONTAINER" >/dev/null 2>&1 || true
}

workspace_stop_hermes_vikunja_proxy() {
  docker rm -f "$WORKSPACE_HERMES_VIKUNJA_PROXY_CONTAINER" >/dev/null 2>&1 || true
}

workspace_openshell_providers_v2_enabled() {
  command -v openshell >/dev/null 2>&1 || return 1
  openshell settings get --global --json 2>/dev/null \
    | jq -e '((.settings.providers_v2_enabled // .providers_v2_enabled) | tostring) == "true"' >/dev/null 2>&1
}

workspace_hermes_vikunja_provider_exists() {
  openshell provider list -o json 2>/dev/null \
    | jq -e --arg name "$WORKSPACE_HERMES_VIKUNJA_PROVIDER" \
      'any(.[]?; .name == $name)' >/dev/null 2>&1
}

workspace_hermes_vikunja_provider_attached() {
  openshell sandbox provider list hermes 2>/dev/null \
    | grep -Eq "^${WORKSPACE_HERMES_VIKUNJA_PROVIDER}[[:space:]]"
}

workspace_install_hermes_vikunja_skill() {
  local skill_dir="${WORKSPACE_CONFIG_DIR}/hermes-skills/vikunja"
  workspace_install_file "${skill_dir}/SKILL.md" 600 <<'EOF'
---
name: vikunja
description: Manage the user's Vikunja projects and tasks through its REST API with curl.
version: 1.0.0
prerequisites:
  env_vars: [VIKUNJA_API_TOKEN]
  commands: [curl, jq]
metadata:
  hermes:
    tags: [Vikunja, Productivity, Tasks, API]
---

# Vikunja tasks

Use Vikunja's REST API directly with `curl`. Do not use Electron or an MCP server.

```bash
VIKUNJA_API_URL=http://host.openshell.internal:3456/api/v1
curl -fsS --max-time 10 "$VIKUNJA_API_URL/user" \
  -H "Authorization: Bearer $VIKUNJA_API_TOKEN" | jq
```

Never print `VIKUNJA_API_TOKEN`. It is an OpenShell-managed placeholder and is
resolved only when sent to the approved Vikunja endpoint.

Common operations:

```bash
# Projects visible to bot-hermes
VIKUNJA_API_URL=http://host.openshell.internal:3456/api/v1
curl -fsS --max-time 10 "$VIKUNJA_API_URL/projects?per_page=1000" \
  -H "Authorization: Bearer $VIKUNJA_API_TOKEN" | jq

# Tasks in a project
VIKUNJA_API_URL=http://host.openshell.internal:3456/api/v1
curl -fsS --max-time 10 "$VIKUNJA_API_URL/tasks?per_page=1000" \
  -H "Authorization: Bearer $VIKUNJA_API_TOKEN" \
  | jq --argjson project_id "$PROJECT_ID" '[.[] | select(.project_id == $project_id)]'

# Create a task
VIKUNJA_API_URL=http://host.openshell.internal:3456/api/v1
curl -fsS --max-time 10 -X PUT "$VIKUNJA_API_URL/projects/$PROJECT_ID/tasks" \
  -H "Authorization: Bearer $VIKUNJA_API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary "$(jq -nc --arg title "$TITLE" '{title:$title}')" | jq

# Update or complete a task
VIKUNJA_API_URL=http://host.openshell.internal:3456/api/v1
curl -fsS --max-time 10 -X POST "$VIKUNJA_API_URL/tasks/$TASK_ID" \
  -H "Authorization: Bearer $VIKUNJA_API_TOKEN" \
  -H 'Content-Type: application/json' \
  --data-binary "$(jq -nc --argjson done true '{done:$done}')" | jq
```

Read before writing. Ask before destructive deletion unless the user explicitly
requested it. Attribute all API activity to `bot-hermes`.
EOF
  nemohermes hermes skill install "$skill_dir" >/dev/null 2>&1
}

workspace_hermes_vikunja_api_ready() {
  command -v nemohermes >/dev/null 2>&1 || return 1
  nemohermes hermes exec --no-tty --timeout 20 -- sh -lc '
    url="$1" expected="$2"
    test -n "${VIKUNJA_API_TOKEN:-}" || exit 1
    curl -fsS --max-time 10 "$url/user" \
      -H "Authorization: Bearer ${VIKUNJA_API_TOKEN}" \
      | jq -e --arg expected "$expected" ".username == \$expected and (.bot_owner_id > 0)" >/dev/null
  ' spark-vikunja "$WORKSPACE_HERMES_VIKUNJA_API_URL" "$WORKSPACE_VIKUNJA_HERMES_BOT_USERNAME" \
    >/dev/null 2>&1
}

workspace_setup_hermes_vikunja_access() {
  local token attached=0 attempt attempts="${SPARK_WORKSPACE_HERMES_API_ATTEMPTS:-10}"
  [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=10
  command -v jq >/dev/null 2>&1 || return 1
  command -v openshell >/dev/null 2>&1 || return 1
  command -v nemohermes >/dev/null 2>&1 || return 1
  token=$(workspace_read_env VIKUNJA_HERMES_API_TOKEN 2>/dev/null || true)
  [[ -n "$token" ]] || return 1
  [[ "$(workspace_read_env VIKUNJA_HERMES_API_STATUS 2>/dev/null || true)" == "verified" ]] || return 1
  [[ "$(workspace_read_env VIKUNJA_HERMES_PROJECT_ACCESS_STATUS 2>/dev/null || true)" == "verified" ]] || return 1
  workspace_start_hermes_vikunja_proxy || return 1
  workspace_openshell_providers_v2_enabled \
    || openshell settings set --global --key providers_v2_enabled --value true --yes >/dev/null 2>&1 \
    || return 1
  if workspace_hermes_vikunja_provider_exists; then
    VIKUNJA_API_TOKEN="$token" openshell provider update "$WORKSPACE_HERMES_VIKUNJA_PROVIDER" \
      --credential VIKUNJA_API_TOKEN >/dev/null 2>&1 || return 1
  else
    VIKUNJA_API_TOKEN="$token" openshell provider create \
      --name "$WORKSPACE_HERMES_VIKUNJA_PROVIDER" --type generic \
      --credential VIKUNJA_API_TOKEN >/dev/null 2>&1 || return 1
  fi
  if workspace_hermes_vikunja_provider_attached; then
    attached=1
  else
    openshell sandbox provider attach hermes "$WORKSPACE_HERMES_VIKUNJA_PROVIDER" >/dev/null 2>&1 \
      || return 1
  fi
  openshell policy update hermes \
    --add-endpoint host.openshell.internal:3456:read-write:rest:enforce \
    --binary /usr/bin/curl --rule-name spark-vikunja-api --wait >/dev/null 2>&1 \
    || return 1
  workspace_install_hermes_vikunja_skill || return 1
  [[ "$attached" == "1" ]] \
    || nemohermes hermes gateway restart --quiet >/dev/null 2>&1 \
    || return 1
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    workspace_hermes_vikunja_api_ready && {
      info "Hermes Vikunja API access verified as ${WORKSPACE_VIKUNJA_HERMES_BOT_USERNAME}"
      return 0
    }
    sleep 1
  done
  return 1
}

workspace_start_hermes_super_productivity_proxy() {
  workspace_start_hermes_host_proxy "$WORKSPACE_HERMES_SUPER_PRODUCTIVITY_PROXY_CONTAINER" \
    "$WORKSPACE_SUPER_PRODUCTIVITY_API_PORT" "$WORKSPACE_SUPER_PRODUCTIVITY_API_PORT" /health 127.0.0.1:3876 60
}

workspace_stop_hermes_super_productivity_proxy() {
  docker rm -f "$WORKSPACE_HERMES_SUPER_PRODUCTIVITY_PROXY_CONTAINER" >/dev/null 2>&1 || true
}

workspace_hermes_super_productivity_proxy_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$WORKSPACE_HERMES_SUPER_PRODUCTIVITY_PROXY_CONTAINER"
}

workspace_install_hermes_super_productivity_skill() {
  local skill_dir="${WORKSPACE_CONFIG_DIR}/hermes-skills/super-productivity"
  workspace_install_file "${skill_dir}/SKILL.md" 600 <<'EOF'
---
name: super-productivity
description: Manage the user's Super Productivity tasks and projects through its private local REST API.
version: 1.0.0
prerequisites:
  commands: [curl, jq]
metadata:
  hermes:
    tags: [Super Productivity, Productivity, Tasks, API]
---

# Super Productivity tasks

Use the local REST API directly with `curl`. Do not use an MCP server. This
endpoint reaches Spark's persistent Electron client; SuperSync propagates its
changes to the user's browsers.

```bash
SUPER_PRODUCTIVITY_API_URL=http://host.openshell.internal:3877
curl -fsS --max-time 10 -H 'Host: 127.0.0.1:3876' "$SUPER_PRODUCTIVITY_API_URL/health" | jq
curl -fsS --max-time 10 -H 'Host: 127.0.0.1:3876' "$SUPER_PRODUCTIVITY_API_URL/tasks" | jq
curl -fsS --max-time 10 -H 'Host: 127.0.0.1:3876' "$SUPER_PRODUCTIVITY_API_URL/projects" | jq
```

Common operations:

```bash
# Create an inbox task
curl -fsS --max-time 10 -X POST "$SUPER_PRODUCTIVITY_API_URL/tasks" \
  -H 'Host: 127.0.0.1:3876' \
  -H 'Content-Type: application/json' \
  --data-binary "$(jq -nc --arg title "$TITLE" '{title:$title}')" | jq

# Create a task in a project
curl -fsS --max-time 10 -X POST "$SUPER_PRODUCTIVITY_API_URL/tasks" \
  -H 'Host: 127.0.0.1:3876' \
  -H 'Content-Type: application/json' \
  --data-binary "$(jq -nc --arg title "$TITLE" --arg projectId "$PROJECT_ID" '{title:$title,projectId:$projectId}')" | jq

# Update a task
curl -fsS --max-time 10 -X PATCH "$SUPER_PRODUCTIVITY_API_URL/tasks/$TASK_ID" \
  -H 'Host: 127.0.0.1:3876' \
  -H 'Content-Type: application/json' \
  --data-binary "$(jq -nc --arg title "$TITLE" '{title:$title}')" | jq

# Archive a completed task
curl -fsS --max-time 10 -X POST -H 'Host: 127.0.0.1:3876' "$SUPER_PRODUCTIVITY_API_URL/tasks/$TASK_ID/archive" | jq
```

Read before writing. Ask before destructive deletion unless the user explicitly
requested it. The API has no token because it is restricted to localhost and
Hermes' enforced OpenShell endpoint policy.
EOF
  nemohermes hermes skill install "$skill_dir" >/dev/null 2>&1
}

workspace_hermes_super_productivity_api_ready() {
  command -v nemohermes >/dev/null 2>&1 || return 1
  nemohermes hermes exec --no-tty --timeout 20 -- sh -lc '
    curl -fsS --max-time 10 -H "Host: 127.0.0.1:3876" "$1/health" | jq -e ".ok == true and .data.rendererReady == true" >/dev/null
  ' spark-super-productivity "$WORKSPACE_HERMES_SUPER_PRODUCTIVITY_API_URL" >/dev/null 2>&1
}

workspace_setup_hermes_super_productivity_access() {
  local attempt attempts="${SPARK_WORKSPACE_HERMES_API_ATTEMPTS:-60}"
  [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=60
  command -v openshell >/dev/null 2>&1 || return 1
  command -v nemohermes >/dev/null 2>&1 || return 1
  workspace_start_hermes_super_productivity_proxy || return 1
  openshell policy update hermes \
    --add-endpoint host.openshell.internal:3877:read-write:rest:enforce \
    --binary /usr/bin/curl --rule-name spark-super-productivity-api --wait >/dev/null 2>&1 \
    || return 1
  workspace_install_hermes_super_productivity_skill || return 1
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    workspace_hermes_super_productivity_api_ready && {
      info "Hermes Super Productivity API access verified"
      return 0
    }
    sleep 1
  done
  return 1
}

workspace_hermes_todoist_provider_exists() {
  openshell provider list -o json 2>/dev/null \
    | jq -e --arg name "$WORKSPACE_HERMES_TODOIST_PROVIDER" \
      'any(.[]?; .name == $name)' >/dev/null 2>&1
}

workspace_hermes_todoist_provider_attached() {
  openshell sandbox provider list hermes 2>/dev/null \
    | grep -Eq "^${WORKSPACE_HERMES_TODOIST_PROVIDER}[[:space:]]"
}

workspace_install_hermes_todoist_skill() {
  local skill_dir="${WORKSPACE_CONFIG_DIR}/hermes-skills/todoist"
  workspace_install_file "${skill_dir}/SKILL.md" 600 <<'EOF'
---
name: todoist
description: Manage the user's Todoist projects and tasks through the official API v1 with curl.
version: 1.1.0
prerequisites:
  env_vars: [TODOIST_API_TOKEN]
  commands: [curl, jq]
metadata:
  hermes:
    tags: [Todoist, Productivity, Tasks, API]
---

# Todoist tasks

Use the official Todoist API v1 directly. Do not use deprecated REST v2 or Sync v9 endpoints.

```bash
TODOIST_API_URL=https://api.todoist.com/api/v1
AUTH="Authorization: Bearer $TODOIST_API_TOKEN"
curl -fsS --max-time 15 "$TODOIST_API_URL/projects?limit=200" -H "$AUTH" | jq
```

Never print `TODOIST_API_TOKEN`. OpenShell resolves it only for the approved Todoist endpoint.
Paginated responses use `results` and `next_cursor`; follow every non-null cursor while keeping the original query parameters.

## Hermes attribution

Spark ensures that the personal label `Hermes` exists. Every task that Hermes changes must retain this label so the user can identify agent intervention.

- Creating a task: include `"Hermes"` in `labels`.
- Updating, moving, completing, reopening, or commenting on a task: first read the task, merge `Hermes` into its existing labels without removing any label, then perform the requested action.
- If the label cannot be applied, stop before the mutation and report the failure.
- Read-only inspection does not add the label.
- Deleting a task removes the attribution with the task; warn about this during the required deletion confirmation.

Common operations:

```bash
# Active tasks (add cursor=... for later pages)
curl -fsS --max-time 15 "$TODOIST_API_URL/tasks?limit=200" -H "$AUTH" | jq

# Create a task attributed to Hermes
curl -fsS --max-time 15 -X POST "$TODOIST_API_URL/tasks" \
  -H "$AUTH" -H 'Content-Type: application/json' \
  --data-binary "$(jq -nc --arg content "$CONTENT" --arg project_id "$PROJECT_ID" \
    '{content:$content,project_id:$project_id,labels:["Hermes"]}')" | jq

# Preserve existing labels and add Hermes before changing an existing task
task=$(curl -fsS --max-time 15 "$TODOIST_API_URL/tasks/$TASK_ID" -H "$AUTH")
labels=$(printf '%s\n' "$task" | jq -c '(.labels // []) + ["Hermes"] | unique')
curl -fsS --max-time 15 -X POST "$TODOIST_API_URL/tasks/$TASK_ID" \
  -H "$AUTH" -H 'Content-Type: application/json' \
  --data-binary "$(jq -nc --argjson labels "$labels" '{labels:$labels}')" | jq

# Complete only after attribution succeeds
curl -fsS --max-time 15 -X POST "$TODOIST_API_URL/tasks/$TASK_ID/close" -H "$AUTH"
```

Read before writing. Ask before irreversible deletion unless explicitly requested. Todoist activity is attributed to the token owner and marked with `Hermes`.
EOF
  nemohermes hermes skill install "$skill_dir" >/dev/null 2>&1
}

workspace_hermes_todoist_access_ready() {
  command -v nemohermes >/dev/null 2>&1 || return 1
  nemohermes hermes exec --no-tty --timeout 25 -- sh -lc '
    test -n "${TODOIST_API_TOKEN:-}" || exit 1
    curl -fsS --max-time 15 "$1/projects?limit=1" \
      -H "Authorization: Bearer ${TODOIST_API_TOKEN}" \
      | jq -e ".results | type == \"array\"" >/dev/null
  ' spark-todoist "$WORKSPACE_TODOIST_API_URL" >/dev/null 2>&1
}

workspace_hermes_todoist_label_ready() {
  command -v nemohermes >/dev/null 2>&1 || return 1
  nemohermes hermes exec --no-tty --timeout 25 -- sh -lc '
    set -eu
    test -n "${TODOIST_API_TOKEN:-}" || exit 1
    cursor=""
    while :; do
      url="$1/labels?limit=200"
      if [ -n "$cursor" ]; then
        encoded=$(jq -rn --arg value "$cursor" "\$value|@uri")
        url="${url}&cursor=${encoded}"
      fi
      body=$(curl -fsS --max-time 15 "$url" \
        -H "Authorization: Bearer ${TODOIST_API_TOKEN}")
      printf "%s\n" "$body" | jq -e ".results | type == \"array\"" >/dev/null
      printf "%s\n" "$body" | jq -e ".results[]? | select(.name == \"Hermes\")" >/dev/null && exit 0
      cursor=$(printf "%s\n" "$body" | jq -r ".next_cursor // empty")
      [ -n "$cursor" ] || exit 1
    done
  ' spark-todoist "$WORKSPACE_TODOIST_API_URL" >/dev/null 2>&1
}

workspace_ensure_hermes_todoist_label() {
  workspace_hermes_todoist_label_ready && return 0
  nemohermes hermes exec --no-tty --timeout 25 -- sh -lc '
    set -eu
    test -n "${TODOIST_API_TOKEN:-}" || exit 1
    cursor=""
    match=""
    while :; do
      url="$1/labels?limit=200"
      if [ -n "$cursor" ]; then
        encoded=$(jq -rn --arg value "$cursor" "\$value|@uri")
        url="${url}&cursor=${encoded}"
      fi
      body=$(curl -fsS --max-time 15 "$url" \
        -H "Authorization: Bearer ${TODOIST_API_TOKEN}")
      match=$(printf "%s\n" "$body" | jq -c "first(.results[]? | select((.name | ascii_downcase) == \"hermes\")) // empty")
      [ -z "$match" ] || break
      cursor=$(printf "%s\n" "$body" | jq -r ".next_cursor // empty")
      [ -n "$cursor" ] || break
    done
    if [ -n "$match" ]; then
      label_id=$(printf "%s\n" "$match" | jq -r ".id")
      payload=$(jq -nc "{name:\"Hermes\"}")
      curl -fsS --max-time 15 -X POST "$1/labels/${label_id}" \
        -H "Authorization: Bearer ${TODOIST_API_TOKEN}" \
        -H "Content-Type: application/json" --data-binary "$payload" >/dev/null
    else
      payload=$(jq -nc "{name:\"Hermes\"}")
      curl -fsS --max-time 15 -X POST "$1/labels" \
        -H "Authorization: Bearer ${TODOIST_API_TOKEN}" \
        -H "Content-Type: application/json" --data-binary "$payload" >/dev/null
    fi
  ' spark-todoist "$WORKSPACE_TODOIST_API_URL" >/dev/null 2>&1 || return 1
  workspace_hermes_todoist_label_ready
}

workspace_hermes_todoist_api_ready() {
  [[ "$(workspace_read_env TODOIST_API_STATUS 2>/dev/null || true)" == "verified" ]] || return 1
  workspace_hermes_todoist_access_ready &&
    workspace_hermes_todoist_label_ready
}

workspace_setup_hermes_todoist_access() {
  local token attached=0 attempt attempts="${SPARK_WORKSPACE_HERMES_API_ATTEMPTS:-10}"
  [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=10
  command -v jq >/dev/null 2>&1 || return 1
  command -v openshell >/dev/null 2>&1 || return 1
  command -v nemohermes >/dev/null 2>&1 || return 1
  token=$(workspace_read_env TODOIST_API_TOKEN 2>/dev/null || true)
  [[ -n "$token" ]] || return 1
  workspace_set_env_key TODOIST_API_STATUS pending
  workspace_openshell_providers_v2_enabled \
    || openshell settings set --global --key providers_v2_enabled --value true --yes >/dev/null 2>&1 \
    || return 1
  if workspace_hermes_todoist_provider_exists; then
    TODOIST_API_TOKEN="$token" openshell provider update "$WORKSPACE_HERMES_TODOIST_PROVIDER" \
      --credential TODOIST_API_TOKEN >/dev/null 2>&1 || return 1
  else
    TODOIST_API_TOKEN="$token" openshell provider create \
      --name "$WORKSPACE_HERMES_TODOIST_PROVIDER" --type generic \
      --credential TODOIST_API_TOKEN >/dev/null 2>&1 || return 1
  fi
  if workspace_hermes_todoist_provider_attached; then
    attached=1
  else
    openshell sandbox provider attach hermes "$WORKSPACE_HERMES_TODOIST_PROVIDER" >/dev/null 2>&1 \
      || return 1
  fi
  openshell policy update hermes \
    --add-endpoint api.todoist.com:443:read-write:rest:enforce \
    --binary /usr/bin/curl --rule-name spark-todoist-api --wait >/dev/null 2>&1 \
    || return 1
  workspace_install_hermes_todoist_skill || return 1
  [[ "$attached" == "1" ]] \
    || nemohermes hermes gateway restart --quiet >/dev/null 2>&1 \
    || return 1
  workspace_set_env_key TODOIST_API_STATUS verified
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if workspace_hermes_todoist_access_ready && workspace_ensure_hermes_todoist_label; then
      info "Hermes Todoist API access and label verified"
      return 0
    fi
    sleep 1
  done
  workspace_set_env_key TODOIST_API_STATUS pending
  return 1
}

workspace_task_manager_artifacts_exist() {
  case "${1:-}" in
    vikunja)
      [[ -e "$WORKSPACE_VIKUNJA_ENV_FILE" ||
         -e "${WORKSPACE_DATA_DIR}/vikunja-files" ||
         -e "${WORKSPACE_CONFIG_DIR}/hermes-skills/vikunja" ]]
      ;;
    super-productivity)
      [[ -e "$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE" ||
         -e "${WORKSPACE_DATA_DIR}/super-productivity-electron" ||
         -e "$WORKSPACE_SUPERSYNC_DIR" ||
         -e "$WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_DIR" ||
         -e "${WORKSPACE_CONFIG_DIR}/hermes-skills/super-productivity" ]]
      ;;
    todoist)
      [[ -e "${WORKSPACE_CONFIG_DIR}/hermes-skills/todoist" ]] ||
        [[ "$(workspace_read_env WORKSPACE_TASK_MANAGER 2>/dev/null || true)" == "todoist" ]]
      ;;
    *) return 1 ;;
  esac
}

workspace_teardown_task_manager_candidate() {
  local previous="$1" pending="$2" current="$3" candidate
  workspace_task_manager_valid "$current" || return 1
  if workspace_task_manager_valid "$previous" && [[ "$previous" != "$current" ]]; then
    printf '%s\n' "$previous"
    return 0
  fi
  if workspace_task_manager_valid "$pending" && [[ "$pending" != "$current" ]]; then
    printf '%s\n' "$pending"
    return 0
  fi
  for candidate in vikunja super-productivity todoist; do
    [[ "$candidate" != "$current" ]] || continue
    if workspace_task_manager_artifacts_exist "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

workspace_task_manager_managed_image_refs() {
  local manager="$1" refs ref
  refs=$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
  while IFS= read -r ref; do
    case "${manager}:${ref}" in
      vikunja:vikunja/vikunja:*) printf '%s\n' "$ref" ;;
      super-productivity:spark/supersync:*|super-productivity:spark/super-productivity-electron:*) printf '%s\n' "$ref" ;;
    esac
  done <<< "$refs"
}

workspace_task_manager_image_refs() {
  local manager="$1" key container ref image_id
  local -a keys=() containers=() defaults=()
  case "$manager" in
    vikunja)
      keys=(WORKSPACE_VIKUNJA_IMAGE)
      containers=("$WORKSPACE_VIKUNJA_CONTAINER")
      defaults=("$WORKSPACE_VIKUNJA_IMAGE_DEFAULT")
      ;;
    super-productivity)
      keys=(WORKSPACE_SUPERSYNC_IMAGE WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_IMAGE)
      containers=("$WORKSPACE_SUPERSYNC_CONTAINER" "$WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_CONTAINER")
      defaults=("$WORKSPACE_SUPERSYNC_IMAGE_DEFAULT" "spark/super-productivity-electron:${WORKSPACE_SUPER_PRODUCTIVITY_VERSION_DEFAULT#v}")
      ;;
    todoist) return 0 ;;
    *) return 1 ;;
  esac
  for key in "${keys[@]}"; do
    ref=$(workspace_read_env "$key" 2>/dev/null || true)
    [[ -n "$ref" ]] && printf '%s\n' "$ref"
  done
  for container in "${containers[@]}"; do
    ref=$(docker inspect --format '{{.Config.Image}}' "$container" 2>/dev/null || true)
    image_id=$(docker inspect --format '{{.Image}}' "$container" 2>/dev/null || true)
    [[ -n "$ref" ]] && printf '%s\n' "$ref"
    [[ -n "$image_id" ]] && printf '%s\n' "$image_id"
  done
  workspace_task_manager_managed_image_refs "$manager"
  printf '%s\n' "${defaults[@]}"
}

workspace_task_manager_teardown_images() {
  local manager="$1" pending stored
  pending=$(workspace_read_env WORKSPACE_TASK_MANAGER_TEARDOWN_PENDING 2>/dev/null || true)
  stored=$(workspace_read_env WORKSPACE_TASK_MANAGER_TEARDOWN_IMAGES 2>/dev/null || true)
  if [[ "$pending" == "$manager" && -n "$stored" ]]; then
    printf '%s\n' "$stored"
    return 0
  fi
  workspace_task_manager_image_refs "$manager" | awk 'NF && !seen[$0]++' | paste -sd, -
}

workspace_remove_task_manager_images() {
  local csv="$1" image_ref failed=0
  local -a image_refs=()
  [[ -n "$csv" ]] || return 0
  IFS=',' read -r -a image_refs <<< "$csv"
  for image_ref in "${image_refs[@]}"; do
    [[ -n "$image_ref" ]] || continue
    if docker image inspect "$image_ref" >/dev/null 2>&1; then
      docker image rm -f "$image_ref" >/dev/null 2>&1 || failed=1
    fi
  done
  [[ "$failed" == "0" ]]
}

workspace_remove_managed_path() {
  local path="$1"
  [[ -n "$path" && -n "$WORKSPACE_CONFIG_DIR" && -n "$WORKSPACE_DATA_DIR" ]] || return 1
  case "$path" in
    "$WORKSPACE_CONFIG_DIR"/*|"$WORKSPACE_DATA_DIR"/*) ;;
    *) return 1 ;;
  esac
  rm -rf -- "$path"
}

workspace_drop_task_manager_database() {
  local manager="$1" db role
  case "$manager" in
    vikunja) db=vikunja; role=vikunja ;;
    super-productivity) db=supersync; role=supersync ;;
    *) return 1 ;;
  esac
  workspace_postgres_psql <<SQL
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = '${db}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${db}";
DROP ROLE IF EXISTS "${role}";
SQL
}

workspace_cleanup_abandoned_hermes_access() {
  local manager="$1" rule skill skill_dir skill_out="" failed=0 provider=""
  command -v openshell >/dev/null 2>&1 || return 1
  command -v nemohermes >/dev/null 2>&1 || return 1
  case "$manager" in
    vikunja)
      rule=spark-vikunja-api
      skill=vikunja
      skill_dir="${WORKSPACE_CONFIG_DIR}/hermes-skills/vikunja"
      provider="$WORKSPACE_HERMES_VIKUNJA_PROVIDER"
      workspace_stop_hermes_vikunja_proxy
      ;;
    super-productivity)
      rule=spark-super-productivity-api
      skill=super-productivity
      skill_dir="${WORKSPACE_CONFIG_DIR}/hermes-skills/super-productivity"
      workspace_stop_hermes_super_productivity_proxy
      ;;
    todoist)
      rule=spark-todoist-api
      skill=todoist
      skill_dir="${WORKSPACE_CONFIG_DIR}/hermes-skills/todoist"
      provider="$WORKSPACE_HERMES_TODOIST_PROVIDER"
      ;;
    *) return 1 ;;
  esac
  openshell policy update hermes --remove-rule "$rule" --wait >/dev/null 2>&1 || failed=1
  if [[ -n "$provider" ]]; then
    case "$manager" in
      vikunja)
        if workspace_hermes_vikunja_provider_attached; then
          openshell sandbox provider detach hermes "$provider" >/dev/null 2>&1 || failed=1
        fi
        if workspace_hermes_vikunja_provider_exists; then
          openshell provider delete "$provider" >/dev/null 2>&1 || failed=1
        fi
        ;;
      todoist)
        if workspace_hermes_todoist_provider_attached; then
          openshell sandbox provider detach hermes "$provider" >/dev/null 2>&1 || failed=1
        fi
        if workspace_hermes_todoist_provider_exists; then
          openshell provider delete "$provider" >/dev/null 2>&1 || failed=1
        fi
        ;;
    esac
  fi
  if ! skill_out=$(nemohermes hermes skill remove "$skill" 2>&1); then
    [[ "$skill_out" == *"is not installed"* ]] || failed=1
  fi
  if [[ "$failed" == "0" ]]; then
    workspace_remove_managed_path "$skill_dir" || return 1
  fi
  nemohermes hermes gateway restart --quiet >/dev/null 2>&1 || failed=1
  [[ "$failed" == "0" ]]
}

workspace_teardown_vikunja() {
  local image_refs_csv="${1:-}" failed=0
  workspace_cleanup_abandoned_hermes_access vikunja || failed=1
  docker rm -f "$WORKSPACE_VIKUNJA_CONTAINER" >/dev/null 2>&1 || true
  workspace_remove_task_manager_images "$image_refs_csv" || failed=1
  workspace_drop_task_manager_database vikunja || failed=1
  workspace_remove_managed_path "${WORKSPACE_DATA_DIR}/vikunja-files" || failed=1
  workspace_remove_managed_path "$WORKSPACE_VIKUNJA_ENV_FILE" || failed=1
  [[ "$failed" == "0" ]]
}

workspace_teardown_super_productivity() {
  local image_refs_csv="${1:-}" failed=0
  workspace_cleanup_abandoned_hermes_access super-productivity || failed=1
  docker rm -f "$WORKSPACE_SUPERSYNC_CONTAINER" "$WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_CONTAINER" >/dev/null 2>&1 || true
  workspace_remove_task_manager_images "$image_refs_csv" || failed=1
  workspace_drop_task_manager_database super-productivity || failed=1
  workspace_remove_managed_path "${WORKSPACE_DATA_DIR}/super-productivity-electron" || failed=1
  workspace_remove_managed_path "$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE" || failed=1
  workspace_remove_managed_path "$WORKSPACE_SUPERSYNC_DIR" || failed=1
  workspace_remove_managed_path "$WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_DIR" || failed=1
  [[ "$failed" == "0" ]]
}

workspace_teardown_todoist() {
  local failed=0
  workspace_cleanup_abandoned_hermes_access todoist || failed=1
  workspace_remove_managed_path "${WORKSPACE_CONFIG_DIR}/hermes-skills/todoist" || failed=1
  [[ "$failed" == "0" ]]
}

workspace_cleanup_abandoned_task_manager() {
  local manager="$1" image_refs_csv="${2:-}"
  case "$manager" in
    vikunja) workspace_teardown_vikunja "$image_refs_csv" ;;
    super-productivity) workspace_teardown_super_productivity "$image_refs_csv" ;;
    todoist) workspace_teardown_todoist ;;
    *) return 1 ;;
  esac
}

workspace_finalize_task_manager_teardown() {
  local abandoned="$1" current="$2" teardown_images_csv attempt ready=0
  teardown_images_csv=$(workspace_read_env WORKSPACE_TASK_MANAGER_TEARDOWN_IMAGES 2>/dev/null || true)
  workspace_task_manager_valid "$abandoned" || return 0
  [[ "$abandoned" != "$current" ]] || return 0
  if [[ ${#SETUP_FAILED[@]} -gt 0 ]]; then
    info "Preserved $(workspace_task_manager_label "$abandoned") data because the new workspace is incomplete"
    return 0
  fi
  for ((attempt = 1; attempt <= 30; attempt++)); do
    case "$current" in
      vikunja) workspace_hermes_vikunja_api_ready && ready=1 ;;
      super-productivity) workspace_hermes_super_productivity_api_ready && ready=1 ;;
      todoist) workspace_hermes_todoist_api_ready && ready=1 ;;
    esac
    [[ "$ready" == "1" ]] && break
    sleep 1
  done
  [[ "$ready" == "1" ]] || return 1
  workspace_cleanup_abandoned_task_manager "$abandoned" "$teardown_images_csv" || return 1
  workspace_remove_env_file_key "$WORKSPACE_ENV_FILE" WORKSPACE_TASK_MANAGER_TEARDOWN_PENDING
  workspace_remove_env_file_key "$WORKSPACE_ENV_FILE" WORKSPACE_TASK_MANAGER_TEARDOWN_IMAGES
  info "Removed abandoned $(workspace_task_manager_label "$abandoned") services, images and data"
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
    if workspace_update_nemohermes_if_needed; then
      :
    else
      setup_fail "NemoHermes update failed; run nemohermes update --yes manually"
      return 0
    fi
    if workspace_hermes_running; then
      if ! workspace_hermes_inference_route_ready; then
        NEMOCLAW_SANDBOX_NAME=hermes nemohermes inference set \
          --provider compatible-endpoint --model "$litellm_model" \
          --sandbox hermes --no-verify >/dev/null 2>&1 || true
      fi
      workspace_configure_hermes_runtime || true
    fi
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
      NEMOCLAW_ENDPOINT_URL="http://host.openshell.internal:${GATEWAY_PORT}/v1" \
      NEMOCLAW_MODEL="$litellm_model" \
      NEMOCLAW_PREFERRED_API=openai-completions \
      NEMOCLAW_DASHBOARD_PORT="$WORKSPACE_HERMES_PORT" \
      NEMOCLAW_HERMES_DASHBOARD_HOST=127.0.0.1 \
      NEMOCLAW_POLICY_TIER=restricted \
      NEMOCLAW_POLICY_MODE=suggested \
      COMPATIBLE_API_KEY=dummy \
      CHAT_UI_URL="$hermes_url" \
      nemohermes onboard --non-interactive --yes-i-accept-third-party-software \
        --yes \
        --no-gpu \
        --control-ui-port "$WORKSPACE_HERMES_PORT" >/dev/null 2>&1 \
      && workspace_start_hermes_private_proxy \
      && workspace_configure_hermes_runtime \
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
      NEMOCLAW_ENDPOINT_URL="http://host.openshell.internal:${GATEWAY_PORT}/v1" \
      NEMOCLAW_MODEL="$litellm_model" \
      NEMOCLAW_PREFERRED_API=openai-completions \
      NEMOCLAW_DASHBOARD_PORT="$WORKSPACE_HERMES_PORT" \
      NEMOCLAW_HERMES_DASHBOARD_HOST=127.0.0.1 \
      NEMOCLAW_POLICY_TIER=restricted \
      NEMOCLAW_POLICY_MODE=suggested \
      COMPATIBLE_API_KEY=dummy \
      CHAT_UI_URL="$hermes_url" \
      bash -c 'curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash' || true
    if command -v nemohermes >/dev/null 2>&1 && workspace_start_hermes_gateway_proxy; then
      workspace_setup_hermes "$model" "$tailnet" "$check_only"
    else
      workspace_set_env_key HERMES_ONBOARD_STATUS manual
      setup_fail "Hermes/NemoClaw install failed"
    fi
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

workspace_confirm_task_manager_migration() {
  local current="$1" target="$2" confirmation
  printf "\n  ${RED}${BOLD}WARNING: destructive task-manager migration${NC}\n\n" >&2
  printf "  %s -> %s\n" \
    "$(workspace_task_manager_label "$current")" "$(workspace_task_manager_label "$target")" >&2
  printf "  After the new task manager is verified, Spark will permanently remove the old one:\n" >&2
  printf "    containers, Docker images, database and role, files, configuration,\n" >&2
  printf "    and Hermes access/proxy integration. No backup will be created.\n\n" >&2
  printf "  Type MIGRATE to continue: " >&2
  read -r confirmation || die "Task manager migration cancelled"
  [[ "$confirmation" == "MIGRATE" ]] || die "Task manager migration cancelled"
}

workspace_select_task_manager() {
  local requested="${1:-}" current="${2:-}" check_only="${3:-0}"
  local choice target_a target_b
  workspace_task_manager_valid "$current" || current=""
  if [[ -n "$requested" ]]; then
    workspace_task_manager_valid "$requested" || die "--task-manager must be 'vikunja', 'super-productivity', or 'todoist'"
    if [[ -n "$current" && "$requested" != "$current" && "$check_only" != "1" ]]; then
      if is_interactive; then
        workspace_confirm_task_manager_migration "$current" "$requested"
      else
        printf "  WARNING: migrating from %s to %s will permanently remove the old task manager and its local data; no backup will be created.\n" \
          "$(workspace_task_manager_label "$current")" "$(workspace_task_manager_label "$requested")" >&2
      fi
    fi
    printf '%s\n' "$requested"
    return 0
  fi
  if ! is_interactive; then
    die "Task manager selection is required" \
      "Use --task-manager vikunja, --task-manager super-productivity, or --task-manager todoist."
  fi
  if [[ -z "$current" ]]; then
    printf "\n  ${BOLD}Choose the task manager:${NC}\n\n" >&2
    printf "    [1] Super Productivity + self-hosted SuperSync\n" >&2
    printf "    [2] Vikunja\n" >&2
    printf "    [3] Todoist (hosted)\n" >&2
    while true; do
      printf "\n  > " >&2
      read -r choice || die "Task manager selection is required"
      case "$choice" in
        1) printf 'super-productivity\n'; return 0 ;;
        2) printf 'vikunja\n'; return 0 ;;
        3) printf 'todoist\n'; return 0 ;;
        *) printf "  Enter 1, 2, or 3. There is no default.\n" >&2 ;;
      esac
    done
  fi
  case "$current" in
    vikunja) target_a=super-productivity; target_b=todoist ;;
    super-productivity) target_a=vikunja; target_b=todoist ;;
    todoist) target_a=vikunja; target_b=super-productivity ;;
  esac
  printf "\n  ${BOLD}Task manager detected: %s${NC}\n\n" "$(workspace_task_manager_label "$current")" >&2
  printf "    [1] Keep and reconcile %s\n" "$(workspace_task_manager_label "$current")" >&2
  printf "    [2] Migrate to %s (complete teardown of the current task manager)\n" "$(workspace_task_manager_label "$target_a")" >&2
  printf "    [3] Migrate to %s (complete teardown of the current task manager)\n" "$(workspace_task_manager_label "$target_b")" >&2
  while true; do
    printf "\n  > " >&2
    read -r choice || die "Task manager selection is required"
    case "$choice" in
      1) printf '%s\n' "$current"; return 0 ;;
      2) requested="$target_a" ;;
      3) requested="$target_b" ;;
      *) printf "  Enter 1, 2, or 3. There is no default.\n" >&2; continue ;;
    esac
    [[ "$check_only" == "1" ]] || workspace_confirm_task_manager_migration "$current" "$requested"
    printf '%s\n' "$requested"
    return 0
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
    warn "Using the workspace email for both the task manager and n8n"
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
      SPARK_WORKSPACE_TASK_MANAGER \
      SPARK_WORKSPACE_VIKUNJA_USERNAME SPARK_WORKSPACE_VIKUNJA_EMAIL \
      SPARK_WORKSPACE_TODOIST_TOKEN \
      SPARK_WORKSPACE_VIKUNJA_PASSWORD SPARK_WORKSPACE_N8N_EMAIL SPARK_WORKSPACE_N8N_PASSWORD; do
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

workspace_remote_persisted_task_manager() {
  local spec="$1" status manager
  [[ "$spec" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._:-]+$ ]] || return 1
  REMOTE_USER="${spec%@*}"
  REMOTE_HOST="${spec#*@}"
  open_remote "$REMOTE_USER" "$REMOTE_HOST" >/dev/null || return 1
  set +e
  status=$(printf '%s\n' \
    "${TGT_PATH} source \"\$(command -v spark)\"; workspace_persisted_task_manager" \
    | remote_in "bash -s" 2>/dev/null)
  set -e
  close_remote >/dev/null 2>&1 || true
  manager=$(printf '%s\n' "$status" | \
    sed -n -e '/^vikunja$/p' -e '/^super-productivity$/p' | tail -n 1)
  workspace_task_manager_valid "$manager" || return 1
  printf '%s\n' "$manager"
}

workspace_setup_remote() {
  local spec="$1" check_only="$2" auto_yes="$3" requested_model="$4" requested_tail_mode="${5:-}"
  local task_manager="${6:-}" postgres_image="${7:-}" vikunja_image="${8:-}" n8n_image="${9:-}"
  local super_productivity_image="${10:-}" supersync_image="${11:-}" funnel_action="${12:-}" args=()
  args=(setup)
  [[ "$check_only" == "1" ]] && args+=(--check)
  [[ "$auto_yes" == "1" ]] && args+=(--yes)
  [[ -n "$requested_model" ]] && args+=(--model "$requested_model")
  [[ -n "$requested_tail_mode" ]] && args+=(--tailscale-mode "$requested_tail_mode")
  [[ -n "$task_manager" ]] && args+=(--task-manager "$task_manager")
  [[ -n "$postgres_image" ]] && args+=(--postgres-image "$postgres_image")
  [[ -n "$vikunja_image" ]] && args+=(--vikunja-image "$vikunja_image")
  [[ -n "$n8n_image" ]] && args+=(--n8n-image "$n8n_image")
  [[ -n "$super_productivity_image" ]] && args+=(--super-productivity-image "$super_productivity_image")
  [[ -n "$supersync_image" ]] && args+=(--supersync-image "$supersync_image")
  [[ -n "$funnel_action" ]] && args+=(--funnel-action "$funnel_action")
  workspace_remote_workspace_cmd "$spec" "${args[@]}"
}

workspace_setup() {
  local auto_yes=0 check_only=0 requested_model="" remote_spec="" requested_tail_mode="" requested_task_manager="" task_manager=""
  local previous_task_manager="" pending_task_manager="" teardown_task_manager="" teardown_task_manager_images=""
  local postgres_image="" vikunja_image="" n8n_image="" super_productivity_image="" supersync_image="" model tailnet
  local vikunja_username="" vikunja_email="" vikunja_password="" vikunja_password_file=""
  local token="" n8n_email_arg="" n8n_password_arg="" n8n_password_file="" funnel_action=""
  local existing_model="" existing_tail_mode="" effective_tail_mode="" env_tail_mode="" setup_overrides=0
  env_tail_mode="${SPARK_WORKSPACE_TAILSCALE_MODE:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) auto_yes=1; shift ;;
      --check) check_only=1; shift ;;
      --model) requested_model="${2:-}"; [[ -n "$requested_model" ]] || die "--model requires a value"; shift 2 ;;
      --remote) remote_spec="${2:-}"; [[ -n "$remote_spec" ]] || die "--remote requires user@host"; shift 2 ;;
      --task-manager)
        requested_task_manager="${2:-}"
        workspace_task_manager_valid "$requested_task_manager" || die "--task-manager must be 'vikunja', 'super-productivity', or 'todoist'"
        shift 2
        ;;
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
      --super-productivity-image) super_productivity_image="${2:-}"; [[ -n "$super_productivity_image" ]] || die "--super-productivity-image requires a value"; shift 2 ;;
      --supersync-image) supersync_image="${2:-}"; [[ -n "$supersync_image" ]] || die "--supersync-image requires a value"; shift 2 ;;
      --n8n-image) n8n_image="${2:-}"; [[ -n "$n8n_image" ]] || die "--n8n-image requires a value"; shift 2 ;;
      --vikunja-username) vikunja_username="${2:-}"; [[ -n "$vikunja_username" ]] || die "--vikunja-username requires a value"; shift 2 ;;
      --vikunja-email) vikunja_email="${2:-}"; [[ -n "$vikunja_email" ]] || die "--vikunja-email requires a value"; shift 2 ;;
      --vikunja-password) vikunja_password="${2:-}"; [[ -n "$vikunja_password" ]] || die "--vikunja-password requires a value"; shift 2 ;;
      --vikunja-password-file) vikunja_password_file="${2:-}"; [[ -n "$vikunja_password_file" ]] || die "--vikunja-password-file requires a path"; shift 2 ;;
      --token) token="${2:-}"; [[ -n "$token" ]] || die "--token requires a value"; shift 2 ;;
      --n8n-email) n8n_email_arg="${2:-}"; [[ -n "$n8n_email_arg" ]] || die "--n8n-email requires a value"; shift 2 ;;
      --n8n-password) n8n_password_arg="${2:-}"; [[ -n "$n8n_password_arg" ]] || die "--n8n-password requires a value"; shift 2 ;;
      --n8n-password-file) n8n_password_file="${2:-}"; [[ -n "$n8n_password_file" ]] || die "--n8n-password-file requires a path"; shift 2 ;;
      --no-smtp) warn "--no-smtp is no longer needed; SMTP support was removed"; shift ;;
      --smtp|--smtp-*) die "SMTP support was removed" "Use: spark ws recover vikunja|n8n" ;;
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
  [[ -z "$vikunja_password" || -z "$vikunja_password_file" ]] || die "Use only one of --vikunja-password or --vikunja-password-file"
  [[ -z "$n8n_password_arg" || -z "$n8n_password_file" ]] || die "Use only one of --n8n-password or --n8n-password-file"
  [[ -n "$vikunja_password_file" ]] && vikunja_password=$(workspace_read_secret_file "Vikunja password" "$vikunja_password_file")
  [[ -n "$n8n_password_file" ]] && n8n_password_arg=$(workspace_read_secret_file "n8n password" "$n8n_password_file")
  [[ -n "$vikunja_password" ]] && { workspace_require_prompt_value "Vikunja password" "$vikunja_password" text; warn "Direct password flags may remain in shell history; prefer --vikunja-password-file"; }
  [[ -n "$vikunja_password" ]] && SPARK_WORKSPACE_VIKUNJA_PASSWORD="$vikunja_password"
  [[ -n "$token" ]] && { workspace_require_prompt_value "Todoist API token" "$token" text; warn "--token may remain in shell history"; SPARK_WORKSPACE_TODOIST_TOKEN="$token"; }
  [[ -n "$n8n_email_arg" ]] && SPARK_WORKSPACE_N8N_EMAIL="$n8n_email_arg"
  [[ -n "$n8n_password_arg" ]] && { workspace_require_prompt_value "n8n password" "$n8n_password_arg" text; warn "Direct password flags may remain in shell history; prefer --n8n-password-file"; }
  [[ -n "$n8n_password_arg" ]] && SPARK_WORKSPACE_N8N_PASSWORD="$n8n_password_arg"
  if [[ -n "$remote_spec" ]]; then
    previous_task_manager=$(workspace_remote_persisted_task_manager "$remote_spec" 2>/dev/null || true)
  else
    previous_task_manager=$(workspace_persisted_task_manager 2>/dev/null || true)
    pending_task_manager=$(workspace_read_env WORKSPACE_TASK_MANAGER_TEARDOWN_PENDING 2>/dev/null || true)
  fi
  task_manager=$(workspace_select_task_manager \
    "$requested_task_manager" "$previous_task_manager" "$check_only")
  SPARK_WORKSPACE_TASK_MANAGER="$task_manager"
  teardown_task_manager=$(workspace_teardown_task_manager_candidate \
    "$previous_task_manager" "$pending_task_manager" "$task_manager" 2>/dev/null || true)
  if workspace_task_manager_valid "$teardown_task_manager"; then
    teardown_task_manager_images=$(workspace_task_manager_teardown_images "$teardown_task_manager" 2>/dev/null || true)
  fi
  if [[ "$task_manager" == "super-productivity" && ( "$requested_tail_mode" == "ports" || "$env_tail_mode" == "ports" ) ]]; then
    die "SuperSync requires HTTPS; --tailscale-mode ports is not supported" "Use Tailscale Services mode."
  fi
  if [[ "$task_manager" != "vikunja" && ( -n "$vikunja_username" || -n "$vikunja_email" || -n "$vikunja_password" || -n "$vikunja_image" ) ]]; then
    die "Vikunja flags cannot be used with --task-manager ${task_manager}"
  fi
  if [[ "$task_manager" != "todoist" && -n "$token" ]]; then
    die "--token requires --task-manager todoist"
  fi
  workspace_reconcile_identity_overrides
  [[ -n "$postgres_image" ]] && workspace_validate_image_ref "Postgres image" "$postgres_image"
  [[ -n "$vikunja_image" ]] && workspace_validate_image_ref "Vikunja image" "$vikunja_image"
  [[ -n "$super_productivity_image" ]] && workspace_validate_image_ref "Super Productivity Electron image" "$super_productivity_image"
  [[ -n "$supersync_image" ]] && workspace_validate_image_ref "SuperSync image" "$supersync_image"
  [[ -n "$n8n_image" ]] && workspace_validate_image_ref "n8n image" "$n8n_image"
  [[ -z "$remote_spec" ]] || {
    if [[ "$check_only" != "1" ]]; then
      [[ -n "$requested_model" ]] || die "--model is required with --remote ws setup"
      SPARK_WORKSPACE_VIKUNJA_USERNAME=$(workspace_prompt_username_choice SPARK_WORKSPACE_VIKUNJA_USERNAME "Workspace username" "$(whoami)")
      SPARK_WORKSPACE_VIKUNJA_EMAIL=$(workspace_prompt SPARK_WORKSPACE_VIKUNJA_EMAIL "Workspace email" "" 0 email)
      SPARK_WORKSPACE_N8N_EMAIL="$SPARK_WORKSPACE_VIKUNJA_EMAIL"
      workspace_require_prompt_value "Workspace username" "$SPARK_WORKSPACE_VIKUNJA_USERNAME" username
      workspace_require_prompt_value "Workspace email" "$SPARK_WORKSPACE_VIKUNJA_EMAIL" email
      workspace_require_prompt_value "n8n admin email" "$SPARK_WORKSPACE_N8N_EMAIL" email
      if [[ "$task_manager" == "todoist" ]]; then
        SPARK_WORKSPACE_TODOIST_TOKEN=$(workspace_prompt SPARK_WORKSPACE_TODOIST_TOKEN "Todoist API token" "" 1 text)
        workspace_require_prompt_value "Todoist API token" "$SPARK_WORKSPACE_TODOIST_TOKEN" text
      fi
      export SPARK_WORKSPACE_VIKUNJA_USERNAME SPARK_WORKSPACE_VIKUNJA_EMAIL
      [[ -n "${SPARK_WORKSPACE_TODOIST_TOKEN:-}" ]] && export SPARK_WORKSPACE_TODOIST_TOKEN
      export SPARK_WORKSPACE_N8N_EMAIL
    fi
    workspace_setup_remote "$remote_spec" "$check_only" "$auto_yes" "$requested_model" \
      "$requested_tail_mode" "$task_manager" "$postgres_image" "$vikunja_image" "$n8n_image" \
      "$super_productivity_image" "$supersync_image" "$funnel_action"
    return $?
  }
  if [[ -z "$requested_tail_mode" && -n "$env_tail_mode" ]]; then
    case "$env_tail_mode" in
      services|ports)
        requested_tail_mode="$env_tail_mode"
        ;;
      *) die "SPARK_WORKSPACE_TAILSCALE_MODE must be 'services' or 'ports'" ;;
    esac
  fi
  [[ -n "$requested_tail_mode" ]] && SPARK_WORKSPACE_TAILSCALE_MODE="$requested_tail_mode"
  [[ -n "$postgres_image" ]] && SPARK_WORKSPACE_POSTGRES_IMAGE="$postgres_image"
  [[ -n "$vikunja_image" ]] && SPARK_WORKSPACE_VIKUNJA_IMAGE="$vikunja_image"
  [[ -n "$super_productivity_image" ]] && SPARK_WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_IMAGE="$super_productivity_image"
  [[ -n "$supersync_image" ]] && SPARK_WORKSPACE_SUPERSYNC_IMAGE="$supersync_image"
  [[ -n "$n8n_image" ]] && SPARK_WORKSPACE_N8N_IMAGE="$n8n_image"
  SETUP_FAILED=()
  SETUP_SKIPPED=()
  WORKSPACE_SETUP_RESUME_HINT=""
  printf "\n  ${BOLD}spark ws setup${NC} — %s + n8n + Hermes\n\n" "$(workspace_task_manager_label "$task_manager")"
  workspace_preflight "$check_only" || true
  existing_model=$(workspace_read_env HERMES_MODEL 2>/dev/null || true)
  existing_tail_mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  effective_tail_mode="${requested_tail_mode:-services}"
  if [[ -n "$teardown_task_manager" || -n "$requested_model" || -n "$postgres_image" || -n "$vikunja_image" || -n "$super_productivity_image" || -n "$supersync_image" || -n "$n8n_image" || -n "$funnel_action" || -n "$vikunja_username" || -n "$vikunja_email" || -n "$vikunja_password" || -n "$token" || -n "$n8n_email_arg" || -n "$n8n_password_arg" || "$effective_tail_mode" != "$existing_tail_mode" ]]; then
    setup_overrides=1
  fi
  if [[ -n "${SPARK_WORKSPACE_POSTGRES_IMAGE:-}" || -n "${SPARK_WORKSPACE_VIKUNJA_IMAGE:-}" || -n "${SPARK_WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_IMAGE:-}" || -n "${SPARK_WORKSPACE_SUPERSYNC_IMAGE:-}" || -n "${SPARK_WORKSPACE_N8N_IMAGE:-}" || -n "${SPARK_WORKSPACE_TAILSCALE_MODE:-}" ]]; then
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
  SPARK_WORKSPACE_TAILSCALE_MODE="$effective_tail_mode"
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
  workspace_migrate_runtime_config
  local human_user human_email human_pass n8n_email n8n_pass n8n_folder_pass vikunja_previous_status n8n_previous_status setup_rc
  local existing_human_user existing_human_email existing_n8n_email
  if [[ "$task_manager" == "super-productivity" ]]; then
    existing_human_user=$(workspace_existing_prompt_value N8N_OWNER_FIRST_NAME "workspace username" username || true)
    existing_human_email=$(workspace_existing_prompt_value SUPER_PRODUCTIVITY_USER_EMAIL "Super Productivity user email" email || true)
  elif [[ "$task_manager" == "todoist" ]]; then
    existing_human_user=$(workspace_existing_prompt_value N8N_OWNER_FIRST_NAME "workspace username" username || true)
    existing_human_email=$(workspace_existing_prompt_value N8N_BASIC_AUTH_USER "workspace email" email || true)
  else
    existing_human_user=$(workspace_existing_prompt_value VIKUNJA_HUMAN_USERNAME "Vikunja human username" username || true)
    existing_human_email=$(workspace_existing_prompt_value VIKUNJA_HUMAN_EMAIL "Vikunja human email" email || true)
  fi
  existing_n8n_email=$(workspace_existing_prompt_value N8N_BASIC_AUTH_USER "n8n admin email" email || true)
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
  if [[ "$task_manager" == "todoist" ]]; then
    [[ -n "${SPARK_WORKSPACE_TODOIST_TOKEN:-}" ]] || SPARK_WORKSPACE_TODOIST_TOKEN=$(workspace_read_env TODOIST_API_TOKEN 2>/dev/null || true)
    SPARK_WORKSPACE_TODOIST_TOKEN=$(workspace_prompt SPARK_WORKSPACE_TODOIST_TOKEN "Todoist API token" "" 1 text)
    workspace_require_prompt_value "Todoist API token" "$SPARK_WORKSPACE_TODOIST_TOKEN" text
  fi
  vikunja_previous_status=$(workspace_read_env VIKUNJA_HUMAN_USER_STATUS 2>/dev/null || true)
  if [[ "$task_manager" != "vikunja" ]]; then
    human_pass=""
  elif [[ -n "${SPARK_WORKSPACE_VIKUNJA_PASSWORD:-}" ]]; then
    human_pass="$SPARK_WORKSPACE_VIKUNJA_PASSWORD"
  elif [[ "$vikunja_previous_status" =~ ^(created|exists)$ ]]; then
    human_pass=""
  else
    human_pass=$(workspace_random_password)
  fi
  n8n_pass="${SPARK_WORKSPACE_N8N_PASSWORD:-$(workspace_random_password)}"
  [[ -z "$human_pass" || "$human_pass" != "$n8n_pass" ]] || die "Vikunja and n8n passwords must be different"
  workspace_require_prompt_value "Workspace username" "$human_user" username
  workspace_require_prompt_value "Workspace email" "$human_email" email
  workspace_require_prompt_value "n8n admin email" "$n8n_email" email
  n8n_previous_status=$(workspace_read_env N8N_OWNER_SETUP_STATUS 2>/dev/null || true)
  WORKSPACE_SHOW_VIKUNJA_PASSWORD=0
  WORKSPACE_SHOW_N8N_PASSWORD=0
  WORKSPACE_SUPERSYNC_PASSKEY_ENROLLMENT_URL=""
  workspace_write_files "$tailnet" "$human_user" "$human_email" "$human_pass" "$n8n_email" "$n8n_pass" "$model" || {
    workspace_summary
    return $?
  }
  if workspace_task_manager_valid "$teardown_task_manager" && [[ "$teardown_task_manager" != "$task_manager" ]]; then
    workspace_set_env_key WORKSPACE_TASK_MANAGER_TEARDOWN_PENDING "$teardown_task_manager"
    [[ -n "$teardown_task_manager_images" ]] && \
      workspace_set_env_key WORKSPACE_TASK_MANAGER_TEARDOWN_IMAGES "$teardown_task_manager_images"
  fi
  if [[ "$task_manager" == "super-productivity" ]]; then
    workspace_prepare_super_productivity_runtime || {
      workspace_summary
      return 1
    }
  fi
  workspace_compose up -d --remove-orphans && info "Compose project ${WORKSPACE_PROJECT} started" || setup_fail "Could not start workspace compose"
  workspace_ensure_postgres_databases
  if [[ "$check_only" != "1" ]]; then
    workspace_start_hermes_dashboard_proxy || setup_fail "Could not start Hermes Tailscale dashboard proxy"
  fi
  workspace_configure_tailscale "$tailnet" "$check_only" "$funnel_action" "$auto_yes"
  if workspace_tailscale_services_mode && workspace_tailscale_service_host_advertised; then
    if command -v nemohermes >/dev/null 2>&1; then
      workspace_start_hermes_gateway_proxy \
        && workspace_setup_hermes "$model" "$tailnet" "$check_only" \
        || setup_fail "Could not expose LiteLLM on the private OpenShell bridge"
    else
      workspace_setup_hermes "$model" "$tailnet" "$check_only"
    fi
  else
    workspace_set_env_key HERMES_ONBOARD_STATUS manual
    setup_fail "Hermes onboarding skipped until Tailscale private access is configured"
  fi
  case "$task_manager" in
    super-productivity)
      workspace_setup_hermes_super_productivity_access \
        || setup_fail "Could not give Hermes private Super Productivity API access"
      ;;
    todoist)
      workspace_setup_hermes_todoist_access \
        || setup_fail "Could not give Hermes verified Todoist API access"
      ;;
    *)
      workspace_create_vikunja_users "$human_pass" || die "Could not configure Vikunja bot-hermes automatically" "Fix Vikunja and rerun spark ws setup"
      workspace_setup_hermes_vikunja_access \
        || setup_fail "Could not give Hermes verified Vikunja API access"
      [[ ! "$vikunja_previous_status" =~ ^(created|exists)$ && "$(workspace_read_env VIKUNJA_HUMAN_USER_STATUS 2>/dev/null || true)" == "created" ]] \
        && WORKSPACE_SHOW_VIKUNJA_PASSWORD=1
      ;;
  esac
  if [[ "$n8n_previous_status" =~ ^(created|exists)$ ]]; then
    info "n8n owner already configured: ${n8n_email}"
    n8n_folder_pass="${SPARK_WORKSPACE_N8N_PASSWORD:-}"
  else
    workspace_create_n8n_owner "$n8n_email" "$n8n_pass" || true
    [[ "$(workspace_read_env N8N_OWNER_SETUP_STATUS 2>/dev/null || true)" == "created" ]] && WORKSPACE_SHOW_N8N_PASSWORD=1
    n8n_folder_pass="$n8n_pass"
  fi
  workspace_ensure_n8n_hermes_folder "$n8n_email" "$n8n_folder_pass" \
    || setup_fail "Could not reconcile the n8n Hermes folder"
  if workspace_tailscale_services_mode && workspace_tailscale_service_host_advertised; then
    if workspace_tailscale_urls_ready_after_setup; then
      workspace_tailscale_clear_error
      info "Tailscale workspace URLs reachable"
    else
      workspace_tailscale_mark_error url-unreachable
      setup_fail "Tailscale workspace URLs are not reachable yet"
    fi
  fi
  workspace_finalize_task_manager_teardown "$teardown_task_manager" "$task_manager" \
    || setup_fail "Could not remove the abandoned $(workspace_task_manager_label "$teardown_task_manager") services, images and data"
  if [[ "$task_manager" == "super-productivity" ]]; then
    if [[ "${#SETUP_FAILED[@]}" -eq 0 ]]; then
      workspace_complete_super_productivity_browser_sync || true
    else
      warn "Super Productivity browser onboarding deferred until infrastructure issues are fixed"
    fi
  fi
  setup_rc=0
  workspace_summary || setup_rc=$?
  workspace_print_initial_credentials "$human_user" "$human_email" "$human_pass" "$n8n_email" "$n8n_pass"
  unset SPARK_WORKSPACE_VIKUNJA_PASSWORD SPARK_WORKSPACE_TODOIST_TOKEN SPARK_WORKSPACE_N8N_PASSWORD human_pass n8n_pass
  return "$setup_rc"
}

workspace_print_verbose_hermes_status() {
  local out json
  json=$(nemohermes hermes status --json 2>/dev/null || true)
  if command -v jq >/dev/null 2>&1 && printf '%s\n' "$json" | jq -e . >/dev/null 2>&1; then
    printf "  ${BOLD}NemoHermes details${NC}\n"
    printf '%s\n' "$json" | jq .
    return 0
  fi
  out=$(nemohermes hermes status 2>/dev/null || nemohermes status 2>/dev/null || true)
  printf '%s\n' "$out" | awk '
    /Sandbox-scoped status for/ { capture=1 }
    capture {
      scoped = scoped $0 ORS
      if ($0 ~ /^[[:space:]]*Agent:[[:space:]]/) {
        capture=0
        captured=1
      }
      next
    }
    {
      print
      if (captured && ! inserted && $0 ~ /Revision:/) {
        printf "\n%s", scoped
        inserted=1
      }
    }
    END {
      if (captured && ! inserted) printf "\n%s", scoped
    }
  '
}

workspace_service_runtime_state() {
  local service="$1"
  workspace_compose_service_running "$service" || { printf 'stopped\n'; return 1; }
  case "$service" in
    vikunja) workspace_vikunja_http_ready && { printf 'ready\n'; return 0; } ;;
    supersync) workspace_supersync_http_ready && { printf 'ready\n'; return 0; } ;;
    super-productivity-electron) workspace_super_productivity_api_ready && { printf 'ready\n'; return 0; } ;;
    n8n) workspace_n8n_http_ready && { printf 'ready\n'; return 0; } ;;
    postgres) printf 'running\n'; return 0 ;;
  esac
  printf 'running-not-ready\n'
  return 1
}

workspace_hermes_runtime_state() {
  local container age
  container=$(workspace_hermes_running_container_name 2>/dev/null || true)
  [[ -n "$container" ]] || { printf 'stopped\n'; return 1; }
  workspace_hermes_local_api_ready && { printf 'ready\n'; return 0; }
  age=$(container_age_seconds "$container" 2>/dev/null || true)
  if [[ "$age" =~ ^[0-9]+$ && "$age" -lt 600 ]]; then printf 'starting\n'; else printf 'unhealthy\n'; fi
  return 1
}

workspace_access_runtime_state() {
  workspace_tailscale_connected || { printf 'disconnected\n'; return 1; }
  workspace_tailscale_services_configured || { printf 'not-configured\n'; return 1; }
  printf 'ready\n'
}

workspace_status_operational() {
  local task_manager task_service
  workspace_configured || return 1
  task_manager=$(workspace_task_manager)
  [[ "$(workspace_service_runtime_state postgres || true)" == "running" ]] || return 1
  if [[ "$task_manager" == "todoist" ]]; then
    workspace_hermes_todoist_api_ready || return 1
  else
    task_service=vikunja
    [[ "$task_manager" == "super-productivity" ]] && task_service=supersync
    [[ "$(workspace_service_runtime_state "$task_service" || true)" == "ready" ]] || return 1
    if [[ "$task_manager" == "super-productivity" ]]; then
      [[ "$(workspace_service_runtime_state super-productivity-electron || true)" == "ready" ]] || return 1
    fi
  fi
  [[ "$(workspace_service_runtime_state n8n || true)" == "ready" ]] || return 1
  [[ "$(workspace_hermes_runtime_state || true)" == "ready" ]] || return 1
  [[ "$(workspace_access_runtime_state || true)" == "ready" ]] || return 1
  case "$task_manager" in
    super-productivity) workspace_hermes_super_productivity_api_ready ;;
    todoist) workspace_hermes_todoist_api_ready ;;
    *) workspace_hermes_vikunja_api_ready ;;
  esac
}

workspace_print_service_row() {
  local state="$1" service="$2" access="$3" color
  case "$state" in
    ready|running) color="$GREEN" ;;
    stopped|starting|running-not-ready) color="$YELLOW" ;;
    unhealthy) color="$RED" ;;
    *) color="$DIM" ;;
  esac
  printf "  ${color}%-20s${NC} %-22s %s\n" "$state" "$service" "$access"
}

workspace_print_status_summary() {
  local postgres_state task_state electron_state n8n_state hermes_state access_state mode model task_manager task_service
  local task_url n8n_url hermes_url
  task_manager=$(workspace_task_manager)
  task_service=vikunja
  [[ "$task_manager" == "super-productivity" ]] && task_service=supersync
  postgres_state=$(workspace_service_runtime_state postgres || true)
  if [[ "$task_manager" == "todoist" ]]; then
    task_state=unavailable
    workspace_hermes_todoist_api_ready && task_state=ready
  else
    task_state=$(workspace_service_runtime_state "$task_service" || true)
  fi
  electron_state=$(workspace_service_runtime_state super-productivity-electron || true)
  n8n_state=$(workspace_service_runtime_state n8n || true)
  hermes_state=$(workspace_hermes_runtime_state || true)
  access_state=$(workspace_access_runtime_state || true)
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  model=$(workspace_read_env HERMES_MODEL 2>/dev/null || true)
  task_url=$(workspace_task_manager_url)
  n8n_url=$(workspace_read_env N8N_URL 2>/dev/null || true)
  hermes_url=$(workspace_read_env HERMES_URL 2>/dev/null || true)

  printf "\n  ${BOLD}Workspace services${NC}\n"
  printf "  ${DIM}%-20s %-22s %s${NC}\n" "STATE" "SERVICE" "ACCESS"
  workspace_print_service_row "$postgres_state" "Postgres" "internal"
  case "$task_manager" in
    super-productivity)
      workspace_print_service_row "$task_state" "SuperSync" "${task_url:-unset}"
      workspace_print_service_row "$electron_state" "Electron API for Hermes" "private bridge"
      ;;
    todoist) workspace_print_service_row "$task_state" "Todoist API" "hosted" ;;
    *) workspace_print_service_row "$task_state" "Vikunja" "${task_url:-unset}" ;;
  esac
  workspace_print_service_row "$n8n_state" "n8n" "${n8n_url:-unset}"
  workspace_print_service_row "$hermes_state" "Hermes" "${hermes_url:-unset}"

  printf "\n  ${BOLD}Agent workspace${NC}\n"
  printf "  %-22s %s\n" "Mode" "${mode:-unset}"
  printf "  %-22s %s\n" "Task manager" "$(workspace_task_manager_label "$task_manager")"
  printf "  %-22s %s\n" "Hermes model" "${model:-unset}"
  printf "  %-22s %s\n" "Private access" "$access_state"
}

workspace_status_json() {
  local ok=false postgres_state task_state n8n_state hermes_state access_state mode model task_manager task_service
  local task_url n8n_url hermes_url task_alias="" task_extra="" supersync_state electron_state
  workspace_status_operational && ok=true
  task_manager=$(workspace_task_manager)
  task_service=vikunja
  [[ "$task_manager" == "super-productivity" ]] && task_service=supersync
  postgres_state=$(workspace_service_runtime_state postgres || true)
  if [[ "$task_manager" == "todoist" ]]; then
    task_state=unavailable
    workspace_hermes_todoist_api_ready && task_state=ready
  else
    task_state=$(workspace_service_runtime_state "$task_service" || true)
  fi
  if [[ "$task_manager" == "super-productivity" ]]; then
    supersync_state="$task_state"
    electron_state=$(workspace_service_runtime_state super-productivity-electron || true)
    task_extra=$(printf ',"supersync":{"state":"%s"},"electron_api":{"state":"%s"}' \
      "$supersync_state" "$electron_state")
  fi
  n8n_state=$(workspace_service_runtime_state n8n || true)
  hermes_state=$(workspace_hermes_runtime_state || true)
  access_state=$(workspace_access_runtime_state || true)
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  model=$(workspace_read_env HERMES_MODEL 2>/dev/null || true)
  task_url=$(workspace_task_manager_url)
  case "$task_manager" in
    super-productivity)
      task_alias=$(printf ',"super_productivity":{"state":"%s","url":"%s"}' \
        "$task_state" "$(workspace_json_escape "$task_url")")
      ;;
    todoist)
      task_alias=$(printf ',"todoist":{"state":"%s","url":"%s"}' \
        "$task_state" "$(workspace_json_escape "$task_url")")
      ;;
    *)
      task_alias=$(printf ',"vikunja":{"state":"%s","url":"%s"}' \
        "$task_state" "$(workspace_json_escape "$task_url")")
      ;;
  esac
  n8n_url=$(workspace_read_env N8N_URL 2>/dev/null || true)
  hermes_url=$(workspace_read_env HERMES_URL 2>/dev/null || true)
  printf '{"ok":%s,"mode":"%s","task_manager":"%s","hermes_model":"%s","access":"%s","services":{"postgres":{"state":"%s"},"task_manager":{"state":"%s","url":"%s"}%s%s,"n8n":{"state":"%s","url":"%s"},"hermes":{"state":"%s","url":"%s"}}}\n' \
    "$ok" "$(workspace_json_escape "$mode")" "$task_manager" "$(workspace_json_escape "$model")" \
    "$access_state" "$postgres_state" "$task_state" "$(workspace_json_escape "$task_url")" \
    "$task_alias" "$task_extra" "$n8n_state" "$(workspace_json_escape "$n8n_url")" "$hermes_state" "$(workspace_json_escape "$hermes_url")"
  [[ "$ok" == "true" ]]
}

cmd_workspace_containers() {
  [[ $# -eq 0 ]] || die "Usage: spark ws containers"
  printf "\n  ${BOLD}spark ws containers${NC}\n\n"
  workspace_configured || die "Workspace not configured" "Run: spark ws setup"
  workspace_compose ps 2>/dev/null || warn "Compose project ${WORKSPACE_PROJECT} not reachable"
  printf "\n"
  docker ps --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null \
    | grep -E '(^NAMES|openshell-hermes|spark-hermes-(litellm|dashboard|vikunja|super-productivity)-proxy)' || true
  printf "\n"
}

cmd_workspace_status() {
  local verbose=0 json_mode=0 quiet=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verbose) verbose=1 ;;
      --json) json_mode=1 ;;
      --quiet) quiet=1 ;;
      --help|-h)
        printf "Usage: spark ws status [--verbose] [--json|--quiet]\n"
        printf "  --verbose  Include full NemoHermes sandbox and policy details.\n"
        return 0
        ;;
      *) die "Unknown ws status option: $1" "Usage: spark ws status [--verbose] [--json|--quiet]" ;;
    esac
    shift
  done
  [[ "$json_mode" == "1" && "$quiet" == "1" ]] && die "Choose either --json or --quiet"
  [[ "$json_mode" == "1" ]] && { workspace_status_json; return $?; }
  [[ "$quiet" == "1" ]] && { workspace_status_operational; return $?; }
  printf "\n  ${BOLD}spark ws status${NC}\n"
  if ! workspace_configured; then
    warn "Workspace not configured"
    printf "\n"
    return 1
  fi
  workspace_print_status_summary
  if [[ "$verbose" == "1" ]] && command -v nemohermes >/dev/null 2>&1; then
    printf "\n"
    workspace_print_verbose_hermes_status
  elif ! command -v nemohermes >/dev/null 2>&1; then
    warn "NemoHermes not installed"
  fi
  printf "\n"
  workspace_status_operational
}

workspace_migrate_runtime_config() {
  workspace_remove_legacy_human_passwords
  workspace_remove_legacy_smtp
  workspace_remove_transient_n8n_owner_config
}

workspace_print_tailscale_runtime_status() {
  local mode out
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  if [[ "$mode" == "services" ]]; then
    out=$(tailscale serve get-config --all 2>/dev/null || true)
    if workspace_tailscale_services_local_configured_from_output "$out"; then
      info "Tailscale Services configured"
    else
      warn "Tailscale Services not configured"
    fi
    return 0
  fi
  tailscale serve status 2>/dev/null || warn "No Tailscale Serve status"
}

workspace_start() {
  [[ $# -eq 0 ]] || die "Usage: spark ws start"
  local model tailnet rc=0

  printf "\n  ${BOLD}spark ws start${NC}\n\n"
  workspace_configured || die "Workspace not configured" "Run: spark ws setup"
  workspace_migrate_runtime_config
  model=$(workspace_read_env HERMES_MODEL 2>/dev/null || true)
  [[ -n "$model" ]] || die "Hermes model is not configured" "Run: spark ws setup"

  workspace_compose up -d --remove-orphans >/dev/null 2>&1 \
    && info "Workspace Compose project started" \
    || { err "Could not start workspace Compose project"; rc=1; }

  SETUP_FAILED=()
  workspace_ensure_gateway 0 1 "$model"
  if [[ ${#SETUP_FAILED[@]} -gt 0 ]]; then
    rc=1
  fi

  workspace_start_hermes_gateway_proxy \
    && info "Hermes inference bridge started" \
    || { err "Could not start Hermes inference bridge"; rc=1; }

  case "$(workspace_task_manager)" in
    super-productivity)
      workspace_start_hermes_super_productivity_proxy \
        && info "Hermes Super Productivity API bridge started" \
        || { err "Could not start Hermes Super Productivity API bridge"; rc=1; }
      ;;
    todoist) info "Hermes Todoist API uses the restricted external endpoint" ;;
    *)
      workspace_start_hermes_vikunja_proxy \
        && info "Hermes Vikunja API bridge started" \
        || { err "Could not start Hermes Vikunja API bridge"; rc=1; }
      ;;
  esac

  workspace_start_hermes_dashboard_proxy \
    && info "Hermes dashboard proxy started" \
    || { err "Could not start Hermes dashboard proxy"; rc=1; }

  tailnet=$(workspace_tailnet_suffix 2>/dev/null || true)
  if workspace_tailscale_services_configured; then
    info "Tailscale workspace access configured"
  elif [[ -n "$tailnet" ]]; then
    workspace_configure_tailscale "$tailnet" 0 abort 1
    [[ ${#SETUP_FAILED[@]} -eq 0 ]] || rc=1
  else
    warn "Tailscale workspace access unavailable"
    rc=1
  fi

  if workspace_start_hermes_private_proxy; then
    info "Hermes/NemoClaw started"
  else
    err "Could not start Hermes/NemoClaw"
    rc=1
  fi

  [[ "$rc" -eq 0 ]] && info "Workspace started" || err "Workspace started with errors; run spark ws doctor"
  printf "\n"
  return "$rc"
}

workspace_stop() {
  [[ $# -eq 0 ]] || die "Usage: spark ws stop"
  local hermes_container="" model="" rc=0

  printf "\n  ${BOLD}spark ws stop${NC}\n\n"
  workspace_configured || die "Workspace not configured" "Run: spark ws setup"
  model=$(workspace_read_env HERMES_MODEL 2>/dev/null || true)

  hermes_container=$(workspace_hermes_running_container_name 2>/dev/null || true)
  if [[ -n "$hermes_container" ]]; then
    workspace_pause_hermes_private_proxy &&
      info "Paused Hermes/NemoClaw (${hermes_container}); sandbox state preserved" ||
      { err "Could not pause Hermes/NemoClaw (${hermes_container})"; rc=1; }
  else
    info "Hermes/NemoClaw already stopped"
  fi

  workspace_stop_hermes_gateway_proxy
  info "Stopped Hermes inference bridge"
  workspace_stop_hermes_vikunja_proxy
  workspace_stop_hermes_super_productivity_proxy
  info "Stopped Hermes task manager API bridge"
  workspace_stop_hermes_dashboard_proxy
  info "Stopped Hermes dashboard proxy"

  gateway_stop || rc=1

  if [[ -n "$model" ]] && workspace_model_running "$model"; then
    SPARK_SKIP_GATEWAY_REFRESH=1 cmd_stop "$model" || rc=1
  else
    info "Workspace model already stopped"
  fi

  workspace_compose stop >/dev/null 2>&1 \
    && info "Stopped workspace Compose project (${WORKSPACE_PROJECT})" \
    || { err "Could not stop workspace Compose project"; rc=1; }

  [[ "$rc" -eq 0 ]] && info "Workspace stopped; data and configuration preserved"
  printf "\n"
  return "$rc"
}

workspace_restart() {
  [[ $# -eq 0 ]] || die "Usage: spark ws restart"
  workspace_stop
  workspace_start
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
  local model task_manager
  model=$(workspace_read_env HERMES_MODEL 2>/dev/null || true)
  task_manager=$(workspace_task_manager)
  printf "\n  ${BOLD}Workspace health${NC}\n"
  workspace_status_item "Compose postgres" workspace_compose_service_running postgres
  if [[ "$task_manager" == "super-productivity" ]]; then
    workspace_status_item "Compose SuperSync" workspace_compose_service_running supersync
    workspace_status_item "Compose Electron API" workspace_compose_service_running super-productivity-electron
  else
    workspace_status_item "Compose Vikunja" workspace_compose_service_running vikunja
  fi
  workspace_status_item "Compose n8n" workspace_compose_service_running n8n
  workspace_status_item "Task manager HTTP local" workspace_task_manager_http_ready
  workspace_status_item "n8n HTTP local" workspace_n8n_http_ready
  workspace_status_item "Task manager private URL" workspace_task_manager_private_url_ready
  workspace_status_item "n8n private URL" workspace_n8n_private_url_ready
  workspace_status_item "Hermes private URL" workspace_hermes_private_status_url_ready
  workspace_status_item "No public listeners" workspace_host_listeners_loopback_only
  workspace_status_item "LiteLLM gateway" workspace_gateway_running
  workspace_status_item "Hermes inference bridge" workspace_hermes_gateway_proxy_running
  if [[ "$task_manager" == "super-productivity" ]]; then
    workspace_status_item "Hermes Super Productivity API bridge" workspace_hermes_super_productivity_proxy_running
  else
    workspace_status_item "Hermes Vikunja API bridge" workspace_hermes_vikunja_proxy_running
  fi
  workspace_status_item "Hermes dashboard proxy" workspace_hermes_dashboard_proxy_running
  workspace_status_item "LiteLLM Hermes route" workspace_litellm_model_routed
  workspace_status_item "Hermes model" workspace_model_running "$model"
  workspace_status_item "Hermes/NemoClaw" workspace_hermes_running
  workspace_status_item "NemoHermes inference route" workspace_hermes_inference_route_ready
}

cmd_workspace_logs() {
  local target="${1:-}"
  case "$target" in
    ""|-h|--help)
      printf "\n  Usage: spark ws logs [task-manager|vikunja|super-productivity|supersync|electron|n8n|postgres|hermes|gateway]\n\n" ;;
    task-manager)
      workspace_require_config
      case "$(workspace_task_manager)" in
        super-productivity) workspace_compose logs -f supersync super-productivity-electron ;;
        todoist) info "Todoist is hosted; no local task-manager logs" ;;
        *) workspace_compose logs -f vikunja ;;
      esac ;;
    todoist) info "Todoist is hosted; no local logs" ;;
    super-productivity)
      workspace_require_config
      workspace_compose logs -f supersync super-productivity-electron ;;
    electron)
      workspace_require_config
      workspace_compose logs -f super-productivity-electron ;;
    vikunja|supersync|n8n|postgres)
      workspace_require_config
      workspace_compose logs -f "$target" ;;
    gateway)
      gateway_logs -f ;;
    hermes)
      nemohermes hermes logs 2>/dev/null || nemohermes logs 2>/dev/null || die "Could not read Hermes logs" ;;
    *) die "Unknown workspace log target: $target" ;;
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
  local task_manager="${1:-$(workspace_task_manager)}"
  printf '%s\n' workspace-config.tgz
  case "$task_manager" in
    super-productivity) printf '%s\n' super-productivity-electron.tgz supersync.sql ;;
    vikunja) printf '%s\n' vikunja.zip vikunja.sql ;;
  esac
  printf '%s\n' n8n.sql hermes-snapshot.status nemoclaw-backup.status
}

workspace_backup_write_checksums() {
  local dir="$1" task_manager="${2:-$(workspace_task_manager)}" file hash checksums
  checksums="${dir}/checksums.sha256"
  : > "$checksums"
  while IFS= read -r file; do
    [[ -s "${dir}/${file}" ]] || return 1
    hash=$(workspace_sha256_file "${dir}/${file}") || return 1
    printf '%s  %s\n' "$hash" "$file" >> "$checksums"
  done < <(workspace_backup_payload_files "$task_manager")
  chmod 600 "$checksums"
}

workspace_backup_verify_checksums() {
  local dir="$1" task_manager="$2" checksums expected file actual required failures=0
  checksums="${dir}/checksums.sha256"
  [[ -f "$checksums" ]] || { warn "checksums.sha256 missing"; return 1; }
  while IFS= read -r required; do
    awk -v file="$required" '
      $1 ~ /^[0-9a-fA-F]{64}$/ && $2 == file && NF == 2 { found=1 }
      END { exit !found }
    ' "$checksums" \
      || { warn "Checksum entry missing: ${required}"; failures=$((failures + 1)); }
  done < <(workspace_backup_payload_files "$task_manager")
  while read -r expected file; do
    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ && "$file" =~ ^[A-Za-z0-9._-]+$ ]] \
      || { warn "Invalid checksum entry: ${file:-missing-file}"; failures=$((failures + 1)); continue; }
    workspace_backup_payload_files "$task_manager" | grep -Fxq "$file" \
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
  local dir="$1" manifest failures=0 key file task_manager status_keys
  [[ -n "$dir" ]] || die "backup --verify requires a backup directory"
  manifest="${dir}/manifest.env"
  [[ -d "$dir" ]] || { err "Backup directory missing: $dir"; return 1; }
  [[ -f "$manifest" ]] || { err "Backup manifest missing: $manifest"; return 1; }
  task_manager=$(sed -n 's/^TASK_MANAGER=//p' "$manifest" | head -1)
  [[ -n "$task_manager" ]] || task_manager=vikunja
  workspace_task_manager_valid "$task_manager" || { err "Backup task manager missing or invalid"; return 1; }
  workspace_file_mode_is "$dir" 700 || { warn "Backup directory mode must be 0700"; failures=$((failures + 1)); }
  status_keys="WORKSPACE_CONFIG_STATUS N8N_DB_STATUS HERMES_SNAPSHOT_STATUS NEMOCLAW_BACKUP_ALL_STATUS CHECKSUMS_STATUS"
  if [[ "$task_manager" == "super-productivity" ]]; then
    status_keys="$status_keys SUPER_PRODUCTIVITY_ELECTRON_STATUS SUPERSYNC_DB_STATUS"
  elif [[ "$task_manager" == "vikunja" ]]; then
    status_keys="$status_keys VIKUNJA_DUMP_STATUS VIKUNJA_DB_STATUS"
  fi
  for key in $status_keys; do
    grep -q "^${key}=ok$" "$manifest" || { warn "Backup manifest not ok: ${key}"; failures=$((failures + 1)); }
  done
  [[ -s "${dir}/workspace-config.tgz" ]] && tar -tzf "${dir}/workspace-config.tgz" >/dev/null 2>&1 \
    || { warn "workspace-config.tgz missing or unreadable"; failures=$((failures + 1)); }
  if [[ "$task_manager" == "super-productivity" ]]; then
    [[ -s "${dir}/super-productivity-electron.tgz" ]] && tar -tzf "${dir}/super-productivity-electron.tgz" >/dev/null 2>&1 \
      || { warn "super-productivity-electron.tgz missing or unreadable"; failures=$((failures + 1)); }
    [[ -s "${dir}/supersync.sql" ]] || { warn "supersync.sql missing or empty"; failures=$((failures + 1)); }
  elif [[ "$task_manager" == "vikunja" ]]; then
    [[ -s "${dir}/vikunja.zip" ]] || { warn "vikunja.zip missing or empty"; failures=$((failures + 1)); }
    [[ -s "${dir}/vikunja.sql" ]] || { warn "vikunja.sql missing or empty"; failures=$((failures + 1)); }
  fi
  [[ -s "${dir}/n8n.sql" ]] || { warn "n8n.sql missing or empty"; failures=$((failures + 1)); }
  [[ -s "${dir}/hermes-snapshot.status" ]] || { warn "hermes-snapshot.status missing or empty"; failures=$((failures + 1)); }
  [[ -s "${dir}/nemoclaw-backup.status" ]] || { warn "nemoclaw-backup.status missing or empty"; failures=$((failures + 1)); }
  [[ -s "${dir}/checksums.sha256" ]] || { warn "checksums.sha256 missing or empty"; failures=$((failures + 1)); }
  for file in manifest.env checksums.sha256 $(workspace_backup_payload_files "$task_manager"); do
    [[ -e "${dir}/${file}" ]] && workspace_file_mode_is "${dir}/${file}" 600 \
      || { warn "${file} mode must be 0600"; failures=$((failures + 1)); }
  done
  workspace_backup_verify_checksums "$dir" "$task_manager" || failures=$((failures + 1))
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
  local ts dir manifest task_manager electron_was_running=0 failures=0 old_umask
  task_manager=$(workspace_task_manager)
  ts=$(date +%Y%m%d-%H%M%S)
  dir="${WORKSPACE_DATA_DIR}/backups/${ts}"
  mkdir -p "$dir"
  chmod 700 "$dir"
  manifest="${dir}/manifest.env"
  old_umask=$(umask)
  umask 077
  : > "$manifest"
  printf 'CREATED_AT=%s\n' "$ts" >> "$manifest"
  printf 'TASK_MANAGER=%s\n' "$task_manager" >> "$manifest"
  tar -C "$WORKSPACE_CONFIG_DIR" -czf "$dir/workspace-config.tgz" . >/dev/null 2>&1 \
    && { printf 'WORKSPACE_CONFIG_STATUS=ok\n' >> "$manifest"; info "Backed up workspace config"; } \
    || { printf 'WORKSPACE_CONFIG_STATUS=failed\n' >> "$manifest"; warn "Could not back up workspace config"; failures=$((failures + 1)); }
  if [[ "$task_manager" == "super-productivity" ]]; then
    workspace_compose_service_running super-productivity-electron && electron_was_running=1
    [[ "$electron_was_running" == "0" ]] || workspace_compose pause super-productivity-electron >/dev/null 2>&1 || true
    tar -C "$WORKSPACE_DATA_DIR" -czf "$dir/super-productivity-electron.tgz" super-productivity-electron >/dev/null 2>&1 \
      && { printf 'SUPER_PRODUCTIVITY_ELECTRON_STATUS=ok\n' >> "$manifest"; info "Backed up Super Productivity Electron data"; } \
      || { printf 'SUPER_PRODUCTIVITY_ELECTRON_STATUS=failed\n' >> "$manifest"; warn "Could not back up Super Productivity Electron data"; failures=$((failures + 1)); }
    [[ "$electron_was_running" == "0" ]] || workspace_compose unpause super-productivity-electron >/dev/null 2>&1 || true
    workspace_compose exec -T -e "PGPASSWORD=$(workspace_read_env SUPERSYNC_DATABASE_PASSWORD)" postgres pg_dump -U supersync supersync > "$dir/supersync.sql" 2>/dev/null \
      && { printf 'SUPERSYNC_DB_STATUS=ok\n' >> "$manifest"; info "Backed up SuperSync Postgres"; } \
      || { printf 'SUPERSYNC_DB_STATUS=failed\n' >> "$manifest"; warn "Could not dump SuperSync Postgres"; failures=$((failures + 1)); }
  elif [[ "$task_manager" == "vikunja" ]]; then
    workspace_compose exec -T vikunja /app/vikunja/vikunja dump -p /tmp -f vikunja.zip >/dev/null 2>&1 \
      && workspace_compose cp vikunja:/tmp/vikunja.zip "$dir/vikunja.zip" >/dev/null 2>&1 \
      && { printf 'VIKUNJA_DUMP_STATUS=ok\n' >> "$manifest"; info "Backed up Vikunja dump"; } \
      || { printf 'VIKUNJA_DUMP_STATUS=failed\n' >> "$manifest"; warn "Could not create Vikunja dump"; failures=$((failures + 1)); }
    workspace_compose exec -T -e "PGPASSWORD=$(workspace_read_env VIKUNJA_DATABASE_PASSWORD)" postgres pg_dump -U vikunja vikunja > "$dir/vikunja.sql" 2>/dev/null \
      && { printf 'VIKUNJA_DB_STATUS=ok\n' >> "$manifest"; info "Backed up Vikunja Postgres"; } \
      || { printf 'VIKUNJA_DB_STATUS=failed\n' >> "$manifest"; warn "Could not dump Vikunja Postgres"; failures=$((failures + 1)); }
  fi
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
  workspace_backup_write_checksums "$dir" "$task_manager" \
    && { printf 'CHECKSUMS_STATUS=ok\n' >> "$manifest"; info "Wrote backup checksums"; } \
    || { printf 'CHECKSUMS_STATUS=failed\n' >> "$manifest"; warn "Could not write backup checksums"; failures=$((failures + 1)); }
  chmod 600 "$manifest" "$dir"/* 2>/dev/null || true
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
WORKSPACE_DOCTOR_VERBOSE=0
WORKSPACE_DOCTOR_TOTAL=0
WORKSPACE_DOCTOR_PASSED=0
WORKSPACE_DOCTOR_CATEGORY=""
WORKSPACE_DOCTOR_ACTION=""
WORKSPACE_DOCTOR_JSON_ITEMS=()
WORKSPACE_DOCTOR_CATEGORIES=()
WORKSPACE_DOCTOR_LABELS=()
WORKSPACE_DOCTOR_RESULTS=()
WORKSPACE_DOCTOR_ACTIONS=()
WORKSPACE_DOCTOR_SECTIONS=()

workspace_doctor_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  printf '%s' "$s"
}

workspace_doctor_section() {
  WORKSPACE_DOCTOR_CATEGORY="$1"
  WORKSPACE_DOCTOR_ACTION="$2"
  WORKSPACE_DOCTOR_SECTIONS+=("$1")
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
  WORKSPACE_DOCTOR_TOTAL=$((WORKSPACE_DOCTOR_TOTAL + 1))
  WORKSPACE_DOCTOR_CATEGORIES+=("$WORKSPACE_DOCTOR_CATEGORY")
  WORKSPACE_DOCTOR_LABELS+=("$label")
  WORKSPACE_DOCTOR_ACTIONS+=("$WORKSPACE_DOCTOR_ACTION")
  if "$@"; then
    WORKSPACE_DOCTOR_PASSED=$((WORKSPACE_DOCTOR_PASSED + 1))
    WORKSPACE_DOCTOR_RESULTS+=("ok")
    WORKSPACE_DOCTOR_JSON_ITEMS+=("{\"id\":\"$(workspace_doctor_json_escape "$id")\",\"category\":\"$(workspace_doctor_json_escape "$WORKSPACE_DOCTOR_CATEGORY")\",\"label\":\"$(workspace_doctor_json_escape "$label")\",\"ok\":true,\"action\":\"$(workspace_doctor_json_escape "$WORKSPACE_DOCTOR_ACTION")\"}")
  else
    WORKSPACE_DOCTOR_FAILED=$((WORKSPACE_DOCTOR_FAILED + 1))
    WORKSPACE_DOCTOR_RESULTS+=("fail")
    WORKSPACE_DOCTOR_JSON_ITEMS+=("{\"id\":\"$(workspace_doctor_json_escape "$id")\",\"category\":\"$(workspace_doctor_json_escape "$WORKSPACE_DOCTOR_CATEGORY")\",\"label\":\"$(workspace_doctor_json_escape "$label")\",\"ok\":false,\"action\":\"$(workspace_doctor_json_escape "$WORKSPACE_DOCTOR_ACTION")\"}")
  fi
}

workspace_doctor_print_json() {
  local model="$1" items="" first=1 category i category_passed category_failed
  if [[ ${#WORKSPACE_DOCTOR_JSON_ITEMS[@]} -gt 0 ]]; then
    local IFS=,
    items="${WORKSPACE_DOCTOR_JSON_ITEMS[*]}"
  fi
  printf '{"ok":%s,"passed":%d,"failed":%d,"total":%d,"model":"%s","areas":[' \
    "$( [[ "$WORKSPACE_DOCTOR_FAILED" -eq 0 ]] && printf true || printf false )" \
    "$WORKSPACE_DOCTOR_PASSED" "$WORKSPACE_DOCTOR_FAILED" "$WORKSPACE_DOCTOR_TOTAL" \
    "$(workspace_doctor_json_escape "$model")"
  for category in "${WORKSPACE_DOCTOR_SECTIONS[@]}"; do
    category_passed=0; category_failed=0
    for i in "${!WORKSPACE_DOCTOR_CATEGORIES[@]}"; do
      [[ "${WORKSPACE_DOCTOR_CATEGORIES[$i]}" == "$category" ]] || continue
      if [[ "${WORKSPACE_DOCTOR_RESULTS[$i]}" == "ok" ]]; then
        category_passed=$((category_passed + 1))
      else
        category_failed=$((category_failed + 1))
      fi
    done
    [[ "$first" == "1" ]] || printf ','
    first=0
    printf '{"name":"%s","passed":%d,"failed":%d,"total":%d}' \
      "$(workspace_doctor_json_escape "$category")" "$category_passed" "$category_failed" "$((category_passed + category_failed))"
  done
  printf '],"checks":[%s]}\n' "$items"
}

workspace_doctor_print_human() {
  local category i category_passed category_failed state action compatibility_label
  printf "\n  ${BOLD}spark ws doctor${NC}\n\n"
  printf "  ${BOLD}Result${NC}\n"
  if [[ "$WORKSPACE_DOCTOR_FAILED" -eq 0 ]]; then
    printf "  ${GREEN}ok${NC}         %d/%d checks passed\n" "$WORKSPACE_DOCTOR_PASSED" "$WORKSPACE_DOCTOR_TOTAL"
  else
    printf "  ${RED}attention${NC}  %d/%d checks passed · %d issue(s)\n" \
      "$WORKSPACE_DOCTOR_PASSED" "$WORKSPACE_DOCTOR_TOTAL" "$WORKSPACE_DOCTOR_FAILED"
  fi

  printf "\n  ${BOLD}Areas${NC}\n"
  for category in "${WORKSPACE_DOCTOR_SECTIONS[@]}"; do
    category_passed=0; category_failed=0
    for i in "${!WORKSPACE_DOCTOR_CATEGORIES[@]}"; do
      [[ "${WORKSPACE_DOCTOR_CATEGORIES[$i]}" == "$category" ]] || continue
      if [[ "${WORKSPACE_DOCTOR_RESULTS[$i]}" == "ok" ]]; then
        category_passed=$((category_passed + 1))
      else
        category_failed=$((category_failed + 1))
      fi
    done
    if [[ "$category_failed" -eq 0 ]]; then state="${GREEN}ok${NC}"; else state="${RED}issue${NC}"; fi
    printf "  %-16b %-24s %d/%d\n" "$state" "$category" "$category_passed" "$((category_passed + category_failed))"
  done

  if [[ "$WORKSPACE_DOCTOR_FAILED" -gt 0 ]]; then
    printf "\n  ${BOLD}Issues${NC}\n"
    for i in "${!WORKSPACE_DOCTOR_LABELS[@]}"; do
      [[ "${WORKSPACE_DOCTOR_RESULTS[$i]}" == "fail" ]] || continue
      printf "  ${RED}[ ]${NC} %s\n" "${WORKSPACE_DOCTOR_LABELS[$i]}"
      printf "      Area: %s\n" "${WORKSPACE_DOCTOR_CATEGORIES[$i]}"
      action="${WORKSPACE_DOCTOR_ACTIONS[$i]}"
      [[ -z "$action" ]] || printf "      Try:  %s\n" "$action"
    done
  fi

  if [[ "$WORKSPACE_DOCTOR_VERBOSE" == "1" ]]; then
    printf "\n  ${BOLD}Checks${NC}\n"
    for i in "${!WORKSPACE_DOCTOR_LABELS[@]}"; do
      if [[ "${WORKSPACE_DOCTOR_RESULTS[$i]}" == "ok" ]]; then state="${GREEN}[x]${NC}"; else state="${RED}[ ]${NC}"; fi
      printf "  %b %s · %s\n" "$state" "${WORKSPACE_DOCTOR_LABELS[$i]}" "${WORKSPACE_DOCTOR_CATEGORIES[$i]}"
      compatibility_label=""
      if [[ "$(workspace_task_manager)" == "vikunja" ]]; then
        case "${WORKSPACE_DOCTOR_LABELS[$i]}" in
          "Shared Postgres initializes Vikunja and n8n DBs")
            compatibility_label="Shared Postgres initializes task manager and n8n DBs" ;;
          "Shared Postgres runtime has Vikunja and n8n roles/databases")
            compatibility_label="Shared Postgres runtime has task manager and n8n roles/databases" ;;
          "Tailscale local config maps vikunja, n8n, hermes")
            compatibility_label="Tailscale local config maps tasks, n8n, hermes" ;;
        esac
      fi
      [[ -z "$compatibility_label" ]] || printf "  %b %s · %s\n" "$state" "$compatibility_label" "${WORKSPACE_DOCTOR_CATEGORIES[$i]}"
    done
  fi
  printf "\n"
}

workspace_env_has() {
  local key val
  for key in "$@"; do
    val=$(workspace_read_env "$key" || true)
    [[ -n "$val" ]] || return 1
  done
}

workspace_human_password_not_stored() {
  local file task_env="$WORKSPACE_VIKUNJA_ENV_FILE" manager
  local -a files=("$WORKSPACE_ENV_FILE" "$WORKSPACE_N8N_ENV_FILE")
  manager=$(workspace_task_manager)
  [[ "$manager" == "super-productivity" ]] && task_env="$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE"
  [[ "$manager" == "todoist" ]] || files+=("$task_env")
  for file in "${files[@]}"; do
    [[ -f "$file" ]] || return 1
    ! grep -Eq '^(VIKUNJA_HUMAN_(PASSWORD|RECOVERY_PASSWORD)|VIKUNJA_HERMES_PASSWORD|N8N_BASIC_AUTH_PASSWORD)=' "$file" || return 1
  done
}

workspace_credentials_are_distinct() {
  local key val seen keys
  seen=""
  case "$(workspace_task_manager)" in
    super-productivity)
      keys="POSTGRES_PASSWORD SUPERSYNC_DATABASE_PASSWORD SUPERSYNC_JWT_SECRET SUPERSYNC_ACCESS_TOKEN SUPERSYNC_ENCRYPTION_PASSWORD DB_POSTGRESDB_PASSWORD N8N_ENCRYPTION_KEY WORKSPACE_MENTION_SECRET"
      ;;
    todoist)
      keys="POSTGRES_PASSWORD DB_POSTGRESDB_PASSWORD N8N_ENCRYPTION_KEY WORKSPACE_MENTION_SECRET TODOIST_API_TOKEN"
      ;;
    *)
      keys="POSTGRES_PASSWORD VIKUNJA_DATABASE_PASSWORD DB_POSTGRESDB_PASSWORD VIKUNJA_SERVICE_SECRET N8N_ENCRYPTION_KEY WORKSPACE_MENTION_SECRET VIKUNJA_HERMES_API_TOKEN"
      ;;
  esac
  for key in $keys; do
    val=$(workspace_read_env "$key" || true)
    [[ -n "$val" ]] || return 1
    if printf '%s\n' "$seen" | grep -Fqx -- "$val"; then
      return 1
    fi
    seen="${seen}${val}"$'\n'
  done
  return 0
}

workspace_no_legacy_recovery_config() {
  local file task_env="$WORKSPACE_VIKUNJA_ENV_FILE" manager
  local -a files=("$WORKSPACE_ENV_FILE" "$WORKSPACE_N8N_ENV_FILE")
  manager=$(workspace_task_manager)
  [[ "$manager" == "super-productivity" ]] && task_env="$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE"
  [[ "$manager" == "todoist" ]] || files+=("$task_env")
  for file in "${files[@]}"; do
    [[ -f "$file" ]] || return 1
    ! grep -Eq '^(WORKSPACE_SMTP_|VIKUNJA_MAILER_|N8N_SMTP_|N8N_EMAIL_MODE=|VIKUNJA_HERMES_(USERNAME|PASSWORD|USER_STATUS)=|N8N_INSTANCE_OWNER_(MANAGED_BY_ENV|EMAIL|FIRST_NAME|LAST_NAME|PASSWORD_HASH)=)' "$file" || return 1
  done
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
  local task_env="$WORKSPACE_VIKUNJA_ENV_FILE" manager
  manager=$(workspace_task_manager)
  [[ "$manager" == "super-productivity" ]] && task_env="$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE"
  workspace_env_file_syntax_valid "$WORKSPACE_POSTGRES_ENV_FILE" &&
    workspace_env_file_syntax_valid "$WORKSPACE_N8N_ENV_FILE" || return 1
  [[ "$manager" == "todoist" ]] && return 0
  workspace_env_file_syntax_valid "$task_env"
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
  local task_db=vikunja task_user=vikunja manager
  manager=$(workspace_task_manager)
  if [[ "$manager" == "super-productivity" ]]; then
    task_db=supersync
    task_user=supersync
  fi
  [[ -f "$WORKSPACE_COMPOSE_FILE" && -f "${WORKSPACE_CONFIG_DIR}/init-db.sh" ]] || return 1
  workspace_compose_mentions_service postgres &&
    ! workspace_compose_mentions_service vikunja-db &&
    ! workspace_compose_mentions_service n8n-db &&
    grep -q 'CREATE DATABASE n8n' "${WORKSPACE_CONFIG_DIR}/init-db.sh" &&
    grep -q 'WHERE NOT EXISTS' "${WORKSPACE_CONFIG_DIR}/init-db.sh" &&
    grep -q 'ALTER USER n8n' "${WORKSPACE_CONFIG_DIR}/init-db.sh" || return 1
  [[ "$manager" == "todoist" ]] && return 0
  grep -q "CREATE DATABASE ${task_db}" "${WORKSPACE_CONFIG_DIR}/init-db.sh" &&
    grep -q "ALTER USER ${task_user}" "${WORKSPACE_CONFIG_DIR}/init-db.sh"
}

workspace_postgres_shared_runtime_ready() {
  local task_db=vikunja manager
  manager=$(workspace_task_manager)
  [[ "$manager" == "super-productivity" ]] && task_db=supersync
  workspace_postgres_role_exists n8n && workspace_postgres_db_exists n8n || return 1
  [[ "$manager" == "todoist" ]] && return 0
  workspace_postgres_role_exists "$task_db" && workspace_postgres_db_exists "$task_db"
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
  local mode bind_addr task_container_port=3456 manager
  [[ -f "$WORKSPACE_COMPOSE_FILE" ]] || return 1
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  bind_addr=127.0.0.1
  [[ "$mode" == "ports" ]] && bind_addr=$(workspace_read_env WORKSPACE_TAILSCALE_BIND_ADDR 2>/dev/null || true)
  if [[ "$mode" == "ports" ]]; then
    workspace_tailscale_bind_addr_ok "$bind_addr" || return 1
  else
    workspace_private_bind_addr_ok "$bind_addr" || return 1
  fi
  manager=$(workspace_task_manager)
  [[ "$manager" != "super-productivity" ]] || task_container_port=1900
  grep -Fq "${bind_addr}:${WORKSPACE_N8N_PORT}:5678" "$WORKSPACE_COMPOSE_FILE" || return 1
  if [[ "$manager" != "todoist" ]]; then
    grep -Fq "${bind_addr}:${WORKSPACE_TASK_MANAGER_PORT}:${task_container_port}" "$WORKSPACE_COMPOSE_FILE" || return 1
  fi
  if [[ "$manager" == "super-productivity" ]]; then
    grep -Fq "127.0.0.1:${WORKSPACE_SUPER_PRODUCTIVITY_API_PORT}:3877" "$WORKSPACE_COMPOSE_FILE" || return 1
  fi
  ! grep -qE '0[.]0[.]0[.]0:|:::[0-9]+|[[]::[]]:' "$WORKSPACE_COMPOSE_FILE"
}

workspace_vikunja_locked_down() {
  [[ -f "$WORKSPACE_VIKUNJA_ENV_FILE" ]] || return 1
  grep -q '^VIKUNJA_SERVICE_ENABLEREGISTRATION=false$' "$WORKSPACE_VIKUNJA_ENV_FILE" &&
    grep -q '^VIKUNJA_SERVICE_ENABLELINKSHARING=false$' "$WORKSPACE_VIKUNJA_ENV_FILE"
}

workspace_vikunja_doctor_ok() {
  local out fail_lines other_failures
  out=$(workspace_vikunja_cli doctor 2>&1) && return 0
  fail_lines=$(printf '%s\n' "$out" | grep '^[[:space:]]*✗ ' || true)
  [[ -n "$fail_lines" ]] || return 1
  other_failures=$(printf '%s\n' "$fail_lines" | grep -v 'Ownership match:' || true)
  [[ -z "$other_failures" ]] &&
    printf '%s\n' "$out" | grep -q 'Writable: yes'
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
  local task_env="$WORKSPACE_VIKUNJA_ENV_FILE" manager
  manager=$(workspace_task_manager)
  [[ "$manager" == "super-productivity" ]] && task_env="$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE"
  [[ -f "$WORKSPACE_POSTGRES_ENV_FILE" && -f "$WORKSPACE_N8N_ENV_FILE" ]] &&
    workspace_file_mode_is "$WORKSPACE_POSTGRES_ENV_FILE" 600 &&
    workspace_file_mode_is "$WORKSPACE_N8N_ENV_FILE" 600 || return 1
  [[ "$manager" == "todoist" ]] && return 0
  [[ -f "$task_env" ]] && workspace_file_mode_is "$task_env" 600
}

workspace_compose_uses_scoped_env_files() {
  local task_env="$WORKSPACE_VIKUNJA_ENV_FILE" manager
  manager=$(workspace_task_manager)
  [[ "$manager" == "super-productivity" ]] && task_env="$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE"
  [[ -f "$WORKSPACE_COMPOSE_FILE" ]] || return 1
  grep -Fq "$WORKSPACE_POSTGRES_ENV_FILE" "$WORKSPACE_COMPOSE_FILE" &&
    grep -Fq "$WORKSPACE_N8N_ENV_FILE" "$WORKSPACE_COMPOSE_FILE" &&
    ! grep -Fq "$WORKSPACE_ENV_FILE" "$WORKSPACE_COMPOSE_FILE" || return 1
  [[ "$manager" == "todoist" ]] && return 0
  grep -Fq "$task_env" "$WORKSPACE_COMPOSE_FILE"
}

workspace_compose_images_configured() {
  local postgres_image task_image n8n_image image_keys="" key
  [[ -f "$WORKSPACE_COMPOSE_FILE" ]] || return 1
  postgres_image=$(workspace_read_env WORKSPACE_POSTGRES_IMAGE 2>/dev/null || true)
  n8n_image=$(workspace_read_env WORKSPACE_N8N_IMAGE 2>/dev/null || true)
  [[ -n "$postgres_image" && -n "$n8n_image" ]] &&
    grep -Fq "image: ${postgres_image}" "$WORKSPACE_COMPOSE_FILE" &&
    grep -Fq "image: ${n8n_image}" "$WORKSPACE_COMPOSE_FILE" || return 1
  case "$(workspace_task_manager)" in
    super-productivity) image_keys="WORKSPACE_SUPERSYNC_IMAGE WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_IMAGE" ;;
    vikunja) image_keys="WORKSPACE_VIKUNJA_IMAGE" ;;
  esac
  for key in $image_keys; do
    task_image=$(workspace_read_env "$key" 2>/dev/null || true)
    [[ -n "$task_image" ]] && grep -Fq "image: ${task_image}" "$WORKSPACE_COMPOSE_FILE" || return 1
  done
}

workspace_image_ref_pinned() {
  local ref="$1"
  [[ "$ref" == *@sha256:* ]] || [[ "$ref" == *:* && "$ref" != *:latest && "$ref" != *:main-latest ]]
}

workspace_compose_images_pinned() {
  local postgres_image task_image n8n_image image_keys="" key
  postgres_image=$(workspace_read_env WORKSPACE_POSTGRES_IMAGE 2>/dev/null || true)
  n8n_image=$(workspace_read_env WORKSPACE_N8N_IMAGE 2>/dev/null || true)
  workspace_image_ref_pinned "$postgres_image" && workspace_image_ref_pinned "$n8n_image" || return 1
  case "$(workspace_task_manager)" in
    super-productivity) image_keys="WORKSPACE_SUPERSYNC_IMAGE WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_IMAGE" ;;
    vikunja) image_keys="WORKSPACE_VIKUNJA_IMAGE" ;;
  esac
  for key in $image_keys; do
    task_image=$(workspace_read_env "$key" 2>/dev/null || true)
    workspace_image_ref_pinned "$task_image" || return 1
  done
}

workspace_compose_runtime_hardened() {
  local minimum=3
  [[ "$(workspace_task_manager)" == "super-productivity" ]] && minimum=4
  [[ "$(workspace_task_manager)" == "todoist" ]] && minimum=2
  [[ -f "$WORKSPACE_COMPOSE_FILE" ]] || return 1
  [[ "$(grep -c 'no-new-privileges:true' "$WORKSPACE_COMPOSE_FILE" 2>/dev/null || true)" -ge "$minimum" ]] &&
    [[ "$(grep -c 'init: true' "$WORKSPACE_COMPOSE_FILE" 2>/dev/null || true)" -ge "$minimum" ]] &&
    [[ "$(grep -c 'stop_grace_period: 30s' "$WORKSPACE_COMPOSE_FILE" 2>/dev/null || true)" -ge "$minimum" ]] &&
    [[ "$(grep -c 'pids_limit:' "$WORKSPACE_COMPOSE_FILE" 2>/dev/null || true)" -ge "$minimum" ]] &&
    [[ "$(grep -c 'max-size: "10m"' "$WORKSPACE_COMPOSE_FILE" 2>/dev/null || true)" -ge "$minimum" ]] &&
    [[ "$(grep -c 'max-file: "5"' "$WORKSPACE_COMPOSE_FILE" 2>/dev/null || true)" -ge "$minimum" ]]
}

workspace_n8n_owner_ready() {
  local status
  status=$(workspace_read_env N8N_OWNER_SETUP_STATUS 2>/dev/null || true)
  [[ "$status" =~ ^(created|exists)$ ]] && workspace_n8n_http_ready
}

workspace_n8n_hermes_folder_ready() {
  local status folder_id matches
  status=$(workspace_read_env N8N_HERMES_FOLDER_STATUS 2>/dev/null || true)
  folder_id=$(workspace_read_env N8N_HERMES_FOLDER_ID 2>/dev/null || true)
  [[ "$status" =~ ^(created|exists)$ && "$folder_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  matches=$(workspace_compose exec -T postgres psql -U n8n -d n8n -Atqc \
    "SELECT (SELECT count(*) FROM folder f JOIN project p ON p.id=f.\"projectId\" WHERE f.name='Hermes' AND f.\"parentFolderId\" IS NULL AND p.type='personal'), (SELECT count(*) FROM folder f JOIN project p ON p.id=f.\"projectId\" WHERE f.id='${folder_id}' AND f.name='Hermes' AND f.\"parentFolderId\" IS NULL AND p.type='personal');" \
    2>/dev/null | tail -1 | tr -d '[:space:]')
  [[ "$matches" == "1|1" ]]
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
  local username email expected_id actual_id
  username=$(workspace_read_env VIKUNJA_HUMAN_USERNAME 2>/dev/null || true)
  email=$(workspace_read_env VIKUNJA_HUMAN_EMAIL 2>/dev/null || true)
  expected_id=$(workspace_read_env VIKUNJA_HUMAN_USER_ID 2>/dev/null || true)
  [[ -n "$username" && -n "$email" && "$expected_id" =~ ^[1-9][0-9]*$ ]] || return 1
  actual_id=$(workspace_vikunja_user_id "$username" "$email" 2>/dev/null || true)
  [[ "$actual_id" == "$expected_id" ]] || return 1
  workspace_vikunja_user_ready "$username" "$email" VIKUNJA_HUMAN_USER_STATUS
}

workspace_vikunja_hermes_ready() {
  local username bot_id status
  username=$(workspace_read_env VIKUNJA_HERMES_BOT_USERNAME 2>/dev/null || true)
  bot_id=$(workspace_read_env VIKUNJA_HERMES_BOT_ID 2>/dev/null || true)
  status=$(workspace_read_env VIKUNJA_HERMES_BOT_STATUS 2>/dev/null || true)
  [[ "$username" == "$WORKSPACE_VIKUNJA_HERMES_BOT_USERNAME" ]] &&
    [[ "$bot_id" =~ ^[1-9][0-9]*$ ]] &&
    [[ "$status" == "created" || "$status" == "exists" ]]
}

workspace_vikunja_hermes_api_ready() {
  local token
  token=$(workspace_read_env VIKUNJA_HERMES_API_TOKEN 2>/dev/null || true)
  [[ -n "$token" ]] || return 1
  workspace_check_vikunja_token "$token" >/dev/null 2>&1
}

workspace_vikunja_hermes_project_access_ready() {
  [[ "$(workspace_read_env VIKUNJA_HERMES_PROJECT_ACCESS_STATUS 2>/dev/null || true)" == "verified" ]]
}

workspace_super_productivity_config_ready() {
  local url email token encryption
  url=$(workspace_task_manager_url)
  email=$(workspace_read_env SUPER_PRODUCTIVITY_USER_EMAIL 2>/dev/null || true)
  token=$(workspace_read_env SUPERSYNC_ACCESS_TOKEN 2>/dev/null || true)
  encryption=$(workspace_read_env SUPERSYNC_ENCRYPTION_PASSWORD 2>/dev/null || true)
  [[ -n "$url" && -n "$email" && -n "$token" && -n "$encryption" ]] &&
    [[ -f "$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE" ]] &&
    grep -q '^RUN_MIGRATIONS_ON_STARTUP=false$' "$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE" &&
    grep -q '^SPARK_HEADLESS=1$' "$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE"
}

workspace_todoist_config_ready() {
  [[ "$(workspace_task_manager)" == "todoist" ]] &&
    [[ "$(workspace_read_env TODOIST_API_URL 2>/dev/null || true)" == "$WORKSPACE_TODOIST_API_URL" ]] &&
    [[ "$(workspace_read_env TODOIST_URL 2>/dev/null || true)" == "$WORKSPACE_TODOIST_APP_URL" ]] &&
    [[ "$(workspace_read_env TODOIST_API_STATUS 2>/dev/null || true)" == "verified" ]] &&
    [[ -n "$(workspace_read_env TODOIST_API_TOKEN 2>/dev/null || true)" ]] &&
    ! grep -Fq 'TODOIST_API_TOKEN' "$WORKSPACE_POSTGRES_ENV_FILE" &&
    ! grep -Fq 'TODOIST_API_TOKEN' "$WORKSPACE_N8N_ENV_FILE"
}

workspace_todoist_no_local_service() {
  ! workspace_compose_mentions_service vikunja &&
    ! workspace_compose_mentions_service supersync &&
    ! workspace_compose_mentions_service super-productivity-electron
}

workspace_super_productivity_electron_build_ready() {
  [[ -s "${WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_DIR}/Dockerfile" ]] &&
    [[ -s "${WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_DIR}/entrypoint.sh" ]] &&
    [[ -s "${WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_DIR}/spark-headless.patch" ]]
}

workspace_supersync_user_ready() {
  local email pass record
  email=$(workspace_read_env SUPER_PRODUCTIVITY_USER_EMAIL 2>/dev/null || true)
  pass=$(workspace_read_env SUPERSYNC_DATABASE_PASSWORD 2>/dev/null || true)
  [[ -n "$email" && -n "$pass" ]] || return 1
  record=$(
    workspace_compose exec -T -e PGPASSWORD="$pass" postgres \
      psql -qAt -U supersync -d supersync -v email="$email" 2>/dev/null <<'SQL' || true
SELECT id || ':' || token_version
FROM users
WHERE email=lower(:'email') AND is_verified=1;
SQL
  )
  [[ "$record" =~ ^[1-9][0-9]*:[0-9]+$ ]]
}

workspace_supersync_token_ready() {
  local url token
  url=$(workspace_task_manager_url)
  token=$(workspace_read_env SUPERSYNC_ACCESS_TOKEN 2>/dev/null || true)
  [[ -n "$url" && -n "$token" ]] || return 1
  curl -fsS --max-time 5 -H "Authorization: Bearer ${token}" \
    "${url%/}/api/sync/status" >/dev/null 2>&1
}

workspace_urls_configured() {
  local task task_manager n8n hermes mode dns tailnet task_public n8n_host n8n_protocol n8n_cookie n8n_editor n8n_webhook expected_host
  task_manager=$(workspace_task_manager)
  task=$(workspace_task_manager_url)
  n8n=$(workspace_read_env N8N_URL 2>/dev/null || true)
  hermes=$(workspace_read_env HERMES_URL 2>/dev/null || true)
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  dns=$(workspace_read_env WORKSPACE_TAILSCALE_DNS_NAME 2>/dev/null || true)
  tailnet=$(workspace_tailnet_suffix 2>/dev/null || true)
  case "$task_manager" in
    super-productivity)
      task_public=$(sed -n 's/^PUBLIC_URL=//p' "$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE" 2>/dev/null | head -1)
      [[ "$(sed -n 's/^SUPERSYNC_INTERNAL_URL=//p' "$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE" 2>/dev/null | head -1)" == "http://supersync:1900" ]] || return 1
      grep -q "^CORS_ORIGINS=.*${task}.*https://app[.]super-productivity[.]com" "$WORKSPACE_SUPER_PRODUCTIVITY_ENV_FILE" || return 1
      ;;
    todoist) task_public=$(workspace_read_env TODOIST_URL 2>/dev/null || true) ;;
    *) task_public=$(sed -n 's/^VIKUNJA_SERVICE_PUBLICURL=//p' "$WORKSPACE_VIKUNJA_ENV_FILE" 2>/dev/null | head -1) ;;
  esac
  n8n_host=$(sed -n 's/^N8N_HOST=//p' "$WORKSPACE_N8N_ENV_FILE" 2>/dev/null | head -1)
  n8n_protocol=$(sed -n 's/^N8N_PROTOCOL=//p' "$WORKSPACE_N8N_ENV_FILE" 2>/dev/null | head -1)
  n8n_cookie=$(sed -n 's/^N8N_SECURE_COOKIE=//p' "$WORKSPACE_N8N_ENV_FILE" 2>/dev/null | head -1)
  n8n_editor=$(sed -n 's/^N8N_EDITOR_BASE_URL=//p' "$WORKSPACE_N8N_ENV_FILE" 2>/dev/null | head -1)
  n8n_webhook=$(sed -n 's/^WEBHOOK_URL=//p' "$WORKSPACE_N8N_ENV_FILE" 2>/dev/null | head -1)
  [[ -n "$task" && -n "$n8n" && -n "$hermes" && "$task_public" == "$task" ]] || return 1
  if [[ "$mode" == "services" ]]; then
    [[ -n "$tailnet" ]] || return 1
    expected_host="${n8n#https://}"
    [[ "$n8n" == "https://n8n.${tailnet}" && "$hermes" == "https://hermes.${tailnet}" ]] || return 1
    if [[ "$task_manager" == "todoist" ]]; then
      [[ "$task" == "$WORKSPACE_TODOIST_APP_URL" ]] || return 1
    else
      [[ "$task" == "https://${WORKSPACE_TASK_MANAGER_SERVICE}.${tailnet}" ]] || return 1
    fi
    [[ "$n8n_host" == "$expected_host" && "$n8n_protocol" == "https" && "$n8n_cookie" == "true" ]] &&
      [[ "$n8n_editor" == "$n8n" && "$n8n_webhook" == "$n8n" ]]
  elif [[ "$mode" == "ports" ]]; then
    workspace_tailscale_dns_name_ok "$dns" || return 1
    [[ "$n8n" == "http://${dns}:${WORKSPACE_N8N_PORT}" && "$hermes" == "http://${dns}:${WORKSPACE_HERMES_PORT}" ]] || return 1
    if [[ "$task_manager" == "todoist" ]]; then
      [[ "$task" == "$WORKSPACE_TODOIST_APP_URL" ]] || return 1
    else
      [[ "$task" == "http://${dns}:${WORKSPACE_TASK_MANAGER_PORT}" ]] || return 1
    fi
    [[ "$n8n_host" == "$dns" && "$n8n_protocol" == "http" && "$n8n_cookie" == "false" ]] &&
      [[ "$n8n_editor" == "$n8n" && "$n8n_webhook" == "$n8n" ]]
  else
    return 1
  fi
}

workspace_http_ready() {
  local url="$1"
  command -v curl >/dev/null 2>&1 || return 1
  curl -fsS --max-time 3 "$url" >/dev/null 2>&1 ||
    curl -4 -fsS --max-time 3 "$url" >/dev/null 2>&1
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

workspace_super_productivity_http_ready() {
  local mode url
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  if [[ "$mode" == "ports" ]]; then
    url=$(workspace_task_manager_url)
    [[ -n "$url" ]] || return 1
    workspace_http_ready "${url%/}/health"
    return $?
  fi
  workspace_http_ready "http://127.0.0.1:${WORKSPACE_TASK_MANAGER_PORT}/health"
}

workspace_supersync_http_ready() {
  workspace_http_ready "http://127.0.0.1:${WORKSPACE_TASK_MANAGER_PORT}/health"
}

workspace_super_productivity_api_ready() {
  local out
  out=$(curl -fsS --max-time 5 -H 'Host: 127.0.0.1:3876' \
    "http://127.0.0.1:${WORKSPACE_SUPER_PRODUCTIVITY_API_PORT}/health" 2>/dev/null) || return 1
  printf '%s\n' "$out" | jq -e '.ok == true and .data.rendererReady == true' >/dev/null 2>&1
}

workspace_task_manager_http_ready() {
  case "$(workspace_task_manager)" in
    super-productivity) workspace_super_productivity_http_ready ;;
    todoist) workspace_hermes_todoist_api_ready ;;
    *) workspace_vikunja_http_ready ;;
  esac
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

workspace_litellm_model_smoke() {
  local litellm_model escaped_model payload out
  litellm_model=$(workspace_read_env HERMES_LITELLM_MODEL 2>/dev/null || true)
  [[ -n "$litellm_model" ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  escaped_model=$(printf '%s' "$litellm_model" | sed 's/\\/\\\\/g; s/"/\\"/g')
  payload=$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with ok."}],"max_tokens":1,"temperature":0}' "$escaped_model")
  out=$(curl -fsS --max-time "${SPARK_WORKSPACE_LITELLM_SMOKE_TIMEOUT:-60}" \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    "http://127.0.0.1:${GATEWAY_PORT}/v1/chat/completions" 2>/dev/null) || return 1
  printf '%s\n' "$out" | grep -Fq '"choices"'
}

workspace_tailscale_https_urls_ready() {
  local task_url n8n hermes mode tailnet dns task_manager
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  [[ "$mode" == "services" || "$mode" == "ports" ]] || return 1
  task_manager=$(workspace_task_manager)
  task_url=$(workspace_task_manager_url)
  n8n=$(workspace_read_env N8N_URL 2>/dev/null || true)
  hermes=$(workspace_read_env HERMES_URL 2>/dev/null || true)
  if [[ "$mode" == "services" ]]; then
    tailnet=$(workspace_tailnet_suffix 2>/dev/null || true)
    [[ -n "$tailnet" ]] || return 1
    [[ "$n8n" == "https://n8n.${tailnet}" && "$hermes" == "https://hermes.${tailnet}" ]] || return 1
    if [[ "$task_manager" == "todoist" ]]; then
      [[ "$task_url" == "$WORKSPACE_TODOIST_APP_URL" ]] || return 1
    else
      [[ "$task_url" == "https://${WORKSPACE_TASK_MANAGER_SERVICE}.${tailnet}" ]] || return 1
    fi
  else
    dns=$(workspace_read_env WORKSPACE_TAILSCALE_DNS_NAME 2>/dev/null || true)
    workspace_tailscale_dns_name_ok "$dns" || return 1
    [[ "$n8n" == "http://${dns}:${WORKSPACE_N8N_PORT}" && "$hermes" == "http://${dns}:${WORKSPACE_HERMES_PORT}" ]] || return 1
    if [[ "$task_manager" == "todoist" ]]; then
      [[ "$task_url" == "$WORKSPACE_TODOIST_APP_URL" ]] || return 1
    else
      [[ "$task_url" == "http://${dns}:${WORKSPACE_TASK_MANAGER_PORT}" ]] || return 1
    fi
  fi
  case "$task_manager" in
    super-productivity) workspace_http_ready "${task_url%/}/health" || return 1 ;;
    todoist) workspace_hermes_todoist_api_ready || return 1 ;;
    *) workspace_http_ready "${task_url%/}/api/v1/info" || return 1 ;;
  esac
  workspace_http_ready "${n8n%/}/healthz" &&
    workspace_hermes_dashboard_ready_at "$hermes"
}

workspace_vikunja_private_url_ready() {
  local url
  url=$(workspace_read_env VIKUNJA_URL 2>/dev/null || true)
  [[ -n "$url" ]] && workspace_http_ready "${url%/}/api/v1/info"
}

workspace_task_manager_private_url_ready() {
  local url
  url=$(workspace_task_manager_url)
  [[ -n "$url" ]] || return 1
  case "$(workspace_task_manager)" in
    super-productivity) workspace_http_ready "${url%/}/health" ;;
    todoist) [[ "$url" == "$WORKSPACE_TODOIST_APP_URL" ]] && workspace_hermes_todoist_api_ready ;;
    *) workspace_http_ready "${url%/}/api/v1/info" ;;
  esac
}

workspace_n8n_private_url_ready() {
  local url
  url=$(workspace_read_env N8N_URL 2>/dev/null || true)
  [[ -n "$url" ]] && workspace_http_ready "${url%/}/healthz"
}

workspace_hermes_private_status_url_ready() {
  local url
  url=$(workspace_read_env HERMES_URL 2>/dev/null || true)
  [[ -n "$url" ]] && workspace_hermes_dashboard_ready_at "$url"
}

workspace_tailscale_urls_ready_after_setup() {
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    workspace_tailscale_https_urls_ready && return 0
    sleep 1
  done
  return 1
}

workspace_runtime_ports_not_public() {
  local ports out
  ports="${WORKSPACE_TASK_MANAGER_PORT}|${WORKSPACE_SUPER_PRODUCTIVITY_API_PORT}|${WORKSPACE_N8N_PORT}|${WORKSPACE_HERMES_PORT}|${WORKSPACE_HERMES_TAILSCALE_PROXY_PORT}|${GATEWAY_PORT}"
  out=$(docker ps --format '{{.Ports}}' 2>/dev/null | grep -E "(${ports})->" || true)
  [[ "$out" != *"0.0.0.0:"* && "$out" != *":::"* && "$out" != *"[::]:"* ]]
}

workspace_host_listeners_loopback_only() {
  local ports bind_addr bridge_ip mode
  ports="${WORKSPACE_TASK_MANAGER_PORT}|${WORKSPACE_SUPER_PRODUCTIVITY_API_PORT}|${WORKSPACE_N8N_PORT}|${WORKSPACE_HERMES_PORT}|${WORKSPACE_HERMES_TAILSCALE_PROXY_PORT}|${GATEWAY_PORT}"
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  bind_addr=""
  bridge_ip=$(workspace_openshell_bridge_ip 2>/dev/null || true)
  if [[ "$mode" == "ports" ]]; then
    bind_addr=$(workspace_read_env WORKSPACE_TAILSCALE_BIND_ADDR 2>/dev/null || true)
    workspace_tailscale_bind_addr_ok "$bind_addr" || bind_addr=""
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltnH 2>/dev/null | awk -v ports="$ports" -v bind_addr="$bind_addr" -v bridge_ip="$bridge_ip" \
      -v gateway_port="$GATEWAY_PORT" -v task_port="$WORKSPACE_TASK_MANAGER_PORT" -v task_api_port="$WORKSPACE_SUPER_PRODUCTIVITY_API_PORT" '
      BEGIN { split(ports, p, "|"); for (i in p) wanted[p[i]]=1 }
      {
        local_addr=$4
        port=local_addr
        sub(/^.*:/, "", port)
        allowed = (local_addr ~ /(^|[^0-9])127[.]0[.]0[.]1:/ || local_addr ~ /\[::1\]:/ || local_addr ~ /(^|[^:])::1:/ || local_addr ~ /localhost:/)
        if (bind_addr != "" && index(local_addr, bind_addr ":") > 0) allowed=1
        if (bridge_ip != "" && (port == gateway_port || port == task_port || port == task_api_port) && index(local_addr, bridge_ip ":") > 0) allowed=1
        if (wanted[port] && ! allowed) bad=1
      }
      END { exit bad }
    '
    return $?
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk -v ports="$ports" -v bind_addr="$bind_addr" -v bridge_ip="$bridge_ip" \
      -v gateway_port="$GATEWAY_PORT" -v task_port="$WORKSPACE_TASK_MANAGER_PORT" -v task_api_port="$WORKSPACE_SUPER_PRODUCTIVITY_API_PORT" '
      BEGIN { split(ports, p, "|"); for (i in p) wanted[p[i]]=1 }
      {
        line=$0
        for (port in wanted) {
          allowed = (line ~ /127[.]0[.]0[.]1:/ || line ~ /\[::1\]:/ || line ~ /localhost:/)
          if (bind_addr != "" && index(line, bind_addr ":" port) > 0) allowed=1
          if (bridge_ip != "" && (port == gateway_port || port == task_port || port == task_api_port) && index(line, bridge_ip ":" port) > 0) allowed=1
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

workspace_tailscale_service_specs() {
  workspace_task_manager_hosted && printf '%s 443\n' "$WORKSPACE_TASK_MANAGER_SERVICE"
  printf 'n8n 443\n'
  printf 'hermes 443\n'
}

workspace_tailscale_status_json() {
  command -v tailscale >/dev/null 2>&1 || return 1
  tailscale status --json 2>/dev/null
}

workspace_tailscale_capmap_available() {
  local json="$1"
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s\n' "$json" | jq -e '.Self.CapMap? != null' >/dev/null 2>&1
}

workspace_tailscale_service_registered_in_json() {
  local json="$1" service="$2" port="$3" cap svc tcp_port
  cap="services/${service}"
  svc="svc:${service}"
  tcp_port="tcp:${port}"
  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$json" | jq -e --arg cap "$cap" --arg svc "$svc" --arg port "$tcp_port" '
      (.Self.CapMap[$cap] // [])
      | map(select(.Name == $svc and ((.Ports // []) | index($port))))
      | length > 0
    ' >/dev/null 2>&1
    return $?
  fi
  printf '%s\n' "$json" | grep -Fq "\"${cap}\"" &&
    printf '%s\n' "$json" | grep -Fq "\"${svc}\"" &&
    printf '%s\n' "$json" | grep -Fq "\"${tcp_port}\""
}

workspace_tailscale_missing_services() {
  local json="$1" service port missing=0
  while read -r service port; do
    [[ -n "$service" ]] || continue
    if ! workspace_tailscale_service_registered_in_json "$json" "$service" "$port"; then
      printf '%s:%s\n' "$service" "$port"
      missing=1
    fi
  done <<EOF
$(workspace_tailscale_service_specs)
EOF
  return "$missing"
}

workspace_tailscale_missing_services_summary() {
  local missing="$1" line out=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    out="${out}${out:+,}${line}"
  done <<EOF
${missing}
EOF
  printf '%s\n' "$out"
}

workspace_tailscale_tag_required_but_missing() {
  local json="$1"
  workspace_tailscale_capmap_available "$json" || return 1
  command -v jq >/dev/null 2>&1 || return 1
  ! printf '%s\n' "$json" | jq -e '((.Self.Tags // []) | length) > 0' >/dev/null 2>&1
}

workspace_tailscale_print_tag_hitl() {
  local dns_name
  dns_name=$(workspace_tailscale_dns_name 2>/dev/null || true)
  printf "    Tailscale Services require this machine to use a tag identity.\n"
  printf "    In the Tailscale admin console:\n"
  printf "      1. Create tag: tag:spark (owner: autogroup:admin).\n"
  if [[ -n "$dns_name" ]]; then
    printf "      2. Assign tag:spark to machine: %s\n" "$dns_name"
  else
    printf "      2. Assign tag:spark to this machine.\n"
  fi
  printf "      3. Re-auth the node if Tailscale asks for it.\n"
  printf "    Then return here; spark will verify the tag before continuing.\n"
}

workspace_tailscale_print_operator_hitl() {
  printf "    Tailscale Serve needs local operator permission for this Unix user.\n"
  printf "    Run on this machine:\n"
  printf "      sudo tailscale set --operator=\$USER\n"
  printf "    Then return here; spark will retry and verify the Serve config write.\n"
}

workspace_tailscale_confirm_step() {
  local prompt="$1" auto_yes="${2:-0}"
  [[ "$auto_yes" == "1" ]] && return 1
  [[ "${SPARK_WORKSPACE_TAILSCALE_HITL_RETRY:-0}" == "1" ]] && return 1
  is_interactive || return 1
  confirm "$prompt"
}

workspace_tailscale_verify_services_after_hitl() {
  local tailnet="$1" missing="$2" auto_yes="$3" json missing_after summary_after
  workspace_tailscale_print_services_hitl "$missing" "$tailnet"
  workspace_tailscale_confirm_step "I created/approved the Tailscale Services; verify now?" "$auto_yes" || return 1
  json=$(workspace_tailscale_status_json 2>/dev/null || true)
  [[ -n "$json" ]] || return 1
  workspace_tailscale_capmap_available "$json" || return 1
  missing_after=$(workspace_tailscale_missing_services "$json" || true)
  if [[ -z "$missing_after" ]]; then
    info "Tailscale Services verified"
    return 0
  fi
  summary_after=$(workspace_tailscale_missing_services_summary "$missing_after")
  warn "Tailscale Services still missing/not authorized: ${summary_after}"
  return 1
}

workspace_tailscale_verify_tag_after_hitl() {
  local auto_yes="$1" json
  workspace_tailscale_print_tag_hitl
  workspace_tailscale_confirm_step "I assigned tag:spark to this machine; verify now?" "$auto_yes" || return 1
  json=$(workspace_tailscale_status_json 2>/dev/null || true)
  [[ -n "$json" ]] || return 1
  if workspace_tailscale_tag_required_but_missing "$json"; then
    warn "Tailscale still reports this machine without a tag"
    return 1
  fi
  info "Tailscale tag verified"
  return 0
}

workspace_tailscale_retry_after_hitl() {
  local tailnet="$1" check_only="$2" funnel_action="$3" auto_yes="$4" prompt="$5"
  workspace_tailscale_confirm_step "$prompt" "$auto_yes" || return 1
  SPARK_WORKSPACE_TAILSCALE_HITL_RETRY=1 workspace_configure_tailscale "$tailnet" "$check_only" "$funnel_action" "$auto_yes"
}

workspace_tailscale_mark_error() {
  local code="$1" url="${2:-}"
  workspace_set_env_key WORKSPACE_TAILSCALE_LAST_ERROR "$code"
  workspace_set_env_key WORKSPACE_TAILSCALE_ENABLE_URL "$url"
}

workspace_tailscale_clear_error() {
  workspace_set_env_key WORKSPACE_TAILSCALE_LAST_ERROR ""
  workspace_set_env_key WORKSPACE_TAILSCALE_ENABLE_URL ""
}

workspace_tailscale_services_registered() {
  local mode json missing last_error
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  [[ "$mode" == "ports" ]] && return 0
  last_error=$(workspace_read_env WORKSPACE_TAILSCALE_LAST_ERROR 2>/dev/null || true)
  [[ "$last_error" == "missing-service" ]] && return 1
  json=$(workspace_tailscale_status_json) || return 1
  # Older/fake status JSON may not expose CapMap. When CapMap exists, it is the source of truth.
  workspace_tailscale_capmap_available "$json" || return 0
  missing=$(workspace_tailscale_missing_services "$json" || true)
  [[ -z "$missing" ]]
}

workspace_tailscale_print_services_hitl() {
  local missing="$1" tailnet="$2" dns_name="" service port
  dns_name=$(workspace_tailscale_dns_name 2>/dev/null || true)
  printf "    Tailscale Services must be created/approved in the Tailscale admin console.\n"
  printf "    Open: https://login.tailscale.com/admin/services\n"
  printf "    Required Services:\n"
  while read -r service port; do
    [[ -n "$service" ]] || continue
    printf "      - %s: address https://%s.%s, endpoint tcp:%s\n" "$service" "$service" "$tailnet" "$port"
  done <<EOF
$(workspace_tailscale_service_specs)
EOF
  if [[ -n "$missing" ]]; then
    printf "    Missing or not authorized for this node:\n"
    while IFS=: read -r service port; do
      [[ -n "$service" ]] || continue
      printf "      - %s (tcp:%s)\n" "$service" "$port"
    done <<EOF
${missing}
EOF
  fi
  if [[ -n "$dns_name" ]]; then
    printf "    Approve/authorize host: %s\n" "$dns_name"
  fi
  printf "    Then rerun: spark ws setup --tailscale-mode services\n"
}

workspace_tailscale_serve_launch_bg() {
  local service="$1" target="$2" status_file="$3" log_file="$4"
  local rc
  if command -v timeout >/dev/null 2>&1; then
    if timeout 5 tailscale serve --bg --service="$service" --https=443 --yes "$target" >"$log_file" 2>&1; then
      rc=0
    else
      rc=$?
    fi
  else
    if tailscale serve --bg --service="$service" --https=443 --yes "$target" >"$log_file" 2>&1; then
      rc=0
    else
      rc=$?
    fi
  fi
  printf "%s" "$rc" >"$status_file"
}

workspace_tailscale_serve_disabled_error() {
  local log
  for log in "$@"; do
    [[ -f "$log" ]] || continue
    grep -q "Serve is not enabled on your tailnet" "$log" && return 0
  done
  return 1
}

workspace_tailscale_operator_error() {
  local log
  for log in "$@"; do
    [[ -f "$log" ]] || continue
    grep -Eq "serve config denied|sudo tailscale set --operator|Use 'sudo tailscale serve" "$log" && return 0
  done
  return 1
}

workspace_tailscale_tagged_node_error() {
  local log
  for log in "$@"; do
    [[ -f "$log" ]] || continue
    grep -qi "service hosts must be tagged nodes" "$log" && return 0
  done
  return 1
}

workspace_tailscale_serve_enable_url() {
  local log url
  for log in "$@"; do
    [[ -f "$log" ]] || continue
    url=$(grep -Eo 'https://login[.]tailscale[.]com/f/serve[^[:space:]]*' "$log" | head -1 || true)
    if [[ -n "$url" ]]; then
      printf '%s\n' "$url"
      return 0
    fi
  done
  return 1
}

workspace_tailscale_print_serve_disabled_hitl() {
  local url="${1:-}"
  printf "    Tailscale Serve is not enabled for this tailnet.\n"
  if [[ -n "$url" ]]; then
    printf "    Enable it here: %s\n" "$url"
  else
    printf "    Run tailscale serve once and follow the login.tailscale.com consent link.\n"
  fi
  printf "    Then rerun: spark ws setup --tailscale-mode services\n"
}

workspace_tailscale_print_pending_approval_hitl() {
  local dns_name
  dns_name=$(workspace_tailscale_dns_name 2>/dev/null || true)
  printf "    Tailscale Services are configured locally, but this host still needs admin approval.\n"
  printf "    Open: https://login.tailscale.com/admin/services\n"
  if [[ -n "$dns_name" ]]; then
    printf "    Approve host: %s for tasks, n8n, hermes.\n" "$dns_name"
  else
    printf "    Approve this host for tasks, n8n, hermes.\n"
  fi
  printf "    Then rerun: spark ws setup\n"
}

workspace_tailscale_offer_ports_fallback() {
  local tailnet="$1" auto_yes="$2"
  [[ "$(workspace_task_manager)" != "super-productivity" ]] || return 1
  [[ "$auto_yes" == "1" ]] && return 1
  is_interactive || return 1
  confirm "Use temporary Tailscale port URLs instead of Services for now?" || return 1
  workspace_tailscale_ports_fallback "$tailnet" || return 1
  workspace_tailscale_clear_error
  return 0
}

workspace_tailscale_ports_fallback() {
  local tailnet="$1" human_user="" human_email="" n8n_email="" model="" bind_addr="" dns_name=""
  human_user=$(workspace_read_env VIKUNJA_HUMAN_USERNAME 2>/dev/null || true)
  human_email=$(workspace_read_env VIKUNJA_HUMAN_EMAIL 2>/dev/null || true)
  n8n_email=$(workspace_read_env N8N_BASIC_AUTH_USER 2>/dev/null || true)
  model=$(workspace_read_env HERMES_MODEL 2>/dev/null || true)
  bind_addr=$(workspace_tailscale_ipv4 2>/dev/null || true)
  dns_name=$(workspace_tailscale_dns_name 2>/dev/null || true)
  [[ -n "$human_user" && -n "$human_email" && -n "$n8n_email" && -n "$model" ]] || return 1
  [[ -n "$bind_addr" && -n "$dns_name" ]] || return 1
  SPARK_WORKSPACE_TAILSCALE_MODE=ports \
    workspace_write_files "$tailnet" "$human_user" "$human_email" unused "$n8n_email" unused "$model" || return 1
  workspace_compose up -d --remove-orphans >/dev/null 2>&1 || return 1
  info "Tailscale Serve is not enabled on this tailnet; using ports fallback"
  return 0
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
  [[ "$(workspace_read_env WORKSPACE_TAILSCALE_LAST_ERROR 2>/dev/null || true)" == "serve-disabled" ]] && return 1
  command -v tailscale >/dev/null 2>&1 && tailscale serve status >/dev/null 2>&1
}

workspace_tailscale_service_host_advertised() {
  local mode out json
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  [[ "$mode" == "ports" ]] && return 0
  json=$(workspace_tailscale_status_json 2>/dev/null || true)
  if [[ -z "$json" ]]; then
    out=$(tailscale serve get-config --all 2>/dev/null || tailscale serve status --json 2>/dev/null || tailscale serve status 2>/dev/null || true)
    [[ "$out" == *"svc:n8n"* && "$out" == *"svc:hermes"* ]] || return 1
    workspace_task_manager_hosted || return 0
    [[ "$out" == *"svc:${WORKSPACE_TASK_MANAGER_SERVICE}"* ]]
    return $?
  fi
  if command -v jq >/dev/null 2>&1 && workspace_tailscale_capmap_available "$json"; then
    printf '%s\n' "$json" | jq -e '.Self.CapMap["service-host"]? != null' >/dev/null 2>&1
    return $?
  fi
  out=$(tailscale serve get-config --all 2>/dev/null || tailscale serve status --json 2>/dev/null || tailscale serve status 2>/dev/null || true)
  [[ "$out" == *"svc:n8n"* && "$out" == *"svc:hermes"* ]] || return 1
  workspace_task_manager_hosted || return 0
  [[ "$out" == *"svc:${WORKSPACE_TASK_MANAGER_SERVICE}"* ]]
}

workspace_tailscale_wait_for_service_host_advertised() {
  local attempts="${SPARK_WORKSPACE_TAILSCALE_APPROVAL_WAIT_ATTEMPTS:-45}" delay="${SPARK_WORKSPACE_TAILSCALE_APPROVAL_WAIT_DELAY:-2}" i=0
  [[ "$attempts" =~ ^[0-9]+$ && "$attempts" -gt 0 ]] || attempts=45
  [[ "$delay" =~ ^[0-9]+([.][0-9]+)?$ ]] || delay=2
  while [[ "$i" -lt "$attempts" ]]; do
    workspace_tailscale_service_host_advertised && return 0
    i=$((i + 1))
    [[ "$i" -lt "$attempts" ]] || break
    sleep "$delay"
  done
  return 1
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

workspace_tailscale_services_local_configured_from_output() {
  local out="$1"
  [[ "$out" == *"svc:n8n"* && "$out" == *"svc:hermes"* ]] &&
    workspace_tailscale_service_target_private "$out" n8n "$WORKSPACE_N8N_PORT" &&
    workspace_tailscale_service_target_private "$out" hermes "$WORKSPACE_HERMES_TAILSCALE_PROXY_PORT" &&
    ! printf '%s\n' "$out" | grep -Eq "0[.]0[.]0[.]0:(${WORKSPACE_TASK_MANAGER_PORT}|${WORKSPACE_N8N_PORT}|${WORKSPACE_HERMES_PORT}|${WORKSPACE_HERMES_TAILSCALE_PROXY_PORT})|[[]::[]]:(${WORKSPACE_TASK_MANAGER_PORT}|${WORKSPACE_N8N_PORT}|${WORKSPACE_HERMES_PORT}|${WORKSPACE_HERMES_TAILSCALE_PROXY_PORT})" || return 1
  workspace_task_manager_hosted || return 0
  [[ "$out" == *"svc:${WORKSPACE_TASK_MANAGER_SERVICE}"* ]] &&
    workspace_tailscale_service_target_private "$out" "$WORKSPACE_TASK_MANAGER_SERVICE" "$WORKSPACE_TASK_MANAGER_PORT"
}

workspace_hermes_dashboard_ready_at() {
  local base_url="$1"
  [[ -n "$base_url" ]] || return 1
  workspace_http_ready "${base_url%/}/"
}

workspace_hermes_api_ready_at() {
  local base_url="$1"
  [[ -n "$base_url" ]] || return 1
  workspace_http_ready "${base_url%/}/health" ||
    workspace_http_ready "${base_url%/}/v1/models"
}

workspace_hermes_local_api_ready() {
  workspace_hermes_api_ready_at "http://127.0.0.1:${WORKSPACE_HERMES_LOCAL_PORT}"
}

workspace_hermes_private_url_ready() {
  local url
  url=$(workspace_read_env HERMES_URL 2>/dev/null || true)
  workspace_hermes_dashboard_ready_at "$url"
}

workspace_hermes_container_name() {
  local containers
  command -v docker >/dev/null 2>&1 || return 1
  containers=$(docker ps -a --filter label=openshell.ai/sandbox-name=hermes --format '{{.Names}}' 2>/dev/null || true)
  if [[ -z "$containers" ]]; then
    containers=$(docker ps -a --filter name=hermes --format '{{.Names}}' 2>/dev/null || true)
  fi
  printf '%s\n' "$containers" | grep -E "^(${WORKSPACE_HERMES_CONTAINER}|openshell-hermes-)" | head -n 1
}

workspace_hermes_running_container_name() {
  local container
  container=$(workspace_hermes_container_name 2>/dev/null || true)
  [[ -n "$container" ]] || return 1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -Fx "$container"
}

workspace_restore_hermes_container_name() {
  local current sandbox_name sandbox_id expected
  current=$(workspace_hermes_container_name 2>/dev/null || true)
  [[ "$current" == "$WORKSPACE_HERMES_CONTAINER" ]] || return 0
  sandbox_name=$(docker inspect --format '{{index .Config.Labels "openshell.ai/sandbox-name"}}' "$current" 2>/dev/null || true)
  sandbox_id=$(docker inspect --format '{{index .Config.Labels "openshell.ai/sandbox-id"}}' "$current" 2>/dev/null || true)
  [[ "$sandbox_name" == "hermes" && -n "$sandbox_id" ]] || return 1
  expected="openshell-${sandbox_name}-${sandbox_id}"
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$expected" && return 1
  docker rename "$current" "$expected" >/dev/null 2>&1
}

workspace_start_hermes_private_proxy() {
  local attempt
  command -v nemohermes >/dev/null 2>&1 || return 1
  if workspace_hermes_private_url_ready && workspace_hermes_local_api_ready; then
    return 0
  fi
  workspace_restore_hermes_container_name || return 1
  NEMOCLAW_SANDBOX_NAME=hermes nemohermes hermes start >/dev/null 2>&1 || true
  NEMOCLAW_SANDBOX_NAME=hermes nemohermes hermes recover >/dev/null 2>&1 || \
    NEMOCLAW_SANDBOX_NAME=hermes nemohermes recover >/dev/null 2>&1 || true
  if command -v openshell >/dev/null 2>&1; then
    workspace_hermes_private_url_ready || openshell forward start --background "$WORKSPACE_HERMES_PORT" hermes >/dev/null 2>&1 || true
    workspace_hermes_local_api_ready || openshell forward start --background "$WORKSPACE_HERMES_LOCAL_PORT" hermes >/dev/null 2>&1 || true
  fi
  for ((attempt = 1; attempt <= 30; attempt++)); do
    workspace_hermes_private_url_ready && workspace_hermes_local_api_ready && return 0
    sleep 1
  done
  return 1
}

workspace_pause_hermes_private_proxy() {
  command -v nemohermes >/dev/null 2>&1 || return 1
  NEMOCLAW_SANDBOX_NAME=hermes nemohermes hermes stop >/dev/null 2>&1
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
  workspace_tailscale_services_registered || return 1
  out=$(tailscale serve get-config --all 2>/dev/null || tailscale serve status --json 2>/dev/null || tailscale serve status 2>/dev/null || true)
  workspace_tailscale_services_local_configured_from_output "$out"
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

workspace_hermes_gateway_proxy_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$WORKSPACE_HERMES_GATEWAY_PROXY_CONTAINER"
}

workspace_hermes_vikunja_proxy_running() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$WORKSPACE_HERMES_VIKUNJA_PROXY_CONTAINER"
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
  expected=$(workspace_read_env HERMES_URL 2>/dev/null || true)
  workspace_hermes_private_url_ready || return 1
  out=$(NEMOCLAW_SANDBOX_NAME=hermes nemohermes hermes dashboard-url --quiet 2>/dev/null || \
    NEMOCLAW_SANDBOX_NAME=hermes nemohermes hermes dashboard-url 2>/dev/null || true)
  [[ -n "$out" ]] || return 1
  [[ -n "$expected" && "$out" == *"$expected"* ]] && return 0
  printf '%s\n' "$out" | grep -Eq "https?://(127[.]0[.]0[.]1|localhost|\[::1\]):${WORKSPACE_HERMES_PORT}(/|[[:space:]]|$)"
}

cmd_workspace_doctor_help() {
  cat <<EOF

  ${BOLD}Usage:${NC} spark ws doctor [--strict] [--verbose] [--json|--quiet] [--model MODEL] [--remote user@host]

  Read-only workspace diagnosis. Checks config, secrets, Compose, Postgres, the
  selected task manager, n8n, private access, LiteLLM, and Hermes/NemoClaw.

  ${BOLD}Flags:${NC}
    --verbose           Show every check instead of the area summary only.
    --json              Machine-readable output for CI/automation.
    --quiet             Print nothing; use only the exit code.
    --strict            Adds production checks, currently pinned image refs.
    --model MODEL       Validate Hermes route/model when it cannot be inferred from config.
    --remote user@host  Run the doctor on a configured remote host.

EOF
}

cmd_workspace_doctor() {
  local requested_model="" remote_spec="" model task_manager json_mode=0 strict_mode=0 verbose=0 quiet=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_mode=1; shift ;;
      --quiet) quiet=1; shift ;;
      --verbose) verbose=1; shift ;;
      --strict) strict_mode=1; shift ;;
      --model) requested_model="${2:-}"; [[ -n "$requested_model" ]] || die "--model requires a value"; shift 2 ;;
      --remote) remote_spec="${2:-}"; [[ -n "$remote_spec" ]] || die "--remote requires user@host"; shift 2 ;;
      -h|--help) cmd_workspace_doctor_help; return 0 ;;
      *) die "Unknown ws doctor flag: $1" ;;
    esac
  done
  [[ "$json_mode" == "1" && "$quiet" == "1" ]] && die "Choose either --json or --quiet"
  if [[ -n "$remote_spec" ]]; then
    local args=(doctor)
    [[ "$strict_mode" == "1" ]] && args+=(--strict)
    [[ "$json_mode" == "1" ]] && args+=(--json)
    [[ "$quiet" == "1" ]] && args+=(--quiet)
    [[ "$verbose" == "1" ]] && args+=(--verbose)
    [[ -n "$requested_model" ]] && args+=(--model "$requested_model")
    workspace_remote_workspace_cmd "$remote_spec" "${args[@]}"
    return $?
  fi

  WORKSPACE_DOCTOR_FAILED=0
  WORKSPACE_DOCTOR_VERBOSE="$verbose"
  WORKSPACE_DOCTOR_TOTAL=0
  WORKSPACE_DOCTOR_PASSED=0
  WORKSPACE_DOCTOR_CATEGORY=""
  WORKSPACE_DOCTOR_ACTION=""
  WORKSPACE_DOCTOR_JSON_ITEMS=()
  WORKSPACE_DOCTOR_CATEGORIES=()
  WORKSPACE_DOCTOR_LABELS=()
  WORKSPACE_DOCTOR_RESULTS=()
  WORKSPACE_DOCTOR_ACTIONS=()
  WORKSPACE_DOCTOR_SECTIONS=()
  model="$requested_model"
  [[ -n "$model" ]] || model=$(workspace_read_env HERMES_MODEL 2>/dev/null || true)
  task_manager=$(workspace_task_manager)

  if ! workspace_configured; then
    workspace_doctor_section "Configuration" "spark ws setup"
    workspace_doctor_check "Workspace is configured" workspace_configured
    if [[ "$json_mode" == "1" ]]; then
      workspace_doctor_print_json "$model"
    elif [[ "$quiet" == "0" ]]; then
      workspace_doctor_print_human
    fi
    return 1
  fi

  workspace_doctor_section "Configuration" "spark ws setup"
  workspace_doctor_check "Config directory exists" test -d "$WORKSPACE_CONFIG_DIR"
  workspace_doctor_check "Config directory mode is 0700" workspace_file_mode_is "$WORKSPACE_CONFIG_DIR" 700
  workspace_doctor_check "Data directory exists" test -d "$WORKSPACE_DATA_DIR"
  workspace_doctor_check "Secrets file exists" test -f "$WORKSPACE_ENV_FILE"
  workspace_doctor_check "Secrets file mode is 0600" workspace_file_mode_is "$WORKSPACE_ENV_FILE" 600
  workspace_doctor_check "Secrets env syntax is valid" workspace_env_file_syntax_valid "$WORKSPACE_ENV_FILE"
  workspace_doctor_check "Compose file exists" test -f "$WORKSPACE_COMPOSE_FILE"
  workspace_doctor_check "Scoped service env files exist and are 0600" workspace_service_env_files_ready
  workspace_doctor_check "Scoped service env syntax is valid" workspace_service_env_files_syntax_valid
  workspace_doctor_check "Compose service exists: postgres" workspace_compose_mentions_service postgres
  if [[ "$task_manager" == "super-productivity" ]]; then
    workspace_doctor_check "Compose service exists: SuperSync" workspace_compose_mentions_service supersync
    workspace_doctor_check "Compose service exists: Electron API" workspace_compose_mentions_service super-productivity-electron
    workspace_doctor_check "Electron build recipe is complete" workspace_super_productivity_electron_build_ready
  elif [[ "$task_manager" == "todoist" ]]; then
    workspace_doctor_check "Todoist requires no local task-manager service" workspace_todoist_no_local_service
  else
    workspace_doctor_check "Compose service exists: Vikunja" workspace_compose_mentions_service vikunja
  fi
  workspace_doctor_check "Compose service exists: n8n" workspace_compose_mentions_service n8n
  workspace_doctor_check "Docker Compose config is valid" workspace_compose_config_valid
  workspace_doctor_check "Compose uses scoped env files, not full secrets.env" workspace_compose_uses_scoped_env_files
  workspace_doctor_check "Compose image refs are recorded and used" workspace_compose_images_configured
  workspace_doctor_check "Compose applies runtime hardening and log rotation" workspace_compose_runtime_hardened
  if [[ "$task_manager" == "super-productivity" ]]; then
    workspace_doctor_check "Shared Postgres initializes SuperSync and n8n DBs" workspace_compose_shared_postgres
  elif [[ "$task_manager" == "todoist" ]]; then
    workspace_doctor_check "Shared Postgres initializes the n8n DB" workspace_compose_shared_postgres
  else
    workspace_doctor_check "Shared Postgres initializes Vikunja and n8n DBs" workspace_compose_shared_postgres
  fi
  workspace_doctor_check "Compose uses private host bindings only" workspace_compose_uses_loopback_ports

  workspace_doctor_section "Identity & recovery" "spark ws setup"
  workspace_doctor_check "Interactive service passwords are not stored" workspace_human_password_not_stored
  if [[ "$task_manager" == "super-productivity" ]]; then
    workspace_doctor_check "Super Productivity and SuperSync configuration is complete" workspace_super_productivity_config_ready
    workspace_doctor_check "SuperSync user exists and is verified" workspace_supersync_user_ready
    workspace_doctor_check "SuperSync passkey is enrolled" workspace_supersync_passkey_ready
    workspace_doctor_check "SuperSync access token works" workspace_supersync_token_ready
    workspace_doctor_check "Browser and Electron SuperSync is verified" workspace_super_productivity_browser_sync_ready
  elif [[ "$task_manager" == "todoist" ]]; then
    workspace_doctor_check "Todoist configuration and token isolation are complete" workspace_todoist_config_ready
    workspace_doctor_check "Todoist API token works from Hermes" workspace_hermes_todoist_access_ready
    workspace_doctor_check "Todoist label Hermes exists" workspace_hermes_todoist_label_ready
  else
    workspace_doctor_check "Vikunja registration/link sharing disabled" workspace_vikunja_locked_down
    workspace_doctor_check "Vikunja internal doctor passes" workspace_vikunja_doctor_ok
    workspace_doctor_check "Vikunja human user exists" workspace_vikunja_human_ready
    workspace_doctor_check "Vikunja bot-hermes exists" workspace_vikunja_hermes_ready
    workspace_doctor_check "Vikunja bot-hermes API token works" workspace_vikunja_hermes_api_ready
    workspace_doctor_check "Vikunja projects are shared with bot-hermes" workspace_vikunja_hermes_project_access_ready
  fi
  workspace_doctor_check "n8n hardened for private agent workflows" workspace_n8n_hardened
  workspace_doctor_check "n8n owner/admin ready" workspace_n8n_owner_ready
  workspace_doctor_check "n8n Hermes folder ready in Personal" workspace_n8n_hermes_folder_ready
  workspace_doctor_check "No legacy or temporary password recovery configuration is stored" workspace_no_legacy_recovery_config
  workspace_doctor_check "Workspace URLs configured" workspace_urls_configured
  if [[ "$task_manager" == "super-productivity" ]]; then
    workspace_doctor_check "Workspace technical secrets and service identity are complete" workspace_env_has \
      WORKSPACE_TASK_MANAGER POSTGRES_PASSWORD SUPERSYNC_DATABASE_PASSWORD SUPERSYNC_JWT_SECRET \
      SUPERSYNC_ACCESS_TOKEN SUPERSYNC_ENCRYPTION_PASSWORD SUPER_PRODUCTIVITY_USER_EMAIL \
      SUPER_PRODUCTIVITY_BROWSER_SYNC_STATUS SUPER_PRODUCTIVITY_BROWSER_SYNC_URL \
      WORKSPACE_SUPER_PRODUCTIVITY_VERSION WORKSPACE_SUPER_PRODUCTIVITY_COMMIT \
      DB_POSTGRESDB_PASSWORD N8N_ENCRYPTION_KEY WORKSPACE_MENTION_SECRET N8N_BASIC_AUTH_USER \
      N8N_OWNER_SETUP_STATUS HERMES_MODEL HERMES_LITELLM_MODEL HERMES_CONTEXT_LENGTH \
      HERMES_MAX_TOKENS HERMES_REASONING_EFFORT HERMES_LITELLM_BASE_URL TASK_MANAGER_URL \
      SUPER_PRODUCTIVITY_URL N8N_URL HERMES_URL WORKSPACE_TAILSCALE_MODE
  elif [[ "$task_manager" == "todoist" ]]; then
    workspace_doctor_check "Workspace technical secrets and service identity are complete" workspace_env_has \
      WORKSPACE_TASK_MANAGER POSTGRES_PASSWORD DB_POSTGRESDB_PASSWORD N8N_ENCRYPTION_KEY \
      WORKSPACE_MENTION_SECRET N8N_BASIC_AUTH_USER N8N_OWNER_SETUP_STATUS TODOIST_API_URL \
      TODOIST_URL TODOIST_API_TOKEN TODOIST_API_STATUS HERMES_MODEL HERMES_LITELLM_MODEL \
      HERMES_CONTEXT_LENGTH HERMES_MAX_TOKENS HERMES_REASONING_EFFORT \
      HERMES_LITELLM_BASE_URL TASK_MANAGER_URL N8N_URL HERMES_URL WORKSPACE_TAILSCALE_MODE
  else
    workspace_doctor_check "Workspace technical secrets and service identity are complete" workspace_env_has \
      POSTGRES_PASSWORD VIKUNJA_DATABASE_PASSWORD VIKUNJA_SERVICE_SECRET DB_POSTGRESDB_PASSWORD \
      N8N_ENCRYPTION_KEY WORKSPACE_MENTION_SECRET VIKUNJA_HUMAN_USERNAME VIKUNJA_HUMAN_EMAIL VIKUNJA_HUMAN_USER_ID N8N_BASIC_AUTH_USER \
      N8N_OWNER_SETUP_STATUS VIKUNJA_HERMES_API_TOKEN VIKUNJA_HERMES_API_STATUS HERMES_MODEL HERMES_LITELLM_MODEL \
      HERMES_CONTEXT_LENGTH HERMES_MAX_TOKENS HERMES_REASONING_EFFORT \
      HERMES_LITELLM_BASE_URL VIKUNJA_URL N8N_URL HERMES_URL WORKSPACE_TAILSCALE_MODE \
      VIKUNJA_HUMAN_USER_STATUS VIKUNJA_HERMES_BOT_USERNAME VIKUNJA_HERMES_BOT_ID \
      VIKUNJA_HERMES_BOT_STATUS VIKUNJA_HERMES_PROJECT_ACCESS_STATUS
  fi
  workspace_doctor_check "Workspace technical secrets are unique per service" workspace_credentials_are_distinct

  workspace_doctor_section "Runtime services" "spark ws restart"
  workspace_doctor_check "Compose service running: postgres" workspace_compose_service_running postgres
  if [[ "$task_manager" == "super-productivity" ]]; then
    workspace_doctor_check "Shared Postgres runtime has SuperSync and n8n roles/databases" workspace_postgres_shared_runtime_ready
  elif [[ "$task_manager" == "todoist" ]]; then
    workspace_doctor_check "Shared Postgres runtime has the n8n role/database" workspace_postgres_shared_runtime_ready
  else
    workspace_doctor_check "Shared Postgres runtime has Vikunja and n8n roles/databases" workspace_postgres_shared_runtime_ready
  fi
  if [[ "$task_manager" == "super-productivity" ]]; then
    workspace_doctor_check "Compose service running: SuperSync" workspace_compose_service_running supersync
    workspace_doctor_check "Compose service running: Electron API" workspace_compose_service_running super-productivity-electron
    workspace_doctor_check "SuperSync endpoint ready" workspace_supersync_http_ready
    workspace_doctor_check "Super Productivity Electron API ready" workspace_super_productivity_api_ready
  elif [[ "$task_manager" == "todoist" ]]; then
    workspace_doctor_check "Todoist API ready from Hermes" workspace_hermes_todoist_api_ready
  else
    workspace_doctor_check "Compose service running: Vikunja" workspace_compose_service_running vikunja
    workspace_doctor_check "Vikunja HTTP endpoint ready" workspace_vikunja_http_ready
  fi
  workspace_doctor_check "Compose service running: n8n" workspace_compose_service_running n8n
  workspace_doctor_check "n8n HTTP endpoint ready" workspace_n8n_http_ready
  workspace_doctor_check "No workspace/gateway port is published on 0.0.0.0" workspace_runtime_ports_not_public
  workspace_doctor_check "Host listeners for workspace/gateway are loopback-only" workspace_host_listeners_loopback_only

  workspace_doctor_section "Private access" "spark ws setup"
  workspace_doctor_check "Tailscale connected" workspace_tailscale_connected
  workspace_doctor_check "Tailscale supports selected private access mode" workspace_tailscale_requested_version_ok
  workspace_doctor_check "Tailscale Funnel disabled" workspace_tailscale_funnel_disabled
  workspace_doctor_check "Tailscale Services registered/authorized" workspace_tailscale_services_registered
  workspace_doctor_check "Tailscale Serve enabled" workspace_tailscale_serve_present
  workspace_doctor_check "Tailscale Service host advertised" workspace_tailscale_service_host_advertised
  if [[ "$task_manager" == "todoist" ]]; then
    workspace_doctor_check "Tailscale local config maps n8n and hermes" workspace_tailscale_services_configured
  elif [[ "$task_manager" == "super-productivity" ]]; then
    workspace_doctor_check "Tailscale local config maps tasks, n8n, hermes" workspace_tailscale_services_configured
  else
    workspace_doctor_check "Tailscale local config maps vikunja, n8n, hermes" workspace_tailscale_services_configured
  fi
  workspace_doctor_check "Tailscale mode is Services or ports" workspace_tailscale_services_mode
  workspace_doctor_check "Tailscale workspace URLs respond" workspace_tailscale_https_urls_ready

  workspace_doctor_section "Inference & agent" "spark ws restart"
  workspace_doctor_check "LiteLLM gateway running" workspace_gateway_running
  workspace_doctor_check "LiteLLM exposes Hermes model route" workspace_litellm_model_routed
  workspace_doctor_check "LiteLLM Hermes route completes smoke request" workspace_litellm_model_smoke
  workspace_doctor_check "Hermes model running: ${model:-none}" workspace_model_running "$model"
  workspace_doctor_check "Hermes/NemoClaw running" workspace_hermes_running
  workspace_doctor_check "NemoHermes maintained release installed" workspace_nemohermes_maintained_release
  workspace_doctor_check "Hermes NemoClaw uses restricted policy and private dashboard/API ports" workspace_hermes_nemoclaw_configured
  workspace_doctor_check "Hermes local API is reachable" workspace_hermes_local_api_ready
  workspace_doctor_check "NemoHermes sandbox doctor passes" workspace_hermes_doctor_ready
  workspace_doctor_check "NemoHermes inference route uses selected LiteLLM model" workspace_hermes_inference_route_ready
  workspace_doctor_check "Hermes model supports automatic tool calling" workspace_model_tool_calling_ready "$model"
  workspace_doctor_check "Hermes model context is at least ${WORKSPACE_HERMES_MIN_CONTEXT} tokens" workspace_model_context_ready "$model"
  workspace_doctor_check "Hermes output and reasoning limits are configured" workspace_hermes_runtime_config_ready
  workspace_doctor_check "Hermes CLI uses the balanced local-model tool profile" workspace_hermes_cli_toolsets_ready
  if [[ "$task_manager" == "super-productivity" ]]; then
    workspace_doctor_check "Hermes reaches the Super Productivity API" workspace_hermes_super_productivity_api_ready
  elif [[ "$task_manager" == "todoist" ]]; then
    workspace_doctor_check "Hermes reaches the Todoist API" workspace_hermes_todoist_api_ready
  else
    workspace_doctor_check "Hermes reaches Vikunja as bot-hermes" workspace_hermes_vikunja_api_ready
  fi
  workspace_doctor_check "Hermes dashboard URL is reachable" workspace_hermes_dashboard_url_ready
  if [[ "$strict_mode" == "1" ]]; then
    workspace_doctor_section "Production" "pin workspace image versions, then run spark ws setup"
    workspace_doctor_check "Compose image refs are pinned for production" workspace_compose_images_pinned
  fi

  if [[ "$json_mode" == "1" ]]; then
    workspace_doctor_print_json "$model"
  elif [[ "$quiet" == "0" ]]; then
    workspace_doctor_print_human
  fi
  [[ "$WORKSPACE_DOCTOR_FAILED" -eq 0 ]]
}

workspace_print_initial_credentials() {
  local vikunja_user="$1" vikunja_email="$2" vikunja_pass="$3" n8n_email="$4" n8n_pass="$5"
  local shown=0
  if [[ "${WORKSPACE_SHOW_VIKUNJA_PASSWORD:-0}" == "1" || "${WORKSPACE_SHOW_N8N_PASSWORD:-0}" == "1" ]]; then
    printf "\n  ${YELLOW}${BOLD}Save these passwords now. Spark does not store or show them again.${NC}\n\n"
  fi
  if [[ "${WORKSPACE_SHOW_VIKUNJA_PASSWORD:-0}" == "1" ]]; then
    printf "  Vikunja\n    user:     %s\n    email:    %s\n    password: %s\n" "$vikunja_user" "$vikunja_email" "$vikunja_pass"
    shown=1
  fi
  if [[ "${WORKSPACE_SHOW_N8N_PASSWORD:-0}" == "1" ]]; then
    [[ "$shown" == "0" ]] || printf "\n"
    printf "  n8n\n    email:    %s\n    password: %s\n" "$n8n_email" "$n8n_pass"
    shown=1
  fi
  if [[ "$shown" != "0" ]]; then
    if [[ "$(workspace_task_manager)" == "vikunja" ]]; then
      printf "\n  If you lose one: ${BOLD}spark ws recover vikunja${NC} or ${BOLD}spark ws recover n8n${NC}\n\n"
    else
      printf "\n  If you lose the n8n password: ${BOLD}spark ws recover n8n${NC}.\n\n"
    fi
  fi
}

workspace_recovery_password_valid() {
  local value="${1-}" length
  [[ -n "$value" && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  length=${#value}
  [[ "$length" -ge 8 && "$length" -le 64 ]]
}

workspace_choose_recovery_password() {
  local auto_yes="$1" password_var="$2" generated_var="$3"
  local choice="" value="" confirmation=""
  if [[ "$auto_yes" == "1" ]]; then
    printf -v "$password_var" '%s' "$(workspace_random_password)"
    printf -v "$generated_var" '%s' 1
    return 0
  fi
  is_interactive || die "Interactive password recovery requires a terminal" "Use --yes to generate a secure password automatically"
  printf "\n  ${BOLD}New password${NC}\n\n" >&2
  printf "    [1] Generate a secure password (recommended)\n" >&2
  printf "    [2] Choose my own password\n\n" >&2
  while true; do
    printf "  > " >&2
    read -r choice || true
    case "$choice" in
      ""|1)
        printf -v "$password_var" '%s' "$(workspace_random_password)"
        printf -v "$generated_var" '%s' 1
        return 0
        ;;
      2)
        while true; do
          printf "  New password: " >&2
          read -rs value || die "Password is required"
          printf "\n  Confirm password: " >&2
          read -rs confirmation || die "Password confirmation is required"
          printf "\n" >&2
          [[ "$value" == "$confirmation" ]] || { warn "Passwords did not match; try again"; continue; }
          workspace_recovery_password_valid "$value" || { warn "Use 8-64 characters on one line"; continue; }
          printf -v "$password_var" '%s' "$value"
          printf -v "$generated_var" '%s' 0
          return 0
        done
        ;;
      *) warn "Choose 1 or 2" ;;
    esac
  done
}

workspace_vikunja_human_user_id() {
  local username email
  username=$(workspace_read_env VIKUNJA_HUMAN_USERNAME 2>/dev/null || true)
  email=$(workspace_read_env VIKUNJA_HUMAN_EMAIL 2>/dev/null || true)
  [[ -n "$username" && -n "$email" ]] || return 1
  workspace_vikunja_cli user list 2>/dev/null | awk -v username="$username" -v email="$email" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    {
      row = $0
      gsub(/│/, "|", row)
      n = split(row, cols, "|")
      if (n >= 5 && trim(cols[3]) == username && trim(cols[4]) == email) {
        print trim(cols[2])
        exit
      }
    }
  '
}

workspace_recover_vikunja() {
  local password="$1" user email user_id
  user=$(workspace_read_env VIKUNJA_HUMAN_USERNAME 2>/dev/null || true)
  email=$(workspace_read_env VIKUNJA_HUMAN_EMAIL 2>/dev/null || true)
  user_id=$(workspace_vikunja_human_user_id) || true
  [[ "$user_id" =~ ^[0-9]+$ ]] || {
    err "Could not identify the configured Vikunja user: ${user:-unknown}"
    return 1
  }
  workspace_vikunja_cli user reset-password "$user_id" -d -p "$password" >/dev/null 2>&1 || {
    err "Vikunja rejected the password change"
    return 1
  }
  workspace_vikunja_login_jwt "$user" "$password" >/dev/null 2>&1 || {
    err "Vikunja password changed, but login verification failed"
    return 1
  }
  info "Vikunja access recovered for ${email}"
}

workspace_semver_at_least() {
  local current="${1#v}" required="${2#v}"
  current="${current%%-*}"
  required="${required%%-*}"
  awk -v current="$current" -v required="$required" 'BEGIN {
    split(current, a, "."); split(required, b, ".")
    for (i=1; i<=3; i++) {
      av=a[i]+0; bv=b[i]+0
      if (av > bv) exit 0
      if (av < bv) exit 1
    }
    exit 0
  }'
}

workspace_n8n_version() {
  workspace_compose exec -T n8n n8n --version 2>/dev/null | tail -1 | tr -d '\r'
}

workspace_n8n_password_hash() {
  local password="$1" hash
  hash=$(printf '%s' "$password" | workspace_compose exec -T n8n node -e '
    const fs = require("fs");
    let bcrypt;
    try { bcrypt = require("bcryptjs"); }
    catch { bcrypt = require("/usr/local/lib/node_modules/n8n/node_modules/bcryptjs"); }
    bcrypt.hash(fs.readFileSync(0, "utf8"), 10).then((value) => process.stdout.write(value + "\n"));
  ' 2>/dev/null | tail -1) || return 1
  [[ "$hash" =~ ^\$2[aby]\$[0-9][0-9]\$[./A-Za-z0-9]{53}$ ]] || return 1
  printf '%s\n' "$hash"
}

workspace_n8n_wait_ready() {
  local i
  for i in {1..30}; do
    workspace_n8n_http_ready && return 0
    sleep "${SPARK_WORKSPACE_WAIT_SLEEP:-1}"
  done
  return 1
}

workspace_n8n_restore_env() {
  local backup="$1"
  [[ -f "$backup" ]] || return 1
  cp "$backup" "$WORKSPACE_N8N_ENV_FILE" || return 1
  chmod 600 "$WORKSPACE_N8N_ENV_FILE"
}

workspace_n8n_write_recovery_env() {
  local email="$1" first="$2" last="$3" hash="$4"
  workspace_require_prompt_value "n8n owner email" "$email" email
  workspace_require_prompt_value "n8n owner first name" "$first" username
  workspace_require_prompt_value "n8n owner last name" "$last" username
  cat >> "$WORKSPACE_N8N_ENV_FILE" <<EOF
N8N_INSTANCE_OWNER_MANAGED_BY_ENV=true
N8N_INSTANCE_OWNER_EMAIL=${email}
N8N_INSTANCE_OWNER_FIRST_NAME=${first}
N8N_INSTANCE_OWNER_LAST_NAME=${last}
N8N_INSTANCE_OWNER_PASSWORD_HASH='${hash}'
EOF
  chmod 600 "$WORKSPACE_N8N_ENV_FILE"
}

workspace_n8n_login_after_startup() {
  # n8n returns healthz=200 about one second before /rest/login is ready.
  local email="$1" password="$2" delay="${SPARK_WORKSPACE_WAIT_SLEEP:-1}"
  sleep "$delay"
  workspace_n8n_login "$email" "$password" && return 0
  sleep "$delay"
  workspace_n8n_login "$email" "$password"
}

workspace_recover_n8n() {
  local password="$1" version email first last hash backup="" rc=0
  version=$(workspace_n8n_version) || true
  [[ -n "$version" ]] || { err "Could not read the n8n version"; return 1; }
  workspace_semver_at_least "$version" 2.17.0 || {
    err "n8n ${version} cannot recover its owner safely"
    printf "    Update n8n to 2.17.0 or newer, then retry.\n" >&2
    return 1
  }
  email=$(workspace_read_env N8N_BASIC_AUTH_USER 2>/dev/null || true)
  first=$(workspace_read_env N8N_OWNER_FIRST_NAME 2>/dev/null || true)
  last=$(workspace_read_env N8N_OWNER_LAST_NAME 2>/dev/null || true)
  [[ -n "$first" ]] || first=Spark
  [[ -n "$last" ]] || last=Admin
  hash=$(workspace_n8n_password_hash "$password") || {
    err "Could not create the n8n bcrypt password hash"
    return 1
  }
  backup=$(mktemp "${WORKSPACE_CONFIG_DIR}/.n8n.env.recover.XXXXXX") || return 1
  chmod 600 "$backup"
  cp "$WORKSPACE_N8N_ENV_FILE" "$backup" || { rm -f "$backup"; return 1; }
  workspace_n8n_write_recovery_env "$email" "$first" "$last" "$hash" || rc=1
  if [[ "$rc" == "0" ]]; then
    workspace_compose up -d --force-recreate --no-deps n8n >/dev/null 2>&1 || rc=1
  fi
  if [[ "$rc" == "0" ]]; then
    workspace_n8n_wait_ready || rc=1
  fi
  if [[ "$rc" == "0" ]]; then
    workspace_n8n_login_after_startup "$email" "$password" || rc=1
  fi
  workspace_n8n_restore_env "$backup" || rc=1
  rm -f "$backup"
  workspace_compose up -d --force-recreate --no-deps n8n >/dev/null 2>&1 || rc=1
  workspace_n8n_wait_ready || rc=1
  if [[ "$rc" == "0" ]]; then
    workspace_n8n_login_after_startup "$email" "$password" || rc=1
  fi
  if [[ "$rc" != "0" ]]; then
    err "n8n recovery did not complete cleanly"
    printf "    Retry: spark ws recover n8n\n" >&2
    return 1
  fi
  info "n8n access recovered for ${email}"
}

workspace_show_recovery_password() {
  local service="$1" identity="$2" password="$3" output
  output=$(printf "\n  ${YELLOW}${BOLD}Save this password now. Spark will not store or show it again.${NC}\n\n  %s\n    email:    %s\n    password: %s\n\n  Press q to close.\n" \
    "$service" "$identity" "$password")

  if command -v less >/dev/null 2>&1 && \
    { [[ -t 0 && -t 1 && -t 2 ]] || [[ "${SPARK_WORKSPACE_FORCE_PAGER:-0}" == "1" ]]; }; then
    LESS='' LESSOPEN='' LESSHISTFILE=- less -R <<< "$output"
    return 0
  fi

  printf "%s\n" "$output"
  warn "Password shown without a pager; use an interactive terminal to hide it after pressing q"
}

workspace_recover() {
  local service="${1:-}" auto_yes=0 password="" generated=0 identity=""
  [[ -n "$service" ]] && shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes) auto_yes=1; shift ;;
      --help|-h)
        printf "Usage: spark ws recover vikunja|n8n [--yes]\n"
        printf "  Reset an existing Vikunja human or n8n owner password.\n"
        printf "  --yes  Generate a secure password and continue without questions.\n"
        return 0
        ;;
      *) die "Unknown ws recover option: $1" "Usage: spark ws recover vikunja|n8n [--yes]" ;;
    esac
  done
  case "$service" in
    vikunja|n8n) ;;
    help|--help|-h|"")
      printf "Usage: spark ws recover vikunja|n8n [--yes]\n"
      printf "  Reset an existing Vikunja human or n8n owner password.\n"
      return 0
      ;;
    *) die "Unknown workspace service: $service" "Choose vikunja or n8n" ;;
  esac
  workspace_require_config
  workspace_migrate_runtime_config
  printf "\n  ${BOLD}spark ws recover ${service}${NC}\n\n"
  if [[ "$auto_yes" != "1" ]]; then
    is_interactive || die "Recovery confirmation requires a terminal" "Use --yes to continue automatically"
    confirm "Replace the ${service} password now?" || { info "No changes made"; printf "\n"; return 0; }
  fi
  workspace_choose_recovery_password "$auto_yes" password generated
  if [[ "$service" == "vikunja" ]]; then
    workspace_recover_vikunja "$password" || { unset password; return 1; }
    identity=$(workspace_read_env VIKUNJA_HUMAN_EMAIL 2>/dev/null || true)
  else
    workspace_recover_n8n "$password" || { unset password; return 1; }
    identity=$(workspace_read_env N8N_BASIC_AUTH_USER 2>/dev/null || true)
  fi
  if [[ "$generated" == "1" ]]; then
    workspace_show_recovery_password "$service" "$identity" "$password"
  fi
  printf "\n"
  unset password
}

workspace_summary() {
  printf "\n"
  if [[ ${#SETUP_FAILED[@]} -gt 0 ]]; then
    printf "  ${RED}${BOLD}Workspace incomplete:${NC} %d issue(s)\n" "${#SETUP_FAILED[@]}"
    local step
    for step in "${SETUP_FAILED[@]}"; do printf "    ${RED}✗${NC} %s\n" "$step"; done
    if [[ -n "${WORKSPACE_SETUP_RESUME_HINT:-}" ]]; then
      printf "\n  %s\n\n" "$WORKSPACE_SETUP_RESUME_HINT"
    else
      printf "\n  Fix them and re-run: ${BOLD}spark ws setup${NC}\n\n"
    fi
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

  Installs/reconciles the private workspace: Vikunja, Super Productivity, or
  Todoist, plus n8n, shared Postgres, and Hermes/NemoClaw.

  ${BOLD}Flags:${NC}
    --check                     Read-only validation; no files, containers, or Funnel changes.
    --yes                       Accept other safe defaults; task-manager selection is still required.
    --remote user@host          Run setup on a configured remote host.
    --model MODEL               Hermes model; selected from spark list data when omitted.
    --task-manager NAME         vikunja, super-productivity, or todoist; required when non-interactive.
    --tailscale-mode services   Prefer HTTPS names for local services; Todoist exposes n8n/hermes only.
    --tailscale-mode ports      Fallback: MagicDNS host + separate ports bound to Tailscale IP.
    --funnel-action reset       Reset active public Funnel and re-check before setup continues.
    --funnel-action abort       Fail if Funnel is active; no Funnel changes.
    --postgres-image IMAGE      Override Postgres image ref.
    --vikunja-image IMAGE       Override Vikunja image ref.
    --super-productivity-image IMAGE
                                Override the custom Electron image ref.
    --supersync-image IMAGE     Override SuperSync image ref.
    --n8n-image IMAGE           Override n8n image ref.
    --vikunja-username NAME     Human Vikunja username.
    --vikunja-email EMAIL       Human Vikunja email.
    --vikunja-password PASS     Current/initial password; visible to shell history/process tools.
    --vikunja-password-file FILE
                                Read current/initial password from the first line of FILE.
    --token TOKEN               Todoist API token; requested securely in the TUI when omitted.
    --n8n-email EMAIL           n8n owner/admin email.
    --n8n-password PASS         Initial password; visible to shell history/process tools.
    --n8n-password-file FILE    Read initial password from the first line of FILE.
  ${BOLD}Funnel rule:${NC}
    reset = this host should have no public Funnel exposure.
    abort = stop and inspect because Funnel might belong to something else.

EOF
}

cmd_workspace_help() {
  cat <<EOF

  ${BOLD}Usage:${NC} spark ws <command> [options]

  ${BOLD}Commands:${NC}
    setup       Install/check the selected task manager + n8n + Hermes
    start       Start the configured workspace runtime
    stop        Stop the workspace runtime and preserve all data
    restart     Stop and start the configured workspace runtime
    recover     Reset a Vikunja human or n8n owner password
    status      Show operational workspace state
    containers  Show raw workspace container state
    logs        Follow task-manager, SuperSync/Electron, n8n, Postgres, Hermes, or gateway logs
    doctor      Read-only workspace check
    backup      Back up config, task-manager data, n8n, Hermes, and NemoClaw state

  Use ${BOLD}spark ws <command> --help${NC} on commands with options.

  ${BOLD}Setup flags:${NC}
    --check                     Read-only validation
    --yes                       Accept safe defaults
    --remote user@host          Run workspace setup on a configured remote host
    --model MODEL               Hermes model; must match spark list data
    --task-manager NAME         vikunja, super-productivity, or todoist
    --tailscale-mode services|ports
                                default = services; ports = MagicDNS + ports
    --funnel-action reset|abort Handle active Tailscale Funnel explicitly
    --postgres-image IMAGE      Override Postgres image ref
    --vikunja-image IMAGE       Override Vikunja image ref
    --super-productivity-image IMAGE
                                Override the custom Electron image ref
    --supersync-image IMAGE     Override SuperSync image ref
    --n8n-image IMAGE           Override n8n image ref
    --vikunja-username NAME     Human Vikunja username
    --vikunja-email EMAIL       Human Vikunja email
    --vikunja-password PASS     Choose initial Vikunja password
    --vikunja-password-file FILE
                                Safer initial Vikunja password input
    --token TOKEN               Todoist token; securely prompted when omitted
    --n8n-email EMAIL           n8n owner/admin email
    --n8n-password PASS         Choose initial n8n password
    --n8n-password-file FILE    Safer initial n8n password input
EOF
}

cmd_workspace() {
  local subcmd="${1:-}"
  [[ -n "$subcmd" ]] && shift || true
  case "$subcmd" in
    setup)  workspace_setup "$@" ;;
    start)  workspace_start "$@" ;;
    stop)   workspace_stop "$@" ;;
    restart) workspace_restart "$@" ;;
    recover) workspace_recover "$@" ;;
    status) cmd_workspace_status "$@" ;;
    containers) cmd_workspace_containers "$@" ;;
    logs)   cmd_workspace_logs "$@" ;;
    doctor) cmd_workspace_doctor "$@" ;;
    backup) cmd_workspace_backup "$@" ;;
    help|--help|-h|"") cmd_workspace_help ;;
    *) die "Unknown ws command: $subcmd" "Run 'spark ws help'" ;;
  esac
}
