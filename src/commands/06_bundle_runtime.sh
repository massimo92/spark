# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
# Generic image-owned initialization and persistent model artifacts.

bundle_validate_runtime() {
  local manifest="$1"
  jq -e '
    def clean: type == "string" and ([explode[] | select(. < 32 or . == 127)] | length) == 0;
    def relative: clean and test("^[A-Za-z0-9_-][A-Za-z0-9._/-]*$") and (split("/") | all(. != ".." and . != "." and . != ""));
    def number: type == "number" and . >= 0;
    ((.model_source // {type:"huggingface"}) |
      .type == "huggingface" or (.type == "prepared" and (.path | relative)))
    and (if .model_source.type == "prepared" then .schema_version == 2 and .initializer != null else .initializer == null end)
    and (if .initializer != null then
      (.initializer.command | type == "array" and length > 0 and all(.[]; clean and length > 0))
      and (.initializer.version | clean and length > 0)
      and ((.initializer.memory_gb // 8) | number and . > 0)
      and ((.initializer.minimum_free_disk_gb // 0) | number)
      and ((.initializer.gpu // false) | type == "boolean")
      else true end)
    and ((.runtime.env // {}) | type == "object" and all(to_entries[];
      (.key | test("^[A-Z][A-Z0-9_]*$") and (test("(^|_)(TOKEN|PASSWORD|SECRET|KEY)($|_)") | not))
      and (.value | clean)))
    and ((.resources.weights_gb // 0) | number)
    and ((.resources.runtime_overhead_gb // 0) | number)
    and ((.resources.kv_estimator // "config") | . == "config" or . == "engine")
  ' "$manifest" >/dev/null 2>&1 || { err "Invalid bundle runtime/initializer configuration"; return 1; }
  local key
  while IFS= read -r key; do
    case "$key" in
      HOME|PATH|HF_HOME|HF_HUB_CACHE|SPARK_BUNDLE_*) err "Bundle cannot override managed environment: ${key}"; return 1 ;;
    esac
  done < <(jq -r '(.runtime.env // {}) | keys[]' "$manifest")
}

bundle_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}';
  else shasum -a 256 | awk '{print $1}'; fi
}

bundle_path_mode() {
  local mode
  mode=$(stat -c '%a' "$1" 2>/dev/null) || mode=$(stat -f '%Lp' "$1" 2>/dev/null) || return 1
  [[ "$mode" =~ ^[0-7]+$ ]] || return 1
  printf '%s\n' "$mode"
}

bundle_content_hash() {
  local dir="$1" file relative mode
  {
    printf 'spark-bundle-revision-v2\n'
    while IFS= read -r file; do
      relative="${file#"${dir}/"}"
      [[ "$file" != "$dir" ]] || relative='.'
      if [[ -L "$file" ]]; then
        printf 'link\t%s\t%s\n' "$relative" "$(readlink "$file")"
      else
        mode=$(bundle_path_mode "$file") || return 1
        if [[ -d "$file" ]]; then
          printf 'directory\t%s\t%s\n' "$relative" "$mode"
        else
          printf 'file\t%s\t%s\n' "$relative" "$mode"
          bundle_sha256 < "$file"
        fi
      fi
    done < <(find "$dir" \( -type f -o -type d -o -type l \) | LC_ALL=C sort)
  } | bundle_sha256
}

bundle_archive_revision() {
  local name="$1" source="$2" hash="$3" dest tmp
  dest="${BUNDLES_DIR}/revisions/${name}/${hash}"
  [[ -d "$dest" ]] && return 0
  mkdir -p "$(dirname "$dest")"
  tmp=$(mktemp -d "$(dirname "$dest")/.revision.XXXXXX")
  cp -pR "${source}/." "$tmp/" || { rm -rf "$tmp"; die "Cannot preserve bundle revision"; }
  if ! mv "$tmp" "$dest" 2>/dev/null; then
    rm -rf "$tmp"
    [[ -d "$dest" ]] || die "Cannot preserve bundle revision"
  fi
}

bundle_artifact_ready() {
  local root="$1" key="$2" path="$3"
  [[ -f "${root}/.spark-ready.json" && -f "${root}/${path}/config.json" ]] || return 1
  jq -e --arg key "$key" --arg path "$path" '.key == $key and .model_path == $path' \
    "${root}/.spark-ready.json" >/dev/null 2>&1
}

# Runs in a subshell so locks are released on failure without changing the
# launcher's traps. The image owns conversion/download logic and recovery.
bundle_execute_initializer() (
  local manifest="$1" image="$2" root="$3" key="$4" model_rel="$5" lock pid memory disk available tmp
  lock="${root}/.spark-init.lock"
  mkdir -p "$root" || die "Cannot create bundle artifact storage"
  if ! mkdir "$lock" 2>/dev/null; then
    pid=$(cat "${lock}/pid" 2>/dev/null || true)
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      die "Bundle initialization is already running (PID ${pid})" "Wait for that launch to finish."
    fi
    rm -rf "$lock"
    mkdir "$lock" || die "Cannot lock bundle initialization"
  fi
  printf '%s\n' "${BASHPID:-$$}" > "${lock}/pid"
  trap 'rm -rf "$lock"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  bundle_artifact_ready "$root" "$key" "$model_rel" && exit 0
  disk=$(jq -r '.initializer.minimum_free_disk_gb // 0' "$manifest")
  available=$(df -Pk "$root" | awk 'END {printf "%.2f", $4/1048576}')
  awk -v f="$available" -v n="$disk" 'BEGIN{exit !(f >= n)}' \
    || die "Initializer needs ${disk} GiB free disk; ${available} GiB available"
  memory=$(jq -r '.initializer.memory_gb // 8' "$manifest")
  if available=$(live_available_gb 2>/dev/null); then
    awk -v f="$available" -v n="$memory" 'BEGIN{exit !(f >= n)}' \
      || die "Initializer needs ${memory} GiB available RAM; ${available} GiB available"
  fi
  local -a command=()
  bundle_initializer_command "$manifest" "$image" "$root" "$key"
  info "Initializing bundle '${BUNDLE_ACTIVE_NAME}' (log: ${root}/initialize.log)"
  if ! "${command[@]}" 2>&1 | tee "${root}/initialize.log"; then
    die "Bundle initialization failed" "Inspect ${root}/initialize.log; a later run can resume."
  fi
  [[ -f "${root}/${model_rel}/config.json" ]] || die "Initializer did not produce ${model_rel}/config.json"
  jq -e 'type == "object"' "${root}/${model_rel}/config.json" >/dev/null \
    || die "Initializer produced an invalid model config"
  tmp=$(mktemp "${root}/.ready.XXXXXX")
  jq -n --arg key "$key" --arg path "$model_rel" --arg image "$image" \
    '{key:$key,model_path:$path,image:$image}' > "$tmp"
  mv "$tmp" "${root}/.spark-ready.json"
)

bundle_initializer_command() {
  local manifest="$1" image="$2" root="$3" key="$4" memory arg
  memory=$(jq -r '.initializer.memory_gb // 8' "$manifest")
  command=(docker run --rm --ipc=host --user "$(id -u):$(id -g)" --workdir /tmp
    --memory "$(awk -v m="$memory" 'BEGIN{printf "%dm", m*1024}')"
    --memory-swap "$(awk -v m="$memory" 'BEGIN{printf "%dm", m*1024}')"
    -e HOME=/tmp -e USER=spark -e LOGNAME=spark
    -e HF_HOME=/tmp/huggingface -e HF_HUB_CACHE=/tmp/huggingface/hub
    -e "SPARK_BUNDLE_DIR=/tmp/huggingface/${root#"${HF_CACHE_DIR}/"}"
    -e "SPARK_BUNDLE_KEY=${key}" -v "${HF_CACHE_DIR}:/tmp/huggingface")
  [[ "$(jq -r '.initializer.gpu // false' "$manifest")" != "true" ]] || command+=(--gpus all)
  local -a initializer=()
  while IFS= read -r arg; do initializer+=("$arg"); done < <(jq -r '.initializer.command[]' "$manifest")
  command+=(--entrypoint "${initializer[0]}" "$image")
  [[ ${#initializer[@]} -le 1 ]] || command+=("${initializer[@]:1}")
}

bundle_initialize() {
  local manifest="$1" image="$2" dry="$3" no_pull="$4" kind path root key
  BUNDLE_TARGET_REVISION=$(jq -r '.defaults.target_model.revision' "$manifest")
  BUNDLE_KV_ESTIMATOR=$(jq -r '.resources.kv_estimator // "config"' "$manifest")
  BUNDLE_WEIGHTS_GB=$(jq -r '.resources.weights_gb // empty' "$manifest")
  BUNDLE_RUNTIME_OVERHEAD_GB=$(jq -r '.resources.runtime_overhead_gb // 0' "$manifest")
  kind=$(jq -r '.model_source.type // "huggingface"' "$manifest")
  [[ "$kind" == "prepared" ]] || return 0
  path=$(jq -r '.model_source.path' "$manifest")
  key=$(jq -Sc --arg image "$image" '{image:$image,target:.defaults.target_model,source:.model_source,initializer:.initializer}' "$manifest" | bundle_sha256)
  root="${HF_CACHE_DIR}/bundles/${BUNDLE_ACTIVE_NAME}/${key}"
  BUNDLE_ARTIFACT_KEY="$key"
  BUNDLE_MODEL_PATH="${root}/${path}"
  BUNDLE_MODEL_LOAD_PATH="/tmp/huggingface/bundles/${BUNDLE_ACTIVE_NAME}/${key}/${path}"
  ALIAS_VLLM_ENV_JSON=$(jq -c --arg dir "/tmp/huggingface/bundles/${BUNDLE_ACTIVE_NAME}/${key}" \
    'with_entries(.value |= gsub("\\{artifact_dir\\}"; $dir))' <<<"$ALIAS_VLLM_ENV_JSON")
  if bundle_artifact_ready "$root" "$key" "$path"; then
    info "Reusing prepared model: ${BUNDLE_MODEL_PATH}"
    return 0
  fi
  if [[ "$dry" == "1" ]]; then
    local -a command=()
    bundle_initializer_command "$manifest" "$image" "$root" "$key"
    printf '  Initialization required; would execute:\n'
    shell_join "${command[@]}"
    BUNDLE_INITIALIZATION_PENDING=1
    return 0
  fi
  [[ "$no_pull" != "1" ]] || die "Prepared model is missing and --no-pull prevents initialization"
  bundle_execute_initializer "$manifest" "$image" "$root" "$key" "$path" || exit 1
}

# Observations come from the engine, not from the model's theoretical KV
# formula. Missing/changed log formats produce null instead of invented values.
record_engine_memory() {
  local cname="$1" started logs kv tokens file tmp
  started=$(docker inspect -f '{{.State.StartedAt}}' "$cname" 2>/dev/null || true)
  [[ -n "$started" ]] || return 0
  logs=$(docker logs --tail 4000 "$cname" 2>&1 || true)
  kv=$(awk '/Available KV cache memory:/ {s=$0; sub(/^.*Available KV cache memory:[[:space:]]*/, "", s); sub(/[[:space:]]*GiB.*$/, "", s); if(s ~ /^[0-9]+([.][0-9]+)?$/) v=s} END{print v}' <<<"$logs")
  tokens=$(awk '/GPU KV cache size:/ {s=$0; sub(/^.*GPU KV cache size:[[:space:]]*/, "", s); sub(/[[:space:]]*tokens.*$/, "", s); gsub(/,/, "", s); if(s ~ /^[0-9]+$/) v=s} END{print v}' <<<"$logs")
  [[ -n "$kv" || -n "$tokens" ]] || return 0
  mkdir -p "${SPARK_CONFIG_DIR}/observations"
  file="${SPARK_CONFIG_DIR}/observations/${cname}.json"
  tmp=$(mktemp "${file}.XXXXXX")
  jq -n --arg started "$started" --arg kv "$kv" --arg tokens "$tokens" \
    '{started_at:$started,source:"vllm-startup-log",kv_gib:(if $kv == "" then null else ($kv|tonumber) end),kv_tokens:(if $tokens == "" then null else ($tokens|tonumber) end)}' > "$tmp"
  mv "$tmp" "$file"
}

engine_memory_json() {
  local cname="$1" started file
  file="${SPARK_CONFIG_DIR}/observations/${cname}.json"
  started=$(docker inspect -f '{{.State.StartedAt}}' "$cname" 2>/dev/null || true)
  if [[ -n "$started" ]] && ! jq -e --arg s "$started" '.started_at == $s' "$file" >/dev/null 2>&1; then
    record_engine_memory "$cname"
  fi
  if [[ -n "$started" ]] && jq -e --arg s "$started" '.started_at == $s' "$file" >/dev/null 2>&1; then
    jq -c . "$file"
  else printf 'null\n'; fi
}
