# --- vLLM bundles ---

is_safe_bundle_name() {
  [[ "${1:-}" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]
}

bundle_decode_base64() {
  if printf '' | base64 --decode >/dev/null 2>&1; then
    base64 --decode
  else
    base64 -D
  fi
}

# Built-ins live inside the single-file Spark release. Refresh the stable
# directory once per process so an updated release immediately replaces them.
bundle_materialize_builtins() {
  [[ "${BUNDLE_BUILTINS_READY:-0}" == "1" ]] && return 0
  local root="${BUNDLES_DIR}/builtin" rel encoded target tmp
  mkdir -p "$root" || die "Cannot create bundle store"
  while IFS=$'\t' read -r rel encoded; do
    [[ -n "$rel" ]] || continue
    [[ "$rel" =~ ^[A-Za-z0-9._/-]+$ && "$rel" != /* && "$rel" != *..* ]] \
      || die "Unsafe built-in bundle path: ${rel}"
    target="${root}/${rel}"
    mkdir -p "$(dirname "$target")" || die "Cannot extract bundle asset"
    tmp=$(mktemp "${target}.tmp.XXXXXX") || die "Cannot create bundle asset"
    printf '%s' "$encoded" | bundle_decode_base64 > "$tmp" \
      || { rm -f "$tmp"; die "Cannot decode bundle asset: ${rel}"; }
    mv "$tmp" "$target" || { rm -f "$tmp"; die "Cannot install bundle asset: ${rel}"; }
  done < <(spark_builtin_bundle_assets)
  BUNDLE_BUILTINS_READY=1
}

bundle_vllm_value() {
  local vllm_json="$1" flag="$2"
  jq -r --arg flag "$flag" '
    . as $args | range(0; length - 1) as $i | select($args[$i] == $flag) | $args[$i + 1]
  ' <<<"$vllm_json" | tail -1
}

bundle_core_flag_reserved() {
  case "${1:-}" in
    mem|no-mem-limit|max-len|kv-cache-dtype|max-num-seqs|mtp|no-mtp|enforce-eager|no-enforce-eager|port|tools|text-only|no-reasoning|no-pull|dry-run|explain|no-wait|tail|force|regen-profile|help)
      return 0 ;;
    *) return 1 ;;
  esac
}

bundle_detect_run_ref() {
  local arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --mem|--max-len|--kv-cache-dtype|--max-num-seqs|--port)
        shift 2 2>/dev/null || return 1 ;;
      --no-mem-limit|--mtp|--no-mtp|--enforce-eager|--no-enforce-eager|--tools|--text-only|--no-reasoning|--no-pull|--dry-run|--explain|--no-wait|--tail|--force|--regen-profile|-h|--help)
        shift ;;
      --*)
        [[ $# -ge 2 ]] || return 1
        shift 2 ;;
      *)
        printf '%s\n' "$arg"
        return 0 ;;
    esac
  done
  return 1
}

bundle_option_exists_in() {
  local manifest="$1" key="$2"
  jq -e --arg key "$key" '(.options // {})[$key] != null' "$manifest" >/dev/null 2>&1
}

bundle_option_defaults_json() {
  jq -c 'reduce ((.options // {}) | to_entries[]) as $o ({}; .[$o.key] = $o.value.default)' "$1"
}

bundle_set_option_value() {
  local manifest="$1" key="$2" raw="$3" type normalized
  type=$(jq -r --arg key "$key" '.options[$key].type // empty' "$manifest")
  case "$type" in
    boolean)
      case "$raw" in
        true|1|on) normalized=true ;;
        false|0|off) normalized=false ;;
        *) die "Invalid --${key} value: ${raw}" "Expected true or false." ;;
      esac
      BUNDLE_OPTION_VALUES_JSON=$(jq -c --arg key "$key" --argjson value "$normalized" '.[$key] = $value' <<<"$BUNDLE_OPTION_VALUES_JSON")
      ;;
    integer)
      [[ "$raw" =~ ^-?[0-9]+$ ]] || die "Invalid --${key} value: ${raw}" "Expected an integer."
      BUNDLE_OPTION_VALUES_JSON=$(jq -c --arg key "$key" --argjson value "$raw" '.[$key] = $value' <<<"$BUNDLE_OPTION_VALUES_JSON")
      ;;
    string)
      [[ ${#raw} -le 1024 && "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || die "Invalid --${key} value"
      BUNDLE_OPTION_VALUES_JSON=$(jq -c --arg key "$key" --arg value "$raw" '.[$key] = $value' <<<"$BUNDLE_OPTION_VALUES_JSON")
      ;;
    *) die "Bundle option --${key} has an unsupported type" ;;
  esac
}

bundle_options_env_json() {
  local manifest="$1" values="$2"
  jq -c --argjson values "$values" '
    reduce ((.options // {}) | to_entries[]) as $o ({};
      .[$o.value.env] =
        (if $o.value.type == "boolean" then (if $values[$o.key] then "1" else "0" end)
         else ($values[$o.key] | tostring) end))
  ' "$manifest"
}

bundle_vllm_remove_flag_json() {
  local vllm_json="$1" flag="$2"
  jq -ce --arg flag "$flag" '
    . as $args
    | reduce range(0; $args | length) as $i
        ({out: [], skip: false};
          if .skip then .skip = false
          elif $args[$i] == $flag then .skip = true
          elif ($args[$i] | startswith($flag + "=")) then .
          else .out += [$args[$i]]
          end)
    | .out
  ' <<<"$vllm_json"
}

bundle_vllm_remove_switch_json() {
  jq -ce --arg flag "$2" '[.[] | select(. != $flag)]' <<<"$1"
}

bundle_vllm_add_switch_json() {
  local vllm_json="$1" flag="$2"
  jq -ce --arg flag "$flag" 'if index($flag) == null then . + [$flag] else . end' <<<"$vllm_json"
}

bundle_dockerfile_instructions() {
  awk '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (instruction == "") instruction = line
      else instruction = instruction " " line
      if (line ~ /\\[[:space:]]*$/) {
        sub(/\\[[:space:]]*$/, "", instruction)
        next
      }
      print instruction
      instruction = ""
    }
    END { if (instruction != "") print instruction }
  ' "$1"
}

bundle_validate_dir() {
  local dir="$1" manifest dockerfile docker_instructions name vllm_json target target_rev drafter drafter_rev tokens spec revision file patch_name actual key type default from
  [[ -d "$dir" ]] || { err "Bundle directory not found: ${dir}"; return 1; }
  manifest="${dir}/bundle.json"
  [[ -f "$manifest" ]] || { err "Missing bundle.json in ${dir}"; return 1; }
  [[ -f "${dir}/Dockerfile" ]] || { err "Missing Dockerfile in ${dir}"; return 1; }
  [[ -f "${dir}/README.md" ]] || { err "Missing README.md in ${dir}"; return 1; }
  if find "$dir" -type l | grep -q .; then
    err "Bundle cannot contain symbolic links: ${dir}"
    return 1
  fi
  if find "$dir" -type f | sed "s#^${dir}/##" | grep -qvE '^[A-Za-z0-9._/-]+$'; then
    err "Bundle contains an unsafe filename"
    return 1
  fi
  jq -e '
    type == "object"
    and .schema_version == 1
    and (.name | type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$"))
    and (.description | type == "string" and length > 0)
    and (.defaults | type == "object")
    and (.defaults.target_model.id | type == "string" and length > 0)
    and (.defaults.target_model.revision | type == "string" and test("^[A-Fa-f0-9]{7,64}$"))
    and (.defaults.draft_model.id | type == "string" and length > 0)
    and (.defaults.draft_model.revision | type == "string" and test("^[A-Fa-f0-9]{7,64}$"))
    and (.defaults.speculative_tokens | type == "number" and floor == . and . > 0)
    and (.defaults.vllm_args | type == "array" and length >= 3 and all(.[]; type == "string"))
    and (.defaults.vllm_args[0] == "vllm")
    and (.defaults.vllm_args[1] == "serve")
    and (.defaults.vllm_args[2] == .defaults.target_model.id)
    and ((.options // {}) | type == "object")
    and all((.options // {}) | to_entries[];
      (.key | test("^[a-z][a-z0-9-]*$"))
      and (.value | type == "object")
      and (.value.description | type == "string" and length > 0)
      and (.value.type == "boolean" or .value.type == "integer" or .value.type == "string")
      and (.value.env | type == "string" and test("^[A-Z][A-Z0-9_]*$"))
      and (if .value.type == "boolean" then (.value.default | type == "boolean")
           elif .value.type == "integer" then (.value.default | type == "number" and floor == .)
           else (.value.default | type == "string") end))
    and (.patches | type == "array" and (map(.file) | unique | length) == length)
    and all(.patches[];
      (.file | type == "string" and test("^patches/[A-Za-z0-9._/-]+[.]patch$") and (contains("..") | not))
      and (.description | type == "string" and length > 0))
  ' "$manifest" >/dev/null 2>&1 || { err "Invalid bundle.json: ${manifest}"; return 1; }

  name=$(jq -r '.name' "$manifest")
  dockerfile="${dir}/Dockerfile"
  docker_instructions=$(bundle_dockerfile_instructions "$dockerfile")
  from=$(awk 'toupper($1) == "FROM" {print $2; exit}' <<<"$docker_instructions")
  [[ "$from" == *@sha256:* || ( "$from" == *:* && "$from" != *:latest ) ]] \
    || { err "Dockerfile FROM must use a versioned base image"; return 1; }

  while IFS= read -r file; do
    [[ -f "${dir}/${file}" ]] || { err "Missing declared patch: ${file}"; return 1; }
    awk -v file="$file" '
      (toupper($1) == "COPY" || toupper($1) == "ADD") && index($0, file) { found=1 }
      END { exit !found }
    ' <<<"$docker_instructions" \
      || { err "Declared patch is not copied explicitly by Dockerfile: ${file}"; return 1; }
    patch_name="${file##*/}"
    awk -v file="$patch_name" '
      toupper($1) == "RUN" && index($0, file) &&
        $0 ~ /(^|[[:space:];])(patch|git[[:space:]]+apply)([[:space:];]|$)/ { found=1 }
      END { exit !found }
    ' <<<"$docker_instructions" \
      || { err "Declared patch is not applied by Dockerfile: ${file}"; return 1; }
  done < <(jq -r '.patches[].file' "$manifest")

  while IFS= read -r actual; do
    actual="${actual#"${dir}/"}"
    jq -e --arg file "$actual" 'any(.patches[]; .file == $file)' "$manifest" >/dev/null 2>&1 \
      || { err "Patch file is not declared in bundle.json: ${actual}"; return 1; }
  done < <(find "${dir}/patches" -type f -name '*.patch' | LC_ALL=C sort)

  while IFS=$'\t' read -r key type default; do
    bundle_core_flag_reserved "$key" && { err "Bundle option conflicts with spark run: --${key}"; return 1; }
    [[ "$key" != *secret* && "$key" != *token* && "$key" != *password* && "$key" != *key* ]] \
      || { err "Bundle options cannot carry secrets: ${key}"; return 1; }
  done < <(jq -r '(.options // {}) | to_entries[] | [.key, .value.type, (.value.default|tostring)] | @tsv' "$manifest")

  vllm_json=$(jq -c '.defaults.vllm_args' "$manifest")
  target=$(jq -r '.defaults.target_model.id' "$manifest")
  target_rev=$(jq -r '.defaults.target_model.revision' "$manifest")
  drafter=$(jq -r '.defaults.draft_model.id' "$manifest")
  drafter_rev=$(jq -r '.defaults.draft_model.revision' "$manifest")
  tokens=$(jq -r '.defaults.speculative_tokens' "$manifest")
  revision=$(bundle_vllm_value "$vllm_json" --revision)
  [[ "$revision" == "$target_rev" ]] || { err "vLLM --revision does not match target revision"; return 1; }
  spec=$(bundle_vllm_value "$vllm_json" --speculative-config)
  jq -e --arg model "$drafter" --arg revision "$drafter_rev" --argjson tokens "$tokens" '
    .model == $model and .revision == $revision and .num_speculative_tokens == $tokens
  ' <<<"$spec" >/dev/null 2>&1 || { err "Speculative config does not match bundle drafter/defaults"; return 1; }
  is_safe_bundle_name "$name"
}

bundle_resolve() {
  local name="$1" imported builtin
  BUNDLE_PATH="" BUNDLE_SOURCE=""
  is_safe_bundle_name "$name" || return 1
  bundle_materialize_builtins
  imported="${BUNDLES_DIR}/imported/${name}"
  builtin="${BUNDLES_DIR}/builtin/vllm/${name}"
  if [[ -d "$imported" ]]; then
    BUNDLE_PATH="$imported" BUNDLE_SOURCE="imported"
    return 0
  fi
  if [[ -d "$builtin" ]]; then
    BUNDLE_PATH="$builtin" BUNDLE_SOURCE="built-in"
    return 0
  fi
  return 1
}

bundle_exists() {
  bundle_resolve "$1" >/dev/null 2>&1
}

bundle_image_tag() {
  printf 'spark/bundle-%s:latest\n' "$1"
}

bundle_image_id() {
  docker image inspect --format '{{.Id}}' "$1" 2>/dev/null | head -1
}

bundle_image_entrypoint() {
  local entry
  entry=$(docker image inspect --format '{{json .Config.Entrypoint}}' "$1" 2>/dev/null || true)
  jq -e 'type == "array" and ((.[0] // "") | split("/")[-1]) == "vllm" and .[1] == "serve"' \
    >/dev/null 2>&1 <<<"$entry"
}

# Always invoke Docker's build. Docker checks the context and reuses cached
# layers when the Dockerfile and every copied patch are unchanged.
bundle_build_for_run() {
  local name="$1" dry="${2:-0}" tag id
  tag=$(bundle_image_tag "$name")
  BUNDLE_BUILT_IMAGE="$tag"
  if [[ "$dry" == "1" ]]; then
    docker image inspect "$tag" >/dev/null 2>&1 \
      || warn "Bundle image is not built; a real run will build ${tag}."
    return 0
  fi
  info "Preparing bundle '${name}'"
  docker build --pull=false \
    --label "spark.bundle.name=${name}" \
    -t "$tag" "$BUNDLE_PATH" || die "Could not build bundle '${name}'"
  id=$(bundle_image_id "$tag")
  [[ "$id" =~ ^sha256:[a-fA-F0-9]{64}$ ]] || die "Built bundle image has no Docker ID"
}

bundle_prepare_run() {
  local name="$1" path="$2" manifest vllm_json image id
  local requested_mem="$mem" requested_len="$max_len" requested_seqs="$max_num_seqs" requested_port="$port" requested_kv="$kv_dtype"
  manifest="${path}/bundle.json"
  bundle_validate_dir "$path" || die "Bundle '${name}' is invalid"
  model=$(jq -r '.defaults.target_model.id' "$manifest")
  vllm_json=$(jq -c '.defaults.vllm_args' "$manifest")

  mem="${requested_mem:-$(bundle_vllm_value "$vllm_json" --gpu-memory-utilization)}"
  max_len="${requested_len:-$(bundle_vllm_value "$vllm_json" --max-model-len)}"
  max_num_seqs="${requested_seqs:-$(bundle_vllm_value "$vllm_json" --max-num-seqs)}"
  port="${requested_port:-$(bundle_vllm_value "$vllm_json" --port)}"
  kv_dtype="${requested_kv:-$(bundle_vllm_value "$vllm_json" --kv-cache-dtype)}"
  kv_dtype="${kv_dtype:-auto}"

  [[ -z "$requested_mem" ]] || vllm_json=$(alias_vllm_set_value_json "$vllm_json" --gpu-memory-utilization "$mem")
  [[ -z "$requested_len" ]] || vllm_json=$(alias_vllm_set_value_json "$vllm_json" --max-model-len "$max_len")
  [[ -z "$requested_seqs" ]] || vllm_json=$(alias_vllm_set_value_json "$vllm_json" --max-num-seqs "$max_num_seqs")
  [[ -z "$requested_port" ]] || vllm_json=$(alias_vllm_set_value_json "$vllm_json" --port "$port")
  if [[ -n "$requested_kv" ]]; then
    vllm_json=$(bundle_vllm_remove_flag_json "$vllm_json" --kv-cache-dtype)
    [[ "$requested_kv" == "auto" ]] || vllm_json=$(jq -ce --arg value "$requested_kv" '. + ["--kv-cache-dtype", $value]' <<<"$vllm_json")
  fi
  case "$enforce_eager_flag" in
    1) vllm_json=$(bundle_vllm_add_switch_json "$vllm_json" --enforce-eager) ;;
    0) vllm_json=$(bundle_vllm_remove_switch_json "$vllm_json" --enforce-eager) ;;
  esac
  [[ "$no_reasoning" != "1" ]] || vllm_json=$(bundle_vllm_remove_flag_json "$vllm_json" --reasoning-parser)

  BUNDLE_PATH="$path"
  bundle_build_for_run "$name" "$dry_run"
  image="$BUNDLE_BUILT_IMAGE"
  id=$(bundle_image_id "$image" || true)
  [[ -n "$id" ]] || id="$image"
  ALIAS_VLLM_ARGS_JSON="$vllm_json"
  ALIAS_VLLM_IMAGE="$image"
  ALIAS_VLLM_IMAGE_ID="$id"
  if bundle_image_entrypoint "$image"; then ALIAS_VLLM_ENTRYPOINT=true; else ALIAS_VLLM_ENTRYPOINT=false; fi
  ALIAS_VLLM_ENV_JSON=$(bundle_options_env_json "$manifest" "$BUNDLE_OPTION_VALUES_JSON")
  BUNDLE_ACTIVE=1
  BUNDLE_ACTIVE_NAME="$name"
  BUNDLE_ACTIVE_OPTIONS_JSON="$BUNDLE_OPTION_VALUES_JSON"
  MTP_ENABLED=0
  mtp_flag=0
}

