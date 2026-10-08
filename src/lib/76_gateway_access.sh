# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
# Serve exposes a service; only the tailnet policy restricts source nodes.
gateway_access_status() {
  local config dns port state
  config=$(gateway_load_config)
  port=$(printf '%s\n' "$config" | jq -r '.access.port // 8443')
  state=$(printf '%s\n' "$config" | jq -r 'if .access.enabled then (if .access.policy_status=="verified" then "verified" else "policy-verification-pending" end) else "local-only" end')
  printf 'Private access: %s\n' "$state"
  if [[ "$state" != local-only ]] && command -v tailscale >/dev/null 2>&1; then
    dns=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // "" | rtrimstr(".")')
    [[ -z "$dns" ]] || printf 'Private API: https://%s:%s/v1\n' "$dns" "$port"
  fi
}
gateway_access_nodes() {
  tailscale status --json | jq -r '([.Self] + [.Peer[]?])[] | [.HostName,.DNSName,(.TailscaleIPs|join(",")),(.Online|tostring)] | @tsv'
}
gateway_access_allow() {
  local requested_port=''
  if [[ "${1:-}" == --port ]]; then [[ $# -ge 3 ]] || return 1; requested_port="$2"; shift 2; fi
  [[ $# -gt 0 ]] || { err 'Usage: spark gateway access allow [--port 8443] <node-name|IP> ...'; return 1; }
  [[ -z "$requested_port" ]] || { [[ "$requested_port" =~ ^[0-9]+$ && "$requested_port" -gt 1024 && "$requested_port" -le 65535 ]] || return 1; }
  local status selector matches count ips='[]' names_json='[]' config
  status=$(tailscale status --json) || return 1
  for selector in "$@"; do
    matches=$(printf '%s\n' "$status" | jq --arg s "$selector" '[([.Self] + [.Peer[]?])[] | select(.HostName==$s or ((.DNSName // "")|rtrimstr("."))==$s or ((.DNSName // "")|split(".")[0])==$s or any(.TailscaleIPs[]?; .==$s))]') || return 1
    count=$(printf '%s\n' "$matches" | jq length)
    [[ "$count" == 1 ]] || { err "Node must resolve uniquely: ${selector}"; return 1; }
    ips=$(jq -nc --argjson a "$ips" --argjson m "$matches" '$a + $m[0].TailscaleIPs | unique') || return 1
    names_json=$(printf '%s\n' "$names_json" | jq --arg name "$selector" '. + [$name]') || return 1
  done
  config=$(gateway_load_config)
  if [[ -n "$requested_port" ]]; then
    if [[ "$(printf '%s\n' "$config" | jq -r '.access.enabled // false')" == true && "$(printf '%s\n' "$config" | jq -r '.access.port // 8443')" != "$requested_port" ]]; then err 'Disable the current publication before changing its port'; return 1; fi
    config=$(printf '%s\n' "$config" | jq --argjson port "$requested_port" '.access.port=$port') || return 1
  fi
  config=$(printf '%s\n' "$config" | jq --argjson ips "$ips" --argjson names "$names_json" '.access.sources=$ips | .access.nodes=$names | .access.policy_status="pending" | del(.access.verified_at)') || return 1
  gateway_save_config "$config" || return 1
  info 'Selected source nodes; apply the grants fragment in Tailscale before enabling access'
  gateway_access_policy
}
gateway_access_policy() {
  local status config addresses sources port tests output
  status=$(tailscale status --json) || return 1
  config=$(gateway_load_config)
  addresses=$(printf '%s\n' "$status" | jq -c '.Self.TailscaleIPs') || return 1
  sources=$(printf '%s\n' "$config" | jq -c '.access.sources // []')
  [[ "$(printf '%s\n' "$sources" | jq length)" -gt 0 ]] || { err 'Select nodes with spark gateway access allow first'; return 1; }
  port=$(printf '%s\n' "$config" | jq -r '.access.port // 8443')
  tests=$(jq -nc --argjson status "$status" --argjson sources "$sources" --argjson dst "$addresses" --arg port "$port" '
    [ $sources[] | {src:.,accept:[$dst[0]+":"+$port]} ] +
    [ $status.Peer[]?.TailscaleIPs[0] | select(. as $ip | $sources | index($ip) | not) | {src:.,deny:[$dst[0]+":"+$port]} ]') || return 1
  output=$(jq -n --argjson src "$sources" --argjson dst "$addresses" --arg port "$port" --argjson tests "$tests" '{grants:[{src:$src,dst:$dst,ip:["tcp:"+$port]}],tests:$tests}') || return 1
  printf '%s\n' "$output"
  printf 'Merge this fragment in the Tailscale admin policy; remove overlapping broad grants/ACLs for this destination/port. Preserve SSH and other services. Run these tests there, then probe from allowed and denied nodes. Source list is a snapshot; refresh it after replacing a node.\n' >&2
}
gateway_access_enable() {
  local port config status dns serve
  config=$(gateway_load_config) || return 1
  port=$(printf '%s\n' "$config" | jq -r '.access.port // 8443')
  if [[ $# -gt 0 ]]; then [[ $# == 2 && "$1" == --port ]] || return 1; port="$2"; fi
  [[ "$port" =~ ^[0-9]+$ && "$port" -gt 1024 && "$port" -le 65535 ]] || { err 'Use an unprivileged HTTPS port (default 8443)'; return 1; }
  [[ "$port" == "$(printf '%s\n' "$config" | jq -r '.access.port // 8443')" ]] || { err 'Generate the policy for this port first: spark gateway access allow --port PORT NODE...'; return 1; }
  gateway_auth_ready && gateway_wait_ready || { err 'Start an authenticated gateway first'; return 1; }
  config=$(gateway_load_config)
  [[ "$(printf '%s\n' "$config" | jq '.access.sources // [] | length')" -gt 0 ]] || { err 'Select nodes and apply their Tailscale policy first'; return 1; }
  tailscale_funnel_status_active && { err 'Funnel active; resolve public exposure before enabling private gateway access'; return 1; }
  status=$(tailscale status --json) || return 1
  dns=$(printf '%s\n' "$status" | jq -r '.Self.DNSName | rtrimstr(".")')
  [[ -n "$dns" ]] || return 1
  serve=$(tailscale serve status --json) || return 1
  # Do not overwrite another service, any subpath, or a TCP forwarder.
  if ! printf '%s\n' "$serve" | jq -e --arg key "$dns:$port" --arg port "$port" --arg target "http://127.0.0.1:$(gateway_configured_port)" '
    ((.TCP[$port] == null) and (.Web[$key] == null)) or
    (.TCP[$port].HTTPS == true and (.Web[$key].Handlers | keys)==["/"] and .Web[$key].Handlers["/"].Proxy==$target)' >/dev/null; then
    err "Tailscale port ${port} belongs to another service"; return 1
  fi
  tailscale serve --bg --https="$port" "http://127.0.0.1:$(gateway_configured_port)" || return 1
  tailscale_funnel_status_active && { tailscale serve --https="$port" off; err 'Public exposure detected'; return 1; }
  config=$(printf '%s\n' "$config" | jq --argjson port "$port" '.access.enabled=true | .access.port=$port | .access.policy_status="pending" | del(.access.verified_at)') || return 1
  gateway_save_config "$config" || return 1
  gateway_access_status
}
gateway_access_disable() {
  local config port status dns key
  config=$(gateway_load_config); port=$(printf '%s\n' "$config" | jq -r '.access.port // 8443')
  status=$(tailscale status --json) || return 1
  dns=$(printf '%s\n' "$status" | jq -r '.Self.DNSName | rtrimstr(".")'); key="$dns:$port"
  # Only remove the exact root handler owned by Spark, never reset all Serve.
  tailscale serve status --json | jq -e --arg key "$key" --arg target "http://127.0.0.1:$(gateway_configured_port)" '(.Web[$key].Handlers // {}) | keys==["/"] and .["/"].Proxy==$target' >/dev/null || { err 'Serve entry absent or owned by another service'; return 1; }
  tailscale serve --https="$port" off || return 1
  gateway_save_config "$(printf '%s\n' "$config" | jq '.access.enabled=false')"
}
gateway_access_protect() {
  local config status entry target dns port count=0 name model backend_port rest
  config=$(gateway_load_config)
  gateway_wait_ready && [[ "$(printf '%s\n' "$config" | jq -r '.access.enabled and (.access.policy_status=="verified")')" == true ]] || { err 'Verify private gateway access before removing legacy direct Serve routes'; return 1; }
  gateway_save_config "$(printf '%s\n' "$config" | jq '.protected=true')" || return 1
  # Protect new launches. Existing backends need an explicit restart with their
  # launch aliases; do not silently interrupt inference or rewrite recipes.
  printf 'New vLLM launches bind localhost. Existing models need restarting with their launch aliases.\n'
  if command -v tailscale >/dev/null 2>&1; then
    status=$(tailscale serve status --json) || return 1
    while IFS=$'\t' read -r name model backend_port rest; do
      [[ -n "$backend_port" ]] || continue
      while IFS= read -r entry; do
        target=$(printf '%s\n' "$entry" | jq -r '.target')
        port=$(printf '%s\n' "$entry" | jq -r '.port')
        [[ "$port" =~ ^[0-9]+$ ]] || return 1
        if [[ "$target" == "http://127.0.0.1:$backend_port" || "$target" == "http://localhost:$backend_port" ]]; then
          tailscale serve --https="$port" off || return 1
          count=$((count+1))
        fi
      done < <(printf '%s\n' "$status" | jq -c '.Web // {} | to_entries[] | select(.value.Handlers | keys==["/"]) | {port:(.key|split(":")|last),target:.value.Handlers["/"].Proxy}')
    done < <(list_managed_containers)
  fi
  printf 'Removed %s direct backend Serve entries. Enable the private gateway after applying its policy.\n' "$count"
}
gateway_access_probe() {
  local url="${1:-}" kind="${2:-allowed}" key code
  [[ "$url" == https://* && "$url" != *$'\n'* ]] || return 1
  case "$kind" in
    denied)
      # Any HTTP response proves network reachability, including a 401.
      if curl -sS --connect-timeout 3 --max-time 5 -o /dev/null "$url/models"; then
        err 'Denied-node test failed: endpoint reachable'; return 1
      fi
      printf 'Network probe: unreachable (also check node connectivity; this alone does not prove the policy)\n' ;;
    allowed)
      local token_file="${SPARK_GATEWAY_TOKEN_FILE:-$(gateway_secrets_path)}"
      key=$(gateway_env_get LITELLM_MASTER_KEY "$token_file") || { err 'Set SPARK_GATEWAY_TOKEN_FILE to a private env file containing LITELLM_MASTER_KEY'; return 1; }
      [[ "$key" =~ ^sk-[a-f0-9]{64}$ ]] || return 1
      code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$url/models") || return 1
      [[ "$code" == 401 || "$code" == 403 ]] || { err 'Anonymous access accepted'; return 1; }
      code=$(printf 'header = "Authorization: Bearer sk-invalid"\n' | curl --config - -sS --max-time 5 -o /dev/null -w '%{http_code}' "$url/models") || return 1
      [[ "$code" == 401 || "$code" == 403 ]] || return 1
      printf 'header = "Authorization: Bearer %s"\n' "$key" | curl --config - -fsS --max-time 5 -o /dev/null "$url/models" || return 1
      printf 'Allowed-node probe passed: token required and accepted\n' ;;
    *) return 1 ;;
  esac
}
gateway_access_command() {
  local sub="${1:-status}"; [[ $# == 0 ]] || shift
  case "$sub" in
    nodes) gateway_access_nodes ;; status) gateway_access_status ;;
    allow) gateway_with_lock gateway_access_allow "$@" ;; policy) gateway_access_policy ;;
    enable) gateway_with_lock gateway_access_enable "$@" ;; disable) gateway_with_lock gateway_access_disable ;;
    protect) gateway_with_lock gateway_access_protect ;; probe) gateway_access_probe "$@" ;; verify) gateway_with_lock gateway_access_verify "$@" ;;
    *) err 'Usage: spark gateway access <nodes|allow NODE...|policy|enable [--port 8443]|disable|status|protect|probe URL [allowed|denied]|verify --allowed NODE --denied NODE>'; return 1 ;;
  esac
}

