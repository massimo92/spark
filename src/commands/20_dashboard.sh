dashboard_html_escape() {
  local s="${1:-}"
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//\"/&quot;}
  s=${s//\'/&#39;}
  printf '%s' "$s"
}

dashboard_state_class() {
  case "${1:-unknown}" in
    ok|running|ready|configured|yes|pass) printf 'ok' ;;
    warn|partial|missing|stopped|no)      printf 'warn' ;;
    fail|error|public)                    printf 'fail' ;;
    *)                                    printf 'unknown' ;;
  esac
}

dashboard_metric() {
  local state="$1" label="$2" value="$3" detail="${4:-}" class
  class=$(dashboard_state_class "$state")
  printf '<article class="metric %s"><span>%s</span><strong>%s</strong><small>%s</small></article>\n' \
    "$class" "$(dashboard_html_escape "$label")" "$(dashboard_html_escape "$value")" "$(dashboard_html_escape "$detail")"
}

dashboard_row_html() {
  local state="$1" label="$2" detail="${3:-}" class
  class=$(dashboard_state_class "$state")
  printf '<li class="row %s"><span class="lamp"></span><span class="label">%s</span><span class="detail">%s</span></li>\n' \
    "$class" "$(dashboard_html_escape "$label")" "$(dashboard_html_escape "$detail")"
}

dashboard_panel_open() {
  local title="$1" kicker="${2:-}"
  printf '<section class="panel"><div class="panel-head"><p>%s</p><h2>%s</h2></div><ul class="rows">\n' \
    "$(dashboard_html_escape "$kicker")" "$(dashboard_html_escape "$title")"
}

dashboard_panel_close() {
  printf '</ul></section>\n'
}

