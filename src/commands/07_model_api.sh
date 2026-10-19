# Model API contracts are independent of the inference engine. Old containers
# have no API label and keep the OpenAI chat-completions contract.
model_api_kind() {
  local kind
  kind=$(docker inspect --format '{{index .Config.Labels "spark.api"}}' "$1" 2>/dev/null || true)
  case "$kind" in systemone) printf 'systemone\n' ;; *) printf 'chat\n' ;; esac
}

model_api_path() {
  case "${1:-chat}" in systemone) printf '/v1/systemone' ;; *) printf '/v1' ;; esac
}

gateway_model_prefix() {
  local provider="$1" model="$2" name
  case "$provider" in
    ollama) printf 'ollama_chat' ;;
    systemone) printf 'systemone' ;;
    vllm)
      name=$(container_for_ref "$model" 2>/dev/null || true)
      if [[ -n "$name" && "$(model_api_kind "$name")" == systemone ]]; then
        printf 'systemone'
      else
        printf 'vllm'
      fi ;;
    *) return 1 ;;
  esac
}

systemone_gateway_preflight() {
  gateway_capabilities decisions >/dev/null || {
    err 'LiteLLM image lacks System One decision routing'
    printf '    Update it first: spark update --litellm\n' >&2
    return 1
  }
}

# Normalize a bundle's custom command back to its canonical vllm-shaped argv.
# Inspect the actual executable and arguments, rather than trusting a saved argv
# label, so alias capture cannot silently preserve a different launch command.
bundle_container_args() {
  local inspect="$1" name hash launcher
  name=$(jq -r '.[0].Config.Labels["spark.bundle.name"] // empty' <<<"$inspect")
  hash=$(jq -r '.[0].Config.Labels["spark.bundle.hash"] // empty' <<<"$inspect")
  is_safe_bundle_name "$name" || return 1
  local SPARK_BUNDLE_PIN="$hash"
  bundle_resolve "$name" || return 1
  launcher=$(jq -c '.runtime.command // []' "${BUNDLE_PATH}/bundle.json")
  [[ "$launcher" != '[]' ]] || return 1
  jq -ce --argjson launcher "$launcher" '
    ((.[0].Config.Entrypoint // []) + (.[0].Config.Cmd // [])) as $cmd
    | if $cmd[:($launcher|length)] == $launcher
      then ["vllm", "serve"] + $cmd[($launcher|length):]
      else error("container command differs from bundle launcher") end
  ' <<<"$inspect"
}