bundle_collect() {
  local dir name
  BUNDLE_LIST_NAMES=() BUNDLE_LIST_PATHS=() BUNDLE_LIST_SOURCES=()
  bundle_materialize_builtins
  if [[ -d "${BUNDLES_DIR}/builtin/vllm" ]]; then
    while IFS= read -r dir; do
      [[ -d "$dir" ]] || continue
      name=$(basename "$dir")
      BUNDLE_LIST_NAMES+=("$name"); BUNDLE_LIST_PATHS+=("$dir"); BUNDLE_LIST_SOURCES+=("built-in")
    done < <(find "${BUNDLES_DIR}/builtin/vllm" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
  fi
  if [[ -d "${BUNDLES_DIR}/imported" ]]; then
    while IFS= read -r dir; do
      [[ -d "$dir" ]] || continue
      name=$(basename "$dir")
      BUNDLE_LIST_NAMES+=("$name"); BUNDLE_LIST_PATHS+=("$dir"); BUNDLE_LIST_SOURCES+=("imported")
    done < <(find "${BUNDLES_DIR}/imported" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
  fi
}

cmd_bundle_list() {
  local json="${1:-0}" i name path source target rows='[]'
  bundle_collect
  if [[ "$json" == "1" ]]; then
    for i in "${!BUNDLE_LIST_NAMES[@]}"; do
      name="${BUNDLE_LIST_NAMES[$i]}"; path="${BUNDLE_LIST_PATHS[$i]}"; source="${BUNDLE_LIST_SOURCES[$i]}"
      target=$(jq -r '.defaults.target_model.id' "${path}/bundle.json")
      rows=$(jq -c --arg name "$name" --arg target "$target" --arg source "$source" '. + [{name:$name,target:$target,source:$source}]' <<<"$rows")
    done
    printf '%s\n' "$rows" | jq .
    return 0
  fi
  printf '\n  NAME\tSOURCE\tTARGET\n'
  for i in "${!BUNDLE_LIST_NAMES[@]}"; do
    name="${BUNDLE_LIST_NAMES[$i]}"; path="${BUNDLE_LIST_PATHS[$i]}"; source="${BUNDLE_LIST_SOURCES[$i]}"
    target=$(jq -r '.defaults.target_model.id' "${path}/bundle.json")
    printf '  %s\t%s\t%s\n' "$name" "$source" "$target"
  done
  [[ ${#BUNDLE_LIST_NAMES[@]} -gt 0 ]] || printf '  No bundles available.\n'
  printf '\n'
}

cmd_bundle_show() {
  local name="$1" json="${2:-0}" manifest
  bundle_resolve "$name" || die "Bundle '${name}' does not exist"
  manifest="${BUNDLE_PATH}/bundle.json"
  if [[ "$json" == "1" ]]; then jq . "$manifest"; return 0; fi
  printf '\n  %s%s%s\n\n' "$BOLD" "$name" "$NC"
  printf '  %s\n\n' "$(jq -r '.description' "$manifest")"
  printf '  Target:   %s\n' "$(jq -r '.defaults.target_model.id' "$manifest")"
  printf '  Drafter:  %s\n' "$(jq -r '.defaults.draft_model.id' "$manifest")"
  printf '  Tokens:   %s\n' "$(jq -r '.defaults.speculative_tokens' "$manifest")"
  printf '  Source:   %s\n' "$BUNDLE_SOURCE"
  printf '\n  Options:\n'
  jq -r '(.options // {}) | to_entries[] | "    --\(.key) <\(.value.type)>  default=\(.value.default)\n      \(.value.description)"' "$manifest"
  printf '\n  Patches:\n'
  jq -r '.patches[] | "    - \(.file): \(.description)"' "$manifest"
  printf '\n'
}

cmd_bundle_init() {
  local name="$1" dir="$2"
  is_safe_bundle_name "$name" || die "Invalid bundle name: ${name}" "Use lowercase letters, numbers, dots, underscores, or hyphens."
  [[ ! -e "$dir" ]] || die "Destination already exists: ${dir}"
  mkdir -p "${dir}/patches" || die "Cannot create bundle directory"
  printf '%s\n' '{' \
    '  "schema_version": 1,' \
    "  \"name\": \"${name}\"," \
    '  "description": "Describe why this bundle exists.",' \
    '  "defaults": {' \
    '    "target_model": {"id": "org/target", "revision": "0000000"},' \
    '    "draft_model": {"id": "org/drafter", "revision": "0000000"},' \
    '    "speculative_tokens": 1,' \
    '    "vllm_args": ["vllm", "serve", "org/target", "--revision", "0000000", "--speculative-config", "{\"method\":\"draft_model\",\"num_speculative_tokens\":1,\"model\":\"org/drafter\",\"revision\":\"0000000\"}"]' \
    '  },' \
    '  "options": {},' \
    '  "patches": []' \
    '}' > "${dir}/bundle.json"
  printf '%s\n' 'FROM vllm/vllm-openai:v0.0.0' > "${dir}/Dockerfile"
  printf '# %s\n\nDescribe the tested configuration and results.\n' "$name" > "${dir}/README.md"
  info "Created bundle template: ${dir}"
}

cmd_bundle_import() {
  local source="$1" force="${2:-0}" name dest tmp
  source="$(cd "$source" 2>/dev/null && pwd)" || die "Bundle directory not found: ${source}"
  bundle_validate_dir "$source" || die "Bundle validation failed"
  name=$(jq -r '.name' "${source}/bundle.json")
  bundle_materialize_builtins
  [[ ! -d "${BUNDLES_DIR}/builtin/vllm/${name}" ]] || die "Cannot import over built-in bundle '${name}'"
  dest="${BUNDLES_DIR}/imported/${name}"
  [[ "$source" != "$dest" ]] || die "Bundle is already imported: ${name}"
  [[ ! -e "$dest" || "$force" == "1" ]] || die "Bundle '${name}' is already imported" "Use --force to replace it."
  mkdir -p "${BUNDLES_DIR}/imported" || die "Cannot create imported bundle store"
  tmp=$(mktemp -d "${BUNDLES_DIR}/imported/.import.XXXXXX") || die "Cannot create import directory"
  cp -R "${source}/." "$tmp/" || { rm -rf "$tmp"; die "Cannot copy bundle"; }
  rm -rf "$dest"
  mv "$tmp" "$dest" || { rm -rf "$tmp"; die "Cannot install bundle"; }
  info "Imported '${name}'"
}

cmd_bundle_remove() {
  local name="$1" path
  path="${BUNDLES_DIR}/imported/${name}"
  is_safe_bundle_name "$name" || die "Invalid bundle name: ${name}"
  [[ -d "$path" ]] || die "Imported bundle '${name}' does not exist" "Built-in bundles cannot be removed."
  confirm "Remove imported bundle '${name}'?" || { warn "Cancelled"; return 0; }
  rm -rf "$path"
  info "Removed bundle '${name}'"
}

bundle_repo_root() {
  local candidate root
  for candidate in "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" "$PWD"; do
    root=$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null || true)
    [[ -n "$root" ]] || continue
    if [[ -f "${root}/scripts/build-single-file.sh" && -d "${root}/bundles/vllm" && -d "${root}/src" ]]; then
      printf '%s\n' "$root"
      return 0
    fi
  done
  return 1
}

cmd_bundle_sync() {
  local check="${1:-0}" root dir file rel name count=0
  root=$(bundle_repo_root) || die "Cannot find the Spark source repository" \
    "Run this command from the Spark repository."
  while IFS= read -r dir; do
    [[ -d "$dir" ]] || continue
    bundle_validate_dir "$dir" || die "Built-in bundle validation failed: $(basename "$dir")"
    name=$(jq -r '.name' "${dir}/bundle.json")
    [[ "$(basename "$dir")" == "$name" ]] \
      || die "Built-in bundle folder must match its name: ${name}"
    while IFS= read -r file; do
      rel="${file#"${root}/"}"
      git -C "$root" ls-files --error-unmatch "$rel" >/dev/null 2>&1 \
        || die "Bundle asset is not tracked by Git: ${rel}" "Run: git add ${rel}"
    done < <(find "$dir" -type f | LC_ALL=C sort)
    count=$((count + 1))
  done < <(find "${root}/bundles/vllm" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
  [[ "$count" -gt 0 ]] || die "No built-in bundles found"

  if [[ "$check" == "1" ]]; then
    "${root}/scripts/build-single-file.sh" --check \
      || die "Built-in bundles are not synchronized" "Run: spark bundle sync"
    info "Built-in bundles are synchronized (${count})"
  else
    "${root}/scripts/build-single-file.sh" || die "Could not synchronize built-in bundles"
    info "Synchronized ${count} built-in bundle(s) into spark"
  fi
}

BUNDLE_SUBMIT_TMP_DIR=""

bundle_submit_cleanup() {
  local path="${BUNDLE_SUBMIT_TMP_DIR:-}"
  [[ -n "$path" && -d "$path" && "$(basename "$path")" == spark-bundle-submit.* ]] || return 0
  rm -rf -- "$path"
  BUNDLE_SUBMIT_TMP_DIR=""
}

bundle_submit_source() {
  local ref="$1"
  BUNDLE_SUBMIT_SOURCE=""
  if [[ -d "$ref" ]]; then
    BUNDLE_SUBMIT_SOURCE=$(cd "$ref" 2>/dev/null && pwd) \
      || die "Bundle directory not found: ${ref}"
    return 0
  fi
  bundle_resolve "$ref" || die "Bundle '${ref}' does not exist" \
    "Pass an installed bundle name or a bundle directory."
  BUNDLE_SUBMIT_SOURCE="$BUNDLE_PATH"
}

cmd_bundle_submit() {
  local ref="$1" dry="${2:-0}" draft="${3:-0}"
  local source manifest name target drafter tokens target_repo repo_url base cache_root checkout dest
  local change verb title branch login permission repo_name push_remote head_ref fork_parent body pr_url
  local -a pr_args=()

  command -v git >/dev/null 2>&1 || die "git is required to submit a bundle"
  bundle_submit_source "$ref"
  source="$BUNDLE_SUBMIT_SOURCE"
  bundle_validate_dir "$source" || die "Bundle validation failed"
  manifest="${source}/bundle.json"
  name=$(jq -r '.name' "$manifest")
  target=$(jq -r '.defaults.target_model.id' "$manifest")
  drafter=$(jq -r '.defaults.draft_model.id' "$manifest")
  tokens=$(jq -r '.defaults.speculative_tokens' "$manifest")

  target_repo="${SPARK_BUNDLE_SUBMIT_GITHUB_REPO:-$GITHUB_REPO}"
  base="${SPARK_BUNDLE_SUBMIT_BASE:-main}"
  repo_url="${SPARK_BUNDLE_SUBMIT_REPO_URL:-https://github.com/${target_repo}.git}"
  cache_root="${SPARK_BUNDLE_SUBMIT_TMP_ROOT:-${TMPDIR:-/tmp}}"
  mkdir -p "$cache_root" || die "Cannot create bundle submission workspace"
  BUNDLE_SUBMIT_TMP_DIR=$(mktemp -d "${cache_root%/}/spark-bundle-submit.XXXXXX") \
    || die "Cannot create bundle submission workspace"
  trap bundle_submit_cleanup EXIT
  checkout="${BUNDLE_SUBMIT_TMP_DIR}/spark"

  info "Valid bundle '${name}'"
  info "Preparing an isolated Spark checkout"
  git clone --quiet --depth 1 --branch "$base" "$repo_url" "$checkout" \
    || die "Could not clone ${target_repo}" "Check network access and the target repository."
  [[ -x "${checkout}/scripts/build-single-file.sh" && -d "${checkout}/bundles/vllm" ]] \
    || die "Submission repository does not have the expected Spark layout"

  dest="${checkout}/bundles/vllm/${name}"
  change="new"
  if [[ -d "$dest" ]]; then
    change="update"
    rm -rf -- "$dest"
  fi
  mkdir -p "$(dirname "$dest")" || die "Cannot prepare bundle destination"
  cp -R "${source}/." "$dest/" || die "Cannot copy bundle into submission checkout"
  bundle_validate_dir "$dest" || die "Copied bundle failed validation"

  while IFS= read -r dest; do
    [[ -d "$dest" ]] || continue
    bundle_validate_dir "$dest" || die "Repository bundle validation failed: $(basename "$dest")"
  done < <(find "${checkout}/bundles/vllm" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)

  "${checkout}/scripts/build-single-file.sh" >/dev/null \
    || die "Could not synchronize the bundle catalog"
  git -C "$checkout" add -- "bundles/vllm/${name}" spark \
    || die "Could not stage the bundle submission"
  git -C "$checkout" diff --cached --quiet \
    && die "Bundle '${name}' matches ${target_repo}:${base}" "There is nothing to submit."

  printf '\n  %sBundle submission%s\n\n' "$BOLD" "$NC"
  printf '  Name:     %s\n' "$name"
  printf '  Change:   %s\n' "$change"
  printf '  Target:   %s\n' "$target"
  printf '  Drafter:  %s\n' "$drafter"
  printf '  Tokens:   %s\n\n' "$tokens"
  git -C "$checkout" diff --cached --stat
  printf '\n  Bundle diff:\n\n'
  git -C "$checkout" diff --cached -- "bundles/vllm/${name}"
  printf '\n'

  if [[ "$dry" == "1" ]]; then
    info "Dry run complete; no branch, push, or PR was created"
    bundle_submit_cleanup
    trap - EXIT
    return 0
  fi

  command -v gh >/dev/null 2>&1 || die "GitHub CLI is required to open the PR" \
    "Install gh, then run: gh auth login"
  is_interactive || die "Publishing a bundle requires confirmation" \
    "Review first with: spark bundle submit ${ref} --dry-run"
  confirm "Open a ${change} bundle PR for '${name}'?" || {
    warn "Cancelled"
    bundle_submit_cleanup
    trap - EXIT
    return 0
  }
  GH_PROMPT_DISABLED=1 gh auth status --hostname github.com >/dev/null 2>&1 \
    || die "GitHub CLI is not authenticated" "Run: gh auth login"
  login=$(GH_PROMPT_DISABLED=1 gh api user --jq .login 2>/dev/null) \
    || die "Could not determine the authenticated GitHub user"
  [[ "$login" =~ ^[A-Za-z0-9-]+$ ]] || die "GitHub returned an invalid login"
  permission=$(GH_PROMPT_DISABLED=1 gh repo view "$target_repo" \
    --json viewerPermission --jq .viewerPermission 2>/dev/null) \
    || die "Could not inspect GitHub permissions for ${target_repo}"

  [[ "$change" == "new" ]] && verb="add" || verb="update"
  title="bundle: ${verb} ${name}"
  branch="spark-bundle/${name}-$(date -u +%Y%m%d%H%M%S)"
  git -C "$checkout" switch --quiet -c "$branch" \
    || die "Could not create submission branch"
  git -C "$checkout" config user.name "$login"
  git -C "$checkout" config user.email "${login}@users.noreply.github.com"
  git -C "$checkout" commit --quiet -m "$title" \
    || die "Could not commit the bundle submission"

  push_remote="origin"
  head_ref="$branch"
  case "$permission" in
    ADMIN|MAINTAIN|WRITE) ;;
    *)
      repo_name="${target_repo##*/}"
      fork_parent=$(GH_PROMPT_DISABLED=1 gh repo view "${login}/${repo_name}" \
        --json parent --jq '.parent.nameWithOwner // ""' 2>/dev/null || true)
      if [[ -z "$fork_parent" ]]; then
        GH_PROMPT_DISABLED=1 gh repo fork "$target_repo" --clone=false >/dev/null \
          || die "Could not create a fork of ${target_repo}"
        fork_parent=$(GH_PROMPT_DISABLED=1 gh repo view "${login}/${repo_name}" \
          --json parent --jq '.parent.nameWithOwner // ""' 2>/dev/null || true)
      fi
      [[ "$fork_parent" == "$target_repo" ]] \
        || die "${login}/${repo_name} is not a fork of ${target_repo}"
      git -C "$checkout" remote add submit \
        "${SPARK_BUNDLE_SUBMIT_FORK_URL:-https://github.com/${login}/${repo_name}.git}"
      push_remote="submit"
      head_ref="${login}:${branch}"
      ;;
  esac
  git -C "$checkout" push --quiet -u "$push_remote" "$branch" \
    || die "Could not push the submission branch"

  body=$(printf '## Bundle\n\n- Name: `%s`\n- Change: `%s`\n- Target: `%s`\n- Drafter: `%s`\n- Speculative tokens: `%s`\n\nPrepared with `spark bundle submit`.\n' \
    "$name" "$change" "$target" "$drafter" "$tokens")
  pr_args=(pr create --repo "$target_repo" --base "$base" --head "$head_ref" \
    --title "$title" --body "$body")
  [[ "$draft" == "1" ]] && pr_args+=(--draft)
  pr_url=$(GH_PROMPT_DISABLED=1 gh "${pr_args[@]}" 2>/dev/null) \
    || die "The branch was pushed, but GitHub could not create the PR" \
      "Open it manually from branch: ${head_ref}"
  info "Pull request opened: ${pr_url}"
  bundle_submit_cleanup
  trap - EXIT
}

bundle_tui_run_configured() {
  local name="$1" manifest value key type default
  local -a bundle_tui_flags=()
  bundle_resolve "$name" || die "Bundle '${name}' does not exist"
  manifest="${BUNDLE_PATH}/bundle.json"
  printf '  Max context length (blank = default): '; read -r value
  [[ -z "$value" ]] || bundle_tui_flags+=(--max-len "$value")
  printf '  Concurrent sequences (blank = default): '; read -r value
  [[ -z "$value" ]] || bundle_tui_flags+=(--max-num-seqs "$value")
  printf '  KV cache dtype auto/fp8 (blank = default): '; read -r value
  [[ -z "$value" ]] || bundle_tui_flags+=(--kv-cache-dtype "$value")
  printf '  API port (blank = default): '; read -r value
  [[ -z "$value" ]] || bundle_tui_flags+=(--port "$value")
  while IFS=$'\t' read -r -u 3 key type default; do
    printf '  --%s %s (blank = %s): ' "$key" "$type" "$default"
    read -r value
    [[ -z "$value" ]] || bundle_tui_flags+=("--${key}" "$value")
  done 3< <(jq -r '(.options // {}) | to_entries[] | [.key, .value.type, (.value.default|tostring)] | @tsv' "$manifest")
  cmd_run "$name" "${bundle_tui_flags[@]}"
}

cmd_bundle_tui() {
  local choice action name path i
  is_interactive || die "Bundle TUI requires a terminal" "Use spark bundle --help for commands."
  bundle_collect
  printf '\n  %sSpark bundles%s\n\n' "$BOLD" "$NC"
  for i in "${!BUNDLE_LIST_NAMES[@]}"; do
    name="${BUNDLE_LIST_NAMES[$i]}"; path="${BUNDLE_LIST_PATHS[$i]}"
    printf '    [%d] %-34s %s\n' "$((i + 1))" "$name" "$(jq -r '.description' "${path}/bundle.json")"
  done
  printf '\n    [n] Create     [i] Import     [q] Exit\n\n  Select: '
  read -r choice || choice=q
  case "$choice" in
    q) return 0 ;;
    n)
      printf '  Name: '; read -r name
      cmd_bundle_init "$name" "./${name}" ;;
    i)
      printf '  Folder: '; read -r path
      cmd_bundle_import "$path" ;;
    *)
      [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#BUNDLE_LIST_NAMES[@]} ]] \
        || die "Choose a listed bundle, n, i, or q"
      name="${BUNDLE_LIST_NAMES[$((choice - 1))]}"
      cmd_bundle_show "$name"
      printf '    [1] Run   [2] Configure and run   [3] Back\n\n  Select: '
      read -r action || action=3
      case "$action" in
        1) cmd_run "$name" ;;
        2) bundle_tui_run_configured "$name" ;;
        3) return 0 ;;
        *) die "Choose 1, 2, or 3" ;;
      esac ;;
  esac
}

