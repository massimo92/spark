#!/usr/bin/env bash
# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
export HOME="$fixture"
export SPARK_BACKEND=vllm SPARK_ACCEL=cuda-unified
# shellcheck disable=SC1091
source "$ROOT_DIR/spark"

FIXTURE_MODEL='Saren/Qwen3.8-Flash-Next-W4A16-AutoRound-hybrid'
gateway_load_config() {
  jq -nc --arg model "$FIXTURE_MODEL" '{main:{model:$model,provider:"vllm"},providers:{vllm:{enabled:true}}}'
}
list_managed_containers() { printf 'fixture\t%s\t8012\n' "$FIXTURE_MODEL"; }
model_api_kind() { printf 'chat\n'; }
docker() {
  jq -nc --arg length "$length" '
    {Cmd:["--max-model-len="+$length,"--reasoning-parser","qwen3","--enable-auto-tool-choice",
      "--tool-call-parser","qwen3_coder","--limit-mm-per-prompt","{\"image\":0}",
      "--override-generation-config","{\"max_new_tokens\":1024}"],
     Labels:{"spark.max_model_len":"4096","spark.is_multimodal":"true"}}'
}
length=32K
yaml=$(gateway_generate_litellm_yaml)
primary=$(printf '%s\n' "$yaml" | sed -n 's/^    model_info: //p' | jq -cs 'select(length == 2 and .[0] == .[1]) | .[0]')
jq -e '.spark_context_window == 32768 and .max_input_tokens == 32768 and .max_output_tokens == 1024
  and .spark_max_output_tokens == 1024
  and .supports_vision == false and .supports_function_calling == true and .spark_reasoning_efforts.xhigh == "xhigh"'   <<<"$primary" >/dev/null
printf 'ok - gateway publishes the effective runtime limits and capabilities for vLLM and main\n'

mkdir -p "$DSH_DIR/state" "$DSH_DIR/secrets"
printf 'sk-%064d\n' 1 >"$DSH_DIR/secrets/gateway-key"
printf '{"plugins":"none"}\n' >"$DSH_DIR/settings.json"
FIXTURE_VISIBLE=$(jq -nc --arg model "vllm/$FIXTURE_MODEL" '{data:[{id:$model},{id:"chatgpt/fixture"},{id:"systemone/fixture"},{id:"zen/*"}]}')
curl() { cat >/dev/null; printf '%s\n' "$FIXTURE_VISIBLE"; }
gateway_curl() {
  [[ "${fail_metadata:-0}" == 0 ]] || return 1
  jq -nc --arg name "vllm/$FIXTURE_MODEL" --argjson info "$(gateway_vllm_model_info fixture "$FIXTURE_MODEL")" '
    {data:[{model_name:$name,model_info:$info},
      {model_name:"chatgpt/fixture",model_info:{mode:"responses",max_input_tokens:200000,supports_vision:true}},
      {model_name:"systemone/fixture",model_info:{mode:"decisions"}}]}'
}
patch="$DSH_DIR/state/cordis.patch.yml"
dsh_sync_catalog
jq -e '
  any(.[]; .id == "session-log-deepseek" and .config.enabled == false) and
  (map(select(.id == "llm-pi-ai"))[0].config.providers |
    .litellm.models[0].contextWindow == 32768 and .litellm.models[0].maxTokens == 1024 and
    .litellm.models[0].input == ["text"] and
    .litellm.models[0].reasoningEfforts.xhigh == "xhigh" and
    .["litellm-responses"].models[0].input == ["text","image"] and
    ([.[] | .models[]] | length) == 2)' "$patch" >/dev/null
if dsh_catalog_matches <<<'{"groups":[]}'; then exit 1; fi
jq -c '[.[] | select(.id=="llm-pi-ai") | .config.providers | to_entries[] |
  {id:.key,models:.value.models}] | {groups:.}' "$patch" | dsh_catalog_matches
printf 'ok - DSH readiness requires the runtime to publish the managed model IDs\n'
length=16384
dsh_sync_catalog
jq -e 'any(.[]; .config.providers.litellm.models[0].contextWindow == 16384)' "$patch" >/dev/null
cp "$patch" "$fixture/previous"
FIXTURE_VISIBLE='{"data":[]}'
fail_metadata=1
if dsh_sync_catalog; then exit 1; fi
cmp "$patch" "$fixture/previous"
fail_metadata=0
dsh_sync_catalog
jq -e 'any(.[]; .id == "llm-pi-ai" and .config.providers == {})' "$patch" >/dev/null
printf 'ok - DSH reconciles protocols, context changes and stopped models, and retains a good catalog on failure\n'

dsh_render_patch '{"data":[{"id":"main"},{"id":"vllm/example"},{"id":"chatgpt/fixture"}]}' \
  '{"data":[{"model_name":"main","model_info":{"spark_context_window":262144,"max_output_tokens":262144}},
    {"model_name":"vllm/example","model_info":{"spark_context_window":262144,"spark_max_output_tokens":210000}},
    {"model_name":"chatgpt/fixture","model_info":{"mode":"responses","max_input_tokens":272000,"max_output_tokens":128000}}]}' \
  protocols http://127.0.0.1:4000/v1 |
  jq -e '[.[] | .insert[]? | select(.id=="llm-pi-ai-protocols") |
    .config.providers.litellm.models[] | {key:.id,value:.maxTokens}] | from_entries |
    .main == null and .["vllm/example"] == null and .["chatgpt/fixture"] == 128000' >/dev/null
printf 'ok - DSH ignores synthesized output limits and leaves room for history\n'

[[ "$(dsh_plugin_selection workflows,chart,chart)" == chart,workflows ]]
if dsh_plugin_selection unknown; then exit 1; fi
[[ "$(dsh_select_plugins '' 1)" == none ]]
[[ "$(dsh_select_plugins '' 1 chart)" == chart ]]
[[ "$(dsh_select_plugins all 1)" == chart,workflows,search-router,session-delete,protocols ]]
[[ -z "$(dsh_selected_assets none)" ]]
dsh_selected_assets session-delete | awk -F '\t' '$1 == "session-delete/package.json" {found=1} END {exit !found}'
[[ "$(dsh_image_id "$DSH_INITIAL_VERSION" none)" != "$(dsh_image_id "$DSH_INITIAL_VERSION" chart)" ]]
dsh_mapping_matches '{"services":{"svc:dsh":{"endpoints":{"tcp:443":"https+insecure://127.0.0.1:3080"}}}}'
if dsh_mapping_matches '{"services":{"svc:dsh":{"endpoints":{"tcp:443":"https+insecure://127.0.0.1:30801"}}}}'; then
  exit 1
fi
printf 'ok - optional plugin selection and assets; private mapping is scoped to DSH\n'
