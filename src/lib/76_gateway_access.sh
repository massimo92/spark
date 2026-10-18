# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
# Serve exposes a service; only the tailnet policy restricts source nodes.
gateway_access_status() {
  local config dns port state
  config=$(gateway_load_config)
  port=$(printf '%s\n' "$config" | jq -r '.access.port // 443')
  state=$(printf '%s\n' "$config" | jq -r 'if .access.enabled and .access.port!=443 then "migration-required" elif .access.enabled then (if .access.policy_status=="verified" then "verified" else "policy-verification-pending" end) else "local-only" end')
  printf 'Private access: %s\n' "$state"
  if [[ "$state" != local-only ]] && command -v tailscale >/dev/null 2>&1; then
    dns=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // "" | rtrimstr(".")')
    [[ -z "$dns" ]] || printf 'Private API: https://%s%s/v1\n' "$dns" "$([[ "$port" == 443 ]] || printf ':%s' "$port")"
  fi
}
gateway_access_nodes() {
  tailscale status --json | jq -r '([.Self] + [.Peer[]?])[] | [.HostName,.DNSName,(.TailscaleIPs|join(",")),(.Online|tostring)] | @tsv'
}
gateway_access_allow() {
  local ssh_port
  ssh_port=$(gateway_access_ssh_port) || return 1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --port) [[ $# -ge 2 && "$2" == 443 ]] || { err 'The private API uses HTTPS port 443 only'; return 1; }; shift 2 ;;
      --ssh-port) [[ $# -ge 2 ]] || return 1; ssh_port="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  [[ "$ssh_port" =~ ^[0-9]+$ && "$ssh_port" -ge 1 && "$ssh_port" -le 65535 && "$ssh_port" != 443 ]] || return 1
  [[ $# -gt 0 ]] || { err 'Usage: spark gateway access allow [--ssh-port 22] <node-name|IP> ...'; return 1; }
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
  config=$(printf '%s\n' "$config" | jq --argjson ips "$ips" --argjson names "$names_json" --argjson ssh "$ssh_port" '
    if .access.port!=null and .access.port!=443 then .access.enabled=false else . end |
    .access.port=443 | .access.ssh_port=$ssh | .access.sources=$ips | .access.nodes=$names |
    .access.policy_status="pending" | del(.access.verified_at)') || return 1
  gateway_save_config "$config" || return 1
  info 'Selected source nodes; apply the grants fragment in Tailscale before enabling access'
  gateway_access_policy
}
gateway_access_policy() {
  local status config addresses sources ssh_port blocked output
  status=$(tailscale status --json) || return 1
  config=$(gateway_load_config) || return 1
  addresses=$(printf '%s\n' "$status" | jq -c '.Self.TailscaleIPs') || return 1
  sources=$(printf '%s\n' "$config" | jq -c '.access.sources // []') || return 1
  [[ "$(printf '%s\n' "$sources" | jq length)" -gt 0 ]] || { err 'Select nodes with spark gateway access allow first'; return 1; }
  ssh_port=$(gateway_access_ssh_port) || return 1
  blocked=$(gateway_access_blocked_ports) || return 1
  output=$(jq -n --argjson src "$sources" --argjson dst "$addresses" --argjson ssh "$ssh_port" --argjson blocked "$blocked" --argjson status "$status" '
    def host: if contains(":") then "["+.+"]" else . end;
    def destinations($ports): [$dst[] | host as $h | $ports[] | $h+":"+(.|tostring)];
    {grants:[{src:$src,dst:$dst,ip:["tcp:443"]},{src:$src,dst:$dst,ip:["tcp:"+($ssh|tostring)]}],
     tests:([$src[] | {src:.,proto:"tcp",accept:destinations([443,$ssh]),deny:destinations($blocked)}] +
            [$src[] | {src:.,proto:"udp",deny:destinations(($blocked+[443,$ssh])|unique)}] +
            [$status.Peer[]?.TailscaleIPs[] | select(. as $ip | $src | index($ip) | not) | {src:.,proto:"tcp",deny:destinations([443])}])}') || return 1
  printf '%s\n' "$output"
  printf 'Merge these grants and tests in the tailnet admin policy. Keep administrative SSH/key authentication. Remove overlapping broad API grants for these clients: only TCP/443 (LiteLLM) and TCP/%s (SSH) should remain reachable on this node. Other administrators keep their SSH rules. Tests cover both IP families and current/common service ports; refresh after adding listeners or replacing a node.\n' "$ssh_port" >&2
}
gateway_access_enable() {
  local config status dns serve key target current port
  [[ $# == 0 || ( $# == 2 && "$1" == --port && "$2" == 443 ) ]] || { err 'The private API uses HTTPS port 443 only'; return 1; }
  gateway_auth_ready && gateway_wait_ready || { err 'Start an authenticated gateway first'; return 1; }
  config=$(gateway_load_config) || return 1
  tailscale_funnel_status_active && { err 'Funnel active; resolve public exposure before enabling private gateway access'; return 1; }
  status=$(tailscale status --json) || return 1
  dns=$(printf '%s\n' "$status" | jq -r '.Self.DNSName // "" | rtrimstr(".")')
  [[ -n "$dns" ]] || return 1
  key="$dns:443"; target="http://127.0.0.1:$(gateway_configured_port)"
  serve=$(tailscale serve status --json) || return 1
  if ! printf '%s\n' "$serve" | jq -e --arg key "$key" '(.TCP["443"]==null and .Web[$key]==null)' >/dev/null; then
    printf '%s\n' "$serve" | jq -e --arg key "$key" '.TCP["443"].HTTPS==true and ((.Web[$key].Handlers // {})|keys)==["/"]' >/dev/null || { err 'Port 443 has another handler or TCP service; no services changed'; return 1; }
    current=$(printf '%s\n' "$serve" | jq -r --arg key "$key" '.Web[$key].Handlers["/"].Proxy // ""')
    gateway_access_owned_target "$current" || { err 'Port 443 belongs to another service; no services changed'; return 1; }
  fi
  tailscale serve --bg --https=443 "$target" || return 1
  tailscale_funnel_status_active && { tailscale serve --https=443 off; err 'Public exposure detected'; return 1; }
  config=$(printf '%s\n' "$config" | jq --argjson ssh "$(gateway_access_ssh_port)" '.access.enabled=true | .access.port=443 | .access.ssh_port=$ssh | .protected=true | .access.policy_status="pending" | del(.access.verified_at)') || return 1
  gateway_save_config "$config" || return 1
  gateway_access_https_ready "$dns" || { err 'HTTPS 443 not ready; authenticated target kept, policy verification pending'; return 1; }
  # Retire only Spark API/backends on this hostname; never reset Serve or touch SSH.
  gateway_access_remove_direct "$dns" "$serve" || return 1
  info 'Node access follows your Tailscale ACL/grants; Spark does not change the tailnet policy'
  gateway_access_status
}
gateway_access_disable() {
  local config port status dns key
  config=$(gateway_load_config); port=$(printf '%s\n' "$config" | jq -r '.access.port // 443')
  status=$(tailscale status --json) || return 1
  dns=$(printf '%s\n' "$status" | jq -r '.Self.DNSName | rtrimstr(".")'); key="$dns:$port"
  # Only remove the exact root handler owned by Spark, never reset all Serve.
  tailscale serve status --json | jq -e --arg key "$key" --arg target "http://127.0.0.1:$(gateway_configured_port)" '(.Web[$key].Handlers // {}) | keys==["/"] and .["/"].Proxy==$target' >/dev/null || { err 'Serve entry absent or owned by another service'; return 1; }
  tailscale serve --https="$port" off || return 1
  gateway_save_config "$(printf '%s\n' "$config" | jq '.access.enabled=false')"
}
gateway_access_protect() {
  local config status dns
  config=$(gateway_load_config)
  gateway_wait_ready && [[ "$(printf '%s\n' "$config" | jq -r '.access.enabled and (.access.policy_status=="verified")')" == true ]] || { err 'Verify private gateway access before removing legacy direct Serve routes'; return 1; }
  gateway_save_config "$(printf '%s\n' "$config" | jq '.protected=true')" || return 1
  status=$(tailscale status --json) || return 1
  dns=$(printf '%s\n' "$status" | jq -r '.Self.DNSName // "" | rtrimstr(".")')
  gateway_access_remove_direct "$dns" "$(tailscale serve status --json)" || return 1
  local findings
  findings=$(gateway_exposure_findings)
  if [[ -n "$findings" ]]; then
    err 'Existing inference listeners still accept non-local connections; restart those model aliases to apply localhost binding'
    printf '%s\n' "$findings" >&2; return 1
  fi
  printf 'Inference APIs are local; node clients use HTTPS/443. Administrative SSH is unchanged.\n'

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
      key=$(gateway_env_get LITELLM_API_KEY "$token_file" 2>/dev/null || gateway_env_get LITELLM_MASTER_KEY "$token_file") || { err 'Set SPARK_GATEWAY_TOKEN_FILE to a private client env file containing LITELLM_API_KEY'; return 1; }
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
    *) err 'Usage: spark gateway access <nodes|allow NODE...|policy|enable [--port 443]|disable|status|protect|probe URL [allowed|denied]|verify --allowed NODE --denied NODE>'; return 1 ;;
  esac
}

gateway_access_json() {
  gateway_load_config | jq -c '{enabled:(.access.enabled // false),port:(.access.port // 443),ssh_port:(.access.ssh_port // 22),policy_status:(.access.policy_status // "not-configured"),verified_at:(.access.verified_at // null),nodes:(.access.nodes // []),protected:(.protected != false)}'
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
gateway_access_verify() (
  local allowed='' denied='' config status dns port key mode node selector matches ips selected script quoted payload blocked addresses ssh_port
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
  [[ "$(printf '%s\n' "$config" | jq -r '.access.port // 443')" == 443 ]] || { err 'Migrate the private API to HTTPS/443 first'; return 1; }
  status=$(tailscale status --json) || return 1
  dns=$(printf '%s\n' "$status" | jq -r '.Self.DNSName | rtrimstr(".")')
  port=$(printf '%s\n' "$config" | jq -r '.access.port // 443')
  key="sk-$(openssl rand -hex 32)" || return 1
  gateway_virtual_create spark-managed "$key" 5m || return 1
  local probe_hash
  probe_hash=$(gateway_key_hash "$key") || return 1
  # Capture the validated hash before local function scope unwinds at EXIT.
  # shellcheck disable=SC2064
  trap "printf '%s' '{\"keys\":[\"$probe_hash\"]}' | gateway_admin_post /key/delete >/dev/null 2>&1 || true" EXIT
  blocked=$(gateway_access_blocked_ports) || return 1
  addresses=$(printf '%s\n' "$status" | jq -c '.Self.TailscaleIPs // []') || return 1
  [[ "$(printf '%s\n' "$addresses" | jq length)" -gt 0 ]] || return 1
  ssh_port=$(gateway_access_ssh_port) || return 1
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
    # A reachable backend or other application would bypass the single API entry.
    for address in p['addresses']:
        for port in p['blocked_ports']:
            try:
                connection=socket.create_connection((address,port),timeout=1)
            except OSError:
                continue
            connection.close()
            raise RuntimeError('Direct application port is reachable: '+str(port))
else:
    for address in p['addresses']:
        try:
            connection=socket.create_connection((address,443),timeout=3)
        except OSError:
            continue
        connection.close()
        raise RuntimeError('denied node can connect to HTTPS/443')
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
    payload=$(jq -nc --arg url "https://$dns/v1" --arg mode "$mode" --argjson blocked "$blocked" --argjson addresses "$addresses" '{url:$url,mode:$mode,blocked_ports:$blocked,addresses:$addresses}') || return 1
    if [[ "$mode" == allowed ]]; then payload="${payload%\}},\"token\":\"${key}\"}"; fi
    printf '%s\n' "$payload" | ssh -o BatchMode=yes -o ClearAllForwardings=yes -o ForwardAgent=no -o ConnectTimeout=5 "$node" "python3 -c $quoted" || { err "${mode} node verification failed; policy remains pending"; return 1; }
  done
  config=$(printf '%s\n' "$config" | jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.access.policy_status="verified" | .access.verified_at=$now') || return 1
  gateway_save_config "$config" && gateway_access_status
)

gateway_access_ssh_port() {
  local port
  port=$(gateway_load_config | jq -r '.access.ssh_port // ""') || return 1
  if [[ -z "$port" && -n "${SSH_CONNECTION:-}" ]]; then port="${SSH_CONNECTION##* }"; fi
  port="${port:-22}"
  [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 && "$port" != 443 ]] || return 1
  printf '%s\n' "$port"
}
gateway_access_blocked_ports() {
  local ssh_port
  ssh_port=$(gateway_access_ssh_port) || return 1
  {
    printf '%s\n' 80 4000 8000 8001 8443 11434 3456 5678 8787 18789
    gateway_configured_port
    list_managed_containers 2>/dev/null | awk -F '\t' '{print $3}' || true
    tailscale serve status --json 2>/dev/null | jq -r '.TCP // {} | keys[]' || true
    if command -v ss >/dev/null 2>&1; then ss -H -lnt 2>/dev/null | awk '{n=$4;sub(/^.*:/,"",n);print n}' || true; fi
  } | jq -Rn --argjson ssh "$ssh_port" '[inputs|tonumber? | select(.>=1 and .<=65535 and .!=443 and .!=$ssh)]|unique'
}
gateway_access_owned_target() {
  local target="${1%/}" name model port rest
  [[ "$target" != "http://127.0.0.1:$(gateway_configured_port)" && "$target" != "http://localhost:$(gateway_configured_port)" && "$target" != http://127.0.0.1:11434 && "$target" != http://localhost:11434 ]] || return 0
  while IFS=$'\t' read -r name model port rest; do
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    [[ "$target" != "http://127.0.0.1:$port" && "$target" != "http://localhost:$port" ]] || return 0
  done < <(list_managed_containers)
  return 1
}
gateway_access_remove_direct() {
  local dns="$1" serve="$2" entry port target ssh_port
  ssh_port=$(gateway_access_ssh_port) || return 1
  while IFS= read -r entry; do
    port=$(printf '%s\n' "$entry" | jq -r '.port')
    target=$(printf '%s\n' "$entry" | jq -r '.target // ""')
    [[ "$port" =~ ^[0-9]+$ && "$port" != 443 && "$port" != "$ssh_port" ]] || continue
    if gateway_access_owned_target "$target"; then tailscale serve --https="$port" off || return 1; fi
  done < <(printf '%s\n' "$serve" | jq -c --arg dns "$dns" '.Web // {} | to_entries[] | select(.key|startswith($dns+":")) | select((.value.Handlers // {}|keys)==["/"]) | {port:(.key|split(":")|last),target:.value.Handlers["/"].Proxy}')
}
gateway_access_https_ready() {
  local dns="$1" attempt
  for ((attempt=0; attempt<5; attempt++)); do
    gateway_curl -fsS --connect-timeout 2 --max-time 5 "https://$dns/v1/models" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
