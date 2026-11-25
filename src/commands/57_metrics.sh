# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
# --- Metrics endpoint: read-only JSON for instances and their vLLM metrics ---
# A python3 stdlib server bound to 127.0.0.1, supervised by a systemd unit, and
# published by Tailscale Serve at /spark on the node hostname next to LiteLLM.
METRICS_PORT="${SPARK_METRICS_PORT:-8791}"
METRICS_DIR="${SPARK_CONFIG_DIR}/metrics"
METRICS_SCRIPT="${METRICS_DIR}/spark-metrics.py"
METRICS_UNIT_NAME="spark-metrics.service"
METRICS_UNIT_DIR="${SPARK_METRICS_UNIT_DIR:-/etc/systemd/system}"
METRICS_SERVE_PATH="/spark"

metrics_target() { printf 'http://127.0.0.1:%s\n' "$METRICS_PORT"; }
metrics_unit_path() { printf '%s/%s\n' "$METRICS_UNIT_DIR" "$METRICS_UNIT_NAME"; }
metrics_installed() { [[ -f "$(metrics_unit_path)" ]]; }
metrics_active() { command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$METRICS_UNIT_NAME" 2>/dev/null; }
metrics_healthy() {
  curl --noproxy '*' -fsS --max-time 2 "$(metrics_target)${METRICS_SERVE_PATH}/health" >/dev/null 2>&1
}
metrics_script_current() {
  [[ -f "$METRICS_SCRIPT" ]] && cmp -s "$METRICS_SCRIPT" <(spark_builtin_metrics_server)
}

metrics_spark_path() {
  local self
  self=$(command -v spark 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")
  [[ "$self" == /* ]] || self="$(cd "$(dirname "$self")" && pwd)/$(basename "$self")"
  printf '%s\n' "$self"
}

metrics_unit_content() {
  local python="$1" spark_bin="$2" user="$3"
  cat <<EOF
# Managed by spark metrics start; remove with spark metrics stop.
[Unit]
Description=Spark read-only metrics endpoint (127.0.0.1:${METRICS_PORT})
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=${user}
Environment=HOME=${HOME}
Environment=PATH=$(dirname "$spark_bin"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${python} -I ${METRICS_SCRIPT} --host 127.0.0.1 --port ${METRICS_PORT} --spark ${spark_bin}
Restart=always
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
}

# The tailnet hostname of this node, without the trailing dot.
metrics_dns() {
  local dns
  dns=$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // "" | rtrimstr(".")' 2>/dev/null) || return 1
  [[ -n "$dns" ]] || return 1
  printf '%s\n' "$dns"
}

# published | unpublished | conflict | unknown (Tailscale unavailable).
metrics_serve_state() {
  local dns serve current
  command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  dns=$(metrics_dns) || { printf 'unknown\n'; return 0; }
  serve=$(tailscale serve status --json 2>/dev/null || true)
  [[ -n "$serve" ]] || serve='{}'
  current=$(printf '%s\n' "$serve" | jq -r --arg key "$dns:443" --arg path "$METRICS_SERVE_PATH" \
    '.Web[$key].Handlers[$path].Proxy // ""' 2>/dev/null) || { printf 'unknown\n'; return 0; }
  if [[ -z "$current" ]]; then printf 'unpublished\n'
  elif [[ "${current%/}" == "$(metrics_target)" ]]; then printf 'published\n'
  else printf 'conflict\n'; fi
}

metrics_publish() {
  local dns serve state
  command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1 || { err 'Tailscale is not connected'; return 1; }
  tailscale_funnel_status_active && { err 'Funnel active; resolve public exposure before publishing metrics'; return 1; }
  dns=$(metrics_dns) || { err 'Cannot read the Tailscale hostname'; return 1; }
  state=$(metrics_serve_state)
  [[ "$state" != conflict ]] || { err "Serve path ${METRICS_SERVE_PATH} on ${dns} belongs to another service; nothing changed"; return 1; }
  serve=$(tailscale serve status --json 2>/dev/null || true)
  [[ -n "$serve" ]] || serve='{}'
  printf '%s\n' "$serve" | jq -e '(.TCP["443"] // null) == null or .TCP["443"].HTTPS == true' >/dev/null 2>&1 ||
    { err 'Port 443 is a raw TCP forward on this node; nothing changed'; return 1; }
  # Tailnet-only Serve on the existing HTTPS/443 hostname; never Funnel.
  tailscale serve --bg --https=443 --set-path "$METRICS_SERVE_PATH" "$(metrics_target)" >/dev/null || return 1
  if tailscale_funnel_status_active; then
    tailscale serve --https=443 --set-path "$METRICS_SERVE_PATH" off >/dev/null 2>&1 || true
    err 'Public exposure detected; metrics unpublished'
    return 1
  fi
}

# Remove only the Spark-owned /spark handler; other Serve config stays untouched.
metrics_unpublish() {
  case "$(metrics_serve_state)" in
    published) tailscale serve --https=443 --set-path "$METRICS_SERVE_PATH" off >/dev/null ;;
    conflict) warn "Serve path ${METRICS_SERVE_PATH} belongs to another service; left unchanged" ;;
    *) return 0 ;;
  esac
}

metrics_require_host() {
  [[ "$SPARK_OS" == Linux ]] || die "spark metrics runs on the Linux model server" "Run it on the GX10/DGX host"
  command -v systemctl >/dev/null 2>&1 || die "systemd is required for the metrics service"
  command -v python3 >/dev/null 2>&1 || die "python3 is required for the metrics service" "Run: spark setup"
  command -v jq >/dev/null 2>&1 || die "jq is required" "Run: spark setup"
}

metrics_install_service() {
  local python spark_bin user staged
  python=$(command -v python3); spark_bin=$(metrics_spark_path); user=$(id -un)
  [[ "$python" == /* && "$spark_bin" == /* && "$spark_bin$python$HOME" != *[[:space:]]* ]] ||
    die "python3, spark and HOME paths must be absolute and contain no spaces"
  mkdir -p "$METRICS_DIR" && chmod 700 "$METRICS_DIR" || die "Cannot create $METRICS_DIR"
  staged=$(mktemp "${METRICS_DIR}/.spark-metrics.XXXXXX") || die "Cannot stage the metrics server"
  spark_builtin_metrics_server > "$staged" && chmod 644 "$staged" && mv "$staged" "$METRICS_SCRIPT" ||
    { rm -f "$staged"; die "Cannot write $METRICS_SCRIPT"; }
  staged=$(mktemp "${METRICS_DIR}/.unit.XXXXXX") || die "Cannot stage the metrics unit"
  metrics_unit_content "$python" "$spark_bin" "$user" > "$staged" || { rm -f "$staged"; die "Cannot render the metrics unit"; }
  printf "  Installing %s (sudo)\n" "$(metrics_unit_path)"
  if ! sudo install -m 0644 "$staged" "$(metrics_unit_path)"; then rm -f "$staged"; die "Cannot install the metrics unit"; fi
  rm -f "$staged"
  sudo systemctl daemon-reload && sudo systemctl enable "$METRICS_UNIT_NAME" >/dev/null 2>&1 &&
    sudo systemctl restart "$METRICS_UNIT_NAME" || die "Cannot start $METRICS_UNIT_NAME" "journalctl -u $METRICS_UNIT_NAME"
}

metrics_wait_healthy() {
  local attempt attempts="${SPARK_METRICS_READY_ATTEMPTS:-10}"
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    metrics_healthy && return 0
    [[ "$attempt" -lt "$attempts" ]] && sleep 1
  done
  return 1
}

metrics_start() {
  local publish=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --local) publish=0 ;;
      *) die "Unknown metrics start flag: $1" "Usage: spark metrics start [--local]" ;;
    esac
    shift
  done
  metrics_require_host
  metrics_install_service
  metrics_wait_healthy || die "Metrics service did not become healthy" "journalctl -u $METRICS_UNIT_NAME"
  info "Metrics service running on $(metrics_target)${METRICS_SERVE_PATH}/metrics (loopback only)"
  if [[ "$publish" == 1 ]]; then
    metrics_publish || die "Metrics service runs locally but is not published on the tailnet" "Fix Tailscale, then rerun: spark metrics start"
    info "Published on the tailnet (Tailscale Serve, no Funnel)"
  fi
  metrics_status
}

metrics_stop() {
  [[ $# == 0 ]] || die "Usage: spark metrics stop"
  metrics_unpublish || warn "Could not remove the Tailscale Serve path ${METRICS_SERVE_PATH}"
  if metrics_installed; then
    sudo systemctl disable --now "$METRICS_UNIT_NAME" >/dev/null 2>&1 || true
    sudo rm -f "$(metrics_unit_path)" || die "Cannot remove $(metrics_unit_path)"
    sudo systemctl daemon-reload || true
  fi
  rm -f "$METRICS_SCRIPT"
  info "Metrics endpoint stopped and removed from boot"
}

metrics_status_json() {
  local installed=false active=false healthy=false current=false state dns url=null
  metrics_installed && installed=true
  metrics_active && active=true
  metrics_healthy && healthy=true
  metrics_script_current && current=true
  state=$(metrics_serve_state)
  if [[ "$state" == published ]] && dns=$(metrics_dns); then url="\"https://${dns}${METRICS_SERVE_PATH}/metrics\""; fi
  printf '{"installed":%s,"active":%s,"healthy":%s,"script_current":%s,"local_url":"%s%s/metrics","serve":"%s","url":%s}\n' \
    "$installed" "$active" "$healthy" "$current" "$(metrics_target)" "$METRICS_SERVE_PATH" "$state" "$url"
}

metrics_status() {
  local json=0 status
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1 ;;
      *) die "Unknown metrics status flag: $1" "Usage: spark metrics status [--json]" ;;
    esac
    shift
  done
  status=$(metrics_status_json)
  if [[ "$json" == 1 ]]; then
    printf '%s\n' "$status"
  else
    printf "\n  ${BOLD}spark metrics${NC}\n"
    printf '%s\n' "$status" | jq -r '
      "  Service:  " + (if .installed then (if .active then "active" else "inactive" end) else "not installed" end) + " (spark-metrics.service)",
      "  Local:    " + .local_url + (if .healthy then " (healthy)" else " (unreachable)" end),
      "  Tailnet:  " + (.url // .serve),
      (if .installed and (.script_current | not) then "  Server script is outdated; run: spark metrics start" else empty end)'
    printf '\n'
  fi
  printf '%s\n' "$status" | jq -e '.installed and .active and .healthy' >/dev/null
}

doctor_checks_metrics() {
  metrics_installed || return 0
  if metrics_active && metrics_healthy; then
    doctor_pass "Metrics" "Metrics endpoint" "healthy on $(metrics_target)"
  else
    doctor_fail "Metrics" "Metrics endpoint" "installed but not healthy" "spark metrics start"
  fi
  if metrics_script_current; then
    doctor_pass "Metrics" "Metrics server version" "current"
  else
    doctor_fail "Metrics" "Metrics server version" "outdated after a Spark update" "spark metrics start"
  fi
  case "$(metrics_serve_state)" in
    published) doctor_pass "Metrics" "Metrics tailnet path" "Serve ${METRICS_SERVE_PATH} (tailnet only)" ;;
    unknown) doctor_skip "Metrics" "Metrics tailnet path" "skipped; Tailscale not connected" ;;
    conflict) doctor_fail "Metrics" "Metrics tailnet path" "${METRICS_SERVE_PATH} owned by another service" "tailscale serve status" ;;
    *) doctor_fail "Metrics" "Metrics tailnet path" "not published" "spark metrics start" ;;
  esac
}

metrics_uninstall() {
  local dry_run="${1:-0}"
  metrics_installed || return 0
  if [[ "$dry_run" == 1 ]]; then printf "  would stop and remove %s\n" "$METRICS_UNIT_NAME"; return 0; fi
  metrics_stop
}

cmd_metrics_help() {
  cat <<EOF

  ${BOLD}Usage:${NC} spark metrics <start [--local]|stop|status [--json]>

  Read-only JSON endpoint with every Spark-managed instance and its vLLM metrics
  (KV cache, tokens, speculative decoding, TTFT/ITL histograms) for tailnet clients.

    start    Install/refresh the ${METRICS_UNIT_NAME} systemd unit (sudo), bound to
             127.0.0.1:${METRICS_PORT}, and publish it with Tailscale Serve at
             https://<node>${METRICS_SERVE_PATH}/metrics. --local skips publishing.
    stop     Remove the Serve path and the systemd unit.
    status   Show service health and the tailnet URL.

  Routes: ${METRICS_SERVE_PATH}/metrics, ${METRICS_SERVE_PATH}/metrics/<instance>,
          ${METRICS_SERVE_PATH}/metrics/<instance>/raw, ${METRICS_SERVE_PATH}/health

EOF
}

cmd_metrics() {
  local sub="${1:-status}"
  [[ $# == 0 ]] || shift
  case "$sub" in
    start) metrics_start "$@" ;;
    stop) metrics_stop "$@" ;;
    status) metrics_status "$@" ;;
    -h|--help|help) cmd_metrics_help ;;
    *) die "Unknown metrics command: $sub" "Usage: spark metrics <start|stop|status>" ;;
  esac
}