cmd_bundle_help() {
  cat <<EOF

  ${BOLD}Usage:${NC} spark bundle [command]

    list [--json]                  List available bundles
    show <name> [--json]           Describe a bundle
    init <name> [--directory DIR]  Create an external bundle template
    validate <directory>           Validate without importing
    import <directory> [--force]   Import or replace a bundle folder
    remove <name>                  Remove an imported bundle
    sync [--check]                 Embed Git-tracked bundles into spark
    submit <name|directory>        Validate and open a GitHub pull request
      [--dry-run] [--draft]        Preview only, or open it as a draft

  With no command, opens the interactive bundle browser.
  Run one with: spark run <bundle> [normal flags] [bundle flags]
  Run automatically builds its Dockerfile and reuses Docker's layer cache.

EOF
}

cmd_bundle() {
  local action="${1:-}" name="" dir="" dry=0 draft=0 ref=""
  [[ -n "$action" ]] || { cmd_bundle_tui; return; }
  shift || true
  case "$action" in
    list)
      [[ "${1:-}" == "--json" || -z "${1:-}" ]] || die "Usage: spark bundle list [--json]"
      cmd_bundle_list "$([[ "${1:-}" == "--json" ]] && printf 1 || printf 0)" ;;
    show)
      name="${1:-}"; [[ -n "$name" ]] || die "Usage: spark bundle show <name> [--json]"
      [[ "${2:-}" == "--json" || -z "${2:-}" ]] || die "Usage: spark bundle show <name> [--json]"
      cmd_bundle_show "$name" "$([[ "${2:-}" == "--json" ]] && printf 1 || printf 0)" ;;
    init)
      name="${1:-}"; [[ -n "$name" ]] || die "Usage: spark bundle init <name> [--directory DIR]"; shift || true
      dir="./${name}"
      if [[ "${1:-}" == "--directory" ]]; then [[ -n "${2:-}" ]] || die "Missing --directory value"; dir="$2"; shift 2; fi
      [[ $# -eq 0 ]] || die "Usage: spark bundle init <name> [--directory DIR]"
      cmd_bundle_init "$name" "$dir" ;;
    validate)
      dir="${1:-}"; [[ -n "$dir" && -z "${2:-}" ]] || die "Usage: spark bundle validate <directory>"
      bundle_validate_dir "$dir" && info "Bundle is valid: ${dir}" ;;
    import)
      dir="${1:-}"; [[ -n "$dir" ]] || die "Usage: spark bundle import <directory> [--force]"
      [[ "${2:-}" == "--force" || -z "${2:-}" ]] || die "Usage: spark bundle import <directory> [--force]"
      cmd_bundle_import "$dir" "$([[ "${2:-}" == "--force" ]] && printf 1 || printf 0)" ;;
    remove)
      name="${1:-}"; [[ -n "$name" && -z "${2:-}" ]] || die "Usage: spark bundle remove <name>"
      cmd_bundle_remove "$name" ;;
    sync)
      [[ "${1:-}" == "--check" || -z "${1:-}" ]] || die "Usage: spark bundle sync [--check]"
      cmd_bundle_sync "$([[ "${1:-}" == "--check" ]] && printf 1 || printf 0)" ;;
    submit)
      ref="${1:-}"; [[ -n "$ref" ]] || die "Usage: spark bundle submit <name|directory> [--dry-run] [--draft]"
      shift || true
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --dry-run) dry=1 ;;
          --draft) draft=1 ;;
          *) die "Usage: spark bundle submit <name|directory> [--dry-run] [--draft]" ;;
        esac
        shift
      done
      cmd_bundle_submit "$ref" "$dry" "$draft" ;;
    help|-h|--help) cmd_bundle_help ;;
    *) die "Unknown bundle command: ${action}" "Run 'spark bundle --help' for usage" ;;
  esac
}
