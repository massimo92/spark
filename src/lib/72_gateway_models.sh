# Based on spark by Massimo Angelini - https://github.com/massimo92/spark

# Client metadata observed for these specific routes. The running backend wins
# for deployment limits and features that can be changed at launch.
gateway_model_client_info() {
  case "$1" in
    vllm/Saren/Qwen3.8-Flash-Next-W4A16-AutoRound-hybrid)
      printf '%s\n' '{"spark_reasoning_efforts":{"off":null,"low":"low","medium":"medium","xhigh":"xhigh"},"spark_dsh_compat":{"supportsDeveloperRole":false,"thinkingFormat":"chat-template","chatTemplateKwargs":{"enable_thinking":{"$var":"thinking.enabled"},"reasoning_effort":{"$var":"thinking.effort","omitWhenOff":true},"preserve_thinking":true}}}'
      ;;
    chatgpt/gpt-6-astra|chatgpt/gpt-6.1-sol|chatgpt/gpt-6-luna)
      local context=272000
      [[ "$1" != chatgpt/gpt-6.1-sol ]] || context=500000
      printf '{"spark_context_window":%s,"max_input_tokens":%s,"supports_vision":true,"spark_reasoning_efforts":{"low":"low","medium":"medium","high":"high","xhigh":"xhigh","max":"max"},"spark_dsh_compat":{"supportsMaxOutputTokens":false}}\n' "$context" "$context"
      ;;
    *) printf '{}\n' ;;
  esac
}

gateway_vllm_model_info() {
  local container="$1" model="$2" runtime profile known artifact
  runtime=$(docker inspect --format '{{json .Config}}' "$container" 2>/dev/null || true)
  known=$(gateway_model_client_info "vllm/$model") || return 1
  artifact=$(jq -r '.Labels["spark.bundle.artifact"] // empty' <<<"$runtime" 2>/dev/null || true)
  [[ "$artifact" =~ ^[a-zA-Z0-9._-]+$ ]] || artifact=""
  profile=$(BUNDLE_ARTIFACT_KEY="$artifact" profile_file_for "$model")
  profile=$(jq -ce 'select(type == "object")' "$profile" 2>/dev/null || printf '{}')
  printf '%s\n' "$runtime" | jq -c --argjson profile "$profile" --argjson known "$known" '
    def value($flag):
      . as $args | [range(0; length) as $i |
        if $args[$i] == $flag then $args[$i+1]
        elif $args[$i] | startswith($flag + "=") then $args[$i] | split("=")[1:] | join("=")
        else empty end] | last;
    def positive: tonumber? | select(. > 0 and . == floor);
    def runtime_length:
      if type == "string" and test("^[0-9]+([.][0-9]+)?[kKmM]$") then
        (.[:-1] | tonumber) *
          (if endswith("k") then 1000 elif endswith("K") then 1024
           elif endswith("m") then 1000000 else 1048576 end) | floor
      else positive end;
    (.Cmd // []) as $args |
    ([($args | value("--max-model-len") | runtime_length),
      (.Labels["spark.max_model_len"] | positive)] | first) as $context |
    ($args | value("--limit-mm-per-prompt") | fromjson? // {}) as $media |
    ($args | value("--reasoning-parser")) as $parser |
    ($args | value("--reasoning-effort-map") | fromjson? // {}) as $efforts |
    ($args | value("--override-generation-config") | fromjson? // {}) as $generation |
    ([$generation.max_new_tokens,
      (if ($args | value("--generation-config")) as $source | $source == null or $source == "auto"
       then $profile.hf.raw.generation_config.max_new_tokens else null end)] | map(positive) | first) as $output |
    (if $context != null and $output != null then [$context, $output] | min else $output end) as $output_limit |
    {mode:"chat",
     spark_context_window:$context,
     max_input_tokens:$context,
     max_output_tokens:$output_limit,
     spark_max_output_tokens:$output_limit,
     supports_vision:(if $media.image == 0 or (($media.image | objects | .count) // -1) == 0 then false
       elif .Labels["spark.is_multimodal"] == "true" then true
       elif .Labels["spark.is_multimodal"] == "false" then false
       else ($profile.is_multimodal | if . == "true" then true
         elif . == "false" then false else . end) end),
     supports_function_calling:(($args | index("--enable-auto-tool-choice")) != null and
       ($args | value("--tool-call-parser")) != null)}
    + ($known | if $parser == null then del(.spark_reasoning_efforts) else . end)
    + (if ($efforts | type) == "object" and $parser != null and ($known | has("spark_reasoning_efforts") | not)
       then ($efforts | keys | map(select(test("^(minimal|low|medium|high|xhigh|max)$"))) |
         map({key:.,value:.}) | from_entries |
         if length > 0 then {spark_reasoning_efforts:.} else {} end)
       else {} end)
    | with_entries(select(.value != null))
  ' 2>/dev/null | awk 'NF { print; found=1 } END { if (!found) print "{\"mode\":\"chat\"}" }'
}

gateway_ollama_model_info() {
  local model="$1" runtime details
  runtime=$(curl -fsS --max-time 2 http://127.0.0.1:11434/api/ps 2>/dev/null || printf '{}')
  details=$(jq -nc --arg model "$model" '{model:$model}' |
    curl -fsS --max-time 2 -H 'Content-Type: application/json' -d @- \
      http://127.0.0.1:11434/api/show 2>/dev/null || printf '{}')
  jq -nc --arg model "$model" --argjson runtime "$runtime" --argjson details "$details" '
    ($runtime.models // [] | map(select(.name == $model or .name == ($model + ":latest"))) |
      first | .context_length | select(type == "number" and . > 0)) as $context |
    {mode:"chat",spark_context_window:$context,max_input_tokens:$context}
    + (if $details.capabilities | type == "array" then
        {supports_vision:($details.capabilities | index("vision") != null),
         supports_function_calling:($details.capabilities | index("tools") != null)}
       else {} end)
  ' | awk 'NF { print; found=1 } END { if (!found) print "{\"mode\":\"chat\"}" }'
}
