#!/usr/bin/env bash
# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
# Docker: real LiteLLM/PostgreSQL, deterministic local OpenAI-compatible backends.
set -euo pipefail
export SPARK_GATEWAY_READY_ATTEMPTS=90
ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v python3 >/dev/null && docker info >/dev/null 2>&1
TEST_ROOT=$(mktemp -d "${SPARK_INTEGRATION_TMPDIR:-/tmp}/spark-gateway.XXXXXX")
backend_pid=''
cleanup() {
  if [[ "$?" != 0 ]]; then docker logs "${GATEWAY_CONTAINER:-spark-test-litellm-$$}" > /tmp/spark-litellm-integration-failure.log 2>&1 || true; fi
  docker rm -f "${GATEWAY_CONTAINER:-spark-test-litellm-$$}" >/dev/null 2>&1 || true
  docker rm -f "${GATEWAY_CONTAINER:-spark-test-litellm-$$}-db" >/dev/null 2>&1 || true
  docker volume rm "${GATEWAY_CONTAINER:-spark-test-litellm-$$}-db-data" "${GATEWAY_CONTAINER:-spark-test-litellm-$$}-db-socket" >/dev/null 2>&1 || true
  [[ -z "$backend_pid" ]] || kill "$backend_pid" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
export HOME="$TEST_ROOT/home" SPARK_BACKEND=vllm SPARK_ACCEL=cpu
mkdir -p "$HOME"
source "$ROOT/spark"
# On macOS stand-ins run on the host; the gateway reaches them through Docker.
if [[ "$SPARK_OS" == Darwin ]]; then
  eval "$(declare -f gateway_generate_litellm_yaml | sed '1s/gateway_generate_litellm_yaml/gateway_test_generate_yaml/')"
  gateway_generate_litellm_yaml() { gateway_test_generate_yaml | sed 's#http://localhost:#http://host.docker.internal:#g'; }
fi
GATEWAY_CONTAINER="spark-test-litellm-$$"
LITELLM_IMAGE="${SPARK_LITELLM_TEST_IMAGE:-$LITELLM_IMAGE}"
# Use two independent upstream ports; LiteLLM must route each model correctly.
cat > "$TEST_ROOT/backend.py" <<'PY'
import json, sys, threading, platform
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class Backend(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        self.respond({"object":"list","data":[{"id":self.server.model,"object":"model","owned_by":"spark-test"}]})
    def do_POST(self):
        request=json.loads(self.rfile.read(int(self.headers.get("Content-Length",0))))
        if request.get("model") != self.server.model:
            self.respond({"error":{"message":"wrong upstream model"}},400); return
        if self.server.model == "Test/Decision":
            if self.path != "/v1/systemone":
                self.respond({"error":{"message":"wrong decision endpoint"}},400); return
            answers={}
            for name,question in request["questions"].items():
                kind=question["type"]
                if kind=="noul": answers[name]={"type":kind,"noul":0.9}
                elif kind=="choice":
                    options=list(question["criteria"])
                    answers[name]={"type":kind,"choice":options[0],"confidence":0.8,
                        "probabilities":{v:(0.9 if i==0 else 0.1/(len(options)-1)) for i,v in enumerate(options)}}
                else: answers[name]={"type":kind,"score":0.8,"confidence":0.6,
                        "legend":{"0":"blocked","1":"done"},"probabilities":{"0":0.2,"1":0.8}}
            self.respond({"model":self.server.model,"answers":answers,"usage":{"input_tokens":20,"output_tokens":0}})
            return
        self.respond({"id":"chatcmpl-test","object":"chat.completion","created":1,"model":self.server.model,
          "choices":[{"index":0,"message":{"role":"assistant","content":self.server.model},"finish_reason":"stop"}],
          "usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}})
    def respond(self, body, status=200):
        data=json.dumps(body).encode(); self.send_response(status)
        self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(data)))
        self.end_headers(); self.wfile.write(data)
servers=[]
for model in ("Test/Alpha","Test/Beta","Test/Decision"):
    bind="0.0.0.0" if platform.system()=="Darwin" else "127.0.0.1"
    server=ThreadingHTTPServer((bind,0),Backend); server.model=model; servers.append(server)
    threading.Thread(target=server.serve_forever,daemon=True).start()
with open(sys.argv[1],"w") as f: json.dump([s.server_address[1] for s in servers],f)
threading.Event().wait()
PY
python3 "$TEST_ROOT/backend.py" "$TEST_ROOT/ports.json" & backend_pid=$!
for ((attempt=0; attempt<30; attempt++)); do [[ ! -s "$TEST_ROOT/ports.json" ]] || break; sleep 0.1; done
alpha=$(jq -r '.[0]' "$TEST_ROOT/ports.json"); beta=$(jq -r '.[1]' "$TEST_ROOT/ports.json")
decision=$(jq -r '.[2]' "$TEST_ROOT/ports.json")
proxy_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
list_managed_containers() { printf 'alpha\tTest/Alpha\t%s\nbeta\tTest/Beta\t%s\ndecision\tTest/Decision\t%s\n' "$alpha" "$beta" "$decision"; }
model_api_kind() { [[ "$1" != decision ]] && printf chat || printf systemone; }
gateway_save_config "$(jq -nc --argjson port "$proxy_port" '{enabled:true,protected:true,port:$port,providers:{vllm:{enabled:true},openai:{enabled:false,api_key:"unused-test-key"}},main:{provider:"vllm",model:"Test/Beta"}}')"
gateway_auth_terminal() { return 0; }
gateway_auth_present_new() { printf '%s\n' "$1" >&3; }
gateway_start 3> "$TEST_ROOT/client.once"
client_token=$(cat "$TEST_ROOT/client.once")
[[ "$client_token" =~ ^sk-[a-f0-9]{64}$ ]]
[[ "$(wc -l < "$TEST_ROOT/client.once")" -eq 1 ]]
! grep -rF "$client_token" "$SPARK_CONFIG_DIR"
[[ "$(gateway_database_client_hashes | jq -r '.[0]')" == "$(gateway_key_hash "$client_token")" ]]
[[ "$(docker inspect "$GATEWAY_CONTAINER" --format '{{json .Config.Env}}')" != *LITELLM_MASTER_KEY=* ]]
gateway_virtual_validate "$client_token"
WORKSPACE_ENV_FILE="$TEST_ROOT/managed-client.env"
touch "$WORKSPACE_ENV_FILE"
managed_token=$(gateway_managed_client_key)
[[ "$managed_token" != "$client_token" && "$managed_token" != "$(gateway_auth_key)" ]]
gateway_virtual_validate "$managed_token"
[[ ! -d "$SPARK_CONFIG_DIR/gateway-migration" ]]
# Real HTTP checks: anonymous/wrong token rejected, correct token accepted.
gateway_wait_ready
gateway_route_smoke vllm Test/Alpha
gateway_route_smoke vllm Test/Beta
gateway_route_smoke systemone Test/Decision
decision_body='{"model":"systemone/Test/Decision","state":{"phase":"validation","tests":"passed"},"questions":{"complete":{"type":"noul","instructions":"Is validation complete?"},"next":{"type":"choice","criteria":{"finish":"all tests passed","continue":"checks remain"}},"progress":{"type":"score","criteria":["blocked","done"]}}}'
decision_response=$({ printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\ndata = %s\n' "$client_token" "$(printf '%s' "$decision_body" | jq -Rs .)"; } | curl --config - -fsS "http://127.0.0.1:$proxy_port/v1/systemone")
jq -e '.answers.complete.noul==0.9 and .answers.next.choice=="finish" and .answers.progress.score==0.8' <<<"$decision_response" >/dev/null
decision_body='{"model":"systemone/Test/Decision","input":"All validation checks passed.","questions":[{"type":"predicate","name":"complete","instructions":"Are all checks complete?"}]}'
decision_response=$({ printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\ndata = %s\n' "$client_token" "$(printf '%s' "$decision_body" | jq -Rs .)"; } | curl --config - -fsS "http://127.0.0.1:$proxy_port/v1/decisions")
jq -e '.answers[0].type=="predicate" and .answers[0].probability==0.9' <<<"$decision_response" >/dev/null
code=$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' --data "$decision_body" "http://127.0.0.1:$proxy_port/v1/decisions")
[[ "$code" == 401 || "$code" == 403 ]]
old="$client_token"
gateway_auth_rotate 3> "$TEST_ROOT/client.once"
client_token=$(cat "$TEST_ROOT/client.once")
[[ "$(wc -l < "$TEST_ROOT/client.once")" -eq 1 ]]
! grep -rF "$client_token" "$SPARK_CONFIG_DIR"
gateway_virtual_validate "$client_token"
[[ "$(gateway_managed_client_key)" == "$managed_token" ]]
code=$(printf 'header = "Authorization: Bearer %s"\n' "$old" | curl --config - -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$proxy_port/v1/models")
[[ "$code" == 401 || "$code" == 403 ]]
gateway_route_smoke vllm Test/Alpha
old="$client_token"
gateway_auth_command rotate 3> "$TEST_ROOT/client.once"
client_token=$(cat "$TEST_ROOT/client.once")
gateway_virtual_validate "$client_token"
[[ "$(gateway_managed_client_key)" == "$managed_token" ]]
code=$(printf 'header = "Authorization: Bearer %s"\n' "$old" | curl --config - -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$proxy_port/v1/models")
[[ "$code" == 401 || "$code" == 403 ]]
gateway_route_smoke vllm Test/Alpha
admin_before=$(gateway_auth_key)
docker restart "$GATEWAY_CONTAINER" >/dev/null
gateway_wait_ready
[[ "$(gateway_auth_key)" != "$admin_before" ]]
gateway_virtual_validate "$client_token"
[[ "$(gateway_managed_client_key)" == "$managed_token" ]]
docker restart "$(gateway_database_name)" >/dev/null
gateway_database_prepare
gateway_wait_ready
gateway_virtual_validate "$client_token"
list_managed_containers() { printf 'alpha\tTest/Alpha\t%s\n' "$alpha"; }
gateway_sync
! gateway_model_routed vllm Test/Beta
! gateway_model_routed systemone Test/Decision
gateway_route_smoke vllm Test/Alpha
jq -e '.main.model=="Test/Beta"' "$GATEWAY_CONFIG" >/dev/null
# Real legacy master -> inference-only virtual-key migration; never redisclose it.
printf '{"keys":%s}' "$(gateway_database_client_hashes)" | gateway_admin_post /key/delete >/dev/null
gateway_env_set LITELLM_MASTER_KEY "$client_token"
gateway_save_config "$(gateway_load_config | jq 'del(.auth)')"
gateway_sync 3> "$TEST_ROOT/client.once"
[[ ! -s "$TEST_ROOT/client.once" ]]
! grep -rF "$client_token" "$SPARK_CONFIG_DIR"
gateway_virtual_validate "$client_token"
# Rotation also recovers a stopped/deleted proxy using only the persisted hashes.
gateway_stop
old="$client_token"
gateway_auth_command rotate 3> "$TEST_ROOT/client.once"
client_token=$(cat "$TEST_ROOT/client.once")
gateway_virtual_validate "$client_token"
! gateway_virtual_validate "$old"
[[ "$(gateway_managed_client_key)" == "$managed_token" ]]
printf 'ok - real LiteLLM: chat and System One routes, both decision formats, authentication, key rotation, restart persistence and route removal\n'