dashboard_setup_html() {
  local summary state="partial"
  summary=$(setup_status_summary)
  [[ "$summary" == */* && "$summary" != *"missing:"* ]] && state="ok"
  dashboard_panel_open "Setup" "host readiness"
  dashboard_row_html "$state" "Prerequisites" "$summary"
  if [[ "$BACKEND" == "vllm" ]]; then
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
      dashboard_row_html ok "GPU" "$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1 || echo detected)"
    else
      dashboard_row_html missing "GPU" "not detected"
    fi
    if [[ -n "$(detect_ngc_image)" ]]; then
      dashboard_row_html ok "vLLM image" "$(detect_ngc_image)"
    else
      dashboard_row_html missing "vLLM image" "run spark setup"
    fi
  else
    if command -v ollama >/dev/null 2>&1; then
      dashboard_row_html ok "Ollama" "$(ollama --version 2>/dev/null | head -1 || echo installed)"
    else
      dashboard_row_html missing "Ollama" "run spark setup"
    fi
    if ollama_reachable; then
      dashboard_row_html ok "Ollama API" "http://localhost:11434"
    else
      dashboard_row_html missing "Ollama API" "not reachable"
    fi
  fi
  dashboard_panel_close
}

dashboard_services_html() {
  local gw_state="stopped" gw_detail ws_count
  gateway_running_state && gw_state="running"
  gw_detail="port $(gateway_configured_port) · providers $(gateway_provider_list)"
  dashboard_panel_open "Services" "runtime"
  dashboard_row_html "$gw_state" "LiteLLM gateway" "$gw_detail"
  if docker_running; then dashboard_row_html ok "Docker" "running"; else dashboard_row_html missing "Docker" "not running"; fi
  if workspace_configured; then
    ws_count=$(workspace_service_count)
    if [[ "$ws_count" -gt 0 ]]; then
      dashboard_row_html running "Workspace compose" "${ws_count} service(s) running"
    else
      dashboard_row_html stopped "Workspace compose" "configured, no running services"
    fi
  else
    dashboard_row_html missing "Workspace compose" "not configured"
  fi
  if command -v tailscale >/dev/null 2>&1 && tailscale status >/dev/null 2>&1; then
    dashboard_row_html ok "Tailscale" "connected"
  elif command -v tailscale >/dev/null 2>&1; then
    dashboard_row_html warn "Tailscale" "installed, not connected"
  else
    dashboard_row_html missing "Tailscale" "not installed"
  fi
  dashboard_panel_close
}

dashboard_models_html() {
  local name model port need wt kv rows=0 reserved=0 free loaded omodel osize omod
  printf '<section class="panel wide"><div class="panel-head"><p>inference</p><h2>Models</h2></div>\n'
  if [[ "$BACKEND" == "ollama" ]]; then
    if ! command -v ollama >/dev/null 2>&1; then
      printf '<ul class="rows">'
      dashboard_row_html missing "Ollama models" "Ollama not installed"
      printf '</ul></section>\n'
      return 0
    fi
    printf '<table><thead><tr><th>Model</th><th>Size</th></tr></thead><tbody>\n'
    while read -r omodel _ osize omod _; do
      [[ -z "${omodel:-}" || "$omodel" == "NAME" ]] && continue
      rows=$((rows + 1))
      printf '<tr><td>%s</td><td>%s</td></tr>\n' \
        "$(dashboard_html_escape "$omodel")" "$(dashboard_html_escape "${osize:-} ${omod:-}")"
    done < <(ollama list 2>/dev/null || true)
    if [[ "$rows" -eq 0 ]]; then
      printf '</tbody></table>\n'
      printf '<ul class="rows">'
      dashboard_row_html missing "Ollama models" "none pulled"
      printf '</ul></section>\n'
      return 0
    fi
    printf '</tbody></table>\n'
    loaded=$(ollama ps 2>/dev/null | awk 'NR>1{print $1}' | tr '\n' ' ' || true)
    [[ -n "${loaded// /}" ]] && printf '<p class="note">Loaded now: %s</p>\n' "$(dashboard_html_escape "$loaded")"
    printf '</section>\n'
    return 0
  fi

  printf '<table><thead><tr><th>Model</th><th>Need</th><th>Weights</th><th>KV</th><th>Port</th><th>Up</th></tr></thead><tbody>\n'
  while IFS=$'\t' read -r name model port need wt kv; do
    [[ -z "$name" ]] && continue
    rows=$((rows + 1))
    [[ "${need:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] && reserved=$(awk -v a="$reserved" -v b="$need" 'BEGIN{printf "%.1f", a+b}')
    printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
      "$(dashboard_html_escape "${model:-unknown}")" "$(dashboard_html_escape "${need:-?}")" \
      "$(dashboard_html_escape "${wt:-?}")" "$(dashboard_html_escape "${kv:-?}")" \
      "$(dashboard_html_escape "${port:-?}")" "$(dashboard_html_escape "$(container_uptime "$name")")"
  done < <(list_managed_containers)
  if [[ "$rows" -eq 0 ]]; then
    printf '<tr><td colspan="6">No vLLM models running</td></tr>\n'
  fi
  printf '</tbody></table>\n'
  free=$(awk -v b="$BUDGET_GB" -v r="$reserved" 'BEGIN{printf "%.1f", b-r}')
  printf '<p class="note">Memory: %s GB total · %s GB OS · %s GB reserved · %s GB free · HF cache %s model(s)</p>\n' \
    "$(dashboard_html_escape "$TOTAL_MEM_GB")" "$(dashboard_html_escape "$OS_RESERVE_GB")" \
    "$(dashboard_html_escape "$reserved")" "$(dashboard_html_escape "$free")" "$(dashboard_html_escape "$(count_downloaded_hf_models)")"
  printf '</section>\n'
}

dashboard_workspace_html() {
  local task_url="" task_manager="" task_label="" n8n_url="" hermes_url="" mode="" model=""
  dashboard_panel_open "Agent workspace" "daily tools"
  if ! workspace_configured; then
    dashboard_row_html missing "Workspace" "not configured"
    dashboard_panel_close
    return 0
  fi
  task_manager=$(workspace_task_manager)
  task_label=$(workspace_task_manager_label "$task_manager")
  task_url=$(workspace_task_manager_url)
  n8n_url=$(workspace_read_env N8N_URL 2>/dev/null || true)
  hermes_url=$(workspace_read_env HERMES_URL 2>/dev/null || true)
  mode=$(workspace_read_env WORKSPACE_TAILSCALE_MODE 2>/dev/null || true)
  model=$(workspace_read_env HERMES_MODEL 2>/dev/null || true)
  dashboard_row_html ok "Workspace" "configured (${mode:-unknown} mode)"
  dashboard_row_html ok "Hermes model" "${model:-unset}"
  dashboard_row_html ok "$task_label" "${task_url:-unset}"
  dashboard_row_html ok "n8n" "${n8n_url:-unset}"
  dashboard_row_html ok "Hermes" "${hermes_url:-unset}"
  dashboard_panel_close
}

dashboard_next_steps_html() {
  local any=0
  dashboard_panel_open "Next steps" "actions"
  if ! gateway_configured; then
    dashboard_row_html warn "Configure gateway" "spark setup"
    any=1
  elif ! gateway_running_state; then
    dashboard_row_html warn "Start gateway" "spark gateway start"
    any=1
  fi
  if [[ "$BACKEND" == "vllm" && "$(count_running_vllm_models)" -eq 0 ]]; then
    dashboard_row_html warn "Start model" "spark models recommend; spark run <model>"
    any=1
  elif [[ "$BACKEND" == "ollama" && "$(count_loaded_ollama_models)" -eq 0 ]]; then
    dashboard_row_html warn "Start model" "spark models recommend; spark run <model>"
    any=1
  fi
  if ! workspace_configured; then
    dashboard_row_html warn "Create workspace" "spark setup --full"
    any=1
  fi
  [[ "$any" -eq 0 ]] && dashboard_row_html ok "Ready" "Private agent stack is available"
  dashboard_panel_close
}

dashboard_write_html() {
  local html="$1" interval="${2:-5}" timestamp setup_summary setup_state gw_state ws_state models_state
  mkdir -p "$(dirname "$html")"
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  setup_summary=$(setup_status_summary)
  setup_state="partial"; [[ "$setup_summary" == */* && "$setup_summary" != *"missing:"* ]] && setup_state="ok"
  gw_state="stopped"; gateway_running_state && gw_state="running"
  ws_state="missing"; workspace_configured && ws_state="configured"
  models_state="missing"
  if [[ "$BACKEND" == "vllm" && "$(count_running_vllm_models)" -gt 0 ]]; then models_state="running"; fi
  if [[ "$BACKEND" == "ollama" && "$(count_loaded_ollama_models)" -gt 0 ]]; then models_state="running"; fi

  {
    printf '<!doctype html><html lang="en"><head><meta charset="utf-8">\n'
    printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
    printf '<meta http-equiv="refresh" content="%s">\n' "$(dashboard_html_escape "$interval")"
    printf '<title>spark dashboard</title>\n'
    printf '<style>\n'
    printf '%s\n' ':root{color-scheme:dark;--bg:#0b0b0b;--ink:#f3f0e8;--muted:#8c8c86;--line:#2a2a28;--red:#ff3b30;--ok:#f3f0e8;--warn:#d8b24d;--fail:#ff3b30;--panel:#11110f;--panel2:#171715}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 1px 1px,#242420 1px,transparent 0) 0 0/18px 18px,var(--bg);color:var(--ink);font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;letter-spacing:0}.shell{width:min(1180px,calc(100vw - 32px));margin:0 auto;padding:28px 0 40px}.hero{min-height:190px;display:flex;align-items:flex-end;justify-content:space-between;border-bottom:1px solid var(--line);padding:0 0 22px;position:relative}.hero:before{content:"";position:absolute;inset:0 0 auto auto;width:240px;height:70px;background:repeating-linear-gradient(90deg,var(--ink) 0 6px,transparent 6px 14px);opacity:.08}.brand p,.panel-head p,.metric span{margin:0 0 10px;color:var(--muted);font-size:12px;text-transform:uppercase}.brand h1{margin:0;font-size:clamp(34px,8vw,86px);line-height:.9;font-weight:800;text-transform:lowercase}.dotmark{display:block;width:54px;height:18px;margin-bottom:28px;background:radial-gradient(circle,var(--red) 2px,transparent 3px) 0 0/9px 9px}.live{display:flex;gap:10px;align-items:center;color:var(--muted);font-size:12px}.live b{width:8px;height:8px;background:var(--red);display:inline-block}.metrics{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px;margin:18px 0}.metric{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:14px;min-height:112px}.metric strong{display:block;font-size:22px;line-height:1.05;overflow-wrap:anywhere}.metric small{display:block;color:var(--muted);margin-top:10px;overflow-wrap:anywhere}.metric.ok{border-color:#55554d}.metric.warn{border-color:#5b4a22}.metric.fail{border-color:#6b201c}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.panel{background:linear-gradient(180deg,var(--panel2),var(--panel));border:1px solid var(--line);border-radius:6px;padding:18px;min-width:0}.panel.wide{grid-column:1/-1}.panel-head{display:flex;align-items:end;justify-content:space-between;gap:14px;margin-bottom:16px}.panel h2{margin:0;font-size:20px;text-transform:lowercase}.rows{list-style:none;margin:0;padding:0;display:grid;gap:8px}.row{display:grid;grid-template-columns:14px minmax(120px,.7fr) minmax(0,1fr);gap:10px;align-items:center;border-top:1px solid var(--line);padding-top:9px;min-width:0}.lamp{width:8px;height:8px;background:var(--muted);display:block}.row.ok .lamp{background:var(--ok)}.row.warn .lamp{background:var(--warn)}.row.fail .lamp{background:var(--fail)}.label{font-weight:700;overflow-wrap:anywhere}.detail{color:var(--muted);overflow-wrap:anywhere}table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;border-top:1px solid var(--line);padding:10px 8px;vertical-align:top;overflow-wrap:anywhere}th{color:var(--muted);font-size:11px;text-transform:uppercase}.note{color:var(--muted);font-size:12px;margin:14px 0 0;overflow-wrap:anywhere}@media(max-width:760px){.shell{width:min(100vw - 20px,1180px);padding-top:18px}.hero{display:block;min-height:160px}.live{margin-top:18px}.metrics,.grid{grid-template-columns:1fr}.row{grid-template-columns:14px 1fr}.detail{grid-column:2}}'
    printf '</style></head><body><div class="shell">\n'
    printf '<header class="hero"><div class="brand"><span class="dotmark"></span><p>spark control plane</p><h1>private agent stack</h1></div><div class="live"><b></b><span>%s</span></div></header>\n' "$(dashboard_html_escape "$timestamp")"
    printf '<section class="metrics">\n'
    dashboard_metric "$setup_state" "setup" "$setup_summary" "${SPARK_OS}/${SPARK_ARCH} · ${ACCEL}"
    dashboard_metric "$gw_state" "gateway" "port $(gateway_configured_port)" "providers $(gateway_provider_list)"
    dashboard_metric "$models_state" "models" "$BACKEND" "$(count_running_vllm_models) vLLM running · $(count_loaded_ollama_models) Ollama loaded"
    dashboard_metric "$ws_state" "workspace" "$ws_state" "$(workspace_service_count) service(s) running"
    printf '</section><main class="grid">\n'
    dashboard_setup_html
    dashboard_services_html
    dashboard_models_html
    dashboard_workspace_html
    dashboard_next_steps_html
    printf '</main></div></body></html>\n'
  } > "$html"
}

