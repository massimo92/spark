#!/usr/bin/env bash
# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
# Linux + Docker: real LiteLLM, deterministic local OpenAI-compatible backends.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[[ "$(uname -s)" == Linux ]] || { printf 'skip - real LiteLLM integration requires Linux host networking\n'; exit 0; }
command -v python3 >/dev/null && docker info >/dev/null 2>&1
TEST_ROOT=$(mktemp -d)
backend_pid=''
cleanup() {
  docker rm -f "${GATEWAY_CONTAINER:-spark-test-litellm-$$}" >/dev/null 2>&1 || true
  [[ -z "$backend_pid" ]] || kill "$backend_pid" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
export HOME="$TEST_ROOT/home" SPARK_BACKEND=vllm SPARK_ACCEL=cpu
mkdir -p "$HOME"
source "$ROOT/spark"
GATEWAY_CONTAINER="spark-test-litellm-$$"
LITELLM_IMAGE="${SPARK_LITELLM_TEST_IMAGE:-$LITELLM_IMAGE}"
# Use two independent upstream ports; LiteLLM must route each model correctly.
cat > "$TEST_ROOT/backend.py" <<'PY'
import json, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class Backend(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        self.respond({"object":"list","data":[{"id":self.server.model,"object":"model","owned_by":"spark-test"}]})
    def do_POST(self):
        request=json.loads(self.rfile.read(int(self.headers.get("Content-Length",0))))
        if request.get("model") != self.server.model:
            self.respond({"error":{"message":"wrong upstream model"}},400); return
        self.respond({"id":"chatcmpl-test","object":"chat.completion","created":1,"model":self.server.model,
          "choices":[{"index":0,"message":{"role":"assistant","content":self.server.model},"finish_reason":"stop"}],
          "usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}})
    def respond(self, body, status=200):
        data=json.dumps(body).encode(); self.send_response(status)
        self.send_header("Content-Type","application/json"); self.send_header("Content-Length",str(len(data)))
        self.end_headers(); self.wfile.write(data)
servers=[]
for model in ("Test/Alpha","Test/Beta"):
    server=ThreadingHTTPServer(("127.0.0.1",0),Backend); server.model=model; servers.append(server)
    threading.Thread(target=server.serve_forever,daemon=True).start()
with open(sys.argv[1],"w") as f: json.dump([s.server_address[1] for s in servers],f)
threading.Event().wait()
PY
python3 "$TEST_ROOT/backend.py" "$TEST_ROOT/ports.json" & backend_pid=$!
for ((attempt=0; attempt<30; attempt++)); do [[ ! -s "$TEST_ROOT/ports.json" ]] || break; sleep 0.1; done
alpha=$(jq -r '.[0]' "$TEST_ROOT/ports.json"); beta=$(jq -r '.[1]' "$TEST_ROOT/ports.json")
proxy_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
list_managed_containers() { printf 'alpha\tTest/Alpha\t%s\nbeta\tTest/Beta\t%s\n' "$alpha" "$beta"; }
gateway_save_config "$(jq -nc --argjson port "$proxy_port" '{enabled:true,protected:true,port:$port,providers:{vllm:{enabled:true}},main:{provider:"vllm",model:"Test/Beta"}}')"
gateway_start
# Real HTTP checks: anonymous/wrong token rejected, correct token accepted.
gateway_wait_ready
gateway_route_smoke vllm Test/Alpha
gateway_route_smoke vllm Test/Beta
old=$(gateway_auth_key)
gateway_auth_rotate
code=$(printf 'header = "Authorization: Bearer %s"\n' "$old" | curl --config - -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$proxy_port/v1/models")
[[ "$code" == 401 || "$code" == 403 ]]
gateway_route_smoke vllm Test/Alpha
list_managed_containers() { printf 'alpha\tTest/Alpha\t%s\n' "$alpha"; }
gateway_sync
! gateway_model_routed vllm Test/Beta
gateway_route_smoke vllm Test/Alpha
jq -e '.main.model=="Test/Beta"' "$GATEWAY_CONFIG" >/dev/null
printf 'ok - real LiteLLM: authenticated inference, two upstream ports, rotation, route removal\n'
