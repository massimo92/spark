# Based on spark by Massimo Angelini - https://github.com/massimo92/spark

DSH_DIR="${WORKSPACE_CONFIG_DIR}/dsh"
DSH_CONTAINER=spark-dsh
DSH_PORT=3080
DSH_INITIAL_VERSION=0.2.1-rc.5
DSH_PLUGIN_NAMES=(chart workflows search-router session-delete protocols)
DSH_PLUGIN_DIRS=(dsh-chart dsh-workflows dsh-search-router session-delete dsh-llm-pi-ai-protocols)

dsh_configured() { [[ -f "$DSH_DIR/settings.json" ]]; }
dsh_setting() { jq -er --arg field "$1" '.[$field]' "$DSH_DIR/settings.json" 2>/dev/null; }
dsh_version_valid() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; }

dsh_plugin_selection() {
  local selection="$1" plugin available csv
  if [[ "$selection" == all ]]; then
    (IFS=,; printf '%s\n' "${DSH_PLUGIN_NAMES[*]}")
    return 0
  fi
  [[ "$selection" != none ]] || { printf 'none\n'; return 0; }
  [[ "$selection" =~ ^[a-z-]+(,[a-z-]+)*$ ]] || return 1
  local selected=() requested=()
  IFS=, read -r -a requested <<<"$selection"
  for plugin in "${requested[@]}"; do
    available=0
    for csv in "${DSH_PLUGIN_NAMES[@]}"; do
      [[ "$csv" != "$plugin" ]] || available=1
    done
    [[ "$available" == 1 ]] || return 1
  done
  for plugin in "${DSH_PLUGIN_NAMES[@]}"; do
    [[ ",$selection," != *",$plugin,"* ]] || selected+=("$plugin")
  done
  (IFS=,; printf '%s\n' "${selected[*]}")
}

dsh_select_plugins() {
  local selection="$1" auto_yes="$2" current="${3:-none}" answer normalized
  if [[ -z "$selection" && "$auto_yes" != 1 ]] && is_interactive; then
    printf '  Optional DSH plugins (choose several, separated by commas)\n' >&2
    printf '    %s\n' "${DSH_PLUGIN_NAMES[@]}" >&2
    while true; do
      printf '  Plugins [all, none, or names] (%s): ' "$current" >&2
      IFS= read -r answer || break
      if [[ -z "$answer" && "$current" == keep ]]; then return 0; fi
      if normalized=$(dsh_plugin_selection "${answer:-$current}"); then
        printf '%s\n' "$normalized"
        return 0
      fi
      warn 'Unknown DSH plugin selection' >&2
    done
  fi
  [[ "${selection:-$current}" != keep ]] || return 0
  dsh_plugin_selection "${selection:-$current}"
}

dsh_write() {
  local file="$1" tmp
  tmp=$(umask 077; mktemp "${file}.XXXXXX") || return 1
  if ! cat >"$tmp"; then rm -f "$tmp"; return 1; fi
  if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
    rm -f "$tmp"
  else
    mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  fi
}

dsh_gateway_url() { printf 'http://127.0.0.1:%s/v1\n' "$(gateway_configured_port)"; }

dsh_ensure_key() {
  local file="$DSH_DIR/secrets/gateway-key" key
  key=$(cat "$file" 2>/dev/null || true)
  if [[ -n "$key" ]] && gateway_virtual_validate "$key"; then return 0; fi
  # Keep the candidate on disk before calling LiteLLM. A retried setup can
  # validate a key whose creation succeeded despite an interrupted response.
  local pending="${file}.pending"
  key=$(cat "$pending" 2>/dev/null || true)
  if [[ ! "$key" =~ ^sk-[a-f0-9]{64}$ ]]; then
    key="sk-$(openssl rand -hex 32)" || return 1
    printf '%s\n' "$key" | dsh_write "$pending" || return 1
  fi
  if ! gateway_virtual_validate "$key"; then
    gateway_virtual_create spark-managed "$key" >/dev/null || return 1
    gateway_virtual_validate "$key" || return 1
  fi
  mv -f "$pending" "$file"
}

