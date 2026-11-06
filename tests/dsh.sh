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
gateway_vllm_template_tokens() {
  [[ "$2" == 8012 ]] || return 1
  if [[ "${ignore_effort:-0}" == 1 ]]; then printf '[5]\n'; return; fi
  case "$3" in
    off) printf '[1]\n' ;;
    low) printf '[2]\n' ;;
    medium) printf '[3]\n' ;;
    default|enabled|xhigh) printf '[4]\n' ;;
    *) printf 'null\n' ;;
  esac
}
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
  and .supports_vision == false and .supports_function_calling == true
  and .spark_reasoning_efforts == {off:null,low:"low",medium:"medium",xhigh:"xhigh"}
  and .spark_default_reasoning_effort == "xhigh"
  and .spark_dsh_compat.chatTemplateKwargs.preserve_thinking == true' <<<"$primary" >/dev/null
ignore_effort=1
if gateway_vllm_template_reasoning "$FIXTURE_MODEL" 8012; then exit 1; fi
ignore_effort=0
printf 'ok - gateway publishes the effective runtime limits and capabilities for vLLM and main\n'

mkdir -p "$DSH_DIR/state" "$DSH_DIR/secrets"
printf 'sk-%064d\n' 1 >"$DSH_DIR/secrets/gateway-key"
printf '{"plugins":"none"}\n' >"$DSH_DIR/settings.json"
FIXTURE_VISIBLE=$(jq -nc --arg model "vllm/$FIXTURE_MODEL" '{data:[{id:$model},{id:"chatgpt/fixture"},{id:"systemone/fixture"},{id:"zen/*"}]}')
curl() { cat >/dev/null; printf '%s\n' "$FIXTURE_VISIBLE"; }
gateway_curl() {
  [[ "${fail_metadata:-0}" == 0 ]] || return 1
  jq -nc --arg name "vllm/$FIXTURE_MODEL" --argjson info "$(gateway_vllm_model_info fixture "$FIXTURE_MODEL" 8012)" '
    {data:[{model_name:$name,model_info:$info},
      {model_name:"chatgpt/fixture",model_info:{mode:"responses",max_input_tokens:200000,supports_vision:true}},
      {model_name:"systemone/fixture",model_info:{mode:"decisions"}}]}'
}
patch="$DSH_DIR/state/cordis.patch.yml"
dsh_sync_catalog
jq -e '
  any(.[]; .id == "workspace-controller" and .config.documentsDirectory == "/workspace") and
  any(.[]; .id == "session-log-deepseek" and .config.enabled == false) and
  (map(select(.id == "llm-pi-ai"))[0].config.providers |
    .litellm.reasoning == "xhigh" and
    .["litellm-responses"].reasoning == null and
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

qwen_route="vllm/$FIXTURE_MODEL"
alias_info=$(jq -nc --arg id "$qwen_route" --arg model "openai/$FIXTURE_MODEL" '
  {data:(["main",$id] | map({model_name:.,litellm_params:{model:$model,api_base:"http://localhost:8012/v1"},
    model_info:{spark_reasoning_efforts:{xhigh:"xhigh"},spark_default_reasoning_effort:"xhigh"}}))}')
alias_visible=$(jq -nc --arg id "$qwen_route" '{data:[{id:"main"},{id:$id}]}')
dsh_render_patch "$alias_visible" "$alias_info" protocols http://127.0.0.1:4000/v1 |
  jq -e --arg id "$qwen_route" '
    [.[] | .insert[]? | select(.id=="llm-pi-ai-protocols") | .config.providers.litellm.models[] |
      {id,name,defaultReasoningEffort}] == [{id:$id,name:"Qwen 3.8 Flash Next",defaultReasoningEffort:"xhigh"}] and
    any(.[]; .id == "agent-default-model" and .config.model == $id and .config.reasoningEffort == "xhigh")' >/dev/null
dsh_render_patch '{"data":[{"id":"main"}]}' "$alias_info" none http://127.0.0.1:4000/v1 |
  jq -e 'any(.[]; .id == "agent-default-model" and .config.model == "main")' >/dev/null
other_backend=$(jq -c '.data[0].litellm_params.api_base = "http://localhost:8013/v1"' <<<"$alias_info")
dsh_render_patch "$alias_visible" "$other_backend" none http://127.0.0.1:4000/v1 |
  jq -e --arg id "$qwen_route" '
    [.[] | select(.id=="llm-pi-ai") | .config.providers.litellm.models[].id] == ["main",$id] and
    any(.[]; .id == "agent-default-model" and .config.model == "main")' >/dev/null
printf 'ok - DSH names Qwen and hides main only when its equivalent named route is available\n'

[[ "$(dsh_plugin_selection workflows,chart,chart)" == chart,workflows ]]
if dsh_plugin_selection unknown; then exit 1; fi
[[ "$(dsh_select_plugins '' 1)" == none ]]
[[ "$(dsh_select_plugins '' 1 chart)" == chart ]]
[[ "$(dsh_select_plugins all 1)" == chart,workflows,search-router,session-delete,protocols ]]
[[ -z "$(dsh_selected_assets none)" ]]
dsh_selected_assets session-delete | awk -F '\t' '$1 == "session-delete/package.json" {found=1} END {exit !found}'
[[ "$(dsh_image_id "$DSH_INITIAL_VERSION" none)" != "$(dsh_image_id "$DSH_INITIAL_VERSION" chart)" ]]
dsh_mapping_matches "$(jq -nc --arg target "https://$(dsh_socket_target)" \
  '{services:{"svc:dsh":{endpoints:{"tcp:443":$target}}}}')" "$(dsh_socket_target)"
if dsh_mapping_matches '{"services":{"svc:dsh":{"endpoints":{"tcp:443":"https+insecure://127.0.0.1:30801"}}}}'; then
  exit 1
fi
printf 'ok - optional plugin selection and assets; private mapping is scoped to DSH\n'
[[ "$(SPARK_DSH_TAILSCALE_USERS=owner@example.com dsh_access_users)" == owner@example.com ]]
if SPARK_DSH_TAILSCALE_USERS='*@example.com' dsh_access_users 2>/dev/null; then exit 1; fi

export SPARK_TAILSCALE_SERVICES_TOKEN=test-token
dsh_service_api() {
  case "$1:$2" in
    GET:test-token) printf '%s\n' "$service_response" ;;
    PUT:test-token)
      [[ "$3" == '{"name":"svc:dsh","ports":["tcp:443"]}' ]] || return 1
      touch "$fixture/service-created"
      printf '\n204\n' ;;
    *) return 1 ;;
  esac
}
service_response=$'{"name":"svc:dsh","ports":["tcp:443","tcp:80"]}\n200'
dsh_register_service
[[ ! -e "$fixture/service-created" ]]
service_response=$'{"name":"svc:dsh","ports":["tcp:80"]}\n200'
if dsh_register_service 2>/dev/null; then exit 1; fi
[[ ! -e "$fixture/service-created" ]]
service_response=$'{}\n404'
dsh_register_service
[[ -e "$fixture/service-created" ]]
printf 'ok - unattended registration creates missing svc:dsh and preserves existing definitions\n'
