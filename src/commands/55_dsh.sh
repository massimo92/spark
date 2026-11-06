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

dsh_stored_users() {
  jq -r '.tailnetUsers // [] | join(",")' "$DSH_DIR/settings.json" 2>/dev/null || true
}

dsh_access_users() {
  local users="${SPARK_DSH_TAILSCALE_USERS-$(dsh_stored_users)}"
  if [[ -n "$users" && ! "$users" =~ ^[A-Za-z0-9_.+@-]+(,[A-Za-z0-9_.+@-]+)*$ ]]; then
    err 'Use a comma-separated list of exact Tailscale logins in SPARK_DSH_TAILSCALE_USERS' >&2
    return 1
  fi
  printf '%s\n' "$users"
}

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
    # Leave input space and, for large windows, the stock compaction headroom
    # plus the retained fraction of the remaining message budget.
    def output_fits($context):
      . as $output |
      select($context != null and $output < $context and
        ($context <= 65536 or ($context - $output) * 0.84 > 65536));
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
      ([$model.spark_context_window, $model.max_input_tokens] | map(positive) | first) as $context |
      (if $id == "main" or ($id | startswith("vllm/") or startswith("ollama_chat/"))
       then $model.spark_max_output_tokens else $model.max_output_tokens end) as $output |
      {id:$id, api:$api, name:$model.display_name,
       contextWindow:$context,
       maxTokens:([$output | positive | output_fits($context)] | first),
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
      {id:"workspace-controller",config:{documentsDirectory:"/workspace"}},
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
  digest=$({ printf '%s\n' "$version" node24-v3; dsh_selected_assets "$plugins"; spark_builtin_dsh_access; } |
    shasum -a 256) || return 1
  printf 'spark/dsh:%s-%s\n' "$version" "${digest:0:16}"
}

