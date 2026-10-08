#!/usr/bin/env bash
# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export SPARK_BACKEND=vllm SPARK_ACCEL=cpu SPARK_GATEWAY_READY_ATTEMPTS=1
source "$ROOT/spark"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
passed=0
check() {
  local label="$1"; shift
  local sandbox
  sandbox=$(mktemp -d "$TEST_ROOT/case.XXXXXX")
  local result=0
  set +e
  (set -e; SPARK_CONFIG_DIR="$sandbox"; GATEWAY_CONFIG="$sandbox/gateway.json"; WORKSPACE_ENV_FILE="$sandbox/absent.env"; "$@")
  result=$?
  set -e
  if [[ "$result" == 0 ]]; then printf 'ok - %s\n' "$label"; passed=$((passed+1)); else printf 'not ok - %s\n' "$label"; exit 1; fi

}
private_mode() { [[ "$(bundle_path_mode "$1")" == "$2" ]]; }
token_persistence() {
  gateway_prepare_runtime vllm
  local first
  first=$(gateway_auth_key)
  gateway_prepare_runtime vllm
  [[ "$first" == "$(gateway_auth_key)" && "$first" =~ ^sk-[a-f0-9]{64}$ ]]
  private_mode "$SPARK_CONFIG_DIR" 700 && private_mode "$(gateway_secrets_path)" 600
  ! grep -q "$first" "$GATEWAY_CONFIG"
  ! gateway_env_set BAD $'injected\nTOKEN=value'
}
token_rotation_rollback() {
  gateway_prepare_runtime vllm
  local old
  old=$(gateway_auth_key)
  gateway_running_state() { return 1; }
  gateway_sync_clients() { return 1; }
  ! gateway_auth_rotate
  [[ "$old" == "$(gateway_auth_key)" ]]
  gateway_sync_clients() { return 0; }
  gateway_auth_rotate
  [[ "$old" != "$(gateway_auth_key)" ]]
}
migrate() {
  gateway_save_config '{"enabled":true,"port":4321,"main":{"provider":"vllm","model":"Org/B"},"providers":{"openai":{"enabled":true,"api_key":"legacy-test-key","models":["test-model"]}}}'
  gateway_auth_ensure
  [[ "$(gateway_env_get OPENAI_API_KEY)" == legacy-test-key ]]
  jq -e '.port==4321 and .main.model=="Org/B" and (.providers.openai|has("api_key")|not)' "$GATEWAY_CONFIG" >/dev/null
  private_mode "$SPARK_CONFIG_DIR/gateway-migration" 700
  [[ -s "$SPARK_CONFIG_DIR/gateway-migration/gateway.json" ]]
}
route_lifecycle() {
  gateway_prepare_runtime vllm
  gateway_set_main_model vllm Org/B
  list_managed_containers() { printf 'one\tOrg/A\t8000\nsecond\tOrg/B\t8001\n'; }
  local yaml
  yaml=$(gateway_generate_litellm_yaml)
  [[ "$yaml" == *'vllm/Org/A'* && "$yaml" == *'vllm/Org/B'* && "$yaml" == *'http://localhost:8001/v1'* && "$yaml" != *'vllm/*'* ]]
  list_managed_containers() { printf 'one\tOrg/A\t8000\n'; }
  yaml=$(gateway_generate_litellm_yaml)
  [[ "$yaml" != *'Org/B'* && "$yaml" != *'model_name: "main"'* ]]
  jq -e '.main.model=="Org/B"' "$GATEWAY_CONFIG" >/dev/null
  gateway_register_ollama alpha
  gateway_register_ollama beta
  gateway_forget_ollama alpha alpha
  jq -e '.providers.ollama.models==["beta"]' "$GATEWAY_CONFIG" >/dev/null
}
provider_modes() {
  gateway_prepare_runtime vllm
  gateway_capabilities() { return 0; }
  gateway_oauth_status() { printf credentials-present; }
  gateway_running_state() { return 1; }
  gateway_env_set XAI_API_KEY api-test-key
  gateway_add xai --auth oauth --model grok-test
  local yaml
  yaml=$(gateway_generate_litellm_yaml)
  [[ "$yaml" == *'"model":"xai/grok-test"'* && "$yaml" == *'"use_xai_oauth":true'* && "$yaml" != *'os.environ/XAI_API_KEY'* ]]
  gateway_add xai --auth api --model grok-second
  yaml=$(gateway_generate_litellm_yaml)
  [[ "$yaml" == *'os.environ/XAI_API_KEY'* && "$yaml" != *'use_xai_oauth'* && "$yaml" == *'grok-test'* ]]
  ! gateway_add claude_max --auth oauth --model anything
  gateway_capabilities() { return 1; }
  ! gateway_add chatgpt --model inaccessible
  jq -e '.providers.chatgpt==null' "$GATEWAY_CONFIG" >/dev/null
}
container_secrets() {
  gateway_prepare_runtime vllm
  gateway_capabilities() { return 0; }
  gateway_oauth_status() { printf credentials-present; }
  gateway_save_config '{"enabled":true,"port":4000,"providers":{"xai":{"enabled":true,"auth":"oauth","models":["grok-test"]}}}'
  docker() { printf '%s\n' "$*" >> "$SPARK_CONFIG_DIR/docker.calls"; }
  SPARK_OS=Linux
  gateway_start_container
  local calls key
  calls=$(cat "$SPARK_CONFIG_DIR/docker.calls"); key=$(gateway_auth_key)
  [[ "$calls" == *'--user '* && "$calls" == *'-e HOME=/tmp'* && "$calls" == *'--env-file'* && "$calls" == *'-e XAI_API_KEY='* && "$calls" == *'/tokens/xai'* && "$calls" == *'--host 127.0.0.1'* && "$calls" != *"$key"* ]]
}
sync_recovery() {
  gateway_prepare_runtime vllm
  printf 'previous routes\ngeneral_settings:\n  master_key: os.environ/LITELLM_MASTER_KEY\n' > "$SPARK_CONFIG_DIR/litellm_config.yaml"
  gateway_running_state() { return 0; }
  gateway_api_ready() { return 1; }
  docker() { [[ "$1" != inspect ]] || printf 'sha256:previous\n'; }
  gateway_start_container() { [[ -n "${GATEWAY_RESTORE_IMAGE:-}" ]]; }
  gateway_wait_ready() { return 0; }
  ! gateway_sync
  [[ "$(cat "$SPARK_CONFIG_DIR/litellm_config.yaml")" == $'previous routes\ngeneral_settings:\n  master_key: os.environ/LITELLM_MASTER_KEY' ]]
  [[ ! -d "$SPARK_CONFIG_DIR/gateway.lock" ]]
}
unchanged_sync() {
  gateway_prepare_runtime vllm
  gateway_generate_litellm_yaml > "$SPARK_CONFIG_DIR/litellm_config.yaml"
  gateway_running_state() { return 0; }
  gateway_api_ready() { return 0; }
  docker() { [[ "$1" != stop ]]; }
  gateway_wait_ready() { return 0; }
  gateway_sync_clients() { return 0; }
  gateway_start_container() { return 1; }
  gateway_sync
}
node_policy() {
  gateway_prepare_runtime vllm
  tailscale() {
    printf '%s\n' '{"Self":{"HostName":"gx10","DNSName":"gx10.example.ts.net.","TailscaleIPs":["100.64.0.1","fd7a:115c:a1e0::1"]},"Peer":{"a":{"HostName":"allowed","DNSName":"allowed.example.ts.net.","TailscaleIPs":["100.64.0.2","fd7a:115c:a1e0::2"]},"b":{"HostName":"denied","DNSName":"denied.example.ts.net.","TailscaleIPs":["100.64.0.3"]}}}'
  }
  gateway_access_allow allowed > /dev/null
  gateway_access_policy > "$SPARK_CONFIG_DIR/policy.json"
  jq -e '.grants[0].src==["100.64.0.2","fd7a:115c:a1e0::2"] and .grants[0].ip==["tcp:8443"] and any(.tests[]; .src=="100.64.0.3" and has("deny"))' "$SPARK_CONFIG_DIR/policy.json" >/dev/null
  ! gateway_access_allow unknown
  jq -e '.access.policy_status=="pending"' "$GATEWAY_CONFIG" >/dev/null
}
serve_ownership() {
  gateway_prepare_runtime vllm
  gateway_save_config '{"enabled":true,"port":4000,"access":{"sources":["100.64.0.2"]},"providers":{"vllm":{"enabled":true}}}'
  gateway_wait_ready() { return 0; }
  tailscale_funnel_status_active() { return 1; }
  tailscale() {
    case "$*" in
      'status --json') printf '{"Self":{"DNSName":"gx.example.ts.net."}}\n' ;;
      'serve status --json') cat "$SPARK_CONFIG_DIR/serve.json" ;;
      *) printf '%s\n' "$*" >> "$SPARK_CONFIG_DIR/serve.calls" ;;
    esac
  }
  printf '{"TCP":{"8443":{"HTTPS":true}},"Web":{"gx.example.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://localhost:3456"}}}}}\n' > "$SPARK_CONFIG_DIR/serve.json"
  ! gateway_access_enable
  [[ ! -f "$SPARK_CONFIG_DIR/serve.calls" ]]
  printf '{"TCP":{"443":{"HTTPS":true}},"Web":{"gx.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://localhost:3456"}}}}}\n' > "$SPARK_CONFIG_DIR/serve.json"
  gateway_access_enable
  [[ "$(cat "$SPARK_CONFIG_DIR/serve.calls")" == *'--https=8443'* && "$(cat "$SPARK_CONFIG_DIR/serve.calls")" != *reset* ]]
  ! gateway_access_disable
}
publication_failure() {
  gateway_prepare_runtime vllm
  gateway_sync() { return 0; }
  gateway_model_routed() { return 1; }
  ! gateway_publish_model vllm Org/A 1
  gateway_publish_model vllm Org/A 0 | grep -q pending
}
client_scope() {
  gateway_prepare_runtime vllm
  WORKSPACE_ENV_FILE="$SPARK_CONFIG_DIR/workspace.env"
  printf 'HERMES_LITELLM_BASE_URL=https://external.example/v1\nCOMPATIBLE_API_KEY=external-key\n' > "$WORKSPACE_ENV_FILE"
  workspace_read_env() { gateway_env_get "$1" "$WORKSPACE_ENV_FILE"; }
  workspace_set_env_key() { gateway_env_set "$1" "$2" "$WORKSPACE_ENV_FILE"; }
  workspace_hermes_running() { return 1; }
  gateway_sync_clients
  [[ "$(workspace_read_env COMPATIBLE_API_KEY)" == external-key ]]
  gateway_env_set HERMES_LITELLM_BASE_URL http://127.0.0.1:4000/v1 "$WORKSPACE_ENV_FILE"
  gateway_sync_clients
  [[ "$(workspace_read_env COMPATIBLE_API_KEY)" == "$(gateway_auth_key)" ]]
}
http_auth() {
  gateway_prepare_runtime vllm
  local pid old code port attempt
  python3 "$ROOT/tests/fixtures/gateway_http.py" "$(gateway_secrets_path)" "$SPARK_CONFIG_DIR/http.port" > "$SPARK_CONFIG_DIR/http.log" 2>&1 & pid=$!
  trap "kill $pid 2>/dev/null || true" EXIT
  for ((attempt=0; attempt<30; attempt++)); do [[ ! -s "$SPARK_CONFIG_DIR/http.port" ]] || break; sleep 0.1; done
  [[ -s "$SPARK_CONFIG_DIR/http.port" ]] || { cat "$SPARK_CONFIG_DIR/http.log" >&2; return 1; }
  port=$(cat "$SPARK_CONFIG_DIR/http.port")
  gateway_save_config "$(gateway_load_config | jq --argjson port "$port" '.port=$port')"
  gateway_running_state() { return 0; }
  gateway_wait_ready
  gateway_model_routed vllm Test/Alpha
  gateway_route_smoke vllm Test/Alpha
  ! gateway_route_smoke vllm Wrong/Model
  old=$(gateway_auth_key)
  gateway_running_state() { return 1; }
  gateway_auth_rotate
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$old" | curl --config - -sS --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/v1/models")
  [[ "$code" == 401 ]]
  gateway_route_smoke vllm Test/Alpha
  gateway_running_state() { return 0; }
  tailscale() { return 1; }
  local output key
  output=$(gateway_status); key=$(gateway_auth_key)
  [[ "$output" != *"$key"* && "$output" == *'Authentication: configured'* ]]
}
verified_access() {
  gateway_prepare_runtime vllm
  tailscale() { printf '%s\n' '{"Self":{"DNSName":"gx.test.ts.net."},"Peer":{"a":{"HostName":"allowed","TailscaleIPs":["100.64.0.2"]},"b":{"HostName":"denied","TailscaleIPs":["100.64.0.3"]}}}'; }
  gateway_save_config '{"enabled":true,"port":4000,"providers":{},"access":{"enabled":true,"sources":["100.64.0.2"],"port":8443}}'
  gateway_wait_ready() { return 0; }
  ssh() {
    local input
    input=$(cat)
    [[ "$*" != *"$(gateway_auth_key)"* ]]
    printf '%s\n' "$input" | jq -e '.url=="https://gx.test.ts.net:8443/v1" and ((.mode=="allowed" and (.token|startswith("sk-"))) or (.mode=="denied" and (has("token")|not)))' >/dev/null
  }
  gateway_access_verify --allowed allowed --denied denied
  jq -e '.access.policy_status=="verified" and (.access.verified_at|type)=="string"' "$GATEWAY_CONFIG" >/dev/null
  ssh() { cat >/dev/null; return 1; }
  ! gateway_access_verify --allowed allowed --denied denied
  jq -e '.access.policy_status=="pending"' "$GATEWAY_CONFIG" >/dev/null
}
setup_persistence() {
  gateway_save_config '{"enabled":true,"port":4321,"protected":false,"main":{"provider":"vllm","model":"Org/B"},"providers":{"openai":{"enabled":true,"models":["account-model"]}}}'
  gateway_env_set OPENAI_API_KEY test-only
  gateway_auth_ensure
  local key
  key=$(gateway_auth_key)
  gateway_start() { return 0; }
  gateway_status() { return 0; }
  gateway_setup_local --yes
  [[ "$key" == "$(gateway_auth_key)" ]]
  jq -e '.port==4321 and .protected==false and .main.model=="Org/B" and .providers.openai.models==["account-model"]' "$GATEWAY_CONFIG" >/dev/null
  ! gateway_protected
}
remote_setup_target() {
  local SETUP_TARGET=remote TGT_OS=Linux TGT_BACKEND=vllm
  ctx_run() { return 0; }
  remote_in() { printf '%s\n' "$*" > "$SPARK_CONFIG_DIR/remote.command"; }
  gateway_save_config() { return 1; }
  step_gateway 1 0
  [[ "$(cat "$SPARK_CONFIG_DIR/remote.command")" == '"$HOME/.local/bin/spark" gateway setup --yes' ]]
  [[ ! -f "$GATEWAY_CONFIG" && ! -f "$(gateway_secrets_path)" ]]
}
callback_and_permissions() {
  gateway_capabilities() { return 0; }
  docker() {
    local script argument
    for argument in "$@"; do script="$argument"; done
    printf '%s' "$script" | FAKE_AUTH_DIR="$(gateway_oauth_dir xai)" python3 "$ROOT/tests/fixtures/oauth_callback.py"
  }
  SPARK_OS=Linux
  export FAKE_CALLBACK_PORT=59999
  ! gateway_login xai
  [[ ! -f "$(gateway_oauth_dir xai)/auth.json" ]]
  export FAKE_CALLBACK_PORT=56121
  gateway_login xai
  private_mode "$(gateway_oauth_dir xai)" 700
  private_mode "$(gateway_oauth_dir xai)/auth.json" 600
  gateway_save_config '{"enabled":true,"port":4000,"providers":{"xai":{"enabled":true,"auth":"oauth"}}}'
  gateway_running_state() { return 1; }
  gateway_logout xai
  [[ ! -f "$(gateway_oauth_dir xai)/auth.json" ]]
  jq -e '.providers.xai.enabled==false' "$GATEWAY_CONFIG" >/dev/null
}
anonymous_rollback_forbidden() {
  gateway_prepare_runtime vllm
  printf 'general_settings:\n  master_key: null\n' > "$SPARK_CONFIG_DIR/litellm_config.yaml"
  gateway_running_state() { return 0; }
  gateway_api_ready() { return 1; }
  docker() { return 0; }
  gateway_start_container() { printf 'start\n' >> "$SPARK_CONFIG_DIR/starts"; return 1; }
  ! gateway_sync
  [[ "$(wc -l < "$SPARK_CONFIG_DIR/starts" | tr -d ' ')" == 1 ]]
  grep -q 'master_key: os.environ/LITELLM_MASTER_KEY' "$SPARK_CONFIG_DIR/litellm_config.yaml"
}
concurrent_registry() {
  gateway_prepare_runtime vllm
  gateway_register_ollama alpha & local first=$!
  gateway_register_ollama beta & local second=$!
  wait "$first"; wait "$second"
  jq -e '.providers.ollama.models==["alpha","beta"]' "$GATEWAY_CONFIG" >/dev/null
  [[ ! -d "$SPARK_CONFIG_DIR/gateway.lock" ]]
}
invalid_token_repair() {
  gateway_prepare_runtime vllm
  gateway_env_set LITELLM_MASTER_KEY invalid-test-key
  gateway_running_state() { return 1; }
  gateway_auth_rotate
  gateway_auth_ready
}
check 'private token persists across setup; rejects dotenv injection' token_persistence
check 'failed client rotation restores token; successful rotation changes it' token_rotation_rollback
check 'legacy API keys migrate privately with recoverable config' migrate
check 'multiple model ports, stopped routes and main preservation' route_lifecycle
check 'API/OAuth selection, model preservation and capability rejection' provider_modes
check 'Docker credentials are file based; OAuth wins over stale xAI key' container_secrets
check 'failed synchronization restores routes and releases lock' sync_recovery
check 'unchanged routes avoid restarting the gateway' unchanged_sync
check 'node resolution includes IPv6 and generates allow/deny policy tests' node_policy
check 'Serve ownership prevents overwrites and preserves unrelated ports' serve_ownership
check 'missing supervised route fails; no-wait remains pending' publication_failure
check 'managed client tokens update; external endpoints retain credentials' client_scope
check 'HTTP token transport, rejection, inference and old-token invalidation' http_auth
check 'SSH node verification keeps token out of argv; failure clears old evidence' verified_access
check 'setup preserves provider credentials, port, main and protection preference' setup_persistence
check 'remote setup configures the target; controller keeps no credentials' remote_setup_target
check 'xAI rejects fallback callback ports; login/logout preserve private permissions' callback_and_permissions
check 'failed migration never restores an anonymous gateway' anonymous_rollback_forbidden
check 'concurrent registry updates keep both routes and release their locks' concurrent_registry
check 'explicit rotation repairs an invalid stored token' invalid_token_repair
printf '%s gateway checks passed\n' "$passed"