gateway_access_json() {
  gateway_load_config | jq -c '{enabled:(.access.enabled // false),port:(.access.port // 8443),policy_status:(.access.policy_status // "not-configured"),verified_at:(.access.verified_at // null),nodes:(.access.nodes // []),protected:(.protected != false)}'
}
# Read-only evidence; configuration alone does not prove backend isolation.
gateway_exposure_findings() {
  local name model port rest listeners serve
  command -v ss >/dev/null 2>&1 || return 0
  listeners=$(ss -H -lnt 2>/dev/null) || return 0
  serve=$(tailscale serve status --json 2>/dev/null || printf '{}')
  while IFS=$'\t' read -r _name model port rest; do
    [[ -n "$port" ]] || continue
    if printf '%s\n' "$listeners" | awk -v port="$port" '$4 ~ ("^(0\\.0\\.0\\.0|\\*|\\[::\\]|::):" port "$") {found=1} END{exit !found}'; then
      printf 'Backend %s listens on all interfaces (%s)\n' "$model" "$port"
    fi
    if printf '%s\n' "$serve" | jq -e --arg a "http://127.0.0.1:$port" --arg b "http://localhost:$port" '[.Web[]?.Handlers[]?.Proxy | select(.==$a or .==$b)] | length>0' >/dev/null; then
      printf 'Tailscale Serve publishes backend %s directly (%s)\n' "$model" "$port"
    fi
  done < <(list_managed_containers)
}