dsh_build_image() (
  local version="$1" plugins="$2" image="$3" staging path encoded i
  docker image inspect "$image" >/dev/null 2>&1 && return 0
  staging=$(mktemp -d) || return 1
  trap 'rm -rf "$staging"' EXIT
  mkdir "$staging/plugins" || return 1
  spark_builtin_dsh_access >"$staging/dsh-access.mjs" && chmod 644 "$staging/dsh-access.mjs" || return 1
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
    printf '\nRUN node node_modules/@deepseek-ai/dsh/lib/bin.js --version\nCOPY dsh-access.mjs ./\n'
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

dsh_plugins_ready() {
  local log="$DSH_DIR/state/launch.log"
  [[ -r "$log" ]] || return 1
  if grep -Eq '^(llm-pi-ai-protocols|dsh-chart|workflows|session-delete|search-router) \(' "$log"; then
    return 1
  else
    [[ $? == 1 ]]
  fi
}

dsh_live_catalog() {
  local url login host cookie
  url=$(dsh_setting url) || return 1
  host="${url#https://}"
  host="${host%/}"
  if [[ "$(dsh_setting access || true)" == tailnet ]]; then
    local users
    users=$(dsh_stored_users)
    curl --noproxy '*' --unix-socket "$(dsh_access_socket)" -fsS --max-time 4 \
      -H "X-Forwarded-Host: $host" -H 'X-Forwarded-Proto: https' -H "Tailscale-User-Login: ${users%%,*}" \
      -H "Origin: ${url%/}" -H 'Content-Type: application/json' \
      -d '{"type":"client-request","rpcId":"00000000-0000-4000-8000-000000000001","method":"session/modelCatalog","payload":{"args":{}}}' \
      http://localhost/api/session/modelCatalog |
      jq -ce '.result | select(.ok == true) | .value | select(.groups | type == "array")'
    return $?
  fi
  login=$(dsh_launch_url) || return 1
  # The self-signed backend is reached strictly on loopback. The Tailscale
  # check below separately verifies the public-facing TLS certificate.
  local loopback=(--noproxy '*' --connect-to "$host:443:127.0.0.1:$DSH_PORT" --insecure --max-time 4)
  cookie=$(printf 'url = "%s"\n' "$login" |
    curl --config - -fsS "${loopback[@]}" -D - -o /dev/null |
    awk '
      /^HTTP\// && $2 == 303 { redirect=1 }
      tolower($1) == "set-cookie:" && tolower($0) ~ /;[[:space:]]*secure/ {
        split($2, pair, ";")
        if (pair[1] ~ /^[A-Za-z0-9._~-]+=[A-Za-z0-9._~%=-]+$/) cookie=pair[1]
      }
      END { if (!redirect || cookie == "") exit 1; print cookie }
    ') || return 1
  printf 'header = "Cookie: %s"\n' "$cookie" |
    curl --config - -fsS "${loopback[@]}" -H "Origin: ${url%/}" -H 'Content-Type: application/json' \
      -d '{"type":"client-request","rpcId":"00000000-0000-4000-8000-000000000001","method":"session/modelCatalog","payload":{"args":{}}}' \
      "${url%/}/api/session/modelCatalog" |
    jq -ce '.result | select(.ok == true) | .value | select(.groups | type == "array")'
}

dsh_catalog_matches() {
  jq -e --slurpfile patch "$DSH_DIR/state/cordis.patch.yml" '
    [$patch[0][] | (select(.id == "llm-pi-ai" and .disabled != true),
      (.insert[]? | select(.id == "llm-pi-ai-protocols"))) |
      .config.providers | to_entries[] | .key as $provider |
      .value.models[] | [$provider,.id]] as $expected |
    [.groups[] | .id as $provider | .models[] | [$provider,.id]] as $active |
    ($expected - $active | length) == 0
  ' >/dev/null
}

dsh_catalog_ready() { dsh_live_catalog 2>/dev/null | dsh_catalog_matches 2>/dev/null; }

dsh_wait_ready() {
  local attempt
  for ((attempt=0; attempt<30; attempt++)); do
    if dsh_running && dsh_launch_url >/dev/null; then
      dsh_plugins_ready || { err 'A DSH plugin did not activate. Inspect the private launch.log.'; return 1; }
      dsh_catalog_ready && return 0
    fi
    sleep 1
  done
  err 'DSH or its managed model catalogue did not become ready. Inspect its private launch.log.'
  return 1
}

dsh_start_container() {
  local image="$1" url="$2" users="${3:-}" host="${2#https://}"
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
      exec > /state/launch.log 2>&1
      for package in @local/dsh-chart @local/dsh-workflows dsh-search-router \
        @local/session-delete @local/dsh-llm-pi-ai-protocols; do
        source="/opt/spark-dsh/node_modules/$package"
        [ -r "$source/package.json" ] || continue
        link="/state/profiles/web/node_modules/$package"
        if [ -L "$link" ] && [ "$(readlink "$link")" = "$source" ]; then continue; fi
        if [ -e "$link" ] || [ -L "$link" ]; then
          echo "DSH profile already owns plugin $package"
          exit 1
        fi
        mkdir -p "${link%/*}"
        ln -s "$source" "$link"
      done
      export LITELLM_API_KEY="$(cat /run/spark-dsh/gateway-key)"
      port="$1" url="$2" users="$4"
      set -- /opt/spark-dsh/node_modules/@deepseek-ai/dsh/lib/bin.js web \
        --no-open --host 127.0.0.1 --port "$1" --public-url "$2" --trusted-host "$3" \
        --tls-cert /run/spark-dsh/tls.crt --tls-key /run/spark-dsh/tls.key
      if [ -n "$users" ]; then
        exec node /opt/spark-dsh/dsh-access.mjs /state/access.sock /state/launch.log \
          "$port" "$url" /run/spark-dsh/tls.crt "$users" "$@"
      fi
      exec node "$@"
    ' sh "$DSH_PORT" "$url" "$host" "$users" >/dev/null && dsh_wait_ready
}

dsh_activate_locked() (
  local version="$1" plugins="$2" url="$3" image="$4" users="$5" previous_image="" previous_url="" previous_running=false
  local settings patch backup previous_key previous_users
  (umask 077; mkdir -p "$DSH_DIR/state" "$DSH_DIR/secrets" "$WORKSPACE_DATA_DIR/dsh-files") || return 1
  chmod 700 "$DSH_DIR" "$DSH_DIR/state" || return 1
  backup=$(mktemp -d "$DSH_DIR/.backup.XXXXXX") || return 1
  trap 'rm -rf "$backup"' EXIT
  if docker inspect "$DSH_CONTAINER" >/dev/null 2>&1; then
    dsh_own_container || { err "Container name $DSH_CONTAINER is already in use"; return 1; }
    previous_image=$(docker inspect -f '{{.Image}}' "$DSH_CONTAINER") || return 1
    previous_running=$(docker inspect -f '{{.State.Running}}' "$DSH_CONTAINER") || return 1
  fi
  previous_url=$(dsh_setting url || true)
  previous_users=$(dsh_stored_users)
  settings=$(jq -nc --arg version "$version" --arg plugins "$plugins" --arg url "$url" --arg image "$image" --arg users "$users" \
    '{version:$version,plugins:$plugins,url:$url,image:$image,
      access:(if $users == "" then "legacy" else "tailnet" end),
      tailnetUsers:($users | split(",") | unique)}') || return 1
  users=$(jq -r '.tailnetUsers | join(",")' <<<"$settings")
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
    dsh_sync_catalog && dsh_wait_ready
    return $?
  fi
  if ! printf '%s\n' "$settings" | dsh_write "$DSH_DIR/settings.json" || ! dsh_sync_catalog "$plugins"; then
    if [[ -f "$backup/settings.json" ]]; then mv "$backup/settings.json" "$DSH_DIR/settings.json"; else rm -f "$DSH_DIR/settings.json"; fi
    return 1
  fi
  if { [[ "$previous_running" != true ]] || docker stop "$DSH_CONTAINER" >/dev/null; } &&
     { [[ -z "$previous_image" ]] || docker rm "$DSH_CONTAINER" >/dev/null; }; then
    if dsh_start_container "$image" "$url" "$users"; then return 0; fi
    if dsh_own_container; then docker rm -f "$DSH_CONTAINER" >/dev/null || return 1; fi
  fi
  if [[ -f "$backup/cordis.patch.yml" ]]; then mv "$backup/cordis.patch.yml" "$patch"; else rm -f "$patch"; fi
  if [[ -f "$backup/settings.json" ]]; then
    mv "$backup/settings.json" "$DSH_DIR/settings.json" || return 1
    if [[ "$previous_running" == true && -n "$previous_image" && -n "$previous_url" ]] && ! dsh_running; then
      if dsh_own_container; then
        docker start "$DSH_CONTAINER" >/dev/null && dsh_wait_ready || err 'Could not restart the previous DSH runtime'
      else
        dsh_start_container "$previous_image" "$previous_url" "$previous_users" || err 'Could not restore the previous DSH runtime'
      fi
    fi
  else
    rm -f "$DSH_DIR/settings.json"
  fi
  return 1
)

dsh_access_socket() { printf '%s/state/access.sock\n' "$DSH_DIR"; }
dsh_socket_target() { printf 'unix:%s\n' "$(dsh_access_socket)"; }
dsh_legacy_target() { printf 'https+insecure://127.0.0.1:%s\n' "$DSH_PORT"; }
dsh_public_target() {
  if [[ "$(dsh_setting access || true)" == tailnet ]]; then dsh_socket_target; else dsh_legacy_target; fi
}

dsh_serve_config() {
  tailscale serve get-config --all 2>/dev/null || tailscale serve status --json 2>/dev/null
}

dsh_private_mapped() {
  local out
  out=$(dsh_serve_config) || return 1
  dsh_mapping_matches "$out"
}

dsh_mapping_matches() {
  jq -e --arg target "${2:-$(dsh_public_target)}" '
    (.services // .Services // {})["svc:dsh"] |
    (.endpoints["tcp:443"] == $target or .endpoints["tcp:443"] == ("https://" + $target)) or
    any((.Web // {}) | to_entries[];
      (.key | endswith(":443")) and .value.Handlers["/"].Proxy == $target)
  ' <<<"$1" >/dev/null 2>&1
}

dsh_service_ip() {
  tailscale status --json 2>/dev/null | jq -er '
    [.Self.CapMap["service-host"][]? | .["svc:dsh"][]? | strings] |
    (map(select(test("^[0-9]+(\\.[0-9]+){3}$"))) | first) //
    (map(select(contains(":") and test("^[0-9A-Fa-f:]+$"))) | first // empty)
  '
}

dsh_service_approved() { dsh_service_ip >/dev/null; }

dsh_service_api() {
  local method="$1" token="$2" data="${3:-}" args=()
  [[ -z "$data" ]] || args=(-H 'Content-Type: application/json' --data-binary "$data")
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl --config - -sS --max-time 12 -X "$method" "${args[@]}" -w '\n%{http_code}' \
      'https://api.tailscale.com/api/v2/tailnet/-/vip-services/svc:dsh'
}

dsh_register_service() {
  local token="${SPARK_TAILSCALE_SERVICES_TOKEN:-}" response code
  [[ -n "$token" ]] || return 0
  [[ "$token" =~ ^[A-Za-z0-9_.~-]+$ ]] || { err 'Invalid Tailscale Services API token'; return 1; }
  response=$(dsh_service_api GET "$token") || return 1
  case "${response##*$'\n'}" in
    200)
      jq -e '.name == "svc:dsh" and (.ports | index("tcp:443") != null)' \
        <<<"${response%$'\n'*}" >/dev/null ||
        { err 'Existing Tailscale Service svc:dsh must include TCP 443'; return 1; }
      ;;
    404)
      response=$(dsh_service_api PUT "$token" '{"name":"svc:dsh","ports":["tcp:443"]}') || return 1
      code="${response##*$'\n'}"
      [[ "$code" =~ ^2[0-9]{2}$ ]] || { err "Could not register Tailscale Service svc:dsh (HTTP $code)"; return 1; }
      ;;
    *) err "Could not read Tailscale Service svc:dsh (HTTP ${response##*$'\n'})"; return 1 ;;
  esac
}

dsh_https_ready() {
  local url host ip headers access
  url=$(dsh_setting url) || return 1
  ip=$(dsh_service_ip) || return 1
  host="${url#https://}"
  host="${host%/}"
  [[ "$ip" != *:* ]] || ip="[$ip]"
  # Linux need not use MagicDNS for its own service. Probe the approved VIP
  # with the service hostname as SNI and keep certificate verification on.
  headers=$(curl --noproxy '*' --resolve "$host:443:$ip" -sS --max-time 5 \
    -o /dev/null -D - "$url" 2>/dev/null) || return 1
  access=$(dsh_setting access || true)
  awk -v access="$access" '
    /^HTTP\// { status=$2; denied=0 }
    tolower($0) ~ /^x-spark-dsh-access: denied[[:space:]]*$/ { denied=1 }
    END { exit !(status == 200 || (access == "tailnet" && status == 403 && denied) ||
      (access != "tailnet" && status == 401)) }
  ' <<<"$headers"
}

dsh_serve_target() {
  local serve_args=(tailscale serve --bg --service=svc:dsh --https=443 --yes "$1")
  if command -v timeout >/dev/null 2>&1; then serve_args=(timeout 15 "${serve_args[@]}"); fi
  "${serve_args[@]}" >/dev/null
}

dsh_publish_locked() {
  local out attempt approved=0
  if tailscale_funnel_status_active; then
    err 'Disable Tailscale Funnel before publishing DSH'
    return 1
  fi
  out=$(dsh_serve_config) || return 1
  if jq -e '(.services // .Services // {}) | has("svc:dsh")' <<<"$out" >/dev/null 2>&1 &&
     ! dsh_mapping_matches "$out" "$(dsh_socket_target)" && ! dsh_mapping_matches "$out" "$(dsh_legacy_target)"; then
    err 'Tailscale Service svc:dsh already points to another target'
    return 1
  fi
  dsh_service_approved || dsh_register_service || return 1
  if ! dsh_mapping_matches "$out"; then
    if ! dsh_serve_target "$(dsh_public_target)"; then
      err 'Could not publish svc:dsh. Check Services socket support, or supply a Services API token to register it.'
      return 1
    fi
    if ! dsh_private_mapped; then
      err 'Tailscale did not save the expected DSH proxy target'
      return 1
    fi
  fi
  for ((attempt=0; attempt<15; attempt++)); do
    if dsh_service_approved; then
      approved=1
      if dsh_https_ready; then
        info "DSH: $(dsh_setting url)"
        [[ "$(dsh_setting access || true)" == tailnet ]] || info 'DSH sign-in: spark ws dsh login'
        return 0
      fi
    fi
    sleep 1
  done
  if [[ "$approved" == 1 ]]; then
    err 'DSH is approved but the private HTTPS proxy is unreachable.'
    if [[ "$(dsh_setting access || true)" == tailnet ]] && dsh_mapping_matches "$out" "$(dsh_legacy_target)"; then
      dsh_serve_target "$(dsh_legacy_target)" || err 'Could not restore the previous DSH publication'
    fi
  else
    err 'DSH host approval is pending. Check that svc:dsh exists and autoApprovers.services includes this host tag.'
  fi
  return 1
}

dsh_publish() { gateway_with_lock dsh_publish_locked; }

dsh_install() {
  local version="$1" plugins="$2" url="$3" image users socket LC_ALL=C
  users=$(dsh_access_users) || return 1
  if [[ -n "$users" ]]; then
    socket=$(dsh_access_socket)
    [[ "${#socket}" -le 107 ]] || { err 'Spark config path is too long for the DSH access socket'; return 1; }
  fi
  dsh_version_valid "$version" || return 1
  image=$(dsh_image_id "$version" "$plugins") || return 1
  dsh_build_image "$version" "$plugins" "$image" || return 1
  gateway_with_lock dsh_activate_locked "$version" "$plugins" "$url" "$image" "$users"
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
  local out
  dsh_configured || return 0
  out=$(dsh_serve_config) || return 0
  if dsh_mapping_matches "$out" "$(dsh_socket_target)" || dsh_mapping_matches "$out" "$(dsh_legacy_target)"; then
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
  elif ! dsh_private_mapped; then printf 'not-advertised\n'
  elif ! dsh_service_approved; then printf 'pending-approval\n'
  elif ! dsh_https_ready; then printf 'https-unreachable\n'
  elif ! dsh_plugins_ready; then printf 'plugins-failed\n'
  elif ! dsh_catalog_ready; then printf 'catalog-incomplete\n'
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
      [[ "$(dsh_setting access || true)" == tailnet ]] ||
        printf '  First visit or expired session: spark ws dsh login\n'
      [[ "$state" == ready ]]
      ;;
    login)
      if [[ "$(dsh_setting access || true)" == tailnet ]] && dsh_running && dsh_private_mapped; then
        printf '%s\n' "$(dsh_setting url)"
        return 0
      fi
      [[ -t 1 ]] || die 'DSH sign-in requires a terminal' 'Use ssh -t when running remotely'
      dsh_running && dsh_mapping_matches "$(dsh_serve_config)" "$(dsh_legacy_target)" ||
        die 'DSH private access is not ready'
      dsh_service_approved || die 'DSH host approval is pending' 'Approve this host for svc:dsh in the Tailscale Services admin console'
      dsh_launch_url || die 'Could not read the DSH sign-in link'
      ;;
    *) die 'Usage: spark ws dsh <status|login>' ;;
  esac
}