dsh_render_patch() {
  local visible="$1" info="$2" plugins="$3" url="$4"
  printf '%s\n%s\n' "$visible" "$info" | jq -s --arg plugins "$plugins" --arg url "$url" '
    def enabled($name): $plugins | split(",") | index($name) != null;
    def positive: select(type == "number" and . > 0 and . == floor);
    def protocol:
      if . == "responses" then "openai-responses"
      elif . == "chat" or . == null then "openai-completions"
      else empty end;
    .[0] as $visible | .[1] as $info |
    ($info.data | map(select(.model_name | type == "string") | {key:.model_name,value:(.model_info // {})}) |
      from_entries) as $catalog |
    [$visible.data[] | select((.id | type) == "string" and (.id | contains("*") | not)) |
      .id as $id | $catalog[$id] as $model |
      ($model.mode | protocol) as $api |
      {id:$id, api:$api, name:$model.display_name,
       contextWindow:([$model.spark_context_window, $model.max_input_tokens] | map(positive) | first),
       maxTokens:([$model.max_output_tokens] | map(positive) | first),
       input:(if $model.supports_vision == true then ["text","image"] else ["text"] end),
       reasoningEfforts:$model.spark_reasoning_efforts, compat:$model.spark_dsh_compat}
      | with_entries(select(.value != null))] | unique_by(.id) as $models |
    def provider($name; $api; $entries):
      {displayName:$name, api:$api, baseURL:$url, apiKeyEnv:"LITELLM_API_KEY", models:$entries};
    def native($name; $api):
      [$models[] | select(.api == $api) | del(.api)] as $entries |
      if ($entries | length) == 0 then {} else
        {($name):provider(("LiteLLM " + (if $api == "openai-responses" then "Responses" else "Chat" end)); $api; $entries)}
      end;
    def insert($id; $name): {insert:[{id:$id,name:$name}]};
    (enabled("protocols")) as $mixed |
    [
      {id:"session-log-deepseek",config:{enabled:false}},
      {id:"llm-deepseek",disabled:true},
      {id:"llm-deepseek-account",disabled:true},
      if $mixed then
        {id:"llm-pi-ai",disabled:true},
        {insert:[{id:"llm-pi-ai-protocols",name:"@local/dsh-llm-pi-ai-protocols",config:{
          providers:(if ($models | length) == 0 then {} else
            {litellm:(provider("LiteLLM";"openai-completions";$models) + {transport:"sse"})} end)}}]}
      else
        {id:"llm-pi-ai",config:{providers:(
          native("litellm";"openai-completions") + native("litellm-responses";"openai-responses"))}}
      end,
      ((($models | map(select(.id == "main")) | first) // ($models | first)) |
        if has("id") then
          {id:"agent-default-model",config:{model:.id,provider:(
            if $mixed or .api == "openai-completions" then "litellm"
            else "litellm-responses" end)}}
        else empty end)
    ] +
    [if enabled("chart") then insert("dsh-chart";"@local/dsh-chart") else empty end,
     if enabled("workflows") then insert("workflows";"@local/dsh-workflows") else empty end,
     if enabled("session-delete") then insert("session-delete";"@local/session-delete") else empty end,
     if enabled("search-router") then
       insert("search-router";"dsh-search-router") | .insert[0].config={order:"tavily, duckduckgo"}
     else empty end,
     if enabled("search-router") then
       {id:"web",config:{searchProvider:"search-router"}},
       {id:"web-search-deepseek",disabled:true},
       {id:"tool-web",disabled:false,config:{fetch:false,searchTimeoutMs:60000}}
     else empty end]
  '
}

dsh_sync_catalog() {
  dsh_configured || return 0
  local plugins="${1:-}" key url visible info patch
  [[ -n "$plugins" ]] || plugins=$(dsh_setting plugins) || return 1
  key=$(cat "$DSH_DIR/secrets/gateway-key" 2>/dev/null) || return 1
  [[ "$key" =~ ^sk-[a-f0-9]{64}$ ]] || return 1
  url=$(dsh_gateway_url) || return 1
  visible=$(printf 'header = "Authorization: Bearer %s"\n' "$key" |
    curl --config - -fsS --max-time 5 "$url/models") || return 1
  # Read deployment metadata using Spark's existing local admin helper. DSH
  # receives the generated catalogue and its own inference credential only.
  info=$(gateway_curl -fsS --max-time 5 "${url%/v1}/model/info") || return 1
  jq -e '.data | type == "array"' <<<"$visible" >/dev/null &&
    jq -e '.data | type == "array"' <<<"$info" >/dev/null || return 1
  patch=$(dsh_render_patch "$visible" "$info" "$plugins" "$url") || return 1
  printf '%s\n' "$patch" | dsh_write "$DSH_DIR/state/cordis.patch.yml"
}

dsh_sync_after_gateway() {
  dsh_sync_catalog || warn 'DSH catalogue refresh failed; retained its last valid catalogue. Run spark ws repair to retry.'
}

dsh_selected_assets() {
  local plugins="$1" path encoded i
  while IFS=$'\t' read -r path encoded; do
    for i in "${!DSH_PLUGIN_NAMES[@]}"; do
      if [[ ",$plugins," == *",${DSH_PLUGIN_NAMES[$i]},"* && "$path" == "${DSH_PLUGIN_DIRS[$i]}/"* ]]; then
        printf '%s\t%s\n' "$path" "$encoded"
        break
      fi
    done
  done < <(spark_builtin_dsh_assets)
}

dsh_image_id() {
  local version="$1" plugins="$2" digest
  digest=$({ printf '%s\n' "$version" node24-v2; dsh_selected_assets "$plugins"; } | shasum -a 256) || return 1
  printf 'spark/dsh:%s-%s\n' "$version" "${digest:0:16}"
}

dsh_build_image() (
  local version="$1" plugins="$2" image="$3" staging path encoded i
  docker image inspect "$image" >/dev/null 2>&1 && return 0
  staging=$(mktemp -d) || return 1
  trap 'rm -rf "$staging"' EXIT
  mkdir "$staging/plugins" || return 1
  while IFS=$'\t' read -r path encoded; do
    mkdir -p "$staging/plugins/${path%/*}" || return 1
    printf '%s' "$encoded" | base64 -d >"$staging/plugins/$path" || return 1
  done < <(dsh_selected_assets "$plugins")
  local packages=("@deepseek-ai/dsh@$version")
  for i in "${!DSH_PLUGIN_NAMES[@]}"; do
    if [[ ",$plugins," == *",${DSH_PLUGIN_NAMES[$i]},"* ]]; then
      [[ -f "$staging/plugins/${DSH_PLUGIN_DIRS[$i]}/package.json" ]] || return 1
      packages+=("./plugins/${DSH_PLUGIN_DIRS[$i]}")
    fi
  done
  {
    printf 'FROM node:24-bookworm-slim\nWORKDIR /opt/spark-dsh\nCOPY plugins/ ./plugins/\n'
    printf 'RUN npm install --omit=dev --install-links --no-audit --no-fund'
    printf ' %s' "${packages[@]}"
    printf '\nRUN node node_modules/@deepseek-ai/dsh/lib/bin.js --version\n'
  } >"$staging/Dockerfile" || return 1
  docker build -t "$image" "$staging"
)

dsh_own_container() {
  local owner
  owner=$(docker inspect -f '{{index .Config.Labels "io.spark.dsh.owner"}}' "$DSH_CONTAINER" 2>/dev/null) || return 1
  [[ "$owner" == "$(gateway_database_owner)" ]]
}

dsh_launch_url() {
  local url
  url=$(dsh_setting url) || return 1
  awk -v root="${url%/}/?token=" '
    $1 == "dsh" && $2 == "web:" && index($3, root) == 1 &&
    substr($3, length(root)+1) ~ /^[A-Za-z0-9_.~-]+$/ { result=$3 }
    END { if (result == "") exit 1; print result }
  ' "$DSH_DIR/state/launch.log" 2>/dev/null
}

dsh_running() {
  dsh_own_container &&
    [[ "$(docker inspect -f '{{.State.Running}}' "$DSH_CONTAINER" 2>/dev/null)" == true ]]
}

dsh_wait_ready() {
  local attempt
  for ((attempt=0; attempt<30; attempt++)); do
    if dsh_running && dsh_launch_url >/dev/null; then return 0; fi
    sleep 1
  done
  err 'DSH did not start. Inspect its private launch.log under the workspace DSH state directory.'
  return 1
}

dsh_start_container() {
  local image="$1" url="$2" host="${2#https://}"
  host="${host%/}"
  : >"$DSH_DIR/state/launch.log" || return 1
  chmod 600 "$DSH_DIR/state/launch.log" || return 1
  docker run -d --name "$DSH_CONTAINER" --restart unless-stopped --init \
    --label "io.spark.dsh.owner=$(gateway_database_owner)" --network host \
    --user "$(id -u):$(id -g)" --cap-drop ALL --security-opt no-new-privileges \
    -e HOME=/state -e DSH_HOME=/state \
    -v "$DSH_DIR/state:/state" -v "$DSH_DIR/secrets:/run/spark-dsh:ro" \
    -v "$WORKSPACE_DATA_DIR/dsh-files:/workspace" -w /workspace \
    "$image" sh -ec '
      umask 077
      export LITELLM_API_KEY="$(cat /run/spark-dsh/gateway-key)"
      exec node /opt/spark-dsh/node_modules/@deepseek-ai/dsh/lib/bin.js web \
        --no-open --host 127.0.0.1 --port "$1" --public-url "$2" --trusted-host "$3" \
        --tls-cert /run/spark-dsh/tls.crt --tls-key /run/spark-dsh/tls.key \
        > /state/launch.log 2>&1
    ' sh "$DSH_PORT" "$url" "$host" >/dev/null && dsh_wait_ready
}

dsh_activate_locked() (
  local version="$1" plugins="$2" url="$3" image="$4" previous_image="" previous_url="" previous_running=false
  local settings patch backup previous_key
  (umask 077; mkdir -p "$DSH_DIR/state" "$DSH_DIR/secrets" "$WORKSPACE_DATA_DIR/dsh-files") || return 1
  backup=$(mktemp -d "$DSH_DIR/.backup.XXXXXX") || return 1
  trap 'rm -rf "$backup"' EXIT
  if docker inspect "$DSH_CONTAINER" >/dev/null 2>&1; then
    dsh_own_container || { err "Container name $DSH_CONTAINER is already in use"; return 1; }
    previous_image=$(docker inspect -f '{{.Image}}' "$DSH_CONTAINER") || return 1
    previous_running=$(docker inspect -f '{{.State.Running}}' "$DSH_CONTAINER") || return 1
  fi
  previous_url=$(dsh_setting url || true)
  settings=$(jq -nc --arg version "$version" --arg plugins "$plugins" --arg url "$url" --arg image "$image" \
    '{version:$version,plugins:$plugins,url:$url,image:$image}') || return 1
  [[ ! -f "$DSH_DIR/settings.json" ]] || cp "$DSH_DIR/settings.json" "$backup/settings.json" || return 1
  patch="$DSH_DIR/state/cordis.patch.yml"
  [[ ! -f "$patch" ]] || cp "$patch" "$backup/cordis.patch.yml" || return 1
  if [[ ! -s "$DSH_DIR/secrets/tls.key" || ! -s "$DSH_DIR/secrets/tls.crt" ]]; then
    (umask 077; openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=localhost \
      -keyout "$DSH_DIR/secrets/tls.key" -out "$DSH_DIR/secrets/tls.crt" >/dev/null 2>&1) || return 1
  fi
  previous_key=$(cat "$DSH_DIR/secrets/gateway-key" 2>/dev/null || true)
  dsh_ensure_key || return 1
  if dsh_running &&
     [[ "$settings" == "$(cat "$DSH_DIR/settings.json" 2>/dev/null || true)" &&
        "$previous_key" == "$(cat "$DSH_DIR/secrets/gateway-key")" ]]; then
    dsh_sync_catalog
    return $?
  fi
  if ! printf '%s\n' "$settings" | dsh_write "$DSH_DIR/settings.json" || ! dsh_sync_catalog "$plugins"; then
    if [[ -f "$backup/settings.json" ]]; then mv "$backup/settings.json" "$DSH_DIR/settings.json"; else rm -f "$DSH_DIR/settings.json"; fi
    return 1
  fi
  if { [[ "$previous_running" != true ]] || docker stop "$DSH_CONTAINER" >/dev/null; } &&
     { [[ -z "$previous_image" ]] || docker rm "$DSH_CONTAINER" >/dev/null; }; then
    if dsh_start_container "$image" "$url"; then return 0; fi
    if dsh_own_container; then docker rm -f "$DSH_CONTAINER" >/dev/null || return 1; fi
  fi
  if [[ -f "$backup/cordis.patch.yml" ]]; then mv "$backup/cordis.patch.yml" "$patch"; else rm -f "$patch"; fi
  if [[ -f "$backup/settings.json" ]]; then
    mv "$backup/settings.json" "$DSH_DIR/settings.json" || return 1
    if [[ "$previous_running" == true && -n "$previous_image" && -n "$previous_url" ]] && ! dsh_running; then
      if dsh_own_container; then
        docker start "$DSH_CONTAINER" >/dev/null && dsh_wait_ready || err 'Could not restart the previous DSH runtime'
      else
        dsh_start_container "$previous_image" "$previous_url" || err 'Could not restore the previous DSH runtime'
      fi
    fi
  else
    rm -f "$DSH_DIR/settings.json"
  fi
  return 1
)

dsh_public_target() { printf 'https+insecure://127.0.0.1:%s\n' "$DSH_PORT"; }

dsh_serve_config() {
  tailscale serve get-config --all 2>/dev/null || tailscale serve status --json 2>/dev/null
}

dsh_private_mapped() {
  local out
  out=$(dsh_serve_config) || return 1
  dsh_mapping_matches "$out"
}

dsh_mapping_matches() {
  jq -e --arg target "$(dsh_public_target)" '
    (.services // .Services // {})["svc:dsh"] |
    .endpoints["tcp:443"] == $target or
    any((.Web // {}) | to_entries[];
      (.key | endswith(":443")) and .value.Handlers["/"].Proxy == $target)
  ' <<<"$1" >/dev/null 2>&1
}

dsh_publish() {
  local out
  if tailscale_funnel_status_active; then
    err 'Disable Tailscale Funnel before publishing DSH'
    return 1
  fi
  out=$(dsh_serve_config) || return 1
  if ! dsh_mapping_matches "$out"; then
    if jq -e '(.services // .Services // {}) | has("svc:dsh")' <<<"$out" >/dev/null 2>&1; then
      err 'Tailscale Service svc:dsh already points to another target'
      return 1
    fi
    local serve_args=(tailscale serve --bg --service=svc:dsh --https=443 --yes "$(dsh_public_target)")
    if command -v timeout >/dev/null 2>&1; then serve_args=(timeout 15 "${serve_args[@]}"); fi
    if ! "${serve_args[@]}" >/dev/null; then
      err 'Register svc:dsh (TCP 443) and approve this host in the Tailscale Services admin console, then rerun setup.'
      return 1
    fi
    dsh_private_mapped || return 1
  fi
  info "DSH: $(dsh_setting url)  (first sign-in: spark ws dsh login)"
}

dsh_install() {
  local version="$1" plugins="$2" url="$3" image
  dsh_version_valid "$version" || return 1
  image=$(dsh_image_id "$version" "$plugins") || return 1
  dsh_build_image "$version" "$plugins" "$image" || return 1
  gateway_with_lock dsh_activate_locked "$version" "$plugins" "$url" "$image"
}

dsh_workspace_setup() {
  local mode="$1" tailnet="$2" plugins="$3" version url
  if [[ "$mode" != services ]]; then
    dsh_workspace_stop && dsh_unpublish
    return $?
  fi
  if [[ "$SPARK_OS" != Linux ]]; then
    [[ "${plugins:-none}" == none ]] || { err 'DSH workspace plugins require a Linux Docker host'; return 1; }
    return 0
  fi
  [[ "$tailnet" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.ts\.net$ ]] || { err 'DSH requires a Tailscale DNS suffix'; return 1; }
  version=$(dsh_setting version || printf '%s\n' "$DSH_INITIAL_VERSION")
  url="https://dsh.${tailnet}/"
  if tailscale_funnel_status_active; then
    err 'Disable Tailscale Funnel before publishing DSH'
    return 1
  fi
  dsh_install "$version" "$plugins" "$url" && dsh_publish
}

dsh_workspace_start() {
  local plugins
  dsh_configured || return 0
  plugins=$(dsh_setting plugins) || return 1
  dsh_workspace_setup "$(workspace_read_env WORKSPACE_TAILSCALE_MODE)" "$1" "$plugins"
}

dsh_workspace_stop() {
  dsh_configured || return 0
  if dsh_running; then docker stop "$DSH_CONTAINER" >/dev/null || return 1; fi
}

dsh_unpublish() {
  if dsh_configured && dsh_private_mapped; then
    tailscale serve --service=svc:dsh --https=443 --yes off >/dev/null || return 1
  fi
}

dsh_workspace_uninstall() {
  local dry_run="$1"
  dsh_configured || return 0
  if [[ "$dry_run" == 1 ]]; then
    printf '  would remove DSH container and private Tailscale publication\n'
  else
    dsh_workspace_stop && dsh_unpublish || return 1
    if dsh_own_container; then docker rm -f "$DSH_CONTAINER" >/dev/null || return 1; fi
    local key
    key=$(cat "$DSH_DIR/secrets/gateway-key" 2>/dev/null || true)
    if [[ "$key" =~ ^sk-[a-f0-9]{64}$ ]] && gateway_running_state; then
      jq -nc --arg hash "$(gateway_key_hash "$key")" '{keys:[$hash]}' |
        gateway_admin_post /key/delete >/dev/null || return 1
    fi
  fi
}

dsh_latest_version() {
  local version
  version=$(curl -fsSL --max-time 8 https://registry.npmjs.org/@deepseek-ai%2fdsh/latest | jq -er '.version') || return 1
  dsh_version_valid "$version" && printf '%s\n' "$version"
}

dsh_version_is_newer() {
  local latest="$1" current="$2"
  [[ "$latest" != "$current" ]] || return 1
  workspace_semver_at_least "$latest" "$current" || return 1
  if [[ "${latest%%-*}" == "${current%%-*}" && "$latest" == *-* ]]; then
    [[ "$current" == *-* ]] || return 1
    [[ "$(printf '%s\n' "$latest" "$current" | LC_ALL=C sort -V | tail -1)" == "$latest" ]]
  fi
}

dsh_status_state() {
  if ! dsh_running; then printf 'stopped\n'
  elif ! dsh_private_mapped; then printf 'running-not-ready\n'
  else printf 'ready\n'
  fi
}

dsh_command() {
  [[ $# == 1 ]] || die 'Usage: spark ws dsh <status|login>'
  dsh_configured || die 'DSH is not configured' 'Run spark ws setup'
  case "$1" in
    status)
      local state
      state=$(dsh_status_state)
      printf 'DeepSeek Harness %s\n  State: %s\n  URL: %s\n  Plugins: %s\n' \
        "$(dsh_setting version)" "$state" "$(dsh_setting url)" "$(dsh_setting plugins)"
      [[ "$state" == ready ]]
      ;;
    login)
      [[ -t 1 ]] || die 'DSH sign-in requires a terminal' 'Use ssh -t when running remotely'
      dsh_running && dsh_private_mapped || die 'DSH private access is not ready'
      dsh_launch_url || die 'Could not read the DSH sign-in link'
      ;;
    *) die 'Usage: spark ws dsh <status|login>' ;;
  esac
}