cmd_dashboard_terminal() {
  local watch=0 interval=5 clear=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --watch) watch=1; shift; [[ "${1:-}" =~ ^[0-9]+$ ]] && { interval="$1"; shift; } ;;
      --interval) [[ $# -ge 2 ]] || die "Missing value for --interval"; interval="$2"; watch=1; shift 2 ;;
      --no-clear) clear=0; shift ;;
      -h|--help)
        printf "\n  ${BOLD}Usage:${NC} spark dashboard --terminal [--watch [seconds]] [--no-clear]\n\n"
        return 0 ;;
      *) die "Unknown dashboard flag: $1" ;;
    esac
  done

  while true; do
    if [[ "$clear" == "1" && -t 1 ]]; then printf '\033[H\033[2J'; fi
    printf "\n  ${BOLD}spark dashboard${NC}  ${DIM}%s${NC}\n\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    print_system_overview
    print_setup_overview
    print_services_overview
    print_models_overview
    print_workspace_overview
    print_next_steps
    printf "\n"
    [[ "$watch" == "1" ]] || break
    sleep "$interval"
  done
}

cmd_dashboard() {
  local port="${SPARK_DASHBOARD_PORT:-$DASHBOARD_PORT}" host="${SPARK_DASHBOARD_HOST:-127.0.0.1}"
  local interval=5 once=0 terminal=0 watch=0 clear=1 explicit_port=0 interval_set=0 dir html py url targs=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --terminal) terminal=1; shift ;;
      --watch) terminal=1; watch=1; shift; [[ "${1:-}" =~ ^[0-9]+$ ]] && { interval="$1"; shift; } ;;
      --interval) [[ $# -ge 2 ]] || die "Missing value for --interval"; interval="$2"; interval_set=1; shift 2 ;;
      --port) [[ $# -ge 2 ]] || die "Missing value for --port"; port="$2"; explicit_port=1; shift 2 ;;
      --host) [[ $# -ge 2 ]] || die "Missing value for --host"; host="$2"; shift 2 ;;
      --once) once=1; shift ;;
      --no-clear) terminal=1; clear=0; shift ;;
      -h|--help)
        printf "\n  ${BOLD}Usage:${NC} spark dashboard [--host 127.0.0.1] [--port 8787] [--interval seconds] [--once]\n"
        printf "         spark dashboard --terminal [--watch [seconds]] [--no-clear]\n\n"
        return 0 ;;
      *) die "Unknown dashboard flag: $1" ;;
    esac
  done
  [[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || die "--interval must be a positive integer"
  [[ "$port" =~ ^[0-9]+$ && "$port" -gt 0 && "$port" -le 65535 ]] || die "--port must be 1-65535"

  if [[ "$terminal" == "1" ]]; then
    [[ "$watch" == "1" ]] && targs+=(--watch "$interval")
    [[ "$watch" != "1" && "$interval_set" == "1" ]] && targs+=(--interval "$interval")
    [[ "$clear" == "0" ]] && targs+=(--no-clear)
    cmd_dashboard_terminal "${targs[@]}"
    return $?
  fi

  dir="${SPARK_DASHBOARD_DIR:-$DASHBOARD_DIR}"
  html="${dir}/index.html"
  dashboard_write_html "$html" "$interval"
  if [[ "$once" == "1" ]]; then
    printf "Dashboard written: %s\n" "$html"
    return 0
  fi

  if [[ "$explicit_port" == "1" ]]; then
    port_in_use "$port" && die "Dashboard port already in use: $port"
  else
    port=$(next_free_port "$port")
  fi
  py=$(command -v python3 || true)
  [[ -n "$py" ]] || die "python3 is required to serve the web dashboard"
  url="http://${host}:${port}/"
  printf "\n  ${BOLD}spark dashboard${NC}\n"
  printf "  URL:  ${BOLD}%s${NC}\n" "$url"
  printf "  File: %s\n" "$html"
  printf "  Refresh: every %ss. Press Ctrl-C to stop.\n\n" "$interval"

  (
    while true; do
      dashboard_write_html "$html" "$interval" || true
      sleep "$interval"
    done
  ) &
  local updater_pid=$! server_pid="" rc=0
  cleanup_dashboard() {
    [[ -n "${updater_pid:-}" ]] && kill "$updater_pid" >/dev/null 2>&1 || true
    [[ -n "${server_pid:-}" ]] && kill "$server_pid" >/dev/null 2>&1 || true
  }
  trap cleanup_dashboard EXIT
  trap 'cleanup_dashboard; exit 130' INT TERM
  set +e
  "$py" -m http.server "$port" --bind "$host" --directory "$dir" &
  server_pid=$!
  wait "$server_pid"
  rc=$?
  set -e
  cleanup_dashboard
  trap - EXIT INT TERM
  return "$rc"
}