# SSH probes establish evidence from two live nodes without storing the token there.
gateway_access_verify() {
  local allowed='' denied='' config status dns port key mode node selector matches ips selected script quoted payload
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --allowed) [[ $# -ge 2 ]] || return 1; allowed="$2"; shift 2 ;;
      --denied) [[ $# -ge 2 ]] || return 1; denied="$2"; shift 2 ;;
      *) return 1 ;;
    esac
  done
  [[ -n "$allowed" && -n "$denied" && "$allowed" != "$denied" ]] || { err 'Usage: spark gateway access verify --allowed [user@]NODE --denied [user@]NODE (SSH and Python 3 required)'; return 1; }
  config=$(gateway_load_config) || return 1
  [[ "$(printf '%s\n' "$config" | jq -r '.access.enabled // false')" == true ]] || return 1
  config=$(printf '%s\n' "$config" | jq '.access.policy_status="pending" | del(.access.verified_at)') || return 1
  gateway_save_config "$config" || return 1
  gateway_wait_ready || return 1
  status=$(tailscale status --json) || return 1
  dns=$(printf '%s\n' "$status" | jq -r '.Self.DNSName | rtrimstr(".")')
  port=$(printf '%s\n' "$config" | jq -r '.access.port // 8443')
  key=$(gateway_auth_key) || return 1
  script=$(cat <<'PY'
import json, socket, ssl, sys, urllib.request, urllib.error, urllib.parse
p=json.load(sys.stdin)
u=p['url']+'/models'
# Distinguish unresolved DNS from policy evidence.
socket.getaddrinfo(urllib.parse.urlparse(u).hostname, None)
def status(token=None):
    headers={} if token is None else {'Authorization':'Bearer '+token}
    try:
        with urllib.request.urlopen(urllib.request.Request(u,headers=headers),timeout=5) as r:
            return r.status
    except urllib.error.HTTPError as e: return e.code
if p['mode']=='allowed':
    assert status() in (401,403), 'anonymous access accepted'
    assert status('sk-invalid') in (401,403), 'invalid token accepted'
    assert status(p['token'])==200, 'valid token rejected'
else:
    try: status()
    except urllib.error.URLError as e:
        if isinstance(e.reason, ssl.SSLError) or not isinstance(e.reason, (TimeoutError,ConnectionError,OSError)):
            raise
    else: raise RuntimeError('denied node can reach the endpoint')
print(p['mode']+' node probe passed')
PY
  ) || return 1
  # POSIX single quoting, including any literal single quotes in the Python source.
  quoted="'${script//\'/\'\\\'\'}'"
  for mode in allowed denied; do
    [[ "$mode" == allowed ]] && node="$allowed" || node="$denied"
    selector="${node##*@}"
    [[ "$node" != -* && "$node" != *$'\n'* && "$node" != *$'\r'* ]] || return 1
    matches=$(printf '%s\n' "$status" | jq --arg s "$selector" '[.Peer[]? | select(.HostName==$s or ((.DNSName // "")|rtrimstr("."))==$s or any(.TailscaleIPs[]?; .==$s))]') || return 1
    [[ "$(printf '%s\n' "$matches" | jq length)" == 1 ]] || { err "Probe node must resolve uniquely: $selector"; return 1; }
    ips=$(printf '%s\n' "$matches" | jq -c '.[0].TailscaleIPs')
    selected=$(printf '%s\n' "$config" | jq -r --argjson ips "$ips" 'any(.access.sources[]; . as $s | $ips | index($s)!=null)')
    [[ "$mode" == allowed && "$selected" == true || "$mode" == denied && "$selected" == false ]] || { err 'Probe nodes do not match the selected policy'; return 1; }
    payload=$(jq -nc --arg url "https://$dns:$port/v1" --arg mode "$mode" '{url:$url,mode:$mode}') || return 1
    if [[ "$mode" == allowed ]]; then payload="${payload%\}},\"token\":\"${key}\"}"; fi
    printf '%s\n' "$payload" | ssh -o BatchMode=yes -o ConnectTimeout=5 "$node" "python3 -c $quoted" || { err "${mode} node verification failed; policy remains pending"; return 1; }
  done
  config=$(printf '%s\n' "$config" | jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.access.policy_status="verified" | .access.verified_at=$now') || return 1
  gateway_save_config "$config" && gateway_access_status
}
