#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARK="${ROOT_DIR}/spark"
SPARK_VERSION="$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$SPARK" | head -1)"

# These tests target the vLLM/NVIDIA path; default detection to it so the no-GPU CI
# runners don't fall through to the Ollama backend. Backend-specific tests override
# SPARK_BACKEND/SPARK_ACCEL inline, or clear them per-invocation with `env -u`.
export SPARK_BACKEND="${SPARK_BACKEND:-vllm}"
export SPARK_ACCEL="${SPARK_ACCEL:-cuda-unified}"

passed=0
failed=0

test_suite="${SPARK_TEST_SUITE:-all}"
test_shard_total="${SPARK_TEST_SHARD_TOTAL:-1}"
test_shard_index="${SPARK_TEST_SHARD_INDEX:-0}"
test_list_only="${SPARK_TEST_LIST_ONLY:-0}"
discovered=0
eligible=0
selected=0

case "$test_suite" in
  all|portability) ;;
  *) printf "Unknown SPARK_TEST_SUITE: %s\n" "$test_suite" >&2; exit 2 ;;
esac
[[ "$test_shard_total" =~ ^[1-9][0-9]*$ ]] || {
  printf "SPARK_TEST_SHARD_TOTAL must be a positive integer\n" >&2
  exit 2
}
[[ "$test_shard_index" =~ ^[0-9]+$ ]] && (( test_shard_index < test_shard_total )) || {
  printf "SPARK_TEST_SHARD_INDEX must be between 0 and total - 1\n" >&2
  exit 2
}
[[ "$test_list_only" == "0" || "$test_list_only" == "1" ]] || {
  printf "SPARK_TEST_LIST_ONLY must be 0 or 1\n" >&2
  exit 2
}

make_fake_bin() {
  local dir="$1"
  mkdir -p "$dir"

  cat > "${dir}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
case "${1:-}" in
  --version)
    echo "Docker version 29.4.3, build fake"
    ;;
  info)
    exit "${FAKE_DOCKER_INFO_EXIT:-1}"
    ;;
  compose)
    shift
    [[ -n "${FAKE_COMPOSE_FILE:-}" ]] && printf '%s\n' "$*" >> "${FAKE_COMPOSE_FILE}"
    case "$*" in
      version) exit "${FAKE_COMPOSE_VERSION_EXIT:-0}" ;;
      *" ps --services --status running"*) [[ -n "${FAKE_COMPOSE_SERVICES:-}" ]] && printf '%b' "${FAKE_COMPOSE_SERVICES}" || true ;;
      *" ps "*|*" ps") [[ -n "${FAKE_COMPOSE_PS:-}" ]] && printf '%b' "${FAKE_COMPOSE_PS}" || true ;;
      *" config --quiet"*) exit "${FAKE_COMPOSE_CONFIG_EXIT:-0}" ;;
      *" up -d"*|*" up"*) exit "${FAKE_COMPOSE_UP_EXIT:-0}" ;;
      *exec*)
        stdin_payload=""
        if [[ ! -t 0 && "${FAKE_DOCKER_READ_STDIN:-1}" == "1" ]]; then
          stdin_payload=$(cat || true)
        fi
        match_payload="$*
${stdin_payload}"
        if [[ -n "${FAKE_COMPOSE_EXEC_FILE:-}" ]]; then
          printf '%s\n' "$*" >> "${FAKE_COMPOSE_EXEC_FILE}"
          [[ -n "$stdin_payload" ]] && printf '%s\n' "$stdin_payload" >> "${FAKE_COMPOSE_EXEC_FILE}"
        fi
        case "$match_payload" in
          *"/app/vikunja/vikunja doctor"*) printf '%b' "${FAKE_VIKUNJA_DOCTOR_OUTPUT:-}"; exit "${FAKE_VIKUNJA_DOCTOR_EXIT:-0}" ;;
          *"pg_roles WHERE rolname='vikunja'"*) [[ "${FAKE_PG_ROLE_VIKUNJA:-1}" == "1" ]] && printf '1\n' ;;
          *"pg_roles WHERE rolname='n8n'"*) [[ "${FAKE_PG_ROLE_N8N:-1}" == "1" ]] && printf '1\n' ;;
          *"pg_database WHERE datname='vikunja'"*) [[ "${FAKE_PG_DB_VIKUNJA:-1}" == "1" ]] && printf '1\n' ;;
          *"pg_database WHERE datname='n8n'"*) [[ "${FAKE_PG_DB_N8N:-1}" == "1" ]] && printf '1\n' ;;
          *"CREATE USER vikunja"*|*"ALTER USER vikunja"*|*"CREATE DATABASE vikunja"*|*"ALTER DATABASE vikunja"*) exit 0 ;;
          *"CREATE USER n8n"*|*"ALTER USER n8n"*|*"CREATE DATABASE n8n"*|*"ALTER DATABASE n8n"*) exit 0 ;;
          *"n8n user-management:reset"*) exit "${FAKE_N8N_USER_RESET_EXIT:-0}" ;;
          *"n8n --version"*) printf '%s\n' "${FAKE_N8N_VERSION:-2.30.5}" ;;
          *"bcryptjs"*) printf '%s\n' "${FAKE_N8N_PASSWORD_HASH:-\$2b\$10\$12345678901234567890123456789012345678901234567890123}" ;;
          *"user reset-password "*) exit "${FAKE_VIKUNJA_PASSWORD_RESET_EXIT:-0}" ;;
          *"user create -u "*)
            if [[ -n "${FAKE_VIKUNJA_CREATED_USER_FILE:-}" ]]; then
              printf '%s\n' "$*" > "$FAKE_VIKUNJA_CREATED_USER_FILE"
            fi
            exit 0 ;;
          *"pg_dump -U vikunja vikunja"*) printf '%s\n' "-- vikunja dump" ;;
          *"pg_dump -U n8n n8n"*) printf '%s\n' "-- n8n dump" ;;
          *"user list -e "*) exit 2 ;;
          *"user list"*)
            if [[ -n "${FAKE_VIKUNJA_USER_LIST_READY_AFTER:-}" ]]; then
              count_file="${FAKE_VIKUNJA_USER_LIST_COUNT_FILE:-/tmp/spark-fake-vikunja-user-list-count}"
              count=0
              [[ -f "$count_file" ]] && count=$(cat "$count_file")
              count=$((count + 1))
              printf '%s\n' "$count" > "$count_file"
              if [[ "$count" -lt "$FAKE_VIKUNJA_USER_LIST_READY_AFTER" ]]; then
                exit 2
              fi
            fi
            printf '%b' "${FAKE_VIKUNJA_USER_LIST:-| 1 | massimo | m@example.com | active |\n| 2 | hermes | hermes@spark.invalid | active |\n}"
            if [[ -n "${FAKE_VIKUNJA_CREATED_USER_FILE:-}" && -f "$FAKE_VIKUNJA_CREATED_USER_FILE" ]]; then
              created=$(cat "$FAKE_VIKUNJA_CREATED_USER_FILE")
              username=$(sed -n 's/.* -u \([^ ]*\).*/\1/p' <<< "$created")
              email=$(sed -n 's/.* -e \([^ ]*\).*/\1/p' <<< "$created")
              printf '| 9 | %s | %s | active |\n' "$username" "$email"
            fi
            ;;
        esac
        exit "${FAKE_COMPOSE_EXEC_EXIT:-0}" ;;
      *" cp vikunja:/tmp/vikunja.zip "*)
        dest="${*: -1}"
        mkdir -p "$(dirname "$dest")"
        printf '%s\n' "fake-vikunja-zip" > "$dest"
        exit 0 ;;
      *" logs "*) [[ -n "${FAKE_COMPOSE_LOGS:-}" ]] && printf '%b' "${FAKE_COMPOSE_LOGS}" ;;
      *) ;;
    esac
    ;;
  image)
    if [[ "${2:-}" == "inspect" ]]; then
      if [[ "${FAKE_DOCKER_IMAGE_EXISTS:-1}" == "0" && \
            ( -z "${FAKE_DOCKER_BUILD_FILE:-}" || ! -s "${FAKE_DOCKER_BUILD_FILE}" ) ]]; then
        exit 1
      fi
      case "$args" in
        *"{{.Id}}"*) printf '%s\n' "${FAKE_DOCKER_IMAGE_ID:-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
        *"Config.Entrypoint"*) printf '%s\n' "${FAKE_DOCKER_ENTRYPOINT_JSON:-[\"vllm\",\"serve\"]}" ;;
        *)
          if [[ -n "${FAKE_DOCKER_LOCAL_DIGEST:-}" ]]; then
            printf '%s@%s\n' "${*: -1}" "$FAKE_DOCKER_LOCAL_DIGEST"
          fi ;;
      esac
    elif [[ "${2:-}" == "rm" ]]; then
      exit 0
    else
      exit 0
    fi
    ;;
  buildx)
    [[ -n "${FAKE_DOCKER_REMOTE_OUTPUT:-${FAKE_DOCKER_REMOTE_DIGEST:-}}" ]] || exit 1
    printf '%b\n' "${FAKE_DOCKER_REMOTE_OUTPUT:-$FAKE_DOCKER_REMOTE_DIGEST}"
    ;;
  build)
    [[ -n "${FAKE_DOCKER_BUILD_FILE:-}" ]] && printf '%s\n' "$args" >> "$FAKE_DOCKER_BUILD_FILE"
    exit "${FAKE_DOCKER_BUILD_EXIT:-0}"
    ;;
  images)
    [[ -n "${FAKE_DOCKER_IMAGE:-}" ]] && printf '%b\n' "${FAKE_DOCKER_IMAGE}"
    ;;
  ps)
    # Managed-container listing (TSV rows via FAKE_MANAGED); plain name listing otherwise.
    if [[ "$args" == *"label=spark.managed=1"* ]]; then
      [[ -n "${FAKE_MANAGED:-}" ]] && printf '%b' "${FAKE_MANAGED}"
    elif [[ "$args" == *'{{.Ports}}'* ]]; then
      [[ -n "${FAKE_DOCKER_PORTS:-}" ]] && printf '%b' "${FAKE_DOCKER_PORTS}"
    elif [[ "$args" == *'{{.Names}}'* ]]; then
      [[ -n "${FAKE_NAMES:-}" ]] && printf '%b' "${FAKE_NAMES}"
    fi
    ;;
  pull)
    [[ -n "${FAKE_DOCKER_PULL_FILE:-}" ]] && printf '%s\n' "${2:-}" >> "${FAKE_DOCKER_PULL_FILE}"
    exit "${FAKE_DOCKER_PULL_EXIT:-0}"
    ;;
  network)
    case "$args" in
      *"inspect openshell-docker"*) printf '%s\n' "${FAKE_OPENSHELL_BRIDGE_IP:-172.19.0.1}" ;;
    esac
    ;;
  run)
    [[ -n "${FAKE_DOCKER_ARGS_FILE:-}" ]] && printf '%s\n' "$args" >> "${FAKE_DOCKER_ARGS_FILE}"
    exit "${FAKE_DOCKER_RUN_EXIT:-0}"
    ;;
  stop|rm|rename)
    [[ -n "${FAKE_DOCKER_STOP_FILE:-}" ]] && printf '%s\n' "$args" >> "${FAKE_DOCKER_STOP_FILE}"
    exit "${FAKE_DOCKER_STOP_EXIT:-0}"
    ;;
  inspect)
    if [[ -n "${FAKE_CONTAINER_INSPECT_JSON:-}" && "$args" != *"{{"* ]]; then
      printf '%s\n' "$FAKE_CONTAINER_INSPECT_JSON"
      exit 0
    fi
    # Adaptive-startup tests: vary by attempt (= number of `run` lines captured so far).
    _att=0
    [[ -n "${FAKE_DOCKER_ARGS_FILE:-}" && -f "${FAKE_DOCKER_ARGS_FILE}" ]] && _att=$(grep -c '^run ' "${FAKE_DOCKER_ARGS_FILE}" 2>/dev/null || echo 0)
    case "$args" in
      *State.Running*) echo "${FAKE_STATE_RUNNING:-true}" ;;
      *State.StartedAt*) echo "${FAKE_STARTED_AT:-}" ;;
      *State.Status*)
        if [[ -n "${FAKE_RETRY:-}" && "${_att}" -le 1 ]]; then echo "exited"
        else echo "${FAKE_STATE_STATUS:-running}"; fi ;;
      *State.OOMKilled*)
        if [[ "${FAKE_RETRY:-}" == "oom" && "${_att}" -le 1 ]]; then echo "true"
        else echo "${FAKE_OOMKILLED:-false}"; fi ;;
      *spark.max_model_len*) echo "${FAKE_DOCKER_MAX_MODEL_LEN:-65536}" ;;
      *Config.Cmd*) echo "${FAKE_DOCKER_CMD_JSON:-[\"Org/Model\",\"--enable-auto-tool-choice\",\"--tool-call-parser\",\"qwen3_coder\"]}" ;;
      *) [[ -n "${FAKE_DOCKER_INSPECT:-}" ]] && echo "${FAKE_DOCKER_INSPECT}" ;;
    esac
    ;;
  logs)
    _att=0
    [[ -n "${FAKE_DOCKER_ARGS_FILE:-}" && -f "${FAKE_DOCKER_ARGS_FILE}" ]] && _att=$(grep -c '^run ' "${FAKE_DOCKER_ARGS_FILE}" 2>/dev/null || echo 0)
    if [[ "${FAKE_RETRY:-}" == "mamba" && "${_att}" -le 1 ]]; then
      echo "ValueError: max_num_seqs (100) exceeds available Mamba cache blocks (${FAKE_MAMBA_N:-64}). Lower max_num_seqs to at most ${FAKE_MAMBA_N:-64} or increase gpu_memory_utilization."
    else
      [[ -n "${FAKE_DOCKER_LOGS:-}" ]] && echo "${FAKE_DOCKER_LOGS}"
    fi
    ;;
  exec)
    [[ -n "${FAKE_DOCKER_EXEC_FILE:-}" ]] && printf '%s\n' "$args" >> "${FAKE_DOCKER_EXEC_FILE}"
    # cgroup memory reads for `spark status` live block.
    case "$args" in
      *"grep -q 'NEMOCLAW_HERMES_DASHBOARD_HOST'"*) exit "${FAKE_HERMES_ENTRYPOINT_PATCHED_EXIT:-1}" ;;
      *"hermes.real dashboard --host 0[.]0[.]0[.]0"*) exit "${FAKE_HERMES_PUBLIC_BOUND_EXIT:-1}" ;;
      *memory.current*) [[ -n "${FAKE_MEM_CURRENT:-}" ]] && echo "${FAKE_MEM_CURRENT}" ;;
      *memory.peak*)    [[ -n "${FAKE_MEM_PEAK:-}" ]] && echo "${FAKE_MEM_PEAK}" ;;
    esac
    ;;
  manifest)
    exit 0
    ;;
  *)
    ;;
esac
EOF
  chmod +x "${dir}/docker"

  # nvidia-smi mock: FAKE_NVIDIA_SMI_EXIT=0 simulates a present GPU. FAKE_VRAM_MIB and
  # FAKE_GPU_NAME drive the discrete-vs-unified classification and the VRAM pool.
  cat > "${dir}/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *-L*)
    [[ "${FAKE_NVIDIA_SMI_EXIT:-1}" == "0" ]] && echo "GPU 0: ${FAKE_GPU_NAME:-NVIDIA Test} (UUID: GPU-0)"
    exit "${FAKE_NVIDIA_SMI_EXIT:-1}" ;;
  *memory.total*)
    [[ -n "${FAKE_VRAM_MIB:-}" ]] && echo "${FAKE_VRAM_MIB}"
    exit "${FAKE_NVIDIA_SMI_EXIT:-1}" ;;
  *--query-gpu=name*)
    [[ -n "${FAKE_GPU_NAME:-}" ]] && echo "${FAKE_GPU_NAME}"
    exit "${FAKE_NVIDIA_SMI_EXIT:-1}" ;;
  *--query-gpu=compute_cap*)
    [[ -n "${FAKE_COMPUTE_CAP:-}" ]] && echo "${FAKE_COMPUTE_CAP}"
    exit "${FAKE_NVIDIA_SMI_EXIT:-1}" ;;
  *--query-gpu=driver_version*)
    [[ -n "${FAKE_DRIVER_VERSION:-}" ]] && echo "${FAKE_DRIVER_VERSION}"
    exit "${FAKE_NVIDIA_SMI_EXIT:-1}" ;;
  *)
    exit "${FAKE_NVIDIA_SMI_EXIT:-1}" ;;
esac
EOF
  chmod +x "${dir}/nvidia-smi"

  cat > "${dir}/nvidia-ctk" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${dir}/nvidia-ctk"

  cat > "${dir}/groups" <<'EOF'
#!/usr/bin/env bash
echo "${FAKE_GROUPS:-massimo docker}"
EOF
  chmod +x "${dir}/groups"

  cat > "${dir}/uv" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${dir}/uv"

  cat > "${dir}/nvitop" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${dir}/nvitop"

  # ollama mock: list/ps from FAKE_OLLAMA_LIST/FAKE_OLLAMA_PS; pull records to a file.
  cat > "${dir}/ollama" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) printf '%b' "${FAKE_OLLAMA_LIST:-}" ;;
  ps)   printf '%b' "${FAKE_OLLAMA_PS:-}" ;;
  pull) [[ -n "${FAKE_OLLAMA_PULL_FILE:-}" ]] && echo "$2" >> "${FAKE_OLLAMA_PULL_FILE}"
        exit "${FAKE_OLLAMA_PULL_EXIT:-0}" ;;
  stop) exit "${FAKE_OLLAMA_STOP_EXIT:-0}" ;;
  show) printf '%b' "${FAKE_OLLAMA_SHOW:-}" ;;
  --version|version) echo "ollama version 0.19.0" ;;
  *)    exit 0 ;;
esac
EOF
  chmod +x "${dir}/ollama"

  # curl mock: probes Ollama's :11434 (FAKE_OLLAMA_UP) and vLLM readiness at /v1/models
  # (FAKE_VLLM_READY, default ready so supervised launches don't block in tests).
cat > "${dir}/curl" <<'EOF'
#!/usr/bin/env bash
stdin_payload=""
[[ "$*" == *"@-"* ]] && stdin_payload=$(cat || true)
args="$*
${stdin_payload}"
case "$args" in
  *https://tasks.test-tailnet.ts.net/api/v1/info*) exit "${FAKE_TAILSCALE_VIKUNJA_EXIT:-0}" ;;
  *https://n8n.test-tailnet.ts.net/healthz*) exit "${FAKE_TAILSCALE_N8N_EXIT:-0}" ;;
  *https://hermes.test-tailnet.ts.net/*) exit "${FAKE_TAILSCALE_HERMES_EXIT:-0}" ;;
  *http://sparkbox.test-tailnet.ts.net:3456/api/v1/info*) exit "${FAKE_TAILSCALE_VIKUNJA_EXIT:-0}" ;;
  *http://sparkbox.test-tailnet.ts.net:5678/healthz*) exit "${FAKE_TAILSCALE_N8N_EXIT:-0}" ;;
  *http://sparkbox.test-tailnet.ts.net:18789/*) exit "${FAKE_TAILSCALE_HERMES_EXIT:-0}" ;;
  *:3456/api/v1/info*) exit "${FAKE_VIKUNJA_INFO_EXIT:-0}" ;;
  *:3456/api/v1/login*) echo '{"token":"jwt_human"}'; exit "${FAKE_VIKUNJA_LOGIN_EXIT:-0}" ;;
  *:3456/api/v1/routes*) echo '{"tasks":{"read_all":{},"create":{},"update":{},"delete":{}},"projects":{"read_all":{},"create":{},"update":{},"delete":{}},"comments":{"read_all":{},"create":{},"update":{},"delete":{}},"labels":{"read_all":{},"create":{},"update":{},"delete":{}},"webhooks":{"read_all":{},"create":{},"update":{},"delete":{}}}'; exit "${FAKE_VIKUNJA_ROUTES_EXIT:-0}" ;;
  *:3456/api/v1/tokens*) [[ -n "${FAKE_CURL_FILE:-}" ]] && printf '%s\n' "$*" >> "${FAKE_CURL_FILE}"; echo "{\"token\":\"${FAKE_VIKUNJA_CREATED_TOKEN:-vk_auto_hermes}\"}"; exit "${FAKE_VIKUNJA_TOKEN_CREATE_EXIT:-0}" ;;
  *:3456/api/v2/user/bots*)
    [[ -n "${FAKE_CURL_FILE:-}" ]] && printf '%s\n' "$args" >> "${FAKE_CURL_FILE}"
    if [[ "$args" == *"-X POST"* ]]; then
      if [[ -n "${FAKE_VIKUNJA_BOT_CREATE_JSON:-}" ]]; then echo "$FAKE_VIKUNJA_BOT_CREATE_JSON"; else echo '{"id":3,"username":"bot-hermes","name":"Hermes","bot_owner_id":1}'; fi
      exit "${FAKE_VIKUNJA_BOT_CREATE_EXIT:-0}"
    fi
    if [[ -n "${FAKE_VIKUNJA_BOTS_JSON:-}" ]]; then echo "$FAKE_VIKUNJA_BOTS_JSON"; else echo '{"items":[{"id":3,"username":"bot-hermes","name":"Hermes","bot_owner_id":1}]}'; fi
    exit "${FAKE_VIKUNJA_BOTS_EXIT:-0}" ;;
  *:3456/api/v2/tokens*)
    [[ -n "${FAKE_CURL_FILE:-}" ]] && printf '%s\n' "$args" >> "${FAKE_CURL_FILE}"
    echo "{\"token\":\"${FAKE_VIKUNJA_CREATED_TOKEN:-vk_auto_hermes}\"}"
    exit "${FAKE_VIKUNJA_TOKEN_CREATE_EXIT:-0}" ;;
  *:3456/api/v2/projects/*/users*)
    [[ -n "${FAKE_CURL_FILE:-}" ]] && printf '%s\n' "$args" >> "${FAKE_CURL_FILE}"
    if [[ "$args" == *"-X GET"* ]]; then
      if [[ -n "${FAKE_VIKUNJA_PROJECT_USERS_JSON:-}" ]]; then echo "$FAKE_VIKUNJA_PROJECT_USERS_JSON"; else echo '{"items":[{"username":"bot-hermes","permission":1}]}'; fi
    else
      echo '{"id":1,"username":"bot-hermes","permission":1}'
    fi
    exit "${FAKE_VIKUNJA_PROJECT_SHARE_EXIT:-0}" ;;
  *:3456/api/v2/projects*)
    [[ -n "${FAKE_CURL_FILE:-}" ]] && printf '%s\n' "$args" >> "${FAKE_CURL_FILE}"
    if [[ -n "${FAKE_VIKUNJA_PROJECTS_JSON:-}" ]]; then echo "$FAKE_VIKUNJA_PROJECTS_JSON"; else echo '{"items":[{"id":10,"title":"Inbox","max_permission":2}]}'; fi
    exit "${FAKE_VIKUNJA_PROJECTS_EXIT:-0}" ;;
  *:3456/api/v1/user*) echo "${FAKE_VIKUNJA_USER_JSON:-{\"id\":3,\"username\":\"bot-hermes\",\"email\":\"\",\"bot_owner_id\":1}}"; exit "${FAKE_VIKUNJA_USER_EXIT:-0}" ;;
  *:5678/healthz*) exit "${FAKE_N8N_HEALTH_EXIT:-0}" ;;
  *:5678/rest/owner/setup*) [[ -n "${FAKE_N8N_OWNER_MARKER:-}" ]] && : > "$FAKE_N8N_OWNER_MARKER"; echo '{"data":{"id":"owner"}}'; exit "${FAKE_N8N_OWNER_EXIT:-0}" ;;
  *:5678/rest/login*)
    if [[ -n "${FAKE_N8N_LOGIN_COUNT_FILE:-}" ]]; then
      login_count=0
      [[ -f "$FAKE_N8N_LOGIN_COUNT_FILE" ]] && login_count=$(cat "$FAKE_N8N_LOGIN_COUNT_FILE")
      login_count=$((login_count + 1))
      printf '%s\n' "$login_count" > "$FAKE_N8N_LOGIN_COUNT_FILE"
      if [[ ",${FAKE_N8N_LOGIN_FAIL_CALLS:-}," == *",$login_count,"* ]]; then
        exit 22
      fi
    fi
    if [[ "${FAKE_N8N_LOGIN_FORBID_EMAIL_FIELD:-0}" == "1" && "$args" == *'"email"'* ]]; then
      echo '{"code":"email_field_forbidden"}'
      exit 400
    fi
    if [[ "${FAKE_N8N_LOGIN_REQUIRE_EMAIL_OR_LDAP:-0}" == "1" && "$args" != *"emailOrLdapLoginId"* ]]; then
      echo '{"code":"invalid_type","path":["emailOrLdapLoginId"],"message":"Required"}'
      exit 400
    fi
    echo '{"data":{"id":"owner"}}'
    if [[ "${FAKE_N8N_LOGIN_AFTER_OWNER:-0}" == "1" && -n "${FAKE_N8N_OWNER_MARKER:-}" && -e "$FAKE_N8N_OWNER_MARKER" ]]; then
      exit 0
    fi
    exit "${FAKE_N8N_LOGIN_EXIT:-0}" ;;
  *:8642/health*) echo "${FAKE_HERMES_HEALTH:-{\"status\":\"ok\"}}"; exit "${FAKE_HERMES_LOCAL_API_EXIT:-0}" ;;
  *:8642/v1/models*) echo "${FAKE_HERMES_MODELS:-{\"data\":[{\"id\":\"hermes-agent\"}]}"; exit "${FAKE_HERMES_LOCAL_API_EXIT:-0}" ;;
  *:18789/*) exit "${FAKE_HERMES_DASHBOARD_EXIT:-0}" ;;
  */v1/chat/completions*) [[ "${FAKE_LITELLM_SMOKE_EXIT:-0}" == "0" ]] && { echo "${FAKE_LITELLM_SMOKE_JSON:-{\"choices\":[{\"message\":{\"content\":\"ok\"}}],\"usage\":{\"completion_tokens\":1}}}"; exit 0; }; exit "${FAKE_LITELLM_SMOKE_EXIT:-1}" ;;
  */v1/models*)
    if [[ "${FAKE_VLLM_READY:-1}" == "1" ]]; then
      if [[ -n "${FAKE_LITELLM_MODELS:-}" ]]; then
        printf '%s\n' "$FAKE_LITELLM_MODELS"
      else
        printf '%s\n' '{"data":[{"id":"vllm/Org/Alpha"}]}'
      fi
      exit 0
    fi
    exit 7 ;;
  *)            [[ "${FAKE_OLLAMA_UP:-0}" == "1" ]] && exit 0; exit 7 ;;
esac
EOF
  chmod +x "${dir}/curl"

  cat > "${dir}/ss" <<'EOF'
#!/usr/bin/env bash
printf '%b' "${FAKE_SS_LISTEN:-LISTEN 0 4096 127.0.0.1:3456 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:5678 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:18789 0.0.0.0:*\nLISTEN 0 4096 127.0.0.1:4000 0.0.0.0:*\n}"
EOF
  chmod +x "${dir}/ss"

  cat > "${dir}/lsof" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
docker  1000 user   10u  IPv4 0t0 TCP 127.0.0.1:3456 (LISTEN)
docker  1000 user   11u  IPv4 0t0 TCP 127.0.0.1:5678 (LISTEN)
hermes  1001 user   12u  IPv4 0t0 TCP 127.0.0.1:18789 (LISTEN)
litellm 1002 user   13u  IPv4 0t0 TCP 127.0.0.1:4000 (LISTEN)
OUT
EOF
  chmod +x "${dir}/lsof"

  # systemctl mock for spark setup OS-hardening checks. list-unit-files echoes a unit only if we
  # pretend it's installed (a realistic control-plane subset); show -p returns the FAKE_* values,
  # applied to every unit (so FAKE_SSHD_OOMSCORE=-1000 marks them all protected).
  cat > "${dir}/systemctl" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *is-active*earlyoom*)        exit "${FAKE_EARLYOOM_ACTIVE:-1}" ;;
  *list-unit-files*)
    for u in ssh.service dbus.service tailscaled.service systemd-logind.service systemd-resolved.service; do
      case "$args" in *"${u}"*) echo "${u} enabled enabled"; break ;; esac
    done ;;
  *"show -p MemoryMin"*)       echo "${FAKE_SSHD_MEMORYMIN:-}" ;;
  *"show -p OOMScoreAdjust"*)  echo "${FAKE_SSHD_OOMSCORE:-}" ;;
  *)                           exit 0 ;;
esac
EOF
  chmod +x "${dir}/systemctl"

  cat > "${dir}/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

read_value() {
  local env_name="$1" file_name="$2" fallback="$3" file_path=""
  file_path="${!file_name:-}"
  if [[ -n "$file_path" && -f "$file_path" ]]; then
    cat "$file_path"
  elif [[ -n "${!env_name:-}" ]]; then
    printf '%s\n' "${!env_name}"
  else
    printf '%s\n' "$fallback"
  fi
}

write_value() {
  local file_name="$1" value="$2" file_path=""
  file_path="${!file_name:-}"
  [[ -n "$file_path" ]] && printf '%s\n' "$value" > "$file_path"
}

swap_total_mib() {
  local v
  v="$(read_value FAKE_SWAP_TOTAL_MIB FAKE_SWAP_TOTAL_MIB_FILE "")"
  if [[ -z "$v" ]]; then
    v="$(read_value FAKE_SWAP_TOTAL_GB FAKE_SWAP_TOTAL_GB_FILE 0)"
    v=$(( v * 1024 ))
  fi
  printf '%s\n' "$v"
}

swap_size_mib() {
  read_value FAKE_SWAPFILE_SIZE_MIB FAKE_SWAPFILE_SIZE_MIB_FILE 0
}

swap_used_mib() {
  local v
  v="$(read_value FAKE_SWAPFILE_USED_MIB FAKE_SWAPFILE_USED_MIB_FILE "")"
  if [[ -z "$v" ]]; then
    v="$(read_value FAKE_SWAP_USED_GB FAKE_SWAP_USED_GB_FILE 0)"
    v=$(( v * 1024 ))
  fi
  printf '%s\n' "$v"
}

swap_on() {
  read_value FAKE_SWAP_ON FAKE_SWAP_ON_FILE 0
}

record() {
  [[ -n "${FAKE_SUDO_LOG:-}" ]] && printf '%s\n' "$*" >> "$FAKE_SUDO_LOG"
}

args=("$@")
while [[ ${#args[@]} -gt 0 ]]; do
  case "${args[0]}" in
    -n|-S) args=("${args[@]:1}") ;;
    -p) args=("${args[@]:2}") ;;
    *) break ;;
  esac
done

if [[ "${args[0]:-}" == "true" ]]; then
  exit 0
fi

if [[ "${args[0]:-}" == "tee" ]]; then
  target="${args[1]:-}"
  content="$(cat)"
  record "tee ${target}: ${content}"
  if [[ "$target" == "/etc/sysctl.d/99-spark.conf" && "$content" =~ vm.swappiness=([0-9]+) ]]; then
    write_value FAKE_SWAPPINESS_FILE "${BASH_REMATCH[1]}"
  fi
  exit 0
fi

if [[ "${args[0]:-}" == "bash" && "${args[1]:-}" == "-c" ]]; then
  cmd="${args[2]:-}"
  record "$cmd"
  if [[ "$cmd" == *"/swapfile.spark"* && "$cmd" == *"fallocate -l "* ]]; then
    desired="$(sed -n 's/.*fallocate -l \([0-9][0-9]*\)M .*/\1/p' <<<"$cmd")"
    total="$(swap_total_mib)"
    size="$(swap_size_mib)"
    on="$(swap_on)"
    base="$total"
    if [[ "$on" == "1" && "$size" -gt 0 ]]; then
      base=$(( total - size ))
      [[ "$base" -lt 0 ]] && base=0
    fi
    write_value FAKE_SWAPFILE_SIZE_MIB_FILE "$desired"
    write_value FAKE_SWAP_ON_FILE 1
    write_value FAKE_SWAPFILE_USED_MIB_FILE 0
    write_value FAKE_SWAP_TOTAL_MIB_FILE $(( base + desired ))
  elif [[ "$cmd" == *"swapon '/swapfile.spark'"* || "$cmd" == *"swapon /swapfile.spark"* ]]; then
    total="$(swap_total_mib)"
    size="$(swap_size_mib)"
    on="$(swap_on)"
    if [[ "$on" != "1" ]]; then
      write_value FAKE_SWAP_TOTAL_MIB_FILE $(( total + size ))
    fi
    write_value FAKE_SWAP_ON_FILE 1
  fi
  exit "${FAKE_SUDO_EXIT:-0}"
fi

record "${args[*]}"
exit "${FAKE_SUDO_EXIT:-0}"
EOF
  chmod +x "${dir}/sudo"

  cat > "${dir}/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "/swapfile.spark" && "$*" == *"-c%s"* || "${*: -1}" == "/swapfile.spark" && "$*" == *"-f%z"* ]]; then
  if [[ -n "${FAKE_SWAPFILE_SIZE_MIB_FILE:-}" && -f "$FAKE_SWAPFILE_SIZE_MIB_FILE" ]]; then
    mib=$(cat "$FAKE_SWAPFILE_SIZE_MIB_FILE")
  else
    mib="${FAKE_SWAPFILE_SIZE_MIB:-0}"
  fi
  [[ "$mib" -gt 0 ]] || exit 1
  printf '%s\n' $(( mib * 1048576 ))
  exit 0
fi
exec /usr/bin/stat "$@"
EOF
  chmod +x "${dir}/stat"

  # swapon mock: prints active swap devices. FAKE_SWAP_ON=1 → spark's swapfile present; default off.
  cat > "${dir}/swapon" <<'EOF'
#!/usr/bin/env bash
read_value() {
  local env_name="$1" file_name="$2" fallback="$3" file_path=""
  file_path="${!file_name:-}"
  if [[ -n "$file_path" && -f "$file_path" ]]; then
    cat "$file_path"
  elif [[ -n "${!env_name:-}" ]]; then
    printf '%s\n' "${!env_name}"
  else
    printf '%s\n' "$fallback"
  fi
}
on="$(read_value FAKE_SWAP_ON FAKE_SWAP_ON_FILE 0)"
total_mib="$(read_value FAKE_SWAP_TOTAL_MIB FAKE_SWAP_TOTAL_MIB_FILE "")"
if [[ -z "$total_mib" ]]; then
  total_gb="$(read_value FAKE_SWAP_TOTAL_GB FAKE_SWAP_TOTAL_GB_FILE 0)"
  total_mib=$(( total_gb * 1024 ))
fi
size_mib="$(read_value FAKE_SWAPFILE_SIZE_MIB FAKE_SWAPFILE_SIZE_MIB_FILE 0)"
used_mib="$(read_value FAKE_SWAPFILE_USED_MIB FAKE_SWAPFILE_USED_MIB_FILE "")"
if [[ -z "$used_mib" ]]; then
  used_gb="$(read_value FAKE_SWAP_USED_GB FAKE_SWAP_USED_GB_FILE 0)"
  used_mib=$(( used_gb * 1024 ))
fi
case "$*" in
  *"--show=SIZE"*|*"--show SIZE"*)
    if [[ "$total_mib" -gt 0 ]]; then
      printf '%s\n' $(( total_mib * 1048576 ))
    elif [[ "$on" == "1" && "$size_mib" -gt 0 ]]; then
      printf '%s\n' $(( size_mib * 1048576 ))
    fi
    ;;
  *"--show=NAME,USED"*|*"--show=NAME,USED --bytes"*)
    [[ "$on" == "1" ]] && printf '/swapfile.spark %s\n' $(( used_mib * 1048576 ))
    ;;
  *"--show=NAME"*)
    [[ "$on" == "1" ]] && echo "/swapfile.spark"
    ;;
esac
exit 0
EOF
  chmod +x "${dir}/swapon"

  # free mock: supports free -g and free -m. Swap total default 0 (off).
  cat > "${dir}/free" <<'EOF'
#!/usr/bin/env bash
read_value() {
  local env_name="$1" file_name="$2" fallback="$3" file_path=""
  file_path="${!file_name:-}"
  if [[ -n "$file_path" && -f "$file_path" ]]; then
    cat "$file_path"
  elif [[ -n "${!env_name:-}" ]]; then
    printf '%s\n' "${!env_name}"
  else
    printf '%s\n' "$fallback"
  fi
}
st_mib="$(read_value FAKE_SWAP_TOTAL_MIB FAKE_SWAP_TOTAL_MIB_FILE "")"
if [[ -z "$st_mib" ]]; then
  st_gb="$(read_value FAKE_SWAP_TOTAL_GB FAKE_SWAP_TOTAL_GB_FILE 0)"
  st_mib=$(( st_gb * 1024 ))
fi
su_mib="$(read_value FAKE_SWAP_USED_MIB FAKE_SWAP_USED_MIB_FILE "")"
if [[ -z "$su_mib" ]]; then
  su_gb="$(read_value FAKE_SWAP_USED_GB FAKE_SWAP_USED_GB_FILE 0)"
  su_mib=$(( su_gb * 1024 ))
fi
if [[ "$*" == *"-m"* ]]; then
  div=1
else
  div=1024
fi
st=$(( st_mib / div )); su=$(( su_mib / div ))
rt="${FAKE_RAM_TOTAL_GB:-121}"; ru="${FAKE_RAM_USED_GB:-40}"; rf="${FAKE_RAM_FREE_GB:-50}"; ra="${FAKE_RAM_AVAIL_GB:-114}"
if [[ "$div" -eq 1 ]]; then
  rt=$(( rt * 1024 )); ru=$(( ru * 1024 )); rf=$(( rf * 1024 )); ra=$(( ra * 1024 ))
fi
printf '               total        used        free      shared  buff/cache   available\n'
printf 'Mem:    %11d %11d %11d %11d %11d %11d\n' "$rt" "$ru" "$rf" 0 28 "$ra"
printf 'Swap:   %11d %11d %11d\n' "$st" "$su" "$(( st - su ))"
EOF
  chmod +x "${dir}/free"

  # sysctl mock: report vm.swappiness from FAKE_SWAPPINESS (empty = unset).
  cat > "${dir}/sysctl" <<'EOF'
#!/usr/bin/env bash
read_swappiness() {
  if [[ -n "${FAKE_SWAPPINESS_FILE:-}" && -f "$FAKE_SWAPPINESS_FILE" ]]; then
    cat "$FAKE_SWAPPINESS_FILE"
  else
    printf '%s\n' "${FAKE_SWAPPINESS:-}"
  fi
}
case "$*" in
  *vm.swappiness*) read_swappiness ;;
esac
exit 0
EOF
  chmod +x "${dir}/sysctl"

  cat > "${dir}/tailscale" <<'EOF'
#!/usr/bin/env bash
[[ -n "${FAKE_TAILSCALE_FILE:-}" ]] && printf '%s\n' "$*" >> "${FAKE_TAILSCALE_FILE}"
case "${1:-}" in
  ip)
    [[ "${2:-}" == "-4" ]] && echo "${FAKE_TAILSCALE_IP:-100.64.0.10}" ;;
  version)
    if [[ -n "${FAKE_TAILSCALE_UPDATE_MARKER:-}" && -e "$FAKE_TAILSCALE_UPDATE_MARKER" ]]; then
      echo "${FAKE_TAILSCALE_VERSION_AFTER_UPDATE:-1.96.5}"
    else
      echo "${FAKE_TAILSCALE_VERSION:-1.96.5}"
    fi ;;
  update)
    [[ -n "${FAKE_TAILSCALE_UPDATE_MARKER:-}" ]] && : > "$FAKE_TAILSCALE_UPDATE_MARKER"
    exit "${FAKE_TAILSCALE_UPDATE_EXIT:-0}" ;;
  status)
    if [[ "${2:-}" == "--json" ]]; then
      if [[ -n "${FAKE_TAILSCALE_STATUS_JSON_FILE:-}" && -f "$FAKE_TAILSCALE_STATUS_JSON_FILE" ]]; then
        cat "$FAKE_TAILSCALE_STATUS_JSON_FILE"
      elif [[ -n "${FAKE_TAILSCALE_STATUS_JSON:-}" ]]; then
        printf '%s\n' "$FAKE_TAILSCALE_STATUS_JSON"
      else
        printf '%s\n' '{"MagicDNSSuffix":"test-tailnet.ts.net."}'
      fi
      exit 0
    fi
    exit "${FAKE_TAILSCALE_STATUS_EXIT:-1}" ;;
  serve)
    if [[ "${2:-}" == "get-config" && "${3:-}" == "--all" ]]; then
      echo "${FAKE_TAILSCALE_SERVE_CONFIG:-svc:tasks 127.0.0.1:3456\nsvc:n8n 127.0.0.1:5678\nsvc:hermes 127.0.0.1:18790}"
      exit "${FAKE_TAILSCALE_GET_CONFIG_EXIT:-0}"
    fi
    [[ "${2:-}" == "status" ]] && exit 0
    [[ -n "${FAKE_TAILSCALE_SERVE_STDERR:-}" ]] && printf '%s\n' "${FAKE_TAILSCALE_SERVE_STDERR}" >&2
    exit "${FAKE_TAILSCALE_SERVE_EXIT:-0}" ;;
  funnel)
    if [[ "${2:-}" == "reset" ]]; then
      [[ -n "${FAKE_TAILSCALE_FUNNEL_RESET_MARKER:-}" ]] && : > "$FAKE_TAILSCALE_FUNNEL_RESET_MARKER"
      exit "${FAKE_TAILSCALE_FUNNEL_RESET_EXIT:-0}"
    fi
    if [[ "${2:-}" == "status" ]]; then
      if [[ -n "${FAKE_TAILSCALE_FUNNEL_RESET_MARKER:-}" && -e "$FAKE_TAILSCALE_FUNNEL_RESET_MARKER" ]]; then
        printf '%b' "${FAKE_TAILSCALE_FUNNEL_AFTER_RESET_STATUS:-}"
        exit "${FAKE_TAILSCALE_FUNNEL_AFTER_RESET_EXIT:-1}"
      fi
      printf '%b' "${FAKE_TAILSCALE_FUNNEL_STATUS:-}"
      exit "${FAKE_TAILSCALE_FUNNEL_EXIT:-1}"
    fi
    exit 1 ;;
  *)
    exit 0 ;;
esac
EOF
  chmod +x "${dir}/tailscale"

  cat > "${dir}/nemohermes" <<'EOF'
#!/usr/bin/env bash
[[ -n "${FAKE_NEMOHERMES_FILE:-}" ]] && printf '%s\n' "$*" >> "${FAKE_NEMOHERMES_FILE}"
[[ -n "${FAKE_NEMOHERMES_FILE:-}" ]] && printf 'NEMOCLAW_AGENT=%s\n' "${NEMOCLAW_AGENT:-}" >> "${FAKE_NEMOHERMES_FILE}"
[[ -n "${FAKE_NEMOHERMES_FILE:-}" ]] && printf 'NEMOCLAW_PREFERRED_API=%s\n' "${NEMOCLAW_PREFERRED_API:-}" >> "${FAKE_NEMOHERMES_FILE}"
[[ -n "${FAKE_NEMOHERMES_FILE:-}" ]] && printf 'NEMOCLAW_ENDPOINT_URL=%s\n' "${NEMOCLAW_ENDPOINT_URL:-}" >> "${FAKE_NEMOHERMES_FILE}"
[[ -n "${FAKE_NEMOHERMES_FILE:-}" ]] && printf 'NEMOCLAW_MODEL=%s\n' "${NEMOCLAW_MODEL:-}" >> "${FAKE_NEMOHERMES_FILE}"
[[ -n "${FAKE_NEMOHERMES_FILE:-}" ]] && printf 'COMPATIBLE_API_KEY=%s\n' "${COMPATIBLE_API_KEY:-}" >> "${FAKE_NEMOHERMES_FILE}"
[[ -n "${FAKE_NEMOHERMES_FILE:-}" ]] && printf 'NEMOCLAW_LOCAL_INFERENCE_TIMEOUT=%s\n' "${NEMOCLAW_LOCAL_INFERENCE_TIMEOUT:-}" >> "${FAKE_NEMOHERMES_FILE}"
[[ -n "${FAKE_NEMOHERMES_FILE:-}" ]] && printf 'NEMOCLAW_SANDBOX_READY_TIMEOUT=%s\n' "${NEMOCLAW_SANDBOX_READY_TIMEOUT:-}" >> "${FAKE_NEMOHERMES_FILE}"
[[ -n "${FAKE_NEMOHERMES_FILE:-}" ]] && printf 'NEMOCLAW_NO_GPU=%s\n' "${NEMOCLAW_NO_GPU:-}" >> "${FAKE_NEMOHERMES_FILE}"
[[ -n "${FAKE_NEMOHERMES_FILE:-}" ]] && printf 'NEMOCLAW_SANDBOX_GPU=%s\n' "${NEMOCLAW_SANDBOX_GPU:-}" >> "${FAKE_NEMOHERMES_FILE}"
[[ -n "${FAKE_NEMOHERMES_FILE:-}" ]] && printf 'CHAT_UI_URL=%s\n' "${CHAT_UI_URL:-}" >> "${FAKE_NEMOHERMES_FILE}"
[[ -n "${FAKE_NEMOHERMES_FILE:-}" ]] && printf 'NEMOCLAW_HERMES_DASHBOARD_HOST=%s\n' "${NEMOCLAW_HERMES_DASHBOARD_HOST:-}" >> "${FAKE_NEMOHERMES_FILE}"
[[ -n "${FAKE_NEMOHERMES_FILE:-}" ]] && printf 'NEMOCLAW_CONFIRM_LEGACY_MANAGED_RECREATE=%s\n' "${NEMOCLAW_CONFIRM_LEGACY_MANAGED_RECREATE:-}" >> "${FAKE_NEMOHERMES_FILE}"
case "$*" in
  *"update --check"*) echo "${FAKE_NEMOHERMES_UPDATE_CHECK:-Current NemoHermes version: 0.0.55
Latest maintained version: 0.0.78
Update available:         no}"; exit "${FAKE_NEMOHERMES_UPDATE_CHECK_EXIT:-0}" ;;
  *"update --yes"*) exit "${FAKE_NEMOHERMES_UPDATE_EXIT:-0}" ;;
  *dashboard-url*) echo "${FAKE_NEMOHERMES_DASHBOARD_URL:-http://127.0.0.1:18789}" ;;
  *"inference get --json"*) echo "${FAKE_NEMOHERMES_INFERENCE_JSON:-{\"provider\":\"compatible-endpoint\",\"model\":\"vllm/Org/Alpha\"}}" ;;
  *"inference get"*) echo "${FAKE_NEMOHERMES_INFERENCE_TEXT:-Provider: compatible-endpoint Model: vllm/Org/Alpha}" ;;
  *"policy-explain --json"*) echo "${FAKE_NEMOHERMES_POLICY_JSON:-{\"tier\":\"restricted\",\"appliedPresets\":[]}}" ;;
  *"policy-explain"*) echo "${FAKE_NEMOHERMES_POLICY_TEXT:-Policy tier: restricted}" ;;
  *"policy-list"*) echo "${FAKE_NEMOHERMES_POLICY_LIST:-restricted}" ;;
  *"hermes exec"*"hermes tools list --platform cli"*)
    printf '%b\n' "${FAKE_HERMES_TOOLS_LIST:-Built-in toolsets (cli):
  enabled  terminal
  enabled  file
  enabled  web
  enabled  skills
  enabled  memory
  enabled  todo
  enabled  cronjob
  enabled  delegation
  disabled  browser
  disabled  code_execution
  disabled  vision
  disabled  video
  disabled  image_gen
  disabled  video_gen
  disabled  x_search
  disabled  tts
  disabled  context_engine
  disabled  session_search
  disabled  clarify
  disabled  homeassistant
  disabled  spotify
  disabled  yuanbao
  disabled  computer_use}" ;;
  *"channels status --channel whatsapp --json"*) echo "${FAKE_WHATSAPP_STATUS_JSON:-{\"verdict\":\"healthy\"}}" ;;
  *"hermes exec"*"-X POST"*"/labels"*)
    [[ "${FAKE_HERMES_TODOIST_LABEL_CREATE_EXIT:-0}" == "0" ]] || exit "${FAKE_HERMES_TODOIST_LABEL_CREATE_EXIT}"
    [[ -n "${FAKE_HERMES_TODOIST_LABEL_STATE_FILE:-}" ]] && : > "$FAKE_HERMES_TODOIST_LABEL_STATE_FILE"
    echo '{"id":"label-hermes","name":"Hermes"}'
    exit 0 ;;
  *"hermes exec"*"/labels?limit=200"*)
    if [[ -n "${FAKE_HERMES_TODOIST_LABELS_JSON:-}" ]]; then
      printf '%s\n' "$FAKE_HERMES_TODOIST_LABELS_JSON"
    elif [[ -n "${FAKE_HERMES_TODOIST_LABEL_STATE_FILE:-}" && ! -e "$FAKE_HERMES_TODOIST_LABEL_STATE_FILE" ]]; then
      echo '{"results":[],"next_cursor":null}'
      exit 1
    else
      echo '{"results":[{"id":"label-hermes","name":"Hermes"}],"next_cursor":null}'
    fi
    exit "${FAKE_HERMES_TODOIST_API_EXIT:-0}" ;;
  *"hermes exec"*"/projects?limit=1"*)
    echo "${FAKE_HERMES_TODOIST_PROJECTS_JSON:-{\"results\":[]}}"
    exit "${FAKE_HERMES_TODOIST_API_EXIT:-0}" ;;
  *"hermes exec"*"/user"*)
    echo "${FAKE_HERMES_VIKUNJA_USER_JSON:-{\"id\":3,\"username\":\"bot-hermes\",\"bot_owner_id\":1}}"
    exit "${FAKE_HERMES_VIKUNJA_API_EXIT:-0}" ;;
  *doctor*) exit "${FAKE_NEMOHERMES_DOCTOR_EXIT:-0}" ;;
  *status*) echo "${FAKE_NEMOHERMES_STATUS:-Hermes ready}" ;;
  *logs*) echo "Hermes logs" ;;
esac
exit "${FAKE_NEMOHERMES_EXIT:-0}"
EOF
  chmod +x "${dir}/nemohermes"

  cat > "${dir}/openshell" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
[[ -n "${FAKE_OPENSHELL_FILE:-}" ]] && printf '%s\n' "$args" >> "$FAKE_OPENSHELL_FILE"
case "$args" in
  "settings get --global --json")
    printf '{"settings":{"providers_v2_enabled":"%s"}}\n' "${FAKE_OPENSHELL_PROVIDERS_V2:-true}" ;;
  "settings set --global --key providers_v2_enabled --value true --yes")
    exit "${FAKE_OPENSHELL_SETTINGS_EXIT:-0}" ;;
  "provider list -o json")
    if [[ "${FAKE_OPENSHELL_PROVIDER_EXISTS:-1}" == "1" ]]; then
      printf '[{"name":"spark-vikunja","type":"generic","credential_keys":["VIKUNJA_API_TOKEN"]}]\n'
    else
      printf '[]\n'
    fi ;;
  provider\ create*|provider\ update*)
    exit "${FAKE_OPENSHELL_PROVIDER_EXIT:-0}" ;;
  "sandbox provider list hermes")
    if [[ "${FAKE_OPENSHELL_PROVIDER_ATTACHED:-1}" == "1" ]]; then
      printf 'spark-vikunja  generic  1  0\n'
    fi ;;
  sandbox\ provider\ attach*|policy\ update*)
    exit "${FAKE_OPENSHELL_POLICY_EXIT:-0}" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "${dir}/openshell"

  # ssh mock for spark setup remote tests. Opening the ControlMaster (-fN) and closing it
  # (-O exit) succeed; otherwise the last arg is the remote command and we answer probes.
  # FAKE_SSH_NVIDIA=1 makes the fake remote look like an NVIDIA/vLLM box.
  cat > "${dir}/ssh" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  [[ "$a" == "-fN" || "$a" == "-O" ]] && exit 0
done
cmd="${@: -1}"
if [[ "$cmd" == "bash -s" ]]; then
  cmd=$(cat)
  [[ -n "${FAKE_SSH_SCRIPT_FILE:-}" ]] && printf '%s\n' "$cmd" >> "$FAKE_SSH_SCRIPT_FILE"
fi
case "$cmd" in
  *"uname -s"*)            echo Linux ;;
  *"uname -m"*)            echo aarch64 ;;
  *"nvidia-smi -L"*)       [[ "${FAKE_SSH_NVIDIA:-0}" == "1" ]] && exit 0 || exit 1 ;;
  *"query-gpu"*)           echo "Remote GPU" ;;
  *"mkdir -p ~/.local/bin"*) exit 0 ;;
  *"cat > ~/.local/bin/spark"*) exit 0 ;;
  *"mkdir -p ~/.local/share/spark/scripts"*) exit 0 ;;
  *"cat > ~/.local/share/spark/scripts/hf_model_inspect.py"*) exit 0 ;;
  *"hf-inspect-venv/bin/python -c"*) exit 0 ;;
  *'grep -q "local/bin"'*) exit 0 ;;
  *"command -v ollama"*)   exit 1 ;;
  *"command -v systemctl"*) exit 0 ;;
  *is-active*earlyoom*)    exit 1 ;;
  *"list-unit-files"*)     echo "ssh.service enabled enabled" ;;
  *"show -p MemoryMin"*)   echo "" ;;
  *'grep -m1 "^VERSION="'*) echo "${FAKE_REMOTE_SPARK_VERSION:-0.0.0}" ;;
  *"export SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo"*\
*"export SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com"*\
*"export SPARK_WORKSPACE_N8N_EMAIL=m@example.com"*\
*"export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH; spark ws setup --yes --model Org/Alpha --tailscale-mode ports --task-manager vikunja --postgres-image postgres:18.1 --vikunja-image vikunja/vikunja:1.2.3 --n8n-image docker.n8n.io/n8nio/n8n:1.100.0"*) echo "remote workspace with creds ok" ;;
  *"export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH; spark ws setup --check --model Org/Alpha --tailscale-mode ports --task-manager vikunja --postgres-image postgres:18.1 --vikunja-image vikunja/vikunja:1.2.3 --n8n-image docker.n8n.io/n8nio/n8n:1.100.0"*) echo "remote workspace with opts ok" ;;
  *"export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH; spark ws setup --check --model Org/Alpha --task-manager vikunja"*) echo "remote workspace ok" ;;
  *"export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH; spark ws doctor --strict --model Org/Alpha"*) echo "remote strict doctor ok" ;;
  *"export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH; spark ws doctor --model Org/Alpha"*) echo "remote doctor ok" ;;
  *)                       exit 1 ;;
esac
exit 0
EOF
  chmod +x "${dir}/ssh"

  # hf mock: "downloads" by writing files into the HF cache. config.json carries known
  # KV dims; the index reports ~14 GB of weights (total_size).
  cat > "${dir}/hf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "download" ]] || exit 0
repo="$2"; file="${3:-}"
dir="${HOME}/.cache/huggingface/hub/models--${repo//\//--}/snapshots/1"
mkdir -p "$dir"
case "$file" in
  config.json)
    cat > "${dir}/config.json" <<JSON
{ "model_type":"qwen3","architectures":["Qwen3ForCausalLM"],"num_hidden_layers":48,
  "num_key_value_heads":4,"num_attention_heads":32,"head_dim":128,"hidden_size":2048,
  "max_position_embeddings":262144,"quantization_config":{"quant_method":"nvfp4"} }
JSON
    ;;
  model.safetensors.index.json)
    echo '{ "metadata": { "total_size": 15032385536 } }' > "${dir}/model.safetensors.index.json"
    ;;
  "")
    : > "${dir}/model-00001-of-00001.safetensors"
    ;;
esac
EOF
  chmod +x "${dir}/hf"
}

test_suite_includes() {
  local test_id="$1"
  [[ "$test_suite" == "all" ]] && return 0

  case "$test_id" in
    test_architecture_command_maps_core_boundaries|\
    test_single_file_build_matches_modules|\
    test_source_guard_loads_without_dispatch|\
    test_alias_create_preserves_dash_prefixed_args|\
    test_alias_capture_replays_image_env_and_operational_overrides|\
    test_alias_capture_rejects_secret_flags|\
    test_alias_backend_mismatch_fails_closed|\
    test_bundle_catalog_embeds_and_validates_builtin|\
    test_bundle_validation_requires_declared_applied_patches|\
    test_bundle_sync_checks_git_catalog|\
    test_bundle_submit_dry_run_prepares_new_and_updated_changes|\
    test_bundle_submit_opens_confirmed_draft_pr|\
    test_bundle_submit_uses_fork_without_write_permission|\
    test_bundle_imports_external_folder_and_run_builds_with_docker_cache|\
    test_bundle_run_resolves_defaults_and_dynamic_options|\
    test_alias_create_from_bundle_stores_bundle_and_adjustments|\
    test_total_mem_detection_positive|\
    test_port_auto_skips_busy|\
    test_config_set_and_show|\
    test_pull_ollama_routes|\
    test_status_ollama_lists|\
    test_stop_ollama_unloads|\
    test_detect_metal_on_apple_silicon|\
    test_detect_cpu_without_gpu|\
    test_gateway_ollama_route_mac|\
    test_setup_picker_routes_to_host|\
    test_help_text_tracks_current_cli|\
    test_workspace_help_and_command|\
    test_workspace_dashboard_proxy_rewrites_host_on_loopback|\
    test_workspace_status_json_quiet_and_containers|\
    test_workspace_backup_manifest_and_verify|\
    test_workspace_backup_verify_flags_public_backup_file)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

run_test() {
  local name="$1" test_id="${2:-}" test_number
  shift

  discovered=$((discovered + 1))
  test_suite_includes "$test_id" || return 0
  eligible=$((eligible + 1))
  test_number=$((eligible - 1))
  (( test_number % test_shard_total == test_shard_index )) || return 0
  selected=$((selected + 1))

  if [[ "$test_list_only" == "1" ]]; then
    printf "%s\n" "$test_id"
    return 0
  fi

  if "$@"; then
    printf "ok - %s\n" "$name"
    passed=$((passed + 1))
  else
    printf "not ok - %s\n" "$name"
    failed=$((failed + 1))
  fi
}

test_architecture_command_maps_core_boundaries() {
  local tmp output
  tmp=$(mktemp -d)
  output=$(HOME="${tmp}/home" SPARK_BACKEND=vllm SPARK_ACCEL=cuda-unified "$SPARK" architecture 2>&1)
  rm -rf "$tmp"

  [[ "$output" == *"Packaging invariant:"* ]] &&
    [[ "$output" == *"Runtime domains:"* ]] &&
    [[ "$output" == *"src/commands/*.sh"* ]] &&
    [[ "$output" == *"workspace"* ]] &&
    [[ "$output" == *"gateway"* ]] &&
    [[ "$output" == *"docs/architecture.md"* ]]
}

test_single_file_build_matches_modules() {
  "${ROOT_DIR}/scripts/build-single-file.sh" --check
}

test_source_guard_loads_without_dispatch() {
  local tmp output status
  tmp=$(mktemp -d)
  output=$(HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=x86_64 SPARK_ACCEL=cpu SPARK_BACKEND=ollama bash -c '
    script="$1"
    set -- unknown
    source "$script"
    declare -F main >/dev/null
    declare -F cmd_architecture >/dev/null
    printf "loaded:%s:%s\n" "$VERSION" "$BACKEND"
  ' _ "$SPARK" 2>&1)
  status=$?
  rm -rf "$tmp"

  [[ "$status" -eq 0 ]] && [[ "$output" == loaded:*:ollama ]]
}

test_super_productivity_workspace_files() {
  local tmp compose env sync_env dockerfile supersync_dockerfile supersync_patch headless_patch gateway_absent mode init_mode
  tmp=$(mktemp -d)
  HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama SPARK_WORKSPACE_TASK_MANAGER=super-productivity \
    SPARK_WORKSPACE_TAILSCALE_MODE=services bash -c '
      source "$1"
      mkdir -p "$WORKSPACE_CONFIG_DIR"
      workspace_install_file "$WORKSPACE_ENV_FILE" 600 <<EOF
WORKSPACE_SUPERSYNC_IMAGE=spark/supersync:18.7.0
WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_IMAGE=spark/super-productivity-electron:18.7.0
WORKSPACE_SUPER_PRODUCTIVITY_VERSION=v18.7.0
WORKSPACE_SUPER_PRODUCTIVITY_COMMIT=4212ed4b0d95b3610f565d077966274fd1294831
EOF
      workspace_write_files_super_productivity robin-triceratops.ts.net massimo m@example.com unused m@example.com unused Org/Alpha
    ' _ "$SPARK" >/dev/null 2>&1
  compose=$(cat "${tmp}/home/.config/spark/workspace/docker-compose.yml")
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env")
  sync_env=$(cat "${tmp}/home/.config/spark/workspace/super-productivity.env")
  dockerfile=$(cat "${tmp}/home/.config/spark/workspace/super-productivity-electron/Dockerfile")
  supersync_dockerfile=$(cat "${tmp}/home/.config/spark/workspace/supersync/Dockerfile")
  supersync_patch=$(cat "${tmp}/home/.config/spark/workspace/supersync/spark-initial-passkey.patch")
  headless_patch=$(cat "${tmp}/home/.config/spark/workspace/super-productivity-electron/spark-headless.patch")
  [[ ! -e "${tmp}/home/.config/spark/workspace/super-productivity-gateway.conf" ]] && gateway_absent=1 || gateway_absent=0
  mode=$(stat -c '%a' "${tmp}/home/.config/spark/workspace/super-productivity.env" 2>/dev/null || stat -f '%Lp' "${tmp}/home/.config/spark/workspace/super-productivity.env")
  init_mode=$(stat -c '%a' "${tmp}/home/.config/spark/workspace/init-db.sh" 2>/dev/null || stat -f '%Lp' "${tmp}/home/.config/spark/workspace/init-db.sh")
  rm -rf "$tmp"
  [[ "$env" == *"WORKSPACE_TASK_MANAGER=super-productivity"* ]] &&
    [[ "$env" == *"WORKSPACE_SUPERSYNC_IMAGE=spark/supersync:18.15.1"* ]] &&
    [[ "$env" == *"WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_IMAGE=spark/super-productivity-electron:18.15.1"* ]] &&
    [[ "$env" == *"WORKSPACE_SUPER_PRODUCTIVITY_VERSION=v18.15.1"* ]] &&
    [[ "$env" == *"WORKSPACE_SUPER_PRODUCTIVITY_COMMIT=014b789c22c9bf75fd7202845639569b61e7cd8e"* ]] &&
    [[ "$env" == *"TASK_MANAGER_URL=https://tasks.robin-triceratops.ts.net"* ]] &&
    [[ "$env" == *"SUPER_PRODUCTIVITY_BROWSER_SYNC_STATUS=pending"* ]] &&
    [[ "$env" == *$'SUPER_PRODUCTIVITY_BROWSER_SYNC_URL=\n'* ]] &&
    [[ "$compose" == *$'  supersync:\n'* ]] &&
    [[ "$compose" == *$'  super-productivity-electron:\n'* ]] &&
    [[ "$compose" != *$'  super-productivity-web:\n'* ]] &&
    [[ "$compose" != *$'  super-productivity-gateway:\n'* ]] &&
    [[ "$compose" != *$'  vikunja:\n'* ]] &&
    [[ "$compose" == *'127.0.0.1:3456:1900'* ]] &&
    [[ "$compose" == *":/var/lib/postgresql"$'\n'* ]] &&
    [[ "$compose" == *"context: ${tmp}/home/.config/spark/workspace/supersync"* ]] &&
    [[ "$compose" != *'super-productivity/super-productivity:latest'* ]] &&
    [[ "$sync_env" == *"PUBLIC_URL=https://tasks.robin-triceratops.ts.net"* ]] &&
    [[ "$sync_env" == *"CORS_ORIGINS=https://tasks.robin-triceratops.ts.net,https://app.super-productivity.com"* ]] &&
    [[ "$sync_env" == *"SUPERSYNC_INTERNAL_URL=http://supersync:1900"* ]] &&
    [[ "$sync_env" == *"SPARK_HEADLESS=1"* ]] &&
    [[ "$dockerfile" == *"TARGETARCH"* ]] &&
    [[ "$dockerfile" == *"git apply --unidiff-zero"* ]] &&
    [[ "$dockerfile" == *"npm ci --ignore-scripts || npm install --ignore-scripts"* ]] &&
    [[ "$dockerfile" == *"xvfb xauth socat"* ]] &&
    [[ "$supersync_dockerfile" == *"packages/super-sync-server"* ]] &&
    [[ "$dockerfile" == *"SUPER_PRODUCTIVITY_VERSION=v18.15.1"* ]] &&
    [[ "$dockerfile" == *"SUPER_PRODUCTIVITY_COMMIT=014b789c22c9bf75fd7202845639569b61e7cd8e"* ]] &&
    [[ "$supersync_dockerfile" == *"SUPER_PRODUCTIVITY_VERSION=v18.15.1"* ]] &&
    [[ "$supersync_dockerfile" == *"SUPER_PRODUCTIVITY_COMMIT=014b789c22c9bf75fd7202845639569b61e7cd8e"* ]] &&
    [[ "$supersync_dockerfile" == *"COPY spark-initial-passkey.patch"* ]] &&
    [[ "$supersync_dockerfile" == *"git apply --check --unidiff-zero /tmp/spark-initial-passkey.patch"* ]] &&
    [[ "$supersync_patch" == *"existingPasskeyCount === 0"* ]] &&
    [[ "$supersync_patch" == *": { tokenVersion: { increment: 1 } })"* ]] &&
    [[ "$headless_patch" != *$'+import { SyncProviderId '* ]] &&
    [[ "$headless_patch" == *"import { SyncWrapperService } from '../../imex/sync/sync-wrapper.service';"* ]] &&
    [[ "$headless_patch" == *"method === 'POST' && path === '/sync'"* ]] &&
    [[ "$headless_patch" == *"const syncResult = await this._syncWrapperService.sync(true);"* ]] &&
    [[ "$headless_patch" == *"synced: syncResult !== 'HANDLED_ERROR'"* ]] &&
    [[ "$gateway_absent" -eq 1 ]] &&
    [[ "$mode" == "600" ]] &&
    [[ "$init_mode" == "644" ]]
}

test_todoist_workspace_files() {
  local tmp compose env postgres_env n8n_env init mode
  tmp=$(mktemp -d)
  HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama SPARK_WORKSPACE_TASK_MANAGER=todoist \
    SPARK_WORKSPACE_TAILSCALE_MODE=services SPARK_WORKSPACE_TODOIST_TOKEN=todoist_test_token bash -c '
      source "$1"
      workspace_write_files_todoist robin-triceratops.ts.net massimo m@example.com unused m@example.com unused Org/Alpha
    ' _ "$SPARK" >/dev/null 2>&1
  compose=$(cat "${tmp}/home/.config/spark/workspace/docker-compose.yml")
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env")
  postgres_env=$(cat "${tmp}/home/.config/spark/workspace/postgres.env")
  n8n_env=$(cat "${tmp}/home/.config/spark/workspace/n8n.env")
  init=$(cat "${tmp}/home/.config/spark/workspace/init-db.sh")
  mode=$(stat -c '%a' "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || stat -f '%Lp' "${tmp}/home/.config/spark/workspace/secrets.env")
  rm -rf "$tmp"
  [[ "$env" == *"WORKSPACE_TASK_MANAGER=todoist"* ]] &&
    [[ "$env" == *"TODOIST_API_URL=https://api.todoist.com/api/v1"* ]] &&
    [[ "$env" == *"TODOIST_URL=https://app.todoist.com/app"* ]] &&
    [[ "$env" == *"TODOIST_API_TOKEN=todoist_test_token"* ]] &&
    [[ "$env" == *"TODOIST_API_STATUS=pending"* ]] &&
    [[ "$env" == *"TASK_MANAGER_URL=https://app.todoist.com/app"* ]] &&
    [[ "$compose" == *$'  postgres:\n'* ]] &&
    [[ "$compose" == *$'  n8n:\n'* ]] &&
    [[ "$compose" != *$'  vikunja:\n'* ]] &&
    [[ "$compose" != *$'  supersync:\n'* ]] &&
    [[ "$compose" != *$'  super-productivity-electron:\n'* ]] &&
    [[ "$compose" != *":3456:"* ]] &&
    [[ "$postgres_env" != *"TODOIST"* ]] &&
    [[ "$n8n_env" != *"TODOIST"* ]] &&
    [[ "$init" == *"CREATE DATABASE n8n"* ]] &&
    [[ "$init" != *"CREATE DATABASE vikunja"* ]] &&
    [[ "$init" != *"CREATE DATABASE supersync"* ]] &&
    [[ "$mode" == "600" ]]
}


test_super_productivity_custom_pins_are_preserved() {
  local tmp env
  tmp=$(mktemp -d)
  HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama SPARK_WORKSPACE_TASK_MANAGER=super-productivity \
    SPARK_WORKSPACE_TAILSCALE_MODE=services bash -c '
      source "$1"
      mkdir -p "$WORKSPACE_CONFIG_DIR"
      workspace_install_file "$WORKSPACE_ENV_FILE" 600 <<EOF
WORKSPACE_SUPERSYNC_IMAGE=registry.example/supersync:custom
WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_IMAGE=registry.example/electron:custom
WORKSPACE_SUPER_PRODUCTIVITY_VERSION=v18.14.0
WORKSPACE_SUPER_PRODUCTIVITY_COMMIT=2222222222222222222222222222222222222222
EOF
      workspace_write_files_super_productivity robin-triceratops.ts.net massimo m@example.com unused m@example.com unused Org/Alpha
    ' _ "$SPARK" >/dev/null 2>&1
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env")
  rm -rf "$tmp"
  [[ "$env" == *"WORKSPACE_SUPERSYNC_IMAGE=registry.example/supersync:custom"* ]] &&
    [[ "$env" == *"WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_IMAGE=registry.example/electron:custom"* ]] &&
    [[ "$env" == *"WORKSPACE_SUPER_PRODUCTIVITY_VERSION=v18.14.0"* ]] &&
    [[ "$env" == *"WORKSPACE_SUPER_PRODUCTIVITY_COMMIT=2222222222222222222222222222222222222222"* ]]
}


test_supersync_reconciles_pre_baseline_migration_history() {
  local tmp log status calls
  tmp=$(mktemp -d)
  log="${tmp}/calls"
  set +e
  HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama SPARK_TEST_LOG="$log" bash -c '
      source "$1"
      workspace_supersync_schema_exists() { return 0; }
      workspace_read_env() {
        [[ "$1" == SUPERSYNC_DATABASE_PASSWORD ]] || return 1
        printf "%s\n" secret
      }
      workspace_compose() {
        case " $* " in
          *" test -d prisma/migrations/0_init "*) return 0 ;;
          *" psql "*)
            payload=$(cat)
            [[ "$payload" == *"migration_name = '\''0_init'\''"* ]] || return 1
            [[ "$payload" == *"migration_name <> '\''0_init'\''"* ]] || return 1
            printf "%s\n" legacy
            ;;
          *" migrate resolve --rolled-back 0_init "*) printf "%s\n" rolled-back >> "$SPARK_TEST_LOG" ;;
          *" migrate resolve --applied 0_init "*) printf "%s\n" applied >> "$SPARK_TEST_LOG" ;;
          *) return 1 ;;
        esac
      }
      workspace_supersync_reconcile_baseline_migration
    ' _ "$SPARK" >/dev/null 2>&1
  status=$?
  set -e
  calls=$(cat "$log" 2>/dev/null || true)
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] && [[ "$calls" == $'rolled-back\napplied' ]]
}


test_supersync_baseline_reconciliation_is_idempotent() {
  local tmp log status
  tmp=$(mktemp -d)
  log="${tmp}/calls"
  set +e
  HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama SPARK_TEST_LOG="$log" bash -c '
      source "$1"
      workspace_supersync_schema_exists() { return 0; }
      workspace_read_env() { printf "%s\n" secret; }
      workspace_compose() {
        case " $* " in
          *" test -d prisma/migrations/0_init "*) return 0 ;;
          *" psql "*) cat >/dev/null; printf "%s\n" applied ;;
          *" migrate resolve "*) printf "%s\n" unexpected >> "$SPARK_TEST_LOG"; return 1 ;;
          *) return 1 ;;
        esac
      }
      workspace_supersync_reconcile_baseline_migration
    ' _ "$SPARK" >/dev/null 2>&1
  status=$?
  set -e
  [[ ! -e "$log" ]] || [[ ! -s "$log" ]]
  local no_calls=$?
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] && [[ "$no_calls" -eq 0 ]]
}


test_supersync_baseline_reconciliation_fails_closed_without_history() {
  local tmp log status
  tmp=$(mktemp -d)
  log="${tmp}/calls"
  set +e
  HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama SPARK_TEST_LOG="$log" bash -c '
      source "$1"
      workspace_supersync_schema_exists() { return 0; }
      workspace_read_env() { printf "%s\n" secret; }
      workspace_compose() {
        case " $* " in
          *" test -d prisma/migrations/0_init "*) return 0 ;;
          *" psql "*) cat >/dev/null; printf "%s\n" unknown ;;
          *" migrate resolve "*) printf "%s\n" unsafe >> "$SPARK_TEST_LOG"; return 0 ;;
          *) return 1 ;;
        esac
      }
      workspace_supersync_reconcile_baseline_migration
    ' _ "$SPARK" >/dev/null 2>&1
  status=$?
  set -e
  [[ ! -e "$log" ]] || [[ ! -s "$log" ]]
  local no_calls=$?
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] && [[ "$no_calls" -eq 0 ]]
}


test_supersync_user_ready_uses_stdin_query() {
  local tmp status
  tmp=$(mktemp -d)
  set +e
  HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama bash -c '
      source "$1"
      workspace_read_env() {
        case "$1" in
          SUPER_PRODUCTIVITY_USER_EMAIL) printf "%s\n" m@example.com ;;
          SUPERSYNC_DATABASE_PASSWORD) printf "%s\n" secret ;;
          *) return 1 ;;
        esac
      }
      workspace_compose() {
        [[ " $* " != *" -c "* ]] || return 1
        payload=$(cat)
        [[ "$payload" == *"FROM users"* ]] || return 1
        [[ "$payload" == *"lower(:'\''email'\'')"* ]] || return 1
        printf "%s\n" 1:0
      }
      workspace_supersync_user_ready
    ' _ "$SPARK" >/dev/null 2>&1
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]]
}

test_supersync_initial_passkey_enrollment_url() {
  local tmp out
  tmp=$(mktemp -d)
  out=$(HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama bash -c '
      source "$1"
      workspace_read_env() {
        [[ "$1" == SUPERSYNC_DATABASE_PASSWORD ]] || return 1
        printf "%s\n" secret
      }
      workspace_random_hex_token() {
        printf "%064d\n" 0
      }
      workspace_task_manager_url() {
        printf "%s\n" https://tasks.example.ts.net
      }
      workspace_compose() {
        payload=$(cat)
        [[ "$payload" == *"NOT EXISTS (SELECT 1 FROM passkeys"* ]] || return 1
        [[ "$payload" == *"+ 900000"* ]] || return 1
        [[ "$payload" != *"token_version"* ]] || return 1
        printf "%s\n" 1
      }
      workspace_supersync_create_passkey_enrollment_url m@example.com
    ' _ "$SPARK" 2>/dev/null)
  rm -rf "$tmp"
  [[ "$out" == "https://tasks.example.ts.net/recover-passkey?token=$(printf '%064d' 0)" ]]
}

test_super_productivity_sync_access_uses_temporary_pager() {
  local tmp out page token encryption
  tmp=$(mktemp -d)
  token=super-secret-access-token
  encryption=super-secret-encryption-key
  mkdir -p "${tmp}/home/.config/spark/workspace"
  cat > "${tmp}/home/.config/spark/workspace/secrets.env" <<EOF
WORKSPACE_TASK_MANAGER=super-productivity
TASK_MANAGER_URL=https://tasks.example.ts.net
SUPER_PRODUCTIVITY_USER_EMAIL=m@example.com
SUPERSYNC_ACCESS_TOKEN=${token}
SUPERSYNC_ENCRYPTION_PASSWORD=${encryption}
EOF
  out=$(HOME="${tmp}/home" PAGER_CAPTURE="${tmp}/pager" bash -c '
    source "$1"
    less() { [[ "$LESSHISTFILE" == "-" ]] && cat > "$PAGER_CAPTURE"; }
    WORKSPACE_SUPERSYNC_PASSKEY_ENROLLMENT_URL=https://tasks.example.ts.net/recover-passkey?token=temporary
    workspace_show_super_productivity_sync_access
  ' _ "$SPARK" 2>&1)
  page=$(cat "${tmp}/pager")
  rm -rf "$tmp"
  [[ "$out" != *"$token"* && "$out" != *"$encryption"* ]]
  [[ "$page" == *"$token"* && "$page" == *"$encryption"* ]]
  [[ "$page" == *"https://tasks.example.ts.net"* ]]
  [[ "$page" == *"recover-passkey?token=temporary"* ]]
}

test_super_productivity_onboarding_verifies_round_trip() {
  local tmp out state
  tmp=$(mktemp -d)
  out=$(printf '\n\nSYNCED\n' | HOME="${tmp}/home" STATE_FILE="${tmp}/state" bash -c '
    source "$1"
    SETUP_FAILED=()
    is_interactive() { return 0; }
    workspace_task_manager() { printf "%s\n" super-productivity; }
    passkey_checks=0
    workspace_supersync_passkey_ready() {
      passkey_checks=$((passkey_checks + 1))
      [[ "$passkey_checks" -gt 1 ]]
    }
    workspace_super_productivity_browser_sync_ready() { return 1; }
    workspace_supersync_create_passkey_enrollment_url() {
      printf "%s\n" https://tasks.example.ts.net/recover-passkey?token=temporary
    }
    workspace_show_super_productivity_sync_access() {
      [[ "$WORKSPACE_SUPERSYNC_PASSKEY_ENROLLMENT_URL" == *"temporary"* ]]
    }
    workspace_task_manager_url() { printf "%s\n" https://tasks.example.ts.net; }
    workspace_read_env() {
      [[ "$1" == SUPER_PRODUCTIVITY_USER_EMAIL ]] && printf "%s\n" m@example.com
    }
    workspace_random_hex_token() { printf "%s\n" 1234567890abcdef; }
    workspace_wait_for_super_productivity_sync_task() {
      [[ "$1" == spark-sync-check-1234567890 ]] && printf "%s\n" task-1
    }
    workspace_wait_for_super_productivity_sync_ready() { return 0; }
    workspace_delete_super_productivity_sync_task() { [[ "$1" == task-1 ]]; }
    workspace_wait_for_supersync_task_delete() { [[ "$1" == task-1 ]]; }
    workspace_set_env_key() { printf "%s=%s\n" "$1" "$2" >> "$STATE_FILE"; }
    workspace_complete_super_productivity_browser_sync
  ' _ "$SPARK" 2>&1)
  state=$(cat "${tmp}/state")
  rm -rf "$tmp"
  [[ "$out" == *"Browser-to-Electron SuperSync verified"* ]]
  [[ "$out" == *"verified in both directions"* ]]
  [[ "$state" == *"SUPER_PRODUCTIVITY_BROWSER_SYNC_STATUS=verified"* ]]
  [[ "$state" == *"SUPER_PRODUCTIVITY_BROWSER_SYNC_URL=https://tasks.example.ts.net"* ]]
}

test_super_productivity_onboarding_retries_verification_in_place() {
  local tmp out state deletes delete_checks sync_triggers
  tmp=$(mktemp -d)
  out=$(printf '\nRETRY\n\nSYNCED\n' | HOME="${tmp}/home" STATE_FILE="${tmp}/state" DELETE_FILE="${tmp}/deletes" DELETE_CHECK_FILE="${tmp}/delete-checks" SYNC_TRIGGER_FILE="${tmp}/sync-triggers" bash -c '
    source "$1"
    SETUP_FAILED=()
    is_interactive() { return 0; }
    workspace_task_manager() { printf "%s\n" super-productivity; }
    workspace_supersync_passkey_ready() { return 0; }
    workspace_super_productivity_browser_sync_ready() { return 1; }
    workspace_show_super_productivity_sync_access() { return 0; }
    workspace_task_manager_url() { printf "%s\n" https://tasks.example.ts.net; }
    workspace_read_env() {
      [[ "$1" == SUPER_PRODUCTIVITY_USER_EMAIL ]] && printf "%s\n" m@example.com
    }
    workspace_random_hex_token() { printf "%s\n" 1234567890abcdef; }
    workspace_wait_for_super_productivity_sync_task() { printf "%s\n" task-1; }
    workspace_delete_super_productivity_sync_task() {
      local deletes=0 triggers=0
      [[ -f "$DELETE_FILE" ]] && deletes=$(wc -l < "$DELETE_FILE")
      [[ -f "$SYNC_TRIGGER_FILE" ]] && triggers=$(wc -l < "$SYNC_TRIGGER_FILE")
      [[ "$triggers" -eq $((deletes * 2 + 1)) ]] || return 1
      printf "delete\n" >> "$DELETE_FILE"
    }
    workspace_trigger_super_productivity_sync() {
      printf "triggered\n" >> "$SYNC_TRIGGER_FILE"
    }
    workspace_supersync_task_delete_recorded() {
      local deletes triggers
      printf "checked\n" >> "$DELETE_CHECK_FILE"
      [[ -f "$SYNC_TRIGGER_FILE" ]] || return 1
      deletes=$(wc -l < "$DELETE_FILE")
      triggers=$(wc -l < "$SYNC_TRIGGER_FILE")
      [[ "$triggers" -ge $((deletes * 2)) ]]
    }
    sleep() { :; }
    workspace_set_env_key() { printf "%s=%s\n" "$1" "$2" >> "$STATE_FILE"; }
    workspace_complete_super_productivity_browser_sync
  ' _ "$SPARK" 2>&1)
  state=$(cat "${tmp}/state" 2>/dev/null || true)
  deletes=$(wc -l < "${tmp}/deletes" 2>/dev/null || printf '0')
  delete_checks=$(wc -l < "${tmp}/delete-checks" 2>/dev/null || printf '0')
  if [[ -f "${tmp}/sync-triggers" ]]; then
    sync_triggers=$(wc -l < "${tmp}/sync-triggers")
  else
    sync_triggers=0
  fi
  rm -rf "$tmp"
  [[ "$out" == *"Retrying only the browser sync verification"* ]]
  [[ "$out" == *"Electron-to-SuperSync deletion verified"* ]]
  [[ "$out" == *"verified in both directions"* ]]
  [[ "$deletes" -eq 2 ]]
  [[ "$delete_checks" -eq 4 ]]
  [[ "$sync_triggers" -eq 4 ]]
  [[ "$state" == *"SUPER_PRODUCTIVITY_BROWSER_SYNC_STATUS=verified"* ]]
}

test_workspace_summary_uses_super_productivity_resume_hint() {
  local tmp out
  tmp=$(mktemp -d)
  out=$(HOME="$tmp/home" bash -c '
    source "$1"
    SETUP_FAILED=("Electron-to-browser SuperSync was not confirmed")
    SETUP_SKIPPED=()
    WORKSPACE_SETUP_RESUME_HINT="Resume only the Super Productivity browser sync verification."
    workspace_summary
  ' _ "$SPARK" 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"Resume only the Super Productivity browser sync verification."* ]]
  [[ "$out" != *"Fix them and re-run"* ]]
}

test_super_productivity_onboarding_requires_interactive_terminal() {
  local out status
  set +e
  out=$(bash -c '
    source "$1"
    SETUP_FAILED=()
    is_interactive() { return 1; }
    workspace_task_manager() { printf "%s\n" super-productivity; }
    workspace_supersync_passkey_ready() { return 0; }
    workspace_super_productivity_browser_sync_ready() { return 1; }
    workspace_complete_super_productivity_browser_sync
  ' _ "$SPARK" 2>&1)
  status=$?
  set -e
  [[ "$status" -ne 0 ]]
  [[ "$out" == *"requires an interactive terminal"* ]]
}

test_workspace_preserves_legacy_postgres_mount() {
  local tmp target
  tmp=$(mktemp -d)
  mkdir -p "${tmp}/home/.local/share/spark/workspace/postgres"
  printf '17\n' > "${tmp}/home/.local/share/spark/workspace/postgres/PG_VERSION"
  target=$(HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama bash -c '
      source "$1"
      workspace_postgres_volume_target
    ' _ "$SPARK")
  rm -rf "$tmp"
  [[ "$target" == "/var/lib/postgresql/data" ]]
}

test_super_productivity_rejects_http_ports_mode() {
  local tmp out status
  tmp=$(mktemp -d)
  set +e
  out=$(HOME="${tmp}/home" SPARK_WORKSPACE_TASK_MANAGER=vikunja "$SPARK" ws setup \
    --task-manager super-productivity --tailscale-mode ports --yes 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] && [[ "$out" == *"SuperSync requires HTTPS"* ]]
}

test_workspace_interactive_task_manager_selector() {
  local tmp super_productivity vikunja todoist kept migrated cancelled status
  tmp=$(mktemp -d)
  super_productivity=$(printf '\n1\n' | SPARK_WORKSPACE_TASK_MANAGER=vikunja HOME="${tmp}/home" bash -c '
    source "$1"
    is_interactive() { return 0; }
    workspace_select_task_manager "" "" 0
  ' _ "$SPARK" 2>"${tmp}/new.err")
  vikunja=$(printf '2\n' | HOME="${tmp}/home" bash -c '
    source "$1"
    is_interactive() { return 0; }
    workspace_select_task_manager "" "" 0
  ' _ "$SPARK" 2>/dev/null)
  todoist=$(printf '3\n' | HOME="${tmp}/home" bash -c '
    source "$1"
    is_interactive() { return 0; }
    workspace_select_task_manager "" "" 0
  ' _ "$SPARK" 2>/dev/null)
  kept=$(printf '\n1\n' | HOME="${tmp}/home" bash -c '
    source "$1"
    is_interactive() { return 0; }
    workspace_select_task_manager "" super-productivity 0
  ' _ "$SPARK" 2>/dev/null)
  migrated=$(printf '2\nMIGRATE\n' | HOME="${tmp}/home" bash -c '
    source "$1"
    is_interactive() { return 0; }
    workspace_select_task_manager "" super-productivity 0
  ' _ "$SPARK" 2>"${tmp}/migration.err")
  set +e
  cancelled=$(printf '2\nno\n' | HOME="${tmp}/home" bash -c '
    source "$1"
    is_interactive() { return 0; }
    workspace_select_task_manager "" super-productivity 0
  ' _ "$SPARK" 2>&1)
  status=$?
  set -e
  [[ "$super_productivity" == "super-productivity" ]]
  [[ "$vikunja" == "vikunja" ]]
  [[ "$todoist" == "todoist" ]]
  [[ "$kept" == "super-productivity" ]]
  [[ "$migrated" == "vikunja" ]]
  [[ "$status" -ne 0 && "$cancelled" == *"migration cancelled"* ]]
  grep -q "There is no default" "${tmp}/new.err"
  grep -q "complete teardown" "${tmp}/migration.err"
  grep -q "No backup will be created" "${tmp}/migration.err"
  rm -rf "$tmp"
}


test_workspace_requires_explicit_noninteractive_task_manager() {
  local tmp out status
  tmp=$(mktemp -d)
  set +e
  out=$(HOME="${tmp}/home" SPARK_WORKSPACE_TASK_MANAGER=super-productivity \
    "$SPARK" ws setup --yes --check --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]]
  [[ "$out" == *"Task manager selection is required"* ]]
  [[ "$out" == *"--task-manager vikunja"* ]]
}

test_workspace_remote_task_manager_detection() {
  local out
  out=$(bash -c '
    source "$1"
    open_remote() { return 0; }
    remote_in() {
      cat >/dev/null
      printf "%s\n" super-productivity
      return 1
    }
    close_remote() { return 0; }
    workspace_remote_persisted_task_manager user@example.test
  ' _ "$SPARK")
  [[ "$out" == "super-productivity" ]]
}

test_workspace_persisted_task_manager_ignores_runtime_override() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "${tmp}/home/.config/spark/workspace"
  printf '%s\n' 'WORKSPACE_TASK_MANAGER=super-productivity' \
    > "${tmp}/home/.config/spark/workspace/secrets.env"
  out=$(HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama bash -c '
      source "$1"
      printf "persisted=%s\n" "$(workspace_persisted_task_manager)"
      SPARK_WORKSPACE_TASK_MANAGER=vikunja
      printf "effective=%s\n" "$(workspace_task_manager)"
    ' _ "$SPARK")
  rm -rf "$tmp"
  [[ "$out" == $'persisted=super-productivity\neffective=vikunja' ]]
}

test_workspace_vikunja_secret_is_manager_scoped() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "${tmp}/home/.config/spark/workspace" "${tmp}/home/.local/share/spark/workspace/postgres"
  printf '%s\n' 'WORKSPACE_TASK_MANAGER=super-productivity' \
    > "${tmp}/home/.config/spark/workspace/secrets.env"
  printf '%s\n' '18' > "${tmp}/home/.local/share/spark/workspace/postgres/PG_VERSION"
  out=$(HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama bash -c '
      source "$1"
      workspace_random_secret() { printf "generated-secret\n"; }
      printf "generated=%s\n" "$(workspace_vikunja_service_secret)"
      printf "%s\n" "WORKSPACE_TASK_MANAGER=vikunja" > "$WORKSPACE_ENV_FILE"
      if workspace_vikunja_service_secret >/dev/null; then
        printf "unguarded\n"
      else
        printf "guarded\n"
      fi
      printf "%s\n" "VIKUNJA_SERVICE_SECRET=old-secret" > "$WORKSPACE_VIKUNJA_ENV_FILE"
      printf "restored=%s\n" "$(workspace_vikunja_service_secret)"
    ' _ "$SPARK")
  rm -rf "$tmp"
  [[ "$out" == $'generated=generated-secret\nguarded\nrestored=old-secret' ]]
}


test_workspace_selects_abandoned_task_manager_for_teardown() {
  local tmp out
  tmp=$(mktemp -d)
  out=$(HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama bash -c '
      source "$1"
      printf "switch=%s\n" "$(workspace_teardown_task_manager_candidate super-productivity "" vikunja)"
      printf "pending=%s\n" "$(workspace_teardown_task_manager_candidate vikunja super-productivity vikunja)"
      workspace_task_manager_artifacts_exist() { [[ "$1" == vikunja ]]; }
      printf "legacy=%s\n" "$(workspace_teardown_task_manager_candidate "" "" super-productivity)"
      workspace_task_manager_artifacts_exist() { [[ "$1" == todoist ]]; }
      printf "hosted=%s\n" "$(workspace_teardown_task_manager_candidate "" "" vikunja)"
    ' _ "$SPARK")
  rm -rf "$tmp"
  [[ "$out" == $'switch=super-productivity\npending=super-productivity\nlegacy=vikunja\nhosted=todoist' ]]
}

test_workspace_task_manager_teardown_removes_images() {
  local tmp log out calls
  tmp=$(mktemp -d)
  log="${tmp}/calls"
  out=$(HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama SPARK_TEST_LOG="$log" bash -c '
      source "$1"
      workspace_read_env() {
        case "$1" in
          WORKSPACE_VIKUNJA_IMAGE) printf "custom/vikunja:7\n" ;;
          WORKSPACE_SUPERSYNC_IMAGE) printf "custom/supersync:7\n" ;;
          WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_IMAGE) printf "custom/electron:7\n" ;;
          *) return 1 ;;
        esac
      }
      docker() {
        case "$*" in
          "image ls --format {{.Repository}}:{{.Tag}}")
            printf "vikunja/vikunja:0.24.6\nspark/supersync:18.7.0\nspark/super-productivity-electron:18.7.0\nunrelated/image:1\n"
            ;;
          "inspect --format {{.Config.Image}} workspace-vikunja") printf "container/vikunja:7\n" ;;
          "inspect --format {{.Image}} workspace-vikunja") printf "sha256:vikunja\n" ;;
          "inspect --format {{.Config.Image}} workspace-supersync") printf "container/supersync:7\n" ;;
          "inspect --format {{.Image}} workspace-supersync") printf "sha256:supersync\n" ;;
          "inspect --format {{.Config.Image}} workspace-super-productivity-electron") printf "container/electron:7\n" ;;
          "inspect --format {{.Image}} workspace-super-productivity-electron") printf "sha256:electron\n" ;;
          image\ inspect\ *) return 0 ;;
          image\ rm\ -f\ *) printf "%s\n" "$*" >> "$SPARK_TEST_LOG" ;;
          *) return 1 ;;
        esac
      }
      vikunja=$(workspace_task_manager_teardown_images vikunja)
      super_productivity=$(workspace_task_manager_teardown_images super-productivity)
      printf "vikunja=%s\n" "$vikunja"
      printf "super-productivity=%s\n" "$super_productivity"
      workspace_remove_task_manager_images "$vikunja"
      workspace_remove_task_manager_images "$super_productivity"
      workspace_read_env() {
        case "$1" in
          WORKSPACE_TASK_MANAGER_TEARDOWN_PENDING) printf "vikunja\n" ;;
          WORKSPACE_TASK_MANAGER_TEARDOWN_IMAGES) printf "stored:image\n" ;;
          *) return 1 ;;
        esac
      }
      printf "stored=%s\n" "$(workspace_task_manager_teardown_images vikunja)"
      printf "mismatch=%s\n" "$(workspace_task_manager_teardown_images super-productivity)"
    ' _ "$SPARK")
  calls=$(cat "$log")
  rm -rf "$tmp"
  [[ "$out" == *"vikunja=custom/vikunja:7,container/vikunja:7,sha256:vikunja,vikunja/vikunja:0.24.6,vikunja/vikunja:latest"* ]] &&
    [[ "$out" == *"super-productivity=custom/supersync:7,custom/electron:7,container/supersync:7,sha256:supersync,container/electron:7,sha256:electron,spark/supersync:18.7.0,spark/super-productivity-electron:18.7.0,spark/supersync:18.15.1,spark/super-productivity-electron:18.15.1"* ]] &&
    [[ "$out" == *"stored=stored:image"* ]] &&
    [[ "$out" == *"mismatch=container/supersync:7,sha256:supersync,container/electron:7,sha256:electron"* ]] &&
    [[ "$calls" == *"image rm -f sha256:vikunja"* ]] &&
    [[ "$calls" == *"image rm -f sha256:supersync"* ]] &&
    [[ "$calls" == *"image rm -f sha256:electron"* ]] &&
    [[ "$calls" == *"image rm -f spark/supersync:18.7.0"* ]] &&
    [[ "$calls" == *"image rm -f spark/super-productivity-electron:18.7.0"* ]]
}


test_workspace_task_manager_teardown_covers_services_and_data() {
  local tmp log calls
  tmp=$(mktemp -d)
  log="${tmp}/calls"
  HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama SPARK_TEST_LOG="$log" bash -c '
      source "$1"
      workspace_cleanup_abandoned_hermes_access() { printf "hermes:%s\n" "$1" >> "$SPARK_TEST_LOG"; }
      workspace_drop_task_manager_database() { printf "database:%s\n" "$1" >> "$SPARK_TEST_LOG"; }
      workspace_remove_managed_path() { printf "remove:%s\n" "$1" >> "$SPARK_TEST_LOG"; }
      docker() { printf "docker:%s\n" "$*" >> "$SPARK_TEST_LOG"; }
      workspace_cleanup_abandoned_task_manager super-productivity
      workspace_cleanup_abandoned_task_manager vikunja
    ' _ "$SPARK" >/dev/null 2>&1
  calls=$(cat "$log")
  rm -rf "$tmp"
  [[ "$calls" == *"hermes:super-productivity"* ]] &&
    [[ "$calls" == *"database:super-productivity"* ]] &&
    [[ "$calls" == *"docker:rm -f workspace-supersync workspace-super-productivity-electron"* ]] &&
    [[ "$calls" == *"remove:${tmp}/home/.local/share/spark/workspace/super-productivity-electron"* ]] &&
    [[ "$calls" == *"remove:${tmp}/home/.config/spark/workspace/super-productivity.env"* ]] &&
    [[ "$calls" == *"remove:${tmp}/home/.config/spark/workspace/supersync"* ]] &&
    [[ "$calls" == *"remove:${tmp}/home/.config/spark/workspace/super-productivity-electron"* ]] &&
    [[ "$calls" == *"hermes:vikunja"* ]] &&
    [[ "$calls" == *"database:vikunja"* ]] &&
    [[ "$calls" == *"docker:rm -f workspace-vikunja"* ]] &&
    [[ "$calls" == *"remove:${tmp}/home/.local/share/spark/workspace/vikunja-files"* ]] &&
    [[ "$calls" == *"remove:${tmp}/home/.config/spark/workspace/vikunja.env"* ]]
}


test_workspace_task_manager_teardown_removes_hermes_access() {
  local tmp log calls
  tmp=$(mktemp -d)
  log="${tmp}/calls"
  HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama SPARK_TEST_LOG="$log" bash -c '
      source "$1"
      openshell() { printf "openshell:%s\n" "$*" >> "$SPARK_TEST_LOG"; }
      nemohermes() { printf "nemohermes:%s\n" "$*" >> "$SPARK_TEST_LOG"; }
      workspace_stop_hermes_vikunja_proxy() { printf "%s\n" stop-vikunja-proxy >> "$SPARK_TEST_LOG"; }
      workspace_stop_hermes_super_productivity_proxy() { printf "%s\n" stop-super-productivity-proxy >> "$SPARK_TEST_LOG"; }
      workspace_hermes_vikunja_provider_attached() { return 0; }
      workspace_hermes_vikunja_provider_exists() { return 0; }
      workspace_hermes_todoist_provider_attached() { return 0; }
      workspace_hermes_todoist_provider_exists() { return 0; }
      workspace_remove_managed_path() { printf "remove:%s\n" "$1" >> "$SPARK_TEST_LOG"; }
      workspace_cleanup_abandoned_hermes_access vikunja
      workspace_cleanup_abandoned_hermes_access super-productivity
      workspace_cleanup_abandoned_hermes_access todoist
    ' _ "$SPARK" >/dev/null 2>&1
  calls=$(cat "$log")
  rm -rf "$tmp"
  [[ "$calls" == *"stop-vikunja-proxy"* ]] &&
    [[ "$calls" == *"openshell:policy update hermes --remove-rule spark-vikunja-api --wait"* ]] &&
    [[ "$calls" == *"openshell:sandbox provider detach hermes spark-vikunja"* ]] &&
    [[ "$calls" == *"openshell:provider delete spark-vikunja"* ]] &&
    [[ "$calls" == *"nemohermes:hermes skill remove vikunja"* ]] &&
    [[ "$calls" == *"remove:${tmp}/home/.config/spark/workspace/hermes-skills/vikunja"* ]] &&
    [[ "$calls" == *"stop-super-productivity-proxy"* ]] &&
    [[ "$calls" == *"openshell:policy update hermes --remove-rule spark-super-productivity-api --wait"* ]] &&
    [[ "$calls" == *"nemohermes:hermes skill remove super-productivity"* ]] &&
    [[ "$calls" == *"remove:${tmp}/home/.config/spark/workspace/hermes-skills/super-productivity"* ]] &&
    [[ "$calls" == *"openshell:policy update hermes --remove-rule spark-todoist-api --wait"* ]] &&
    [[ "$calls" == *"openshell:sandbox provider detach hermes spark-todoist"* ]] &&
    [[ "$calls" == *"openshell:provider delete spark-todoist"* ]] &&
    [[ "$calls" == *"nemohermes:hermes skill remove todoist"* ]] &&
    [[ "$calls" == *"remove:${tmp}/home/.config/spark/workspace/hermes-skills/todoist"* ]] &&
    [[ "$(grep -c '^nemohermes:hermes gateway restart --quiet$' <<<"$calls")" == 3 ]]
}


test_workspace_task_manager_teardown_drops_database_and_role() {
  local tmp vikunja_sql supersync_sql
  tmp=$(mktemp -d)
  vikunja_sql=$(HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama bash -c '
      source "$1"
      workspace_postgres_psql() { cat; }
      workspace_drop_task_manager_database vikunja
    ' _ "$SPARK")
  supersync_sql=$(HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama bash -c '
      source "$1"
      workspace_postgres_psql() { cat; }
      workspace_drop_task_manager_database super-productivity
    ' _ "$SPARK")
  rm -rf "$tmp"
  [[ "$vikunja_sql" == *"datname = 'vikunja'"* ]] &&
    [[ "$vikunja_sql" == *'DROP DATABASE IF EXISTS "vikunja";'* ]] &&
    [[ "$vikunja_sql" == *'DROP ROLE IF EXISTS "vikunja";'* ]] &&
    [[ "$supersync_sql" == *"datname = 'supersync'"* ]] &&
    [[ "$supersync_sql" == *'DROP DATABASE IF EXISTS "supersync";'* ]] &&
    [[ "$supersync_sql" == *'DROP ROLE IF EXISTS "supersync";'* ]]
}


test_workspace_task_manager_teardown_waits_and_retries() {
  local tmp log status calls env
  tmp=$(mktemp -d)
  mkdir -p "${tmp}/home/.config/spark/workspace"
  printf '%s\n' 'WORKSPACE_TASK_MANAGER=super-productivity' \
    'WORKSPACE_TASK_MANAGER_TEARDOWN_PENDING=vikunja' \
    'WORKSPACE_TASK_MANAGER_TEARDOWN_IMAGES=vikunja/vikunja:1,sha256:old' \
    > "${tmp}/home/.config/spark/workspace/secrets.env"
  log="${tmp}/calls"
  HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama SPARK_TEST_LOG="$log" bash -c '
      source "$1"
      workspace_cleanup_abandoned_task_manager() {
        printf "cleanup:%s:%s\n" "$1" "$2" >> "$SPARK_TEST_LOG"
        [[ "${SPARK_TEST_CLEANUP_FAIL:-0}" != 1 ]]
      }
      workspace_hermes_super_productivity_api_ready() { return 0; }
      SETUP_FAILED=(new-manager-failed)
      workspace_finalize_task_manager_teardown vikunja super-productivity
      [[ ! -e "$SPARK_TEST_LOG" ]]
      [[ "$(workspace_read_env WORKSPACE_TASK_MANAGER_TEARDOWN_PENDING)" == vikunja ]]
      [[ "$(workspace_read_env WORKSPACE_TASK_MANAGER_TEARDOWN_IMAGES)" == "vikunja/vikunja:1,sha256:old" ]]
      SETUP_FAILED=()
      SPARK_TEST_CLEANUP_FAIL=1
      ! workspace_finalize_task_manager_teardown vikunja super-productivity
      [[ "$(workspace_read_env WORKSPACE_TASK_MANAGER_TEARDOWN_PENDING)" == vikunja ]]
      [[ "$(workspace_read_env WORKSPACE_TASK_MANAGER_TEARDOWN_IMAGES)" == "vikunja/vikunja:1,sha256:old" ]]
      SPARK_TEST_CLEANUP_FAIL=0
      workspace_finalize_task_manager_teardown vikunja super-productivity
      [[ -z "$(workspace_read_env WORKSPACE_TASK_MANAGER_TEARDOWN_PENDING)" ]]
      [[ -z "$(workspace_read_env WORKSPACE_TASK_MANAGER_TEARDOWN_IMAGES)" ]]
    ' _ "$SPARK" >/dev/null 2>&1
  status=$?
  calls=$(cat "$log" 2>/dev/null || true)
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env")
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] &&
    [[ "$calls" == $'cleanup:vikunja:vikunja/vikunja:1,sha256:old\ncleanup:vikunja:vikunja/vikunja:1,sha256:old' ]] &&
    [[ "$env" != *"WORKSPACE_TASK_MANAGER_TEARDOWN_PENDING="* ]] &&
    [[ "$env" != *"WORKSPACE_TASK_MANAGER_TEARDOWN_IMAGES="* ]]
}

test_workspace_task_manager_teardown_covers_all_transitions() {
  local tmp log status calls
  tmp=$(mktemp -d)
  mkdir -p "${tmp}/home/.config/spark/workspace"
  log="${tmp}/calls"
  HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama SPARK_TEST_LOG="$log" bash -c '
      source "$1"
      workspace_cleanup_abandoned_task_manager() {
        printf "%s->%s\n" "$1" "$SPARK_TEST_CURRENT" >> "$SPARK_TEST_LOG"
      }
      workspace_hermes_vikunja_api_ready() { [[ "$SPARK_TEST_CURRENT" == vikunja ]]; }
      workspace_hermes_super_productivity_api_ready() { [[ "$SPARK_TEST_CURRENT" == super-productivity ]]; }
      workspace_hermes_todoist_api_ready() { [[ "$SPARK_TEST_CURRENT" == todoist ]]; }
      sleep() { :; }
      SETUP_FAILED=()
      for transition in \
        vikunja:super-productivity vikunja:todoist \
        super-productivity:vikunja super-productivity:todoist \
        todoist:vikunja todoist:super-productivity; do
        abandoned=${transition%%:*}
        SPARK_TEST_CURRENT=${transition#*:}
        workspace_set_env_key WORKSPACE_TASK_MANAGER_TEARDOWN_PENDING "$abandoned"
        workspace_finalize_task_manager_teardown "$abandoned" "$SPARK_TEST_CURRENT"
        [[ -z "$(workspace_read_env WORKSPACE_TASK_MANAGER_TEARDOWN_PENDING)" ]]
      done
    ' _ "$SPARK" >/dev/null 2>&1
  status=$?
  calls=$(cat "$log" 2>/dev/null || true)
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] &&
    [[ "$calls" == $'vikunja->super-productivity\nvikunja->todoist\nsuper-productivity->vikunja\nsuper-productivity->todoist\ntodoist->vikunja\ntodoist->super-productivity' ]]
}


test_workspace_remove_managed_path_rejects_broad_targets() {
  local tmp status
  tmp=$(mktemp -d)
  mkdir -p "${tmp}/home/.config/spark/workspace/allowed" "${tmp}/outside"
  HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama bash -c '
      source "$1"
      workspace_remove_managed_path "$WORKSPACE_CONFIG_DIR/allowed"
      [[ ! -e "$WORKSPACE_CONFIG_DIR/allowed" ]]
      ! workspace_remove_managed_path "$WORKSPACE_CONFIG_DIR"
      ! workspace_remove_managed_path "$2/outside"
      [[ -d "$2/outside" ]]
    ' _ "$SPARK" "$tmp"
  status=$?
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]]
}

test_doctor_reports_no_ngc_image() {
  local tmp fake_bin output
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" doctor 2>&1)
  rm -rf "$tmp"

  [[ "$output" == *"NGC container"* ]] &&
    [[ "$output" == *"vLLM image not pulled"* ]] &&
    [[ "$output" == *"checks passed"* ]]
}

test_doctor_skips_blocked_ngc_vllm_image() {
  local tmp fake_bin output
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_DOCKER_IMAGE=$'nvcr.io/nvidia/vllm:26.06-py3\nnvcr.io/nvidia/vllm:26.05-py3' \
    "$SPARK" doctor --verbose 2>&1)
  rm -rf "$tmp"

  [[ "$output" == *"NGC container"* ]] &&
    [[ "$output" == *"nvcr.io/nvidia/vllm:26.05-py3"* ]] &&
    [[ "$output" != *"NGC container: nvcr.io/nvidia/vllm:26.06-py3"* ]]
}

test_vllm_image_override_wins() {
  local tmp fake_bin output
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_VLLM_IMAGE="eugr/spark-vllm:latest" \
    "$SPARK" doctor --verbose 2>&1)
  rm -rf "$tmp"

  [[ "$output" == *"NGC container"* ]] && [[ "$output" == *"eugr/spark-vllm:latest"* ]]
}

test_doctor_reports_bad_hf_cache_permissions() {
  local tmp fake_bin output bad
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  bad="${tmp}/home/.cache/huggingface/hub/models--Org--Bad/.no_exist/x"
  mkdir -p "$(dirname "$bad")"
  : > "$bad"
  chmod a-w "$bad"
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" doctor 2>&1)
  chmod u+w "$bad"
  rm -rf "$tmp"

  [[ "$output" == *"HF cache permissions"* ]] &&
    [[ "$output" == *"not writable"* ]] &&
    [[ "$output" == *"sudo chown"* ]]
}

test_setup_check_reports_incomplete() {
  local tmp fake_bin output status
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home"

  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" setup --check </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -ne 0 ]] &&
    [[ "$output" == *"Setup incomplete"* ]] &&
    [[ "$output" != *"Setup complete"* ]]
}

test_setup_check_reports_tailscale_funnel() {
  local tmp fake_bin output status tailscale_calls
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home"

  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_TAILSCALE_FUNNEL_EXIT=0 \
    FAKE_TAILSCALE_FUNNEL_STATUS='https://public.example.com\n' \
    FAKE_TAILSCALE_FILE="${tmp}/tailscale.log" \
    "$SPARK" setup --check </dev/null 2>&1)
  status=$?
  set -e
  tailscale_calls=$(cat "${tmp}/tailscale.log" 2>/dev/null || echo "")
  rm -rf "$tmp"

  [[ "$status" -ne 0 ]] &&
    [[ "$output" == *"Tailscale Funnel is active; public internet exposure must be removed"* ]] &&
    [[ "$tailscale_calls" != *"funnel reset"* ]]
}

test_doctor_reports_tailscale_funnel() {
  local tmp fake_bin output
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_TAILSCALE_FUNNEL_EXIT=0 \
    FAKE_TAILSCALE_FUNNEL_STATUS='https://public.example.com\n' \
    "$SPARK" doctor 2>&1)
  rm -rf "$tmp"

  [[ "$output" == *"Tailscale Funnel"* ]] && [[ "$output" == *"active public exposure"* ]]
}

test_doctor_json_quiet_and_exit_codes() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin json quiet_out json_status quiet_status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  set +e
  json=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" doctor --json 2>/dev/null)
  json_status=$?
  quiet_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" doctor --quiet 2>&1)
  quiet_status=$?
  set -e
  rm -rf "$tmp"
  [[ "$json_status" -ne 0 && "$quiet_status" -ne 0 && -z "$quiet_out" ]] &&
    printf '%s' "$json" | jq -e '
      .ok == false and .failed > 0 and .total == (.passed + .failed) and
      ([.areas[] | select(.name == "Runtime" and .failed > 0)] | length == 1) and
      ([.checks[] | select(.label == "Docker" and .state == "fail" and (.action | length > 0))] | length == 1)
    ' >/dev/null
}

test_invalid_port_fails_before_side_effects() {
  local output status
  set +e
  output=$("$SPARK" run Org/Model --port abc --dry-run 2>&1)
  status=$?
  set -e

  [[ "$status" -ne 0 ]] &&
    [[ "$output" == *"Invalid --port value"* ]]
}

test_dry_run_uses_json_profile_safely() {
  if ! command -v jq >/dev/null 2>&1; then
    printf "skip - jq not installed\n"
    return 0
  fi

  local tmp fake_bin model_dir marker output
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  marker="${tmp}/profile-executed"
  model_dir="${tmp}/home/.cache/huggingface/hub/models--Org--Model/snapshots/1"
  make_fake_bin "$fake_bin"
  mkdir -p "$model_dir"

  cat > "${model_dir}/config.json" <<EOF
{
  "model_type": "qwen3",
  "architectures": ["Qwen3ForCausalLM"],
  "max_position_embeddings": "1; touch ${marker}"
}
EOF

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Model --dry-run 2>&1)
  local status=$?
  local marker_missing=0
  [[ ! -e "$marker" ]] && marker_missing=1
  rm -rf "$tmp"

  [[ "$status" -eq 0 ]] &&
    [[ "$output" == *"docker run"* ]] &&
    [[ "$output" == *"--max-model-len 32768"* ]] &&
    [[ "$marker_missing" -eq 1 ]]
}

test_docker_run_failure_shows_error() {
  if ! command -v jq >/dev/null 2>&1; then
    printf "skip - jq not installed\n"
    return 0
  fi

  local tmp fake_bin model_dir output status
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  model_dir="${tmp}/home/.cache/huggingface/hub/models--Org--Model/snapshots/1"
  make_fake_bin "$fake_bin"
  mkdir -p "$model_dir"

  cat > "${model_dir}/config.json" <<'EOF'
{"model_type": "qwen3", "architectures": ["Qwen3ForCausalLM"], "max_position_embeddings": 4096}
EOF

  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_RUN_EXIT=1 \
    "$SPARK" run Org/Model 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -ne 0 ]] &&
    [[ "$output" == *"docker run failed"* ]]
}

test_corrupt_profile_reports_error() {
  if ! command -v jq >/dev/null 2>&1; then
    printf "skip - jq not installed\n"
    return 0
  fi

  local tmp fake_bin output status
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark/profiles"
  mkdir -p "${tmp}/home/.cache/huggingface/hub/models--Org--Model/snapshots/1"

  printf "not valid json{{{" > "${tmp}/home/.config/spark/profiles/Org--Model.json"

  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Model --dry-run 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -ne 0 ]] &&
    [[ "$output" == *"Invalid profile JSON"* ]]
}

# Write a model snapshot with the given config.json contents; echoes HOME dir.
make_model() {
  local home="$1" ref="$2" config="$3"
  local dir="${home}/.cache/huggingface/hub/models--${ref//\//--}/snapshots/1"
  mkdir -p "$dir"
  printf '%s\n' "$config" > "${dir}/config.json"
}

# Shared config with known KV dims: KV at 128K = 2*48*4*128*2*131072/1024^3 = 12.0 GB,
# weights (nvfp4, 30B params) = 30e9*0.5/1024^3 = 14.0 GB.
KV_CONFIG='{ "model_type":"qwen3", "architectures":["Qwen3ForCausalLM"],
  "num_hidden_layers":48, "num_key_value_heads":4, "num_attention_heads":32,
  "head_dim":128, "hidden_size":2048, "max_position_embeddings":262144,
  "quantization_config":{"quant_method":"nvfp4"}, "num_parameters":30000000000 }'

hf_inspect_json() {
  local mtp="${1:-false}" kv_fp8="${2:-false}" ctx="${3:-null}" tools="${4:-false}" arch="${5:-dense}" quant="${6:-nvfp4}"
  local cmd="${7:-vllm serve Org/Test --load-format fastsafetensors}" image="${8:-}"
  jq -nc --argjson mtp "$mtp" --argjson kv "$kv_fp8" --argjson ctx "$ctx" --argjson tools "$tools" \
    --arg arch "$arch" --arg quant "$quant" --arg cmd "$cmd" --arg image "$image" '{
      model_id:"Org/Test", revision:"rev-test", tags:["vllm","blackwell"],
      card:{license:"test", recommended_runtime:"vllm", recommended_image:$image, recommended_command:$cmd, long_context:($ctx != null), recommended_context:$ctx, config_context:262144, kv_cache_fp8_recommended:$kv},
      features:{family:"qwen", architecture:$arch, quantization:$quant, has_mtp:$mtp, has_reasoning:true, supports_tools:$tools, is_multimodal:false, is_moe:($arch == "moe"), is_nvfp4:($quant == "nvfp4"), is_fp8:($quant == "fp8"), is_gguf:false},
      raw:{model_type:"qwen3", architectures:["Qwen3ForCausalLM"], quantization_config:{quant_method:$quant}}
    }'
}


test_alias_create_preserves_dash_prefixed_args() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(printf 'Org/Model\n0.65\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_ASSUME_INTERACTIVE=1 "$SPARK" alias create demo 2>&1)
  jq -e '.demo.kind == "guided" and .demo.run_args == ["--mem", "0.65"]' \
    "${tmp}/home/.config/spark/aliases.json" >/dev/null
  local ok=$?
  rm -rf "$tmp"
  [[ "$ok" == "0" && "$out" == *"Saved alias 'demo'"* ]]
}

test_alias_capture_replays_image_env_and_operational_overrides() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin inspect managed out stop_file run_file
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Captured" "$KV_CONFIG"
  managed=$'spark-vllm-captured\tOrg/Captured\t8000\t78\t14\t24\n'
  inspect=$(jq -nc '[{
    State:{Running:true}, Path:"vllm",
    Args:["serve","Org/Captured","--gpu-memory-utilization","0.65","--max-model-len","4096","--max-num-seqs","2","--port","8000","--port=9000"],
    Config:{
      Entrypoint:["vllm","serve"],
      Cmd:["Org/Captured","--gpu-memory-utilization","0.65","--max-model-len","4096","--max-num-seqs","2","--port","8000","--port=9000"],
      Image:"eugr/spark-vllm:latest",
      Env:["VLLM_MARLIN_USE_ATOMIC_ADD=1","HF_TOKEN=must-not-be-captured","AWS_SECRET_ACCESS_KEY=must-not-be-captured"]
    },
    Image:("sha256:" + ("a" * 64))
  }]')

  printf '1\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ASSUME_INTERACTIVE=1 \
    FAKE_MANAGED="$managed" FAKE_CONTAINER_INSPECT_JSON="$inspect" \
    "$SPARK" alias capture replay >/dev/null 2>&1
  jq -e '
    .replay.image == "eugr/spark-vllm:latest"
    and .replay.image_id == ("sha256:" + ("a" * 64))
    and .replay.vllm_entrypoint == true
    and .replay.vllm_args[0:3] == ["vllm","serve","Org/Captured"]
    and .replay.env == {VLLM_MARLIN_USE_ATOMIC_ADD:"1"}
  ' "${tmp}/home/.config/spark/aliases.json" >/dev/null

  stop_file="${tmp}/docker-stop"; run_file="${tmp}/docker-run"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_VLLM_IMAGE="other/should-not-win:latest" FAKE_MANAGED="$managed" \
    FAKE_DOCKER_STOP_FILE="$stop_file" FAKE_DOCKER_ARGS_FILE="$run_file" \
    "$SPARK" run replay --force --port 8001 --explain </dev/null 2>&1)
  local ok=0
  [[ "$out" == *"image=eugr/spark-vllm:latest"* ]] || ok=1
  [[ "$out" == *"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa Org/Captured"* ]] || ok=1
  [[ "$out" != *"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa vllm serve"* ]] || ok=1
  [[ "$out" == *"VLLM_MARLIN_USE_ATOMIC_ADD=1"* ]] || ok=1
  [[ "$out" == *"--port 8001"* && "$out" != *"--port 8000"* && "$out" != *"--port=9000"* ]] || ok=1
  [[ ! -s "$stop_file" && ! -s "$run_file" ]] || ok=1
  rm -rf "$tmp"
  [[ "$ok" == "0" ]]
}

test_alias_capture_rejects_secret_flags() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin inspect managed out status=0 aliases
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  managed=$'spark-vllm-secret\tOrg/Secret\t8000\t10\t5\t5\n'
  inspect=$(jq -nc '[{
    State:{Running:true}, Path:"vllm", Args:["serve","Org/Secret","--api-key","topsecret"],
    Config:{Entrypoint:["vllm","serve"], Cmd:["Org/Secret","--api-key","topsecret"], Image:"eugr/spark-vllm:latest", Env:[]},
    Image:("sha256:" + ("b" * 64))
  }]')
  out=$(printf '1\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ASSUME_INTERACTIVE=1 \
    FAKE_MANAGED="$managed" FAKE_CONTAINER_INSPECT_JSON="$inspect" \
    "$SPARK" alias capture unsafe 2>&1) || status=$?
  aliases="${tmp}/home/.config/spark/aliases.json"
  local ok=0
  [[ "$status" -ne 0 && "$out" != *"topsecret"* ]] || ok=1
  [[ ! -f "$aliases" ]] || ! grep -Eq 'topsecret|api-key' "$aliases" || ok=1
  rm -rf "$tmp"
  [[ "$ok" == "0" ]]
}

test_alias_backend_mismatch_fails_closed() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status=0
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark"
  printf '%s\n' '{"cross":{"kind":"guided","backend":"vllm","model":"Org/Model","run_args":[]}}' \
    > "${tmp}/home/.config/spark/aliases.json"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    "$SPARK" run cross --dry-run </dev/null 2>&1) || status=$?
  rm -rf "$tmp"
  [[ "$status" -ne 0 && "$out" == *"targets vllm; this machine uses ollama"* ]]
}

test_bundle_catalog_embeds_and_validates_builtin() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin list show
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  list=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" bundle list --json 2>&1)
  show=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" bundle show qwen38-dflash2-lookup 2>&1)
  local ok=0
  jq -e '.[] | select(.name == "qwen38-dflash2-lookup" and .source == "built-in")' <<<"$list" >/dev/null || ok=1
  [[ "$show" == *"DFlash2 W4A16"* && "$show" == *"--lookup"* ]] || ok=1
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" bundle validate \
    "${ROOT_DIR}/bundles/vllm/qwen38-dflash2-lookup" >/dev/null 2>&1 || ok=1
  rm -rf "$tmp"
  [[ "$ok" == "0" ]]
}

test_bundle_validation_requires_declared_applied_patches() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin undeclared unapplied docker_tmp out status=0
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  undeclared="${tmp}/undeclared"
  unapplied="${tmp}/unapplied"
  cp -R "${ROOT_DIR}/bundles/vllm/qwen38-dflash2-lookup" "$undeclared"
  cp -R "${ROOT_DIR}/bundles/vllm/qwen38-dflash2-lookup" "$unapplied"

  printf '%s\n' 'unused' > "${undeclared}/patches/unused.patch"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" bundle validate "$undeclared" 2>&1) \
    && status=0 || status=$?
  local ok=0
  [[ "$status" -ne 0 && "$out" == *"Patch file is not declared in bundle.json: patches/unused.patch"* ]] || ok=1

  docker_tmp="${tmp}/Dockerfile"
  sed '/^[[:space:]]*< \/tmp\/qwen38-patches\/qwen3-dflash-w4a16.patch;/d' \
    "${unapplied}/Dockerfile" > "$docker_tmp"
  mv "$docker_tmp" "${unapplied}/Dockerfile"
  status=0
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" bundle validate "$unapplied" 2>&1) \
    && status=0 || status=$?
  [[ "$status" -ne 0 && "$out" == *"Declared patch is not applied by Dockerfile: patches/qwen3-dflash-w4a16.patch"* ]] || ok=1

  rm -rf "$tmp"
  [[ "$ok" == "0" ]]
}

test_bundle_sync_checks_git_catalog() {
  local tmp fake_bin output check_output standalone outside status=0
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  output=$(cd "$ROOT_DIR" && HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    "$SPARK" bundle sync 2>&1)
  check_output=$(cd "$ROOT_DIR" && HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    "$SPARK" bundle sync --check 2>&1)
  local ok=0
  [[ "$output" == *"Synchronized 1 built-in bundle(s) into spark"* ]] || ok=1
  [[ "$check_output" == *"Built-in bundles are synchronized (1)"* ]] || ok=1

  standalone="${tmp}/standalone-spark"
  outside="${tmp}/outside"
  cp "$SPARK" "$standalone"
  chmod +x "$standalone"
  mkdir -p "$outside"
  output=$(cd "$outside" && HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    "$standalone" bundle sync --check 2>&1) && status=0 || status=$?
  [[ "$status" -ne 0 && "$output" == *"Cannot find the Spark source repository"* ]] || ok=1

  rm -rf "$tmp"
  [[ "$ok" == "0" ]]
}

make_bundle_submit_origin() {
  local origin="$1" head
  head=$(git -C "$ROOT_DIR" rev-parse HEAD)
  git clone --quiet --bare "$ROOT_DIR" "$origin"
  git --git-dir="$origin" branch -f main "$head"
  git --git-dir="$origin" symbolic-ref HEAD refs/heads/main
}

test_bundle_submit_dry_run_prepares_new_and_updated_changes() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin origin new_source update_source manifest_tmp new_out update_out status=0 no_change_out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  origin="${tmp}/origin.git"
  make_bundle_submit_origin "$origin"

  new_source="${tmp}/new-bundle"
  cp -R "${ROOT_DIR}/bundles/vllm/qwen38-dflash2-lookup" "$new_source"
  manifest_tmp="${tmp}/bundle.json"
  jq '.name="submit-new-bundle"' "${new_source}/bundle.json" > "$manifest_tmp"
  mv "$manifest_tmp" "${new_source}/bundle.json"
  new_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_BUNDLE_SUBMIT_REPO_URL="$origin" SPARK_BUNDLE_SUBMIT_TMP_ROOT="$tmp" \
    "$SPARK" bundle submit "$new_source" --dry-run 2>&1)

  update_source="${tmp}/update-bundle"
  cp -R "${ROOT_DIR}/bundles/vllm/qwen38-dflash2-lookup" "$update_source"
  printf '\nSubmission update test.\n' >> "${update_source}/README.md"
  update_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_BUNDLE_SUBMIT_REPO_URL="$origin" SPARK_BUNDLE_SUBMIT_TMP_ROOT="$tmp" \
    "$SPARK" bundle submit "$update_source" --draft --dry-run 2>&1)

  no_change_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_BUNDLE_SUBMIT_REPO_URL="$origin" SPARK_BUNDLE_SUBMIT_TMP_ROOT="$tmp" \
    "$SPARK" bundle submit qwen38-dflash2-lookup --dry-run 2>&1) && status=0 || status=$?
  local ok=0
  [[ "$new_out" == *"Change:   new"* && "$new_out" == *"Dry run complete"* ]] || ok=1
  [[ "$update_out" == *"Change:   update"* && "$update_out" == *"Dry run complete"* ]] || ok=1
  [[ "$status" -ne 0 && "$no_change_out" == *"There is nothing to submit"* ]] || ok=1
  git --git-dir="$origin" for-each-ref --format='%(refname)' refs/heads/spark-bundle/ | grep -q . && ok=1
  find "$tmp" -maxdepth 1 -type d -name 'spark-bundle-submit.*' | grep -q . && ok=1
  rm -rf "$tmp"
  [[ "$ok" == "0" ]]
}

test_bundle_submit_opens_confirmed_draft_pr() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin origin source manifest_tmp gh_log out refs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  origin="${tmp}/origin.git"
  make_bundle_submit_origin "$origin"
  source="${tmp}/published-bundle"
  cp -R "${ROOT_DIR}/bundles/vllm/qwen38-dflash2-lookup" "$source"
  manifest_tmp="${tmp}/bundle.json"
  jq '.name="submit-published-bundle"' "${source}/bundle.json" > "$manifest_tmp"
  mv "$manifest_tmp" "${source}/bundle.json"
  gh_log="${tmp}/gh.log"
  cat > "${fake_bin}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_GH_LOG}"
case "$*" in
  "auth status --hostname github.com") exit 0 ;;
  "api user --jq .login") printf 'spark-tester\n' ;;
  *"--json viewerPermission --jq .viewerPermission") printf 'WRITE\n' ;;
  pr\ create\ *) printf 'https://github.com/massimo92/spark/pull/123\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${fake_bin}/gh"
  out=$(printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ASSUME_INTERACTIVE=1 \
    FAKE_GH_LOG="$gh_log" SPARK_BUNDLE_SUBMIT_REPO_URL="$origin" \
    SPARK_BUNDLE_SUBMIT_TMP_ROOT="$tmp" \
    "$SPARK" bundle submit "$source" --draft 2>&1)
  refs=$(git --git-dir="$origin" for-each-ref --format='%(refname)' \
    'refs/heads/spark-bundle/submit-published-bundle-*')
  local ok=0
  [[ "$out" == *"Pull request opened: https://github.com/massimo92/spark/pull/123"* ]] || ok=1
  [[ -n "$refs" ]] || ok=1
  grep -q -- '--draft' "$gh_log" || ok=1
  find "$tmp" -maxdepth 1 -type d -name 'spark-bundle-submit.*' | grep -q . && ok=1
  rm -rf "$tmp"
  [[ "$ok" == "0" ]]
}

test_bundle_submit_uses_fork_without_write_permission() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin origin fork source manifest_tmp gh_log out fork_refs origin_refs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  origin="${tmp}/origin.git"; fork="${tmp}/fork.git"
  make_bundle_submit_origin "$origin"
  git clone --quiet --bare "$origin" "$fork"
  source="${tmp}/fork-bundle"
  cp -R "${ROOT_DIR}/bundles/vllm/qwen38-dflash2-lookup" "$source"
  manifest_tmp="${tmp}/bundle.json"
  jq '.name="submit-fork-bundle"' "${source}/bundle.json" > "$manifest_tmp"
  mv "$manifest_tmp" "${source}/bundle.json"
  gh_log="${tmp}/gh.log"
  cat > "${fake_bin}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_GH_LOG}"
case "$*" in
  "auth status --hostname github.com") exit 0 ;;
  "api user --jq .login") printf 'spark-tester\n' ;;
  *"--json viewerPermission --jq .viewerPermission") printf 'READ\n' ;;
  "repo view spark-tester/spark --json parent --jq "*) printf 'massimo92/spark\n' ;;
  pr\ create\ *) printf 'https://github.com/massimo92/spark/pull/124\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${fake_bin}/gh"
  out=$(printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ASSUME_INTERACTIVE=1 \
    FAKE_GH_LOG="$gh_log" SPARK_BUNDLE_SUBMIT_REPO_URL="$origin" \
    SPARK_BUNDLE_SUBMIT_FORK_URL="$fork" SPARK_BUNDLE_SUBMIT_TMP_ROOT="$tmp" \
    "$SPARK" bundle submit "$source" 2>&1)
  fork_refs=$(git --git-dir="$fork" for-each-ref --format='%(refname)' \
    'refs/heads/spark-bundle/submit-fork-bundle-*')
  origin_refs=$(git --git-dir="$origin" for-each-ref --format='%(refname)' \
    'refs/heads/spark-bundle/submit-fork-bundle-*')
  local ok=0
  [[ "$out" == *"Pull request opened: https://github.com/massimo92/spark/pull/124"* ]] || ok=1
  [[ -n "$fork_refs" && -z "$origin_refs" ]] || ok=1
  grep -q -- '--head spark-tester:spark-bundle/submit-fork-bundle-' "$gh_log" || ok=1
  rm -rf "$tmp"
  [[ "$ok" == "0" ]]
}

test_bundle_imports_external_folder_and_run_builds_with_docker_cache() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin source manifest_tmp build_file list
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  source="${tmp}/external-bundle"
  cp -R "${ROOT_DIR}/bundles/vllm/qwen38-dflash2-lookup" "$source"
  manifest_tmp="${tmp}/bundle.json"
  jq '.name="external-bundle"' "${source}/bundle.json" > "$manifest_tmp"
  mv "$manifest_tmp" "${source}/bundle.json"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" bundle import "$source" >/dev/null 2>&1
  list=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" bundle list --json 2>&1)
  build_file="${tmp}/docker-build"
  make_model "${tmp}/home" "sakamakismile/Qwen3.8-27B-MTP-NVFP4" "$KV_CONFIG"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_BUILD_FILE="$build_file" "$SPARK" run external-bundle --no-wait >/dev/null 2>&1
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_BUILD_FILE="$build_file" "$SPARK" run external-bundle --no-wait >/dev/null 2>&1
  local ok=0
  jq -e '.[] | select(.name == "external-bundle" and .source == "imported")' <<<"$list" >/dev/null || ok=1
  [[ "$(grep -c '^build ' "$build_file")" -eq 2 ]] || ok=1
  [[ "$(cat "$build_file")" == *"-t spark/bundle-external-bundle:latest"* ]] || ok=1
  rm -rf "$tmp"
  [[ "$ok" == "0" ]]
}

test_bundle_run_resolves_defaults_and_dynamic_options() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output unbuilt_output
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "sakamakismile/Qwen3.8-27B-MTP-NVFP4" "$KV_CONFIG"
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    "$SPARK" run qwen38-dflash2-lookup --dry-run --max-len 32768 --lookup false 2>&1)
  local ok=0
  [[ "$output" == *"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"* ]] || ok=1
  [[ "$output" == *"--max-model-len 32768"* ]] || ok=1
  [[ "$output" == *"--speculative-config"* && "$output" == *"num_speculative_tokens"* ]] || ok=1
  [[ "$output" == *"VLLM_DFLASH2_LOOKUP=0"* ]] || ok=1
  [[ "$output" == *"spark.bundle.name=qwen38-dflash2-lookup"* ]] || ok=1
  [[ "$output" != *"VLLM_SPEC_DECODE_ATTN"* ]] || ok=1
  unbuilt_output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE_EXISTS=0 "$SPARK" run qwen38-dflash2-lookup --dry-run 2>&1) || ok=1
  [[ "$unbuilt_output" == *"spark/bundle-qwen38-dflash2-lookup:latest"* ]] || ok=1
  [[ "$unbuilt_output" == *"Docker command that would be executed"* ]] || ok=1
  rm -rf "$tmp"
  [[ "$ok" == "0" ]]
}

test_alias_create_from_bundle_stores_bundle_and_adjustments() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin aliases output create_output
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "sakamakismile/Qwen3.8-27B-MTP-NVFP4" "$KV_CONFIG"
  if ! create_output=$(printf 'b1\n\nn\n\n\n\n\n\nn\nfalse\n\n\n\n' | \
    HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ASSUME_INTERACTIVE=1 \
    "$SPARK" alias create qwen-bundle-alias 2>&1); then
    printf '%s\n' "$create_output" >&2
    rm -rf "$tmp"
    return 1
  fi
  aliases="${tmp}/home/.config/spark/aliases.json"
  local ok=0
  jq -e '
    .["qwen-bundle-alias"].kind == "bundle"
    and .["qwen-bundle-alias"].bundle == "qwen38-dflash2-lookup"
    and (.["qwen-bundle-alias"] | has("bundle_hash") | not)
    and .["qwen-bundle-alias"].run_args == []
    and .["qwen-bundle-alias"].options.lookup == false
  ' "$aliases" >/dev/null || ok=1
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    "$SPARK" run qwen-bundle-alias --dry-run 2>&1) || ok=1
  [[ "$output" == *"VLLM_DFLASH2_LOOKUP=0"* ]] || ok=1
  rm -rf "$tmp"
  [[ "$ok" == "0" ]]
}

test_total_mem_detection_positive() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output mem
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  # Bare config → need ~0, so it fits as long as detection yields a positive total.
  make_model "${tmp}/home" "Org/Bare" '{ "model_type":"qwen3", "max_position_embeddings":4096 }'

  # Do NOT pin SPARK_TOTAL_MEM_GB — this exercises real detection (/proc or sysctl).
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_OS_RESERVE_GB=0 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Bare --dry-run 2>&1)
  mem=$(printf '%s\n' "$output" | sed -n 's/.*Machine:[[:space:]]*\([0-9][0-9]*\) GB total.*/\1/p')
  rm -rf "$tmp"

  [[ "$mem" =~ ^[0-9]+$ ]] && [[ "$mem" -gt 0 ]]
}

test_need_based_fraction() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Qwen/Qwen3-30B --dry-run 2>&1)
  rm -rf "$tmp"

  [[ "$output" == *"KV cache:  24.0 GB"* ]] &&
    [[ "$output" == *"Weights:   14.0 GB"* ]] &&
    [[ "$output" == *"--gpu-memory-utilization 0.34"* ]] &&
    [[ "$output" == *"--max-model-len 262144"* ]]
}

test_fp8_halves_kv() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Qwen/Qwen3-30B --dry-run --kv-cache-dtype fp8 2>&1)
  rm -rf "$tmp"

  [[ "$output" == *"KV cache:  12.0 GB"* ]] &&
    [[ "$output" == *"--kv-cache-dtype fp8"* ]]
}

test_text_config_nested() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/MM" '{ "model_type":"llava", "architectures":["LlavaForConditionalGeneration"],
    "vision_config": {"hidden_size": 1024},
    "text_config": { "num_hidden_layers":32, "num_key_value_heads":8, "head_dim":128,
      "num_attention_heads":32, "hidden_size":4096, "max_position_embeddings":131072 } }'

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/MM --dry-run 2>&1)
  rm -rf "$tmp"

  # KV must be computed from text_config, not 0.
  [[ "$output" != *"KV cache:  0 GB"* ]] &&
    [[ "$output" == *"KV cache:"* ]] &&
    [[ "$output" != *"lacks KV cache fields"* ]]
}

test_missing_kv_fields_warns_not_aborts() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Bare" '{ "model_type":"qwen3", "architectures":["Qwen3ForCausalLM"], "max_position_embeddings":4096 }'

  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Bare --dry-run 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -eq 0 ]] && [[ "$output" == *"lacks KV cache fields"* ]]
}

test_capacity_verification_aborts() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"

  # A live model reserving 100 GB; budget is 121-10=111, so weights (14) alone don't fit
  # in the 11 GB free -> aborts non-interactively (no context helps).
  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED='spark-vllm-big\torg/big\t8000\t100.0\t80.0\t20.0\n' \
    "$SPARK" run Qwen/Qwen3-30B </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -ne 0 ]] &&
    [[ "$output" == *"Not enough memory"* ]] &&
    [[ "$output" == *"Needs:      41.0 GB"* ]] &&
    [[ "$output" == *"org/big"* ]] &&
    [[ "$output" == *"won't help"* ]]
}

test_port_auto_skips_busy() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED='spark-vllm-mini\torg/mini\t8000\t5.0\t3.0\t2.0\n' \
    "$SPARK" run Qwen/Qwen3-30B --dry-run 2>&1)
  rm -rf "$tmp"

  [[ "$output" == *"--port 8001"* ]]
}

test_gateway_yaml_per_model() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin yaml
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark"
  cat > "${tmp}/home/.config/spark/gateway.json" <<'EOF'
{ "enabled": true, "port": 4000, "providers": {
  "vllm": { "enabled": true, "port": 8000 }, "openrouter": { "enabled": false },
  "ollama": { "enabled": false }, "zen": { "enabled": false }, "together": { "enabled": false } } }
EOF

  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_MANAGED='spark-vllm-a\torg/A\t8000\t40.0\t30.0\t10.0\nspark-vllm-b\torg/B\t8001\t60.0\t55.0\t5.0\n' \
    "$SPARK" gateway start >/dev/null 2>&1 || true
  yaml=$(cat "${tmp}/home/.config/spark/litellm_config.yaml" 2>/dev/null || echo "")
  rm -rf "$tmp"

  [[ "$yaml" == *'model_name: "vllm/org/A"'* ]] &&
    [[ "$yaml" == *'model_name: "vllm/org/B"'* ]] &&
    [[ "$yaml" == *'model_name: "vllm/*"'* ]]
}

test_missing_model_no_pull_errors() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home"

  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Missing --no-pull </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -ne 0 ]] && [[ "$output" == *"not found in HF cache"* ]]
}

test_missing_model_dry_run_errors() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home"

  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Missing --dry-run </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -ne 0 ]] && [[ "$output" == *"not found in HF cache"* ]]
}

test_autopull_fits_downloads_and_starts() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status weights
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home"

  set +e
  output=$(printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_ASSUME_INTERACTIVE=1 SPARK_TOTAL_MEM_GB=121 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Qwen/Qwen3-30B 2>&1)
  status=$?
  weights="${tmp}/home/.cache/huggingface/hub/models--Qwen--Qwen3-30B/snapshots/1/model-00001-of-00001.safetensors"
  local downloaded=0; [[ -f "$weights" ]] && downloaded=1
  set -e
  rm -rf "$tmp"

  [[ "$status" -eq 0 ]] &&
    [[ "$output" == *"not downloaded"* ]] &&
    [[ "$output" == *"Model fits"* ]] &&
    [[ "$output" == *"started"* ]] &&
    [[ "$downloaded" -eq 1 ]]
}

test_autopull_no_fit_download_only() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home"

  # A live 100 GB model leaves no room; answer "y" to download anyway (without starting).
  set +e
  output=$(printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_ASSUME_INTERACTIVE=1 SPARK_TOTAL_MEM_GB=121 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED='spark-vllm-big\torg/big\t8000\t100.0\t80.0\t20.0\n' \
    "$SPARK" run Qwen/Qwen3-30B 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"

  [[ "$status" -eq 0 ]] &&
    [[ "$output" == *"Not enough memory"* ]] &&
    [[ "$output" == *"won't help"* ]] &&
    [[ "$output" == *"Downloaded Qwen/Qwen3-30B"* ]] &&
    [[ "$output" != *"started"* ]]
}

TWO_MODELS='spark-vllm-a\torg/Alpha\t8000\t40.0\t30.0\t10.0\nspark-vllm-b\torg/Beta\t8001\t60.0\t55.0\t5.0\n'

test_stop_specific_model() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; mkdir -p "${tmp}/home"
  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_MANAGED="$TWO_MODELS" \
    "$SPARK" stop org/Beta 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] && [[ "$output" == *"Stopped spark-vllm-b"* ]] && [[ "$output" != *"spark-vllm-a"* ]]
}

test_stop_all() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; mkdir -p "${tmp}/home"
  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_MANAGED="$TWO_MODELS" \
    "$SPARK" stop --all 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] && [[ "$output" == *"spark-vllm-a"* ]] && [[ "$output" == *"spark-vllm-b"* ]]
}

test_down_stops_models_and_gateway() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out stops status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; mkdir -p "${tmp}/home"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_NAMES='spark-litellm\n' \
    FAKE_MANAGED="$TWO_MODELS" FAKE_DOCKER_STOP_FILE="${tmp}/stops" \
    "$SPARK" down 2>&1)
  status=$?
  set -e
  stops=$(cat "${tmp}/stops" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] && [[ "$stops" == *"spark-litellm"* ]] &&
    [[ "$stops" == *"spark-vllm-a"* ]] && [[ "$stops" == *"spark-vllm-b"* ]] &&
    [[ "$out" == *"Spark services stopped"* ]]
}

test_stop_ambiguous_requires_target() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; mkdir -p "${tmp}/home"
  set +e
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_MANAGED="$TWO_MODELS" \
    "$SPARK" stop 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] && [[ "$output" == *"Multiple models running"* ]]
}

test_status_renders_served_models() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; mkdir -p "${tmp}/home/.config/spark"
  printf '%s\n' '{"enabled":true,"port":4000,"providers":{"vllm":{"enabled":true}}}' > "${tmp}/home/.config/spark/gateway.json"
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_INFO_EXIT=0 FAKE_NAMES='spark-litellm\n' FAKE_MANAGED="$TWO_MODELS" \
    FAKE_LITELLM_MODELS='{"data":[{"id":"vllm/org/Alpha"},{"id":"vllm/org/Beta"}]}' \
    "$SPARK" status 2>&1)
  rm -rf "$tmp"
  [[ "$output" == *"Served models"* ]] &&
    [[ "$output" == *"org/Alpha"* ]] &&
    [[ "$output" == *"ready"* ]] &&
    [[ "$output" == *"Direct:  http://localhost:8000/v1"* ]] &&
    [[ "$output" == *"Gateway: http://localhost:4000/v1 · model vllm/org/Alpha · routed"* ]] &&
    [[ "$output" == *"Memory:"* && "$output" == *"GB weights"* && "$output" == *"GB KV cache"* ]] &&
    [[ "$output" == *"Capacity:"* ]] &&
    [[ "$output" == *"GB allocatable"* ]] &&
    [[ "$output" != *"Agent workspace"* ]] &&
    [[ "$output" != *"Workspace compose"* ]] &&
    [[ "$output" != *"Tailscale"* ]] &&
    [[ "$output" != *"HF cache"* ]] &&
    [[ "$output" != *"Next steps"* ]]
}

test_status_json_quiet_and_exit_codes() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin json unhealthy_json quiet_out bad_out good_status bad_status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark"
  printf '%s\n' '{"enabled":true,"port":4000,"providers":{"vllm":{"enabled":true}}}' > "${tmp}/home/.config/spark/gateway.json"
  json=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_DOCKER_INFO_EXIT=0 \
    FAKE_NAMES='spark-litellm\n' FAKE_MANAGED="$TWO_MODELS" \
    FAKE_LITELLM_MODELS='{"data":[{"id":"vllm/org/Alpha"},{"id":"vllm/org/Beta"}]}' "$SPARK" status --json)
  set +e
  quiet_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_DOCKER_INFO_EXIT=0 \
    FAKE_NAMES='spark-litellm\n' FAKE_MANAGED="$TWO_MODELS" \
    FAKE_LITELLM_MODELS='{"data":[{"id":"vllm/org/Alpha"},{"id":"vllm/org/Beta"}]}' "$SPARK" status --quiet 2>&1)
  good_status=$?
  bad_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_DOCKER_INFO_EXIT=0 FAKE_VLLM_READY=0 \
    FAKE_NAMES='spark-litellm\n' FAKE_MANAGED="$TWO_MODELS" "$SPARK" status --quiet 2>&1)
  bad_status=$?
  unhealthy_json=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_DOCKER_INFO_EXIT=0 FAKE_VLLM_READY=0 \
    FAKE_STARTED_AT=2020-01-01T00:00:00Z FAKE_NAMES='spark-litellm\n' FAKE_MANAGED="$TWO_MODELS" \
    "$SPARK" status --json 2>/dev/null)
  set -e
  rm -rf "$tmp"
  printf '%s' "$json" | jq -e '
    .ok == true and .gateway.state == "ready" and
    ([.models[] | select(.state == "ready" and .gateway_model == "vllm/org/Alpha" and .gateway_routed == true)] | length == 1)
  ' >/dev/null &&
    printf '%s' "$unhealthy_json" | jq -e '.ok == false and ([.models[] | select(.state == "unhealthy")] | length == 2)' >/dev/null &&
    [[ "$good_status" -eq 0 && -z "$quiet_out" ]] &&
    [[ "$bad_status" -ne 0 && -z "$bad_out" ]]
}

test_dashboard_web_once_writes_product_ui() {
  local tmp fake_bin out html
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark"
  printf '%s\n' '{"enabled":true,"port":4000,"providers":{"vllm":{"enabled":true}}}' > "${tmp}/home/.config/spark/gateway.json"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_TOTAL_MEM_GB=121 \
    FAKE_MANAGED="$TWO_MODELS" FAKE_NAMES='spark-litellm\n' "$SPARK" dashboard --once 2>&1)
  html=$(cat "${tmp}/home/.config/spark/dashboard/index.html" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"Dashboard written:"* ]] &&
    [[ "$html" == *"spark dashboard"* ]] &&
    [[ "$html" == *"private agent stack"* ]] &&
    [[ "$html" == *"Setup"* ]] &&
    [[ "$html" == *"Services"* ]] &&
    [[ "$html" == *"Models"* ]] &&
    [[ "$html" == *"Agent workspace"* ]] &&
    [[ "$html" == *"Next steps"* ]]
}

test_dashboard_terminal_still_renders_snapshot() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark"
  printf '%s\n' '{"enabled":true,"port":4000,"providers":{"vllm":{"enabled":true}}}' > "${tmp}/home/.config/spark/gateway.json"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_TOTAL_MEM_GB=121 \
    FAKE_MANAGED="$TWO_MODELS" FAKE_NAMES='spark-litellm\n' "$SPARK" dashboard --terminal --no-clear 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"spark dashboard"* ]] &&
    [[ "$out" == *"Setup"* ]] &&
    [[ "$out" == *"Services"* ]] &&
    [[ "$out" == *"Models"* ]] &&
    [[ "$out" == *"Agent workspace"* ]] &&
    [[ "$out" == *"Next steps"* ]]
}

test_gateway_add_remove_provider() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin add_out rm_out enabled disabled
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark"
  cat > "${tmp}/home/.config/spark/gateway.json" <<'EOF'
{ "enabled": true, "port": 4000, "providers": {
  "vllm": { "enabled": true, "port": 8000 }, "openrouter": { "enabled": false },
  "ollama": { "enabled": false }, "zen": { "enabled": false }, "together": { "enabled": false } } }
EOF
  # ollama needs no API key, so add/remove are non-interactive.
  add_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" gateway add ollama 2>&1)
  enabled=$(jq -r '.providers.ollama.enabled' "${tmp}/home/.config/spark/gateway.json")
  rm_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" gateway remove ollama 2>&1)
  disabled=$(jq -r '.providers.ollama.enabled' "${tmp}/home/.config/spark/gateway.json")
  rm -rf "$tmp"
  [[ "$add_out" == *"Enabled ollama"* ]] && [[ "$enabled" == "true" ]] &&
    [[ "$rm_out" == *"Disabled ollama"* ]] && [[ "$disabled" == "false" ]]
}

# --- Platform / accelerator detection ---
test_detect_metal_on_apple_silicon() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(env -u SPARK_ACCEL -u SPARK_BACKEND HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_OS_OVERRIDE=Darwin SPARK_ARCH_OVERRIDE=arm64 FAKE_NVIDIA_SMI_EXIT=1 \
    "$SPARK" __detect 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"accel=metal"* ]] && [[ "$out" == *"backend=ollama"* ]]
}

test_detect_cuda_unified_on_arm_nvidia() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(env -u SPARK_ACCEL -u SPARK_BACKEND HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 FAKE_NVIDIA_SMI_EXIT=0 \
    "$SPARK" __detect 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"accel=cuda-unified"* ]] && [[ "$out" == *"backend=vllm"* ]]
}

test_detect_cuda_discrete_on_x86_nvidia() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(env -u SPARK_ACCEL -u SPARK_BACKEND HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=x86_64 FAKE_NVIDIA_SMI_EXIT=0 FAKE_VRAM_MIB=24576 \
    "$SPARK" __detect 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"accel=cuda-discrete"* ]] && [[ "$out" == *"backend=vllm"* ]]
}

test_detect_cpu_without_gpu() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(env -u SPARK_ACCEL -u SPARK_BACKEND HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=x86_64 FAKE_NVIDIA_SMI_EXIT=1 \
    "$SPARK" __detect 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"accel=cpu"* ]] && [[ "$out" == *"backend=ollama"* ]]
}

test_discrete_uses_vram_pool() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Small" '{ "model_type":"qwen3", "max_position_embeddings":4096 }'
  # Discrete GPU: pool is VRAM (24576 MiB → 24 GB), reserve is a small headroom.
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ACCEL=cuda-discrete \
    FAKE_NVIDIA_SMI_EXIT=0 FAKE_VRAM_MIB=24576 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Small --dry-run 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"24 GB VRAM"* ]] && [[ "$out" == *"headroom"* ]]
}

# --- Ollama backend ---
test_ollama_dry_run_plans_pull() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    "$SPARK" run qwen3:30b --dry-run 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"ollama pull qwen3:30b"* ]] &&
    [[ "$out" == *"ollama_chat/qwen3:30b"* ]] &&
    [[ "$out" == *"(ollama)"* ]] &&
    [[ "$out" != *"docker run"* ]]
}

test_ollama_run_pulls_and_enables_gateway() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out pulls cfg
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama SPARK_TOTAL_MEM_GB=121 \
    FAKE_OLLAMA_UP=1 FAKE_OLLAMA_PULL_FILE="${tmp}/pulls.txt" \
    "$SPARK" run qwen3:30b 2>&1)
  pulls=$(cat "${tmp}/pulls.txt" 2>/dev/null || echo "")
  cfg=$(jq -r '.providers.ollama.enabled' "${tmp}/home/.config/spark/gateway.json" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$pulls" == *"qwen3:30b"* ]] && [[ "$cfg" == "true" ]] && [[ "$out" == *"ready via Ollama"* ]]
}

# --- spark setup --host (local setup; --check goes straight to local in non-TTY) ---
test_host_check_ollama_ready() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama SPARK_ACCEL=metal \
    SPARK_OS_OVERRIDE=Darwin FAKE_OLLAMA_UP=1 FAKE_DOCKER_INFO_EXIT=0 \
    "$SPARK" setup --check </dev/null 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"backend ollama"* ]] && [[ "$out" == *"Ollama: installed"* ]] &&
    [[ "$out" == *"ready to serve"* ]]
}

test_host_check_vllm_no_gpu() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_ACCEL=cuda-unified \
    SPARK_OS_OVERRIDE=Linux FAKE_NVIDIA_SMI_EXIT=1 \
    "$SPARK" setup --check </dev/null 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"backend vllm"* ]] && [[ "$out" == *"No NVIDIA GPU detected"* ]] &&
    [[ "$out" == *"incomplete"* ]]
}

# --- Host OS hardening (swap-off + earlyoom -m5 + sshd MemoryMin/OOMScoreAdjust) ---
test_host_check_hardening_missing() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_ACCEL=cuda-unified \
    SPARK_OS_OVERRIDE=Linux "$SPARK" setup --check </dev/null 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"early-OOM not active"* ]] && [[ "$out" == *"not fully protected"* ]]
}

test_host_check_hardening_present() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  printf 'EARLYOOM_ARGS="-m 5 -s 10"\n' > "${tmp}/earlyoom.conf"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${fake_bin}/earlyoom"; chmod +x "${fake_bin}/earlyoom"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_ACCEL=cuda-unified \
    SPARK_OS_OVERRIDE=Linux FAKE_EARLYOOM_ACTIVE=0 FAKE_SWAP_TOTAL_GB=64 FAKE_SWAPPINESS=10 \
    FAKE_SSHD_MEMORYMIN=536870912 FAKE_SSHD_OOMSCORE=-1000 \
    EARLYOOM_DEFAULT_FILE="${tmp}/earlyoom.conf" \
    "$SPARK" setup --check </dev/null 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"earlyoom active (-m 5% -s 10%"* ]] && [[ "$out" == *"control-plane: OOM-protected"* ]] &&
    [[ "$out" == *"swappiness=10"* ]] && [[ "$out" != *"early-OOM not active"* ]] &&
    [[ "$out" != *"not fully protected"* ]] && [[ "$out" != *"Swap too small"* ]]
}

# Swap is reconciled by TOTAL active swap: ≥ target → no-op (no extra file); < target → flags it.
test_swap_reconcile_by_total() {
  local tmp fake_bin enough small
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  enough=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_ACCEL=cuda-unified \
    SPARK_OS_OVERRIDE=Linux FAKE_SWAP_TOTAL_GB=80 FAKE_SWAPPINESS=10 \
    "$SPARK" setup --check </dev/null 2>&1 || true)
  small=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_ACCEL=cuda-unified \
    SPARK_OS_OVERRIDE=Linux FAKE_SWAP_TOTAL_GB=16 FAKE_SWAPPINESS=10 \
    "$SPARK" setup --check </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$enough" == *"Swap: on (81920MiB total)"* ]] && [[ "$enough" != *"Swap too small"* ]] &&
    [[ "$small" == *"Swap too small"* ]]
}

run_swap_step_fixture() {
  local fake_bin="$1" home="$2" auto_yes="${3:-1}" check_only="${4:-0}"
  export FAKE_SWAP_TOTAL_MIB FAKE_SWAP_TOTAL_MIB_FILE FAKE_SWAP_TOTAL_GB FAKE_SWAP_TOTAL_GB_FILE
  export FAKE_SWAPFILE_SIZE_MIB FAKE_SWAPFILE_SIZE_MIB_FILE FAKE_SWAP_ON FAKE_SWAP_ON_FILE
  export FAKE_SWAPFILE_USED_MIB FAKE_SWAPFILE_USED_MIB_FILE FAKE_SWAP_USED_MIB FAKE_SWAP_USED_MIB_FILE
  export FAKE_SWAP_USED_GB FAKE_SWAP_USED_GB_FILE FAKE_SWAPPINESS FAKE_SWAPPINESS_FILE FAKE_SUDO_LOG
  HOME="$home" PATH="${fake_bin}:$PATH" bash -c '
    script="$1"; auto_yes="$2"; check_only="$3"
    source "$script"
    SETUP_TARGET=local
    SETUP_FAILED=()
    SETUP_SKIPPED=()
    SUDO_PW=""
    SUDO_READY=0
    step_swap_ensure "$auto_yes" "$check_only"
    printf "failed=%s skipped=%s\n" "${#SETUP_FAILED[@]}" "${#SETUP_SKIPPED[@]}"
  ' _ "$SPARK" "$auto_yes" "$check_only" 2>&1
}

test_swap_ready_no_mutation() {
  local tmp fake_bin out log
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; log="${tmp}/sudo.log"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_SWAP_TOTAL_MIB=65536 FAKE_SWAPPINESS=10 FAKE_SUDO_LOG="$log" \
    run_swap_step_fixture "$fake_bin" "${tmp}/home")
  [[ ! -s "$log" ]] || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  [[ "$out" == *"Swap: on (65536MiB total)"* ]] && [[ "$out" == *"failed=0"* ]]
}

test_swap_swapon_wins_when_free_reports_zero() {
  local tmp fake_bin setup_out doctor_out log
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; log="${tmp}/sudo.log"
  setup_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_SWAP_TOTAL_MIB=0 FAKE_SWAP_ON=1 FAKE_SWAPFILE_SIZE_MIB=131072 FAKE_SWAPFILE_USED_MIB=0 \
    FAKE_SWAPPINESS=10 FAKE_SUDO_LOG="$log" \
    run_swap_step_fixture "$fake_bin" "${tmp}/home")
  [[ ! -s "$log" ]] || { rm -rf "$tmp"; return 1; }
  doctor_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_ACCEL=cuda-unified \
    SPARK_OS_OVERRIDE=Linux FAKE_SWAP_TOTAL_MIB=0 FAKE_SWAP_ON=1 FAKE_SWAPFILE_SIZE_MIB=131072 \
    FAKE_SWAPFILE_USED_MIB=0 FAKE_SWAPPINESS=10 "$SPARK" doctor --verbose 2>&1 || true)
  rm -rf "$tmp"
  [[ "$setup_out" == *"Swap: on (131072MiB total) via swapon (free=0MiB)"* ]] &&
    [[ "$setup_out" == *"failed=0"* ]] &&
    [[ "$doctor_out" == *"Swap and swappiness"* ]] &&
    [[ "$doctor_out" == *"131072 MiB via swapon (free=0MiB)"* ]] &&
    [[ "$doctor_out" != *"target ≥"* ]]
}

test_swap_wrong_swappiness_reconciles() {
  local tmp fake_bin out log sw_file
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; log="${tmp}/sudo.log"; sw_file="${tmp}/swappiness"
  printf '60\n' > "$sw_file"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_SWAP_TOTAL_MIB=65536 FAKE_SWAPPINESS_FILE="$sw_file" FAKE_SUDO_LOG="$log" \
    run_swap_step_fixture "$fake_bin" "${tmp}/home")
  [[ "$(cat "$sw_file")" == "10" ]] || { rm -rf "$tmp"; return 1; }
  [[ "$(cat "$log")" != *"/swapfile.spark"* ]] || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  [[ "$out" == *"Swap: on (65536MiB total)"* ]] && [[ "$out" == *"swappiness=10"* ]] && [[ "$out" == *"failed=0"* ]]
}

test_swap_missing_file_creates_topup() {
  local tmp fake_bin out total_file size_file on_file used_file sw_file log
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  total_file="${tmp}/swap-total"; size_file="${tmp}/swap-size"; on_file="${tmp}/swap-on"; used_file="${tmp}/swap-used"; sw_file="${tmp}/swappiness"; log="${tmp}/sudo.log"
  printf '16384\n' > "$total_file"; printf '0\n' > "$size_file"; printf '0\n' > "$on_file"; printf '0\n' > "$used_file"; printf '10\n' > "$sw_file"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_SWAP_TOTAL_MIB_FILE="$total_file" FAKE_SWAPFILE_SIZE_MIB_FILE="$size_file" FAKE_SWAP_ON_FILE="$on_file" \
    FAKE_SWAPFILE_USED_MIB_FILE="$used_file" FAKE_SWAPPINESS_FILE="$sw_file" FAKE_SUDO_LOG="$log" \
    run_swap_step_fixture "$fake_bin" "${tmp}/home")
  [[ "$(cat "$total_file")" == "65536" && "$(cat "$size_file")" == "49152" && "$(cat "$on_file")" == "1" ]] || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  [[ "$out" == *"Swap: on (65536MiB total)"* ]] && [[ "$out" == *"failed=0"* ]]
}

test_swap_existing_inactive_file_activates() {
  local tmp fake_bin out total_file size_file on_file used_file sw_file log
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  total_file="${tmp}/swap-total"; size_file="${tmp}/swap-size"; on_file="${tmp}/swap-on"; used_file="${tmp}/swap-used"; sw_file="${tmp}/swappiness"; log="${tmp}/sudo.log"
  printf '16384\n' > "$total_file"; printf '49152\n' > "$size_file"; printf '0\n' > "$on_file"; printf '0\n' > "$used_file"; printf '10\n' > "$sw_file"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_SWAP_TOTAL_MIB_FILE="$total_file" FAKE_SWAPFILE_SIZE_MIB_FILE="$size_file" FAKE_SWAP_ON_FILE="$on_file" \
    FAKE_SWAPFILE_USED_MIB_FILE="$used_file" FAKE_SWAPPINESS_FILE="$sw_file" FAKE_SUDO_LOG="$log" \
    run_swap_step_fixture "$fake_bin" "${tmp}/home")
  [[ "$(cat "$total_file")" == "65536" && "$(cat "$on_file")" == "1" && "$(cat "$log")" != *"fallocate"* ]] || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  [[ "$out" == *"Swap: on (65536MiB total)"* ]] && [[ "$out" == *"failed=0"* ]]
}

test_swap_active_unused_wrong_size_recreates() {
  local tmp fake_bin out total_file size_file on_file used_file sw_file log
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  total_file="${tmp}/swap-total"; size_file="${tmp}/swap-size"; on_file="${tmp}/swap-on"; used_file="${tmp}/swap-used"; sw_file="${tmp}/swappiness"; log="${tmp}/sudo.log"
  printf '32768\n' > "$total_file"; printf '16384\n' > "$size_file"; printf '1\n' > "$on_file"; printf '0\n' > "$used_file"; printf '10\n' > "$sw_file"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_SWAP_TOTAL_MIB_FILE="$total_file" FAKE_SWAPFILE_SIZE_MIB_FILE="$size_file" FAKE_SWAP_ON_FILE="$on_file" \
    FAKE_SWAPFILE_USED_MIB_FILE="$used_file" FAKE_SWAPPINESS_FILE="$sw_file" FAKE_SUDO_LOG="$log" \
    run_swap_step_fixture "$fake_bin" "${tmp}/home")
  [[ "$(cat "$total_file")" == "65536" && "$(cat "$size_file")" == "49152" && "$(cat "$log")" == *"swapoff"* ]] || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  [[ "$out" == *"Swap: on (65536MiB total)"* ]] && [[ "$out" == *"failed=0"* ]]
}

test_swap_active_used_wrong_size_fails_safely() {
  local tmp fake_bin out total_file size_file on_file used_file sw_file log
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  total_file="${tmp}/swap-total"; size_file="${tmp}/swap-size"; on_file="${tmp}/swap-on"; used_file="${tmp}/swap-used"; sw_file="${tmp}/swappiness"; log="${tmp}/sudo.log"
  printf '32768\n' > "$total_file"; printf '16384\n' > "$size_file"; printf '1\n' > "$on_file"; printf '1024\n' > "$used_file"; printf '10\n' > "$sw_file"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_SWAP_TOTAL_MIB_FILE="$total_file" FAKE_SWAPFILE_SIZE_MIB_FILE="$size_file" FAKE_SWAP_ON_FILE="$on_file" \
    FAKE_SWAPFILE_USED_MIB_FILE="$used_file" FAKE_SWAPPINESS_FILE="$sw_file" FAKE_SUDO_LOG="$log" \
    run_swap_step_fixture "$fake_bin" "${tmp}/home")
  [[ ! -s "$log" && "$(cat "$size_file")" == "16384" ]] || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  [[ "$out" == *"Could not reconcile swap"* ]] && [[ "$out" == *"stop memory pressure"* ]] && [[ "$out" == *"failed=1"* ]]
}

test_setup_full_continues_after_swap_reconcile() {
  local tmp fake_bin out total_file size_file on_file used_file sw_file log status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  total_file="${tmp}/swap-total"; size_file="${tmp}/swap-size"; on_file="${tmp}/swap-on"; used_file="${tmp}/swap-used"; sw_file="${tmp}/swappiness"; log="${tmp}/sudo.log"
  printf '16384\n' > "$total_file"; printf '0\n' > "$size_file"; printf '0\n' > "$on_file"; printf '0\n' > "$used_file"; printf '10\n' > "$sw_file"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_SWAP_TOTAL_MIB_FILE="$total_file" FAKE_SWAPFILE_SIZE_MIB_FILE="$size_file" FAKE_SWAP_ON_FILE="$on_file" \
    FAKE_SWAPFILE_USED_MIB_FILE="$used_file" FAKE_SWAPPINESS_FILE="$sw_file" FAKE_SUDO_LOG="$log" \
    bash -c '
      script="$1"
      source "$script"
      run_setup_wizard() { step_swap_ensure 1 0; }
      cmd_setup_full_workspace() { echo "workspace reached"; }
      cmd_setup --yes --full
    ' _ "$SPARK" 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] && [[ "$out" == *"workspace reached"* ]] && [[ "$out" != *"Workspace setup skipped"* ]]
}

# spark status shows a live block: host RAM/swap + per-model reserved/now/peak from the cgroup.
test_status_live_memory() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_ACCEL=cuda-unified \
    SPARK_TOTAL_MEM_GB=121 \
    FAKE_MANAGED="spark-vllm-q\tOrg/Q\t8000\t80.1\t71.2\t6.0\n" \
    FAKE_RAM_TOTAL_GB=121 FAKE_RAM_USED_GB=108 FAKE_RAM_AVAIL_GB=13 \
    FAKE_SWAP_TOTAL_GB=176 FAKE_SWAP_USED_GB=2 \
    FAKE_MEM_CURRENT=$((84 * 1073741824)) FAKE_MEM_PEAK=$((90 * 1073741824)) \
    "$SPARK" status 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"Live:"* ]] && [[ "$out" == *"RAM 108/121 GB used"* ]] && [[ "$out" == *"swap 2/176 GB"* ]] &&
    [[ "$out" == *"80.1 GB reserved"* ]] && [[ "$out" == *"84.0 GB now"* ]] && [[ "$out" == *"90.0 GB peak"* ]]
}

# --- Unified setup wizard (host vs server picker, parity, bootstrap) ---
test_setup_picker_routes_to_host() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  # Pick [1] this machine; --check short-circuits the install prompts.
  out=$(printf '1\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    SPARK_ACCEL=metal SPARK_OS_OVERRIDE=Darwin FAKE_OLLAMA_UP=1 FAKE_DOCKER_INFO_EXIT=0 \
    "$SPARK" setup --check 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"what do you want to set up"* ]] && [[ "$out" == *"set up this machine"* ]] &&
    [[ "$out" == *"backend ollama"* ]]
}

test_setup_host_no_disable_password() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_ACCEL=cuda-unified \
    SPARK_OS_OVERRIDE=Linux "$SPARK" setup --check </dev/null 2>&1) || true
  rm -rf "$tmp"
  # Host mode (--check) must never claim to disable password SSH.
  [[ "$out" != *"Disabled password SSH login"* ]]
}

test_setup_server_check_parity() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  # Drive the wizard: [2] remote, target, "no key" -> bootstrap. ssh/sshpass are mocked so
  # the install set runs against a fake "remote" that mirrors the local checks.
  out=$(printf '2\nme@10.0.0.5\nn\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_OS_OVERRIDE=Linux FAKE_SSH_NVIDIA=1 \
    "$SPARK" setup --check 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"Phase 2: Remote install"* ]] && [[ "$out" == *"NVIDIA Container Toolkit"* ]]
}

test_setup_unknown_flag_fails() {
  local out status
  set +e
  out=$("$SPARK" setup --bogus </dev/null 2>&1); status=$?
  set -e
  [[ "$status" -ne 0 ]] && [[ "$out" == *"Unknown flag"* ]]
}

test_setup_full_check_runs_workspace_phase() {
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; mkdir -p "${tmp}/home"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" setup --check --full </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"spark setup --full"* ]] &&
    [[ "$out" == *"spark ws setup"* ]]
}

# --- spark ws ---
make_min_workspace_config() {
  local home="$1" dir
  dir="${home}/.config/spark/workspace"
  mkdir -p "$dir"
  : > "${dir}/docker-compose.yml"
  if [[ ! -f "${dir}/secrets.env" ]]; then
    : > "${dir}/secrets.env"
    chmod 600 "${dir}/secrets.env"
  fi
}

test_help_text_tracks_current_cli() {
  local top bundle dashboard gateway config models reinstall uninstall ws recover setup_error status
  top=$("$SPARK" help 2>&1)
  bundle=$("$SPARK" bundle --help 2>&1)
  dashboard=$("$SPARK" dashboard --help 2>&1)
  gateway=$("$SPARK" gateway --help 2>&1)
  config=$("$SPARK" config --help 2>&1)
  models=$("$SPARK" models --help 2>&1)
  reinstall=$("$SPARK" reinstall --help 2>&1)
  uninstall=$("$SPARK" uninstall --help 2>&1)
  ws=$("$SPARK" ws --help 2>&1)
  recover=$("$SPARK" ws recover --help 2>&1)
  status=$("$SPARK" status --help 2>&1)
  set +e
  setup_error=$("$SPARK" setup --not-a-real-flag 2>&1)
  set -e

  [[ "$top" == *"Web dashboard, with an optional terminal view"* ]] &&
    [[ "$top" == *"version          Show the installed Spark version"* ]] &&
    [[ "$top" == *"--no-mem-limit"* ]] &&
    [[ "$top" == *"--mtp / --no-mtp"* ]] &&
    [[ "$top" == *"--explain"* ]] &&
    [[ "$top" == *"bundle sync [--check]"* ]] &&
    [[ "$top" == *"spark bundle --help"* ]] &&
    [[ "$top" != *"default: 128K"* ]] &&
    [[ "$top" != *"default: 5"* ]] &&
    [[ "$dashboard" == *"--terminal"* ]] &&
    [[ "$bundle" == *"sync [--check]"* ]] &&
    [[ "$bundle" == *"Run automatically builds its Dockerfile"* ]] &&
    [[ "$dashboard" == *"--watch [seconds]"* ]] &&
    [[ "$gateway" == *"start|stop|status|logs|add|remove"* ]] &&
    [[ "$config" == *"auto-update on|off"* ]] &&
    [[ "$models" == *"recommend [--json]"* ]] &&
    [[ "$reinstall" == *"--purge-models|--keep-models"* ]] &&
    [[ "$uninstall" == *"-y|--yes"* ]] &&
    [[ "$ws" == *"Reset a Vikunja human or n8n owner password"* ]] &&
    [[ "$ws" == *"SuperSync/Electron"* ]] &&
    [[ "$recover" == *"Vikunja human or n8n owner password"* ]] &&
    [[ "$status" == *"--verbose"* ]] &&
    [[ "$setup_error" == *"--tailscale-mode services|ports"* ]]
}

test_workspace_help_and_command() {
  local out old status
  out=$("$SPARK" ws help 2>&1)
  set +e
  old=$("$SPARK" workspace help 2>&1)
  status=$?
  set -e
  [[ "$out" == *"ws <command>"* ]] && [[ "$out" == *"setup"* ]] &&
    [[ "$out" == *"--tailscale-mode services|ports"* ]] &&
    [[ "$status" -ne 0 ]] &&
    [[ "$old" == *"Unknown command: workspace"* ]]
}

test_workspace_lifecycle_commands() {
  local tmp fake_bin calls out down status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_min_workspace_config "${tmp}/home"
  calls="${tmp}/calls"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" CALLS="$calls" bash -c '
    source "$1"
    workspace_configured() { return 0; }
    workspace_migrate_runtime_config() { printf "migrate\n" >> "$CALLS"; }
    workspace_read_env() { [[ "$1" == HERMES_MODEL ]] && printf "Org/Model\n"; }
    workspace_compose() { printf "compose %s\n" "$*" >> "$CALLS"; }
    workspace_ensure_gateway() { printf "gateway %s\n" "$*" >> "$CALLS"; }
    workspace_tailscale_services_configured() { return 0; }
    workspace_start_hermes_gateway_proxy() { printf "bridge start\n" >> "$CALLS"; }
    workspace_stop_hermes_gateway_proxy() { printf "bridge stop\n" >> "$CALLS"; }
    workspace_start_hermes_vikunja_proxy() { printf "tasks bridge start\n" >> "$CALLS"; }
    workspace_stop_hermes_vikunja_proxy() { printf "tasks bridge stop\n" >> "$CALLS"; }
    workspace_start_hermes_dashboard_proxy() { printf "dashboard proxy start\n" >> "$CALLS"; }
    workspace_stop_hermes_dashboard_proxy() { printf "dashboard proxy stop\n" >> "$CALLS"; }
    workspace_start_hermes_private_proxy() { printf "hermes start\n" >> "$CALLS"; }
    workspace_hermes_running_container_name() { printf "workspace-hermes\n"; }
    nemohermes() { printf "nemohermes %s\n" "$*" >> "$CALLS"; }
    gateway_stop() { printf "gateway stop\n" >> "$CALLS"; }
    workspace_model_running() { return 0; }
    cmd_stop() { printf "model stop %s\n" "$*" >> "$CALLS"; }
    docker() { printf "docker %s\n" "$*" >> "$CALLS"; }
    workspace_start
    workspace_stop
  ' _ "$SPARK"
  out=$("$SPARK" ws help 2>&1)
  set +e
  down=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws down 2>&1)
  status=$?
  set -e
  calls=$(cat "$calls")
  rm -rf "$tmp"
  [[ "$calls" == *"migrate"* ]] &&
    [[ "$calls" == *"compose up -d --remove-orphans"* ]] &&
    [[ "$calls" == *"gateway 0 1 Org/Model"* ]] &&
    [[ "$calls" == *"bridge start"* ]] &&
    [[ "$calls" == *"tasks bridge start"* ]] &&
    [[ "$calls" == *"dashboard proxy start"* ]] &&
    [[ "$calls" == *"hermes start"* ]] &&
    [[ "$calls" == *"nemohermes hermes stop"* ]] &&
    [[ "$calls" == *"gateway stop"* ]] &&
    [[ "$calls" == *"bridge stop"* ]] &&
    [[ "$calls" == *"tasks bridge stop"* ]] &&
    [[ "$calls" == *"dashboard proxy stop"* ]] &&
    [[ "$calls" == *"model stop Org/Model"* ]] &&
    [[ "$calls" == *"compose stop"* ]] &&
    [[ "$out" == *"start"* && "$out" == *"stop"* && "$out" == *"restart"* ]] &&
    [[ "$out" != *"down       Stop"* ]] &&
    [[ "$status" -ne 0 ]] && [[ "$down" == *"Unknown ws command: down"* ]]
}

test_workspace_restart_orders_stop_then_start() {
  local out
  out=$(bash -c '
    source "$1"
    workspace_stop() { printf "stop\n"; }
    workspace_start() { printf "start\n"; }
    workspace_restart
  ' _ "$SPARK")
  [[ "$out" == $'stop\nstart' ]]
}

test_workspace_hermes_start_uses_official_lifecycle() {
  local out
  out=$(bash -c '
    source "$1"
    private_probes=0
    nemo_calls=""
    workspace_hermes_private_url_ready() {
      private_probes=$((private_probes + 1))
      [[ "$private_probes" -gt 1 ]]
    }
    workspace_hermes_local_api_ready() { return 0; }
    workspace_restore_hermes_container_name() { return 0; }
    nemohermes() { nemo_calls="${nemo_calls}${*}\n"; }
    openshell() { :; }
    workspace_start_hermes_private_proxy
    printf "%b" "$nemo_calls"
  ' _ "$SPARK")
  [[ "$out" == *"hermes start"* ]] && [[ "$out" == *"hermes recover"* ]]
}

test_workspace_bridge_waits_for_delayed_readiness() {
  local tmp out
  tmp=$(mktemp -d)
  out=$(HOME="${tmp}/home" bash -c '
    source "$1"
    probes=0
    workspace_openshell_bridge_ip() { printf "172.19.0.1\n"; }
    docker() {
      case "${1:-}" in
        inspect) printf "true\n" ;;
      esac
    }
    curl() {
      probes=$((probes + 1))
      [[ "$probes" -ge 8 ]]
    }
    sleep() { :; }
    workspace_start_hermes_gateway_proxy
    printf "probes=%s\n" "$probes"
  ' _ "$SPARK")
  rm -rf "$tmp"
  [[ "$out" == "probes=8" ]]
}

test_workspace_dashboard_proxy_rewrites_host_on_loopback() {
  local tmp fake_bin docker_args proxy_script
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_DOCKER_ARGS_FILE="${tmp}/docker.log" bash -c '
    source "$1"
    workspace_start_hermes_dashboard_proxy
  ' _ "$SPARK"
  docker_args=$(cat "${tmp}/docker.log")
  proxy_script="${tmp}/home/.config/spark/workspace/hermes-dashboard-proxy.py"
  [[ "$docker_args" == *"--network host"* ]] &&
    [[ "$docker_args" == *"hermes-dashboard-proxy.py 18790 18789"* ]] &&
    grep -Fq 'asyncio.start_server(handle, "127.0.0.1"' "$proxy_script" &&
    grep -Fq 'Host: 127.0.0.1:' "$proxy_script" &&
    grep -Fq 'Origin: http://127.0.0.1:' "$proxy_script"
  local status=$?
  rm -rf "$tmp"
  return "$status"
}

test_workspace_listener_check_allows_only_openshell_gateway_bridge() {
  bash -c '
    source "$1"
    workspace_read_env() { [[ "$1" == WORKSPACE_TAILSCALE_MODE ]] && printf "services\n"; }
    workspace_openshell_bridge_ip() { printf "172.19.0.1\n"; }
    ss() { printf "LISTEN 0 4096 172.19.0.1:4000 0.0.0.0:*\nLISTEN 0 4096 172.19.0.1:3456 0.0.0.0:*\n"; }
    workspace_host_listeners_loopback_only
  ' _ "$SPARK"
}

test_workspace_model_start_disables_mtp_for_reliable_recovery() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "${tmp}/home/.config/spark"
  printf '{}\n' > "${tmp}/home/.config/spark/gateway.json"
  out=$(HOME="${tmp}/home" bash -c '
    source "$1"
    docker() { [[ "$*" == *"ps --format"* ]] && printf "%s\n" "$GATEWAY_CONTAINER"; }
    workspace_model_state() { printf "stopped\n"; }
    cmd_run() { printf "%s\n" "$*"; }
    workspace_ensure_gateway 0 1 Org/Model
  ' _ "$SPARK")
  rm -rf "$tmp"
  [[ "$out" == *"Org/Model --no-mtp --tools --max-len 65536"* ]] && [[ "$out" != *"--no-wait"* ]]
}

test_workspace_model_restarts_without_tool_calling() {
  local tmp out
  tmp=$(mktemp -d)
  mkdir -p "${tmp}/home/.config/spark"
  printf '{}\n' > "${tmp}/home/.config/spark/gateway.json"
  out=$(HOME="${tmp}/home" bash -c '
    source "$1"
    docker() { [[ "$*" == *"ps --format"* ]] && printf "%s\n" "$GATEWAY_CONTAINER"; }
    workspace_model_state() { printf "running+routed\n"; }
    workspace_model_tool_calling_ready() { return 1; }
    cmd_run() { printf "%s\n" "$*"; }
    workspace_ensure_gateway 0 1 Org/Model
  ' _ "$SPARK")
  rm -rf "$tmp"
  [[ "$out" == *"Org/Model --no-mtp --tools --max-len 65536 --force"* ]]
}

test_workspace_model_tool_calling_requires_expected_parser() {
  local tmp fake_bin wrong=0 right=0 profile
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark/profiles"
  profile="${tmp}/home/.config/spark/profiles/Org--Model.json"
  printf '%s\n' '{"tool_call_parser":"qwen3_xml","hf":{"raw":{"model_type":"qwen3_5"}}}' > "$profile"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_MANAGED=$'spark-vllm-model\tOrg/Model\t8000\t1\t1\t0\n' \
    FAKE_DOCKER_CMD_JSON='["Org/Model","--enable-auto-tool-choice","--tool-call-parser","qwen3_xml"]' \
    bash -c 'source "$1"; workspace_model_tool_calling_ready Org/Model' _ "$SPARK" || wrong=$?
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_MANAGED=$'spark-vllm-model\tOrg/Model\t8000\t1\t1\t0\n' \
    FAKE_DOCKER_CMD_JSON='["Org/Model","--enable-auto-tool-choice","--tool-call-parser","qwen3_coder"]' \
    bash -c 'source "$1"; workspace_model_tool_calling_ready Org/Model' _ "$SPARK" || right=$?
  rm -rf "$tmp"
  [[ "$wrong" -ne 0 && "$right" -eq 0 ]]
}

test_workspace_hermes_toolsets_are_balanced() {
  local tmp fake_bin calls wrong=0
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    bash -c 'source "$1"; workspace_configure_hermes_cli_toolsets; workspace_hermes_cli_toolsets_ready' _ "$SPARK"
  calls=$(cat "${tmp}/nemohermes.log")
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_HERMES_TOOLS_LIST=$'Built-in toolsets (cli):\n  enabled  terminal\n  enabled  browser' \
    bash -c 'source "$1"; workspace_hermes_cli_toolsets_ready' _ "$SPARK" || wrong=$?
  rm -rf "$tmp"
  [[ "$calls" == *"hermes tools enable --platform cli terminal file web skills memory todo cronjob delegation"* ]] &&
    [[ "$calls" == *"hermes tools disable --platform cli browser code_execution vision video image_gen video_gen x_search tts context_engine session_search clarify homeassistant spotify yuanbao computer_use"* ]] &&
    [[ "$wrong" -ne 0 ]]
}

test_workspace_status_uses_tailscale_services_config() {
  local tmp fake_bin out calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_min_workspace_config "${tmp}/home"
  printf 'WORKSPACE_TAILSCALE_MODE=services\n' > "${tmp}/home/.config/spark/workspace/secrets.env"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_TAILSCALE_FILE="${tmp}/tailscale.log" \
    bash -c 'source "$1"; workspace_print_tailscale_runtime_status' _ "$SPARK" 2>&1)
  calls=$(cat "${tmp}/tailscale.log")
  rm -rf "$tmp"
  [[ "$calls" == *"serve get-config --all"* ]] &&
    [[ "$calls" != *"serve status"* ]] &&
    [[ "$out" == *"Tailscale Services configured"* ]]
}

test_workspace_restores_openshell_hermes_name() {
  local out
  out=$(bash -c '
    source "$1"
    renamed=""
    workspace_hermes_container_name() { printf "workspace-hermes\n"; }
    docker() {
      case "$*" in
        *sandbox-name*) printf "hermes\n" ;;
        *sandbox-id*) printf "abc-123\n" ;;
        "ps -a --format "*) return 0 ;;
        "rename workspace-hermes openshell-hermes-abc-123") renamed="$*" ;;
      esac
    }
    workspace_restore_hermes_container_name
    printf "%s\n" "$renamed"
  ' _ "$SPARK")
  [[ "$out" == "rename workspace-hermes openshell-hermes-abc-123" ]]
}

test_workspace_setup_rejects_bad_tailscale_mode() {
  local out status
  set +e
  out=$("$SPARK" ws setup --task-manager vikunja --tailscale-mode public </dev/null 2>&1); status=$?
  set -e
  [[ "$status" -ne 0 ]] && [[ "$out" == *"--tailscale-mode must be 'services' or 'ports'"* ]]
}

test_workspace_setup_rejects_bad_image_ref() {
  local tmp out status mutated=0
  tmp=$(mktemp -d)
  set +e
  out=$(HOME="${tmp}/home" "$SPARK" ws setup --task-manager vikunja --check --model Org/Alpha \
    --postgres-image 'postgres:18 # broken' </dev/null 2>&1)
  status=$?
  set -e
  [[ -e "${tmp}/home/.config/spark/workspace/secrets.env" ]] && mutated=1
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Invalid Postgres image"* ]] &&
    [[ "$mutated" -eq 0 ]]
}

test_workspace_setup_rejects_multiline_secret() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status mutated=0
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=$'massimo\nbad' SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1)
  status=$?
  set -e
  [[ -e "${tmp}/home/.config/spark/workspace/secrets.env" ]] && mutated=1
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Ignoring invalid Workspace username"* ]] &&
    [[ "$out" == *"Workspace username is required"* ]] &&
    [[ "$mutated" -eq 0 ]]
}

make_cached_model() {
  local home="$1" model="$2" dir
  dir="${home}/.cache/huggingface/hub/models--${model//\//--}/snapshots/1"
  mkdir -p "$dir"
  : > "${dir}/config.json"
}

test_workspace_check_no_mutation() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 "$SPARK" ws setup --task-manager vikunja --check --model Org/Alpha 2>&1)
  status=$?
  set -e
  local mutated=0
  [[ -e "${tmp}/home/.config/spark/workspace/docker-compose.yml" ]] && mutated=1
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Workspace incomplete"* ]] &&
    [[ "$mutated" -eq 0 ]]
}

test_workspace_check_existing_config_no_mutation() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env_file before after
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_TAILSCALE_MODE=services \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  before=$(cat "$env_file")
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\nopenshell-hermes-test\n' \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"CapMap":{"services/tasks":[{"Name":"svc:tasks","Ports":["tcp:443"]}],"services/n8n":[{"Name":"svc:n8n","Ports":["tcp:443"]}],"services/hermes":[{"Name":"svc:hermes","Ports":["tcp:443"]}]}}}' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_VIKUNJA_USER_EXIT=1 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --check --model Org/Alpha 2>&1)
  status=$?
  set -e
  after=$(cat "$env_file")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Workspace incomplete"* ]] &&
    [[ "$before" == "$after" ]] &&
    [[ "$after" == *"VIKUNJA_HERMES_API_STATUS=verified"* ]]
}

test_workspace_check_reports_missing_compose_plugin() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status mutated=0
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_COMPOSE_VERSION_EXIT=1 FAKE_TAILSCALE_STATUS_EXIT=0 \
    "$SPARK" ws setup --task-manager vikunja --check --model Org/Alpha 2>&1)
  status=$?
  set -e
  [[ -e "${tmp}/home/.config/spark/workspace/docker-compose.yml" ]] && mutated=1
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Docker Compose plugin missing or unusable"* ]] &&
    [[ "$out" == *"Workspace incomplete"* ]] &&
    [[ "$mutated" -eq 0 ]]
}

test_workspace_model_tui_uses_list() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  make_cached_model "${tmp}/home" "Org/Beta"
  out=$(printf '2\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ASSUME_INTERACTIVE=1 \
    FAKE_TAILSCALE_STATUS_EXIT=0 "$SPARK" ws setup --task-manager vikunja --check 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"Choose the model Hermes will use"* ]] && [[ "$out" == *"Org/Alpha"* ]] && [[ "$out" == *"Org/Beta"* ]]
}

test_workspace_rejects_partial_model() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status dir
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  dir="${tmp}/home/.cache/huggingface/hub/models--Org--Partial"
  mkdir -p "${dir}/snapshots/1" "${dir}/blobs"
  : > "${dir}/snapshots/1/config.json"
  : > "${dir}/blobs/weights.incomplete"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 "$SPARK" ws setup --task-manager vikunja --check --model Org/Partial 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Model not found or not fully downloaded in spark list: Org/Partial"* ]]
}

test_workspace_setup_waits_for_model() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Alpha" "$KV_CONFIG"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_TOTAL_MEM_GB=121 \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.05-py3" FAKE_NAMES='spark-litellm\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"Container '"*"started"* ]] &&
    [[ "$out" == *"started. "*"serving"* ]] &&
    [[ "$out" == *"waiting for it to serve"* ]]
}

test_workspace_setup_writes_compose_names() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out compose init tailscale_calls nemo_calls openshell_calls curl_calls docker_calls skill env postgres_env vikunja_env n8n_env workspace_mode compose_mode gateway_mode litellm_mode
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_FILE="${tmp}/tailscale.log" \
    FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_OPENSHELL_FILE="${tmp}/openshell.log" \
    FAKE_OPENSHELL_PROVIDERS_V2=false FAKE_OPENSHELL_PROVIDER_EXISTS=0 \
    FAKE_OPENSHELL_PROVIDER_ATTACHED=0 \
    FAKE_DOCKER_ARGS_FILE="${tmp}/docker.log" \
    FAKE_CURL_FILE="${tmp}/curl.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1 || true)
  compose=$(cat "${tmp}/home/.config/spark/workspace/docker-compose.yml" 2>/dev/null || echo "")
  init=$(cat "${tmp}/home/.config/spark/workspace/init-db.sh" 2>/dev/null || echo "")
  tailscale_calls=$(cat "${tmp}/tailscale.log" 2>/dev/null || echo "")
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  openshell_calls=$(cat "${tmp}/openshell.log" 2>/dev/null || echo "")
  curl_calls=$(cat "${tmp}/curl.log" 2>/dev/null || echo "")
  docker_calls=$(cat "${tmp}/docker.log" 2>/dev/null || echo "")
  skill=$(cat "${tmp}/home/.config/spark/workspace/hermes-skills/vikunja/SKILL.md" 2>/dev/null || echo "")
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  postgres_env=$(cat "${tmp}/home/.config/spark/workspace/postgres.env" 2>/dev/null || echo "")
  vikunja_env=$(cat "${tmp}/home/.config/spark/workspace/vikunja.env" 2>/dev/null || echo "")
  n8n_env=$(cat "${tmp}/home/.config/spark/workspace/n8n.env" 2>/dev/null || echo "")
  workspace_mode=$(stat -c '%a' "${tmp}/home/.config/spark/workspace" 2>/dev/null || stat -f '%Lp' "${tmp}/home/.config/spark/workspace" 2>/dev/null || echo "")
  compose_mode=$(stat -c '%a' "${tmp}/home/.config/spark/workspace/docker-compose.yml" 2>/dev/null || stat -f '%Lp' "${tmp}/home/.config/spark/workspace/docker-compose.yml" 2>/dev/null || echo "")
  gateway_mode=$(stat -c '%a' "${tmp}/home/.config/spark/gateway.json" 2>/dev/null || stat -f '%Lp' "${tmp}/home/.config/spark/gateway.json" 2>/dev/null || echo "")
  litellm_mode=$(stat -c '%a' "${tmp}/home/.config/spark/litellm_config.yaml" 2>/dev/null || stat -f '%Lp' "${tmp}/home/.config/spark/litellm_config.yaml" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"Workspace complete"* ]] &&
    [[ "$(sed -n '1p' <<< "$compose")" == "services:" ]] &&
    [[ "$(sed -n '2p' <<< "$compose")" == "  postgres:" ]] &&
    [[ "$(grep -c '^  \(postgres\|vikunja\|n8n\):$' <<< "$compose")" -eq 3 ]] &&
    [[ "$compose" == *"postgres.env"* ]] && [[ "$compose" == *"vikunja.env"* ]] &&
    [[ "$compose" == *"n8n.env"* ]] && [[ "$compose" != *"secrets.env"* ]] &&
    [[ "$compose" == *"image: postgres:18"* ]] &&
    [[ "$compose" == *"image: vikunja/vikunja:latest"* ]] &&
    [[ "$compose" == *"image: docker.n8n.io/n8nio/n8n:latest"* ]] &&
    [[ "$compose" == *"container_name: workspace-postgres"* ]] &&
    [[ "$compose" == *"container_name: workspace-vikunja"* ]] &&
    [[ "$compose" == *"container_name: workspace-n8n"* ]] &&
    [[ "$compose" != *"vikunja-db"* ]] && [[ "$compose" != *"n8n-db"* ]] &&
    [[ "$compose" != *"spark-vikunja"* ]] && [[ "$init" == *"CREATE DATABASE vikunja"* ]] &&
    [[ "$init" == *"CREATE DATABASE n8n"* ]] && [[ "$init" == *"WHERE NOT EXISTS"* ]] &&
    [[ "$init" == *"ALTER USER vikunja"* ]] && [[ "$init" == *"ALTER USER n8n"* ]] &&
    [[ "$(grep -c 'no-new-privileges:true' <<< "$compose")" -ge 3 ]] &&
    [[ "$(grep -c 'init: true' <<< "$compose")" -ge 3 ]] &&
    [[ "$(grep -c 'stop_grace_period: 30s' <<< "$compose")" -ge 3 ]] &&
    [[ "$(grep -c 'max-size: "10m"' <<< "$compose")" -ge 3 ]] &&
    [[ "$(grep -c 'max-file: "5"' <<< "$compose")" -ge 3 ]] &&
    [[ "$tailscale_calls" == *"serve --bg --service=svc:tasks --https=443 --yes http://127.0.0.1:3456"* ]] &&
    [[ "$nemo_calls" == *"onboard --non-interactive --yes-i-accept-third-party-software --yes --no-gpu --control-ui-port 18789"* ]] &&
    [[ "$nemo_calls" == *"NEMOCLAW_AGENT=hermes"* ]] &&
    [[ "$nemo_calls" == *"NEMOCLAW_PREFERRED_API=openai-completions"* ]] &&
    [[ "$nemo_calls" == *"NEMOCLAW_LOCAL_INFERENCE_TIMEOUT=300"* ]] &&
    [[ "$nemo_calls" == *"NEMOCLAW_SANDBOX_READY_TIMEOUT=600"* ]] &&
    [[ "$nemo_calls" == *"NEMOCLAW_NO_GPU=1"* ]] &&
    [[ "$nemo_calls" == *"NEMOCLAW_SANDBOX_GPU=0"* ]] &&
    [[ "$nemo_calls" == *"NEMOCLAW_ENDPOINT_URL=http://host.openshell.internal:4000/v1"* ]] &&
    [[ "$nemo_calls" == *"CHAT_UI_URL=https://hermes.test-tailnet.ts.net"* ]] &&
    [[ "$nemo_calls" == *"hermes skill install "*"/hermes-skills/vikunja"* ]] &&
    [[ "$nemo_calls" == *"hermes config set model.max_tokens 512"* ]] &&
    [[ "$nemo_calls" == *"hermes config set model.context_length 65536"* ]] &&
    [[ "$nemo_calls" == *"hermes config set agent.reasoning_effort none"* ]] &&
    [[ "$nemo_calls" == *"hermes gateway restart --quiet"* ]] &&
    [[ "$docker_calls" == *"--name spark-hermes-litellm-proxy"* ]] &&
    [[ "$docker_calls" == *"172.19.0.1 4000 127.0.0.1 4000"* ]] &&
    [[ "$docker_calls" == *"--name spark-hermes-vikunja-proxy"* ]] &&
    [[ "$docker_calls" == *"172.19.0.1 3456 127.0.0.1 3456"* ]] &&
    [[ "$openshell_calls" == *"settings set --global --key providers_v2_enabled --value true --yes"* ]] &&
    [[ "$openshell_calls" == *"provider create --name spark-vikunja --type generic --credential VIKUNJA_API_TOKEN"* ]] &&
    [[ "$openshell_calls" == *"sandbox provider attach hermes spark-vikunja"* ]] &&
    [[ "$openshell_calls" == *"policy update hermes --add-endpoint host.openshell.internal:3456:read-write:rest:enforce --binary /usr/bin/curl --rule-name spark-vikunja-api --wait"* ]] &&
    [[ "$openshell_calls" != *"vk_auto_hermes"* ]] &&
    [[ "$skill" == *"env_vars: [VIKUNJA_API_TOKEN]"* ]] &&
    [[ "$skill" == *"Use Vikunja's REST API directly"* ]] &&
    [[ "$skill" == *"Do not use Electron or an MCP server"* ]] &&
    [[ "$skill" == *"curl -fsS --max-time 10"* ]] &&
    [[ "$curl_calls" == *'"expires_at":"2099-12-31T23:59:59Z"'* ]] &&
    [[ "$curl_calls" == *'"owner_id":3'* ]] &&
    [[ "$curl_calls" == *'/api/v2/tokens'* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=services"* ]] &&
    [[ "$env" == *"VIKUNJA_URL=https://tasks.test-tailnet.ts.net"* ]] &&
    [[ "$env" == *"HERMES_DASHBOARD_PORT=18789"* ]] &&
    [[ "$env" == *"HERMES_LITELLM_MODEL=vllm/Org/Alpha"* ]] &&
    [[ "$env" == *"HERMES_CONTEXT_LENGTH=65536"* ]] &&
    [[ "$env" == *"HERMES_MAX_TOKENS=512"* ]] &&
    [[ "$env" == *"HERMES_REASONING_EFFORT=none"* ]] &&
    [[ "$env" == *"HERMES_POLICY_TIER=restricted"* ]] &&
    [[ "$env" == *"HERMES_ONBOARD_STATUS=configured"* ]] &&
    [[ "$env" == *"N8N_PROTOCOL=https"* ]] &&
    [[ "$env" == *"N8N_SECURE_COOKIE=true"* ]] &&
    [[ "$n8n_env" == *"N8N_PROTOCOL=https"* ]] &&
    [[ "$n8n_env" == *"N8N_SECURE_COOKIE=true"* ]] &&
    [[ "$env" == *"WORKSPACE_POSTGRES_IMAGE=postgres:18"* ]] &&
    [[ "$env" == *"WORKSPACE_VIKUNJA_IMAGE=vikunja/vikunja:latest"* ]] &&
    [[ "$env" == *"WORKSPACE_N8N_IMAGE=docker.n8n.io/n8nio/n8n:latest"* ]] &&
    [[ "$env" == *"VIKUNJA_HUMAN_USER_STATUS=exists"* ]] &&
    [[ "$env" == *"VIKUNJA_HUMAN_USER_ID=1"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_BOT_USERNAME=bot-hermes"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_BOT_ID=3"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_BOT_STATUS=exists"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_PROJECT_ACCESS_STATUS=verified"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_API_TOKEN=vk_auto_hermes"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_API_STATUS=verified"* ]] &&
    [[ "$env" != *"VIKUNJA_HERMES_PASSWORD="* ]] &&
    [[ "$env" != *"VIKUNJA_HUMAN_PASSWORD=secret123"* ]] &&
    [[ "$postgres_env" == *"VIKUNJA_DATABASE_PASSWORD="* ]] &&
    [[ "$postgres_env" == *"DB_POSTGRESDB_PASSWORD="* ]] &&
    [[ "$postgres_env" != *"N8N_BASIC_AUTH_PASSWORD"* ]] &&
    [[ "$vikunja_env" == *"VIKUNJA_SERVICE_ENABLELINKSHARING=false"* ]] &&
    [[ "$vikunja_env" != *"N8N_BASIC_AUTH_PASSWORD"* ]] &&
    [[ "$n8n_env" == *"NODES_EXCLUDE="*"n8n-nodes-base.executeCommand"* ]] &&
    [[ "$n8n_env" == *"N8N_GIT_NODE_ENABLE_HOOKS=false"* ]] &&
    [[ "$n8n_env" == *"N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true"* ]] &&
    [[ "$n8n_env" == *"N8N_COMMUNITY_PACKAGES_ENABLED=false"* ]] &&
    [[ "$n8n_env" == *"N8N_UNVERIFIED_PACKAGES_ENABLED=false"* ]] &&
    [[ "$n8n_env" == *"N8N_VERIFIED_PACKAGES_ENABLED=false"* ]] &&
    [[ "$n8n_env" == *"N8N_COMMUNITY_PACKAGES_MANAGED_BY_ENV=true"* ]] &&
    [[ "$n8n_env" == *"N8N_COMMUNITY_PACKAGES=[]"* ]] &&
    [[ "$n8n_env" != *"VIKUNJA_HUMAN_PASSWORD"* ]] &&
    [[ "$n8n_env" != *"VIKUNJA_DATABASE_PASSWORD"* ]] &&
    [[ "$workspace_mode" == "700" ]] &&
    [[ "$compose_mode" == "644" ]] &&
    [[ "$gateway_mode" == "600" ]] &&
    [[ "$litellm_mode" == "600" ]]
}

test_workspace_setup_healthy_fast_path_no_mutation() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env_file compose_file env_before compose_before env_after compose_after compose_calls nemo_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  compose_file="${tmp}/home/.config/spark/workspace/docker-compose.yml"
  env_before=$(cksum "$env_file")
  compose_before=$(cksum "$compose_file")
  : > "${tmp}/compose.log"
  : > "${tmp}/nemohermes.log"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_COMPOSE_FILE="${tmp}/compose.log" FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes 2>&1)
  status=$?
  set -e
  env_after=$(cksum "$env_file")
  compose_after=$(cksum "$compose_file")
  compose_calls=$(cat "${tmp}/compose.log" 2>/dev/null || echo "")
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] &&
    [[ "$out" == *"Workspace already configured"* ]] &&
    [[ "$env_before" == "$env_after" ]] &&
    [[ "$compose_before" == "$compose_after" ]] &&
    [[ "$compose_calls" != *" up -d"* ]] &&
    [[ "$nemo_calls" != *"onboard"* ]]
}

test_workspace_setup_repairs_compose_drift_without_hermes_onboard() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status compose_file tmp_compose compose compose_calls nemo_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_TAILSCALE_MODE=services \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  compose_file="${tmp}/home/.config/spark/workspace/docker-compose.yml"
  tmp_compose="${compose_file}.tmp"
  grep -v 'init: true' "$compose_file" > "$tmp_compose"
  mv "$tmp_compose" "$compose_file"
  : > "${tmp}/compose.log"
  : > "${tmp}/nemohermes.log"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_COMPOSE_FILE="${tmp}/compose.log" FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes 2>&1)
  status=$?
  set -e
  compose=$(cat "$compose_file" 2>/dev/null || echo "")
  compose_calls=$(cat "${tmp}/compose.log" 2>/dev/null || echo "")
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] &&
    [[ "$out" == *"Workspace drift detected; reconciling"* ]] &&
    [[ "$(grep -c 'init: true' <<< "$compose")" -ge 3 ]] &&
    [[ "$compose_calls" == *" up -d --remove-orphans"* ]] &&
    [[ "$nemo_calls" != *"onboard"* ]]
}

test_workspace_setup_backs_up_and_normalizes_invalid_env() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env_file backups env_text
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  printf '%s\n' 'POSTGRES_PASSWORD=duplicate' 'BROKEN LINE' >> "$env_file"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_BACKUP_SUFFIX=testbackup \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes 2>&1)
  status=$?
  set -e
  backups=$(find "${tmp}/home/.config/spark/workspace" -name 'secrets.env.bak.testbackup' -print 2>/dev/null || true)
  env_text=$(cat "$env_file" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] &&
    [[ "$out" == *"Backed up invalid env file"* ]] &&
    [[ -n "$backups" ]] &&
    [[ "$env_text" != *"BROKEN LINE"* ]] &&
    [[ "$(grep -c '^POSTGRES_PASSWORD=' <<< "$env_text")" -eq 1 ]]
}

test_workspace_setup_refuses_missing_secret_with_data() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env_file tmp_env
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  tmp_env="${env_file}.tmp"
  grep -v '^POSTGRES_PASSWORD=' "$env_file" > "$tmp_env"
  mv "$tmp_env" "$env_file"
  chmod 600 "$env_file"
  mkdir -p "${tmp}/home/.local/share/spark/workspace/postgres"
  printf '%s\n' data > "${tmp}/home/.local/share/spark/workspace/postgres/PG_VERSION"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Missing Postgres password (POSTGRES_PASSWORD) while existing workspace data is present"* ]]
}

test_workspace_setup_fails_when_hermes_onboard_fails() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_NEMOHERMES_EXIT=1 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1)
  status=$?
  set -e
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Hermes onboarding failed"* ]] &&
    [[ "$out" == *"Workspace incomplete"* ]] &&
    [[ "$env" == *"HERMES_ONBOARD_STATUS=manual"* ]]
}

test_workspace_setup_updates_stale_nemohermes() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin nemo_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_NEMOHERMES_UPDATE_CHECK=$'Current NemoHermes version: 0.0.55\nLatest maintained version: 0.0.78\nUpdate available:         yes' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$nemo_calls" == *"update --check"* ]] &&
    [[ "$nemo_calls" == *"update --yes"* ]] &&
    [[ "$nemo_calls" == *'NEMOCLAW_CONFIRM_LEGACY_MANAGED_RECREATE=["hermes"]'* ]] &&
    [[ "$nemo_calls" == *"onboard --non-interactive"* ]]
}

test_workspace_setup_stops_when_nemohermes_update_fails() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status nemo_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_NEMOHERMES_UPDATE_CHECK=$'Current NemoHermes version: 0.0.55\nLatest maintained version: 0.0.78\nUpdate available:         yes' \
    FAKE_NEMOHERMES_UPDATE_EXIT=9 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1)
  status=$?
  set -e
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"NemoHermes update failed"* ]] &&
    [[ "$nemo_calls" == *"update --yes"* ]] &&
    [[ "$nemo_calls" != *"onboard --non-interactive"* ]]
}

test_workspace_setup_keeps_hermes_dashboard_on_loopback() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin docker_calls nemo_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${fake_bin}/sleep"
  chmod +x "${fake_bin}/sleep"
  make_cached_model "${tmp}/home" "Org/Alpha"
  mkdir -p "${tmp}/home/.config/spark/workspace"
  printf 'HERMES_URL=http://127.0.0.1:18789\n' > "${tmp}/home/.config/spark/workspace/secrets.env"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" FAKE_DOCKER_EXEC_FILE="${tmp}/docker-exec.log" \
    FAKE_NAMES=$'openshell-hermes-test\n' FAKE_HERMES_DASHBOARD_EXIT=7 FAKE_TAILSCALE_HERMES_EXIT=7 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  docker_calls=$(cat "${tmp}/docker-exec.log" 2>/dev/null || echo "")
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$nemo_calls" == *"NEMOCLAW_HERMES_DASHBOARD_HOST=127.0.0.1"* ]] &&
    [[ "$docker_calls" != *"python3 -c"* ]] &&
    [[ "$docker_calls" != *"exec -d -e CHAT_UI_URL=http://127.0.0.1:18789"* ]]
}

test_workspace_tailnet_from_self_dnsname() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON='{"Self":{"DNSName":"sparkbox.test-tailnet.ts.net."}}' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$env" == *"VIKUNJA_URL=https://tasks.test-tailnet.ts.net"* ]] &&
    [[ "$env" == *"N8N_URL=https://n8n.test-tailnet.ts.net"* ]] &&
    [[ "$env" == *"HERMES_URL=https://hermes.test-tailnet.ts.net"* ]]
}

test_workspace_setup_requires_tailnet_urls() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env compose
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON='{"Self":{"TailscaleIPs":["100.64.0.10"]}}' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1)
  status=$?
  set -e
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  compose=$(cat "${tmp}/home/.config/spark/workspace/docker-compose.yml" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Tailscale tailnet DNS suffix not detected"* ]] &&
    [[ "$out" == *"Workspace incomplete"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=manual"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_BIND_ADDR=127.0.0.1"* ]] &&
    [[ "$compose" == *"127.0.0.1:3456:3456"* ]] &&
    [[ "$compose" == *"127.0.0.1:5678:5678"* ]] &&
    [[ "$compose" != *'":3456:3456"'* ]] &&
    [[ "$compose" != *'"0.0.0.0:3456:3456"'* ]] &&
    grep -qx 'VIKUNJA_URL=' <<< "$env" &&
    grep -qx 'N8N_URL=' <<< "$env" &&
    grep -qx 'HERMES_URL=' <<< "$env"
}

test_workspace_ports_requires_magicdns_urls() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env compose
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON='{"Self":{"TailscaleIPs":["100.64.0.10"]}}' \
    FAKE_TAILSCALE_IP=100.64.0.10 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha --tailscale-mode ports 2>&1)
  status=$?
  set -e
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  compose=$(cat "${tmp}/home/.config/spark/workspace/docker-compose.yml" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Tailscale MagicDNS/IPv4 not detected for ports fallback"* ]] &&
    [[ "$out" == *"Workspace incomplete"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=manual"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_BIND_ADDR=127.0.0.1"* ]] &&
    [[ "$compose" == *"127.0.0.1:3456:3456"* ]] &&
    [[ "$compose" == *"127.0.0.1:5678:5678"* ]] &&
    [[ "$compose" != *"100.64.0.10:3456:3456"* ]] &&
    grep -qx 'VIKUNJA_URL=' <<< "$env" &&
    grep -qx 'N8N_URL=' <<< "$env" &&
    grep -qx 'HERMES_URL=' <<< "$env"
}

test_workspace_tailscale_ports_fallback() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env compose tailscale_calls nemo_calls out doctor
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_TAILSCALE_VERSION=1.84.0 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10","fd7a:115c:a1e0::10"]}}' \
    FAKE_TAILSCALE_IP=100.64.0.10 FAKE_TAILSCALE_FILE="${tmp}/tailscale.log" \
    FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha --tailscale-mode ports \
      --postgres-image postgres:18.1 --vikunja-image vikunja/vikunja:1.2.3 \
      --n8n-image docker.n8n.io/n8nio/n8n:1.100.0 2>&1 || true)
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  compose=$(cat "${tmp}/home/.config/spark/workspace/docker-compose.yml" 2>/dev/null || echo "")
  tailscale_calls=$(cat "${tmp}/tailscale.log" 2>/dev/null || echo "")
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  doctor=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_TAILSCALE_VERSION=1.84.0 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10","fd7a:115c:a1e0::10"]}}' \
    FAKE_TAILSCALE_IP=100.64.0.10 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --verbose --model Org/Alpha 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"Tailscale MagicDNS port fallback configured"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=ports"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_BIND_ADDR=100.64.0.10"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_DNS_NAME=sparkbox.test-tailnet.ts.net"* ]] &&
    [[ "$env" == *"VIKUNJA_URL=http://sparkbox.test-tailnet.ts.net:3456"* ]] &&
    [[ "$env" == *"N8N_URL=http://sparkbox.test-tailnet.ts.net:5678"* ]] &&
    [[ "$env" == *"HERMES_URL=http://sparkbox.test-tailnet.ts.net:18789"* ]] &&
    [[ "$nemo_calls" == *"CHAT_UI_URL=http://sparkbox.test-tailnet.ts.net:18789"* ]] &&
    [[ "$nemo_calls" != *"CHAT_UI_URL=https://hermes.test-tailnet.ts.net"* ]] &&
    [[ "$env" == *"N8N_PROTOCOL=http"* ]] &&
    [[ "$env" == *"N8N_SECURE_COOKIE=false"* ]] &&
    [[ "$env" == *"WORKSPACE_POSTGRES_IMAGE=postgres:18.1"* ]] &&
    [[ "$env" == *"WORKSPACE_VIKUNJA_IMAGE=vikunja/vikunja:1.2.3"* ]] &&
    [[ "$env" == *"WORKSPACE_N8N_IMAGE=docker.n8n.io/n8nio/n8n:1.100.0"* ]] &&
    [[ "$compose" == *"image: postgres:18.1"* ]] &&
    [[ "$compose" == *"image: vikunja/vikunja:1.2.3"* ]] &&
    [[ "$compose" == *"image: docker.n8n.io/n8nio/n8n:1.100.0"* ]] &&
    [[ "$compose" == *"100.64.0.10:3456:3456"* ]] &&
    [[ "$compose" == *"100.64.0.10:5678:5678"* ]] &&
    [[ "$tailscale_calls" != *"serve --service=svc:"* ]] &&
    [[ "$doctor" == *"[x] Compose uses private host bindings only"* ]] &&
    [[ "$doctor" == *"[x] Tailscale supports selected private access mode"* ]] &&
    [[ "$doctor" == *"[x] Tailscale mode is Services or ports"* ]] &&
    [[ "$doctor" == *"[x] Tailscale workspace URLs respond"* ]]
}

test_workspace_setup_updates_old_tailscale_for_services() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out env tailscale_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_VERSION=1.84.0 FAKE_TAILSCALE_VERSION_AFTER_UPDATE=1.96.5 \
    FAKE_TAILSCALE_UPDATE_MARKER="${tmp}/tailscale.updated" FAKE_TAILSCALE_FILE="${tmp}/tailscale.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1 || true)
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  tailscale_calls=$(cat "${tmp}/tailscale.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"Tailscale is older than 1.86; attempting update"* ]] &&
    [[ "$out" == *"Tailscale updated"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=services"* ]] &&
    [[ "$tailscale_calls" == *"update"* ]] &&
    [[ "$tailscale_calls" == *"serve --bg --service=svc:tasks"* ]]
}

test_workspace_setup_defaults_to_services_from_ports_workspace() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out env tailscale_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10","fd7a:115c:a1e0::10"]}}' \
    FAKE_TAILSCALE_IP=100.64.0.10 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha --tailscale-mode ports >/dev/null 2>&1 || true
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10","fd7a:115c:a1e0::10"]}}' \
    FAKE_TAILSCALE_IP=100.64.0.10 FAKE_TAILSCALE_FILE="${tmp}/tailscale.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1 || true)
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  tailscale_calls=$(cat "${tmp}/tailscale.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"Tailscale Services configured"* || "$out" == *"Workspace drift detected; reconciling"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=services"* ]] &&
    [[ "$env" == *"VIKUNJA_URL=https://tasks.test-tailnet.ts.net"* ]] &&
    [[ "$env" == *"N8N_URL=https://n8n.test-tailnet.ts.net"* ]] &&
    [[ "$env" == *"HERMES_URL=https://hermes.test-tailnet.ts.net"* ]] &&
    [[ "$tailscale_calls" == *"serve --bg --service=svc:tasks --https=443 --yes http://127.0.0.1:3456"* ]] &&
    [[ "$tailscale_calls" == *"serve --bg --service=svc:n8n --https=443 --yes http://127.0.0.1:5678"* ]] &&
    [[ "$tailscale_calls" == *"serve --bg --service=svc:hermes --https=443 --yes http://127.0.0.1:18790"* ]]
}

test_workspace_setup_reports_missing_tailscale_services_hitl() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env tailscale_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10"],"CapMap":{"services/tasks":[{"Name":"svc:tasks","Ports":["tcp:443"]}],"services/n8n":[{"Name":"svc:n8n","Ports":["tcp:443"]}]}}}' \
    FAKE_TAILSCALE_FILE="${tmp}/tailscale.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1)
  status=$?
  set -e
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  tailscale_calls=$(cat "${tmp}/tailscale.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Tailscale Services must be created/approved in the Tailscale admin console"* ]] &&
    [[ "$out" == *"Open: https://login.tailscale.com/admin/services"* ]] &&
    [[ "$out" == *"hermes (tcp:443)"* ]] &&
    [[ "$out" == *"Approve/authorize host: sparkbox.test-tailnet.ts.net"* ]] &&
    [[ "$out" == *"Tailscale Services not registered/authorized: hermes:443"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=manual"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_LAST_ERROR=missing-service"* ]] &&
    [[ "$tailscale_calls" != *"serve --bg --service=svc:"* ]]
}

test_workspace_setup_yes_does_not_fallback_when_services_disabled() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env nemo_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10","fd7a:115c:a1e0::10"]}}' \
    FAKE_TAILSCALE_IP=100.64.0.10 FAKE_TAILSCALE_SERVE_EXIT=1 FAKE_TAILSCALE_SERVE_STDERR='Serve is not enabled on your tailnet.\nTo enable, visit:\n\n         https://login.tailscale.com/f/serve?node=test' FAKE_TAILSCALE_GET_CONFIG_EXIT=1 FAKE_TAILSCALE_SERVE_CONFIG='not-configured' FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1)
  status=$?
  set -e
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Tailscale Serve is not enabled for this tailnet"* ]] &&
    [[ "$out" == *"https://login.tailscale.com/f/serve?node=test"* ]] &&
    [[ "$out" == *"Workspace incomplete"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=manual"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_LAST_ERROR=serve-disabled"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_ENABLE_URL=https://login.tailscale.com/f/serve?node=test"* ]] &&
    [[ "$nemo_calls" != *"onboard"* ]]
}

test_workspace_setup_reports_tailscale_service_pending_approval() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env nemo_calls serve_config
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  serve_config='{"version":"0.0.1","services":{"svc:tasks":{"endpoints":{"tcp:443":"http://127.0.0.1:3456"}},"svc:n8n":{"endpoints":{"tcp:443":"http://127.0.0.1:5678"}},"svc:hermes":{"endpoints":{"tcp:443":"http://127.0.0.1:18790"}}}}'
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10"],"Tags":["tag:spark"],"CapMap":{"services/tasks":[{"Name":"svc:tasks","Ports":["tcp:443"]}],"services/n8n":[{"Name":"svc:n8n","Ports":["tcp:443"]}],"services/hermes":[{"Name":"svc:hermes","Ports":["tcp:443"]}]}}}' \
    FAKE_TAILSCALE_SERVE_CONFIG="$serve_config" FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1)
  status=$?
  set -e
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Tailscale Services configured locally"* ]] &&
    [[ "$out" == *"Tailscale Service host pending admin approval"* ]] &&
    [[ "$out" == *"Open: https://login.tailscale.com/admin/services"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=services"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_LAST_ERROR=pending-approval"* ]] &&
    [[ "$nemo_calls" != *"onboard"* ]]
}

test_workspace_waits_for_delayed_tailscale_service_approval() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin status status_file updater initial_json approved_json
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark/workspace"
  printf 'WORKSPACE_TAILSCALE_MODE=services\n' > "${tmp}/home/.config/spark/workspace/secrets.env"
  status_file="${tmp}/tailscale-status.json"
  initial_json='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10"],"Tags":["tag:spark"],"CapMap":{"services/tasks":[{"Name":"svc:tasks","Ports":["tcp:443"]}],"services/n8n":[{"Name":"svc:n8n","Ports":["tcp:443"]}],"services/hermes":[{"Name":"svc:hermes","Ports":["tcp:443"]}]}}}'
  approved_json='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10"],"Tags":["tag:spark"],"CapMap":{"services/tasks":[{"Name":"svc:tasks","Ports":["tcp:443"]}],"services/n8n":[{"Name":"svc:n8n","Ports":["tcp:443"]}],"services/hermes":[{"Name":"svc:hermes","Ports":["tcp:443"]}],"service-host":[{"Name":"svc:tasks"},{"Name":"svc:n8n"},{"Name":"svc:hermes"}]}}}'
  printf '%s\n' "$initial_json" > "$status_file"
  ( sleep 0.2; printf '%s\n' "$approved_json" > "$status_file" ) &
  updater=$!
  set +e
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_TAILSCALE_APPROVAL_WAIT_ATTEMPTS=20 SPARK_WORKSPACE_TAILSCALE_APPROVAL_WAIT_DELAY=0.1 \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_TAILSCALE_STATUS_JSON_FILE="$status_file" \
    bash -c 'source "$1"; workspace_tailscale_wait_for_service_host_advertised' bash "$SPARK"
  status=$?
  set -e
  wait "$updater" 2>/dev/null || true
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]]
}

test_workspace_setup_reports_missing_tailscale_tag() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env nemo_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10"],"CapMap":{"services/tasks":[{"Name":"svc:tasks","Ports":["tcp:443"]}],"services/n8n":[{"Name":"svc:n8n","Ports":["tcp:443"]}],"services/hermes":[{"Name":"svc:hermes","Ports":["tcp:443"]}]}}}' \
    FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1)
  status=$?
  set -e
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Tailscale Services require this machine to use a tag identity"* ]] &&
    [[ "$out" == *"Create tag: tag:spark"* ]] &&
    [[ "$out" == *"Assign tag:spark to machine: sparkbox.test-tailnet.ts.net"* ]] &&
    [[ "$out" == *"Tailscale machine is not tagged for Services"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=manual"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_LAST_ERROR=missing-tag"* ]] &&
    [[ "$nemo_calls" != *"onboard"* ]]
}

test_workspace_setup_reports_missing_tailscale_operator() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env nemo_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_SERVE_EXIT=1 FAKE_TAILSCALE_SERVE_STDERR="Access denied: serve config denied\nUse 'sudo tailscale serve --bg --service=svc:tasks --https=443 --yes http://127.0.0.1:3456'.\nTo not require root, use 'sudo tailscale set --operator=\$USER' once." \
    FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1)
  status=$?
  set -e
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Tailscale Serve needs local operator permission"* ]] &&
    [[ "$out" == *"sudo tailscale set --operator=\$USER"* ]] &&
    [[ "$out" == *"Tailscale operator permission is not configured"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=manual"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_LAST_ERROR=operator-missing"* ]] &&
    [[ "$nemo_calls" != *"onboard"* ]]
}

test_workspace_setup_interactive_offers_ports_fallback_when_services_disabled() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env nemo_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(printf '\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_ASSUME_INTERACTIVE=1 \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10","fd7a:115c:a1e0::10"]}}' \
    FAKE_TAILSCALE_IP=100.64.0.10 FAKE_TAILSCALE_SERVE_EXIT=1 FAKE_TAILSCALE_SERVE_STDERR='Serve is not enabled on your tailnet.' FAKE_TAILSCALE_GET_CONFIG_EXIT=1 FAKE_TAILSCALE_SERVE_CONFIG='not-configured' FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_NAMES='spark-litellm\n' FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --model Org/Alpha 2>&1)
  status=$?
  set -e
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Use temporary Tailscale port URLs instead of Services for now?"* ]] &&
    [[ "$out" != *"using ports fallback"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=manual"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_LAST_ERROR=serve-disabled"* ]] &&
    [[ "$nemo_calls" != *"onboard"* ]]
}

test_workspace_setup_explicit_services_does_not_fall_back_to_ports() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env nemo_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10","fd7a:115c:a1e0::10"]}}' \
    FAKE_TAILSCALE_IP=100.64.0.10 FAKE_TAILSCALE_SERVE_EXIT=1 FAKE_TAILSCALE_SERVE_STDERR='Serve is not enabled on your tailnet.' FAKE_TAILSCALE_GET_CONFIG_EXIT=1 FAKE_TAILSCALE_SERVE_CONFIG='not-configured' FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha --tailscale-mode services 2>&1)
  status=$?
  set -e
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Tailscale Serve is not enabled for this tailnet"* ]] &&
    [[ "$out" == *"Hermes onboarding skipped until Tailscale private access is configured"* ]] &&
    [[ "$out" != *"using ports fallback"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=manual"* ]] &&
    [[ "$nemo_calls" != *"onboard"* ]]
}

test_workspace_setup_blocks_tailscale_funnel() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status tailscale_calls nemo_calls mutated=0
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_FUNNEL_EXIT=0 FAKE_TAILSCALE_FUNNEL_STATUS='https://public.example.com\n' \
    FAKE_TAILSCALE_FILE="${tmp}/tailscale.log" FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1)
  status=$?
  set -e
  tailscale_calls=$(cat "${tmp}/tailscale.log" 2>/dev/null || echo "")
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  [[ -e "${tmp}/home/.config/spark/workspace/secrets.env" || -e "${tmp}/home/.config/spark/workspace/docker-compose.yml" ]] && mutated=1
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Tailscale Funnel is active; rerun with --funnel-action reset"* ]] &&
    [[ "$tailscale_calls" != *"funnel reset"* ]] &&
    [[ "$tailscale_calls" != *"serve --bg --service=svc:"* ]] &&
    [[ "$nemo_calls" != *"onboard"* ]] &&
    [[ "$mutated" -eq 0 ]]
}

test_workspace_setup_resets_tailscale_funnel_with_flag() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status tailscale_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_FUNNEL_EXIT=0 FAKE_TAILSCALE_FUNNEL_STATUS='https://public.example.com\n' \
    FAKE_TAILSCALE_FUNNEL_RESET_MARKER="${tmp}/funnel.reset" \
    FAKE_TAILSCALE_FILE="${tmp}/tailscale.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha --funnel-action reset 2>&1)
  status=$?
  set -e
  tailscale_calls=$(cat "${tmp}/tailscale.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] &&
    [[ "$out" == *"Tailscale Funnel reset"* ]] &&
    [[ "$tailscale_calls" == *"funnel reset"* ]] &&
    [[ "$tailscale_calls" == *"serve --bg --service=svc:"* ]]
}

test_workspace_setup_check_reports_funnel_without_reset() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status tailscale_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_TAILSCALE_FUNNEL_EXIT=0 \
    FAKE_TAILSCALE_FUNNEL_STATUS='https://public.example.com\n' \
    FAKE_TAILSCALE_FILE="${tmp}/tailscale.log" FAKE_NAMES='spark-litellm\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --check --model Org/Alpha 2>&1)
  status=$?
  set -e
  tailscale_calls=$(cat "${tmp}/tailscale.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Tailscale Funnel is active; public internet exposure must be removed"* ]] &&
    [[ "$tailscale_calls" != *"funnel reset"* ]]
}

test_workspace_setup_repairs_shared_postgres_runtime() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_COMPOSE_EXEC_FILE="${tmp}/compose-exec.log" \
    FAKE_PG_ROLE_VIKUNJA=0 FAKE_PG_ROLE_N8N=0 FAKE_PG_DB_VIKUNJA=0 FAKE_PG_DB_N8N=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  calls=$(cat "${tmp}/compose-exec.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$calls" == *"CREATE USER vikunja"* ]] &&
    [[ "$calls" == *"CREATE DATABASE vikunja"* ]] &&
    [[ "$calls" == *"CREATE USER n8n"* ]] &&
    [[ "$calls" == *"CREATE DATABASE n8n"* ]]
}

test_workspace_setup_fails_when_vikunja_token_creation_fails() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out env status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_VIKUNJA_TOKEN_CREATE_EXIT=1 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1)
  status=$?
  set -e
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Could not configure Vikunja bot-hermes automatically"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_API_STATUS=manual"* ]] &&
    [[ "$env" != *"VIKUNJA_HERMES_API_TOKEN=vk_auto_hermes"* ]]
}

test_workspace_setup_waits_for_vikunja_cli() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env count
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_WAIT_SLEEP=0 SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo \
    SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com SPARK_WORKSPACE_N8N_PASSWORD=secret456 \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_VIKUNJA_USER_LIST_READY_AFTER=2 \
    FAKE_VIKUNJA_USER_LIST_COUNT_FILE="${tmp}/vikunja-count" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  count=$(cat "${tmp}/vikunja-count" 2>/dev/null || echo 0)
  rm -rf "$tmp"
  [[ "$count" -ge 2 ]] &&
    [[ "$env" == *"VIKUNJA_HUMAN_USER_STATUS=exists"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_BOT_STATUS=exists"* ]] &&
    [[ "$env" != *"VIKUNJA_HUMAN_PASSWORD=secret123"* ]]
}

test_workspace_setup_creates_hermes_bot() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin compose_calls curl_calls env
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_COMPOSE_EXEC_FILE="${tmp}/compose-exec.log" \
    FAKE_CURL_FILE="${tmp}/curl.log" FAKE_VIKUNJA_BOTS_JSON='{"items":[]}' \
    FAKE_VIKUNJA_USER_LIST='| 1 | massimo | m@example.com | active |\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  compose_calls=$(cat "${tmp}/compose-exec.log" 2>/dev/null || echo "")
  curl_calls=$(cat "${tmp}/curl.log" 2>/dev/null || echo "")
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$compose_calls" != *"user create -u hermes"* ]] &&
    [[ "$curl_calls" == *"-X POST http://127.0.0.1:3456/api/v2/user/bots"* ]] &&
    [[ "$curl_calls" == *'"username":"bot-hermes"'* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_BOT_STATUS=created"* ]] &&
    [[ "$env" != *"VIKUNJA_HERMES_PASSWORD="* ]]
}

test_workspace_setup_requires_hermes_vikunja_api_access() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 SPARK_WORKSPACE_HERMES_API_ATTEMPTS=1 \
    FAKE_HERMES_VIKUNJA_API_EXIT=1 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Could not give Hermes verified Vikunja API access"* ]]
}

test_workspace_setup_resolves_unicode_vikunja_user_id() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env user_list
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  user_list='┌────┬──────────┬─────────────────┬────────┐\n│ ID │ USERNAME │      EMAIL      │ STATUS │\n├────┼──────────┼─────────────────┼────────┤\n│ 7  │ massimo  │ m@example.com   │ Active │\n└────┴──────────┴─────────────────┴────────┘\n'
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_VIKUNJA_USER_LIST="$user_list" \
    FAKE_VIKUNJA_BOTS_JSON='{"items":[{"id":3,"username":"bot-hermes","name":"Hermes","bot_owner_id":7}]}' \
    FAKE_VIKUNJA_USER_JSON='{"id":3,"username":"bot-hermes","email":"","bot_owner_id":7}' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$env" == *"VIKUNJA_HUMAN_USER_ID=7"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_API_STATUS=verified"* ]]
}

test_workspace_setup_shares_projects_with_hermes_bot() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin curl_calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_CURL_FILE="${tmp}/curl.log" FAKE_VIKUNJA_PROJECT_USERS_JSON='{"items":[]}' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  curl_calls=$(cat "${tmp}/curl.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$curl_calls" == *"-X POST http://127.0.0.1:3456/api/v2/projects/10/users"* ]] &&
    [[ "$curl_calls" == *'"username":"bot-hermes","permission":1'* ]]
}

test_workspace_rejects_regular_user_token_for_hermes() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_VIKUNJA_CREATED_TOKEN=vk_regular \
    FAKE_VIKUNJA_USER_JSON='{"id":2,"username":"hermes","email":"hermes@spark.invalid","bot_owner_id":0}' \
    FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$env" == *"VIKUNJA_HERMES_API_STATUS=wrong-user"* ]] &&
    [[ "$env" != *"VIKUNJA_HERMES_PROJECT_ACCESS_STATUS=verified"* ]]
}

test_workspace_rejects_bot_owned_by_another_user() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_VIKUNJA_CREATED_TOKEN=vk_foreign_bot \
    FAKE_VIKUNJA_USER_JSON='{"id":3,"username":"bot-hermes","email":"","bot_owner_id":9}' \
    FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$env" == *"VIKUNJA_HUMAN_USER_ID=1"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_API_STATUS=wrong-user"* ]]
}

test_workspace_setup_never_persists_human_password_on_vikunja_failure() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_VIKUNJA_USER_LIST='| 9 | someone | s@example.com | active |\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1 || true)
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"Vikunja user not verified: massimo"* ]] &&
    [[ "$env" != *"VIKUNJA_HUMAN_PASSWORD="* ]] &&
    [[ "$env" != *"VIKUNJA_HUMAN_RECOVERY_PASSWORD="* ]] &&
    [[ "$env" == *"VIKUNJA_HUMAN_USER_STATUS=manual"* ]]
}

test_workspace_setup_preserves_existing_secrets() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env_file pg_before vdb_before n8n_before token_before token_after pg_after vdb_after n8n_after
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_VIKUNJA_CREATED_TOKEN=vk_keep \
    SPARK_WORKSPACE_VIKUNJA_IMAGE=vikunja/vikunja:1.0.0 \
    SPARK_WORKSPACE_N8N_IMAGE=docker.n8n.io/n8nio/n8n:1.100.0 \
    FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  pg_before=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$env_file")
  vdb_before=$(sed -n 's/^VIKUNJA_DATABASE_PASSWORD=//p' "$env_file")
  n8n_before=$(sed -n 's/^DB_POSTGRESDB_PASSWORD=//p' "$env_file")
  token_before=$(sed -n 's/^VIKUNJA_HERMES_API_TOKEN=//p' "$env_file")
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=changed123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=changed456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  pg_after=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$env_file")
  vdb_after=$(sed -n 's/^VIKUNJA_DATABASE_PASSWORD=//p' "$env_file")
  n8n_after=$(sed -n 's/^DB_POSTGRESDB_PASSWORD=//p' "$env_file")
  token_after=$(sed -n 's/^VIKUNJA_HERMES_API_TOKEN=//p' "$env_file")
  rm -rf "$tmp"
  [[ -n "$pg_before" ]] && [[ "$pg_before" == "$pg_after" ]] &&
    [[ "$vdb_before" == "$vdb_after" ]] &&
    [[ "$n8n_before" == "$n8n_after" ]] &&
    [[ "$token_before" == "vk_keep" ]] && [[ "$token_before" == "$token_after" ]]
}

test_workspace_setup_missing_required_values_do_not_pollute_env() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env_file env=""
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha </dev/null 2>&1)
  status=$?
  set -e
  [[ -f "$env_file" ]] && env=$(cat "$env_file")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Workspace username is required"* ]] &&
    [[ "$env" != *"✗"* ]] &&
    [[ "$env" != *"is required"* ]]
}

test_workspace_setup_generates_prints_and_forgets_passwords() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out env vikunja_env n8n_env passwords first second
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    FAKE_VIKUNJA_USER_LIST='| 2 | hermes | hermes@spark.invalid | active |\n' \
    FAKE_VIKUNJA_CREATED_USER_FILE="${tmp}/vikunja.user" \
    FAKE_VIKUNJA_BOTS_JSON='{"items":[{"id":3,"username":"bot-hermes","bot_owner_id":9}]}' \
    FAKE_VIKUNJA_USER_JSON='{"id":3,"username":"bot-hermes","email":"","bot_owner_id":9}' \
    FAKE_N8N_LOGIN_EXIT=7 FAKE_N8N_LOGIN_AFTER_OWNER=1 FAKE_N8N_OWNER_MARKER="${tmp}/n8n.owner" \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --no-smtp --model Org/Alpha 2>&1 || true)
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env")
  vikunja_env=$(cat "${tmp}/home/.config/spark/workspace/vikunja.env")
  n8n_env=$(cat "${tmp}/home/.config/spark/workspace/n8n.env")
  passwords=$(sed -n 's/^    password: //p' <<< "$out")
  first=$(sed -n '1p' <<< "$passwords"); second=$(sed -n '2p' <<< "$passwords")
  rm -rf "$tmp"
  [[ "$out" == *"Save these passwords now"* ]] &&
    [[ -n "$first" && -n "$second" && "$first" != "$second" ]] &&
    [[ "$env$vikunja_env$n8n_env" != *"$first"* ]] &&
    [[ "$env$vikunja_env$n8n_env" != *"$second"* ]] &&
    [[ "$env$vikunja_env$n8n_env" != *"VIKUNJA_HUMAN_RECOVERY_PASSWORD="* ]] &&
    [[ "$env$vikunja_env$n8n_env" != *"N8N_BASIC_AUTH_PASSWORD="* ]]
}

test_workspace_setup_accepts_password_flags_and_files() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out env
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  printf '%s\n' 'N8nFilePassword456' > "${tmp}/n8n.pass"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    FAKE_VIKUNJA_USER_LIST='| 2 | hermes | hermes@spark.invalid | active |\n' \
    FAKE_VIKUNJA_CREATED_USER_FILE="${tmp}/vikunja.user" \
    FAKE_VIKUNJA_BOTS_JSON='{"items":[{"id":3,"username":"bot-hermes","bot_owner_id":9}]}' \
    FAKE_VIKUNJA_USER_JSON='{"id":3,"username":"bot-hermes","email":"","bot_owner_id":9}' \
    FAKE_N8N_LOGIN_EXIT=7 FAKE_N8N_LOGIN_AFTER_OWNER=1 FAKE_N8N_OWNER_MARKER="${tmp}/n8n.owner" \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --no-smtp --model Org/Alpha \
      --vikunja-password VikunjaFlagPassword123 --n8n-password-file "${tmp}/n8n.pass" 2>&1 || true)
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env")
  rm -rf "$tmp"
  [[ "$out" == *"password: VikunjaFlagPassword123"* ]] &&
    [[ "$out" == *"password: N8nFilePassword456"* ]] &&
    [[ "$out" == *"prefer --vikunja-password-file"* ]] &&
    [[ "$env" != *"VikunjaFlagPassword123"* ]] && [[ "$env" != *"N8nFilePassword456"* ]]
}

test_workspace_setup_prompts_for_existing_vikunja_password() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env_file staged out env
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=InitialPassword123 \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com SPARK_WORKSPACE_N8N_PASSWORD=secret456 \
    FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  staged="${env_file}.staged"
  grep -v '^VIKUNJA_HERMES_BOT_STATUS=' "$env_file" > "$staged"
  printf '%s\n' 'VIKUNJA_HERMES_BOT_STATUS=manual' >> "$staged"
  mv "$staged" "$env_file"
  out=$(printf '%s\n' 'CurrentPassword123' | \
    HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_ASSUME_INTERACTIVE=1 FAKE_DOCKER_READ_STDIN=0 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1 || true)
  env=$(cat "$env_file")
  rm -rf "$tmp"
  [[ "$out" == *"Current Vikunja password for massimo"* ]] &&
    [[ "$out" != *"CurrentPassword123"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_BOT_STATUS=exists"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_PROJECT_ACCESS_STATUS=verified"* ]] &&
    [[ "$env" != *"CurrentPassword123"* ]]
}

test_workspace_credentials_command_removed() {
  local out status
  set +e
  out=$("$SPARK" ws credentials 2>&1)
  status=$?
  set -e
  [[ "$status" -ne 0 ]] && [[ "$out" == *"Unknown ws command: credentials"* ]] &&
    [[ "$("$SPARK" ws help 2>&1)" != *"credentials"* ]]
}

test_workspace_setup_rejects_removed_smtp() {
  local out status help
  set +e
  out=$("$SPARK" ws setup --task-manager vikunja --smtp 2>&1)
  status=$?
  set -e
  help=$("$SPARK" ws setup --task-manager vikunja --help 2>&1)
  [[ "$status" -ne 0 ]] && [[ "$out" == *"SMTP support was removed"* ]] &&
    [[ "$out" == *"spark ws recover vikunja|n8n"* ]] && [[ "$help" != *"--smtp"* ]]
}

test_workspace_setup_removes_legacy_smtp() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out config env vikunja_env n8n_env backup
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  config="${tmp}/home/.config/spark/workspace"
  printf '%s\n' 'WORKSPACE_SMTP_PASSWORD=legacy-secret' >> "${config}/secrets.env"
  printf '%s\n' 'VIKUNJA_MAILER_PASSWORD=legacy-secret' >> "${config}/vikunja.env"
  printf '%s\n' 'N8N_SMTP_PASS=legacy-secret' >> "${config}/n8n.env"
  cp "${config}/n8n.env" "${config}/n8n.env.bak.legacy"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1 || true)
  env=$(cat "${config}/secrets.env")
  vikunja_env=$(cat "${config}/vikunja.env")
  n8n_env=$(cat "${config}/n8n.env")
  backup=$(cat "${config}/n8n.env.bak.legacy")
  rm -rf "$tmp"
  [[ "$out" == *"Removed legacy SMTP configuration and credentials"* ]] &&
    [[ "$env$vikunja_env$n8n_env$backup" != *"legacy-secret"* ]]
}

test_workspace_recover_vikunja() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out pager password config calls stored user_list
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  cat > "${fake_bin}/less" <<'EOF'
#!/usr/bin/env bash
cat > "${FAKE_LESS_OUTPUT_FILE}"
EOF
  chmod +x "${fake_bin}/less"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  user_list='┌────┬──────────┬─────────────────┬────────┐\n│ ID │ USERNAME │      EMAIL      │ STATUS │\n├────┼──────────┼─────────────────┼────────┤\n│ 1  │ massimo  │ m@example.com   │ Active │\n└────┴──────────┴─────────────────┴────────┘\n'
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_FORCE_PAGER=1 FAKE_LESS_OUTPUT_FILE="${tmp}/pager" \
    FAKE_VIKUNJA_USER_LIST="$user_list" FAKE_COMPOSE_EXEC_FILE="${tmp}/calls" \
    "$SPARK" ws recover vikunja --yes 2>&1)
  pager=$(cat "${tmp}/pager")
  password=$(sed -n 's/^    password: //p' <<< "$pager")
  config="${tmp}/home/.config/spark/workspace"
  calls=$(cat "${tmp}/calls")
  stored=$(cat "${config}/secrets.env" "${config}/vikunja.env" "${config}/n8n.env")
  rm -rf "$tmp"
  [[ "$out" == *"Vikunja access recovered for m@example.com"* ]] &&
    [[ "$calls" == *"user reset-password 1 -d -p"* ]] &&
    [[ -n "$password" ]] && [[ "$stored" != *"$password"* ]] &&
    [[ "$pager" == *"Press q to close."* ]] && [[ "$out" != *"password: $password"* ]]
}

test_workspace_recover_n8n() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out password config calls n8n_env login_count
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_WAIT_SLEEP=0 FAKE_COMPOSE_FILE="${tmp}/calls" \
    FAKE_N8N_LOGIN_COUNT_FILE="${tmp}/login-count" FAKE_N8N_LOGIN_FAIL_CALLS=1,3 \
    "$SPARK" ws recover n8n --yes 2>&1)
  password=$(sed -n 's/^    password: //p' <<< "$out")
  config="${tmp}/home/.config/spark/workspace"
  calls=$(cat "${tmp}/calls")
  n8n_env=$(cat "${config}/n8n.env")
  login_count=$(cat "${tmp}/login-count")
  rm -rf "$tmp"
  [[ "$out" == *"n8n access recovered for m@example.com"* ]] &&
    [[ $(grep -c 'force-recreate --no-deps n8n' <<< "$calls") -eq 2 ]] &&
    [[ "$calls" != *"user-management:reset"* ]] &&
    [[ "$login_count" -eq 4 ]] &&
    [[ "$n8n_env" != *"N8N_INSTANCE_OWNER_"* ]] &&
    [[ -n "$password" ]] && [[ "$n8n_env" != *"$password"* ]]
}

test_workspace_recover_n8n_fails_after_two_login_attempts() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status login_count
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_WAIT_SLEEP=0 FAKE_N8N_LOGIN_COUNT_FILE="${tmp}/login-count" \
    FAKE_N8N_LOGIN_FAIL_CALLS=1,2 "$SPARK" ws recover n8n --yes 2>&1)
  status=$?
  set -e
  login_count=$(cat "${tmp}/login-count")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$login_count" -eq 2 ]] &&
    [[ "$out" == *"n8n recovery did not complete cleanly"* ]]
}

test_workspace_recover_n8n_requires_supported_version() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_N8N_VERSION=2.16.9 "$SPARK" ws recover n8n --yes 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] && [[ "$out" == *"Update n8n to 2.17.0 or newer"* ]]
}

test_workspace_setup_repairs_polluted_required_env_values() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env_file env out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  grep -Ev '^(VIKUNJA_HUMAN_USERNAME|VIKUNJA_HUMAN_EMAIL|N8N_BASIC_AUTH_USER|N8N_BASIC_AUTH_PASSWORD|N8N_OWNER_FIRST_NAME)=' "$env_file" > "${env_file}.tmp"
  cat >> "${env_file}.tmp" <<'EOF_ENV'
VIKUNJA_HUMAN_USERNAME=  ✗ Vikunja human username is required
VIKUNJA_HUMAN_EMAIL=  ✗ Vikunja human email is required
N8N_BASIC_AUTH_USER=  ✗ n8n admin email is required
N8N_BASIC_AUTH_PASSWORD=  ✗ n8n admin/basic-auth password is required
N8N_OWNER_FIRST_NAME=  ✗ Vikunja human username is required
EOF_ENV
  mv "${env_file}.tmp" "$env_file"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha 2>&1 || true)
  env=$(cat "$env_file")
  rm -rf "$tmp"
  [[ "$out" == *"Ignoring invalid stored Vikunja human username"* ]] &&
    [[ "$env" == *"VIKUNJA_HUMAN_USERNAME=massimo"* ]] &&
    [[ "$env" == *"VIKUNJA_HUMAN_EMAIL=m@example.com"* ]] &&
    [[ "$env" == *"N8N_BASIC_AUTH_USER=m@example.com"* ]] &&
    [[ "$env" == *"N8N_OWNER_FIRST_NAME=massimo"* ]] &&
    [[ "$env" != *"✗"* ]] &&
    [[ "$env" != *"is required"* ]]
}

test_workspace_setup_cleans_polluted_env_before_missing_value_abort() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env_file env out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  mkdir -p "$(dirname "$env_file")"
  cat > "$env_file" <<'EOF_ENV'
HERMES_MODEL=Org/Alpha
VIKUNJA_HUMAN_USERNAME=  ✗ Vikunja human username is required
VIKUNJA_HUMAN_EMAIL=  ✗ Vikunja human email is required
N8N_BASIC_AUTH_USER=  ✗ n8n admin email is required
N8N_BASIC_AUTH_PASSWORD=  ✗ n8n admin/basic-auth password is required
N8N_OWNER_FIRST_NAME=  ✗ Vikunja human username is required
EOF_ENV
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha </dev/null 2>&1)
  status=$?
  set -e
  env=$(cat "$env_file")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Removed legacy stored interactive-user credentials"* ]] &&
    [[ "$out" == *"Workspace username is required"* ]] &&
    [[ "$env" != *"✗"* ]] &&
    [[ "$env" != *"is required"* ]]
}

test_workspace_remote_delegates() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_REMOTE_SPARK_VERSION="$SPARK_VERSION" \
    "$SPARK" ws setup --task-manager vikunja --check --remote me@10.0.0.5 --model Org/Alpha \
      --tailscale-mode ports --postgres-image postgres:18.1 \
      --vikunja-image vikunja/vikunja:1.2.3 --n8n-image docker.n8n.io/n8nio/n8n:1.100.0 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"Installed spark CLI v${SPARK_VERSION}"* ]] && [[ "$out" == *"remote workspace with opts ok"* ]]
}

test_workspace_remote_delegates_credentials() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_REMOTE_SPARK_VERSION="$SPARK_VERSION" \
    "$SPARK" ws setup --task-manager vikunja --yes --remote me@10.0.0.5 --model Org/Alpha \
      --tailscale-mode ports --postgres-image postgres:18.1 \
      --vikunja-image vikunja/vikunja:1.2.3 --n8n-image docker.n8n.io/n8nio/n8n:1.100.0 \
      --vikunja-username massimo --vikunja-email m@example.com --vikunja-password secret123 \
      --n8n-email m@example.com --n8n-password secret123 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"Installed spark CLI v${SPARK_VERSION}"* ]] && [[ "$out" == *"remote workspace with creds ok"* ]]
}

test_workspace_remote_check_does_not_forward_credentials() {
  local tmp fake_bin out script
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_REMOTE_SPARK_VERSION="$SPARK_VERSION" \
    FAKE_SSH_SCRIPT_FILE="${tmp}/remote-script.log" \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=n8n@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 \
    "$SPARK" ws setup --task-manager vikunja --check --remote me@10.0.0.5 --model Org/Alpha \
      --tailscale-mode ports --postgres-image postgres:18.1 \
      --vikunja-image vikunja/vikunja:1.2.3 --n8n-image docker.n8n.io/n8nio/n8n:1.100.0 2>&1 || true)
  script=$(cat "${tmp}/remote-script.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"remote workspace with opts ok"* ]] &&
    [[ "$script" != $'export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH;\n'* ]] &&
    [[ "$script" != *"secret123"* ]] &&
    [[ "$script" != *"secret456"* ]] &&
    [[ "$script" != *"SPARK_WORKSPACE_VIKUNJA_PASSWORD"* ]] &&
    [[ "$script" != *"SPARK_WORKSPACE_N8N_PASSWORD"* ]]
}

test_workspace_doctor_remote_delegates_doctor() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_REMOTE_SPARK_VERSION="$SPARK_VERSION" \
    "$SPARK" ws doctor --remote me@10.0.0.5 --model Org/Alpha 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"Installed spark CLI v${SPARK_VERSION}"* ]] &&
    [[ "$out" == *"remote doctor ok"* ]] &&
    [[ "$out" != *"remote workspace ok"* ]]
}

test_workspace_doctor_remote_delegates_strict() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_REMOTE_SPARK_VERSION="$SPARK_VERSION" \
    "$SPARK" ws doctor --strict --remote me@10.0.0.5 --model Org/Alpha 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"Installed spark CLI v${SPARK_VERSION}"* ]] &&
    [[ "$out" == *"remote strict doctor ok"* ]]
}

test_workspace_doctor_checklist_passes() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 \
    SPARK_WORKSPACE_VIKUNJA_IMAGE=vikunja/vikunja:1.0.0 \
    SPARK_WORKSPACE_N8N_IMAGE=docker.n8n.io/n8nio/n8n:1.100.0 \
    FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --verbose --model Org/Alpha 2>&1)
  rm -rf "$tmp"
    [[ "$out" == *"64/64 checks passed"* ]] &&
    [[ "$out" == *"Configuration"* ]] &&
    [[ "$out" == *"Identity & recovery"* ]] &&
    [[ "$out" == *"Runtime services"* ]] &&
    [[ "$out" == *"Private access"* ]] &&
    [[ "$out" == *"Inference & agent"* ]] &&
    [[ "$out" == *"[x] Compose service running: postgres"* ]] &&
    [[ "$out" == *"[x] Interactive service passwords are not stored"* ]] &&
    [[ "$out" == *"[x] Scoped service env files exist and are 0600"* ]] &&
    [[ "$out" == *"[x] Docker Compose config is valid"* ]] &&
    [[ "$out" == *"[x] Compose uses scoped env files, not full secrets.env"* ]] &&
    [[ "$out" == *"[x] Compose image refs are recorded and used"* ]] &&
    [[ "$out" == *"[x] Compose applies runtime hardening and log rotation"* ]] &&
    [[ "$out" == *"[x] Shared Postgres initializes task manager and n8n DBs"* ]] &&
    [[ "$out" == *"[x] Vikunja HTTP endpoint ready"* ]] &&
    [[ "$out" == *"[x] n8n HTTP endpoint ready"* ]] &&
    [[ "$out" == *"[x] Workspace URLs configured"* ]] &&
    [[ "$out" == *"[x] Workspace technical secrets are unique per service"* ]] &&
    [[ "$out" == *"[x] Vikunja human user exists"* ]] &&
    [[ "$out" == *"[x] Vikunja bot-hermes exists"* ]] &&
    [[ "$out" == *"[x] Vikunja bot-hermes API token works"* ]] &&
    [[ "$out" == *"[x] Vikunja projects are shared with bot-hermes"* ]] &&
    [[ "$out" == *"[x] n8n hardened for private agent workflows"* ]] &&
    [[ "$out" == *"[x] n8n owner/admin ready"* ]] &&
    [[ "$out" == *"[x] Tailscale supports selected private access mode"* ]] &&
    [[ "$out" == *"[x] Tailscale Services registered/authorized"* ]] &&
    [[ "$out" == *"[x] Tailscale Serve enabled"* ]] &&
    [[ "$out" == *"[x] Tailscale Service host advertised"* ]] &&
    [[ "$out" == *"[x] Tailscale local config maps tasks, n8n, hermes"* ]] &&
    [[ "$out" == *"[x] Tailscale mode is Services or ports"* ]] &&
    [[ "$out" == *"[x] Tailscale workspace URLs respond"* ]] &&
    [[ "$out" == *"[x] No workspace/gateway port is published on 0.0.0.0"* ]] &&
    [[ "$out" == *"[x] Host listeners for workspace/gateway are loopback-only"* ]] &&
    [[ "$out" == *"[x] Shared Postgres runtime has task manager and n8n roles/databases"* ]] &&
    [[ "$out" == *"[x] LiteLLM exposes Hermes model route"* ]] &&
    [[ "$out" == *"[x] LiteLLM Hermes route completes smoke request"* ]] &&
    [[ "$out" == *"[x] Vikunja internal doctor passes"* ]] &&
    [[ "$out" == *"[x] NemoHermes maintained release installed"* ]] &&
    [[ "$out" == *"[x] Hermes NemoClaw uses restricted policy and private dashboard/API ports"* ]] &&
    [[ "$out" == *"[x] Hermes local API is reachable"* ]] &&
    [[ "$out" == *"[x] NemoHermes sandbox doctor passes"* ]] &&
    [[ "$out" == *"[x] NemoHermes inference route uses selected LiteLLM model"* ]] &&
    [[ "$out" == *"[x] Hermes model supports automatic tool calling"* ]] &&
    [[ "$out" == *"[x] Hermes model context is at least 65536 tokens"* ]] &&
    [[ "$out" == *"[x] Hermes output and reasoning limits are configured"* ]] &&
    [[ "$out" == *"[x] Hermes CLI uses the balanced local-model tool profile"* ]] &&
    [[ "$out" == *"[x] Hermes reaches Vikunja as bot-hermes"* ]] &&
    [[ "$out" == *"[x] Hermes dashboard URL is reachable"* ]]
}

test_workspace_doctor_flags_stale_nemohermes_release() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_NEMOHERMES_UPDATE_CHECK=$'Current NemoHermes version: 0.0.55\nLatest maintained version: 0.0.78\nUpdate available:         yes' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --verbose --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] NemoHermes maintained release installed"* ]]
}

test_workspace_doctor_strict_checks_pinned_images() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 \
    SPARK_WORKSPACE_VIKUNJA_IMAGE=vikunja/vikunja:1.0.0 \
    SPARK_WORKSPACE_N8N_IMAGE=docker.n8n.io/n8nio/n8n:1.100.0 \
    FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --strict --verbose --model Org/Alpha 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"65/65 checks passed"* ]] &&
    [[ "$out" == *"[x] Compose image refs are pinned for production"* ]] &&
    [[ "$out" != *"Hermes GitHub repo access verified"* ]] &&
    [[ "$out" != *"Hermes WhatsApp channel healthy"* ]]
}

test_workspace_doctor_strict_flags_latest_images() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --strict --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Compose image refs are pinned for production"* ]] &&
    [[ "$out" != *"Hermes GitHub repo access verified"* ]] &&
    [[ "$out" != *"Hermes WhatsApp channel healthy"* ]]
}

test_workspace_doctor_json() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --json --model Org/Alpha)
  rm -rf "$tmp"
  printf '%s' "$out" | jq -e '
    .ok == true and
    .passed == 64 and
    .failed == 0 and
    .total == 64 and
    .model == "Org/Alpha" and
    ([.areas[] | select(.name == "Configuration" and .passed == 18 and .failed == 0)] | length == 1) and
    ([.areas[] | select(.name == "Identity & recovery" and .passed == 13 and .failed == 0)] | length == 1) and
    ([.areas[] | select(.name == "Inference & agent" and .passed == 16 and .failed == 0)] | length == 1) and
    ([.checks[] | select(.label == "LiteLLM exposes Hermes model route" and .ok == true)] | length == 1) and
    ([.checks[] | select(.label == "LiteLLM exposes Hermes model route" and .category == "Inference & agent" and (.action | length > 0))] | length == 1) and
    ([.checks[] | select(.label == "LiteLLM Hermes route completes smoke request" and .ok == true)] | length == 1) and
    ([.checks[] | select(.label == "NemoHermes inference route uses selected LiteLLM model" and .ok == true)] | length == 1) and
    ([.checks[] | select(.label == "Hermes model supports automatic tool calling" and .ok == true)] | length == 1) and
    ([.checks[] | select(.label == "Hermes model context is at least 65536 tokens" and .ok == true)] | length == 1) and
    ([.checks[] | select(.label == "Hermes output and reasoning limits are configured" and .ok == true)] | length == 1) and
    ([.checks[] | select(.label == "Hermes CLI uses the balanced local-model tool profile" and .ok == true)] | length == 1) and
    ([.checks[] | select(.label == "Hermes reaches Vikunja as bot-hermes" and .ok == true)] | length == 1) and
    ([.checks[] | select(.label == "Tailscale workspace URLs respond" and .ok == true)] | length == 1)
  ' >/dev/null
}

test_workspace_doctor_quiet_and_unconfigured_summary() {
  local tmp fake_bin out quiet_out status quiet_status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws doctor 2>&1)
  status=$?
  quiet_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws doctor --quiet 2>&1)
  quiet_status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 && "$quiet_status" -ne 0 && -z "$quiet_out" ]] &&
    [[ "$out" == *"0/1 checks passed"* ]] &&
    [[ "$out" == *"[ ] Workspace is configured"* ]] &&
    [[ "$out" != *"Config directory mode is 0700"* ]]
}

test_workspace_status_renders_containers_and_agent_workspace() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out verbose_out revision_line scoped_line
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_PS=$'NAME STATUS\nworkspace-n8n Up' \
    FAKE_NEMOHERMES_STATUS=$'Sandbox-scoped status for hermes:\n  Model: vllm/Org/Alpha\n  Agent: Hermes Agent\n\nSandbox:\n  Id: abc-123\n  Revision: 1\n\nPolicy:\nprivate policy detail' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws status 2>&1)
  verbose_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\nopenshell-hermes-test\n' \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"CapMap":{"services/tasks":[{"Name":"svc:tasks","Ports":["tcp:443"]}],"services/n8n":[{"Name":"svc:n8n","Ports":["tcp:443"]}],"services/hermes":[{"Name":"svc:hermes","Ports":["tcp:443"]}]}}}' \
    FAKE_COMPOSE_PS=$'NAME STATUS\nworkspace-n8n Up' \
    FAKE_NEMOHERMES_STATUS=$'Sandbox-scoped status for hermes:\n  Model: vllm/Org/Alpha\n  Agent: Hermes Agent\n\nSandbox:\n  Id: abc-123\n  Revision: 1\n\nPolicy:\nprivate policy detail' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws status --verbose 2>&1)
  revision_line=$(printf '%s\n' "$verbose_out" | grep -n 'Revision:' | cut -d: -f1)
  scoped_line=$(printf '%s\n' "$verbose_out" | grep -n 'Sandbox-scoped status' | cut -d: -f1)
  rm -rf "$tmp"
  [[ "$out" == *"spark ws status"* ]] &&
    [[ "$out" == *"Workspace services"* ]] &&
    [[ "$out" == *"Postgres"* && "$out" == *"Vikunja"* && "$out" == *"n8n"* && "$out" == *"Hermes"* ]] &&
    [[ "$out" == *"ready"* && "$out" == *"running"* ]] &&
    [[ "$out" == *"Agent workspace"* ]] &&
    [[ "$out" == *"Hermes model"* && "$out" == *"Org/Alpha"* ]] &&
    [[ "$out" == *"Private access"* && "$out" == *"ready"* ]] &&
    [[ "$out" == *"https://tasks.test-tailnet.ts.net"* ]] &&
    [[ "$out" != *"Workspace health"* ]] &&
    [[ "$out" != *"URLs:"* ]] &&
    [[ "$out" != *"LiteLLM"* ]] &&
    [[ "$out" != *"Policy:"* ]] &&
    [[ "$out" != *"Sandbox-scoped status"* ]] &&
    [[ "$out" != *"private policy detail"* ]] &&
    [[ "$verbose_out" == *"Policy:"* ]] &&
    [[ "$verbose_out" == *"private policy detail"* ]] &&
    [[ -n "$revision_line" && -n "$scoped_line" && "$scoped_line" -gt "$revision_line" ]]
}

test_workspace_status_json_quiet_and_containers() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin json quiet_out containers quiet_status status_json
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_min_workspace_config "${tmp}/home"
  cat > "${tmp}/home/.config/spark/workspace/secrets.env" <<'ENV'
WORKSPACE_TAILSCALE_MODE=services
HERMES_MODEL=Org/Alpha
VIKUNJA_URL=https://tasks.test-tailnet.ts.net
N8N_URL=https://n8n.test-tailnet.ts.net
HERMES_URL=https://hermes.test-tailnet.ts.net
ENV
  status_json='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"CapMap":{"services/tasks":[{"Name":"svc:tasks","Ports":["tcp:443"]}],"services/n8n":[{"Name":"svc:n8n","Ports":["tcp:443"]}],"services/hermes":[{"Name":"svc:hermes","Ports":["tcp:443"]}]}}}'
  json=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON="$status_json" FAKE_NAMES='openshell-hermes-test\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' "$SPARK" ws status --json)
  set +e
  quiet_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON="$status_json" FAKE_NAMES='openshell-hermes-test\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' "$SPARK" ws status --quiet 2>&1)
  quiet_status=$?
  set -e
  containers=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_NAMES='openshell-hermes-test\nspark-hermes-dashboard-proxy\n' \
    FAKE_COMPOSE_PS=$'NAME STATUS\nworkspace-n8n Up' "$SPARK" ws containers 2>&1)
  rm -rf "$tmp"
  printf '%s' "$json" | jq -e '
    .ok == true and .access == "ready" and .services.vikunja.state == "ready" and
    .services.n8n.state == "ready" and .services.hermes.state == "ready"
  ' >/dev/null &&
    [[ "$quiet_status" -eq 0 && -z "$quiet_out" ]] &&
    [[ "$containers" == *"spark ws containers"* ]] &&
    [[ "$containers" == *"workspace-n8n Up"* ]] &&
    [[ "$containers" == *"openshell-hermes-test"* ]]
}

test_workspace_doctor_flags_public_host_listener() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_SS_LISTEN='LISTEN 0 4096 0.0.0.0:3456 0.0.0.0:*\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Host listeners for workspace/gateway are loopback-only"* ]]
}

test_workspace_doctor_rejects_public_bind_addr_allowlist() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env_file
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  while IFS= read -r line; do
    case "$line" in
      WORKSPACE_TAILSCALE_BIND_ADDR=*) printf '%s\n' 'WORKSPACE_TAILSCALE_BIND_ADDR=0.0.0.0' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$env_file" > "${env_file}.tmp"
  mv "${env_file}.tmp" "$env_file"
  chmod 600 "$env_file"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_SS_LISTEN='LISTEN 0 4096 0.0.0.0:3456 0.0.0.0:*\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Host listeners for workspace/gateway are loopback-only"* ]]
}

test_workspace_doctor_rejects_non_tailscale_host_listener_allowlist() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env_file
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10"]}}' \
    FAKE_TAILSCALE_IP=100.64.0.10 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha --tailscale-mode ports >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  while IFS= read -r line; do
    case "$line" in
      WORKSPACE_TAILSCALE_BIND_ADDR=*) printf '%s\n' 'WORKSPACE_TAILSCALE_BIND_ADDR=192.168.1.10' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$env_file" > "${env_file}.tmp"
  mv "${env_file}.tmp" "$env_file"
  chmod 600 "$env_file"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_TAILSCALE_IP=100.64.0.10 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10"]}}' \
    FAKE_NAMES='spark-litellm\n' FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_SS_LISTEN='LISTEN 0 4096 192.168.1.10:3456 0.0.0.0:*\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Host listeners for workspace/gateway are loopback-only"* ]]
}

test_workspace_doctor_rejects_public_compose_bind() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env_file compose_file
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  compose_file="${tmp}/home/.config/spark/workspace/docker-compose.yml"
  while IFS= read -r line; do
    case "$line" in
      WORKSPACE_TAILSCALE_MODE=*) printf '%s\n' 'WORKSPACE_TAILSCALE_MODE=ports' ;;
      WORKSPACE_TAILSCALE_BIND_ADDR=*) printf '%s\n' 'WORKSPACE_TAILSCALE_BIND_ADDR=0.0.0.0' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$env_file" > "${env_file}.tmp"
  mv "${env_file}.tmp" "$env_file"
  chmod 600 "$env_file"
  while IFS= read -r line; do
    case "$line" in
      *"127.0.0.1:3456:3456"*) printf '%s\n' '      - "0.0.0.0:3456:3456"' ;;
      *"127.0.0.1:5678:5678"*) printf '%s\n' '      - "0.0.0.0:5678:5678"' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$compose_file" > "${compose_file}.tmp"
  mv "${compose_file}.tmp" "$compose_file"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Compose uses private host bindings only"* ]]
}

test_workspace_doctor_rejects_non_tailscale_ports_bind() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env_file compose_file
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  compose_file="${tmp}/home/.config/spark/workspace/docker-compose.yml"
  while IFS= read -r line; do
    case "$line" in
      WORKSPACE_TAILSCALE_MODE=*) printf '%s\n' 'WORKSPACE_TAILSCALE_MODE=ports' ;;
      WORKSPACE_TAILSCALE_BIND_ADDR=*) printf '%s\n' 'WORKSPACE_TAILSCALE_BIND_ADDR=192.168.1.10' ;;
      WORKSPACE_TAILSCALE_DNS_NAME=*) printf '%s\n' 'WORKSPACE_TAILSCALE_DNS_NAME=sparkbox.test-tailnet.ts.net' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$env_file" > "${env_file}.tmp"
  mv "${env_file}.tmp" "$env_file"
  chmod 600 "$env_file"
  while IFS= read -r line; do
    case "$line" in
      *"127.0.0.1:3456:3456"*) printf '%s\n' '      - "192.168.1.10:3456:3456"' ;;
      *"127.0.0.1:5678:5678"*) printf '%s\n' '      - "192.168.1.10:5678:5678"' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$compose_file" > "${compose_file}.tmp"
  mv "${compose_file}.tmp" "$compose_file"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_TAILSCALE_IP=100.64.0.10 \
    FAKE_NAMES='spark-litellm\n' FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Compose uses private host bindings only"* ]] &&
    [[ "$out" == *"[ ] Tailscale local config maps vikunja, n8n, hermes"* ]]
}

test_workspace_doctor_flags_public_docker_port() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_DOCKER_PORTS='[::]:3456->3456/tcp\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] No workspace/gateway port is published on 0.0.0.0"* ]]
}

test_workspace_doctor_flags_vikunja_doctor_failure() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_VIKUNJA_DOCTOR_EXIT=1 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Vikunja internal doctor passes"* ]]
}

test_workspace_doctor_accepts_writable_vikunja_group_mismatch() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status doctor_output
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  doctor_output=$'  ✗ Ownership match: directory owned by gid 1000 but Vikunja process is not a member of that group\n  ✓ Writable: yes\n\n1 check(s) failed\n'
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_VIKUNJA_DOCTOR_EXIT=1 FAKE_VIKUNJA_DOCTOR_OUTPUT="$doctor_output" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --verbose --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] &&
    [[ "$out" == *"[x] Vikunja internal doctor passes"* ]]
}

test_workspace_doctor_flags_stale_vikunja_token_status() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_VIKUNJA_USER_EXIT=1 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Vikunja bot-hermes API token works"* ]]
}

test_workspace_doctor_requires_vikunja_user_and_email_same_row() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_VIKUNJA_USER_LIST='| 1 | massimo | other@example.com | active |\n| 2 | other | m@example.com | active |\n| 3 | hermes | hermes@spark.invalid | active |\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Vikunja human user exists"* ]]
}

test_workspace_doctor_rejects_vikunja_user_substring_match() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_VIKUNJA_USER_LIST='| 1 | massimox | m@example.com | active |\n| 2 | hermes | hermes@spark.invalid | active |\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Vikunja human user exists"* ]]
}

test_workspace_doctor_rejects_manual_localhost_urls() {
  local tmp fake_bin out status env_file
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_min_workspace_config "${tmp}/home"
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  cat > "$env_file" <<EOF
VIKUNJA_URL=http://127.0.0.1:3456
N8N_URL=http://127.0.0.1:5678
HERMES_URL=http://127.0.0.1:18789
WORKSPACE_TAILSCALE_MODE=manual
EOF
  chmod 600 "$env_file"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Workspace URLs configured"* ]]
}

test_workspace_doctor_flags_public_config_dir() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  chmod 755 "${tmp}/home/.config/spark/workspace"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Config directory mode is 0700"* ]]
}

test_workspace_doctor_flags_stale_service_urls() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env_file tmp_env
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/n8n.env"
  tmp_env="${env_file}.tmp"
  while IFS= read -r line; do
    case "$line" in
      N8N_EDITOR_BASE_URL=*) printf '%s\n' 'N8N_EDITOR_BASE_URL=https://old.example.invalid' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$env_file" > "$tmp_env"
  mv "$tmp_env" "$env_file"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Workspace URLs configured"* ]]
}

test_workspace_doctor_rejects_wrong_tailnet_urls() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status file
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  for file in \
    "${tmp}/home/.config/spark/workspace/secrets.env" \
    "${tmp}/home/.config/spark/workspace/vikunja.env" \
    "${tmp}/home/.config/spark/workspace/n8n.env"; do
    while IFS= read -r line; do
      printf '%s\n' "${line//test-tailnet.ts.net/other-tailnet.ts.net}"
    done < "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
    chmod 600 "$file"
  done
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Workspace URLs configured"* ]] &&
    [[ "$out" == *"[ ] Tailscale workspace URLs respond"* ]]
}

test_workspace_doctor_rejects_stale_ports_urls() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env_file
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10"]}}' \
    FAKE_TAILSCALE_IP=100.64.0.10 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha --tailscale-mode ports >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  while IFS= read -r line; do
    case "$line" in
      HERMES_URL=*) printf '%s\n' 'HERMES_URL=http://oldbox.test-tailnet.ts.net:18789' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$env_file" > "${env_file}.tmp"
  mv "${env_file}.tmp" "$env_file"
  chmod 600 "$env_file"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_TAILSCALE_IP=100.64.0.10 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10"]}}' \
    FAKE_NAMES='spark-litellm\n' FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Workspace URLs configured"* ]] &&
    [[ "$out" == *"[ ] Tailscale workspace URLs respond"* ]]
}

test_workspace_doctor_rejects_stale_ports_dns_name() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status file
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10"]}}' \
    FAKE_TAILSCALE_IP=100.64.0.10 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha --tailscale-mode ports >/dev/null 2>&1 || true
  for file in \
    "${tmp}/home/.config/spark/workspace/secrets.env" \
    "${tmp}/home/.config/spark/workspace/vikunja.env" \
    "${tmp}/home/.config/spark/workspace/n8n.env"; do
    while IFS= read -r line; do
      printf '%s\n' "${line//sparkbox.test-tailnet.ts.net/oldbox.test-tailnet.ts.net}"
    done < "$file" > "${file}.tmp"
    mv "${file}.tmp" "$file"
    chmod 600 "$file"
  done
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_TAILSCALE_IP=100.64.0.10 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10"]}}' \
    FAKE_NAMES='spark-litellm\n' FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Workspace URLs configured"* ]] &&
    [[ "$out" == *"[ ] Tailscale local config maps vikunja, n8n, hermes"* ]] &&
    [[ "$out" == *"[ ] Tailscale workspace URLs respond"* ]]
}

test_workspace_doctor_flags_stale_n8n_owner_status() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  grep -v '^N8N_OWNER_SETUP_STATUS=' "${tmp}/home/.config/spark/workspace/secrets.env" > "${tmp}/owner-status.env"
  printf '%s\n' 'N8N_OWNER_SETUP_STATUS=manual' >> "${tmp}/owner-status.env"
  mv "${tmp}/owner-status.env" "${tmp}/home/.config/spark/workspace/secrets.env"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] n8n owner/admin ready"* ]]
}

test_workspace_doctor_flags_stored_human_password() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  printf '%s\n' 'VIKUNJA_HUMAN_PASSWORD=secret123' >> "${tmp}/home/.config/spark/workspace/secrets.env"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Interactive service passwords are not stored"* ]]
}

test_workspace_doctor_flags_duplicate_credentials() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env_file secret
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  secret=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$env_file")
  SECRET="$secret" awk '
    /^VIKUNJA_DATABASE_PASSWORD=/ { print "VIKUNJA_DATABASE_PASSWORD=" ENVIRON["SECRET"]; next }
    { print }
  ' "$env_file" > "${env_file}.tmp"
  mv "${env_file}.tmp" "$env_file"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Workspace technical secrets are unique per service"* ]]
}

test_workspace_doctor_flags_invalid_secrets_env() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  printf '%s\n' 'not a valid env line' >> "${tmp}/home/.config/spark/workspace/secrets.env"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Secrets env syntax is valid"* ]]
}

test_workspace_doctor_flags_invalid_service_env() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  printf '%s\n' 'N8N_PROTOCOL=http' >> "${tmp}/home/.config/spark/workspace/n8n.env"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Scoped service env syntax is valid"* ]]
}

test_workspace_doctor_flags_wrong_n8n_cookie_mode() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env_file tmp_env
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/n8n.env"
  tmp_env="${env_file}.tmp"
  while IFS= read -r line; do
    case "$line" in
      N8N_SECURE_COOKIE=*) printf '%s\n' 'N8N_SECURE_COOKIE=false' ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$env_file" > "$tmp_env"
  mv "$tmp_env" "$env_file"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] n8n hardened for private agent workflows"* ]]
}

test_workspace_doctor_flags_non_idempotent_postgres_init() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status init_file
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  init_file="${tmp}/home/.config/spark/workspace/init-db.sh"
  cat > "$init_file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
psql --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" <<'SQL'
CREATE USER vikunja;
CREATE DATABASE vikunja OWNER vikunja;
CREATE USER n8n;
CREATE DATABASE n8n OWNER n8n;
SQL
EOF
  chmod 700 "$init_file"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Shared Postgres initializes Vikunja and n8n DBs"* ]]
}

test_workspace_doctor_flags_missing_postgres_runtime_db() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_PG_DB_N8N=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Shared Postgres runtime has Vikunja and n8n roles/databases"* ]]
}

test_workspace_doctor_flags_missing_litellm_route() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_LITELLM_MODELS='{"data":[{"id":"vllm/Other"}]}' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] LiteLLM exposes Hermes model route"* ]]
}

test_workspace_doctor_flags_litellm_smoke_failure() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_LITELLM_SMOKE_EXIT=22 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] LiteLLM Hermes route completes smoke request"* ]]
}

test_workspace_doctor_flags_wrong_nemohermes_route() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_NEMOHERMES_INFERENCE_JSON='{"provider":"compatible-endpoint","model":"vllm/Other"}' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] NemoHermes inference route uses selected LiteLLM model"* ]]
}

test_workspace_doctor_flags_nemohermes_doctor_failure() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_HERMES_LOCAL_API_EXIT=7 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Hermes local API is reachable"* ]] &&
    [[ "$out" == *"[ ] NemoHermes sandbox doctor passes"* ]]
}

test_workspace_doctor_flags_missing_tailscale_service_registration() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10"],"CapMap":{"services/tasks":[{"Name":"svc:tasks","Ports":["tcp:443"]}],"services/n8n":[{"Name":"svc:n8n","Ports":["tcp:443"]}]}}}' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Tailscale Services registered/authorized"* ]]
}

test_workspace_doctor_flags_tailscale_serve_disabled() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  awk '
    /^WORKSPACE_TAILSCALE_LAST_ERROR=/ { print "WORKSPACE_TAILSCALE_LAST_ERROR=serve-disabled"; next }
    { print }
  ' "${tmp}/home/.config/spark/workspace/secrets.env" > "${tmp}/home/.config/spark/workspace/secrets.env.tmp"
  mv "${tmp}/home/.config/spark/workspace/secrets.env.tmp" "${tmp}/home/.config/spark/workspace/secrets.env"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Tailscale Serve enabled"* ]]
}

test_workspace_doctor_flags_tailscale_service_host_not_advertised() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_TAILSCALE_GET_CONFIG_EXIT=0 FAKE_TAILSCALE_SERVE_CONFIG='{"version":"0.0.1"}' \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10"],"CapMap":{"services/tasks":[{"Name":"svc:tasks","Ports":["tcp:443"]}],"services/n8n":[{"Name":"svc:n8n","Ports":["tcp:443"]}],"services/hermes":[{"Name":"svc:hermes","Ports":["tcp:443"]}]}}}' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Tailscale Service host advertised"* ]]
}

test_workspace_doctor_flags_wrong_nemoclaw_policy() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  perl -0pi -e 's/^HERMES_POLICY_TIER=restricted$/HERMES_POLICY_TIER=balanced/m' "${tmp}/home/.config/spark/workspace/secrets.env"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Hermes NemoClaw uses restricted policy and private dashboard/API ports"* ]]
}

test_workspace_doctor_flags_wrong_hermes_dashboard_url() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_TAILSCALE_HERMES_EXIT=7 \
    FAKE_NEMOHERMES_DASHBOARD_URL='http://127.0.0.1:9999' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Hermes dashboard URL is reachable"* ]]
}

test_workspace_doctor_flags_missing_tailscale_service_config() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_TAILSCALE_SERVE_CONFIG='svc:tasks 127.0.0.1:3456\nsvc:n8n 127.0.0.1:5678' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Tailscale local config maps vikunja, n8n, hermes"* ]]
}

test_workspace_doctor_flags_tailscale_funnel_enabled() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_TAILSCALE_FUNNEL_EXIT=0 \
    FAKE_TAILSCALE_FUNNEL_STATUS='https://tasks.example.com\n' \
    FAKE_NAMES='spark-litellm\n' FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Tailscale Funnel disabled"* ]]
}

test_workspace_doctor_rejects_public_tailscale_service_target() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_TAILSCALE_SERVE_CONFIG='svc:tasks 0.0.0.0:3456\nsvc:n8n 127.0.0.1:5678\nsvc:hermes 127.0.0.1:18790' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Tailscale local config maps vikunja, n8n, hermes"* ]]
}

test_workspace_doctor_rejects_swapped_tailscale_service_ports() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_TAILSCALE_SERVE_CONFIG='svc:tasks 127.0.0.1:5678\nsvc:n8n 127.0.0.1:3456\nsvc:hermes 127.0.0.1:18790' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Tailscale local config maps vikunja, n8n, hermes"* ]]
}

test_workspace_doctor_accepts_multiline_tailscale_service_json() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out serve_config
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  serve_config=$'{
    "svc:tasks": { "Handlers": { "/": { "Proxy": "http://127.0.0.1:3456" } } },
    "svc:n8n": { "Handlers": { "/": { "Proxy": "http://127.0.0.1:5678" } } },
    "svc:hermes": { "Handlers": { "/": { "Proxy": "http://127.0.0.1:18790" } } }
  }'
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_TAILSCALE_SERVE_CONFIG="$serve_config" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --verbose --model Org/Alpha 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"64/64 checks passed"* ]] &&
    [[ "$out" == *"[x] Tailscale local config maps vikunja, n8n, hermes"* ]]
}

test_workspace_doctor_accepts_tailscale_services_endpoint_json() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out serve_config
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  serve_config='{"version":"0.0.1","services":{"svc:tasks":{"endpoints":{"tcp:443":"http://127.0.0.1:3456"}},"svc:n8n":{"endpoints":{"tcp:443":"http://127.0.0.1:5678"}},"svc:hermes":{"endpoints":{"tcp:443":"http://127.0.0.1:18790"}}}}'
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_TAILSCALE_SERVE_CONFIG="$serve_config" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --verbose --model Org/Alpha 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"64/64 checks passed"* ]] &&
    [[ "$out" == *"[x] Tailscale local config maps vikunja, n8n, hermes"* ]]
}

test_workspace_doctor_flags_invalid_compose_config() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_COMPOSE_CONFIG_EXIT=1 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Docker Compose config is valid"* ]]
}

test_workspace_doctor_flags_missing_runtime_hardening() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status compose_file tmp_compose
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  compose_file="${tmp}/home/.config/spark/workspace/docker-compose.yml"
  tmp_compose="${compose_file}.tmp"
  grep -v 'init: true' "$compose_file" > "$tmp_compose"
  mv "$tmp_compose" "$compose_file"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Compose applies runtime hardening and log rotation"* ]]
}

test_workspace_backup_manifest_and_verify() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin manifest config_tgz checksums hermes_status nemoclaw_status out verify_out backup_dir
  local hermes_status_text nemoclaw_status_text
  local backup_mode manifest_mode config_mode checksums_mode
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws backup 2>&1)
  manifest=$(find "${tmp}/home/.local/share/spark/workspace/backups" -name manifest.env -print -quit 2>/dev/null)
  config_tgz=$(find "${tmp}/home/.local/share/spark/workspace/backups" -name workspace-config.tgz -print -quit 2>/dev/null)
  checksums=$(find "${tmp}/home/.local/share/spark/workspace/backups" -name checksums.sha256 -print -quit 2>/dev/null)
  backup_dir=$(dirname "$manifest")
  hermes_status="${backup_dir}/hermes-snapshot.status"
  nemoclaw_status="${backup_dir}/nemoclaw-backup.status"
  verify_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws backup --verify "$backup_dir" 2>&1)
  local manifest_text
  manifest_text=$(cat "$manifest" 2>/dev/null || echo "")
  hermes_status_text=$(cat "$hermes_status" 2>/dev/null || echo "")
  nemoclaw_status_text=$(cat "$nemoclaw_status" 2>/dev/null || echo "")
  backup_mode=$(stat -c '%a' "$backup_dir" 2>/dev/null || stat -f '%Lp' "$backup_dir" 2>/dev/null || echo "")
  manifest_mode=$(stat -c '%a' "$manifest" 2>/dev/null || stat -f '%Lp' "$manifest" 2>/dev/null || echo "")
  config_mode=$(stat -c '%a' "$config_tgz" 2>/dev/null || stat -f '%Lp' "$config_tgz" 2>/dev/null || echo "")
  checksums_mode=$(stat -c '%a' "$checksums" 2>/dev/null || stat -f '%Lp' "$checksums" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"Backed up workspace config"* ]] &&
    [[ "$out" == *"Wrote backup checksums"* ]] &&
    [[ "$verify_out" == *"Backup verified"* ]] &&
    [[ -n "$manifest" ]] && [[ -n "$config_tgz" ]] && [[ -n "$checksums" ]] &&
    [[ "$backup_mode" == "700" ]] &&
    [[ "$manifest_mode" == "600" ]] &&
    [[ "$config_mode" == "600" ]] &&
    [[ "$checksums_mode" == "600" ]] &&
    [[ "$hermes_status_text" == "ok" ]] && [[ "$nemoclaw_status_text" == "ok" ]] &&
    [[ "$manifest_text" == *"WORKSPACE_CONFIG_STATUS=ok"* ]] &&
    [[ "$manifest_text" == *"VIKUNJA_DUMP_STATUS=ok"* ]] &&
    [[ "$manifest_text" == *"VIKUNJA_DB_STATUS=ok"* ]] &&
    [[ "$manifest_text" == *"N8N_DB_STATUS=ok"* ]] &&
    [[ "$manifest_text" == *"HERMES_SNAPSHOT_STATUS=ok"* ]] &&
    [[ "$manifest_text" == *"NEMOCLAW_BACKUP_ALL_STATUS=ok"* ]] &&
    [[ "$manifest_text" == *"CHECKSUMS_STATUS=ok"* ]]
}

test_workspace_backup_requires_config() {
  local tmp fake_bin out status mutated=0
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws backup 2>&1)
  status=$?
  set -e
  [[ -d "${tmp}/home/.local/share/spark/workspace/backups" ]] && mutated=1
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Workspace not configured"* ]] &&
    [[ "$mutated" -eq 0 ]]
}

test_workspace_backup_verify_rejects_extra_args() {
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws backup --verify "$tmp" extra 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Usage: spark ws backup --verify BACKUP_DIR"* ]]
}

test_workspace_logs_requires_config() {
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws logs vikunja 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Workspace not configured"* ]]
}

test_workspace_backup_verify_flags_missing_hermes_marker() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin manifest backup_dir out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws backup >/dev/null 2>&1 || true
  manifest=$(find "${tmp}/home/.local/share/spark/workspace/backups" -name manifest.env -print -quit 2>/dev/null)
  backup_dir=$(dirname "$manifest")
  rm -f "${backup_dir}/hermes-snapshot.status"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws backup --verify "$backup_dir" 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"hermes-snapshot.status missing or empty"* ]]
}

test_workspace_backup_verify_flags_public_backup_file() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin manifest backup_dir out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws backup >/dev/null 2>&1 || true
  manifest=$(find "${tmp}/home/.local/share/spark/workspace/backups" -name manifest.env -print -quit 2>/dev/null)
  backup_dir=$(dirname "$manifest")
  chmod 644 "${backup_dir}/workspace-config.tgz"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws backup --verify "$backup_dir" 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"workspace-config.tgz mode must be 0600"* ]]
}

test_workspace_backup_verify_flags_checksum_mismatch() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin manifest backup_dir out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws backup >/dev/null 2>&1 || true
  manifest=$(find "${tmp}/home/.local/share/spark/workspace/backups" -name manifest.env -print -quit 2>/dev/null)
  backup_dir=$(dirname "$manifest")
  printf '%s\n' 'corrupt' > "${backup_dir}/n8n.sql"
  chmod 600 "${backup_dir}/n8n.sql"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws backup --verify "$backup_dir" 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Backup checksum mismatch: n8n.sql"* ]]
}

test_workspace_backup_verify_flags_missing_checksum_entry() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin manifest backup_dir checksums out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws backup >/dev/null 2>&1 || true
  manifest=$(find "${tmp}/home/.local/share/spark/workspace/backups" -name manifest.env -print -quit 2>/dev/null)
  backup_dir=$(dirname "$manifest")
  checksums="${backup_dir}/checksums.sha256"
  cp "${backup_dir}/n8n.sql" "${backup_dir}/n8nXsql"
  while IFS= read -r line; do
    printf '%s\n' "${line//n8n.sql/n8nXsql}"
  done < "$checksums" > "${checksums}.tmp"
  mv "${checksums}.tmp" "$checksums"
  chmod 600 "$checksums"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws backup --verify "$backup_dir" 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Checksum entry missing: n8n.sql"* ]]
}

test_workspace_backup_verify_flags_unexpected_checksum_entry() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin manifest backup_dir checksums out status hash
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws backup >/dev/null 2>&1 || true
  manifest=$(find "${tmp}/home/.local/share/spark/workspace/backups" -name manifest.env -print -quit 2>/dev/null)
  backup_dir=$(dirname "$manifest")
  checksums="${backup_dir}/checksums.sha256"
  printf '%s\n' 'extra' > "${backup_dir}/extra.txt"
  chmod 600 "${backup_dir}/extra.txt"
  hash=$(sha256sum "${backup_dir}/extra.txt" 2>/dev/null | awk '{print $1}' || shasum -a 256 "${backup_dir}/extra.txt" | awk '{print $1}')
  printf '%s  extra.txt\n' "$hash" >> "$checksums"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws backup --verify "$backup_dir" 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Unexpected checksum entry: extra.txt"* ]]
}

test_workspace_removed_commands_are_unknown() {
  local tmp fake_bin out1 out2 out3 out4 out5 s1 s2 s3 s4 s5 mutated=0
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  set +e
  out1=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws github 2>&1); s1=$?
  out2=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws whatsapp 2>&1); s2=$?
  out3=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws vikunja-token 2>&1); s3=$?
  out4=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws n8n-owner 2>&1); s4=$?
  out5=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws workflows 2>&1); s5=$?
  set -e
  [[ -e "${tmp}/home/.config/spark/workspace/secrets.env" || -e "${tmp}/home/.config/spark/workspace/github-repos.txt" || -e "${tmp}/home/.config/spark/workspace/workflows" ]] && mutated=1
  rm -rf "$tmp"
  [[ "$s1" -ne 0 && "$s2" -ne 0 && "$s3" -ne 0 && "$s4" -ne 0 && "$s5" -ne 0 ]] &&
    [[ "$out1$out2$out3$out4$out5" == *"Unknown ws command"* ]] &&
    [[ "$mutated" -eq 0 ]]
}

test_workspace_setup_accepts_todoist_token() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env out status label_state skill
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  label_state="${tmp}/todoist-hermes-label"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 SPARK_WORKSPACE_HERMES_API_ATTEMPTS=1 \
    FAKE_HERMES_TODOIST_LABEL_STATE_FILE="$label_state" FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager todoist --yes --model Org/Alpha --token td_test 2>&1)
  status=$?
  set -e
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  skill=$(cat "${tmp}/home/.config/spark/workspace/hermes-skills/todoist/SKILL.md" 2>/dev/null || echo "")
  [[ "$status" -eq 0 ]] && [[ "$out" == *"Workspace complete!"* ]] &&
    [[ "$env" == *"TODOIST_API_TOKEN=td_test"* ]] &&
    [[ "$env" == *"TODOIST_API_STATUS=verified"* ]] &&
    [[ -e "$label_state" ]] &&
    [[ "$skill" == *'Every task that Hermes changes must retain this label'* ]]
  status=$?
  rm -rf "$tmp"
  return "$status"
}

test_workspace_setup_fails_when_todoist_label_creation_fails() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env out status label_state
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  label_state="${tmp}/todoist-hermes-label"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 SPARK_WORKSPACE_HERMES_API_ATTEMPTS=1 \
    FAKE_HERMES_TODOIST_LABEL_STATE_FILE="$label_state" \
    FAKE_HERMES_TODOIST_LABEL_CREATE_EXIT=1 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager todoist --yes --model Org/Alpha --token td_test 2>&1)
  status=$?
  set -e
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Could not give Hermes verified Todoist API access"* ]] &&
    [[ "$env" == *"TODOIST_API_STATUS=pending"* ]] &&
    [[ ! -e "$label_state" ]]
}

test_workspace_setup_rejects_multiline_todoist_token() {
  local tmp fake_bin out status mutated=0
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    "$SPARK" ws setup --task-manager todoist --yes --model Org/Alpha --token $'td_test\nbad' 2>&1)
  status=$?
  set -e
  [[ -e "${tmp}/home/.config/spark/workspace/secrets.env" ]] && mutated=1
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Todoist API token is invalid or missing"* ]] &&
    [[ "$mutated" -eq 0 ]]
}

test_workspace_setup_rejects_removed_vikunja_token_flag() {
  local tmp fake_bin out status mutated=0
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha --vikunja-token vk_test 2>&1)
  status=$?
  set -e
  [[ -e "${tmp}/home/.config/spark/workspace/secrets.env" ]] && mutated=1
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Unknown ws setup flag: --vikunja-token"* ]] &&
    [[ "$mutated" -eq 0 ]]
}

test_workspace_setup_rerun_bootstraps_n8n_owner() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_N8N_LOGIN_EXIT=7 FAKE_N8N_LOGIN_AFTER_OWNER=1 FAKE_N8N_OWNER_MARKER="${tmp}/n8n.owner" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_N8N_LOGIN_EXIT=7 FAKE_N8N_LOGIN_AFTER_OWNER=1 FAKE_N8N_OWNER_MARKER="${tmp}/n8n.owner" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$env" == *"N8N_OWNER_SETUP_STATUS=created"* || "$env" == *"N8N_OWNER_SETUP_STATUS=exists"* ]]
}

test_workspace_setup_uses_only_n8n_2x_login_field() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_N8N_LOGIN_REQUIRE_EMAIL_OR_LDAP=1 FAKE_N8N_LOGIN_FORBID_EMAIL_FIELD=1 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --task-manager vikunja --yes --model Org/Alpha >/dev/null 2>&1 || true
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$env" == *"N8N_OWNER_SETUP_STATUS=exists"* ]]
}

# --- Doctor per backend ---
test_doctor_ollama_backend() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama SPARK_ACCEL=metal \
    FAKE_OLLAMA_UP=1 FAKE_OLLAMA_LIST="NAME\tID\tSIZE\tMOD\nqwen3:30b\tabc\t18\tGB\n" \
    "$SPARK" doctor --verbose 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"backend ollama"* ]] && [[ "$out" == *"Ollama API"* ]] &&
    [[ "$out" == *"reachable on port 11434"* ]] && [[ "$out" == *"Pulled models"* ]] &&
    [[ "$out" == *"1 found"* ]] && [[ "$out" != *"NGC"* ]]
}

# --- Ollama advisory (estimate at default ctx + warn/confirm) ---
test_ollama_oversized_warns_aborts() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(printf 'n\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    SPARK_TOTAL_MEM_GB=121 SPARK_ASSUME_INTERACTIVE=1 FAKE_OLLAMA_UP=1 \
    FAKE_OLLAMA_LIST="NAME\tID\tSIZE\tMODIFIED\nbig:latest\tabc123\t200\tGB\n" \
    "$SPARK" run big:latest 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"offload layers to CPU"* ]] && [[ "$out" == *"Aborted"* ]] && [[ "$out" != *"ready via Ollama"* ]]
}

test_ollama_oversized_continue_yes() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    SPARK_TOTAL_MEM_GB=121 SPARK_ASSUME_INTERACTIVE=1 FAKE_OLLAMA_UP=1 \
    FAKE_OLLAMA_LIST="NAME\tID\tSIZE\tMODIFIED\nbig:latest\tabc123\t200\tGB\n" \
    FAKE_OLLAMA_SHOW="block_count 80\nattention.head_count_kv 8\nattention.key_length 128\n" \
    "$SPARK" run big:latest 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"offload layers to CPU"* ]] && [[ "$out" == *"ready via Ollama"* ]]
}

# --- Gateway networking per OS ---
# Write a minimal gateway config with the Ollama provider enabled.
write_ollama_gateway_config() {
  local home="$1"
  mkdir -p "${home}/.config/spark"
  printf '%s\n' '{"enabled":true,"port":4000,"providers":{"ollama":{"enabled":true}}}' \
    > "${home}/.config/spark/gateway.json"
}

test_gateway_ollama_route_mac() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin yaml dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  write_ollama_gateway_config "${tmp}/home"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_OS_OVERRIDE=Darwin \
    FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" gateway start >/dev/null 2>&1 || true
  yaml=$(cat "${tmp}/home/.config/spark/litellm_config.yaml" 2>/dev/null || echo "")
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$yaml" == *"ollama_chat/*"* ]] && [[ "$yaml" == *"host.docker.internal:11434"* ]] &&
    [[ "$dargs" == *"-p 127.0.0.1:4000:4000"* ]]
}

test_gateway_ollama_route_linux() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin yaml dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  write_ollama_gateway_config "${tmp}/home"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_OS_OVERRIDE=Linux \
    FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" gateway start >/dev/null 2>&1 || true
  yaml=$(cat "${tmp}/home/.config/spark/litellm_config.yaml" 2>/dev/null || echo "")
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$yaml" == *"ollama_chat/*"* ]] && [[ "$yaml" == *"http://localhost:11434"* ]] &&
    [[ "$dargs" == *"--network host"* ]] && [[ "$dargs" == *"--host 127.0.0.1"* ]]
}

# --- Compatibility validation ---
test_ollama_blocks_vllm_only_model() {
  local tmp fake_bin out rc
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    "$SPARK" run RedHatAI/Qwen3-NVFP4 --dry-run 2>&1) && rc=0 || rc=$?
  rm -rf "$tmp"
  [[ "${rc:-0}" -ne 0 ]] && [[ "$out" == *"vLLM-only"* ]]
}

test_vllm_blocks_ollama_tag() {
  local tmp fake_bin out rc
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    "$SPARK" run qwen3:30b --dry-run 2>&1) && rc=0 || rc=$?
  rm -rf "$tmp"
  [[ "${rc:-0}" -ne 0 ]] && [[ "$out" == *"Ollama model tag"* ]]
}

# --- Capacity: auto-fit max context before offering fp8 ---
# 30B: weights 14, KV@262K 24, need 41.0. Reserve 88 -> free 26: full context does
# not fit, so run auto-reduces to the largest 1024-aligned KV-auto context that fits.
RESERVE_85='spark-vllm-big\torg/big\t8000\t88.0\t73.0\t15.0\n'
RESERVE_FP8_ONLY='spark-vllm-big\torg/big\t8000\t98.8\t83.8\t15.0\n'

test_dryrun_shows_fit_options() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_MANAGED="$RESERVE_85" \
    "$SPARK" run Qwen/Qwen3-30B --dry-run </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] &&
    [[ "$out" == *"Using max context that fits now: 109568/262144 tokens"* ]] &&
    [[ "$out" == *"--max-model-len 109568"* ]] &&
    [[ "$out" == *"docker run"* ]]
}

test_dryrun_live_available_caps_auto_fit() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_RAM_AVAIL_GB=25 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_MANAGED="$RESERVE_85" \
    "$SPARK" run Qwen/Qwen3-30B --dry-run </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] &&
    [[ "$out" == *"Using max context that fits now: 99328/262144 tokens"* ]] &&
    [[ "$out" == *"--max-model-len 99328"* ]] &&
    [[ "$out" == *"docker run"* ]]
}

test_menu_choose_fp8_relaunches() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  printf '1\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_ASSUME_INTERACTIVE=1 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED="$RESERVE_FP8_ONLY" FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" run Qwen/Qwen3-30B >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"--max-model-len 1024"* ]] && [[ "$dargs" == *"--kv-cache-dtype fp8"* ]]
}

test_menu_choose_auto_relaunches() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED="$RESERVE_85" FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" run Qwen/Qwen3-30B >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"--max-model-len 109568"* ]] && [[ "$dargs" != *"--kv-cache-dtype fp8"* ]]
}

test_menu_cancel_aborts() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  out=$(printf '2\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_ASSUME_INTERACTIVE=1 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED="$RESERVE_FP8_ONLY" FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" run Qwen/Qwen3-30B 2>&1 || true)
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"Aborted"* ]] && [[ -z "$dargs" ]]
}

test_autopull_menu_downloads_at_choice() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs weights downloaded
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; mkdir -p "${tmp}/home"
  # Not downloaded; sized from metadata. Only a tiny fp8 context fits, so choose fp8 explicitly.
  printf '1\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ASSUME_INTERACTIVE=1 \
    SPARK_TOTAL_MEM_GB=121 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED="$RESERVE_FP8_ONLY" FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" run Qwen/Qwen3-30B >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  weights="${tmp}/home/.cache/huggingface/hub/models--Qwen--Qwen3-30B/snapshots/1/model-00001-of-00001.safetensors"
  downloaded=0; [[ -f "$weights" ]] && downloaded=1
  rm -rf "$tmp"
  [[ "$downloaded" -eq 1 ]] && [[ "$dargs" == *"--max-model-len 1024"* ]] && [[ "$dargs" == *"--kv-cache-dtype fp8"* ]]
}

test_mem_override_suggests_mem() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_MANAGED="$RESERVE_85" \
    "$SPARK" run Qwen/Qwen3-30B --mem 0.9 </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] && [[ "$out" == *"Fits with --mem ≤ 0.21"* ]] && [[ "$out" != *"--max-len"* ]]
}

# --- Per-container hard memory limit (--memory) ---
# 30B NEED 41.0 at 262K context.
test_mem_limit_present_unified() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    SPARK_SWAP_GB=64 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    "$SPARK" run Qwen/Qwen3-30B </dev/null >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  # --memory cap = NEED + WARMUP_HEADROOM (default 20): (41.0+20)×1024 = 62464 MiB.
  # --memory-swap = cap + provisioned swap (64G): 62464 + 65536 = 128000 MiB (lets the load peak
  # spill to swap instead of cgroup-OOMing mid-load).
  [[ "$dargs" == *"--memory 62464m"* ]] && [[ "$dargs" == *"--memory-swap 128000m"* ]]
}

test_mem_limit_absent_discrete() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-discrete \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    "$SPARK" run Qwen/Qwen3-30B </dev/null >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"vllm serve"* ]] && [[ "$dargs" != *"--memory"* ]]
}

test_mem_limit_absent_with_flag() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    "$SPARK" run Qwen/Qwen3-30B --no-mem-limit </dev/null >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"vllm serve"* ]] && [[ "$dargs" != *"--memory"* ]]
}

test_vllm_runs_as_host_user_with_user_cache() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs uid gid
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    "$SPARK" run Qwen/Qwen3-30B </dev/null >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/d.txt" 2>/dev/null || echo "")
  uid=$(id -u); gid=$(id -g)
  rm -rf "$tmp"
  [[ "$dargs" == *"--user ${uid}:${gid}"* ]] &&
    [[ "$dargs" == *"-e HOME=/tmp"* ]] &&
    [[ "$dargs" == *"-e HF_HOME=/tmp/huggingface"* ]] &&
    [[ "$dargs" == *"-e HF_HUB_CACHE=/tmp/huggingface/hub"* ]] &&
    [[ "$dargs" == *":/tmp/huggingface"* ]] &&
    [[ "$dargs" != *":/root/.cache/huggingface"* ]]
}

test_mem_limit_headroom_env() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  # SPARK_WARMUP_HEADROOM_GB=30: (41.0+30)×1024 = 72704 MiB.
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    SPARK_WARMUP_HEADROOM_GB=30 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" "$SPARK" run Qwen/Qwen3-30B </dev/null >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"--memory 72704m"* ]] && [[ "$dargs" != *"62464m"* ]]
}

# --- Adaptive supervised startup ---
# Default concurrency cap is 100 (replacing vLLM's 256) and is announced.
test_max_num_seqs_default() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    "$SPARK" run Qwen/Qwen3-30B </dev/null 2>&1 || true)
  dargs=$(cat "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"--max-num-seqs 5"* ]] && [[ "$out" == *"up to 5 concurrent"* ]]
}

test_max_num_seqs_override() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    "$SPARK" run Qwen/Qwen3-30B --max-num-seqs 200 </dev/null >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"--max-num-seqs 200"* ]] && [[ "$dargs" != *"--max-num-seqs 100"* ]]
}

# Hybrid/Mamba cache-block failure → auto-lower --max-num-seqs and retry, then serve.
test_startup_retry_mamba() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out last
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    FAKE_RETRY=mamba FAKE_MAMBA_N=2 \
    "$SPARK" run Qwen/Qwen3-30B </dev/null 2>&1 || true)
  last=$(tail -1 "${tmp}/d.txt" 2>/dev/null || echo "")
  local nruns; nruns=$(grep -c '^run ' "${tmp}/d.txt" 2>/dev/null || echo 0)
  rm -rf "$tmp"
  [[ "$nruns" -eq 2 ]] && [[ "$last" == *"--max-num-seqs 2"* ]] &&
    [[ "$out" == *"retrying with --max-num-seqs 2"* ]] && [[ "$out" == *"serving"* ]]
}

# Warmup OOM → raise the cgroup margin (25%→50%) within the cap and retry.
test_startup_retry_oom() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out last
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    FAKE_RETRY=oom \
    "$SPARK" run Qwen/Qwen3-30B </dev/null 2>&1 || true)
  last=$(tail -1 "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  # The warmup-OOM lever is now --enforce-eager (removes the CUDA-graph peak), not a margin bump.
  [[ "$last" == *"--enforce-eager"* ]] && [[ "$out" == *"--enforce-eager"* ]] && [[ "$out" == *"serving"* ]]
}

# An unrecognized startup crash aborts without retrying.
test_startup_unrecoverable_aborts() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out nruns
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    FAKE_STATE_STATUS=exited FAKE_DOCKER_LOGS="RuntimeError: unrelated fatal error" \
    "$SPARK" run Qwen/Qwen3-30B </dev/null 2>&1)
  set -e
  nruns=$(grep -c '^run ' "${tmp}/d.txt" 2>/dev/null || echo 0)
  rm -rf "$tmp"
  [[ "$nruns" -eq 1 ]] && [[ "$out" == *"failed to start"* ]]
}

# --no-wait launches and returns without supervising.
test_startup_no_wait() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Qwen/Qwen3-30B --no-wait </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"started"* ]] && [[ "$out" != *"waiting for it to serve"* ]]
}

# A MoE model (vLLM under-profiles these → big startup peak) gets --enforce-eager auto on the first
# launch (no measured peak yet); a dense model does not.
MOE_CONFIG='{ "model_type":"qwen3_moe", "architectures":["Qwen3MoeForCausalLM"],
  "num_hidden_layers":48, "num_key_value_heads":4, "num_attention_heads":32,
  "head_dim":128, "hidden_size":2048, "max_position_embeddings":262144, "num_experts":128,
  "quantization_config":{"quant_method":"nvfp4"}, "num_parameters":30000000000 }'
test_enforce_eager_auto_for_moe() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin moe dense
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Moe" "$MOE_CONFIG"
  make_model "${tmp}/home" "Org/Dense" "$KV_CONFIG"
  moe=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" "$SPARK" run Org/Moe --dry-run </dev/null 2>&1 || true)
  dense=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" "$SPARK" run Org/Dense --dry-run </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$moe" == *"--enforce-eager"* ]] && [[ "$dense" != *"--enforce-eager"* ]]
}

test_hf_moe_nvfp4_emits_marlin_atomic() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Moe" "$MOE_CONFIG"
  meta=$(hf_inspect_json false false null false moe nvfp4)
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Moe --dry-run </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"--moe-backend marlin"* ]] && [[ "$out" == *"VLLM_MARLIN_USE_ATOMIC_ADD=1"* ]]
}

test_hf_inspector_compressed_tensors_nvfp4_tag() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  command -v python3 >/dev/null 2>&1 || { printf "skip - python3 not installed\n"; return 0; }
  local tmp q
  tmp=$(mktemp -d)
  make_model "${tmp}/home" "Org/Model-NVFP4" '{ "model_type":"qwen3", "architectures":["Qwen3MoeForCausalLM"],
    "max_position_embeddings":262144, "num_experts":128,
    "quantization_config":{"quant_method":"compressed-tensors"} }'
  q=$(python3 "${ROOT_DIR}/scripts/hf_model_inspect.py" --model-id Org/Model-NVFP4 \
    --local-path "${tmp}/home/.cache/huggingface/hub/models--Org--Model-NVFP4/snapshots/1" \
    | jq -r '.features.quantization')
  rm -rf "$tmp"
  [[ "$q" == "nvfp4" ]]
}

test_hf_inspector_modelopt_hf_quant_nvfp4_tag() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  command -v python3 >/dev/null 2>&1 || { printf "skip - python3 not installed\n"; return 0; }
  local tmp dir q
  tmp=$(mktemp -d)
  make_model "${tmp}/home" "Org/Model-ModelOpt" '{ "model_type":"qwen3", "architectures":["Qwen3MoeForCausalLM"],
    "max_position_embeddings":262144, "num_experts":128,
    "quantization_config":{"quant_method":"modelopt"} }'
  dir="${tmp}/home/.cache/huggingface/hub/models--Org--Model-ModelOpt/snapshots/1"
  printf '%s\n' '{ "quantization": { "quantized_layers": { "layer0": { "quant_algo":"W4A16_NVFP4" } } } }' > "${dir}/hf_quant_config.json"
  q=$(python3 "${ROOT_DIR}/scripts/hf_model_inspect.py" --model-id Org/Model-ModelOpt \
    --local-path "$dir" | jq -r '.features.quantization')
  rm -rf "$tmp"
  [[ "$q" == "nvfp4" ]]
}

test_hf_inspector_prefers_recommended_multiline_command_from_readme() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  command -v python3 >/dev/null 2>&1 || { printf "skip - python3 not installed\n"; return 0; }
  local tmp dir cmd image
  tmp=$(mktemp -d)
  make_model "${tmp}/home" "Org/Model-Readme" '{ "model_type":"qwen3", "architectures":["Qwen3MoeForCausalLM"],
    "max_position_embeddings":262144, "num_experts":128,
    "quantization_config":{"quant_method":"modelopt"} }'
  dir="${tmp}/home/.cache/huggingface/hub/models--Org--Model-Readme/snapshots/1"
  cat > "${dir}/README.md" <<'EOF'
# Test

Use the official `vllm/vllm-openai:nightly` container.

vllm serve Org/Model-Readme --port 8000 --quantization modelopt --max-model-len 262144

For NVIDIA DGX Spark, we recommend using this `vllm serve` command:

```sh
vllm serve Org/Model-Readme \
  --host 0.0.0.0 \
  --port 8000 \
  --trust-remote-code \
  --kv-cache-dtype fp8 \
  --attention-backend flashinfer \
  --moe-backend marlin \
  --max-model-len 262144 \
  --max-num-seqs 4 \
  --max-num-batched-tokens 8192 \
  --enable-chunked-prefill \
  --async-scheduling \
  --enable-prefix-caching \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3,"moe_backend":"triton"}' \
  --load-format fastsafetensors
```
EOF
  cmd=$(python3 -S "${ROOT_DIR}/scripts/hf_model_inspect.py" --model-id Org/Model-Readme \
    --local-path "$dir" --local-files-only | jq -r '.card.recommended_command')
  image=$(python3 -S "${ROOT_DIR}/scripts/hf_model_inspect.py" --model-id Org/Model-Readme \
    --local-path "$dir" --local-files-only | jq -r '.card.recommended_image')
  rm -rf "$tmp"
  [[ "$cmd" == *"--attention-backend flashinfer"* ]] &&
    [[ "$cmd" == *"--speculative-config '{\"method\":\"mtp\",\"num_speculative_tokens\":3,\"moe_backend\":\"triton\"}'"* ]] &&
    [[ "$image" == "vllm/vllm-openai:nightly" ]]
}

test_hf_inspector_tools_requires_tool_calling_signal() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  command -v python3 >/dev/null 2>&1 || { printf "skip - python3 not installed\n"; return 0; }
  local tmp dir generic explicit
  tmp=$(mktemp -d)
  make_model "${tmp}/home" "Org/Model-Tools" '{ "model_type":"qwen3", "architectures":["Qwen3ForCausalLM"],
    "max_position_embeddings":32768 }'
  dir="${tmp}/home/.cache/huggingface/hub/models--Org--Model-Tools/snapshots/1"
  printf '# Test\n\nUseful developer tools and examples.\n' > "${dir}/README.md"
  generic=$(python3 -S "${ROOT_DIR}/scripts/hf_model_inspect.py" --model-id Org/Model-Tools \
    --local-path "$dir" --local-files-only | jq -r '.features.supports_tools')
  printf '# Test\n\nSupports tool calling with <tool_call> blocks.\n' > "${dir}/README.md"
  explicit=$(python3 -S "${ROOT_DIR}/scripts/hf_model_inspect.py" --model-id Org/Model-Tools \
    --local-path "$dir" --local-files-only | jq -r '.features.supports_tools')
  rm -rf "$tmp"
  [[ "$generic" == "false" ]] && [[ "$explicit" == "true" ]]
}

test_qwen35_uses_qwen3_coder_tool_parser() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Qwen35" '{ "model_type":"qwen3_5", "architectures":["Qwen3_5ForConditionalGeneration"], "max_position_embeddings":262144 }'
  meta=$(hf_inspect_json false false 262144 true dense nvfp4 \
    "vllm serve Org/Qwen35 --quantization modelopt" "vllm/vllm-openai:nightly" \
    | jq '.raw.model_type="qwen3_5" | .raw.architectures=["Qwen3_5ForConditionalGeneration"]')
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="vllm/vllm-openai:nightly" \
    "$SPARK" run Org/Qwen35 --dry-run --tools --no-mtp </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"--enable-auto-tool-choice --tool-call-parser qwen3_coder"* ]] &&
    [[ "$out" != *"--tool-call-parser qwen3_xml"* ]]
}

test_gemma4_uses_gemma4_tool_and_reasoning_parsers() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Gemma4" '{ "model_type":"gemma4", "architectures":["Gemma4ForConditionalGeneration"], "max_position_embeddings":262144 }'
  meta=$(hf_inspect_json false true 262144 true moe nvfp4 \
    "vllm serve Org/Gemma4 --quantization modelopt" "vllm/vllm-openai:nightly" \
    | jq '.raw.model_type="gemma4" | .raw.architectures=["Gemma4ForConditionalGeneration"] | .features.is_multimodal=true')
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="vllm/vllm-openai:nightly" \
    "$SPARK" run Org/Gemma4 --dry-run --tools --no-mtp </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"--reasoning-parser gemma4"* ]] &&
    [[ "$out" == *"--enable-auto-tool-choice --tool-call-parser gemma4"* ]] &&
    [[ "$out" != *"--attention-backend flashinfer"* ]]
}

test_text_only_uses_vllm_json_multimodal_limit() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Vision" '{ "model_type":"gemma4", "architectures":["Gemma4ForConditionalGeneration"], "max_position_embeddings":262144 }'
  meta=$(hf_inspect_json false true 262144 true moe nvfp4 \
    "vllm serve Org/Vision --quantization modelopt" "vllm/vllm-openai:nightly" \
    | jq '.raw.model_type="gemma4" | .raw.architectures=["Gemma4ForConditionalGeneration"] | .features.is_multimodal=true')
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="vllm/vllm-openai:nightly" \
    "$SPARK" run Org/Vision --dry-run --text-only --no-mtp --max-len 3072 </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *'--limit-mm-per-prompt \{\"image\":0\}'* ]] &&
    [[ "$out" == *"--max-num-batched-tokens 3072"* ]]
}

test_hf_card_context_wins() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Long" "$KV_CONFIG"
  meta=$(hf_inspect_json false false 262144 false dense nvfp4)
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Long --dry-run </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"--max-model-len 262144"* ]] && [[ "$out" == *"--max-num-batched-tokens 32768"* ]]
}

test_hf_mtp_auto_enables_when_supported() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin with_mtp without_mtp meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/MTP" "$KV_CONFIG"
  meta=$(hf_inspect_json true false null false dense nvfp4)
  with_mtp=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/MTP --dry-run --explain </dev/null 2>&1 || true)
  rm -f "${tmp}/home/.config/spark/profiles/Org--MTP.json"
  meta=$(hf_inspect_json false false null false dense nvfp4)
  without_mtp=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/MTP --dry-run --explain </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$with_mtp" == *"--speculative-config"* ]] &&
    [[ "$with_mtp" == *"MTP: auto-enable"* ]] &&
    [[ "$without_mtp" != *"--speculative-config"* ]] &&
    [[ "$without_mtp" != *"MTP: auto-enable"* ]]
}

test_hf_mtp_raises_memory_floor() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/MTPMem" "$KV_CONFIG"
  meta=$(hf_inspect_json true false 262144 false moe nvfp4)
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/MTPMem --dry-run </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"--speculative-config"* ]] &&
    [[ "$out" == *"--gpu-memory-utilization 0.65"* ]]
}

test_hf_stream_interval_from_recommended_command() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Stream" "$KV_CONFIG"
  meta=$(hf_inspect_json true false 262144 false moe nvfp4 \
    "vllm serve Org/Stream --load-format fastsafetensors --stream-interval 32 --speculative-config '{\"method\":\"mtp\",\"num_speculative_tokens\":3,\"moe_backend\":\"triton\"}'")
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    MTP_ENABLED=1 "$SPARK" run Org/Stream --dry-run </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"--stream-interval 32"* ]]
}

test_hf_quantization_from_recommended_command() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Quant" "$KV_CONFIG"
  meta=$(hf_inspect_json false false 32768 false dense nvfp4 \
    "vllm serve Org/Quant --quantization modelopt --max-model-len 32768")
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Quant --dry-run --no-mtp </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"--quantization modelopt"* ]]
}

test_hf_recommended_official_image_entrypoint() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Official" "$KV_CONFIG"
  meta=$(hf_inspect_json false false 32768 false dense nvfp4 \
    "vllm serve Org/Official --quantization modelopt" "vllm/vllm-openai:nightly")
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" \
    FAKE_DOCKER_IMAGE=$'vllm/vllm-openai:nightly\nnvcr.io/nvidia/vllm:26.05-py3' \
    "$SPARK" run Org/Official --dry-run --no-mtp </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"-e USER=spark -e LOGNAME=spark"* ]] &&
    [[ "$out" == *"vllm/vllm-openai:nightly Org/Official"* ]] &&
    [[ "$out" != *"vllm/vllm-openai:nightly vllm serve"* ]]
}

test_hf_recommended_image_falls_back_to_local_readme() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out meta model_dir
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/ReadmeImage" "$KV_CONFIG"
  model_dir="${tmp}/home/.cache/huggingface/hub/models--Org--ReadmeImage/snapshots/1"
  printf 'Use docker image `vllm/vllm-openai:nightly`.\n' > "${model_dir}/README.md"
  meta=$(hf_inspect_json false false 32768 false dense nvfp4 \
    "vllm serve Org/ReadmeImage --quantization modelopt")
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" \
    FAKE_DOCKER_IMAGE=$'vllm/vllm-openai:nightly\nnvcr.io/nvidia/vllm:26.05-py3' \
    "$SPARK" run Org/ReadmeImage --dry-run --no-mtp </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"vllm/vllm-openai:nightly Org/ReadmeImage"* ]]
}

test_mtp_batched_tokens_overrides_recommended_command() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/MTPBatch" "$KV_CONFIG"
  meta=$(hf_inspect_json true false 262144 false moe nvfp4 \
    "vllm serve Org/MTPBatch --load-format fastsafetensors --max-num-batched-tokens 8192 --speculative-config '{\"method\":\"mtp\",\"num_speculative_tokens\":3,\"moe_backend\":\"triton\"}'")
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    MTP_ENABLED=1 "$SPARK" run Org/MTPBatch --dry-run </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"--max-num-batched-tokens 32768"* ]] &&
    [[ "$out" != *"--max-num-batched-tokens 8192"* ]]
}

test_blackwell_single_stream_mtp_uses_flashinfer_cutlass_and_stream64() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Blackwell" "$MOE_CONFIG"
  meta=$(hf_inspect_json true false 262144 false moe nvfp4)
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_ACCEL=cuda-unified FAKE_NVIDIA_SMI_EXIT=0 FAKE_COMPUTE_CAP=12.1 FAKE_GPU_NAME="NVIDIA GB10" \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    MTP_ENABLED=1 "$SPARK" run Org/Blackwell --dry-run --max-num-seqs 1 </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"--stream-interval 64"* ]] &&
    [[ "$out" == *"flashinfer_cutlass"* ]]
}

test_hf_mtp_launch_sets_batched_tokens() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/MTP" "$KV_CONFIG"
  meta=$(hf_inspect_json true true null false dense nvfp4)
  printf 'n\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_ASSUME_INTERACTIVE=1 SPARK_HF_MODEL_INSPECT_JSON="$meta" \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.05-py3" FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" \
    "$SPARK" run Org/MTP --no-wait >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"--speculative-config"* ]] && [[ "$dargs" == *"--max-num-batched-tokens 32768"* ]]
}

test_hf_kv_fp8_question_and_recommendation() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin ask auto meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/KV" "$KV_CONFIG"
  meta=$(hf_inspect_json false false null false dense nvfp4)
  ask=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/KV --dry-run --explain </dev/null 2>&1 || true)
  rm -f "${tmp}/home/.config/spark/profiles/Org--KV.json"
  meta=$(hf_inspect_json false true null false dense nvfp4)
  auto=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/KV --dry-run --explain </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$ask" == *"KV cache FP8: ask"* ]] &&
    [[ "$auto" == *"KV cache FP8: ask, default no (card recommends)"* ]] &&
    [[ "$auto" != *"--kv-cache-dtype fp8"* ]]
}

test_kv_fp8_override_does_not_persist_to_profile() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out saved
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/KVOverride" "$KV_CONFIG"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/KVOverride --dry-run --kv-cache-dtype fp8 </dev/null 2>&1 || true)
  saved=$(jq -r '.kv_cache_dtype // ""' "${tmp}/home/.config/spark/profiles/Org--KVOverride.json" 2>/dev/null || true)
  rm -rf "$tmp"
  [[ "$out" == *"--kv-cache-dtype fp8"* ]] && [[ "$saved" == "auto" ]]
}

test_dry_run_explain_shows_hf_and_flags() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out meta status=0
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Explain" "$KV_CONFIG"
  meta=$(hf_inspect_json false false null true dense nvfp4)
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    ALIAS_VLLM_IMAGE_ID="--privileged" ALIAS_VLLM_ENV_JSON='{"EVIL":"1"}' \
    ALIAS_VLLM_ARGS_JSON='["vllm","serve","Evil/Model"]' \
    "$SPARK" run Org/Explain --explain </dev/null 2>&1) || status=$?
  rm -rf "$tmp"
  [[ "$status" == "0" ]] && [[ "$out" == *"Explain"* ]] && [[ "$out" == *"HF:"* ]] && \
    [[ "$out" == *"Features:"* ]] && [[ "$out" == *"vLLM:"* ]] && \
    [[ "$out" == *"--load-format fastsafetensors"* ]] && [[ "$out" == *"Tool calling: ask"* ]] && \
    [[ "$out" == *"Docker command that would be executed"* ]] && \
    [[ "$out" != *"--privileged"* && "$out" != *"EVIL=1"* && "$out" != *"Evil/Model"* ]]
}

test_hf_metadata_cli_overrides_win() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Override" "$KV_CONFIG"
  meta=$(hf_inspect_json false true 262144 false dense nvfp4)
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Org/Override --dry-run --max-len 4096 --kv-cache-dtype auto </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"--max-model-len 4096"* ]] && [[ "$out" != *"--kv-cache-dtype fp8"* ]]
}

test_calibrate_dry_run_lists_candidates() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out meta
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Calibrate" "$MOE_CONFIG"
  meta=$(hf_inspect_json true false 262144 false moe nvfp4)
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.05-py3" \
    "$SPARK" calibrate Org/Calibrate --dry-run </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"Calibration candidates"* ]] &&
    [[ "$out" == *"baseline"* ]] &&
    [[ "$out" == *"mtp-"* ]] &&
    [[ "$out" == *"KV auto"* ]]
}

test_calibrate_saves_best_and_run_uses_it() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out run meta pf saved
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Calibrate" "$MOE_CONFIG"
  meta=$(hf_inspect_json true false 262144 false moe nvfp4)
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    SPARK_HF_MODEL_INSPECT_JSON="$meta" SPARK_CALIBRATE_FAKE_TPS="10 20 30 40 50" \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.05-py3" "$SPARK" calibrate Org/Calibrate --passes 1 --force </dev/null 2>&1 || true)
  pf="${tmp}/home/.config/spark/profiles/Org--Calibrate.json"
  saved=$(jq -r '.calibration.best.tokens_per_second // empty' "$pf" 2>/dev/null || true)
  run=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.05-py3" "$SPARK" run Org/Calibrate --dry-run --explain </dev/null 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"Calibration saved: 50"* ]] &&
    [[ "$saved" == "50" ]] &&
    [[ "$run" == *"Calib:"* ]] &&
    [[ "$run" == *"--max-num-seqs 1"* ]] &&
    [[ "$run" == *"--speculative-config"* ]] &&
    [[ "$run" == *"--stream-interval 64"* ]]
}

# A cached profile from an older spark (no schema_version, missing fields like is_moe) is refreshed
# automatically on the next run — so decisions that depend on the new fields work without user action.
test_profile_schema_autoregen() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out pf sv
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  pf="${tmp}/home/.config/spark/profiles/Qwen--Qwen3-30B.json"
  mkdir -p "$(dirname "$pf")"
  # Stale profile: no schema_version, no is_moe (pre-MoE-detection schema).
  printf '%s\n' '{"model":"Qwen/Qwen3-30B","max_model_len":4096,"gpu_memory_utilization":"0.5","weights_gb":"10","kv_gb":"1","need_gb":"11","kv_cache_dtype":"auto","is_multimodal":false}' > "$pf"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" "$SPARK" run Qwen/Qwen3-30B --dry-run </dev/null 2>&1 || true)
  sv=$(jq -r '.schema_version // "none"' "$pf" 2>/dev/null || echo none)
  rm -rf "$tmp"
  [[ "$out" == *"Refreshing model profile"* ]] && [[ "$sv" == "8" ]]
}

# CUDA-graph calibration over the two-column peak table: eager peak on record + no graph peak →
# calibrate (try graphs); graph peak "oom" → stay eager; numeric graph peak → use graphs. Verified
# via the dry-run launch command (--enforce-eager present or not).
# $3=eager_peak_gb (or ""), $4=cudagraph_peak_gb (number / "oom" / "")
_write_cal_profile() {
  local pf
  pf="$1/.config/spark/profiles/$(printf '%s' "$2" | sed 's,/,--,g').json"
  mkdir -p "$(dirname "$pf")"
  jq -n --arg m "$2" --arg ep "$3" --arg cp "$4" '{
    schema_version:8, model:$m, generated:"2026-01-01", reasoning_parser:"", tool_call_parser:"",
    gpu_memory_utilization:"0.2", max_model_len:8192, is_multimodal:false, is_moe:"1",
    model_size_gb:"10", weights_gb:"10", kv_gb:"1", need_gb:"11", kv_cache_dtype:"auto",
    warmup: {"8192/auto": ({date:"2026-01-01"}
      + (if $ep != "" then {eager_peak_gb: $ep} else {} end)
      + (if $cp != "" then {cudagraph_peak_gb: $cp} else {} end))}
  }' > "$pf"
}
# Legacy single-peak entry (pre-two-column), to verify migration-on-read.
# $3=peak_gb $4=enforce_eager $5=cudagraph_oom
_write_legacy_cal_profile() {
  local pf
  pf="$1/.config/spark/profiles/$(printf '%s' "$2" | sed 's,/,--,g').json"
  mkdir -p "$(dirname "$pf")"
  jq -n --arg m "$2" --arg p "$3" --arg e "$4" --arg c "$5" '{
    schema_version:8, model:$m, generated:"2026-01-01", reasoning_parser:"", tool_call_parser:"",
    gpu_memory_utilization:"0.2", max_model_len:8192, is_multimodal:false, is_moe:"1",
    model_size_gb:"10", weights_gb:"10", kv_gb:"1", need_gb:"11", kv_cache_dtype:"auto",
    warmup: {"8192/auto": {peak_gb:$p, enforce_eager:$e, cudagraph_oom:$c, date:"2026-01-01"}}
  }' > "$pf"
}
_cal_dry() {  # $1=home $2=fake_bin — run dry-run, echo output
  HOME="$1" PATH="$2:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" "$SPARK" run Org/Cal --dry-run </dev/null 2>&1 || true
}
test_cudagraph_calibration() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin cal oom fit
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Cal" "$KV_CONFIG"
  _write_cal_profile "${tmp}/home" "Org/Cal" "15" ""      # eager peak only → calibrate
  cal=$(_cal_dry "${tmp}/home" "$fake_bin")
  _write_cal_profile "${tmp}/home" "Org/Cal" "15" "oom"   # graphs OOMed → stay eager
  oom=$(_cal_dry "${tmp}/home" "$fake_bin")
  _write_cal_profile "${tmp}/home" "Org/Cal" "" "20"      # graphs fit → use graphs
  fit=$(_cal_dry "${tmp}/home" "$fake_bin")
  rm -rf "$tmp"
  local cal_cmd oom_cmd fit_cmd
  cal_cmd=$(printf '%s\n' "$cal" | grep 'vllm serve' || true)
  oom_cmd=$(printf '%s\n' "$oom" | grep 'vllm serve' || true)
  fit_cmd=$(printf '%s\n' "$fit" | grep 'vllm serve' || true)
  [[ "$cal_cmd" != *"--enforce-eager"* ]] && [[ "$cal" == *"Calibrating"* ]] &&
    [[ "$oom_cmd" == *"--enforce-eager"* ]] && [[ "$fit_cmd" != *"--enforce-eager"* ]]
}
test_warmup_legacy_migration() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin cal oom fit
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Cal" "$KV_CONFIG"
  _write_legacy_cal_profile "${tmp}/home" "Org/Cal" "15" "1" "0"   # legacy eager, graphs untried → calibrate
  cal=$(_cal_dry "${tmp}/home" "$fake_bin")
  _write_legacy_cal_profile "${tmp}/home" "Org/Cal" "15" "1" "1"   # legacy eager + cudagraph_oom → eager
  oom=$(_cal_dry "${tmp}/home" "$fake_bin")
  _write_legacy_cal_profile "${tmp}/home" "Org/Cal" "20" "0" "0"   # legacy graphs-worked → use graphs
  fit=$(_cal_dry "${tmp}/home" "$fake_bin")
  rm -rf "$tmp"
  local cal_cmd oom_cmd fit_cmd
  cal_cmd=$(printf '%s\n' "$cal" | grep 'vllm serve' || true)
  oom_cmd=$(printf '%s\n' "$oom" | grep 'vllm serve' || true)
  fit_cmd=$(printf '%s\n' "$fit" | grep 'vllm serve' || true)
  [[ "$cal_cmd" != *"--enforce-eager"* ]] && [[ "$cal" == *"Calibrating"* ]] &&
    [[ "$oom_cmd" == *"--enforce-eager"* ]] && [[ "$fit_cmd" != *"--enforce-eager"* ]]
}

# --- Admission budget (TOTAL − OS reserve) ---
# Admission budget = TOTAL − OS_RESERVE (unified default 7 → 114 GB). 30B need 28 + reserved 90 =
# 118 > 114 → blocked by the budget. Proves the budget binds when stacking models.
test_budget_blocks_when_stacking() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED='spark-vllm-big\torg/big\t8000\t90.0\t75.0\t15.0\n' \
    "$SPARK" run Qwen/Qwen3-30B --dry-run --max-len 262144 </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] && [[ "$out" == *"Not enough memory"* ]] && [[ "$out" == *"OS-reserved"* ]]
}

# The budget applies to a single model too: --mem 0.97 (117.4 GB) exceeds the budget (114) and is
# blocked, suggesting the largest --mem that fits.
test_budget_blocks_single_model() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    "$SPARK" run Qwen/Qwen3-30B --mem 0.97 --dry-run </dev/null 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] && [[ "$out" == *"Not enough memory"* ]] && [[ "$out" == *"Fits with --mem"* ]]
}

# Discrete GPUs get a smaller OS reserve (2 → budget 119): the full-context stacking case fits.
test_budget_larger_on_discrete() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-discrete \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED='spark-vllm-big\torg/big\t8000\t75.0\t60.0\t15.0\n' \
    "$SPARK" run Qwen/Qwen3-30B --dry-run --max-len 262144 </dev/null 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"vllm serve"* ]] && [[ "$out" != *"Not enough memory"* ]]
}

# --- Command coverage: spark's own logic per command (not the external tools) ---
test_pull_vllm_ready() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm "$SPARK" pull Org/Model </dev/null 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"Ready. Run: spark run Org/Model"* ]]
}

test_pull_ollama_routes() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama "$SPARK" pull qwen3:30b </dev/null 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"with Ollama"* ]] && [[ "$out" == *"Ready"* ]]
}

test_list_shows_models() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.cache/huggingface/hub/models--Org--Alpha/snapshots/1"
  mkdir -p "${tmp}/home/.cache/huggingface/hub/models--Org--Beta/snapshots/1"
  : > "${tmp}/home/.cache/huggingface/hub/models--Org--Alpha/snapshots/1/model.safetensors"
  : > "${tmp}/home/.cache/huggingface/hub/models--Org--Beta/snapshots/1/model.safetensors"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" list 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"MODEL"* ]] && [[ "$out" == *"STATUS"* ]] &&
    [[ "$out" == *"Org/Alpha"* ]] && [[ "$out" == *"Org/Beta"* ]] &&
    [[ "$out" == *"complete"* ]]
}

test_list_marks_partial_models() {
  local tmp fake_bin out dir
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  dir="${tmp}/home/.cache/huggingface/hub/models--Org--Partial"
  mkdir -p "${dir}/snapshots/1" "${dir}/blobs"
  : > "${dir}/snapshots/1/config.json"
  : > "${dir}/blobs/weights.incomplete"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" list 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"Org/Partial"* ]] && [[ "$out" == *"partial"* ]]
}

test_list_ignores_stale_incomplete_blobs() {
  local tmp fake_bin out dir
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  dir="${tmp}/home/.cache/huggingface/hub/models--Org--Complete"
  mkdir -p "${dir}/snapshots/1" "${dir}/blobs"
  : > "${dir}/snapshots/1/config.json"
  : > "${dir}/snapshots/1/model.safetensors"
  : > "${dir}/blobs/old-download.incomplete"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" list 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"Org/Complete"* ]] && [[ "$out" == *"complete"* ]] && [[ "$out" != *"partial"* ]]
}

test_list_empty() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" list 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"No models downloaded"* ]]
}

test_rm_removes_the_right_dir() {
  local tmp fake_bin out d
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  d="${tmp}/home/.cache/huggingface/hub/models--Org--Gone"; mkdir -p "${d}/snapshots/1"
  out=$(printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ASSUME_INTERACTIVE=1 "$SPARK" rm Org/Gone 2>&1)
  local gone=1; [[ -d "$d" ]] && gone=0
  rm -rf "$tmp"
  [[ "$out" == *"Removed Org/Gone"* ]] && [[ "$gone" -eq 1 ]]
}

test_rm_removes_multiple_models() {
  local tmp fake_bin out a b
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  a="${tmp}/home/.cache/huggingface/hub/models--Org--A"; mkdir -p "${a}/snapshots/1"
  b="${tmp}/home/.cache/huggingface/hub/models--Org--B"; mkdir -p "${b}/snapshots/1"
  out=$(printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ASSUME_INTERACTIVE=1 "$SPARK" rm Org/A Org/B 2>&1)
  local gone=1; { [[ -d "$a" ]] || [[ -d "$b" ]]; } && gone=0
  rm -rf "$tmp"
  [[ "$out" == *"Remove 2 models"* ]] && [[ "$out" == *"Removed Org/A"* ]] && [[ "$out" == *"Removed Org/B"* ]] && [[ "$gone" -eq 1 ]]
}

test_rm_missing_model_deletes_none() {
  local tmp fake_bin out a status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  a="${tmp}/home/.cache/huggingface/hub/models--Org--A"; mkdir -p "${a}/snapshots/1"
  out=$(printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ASSUME_INTERACTIVE=1 "$SPARK" rm Org/A Org/Missing 2>&1) && status=0 || status=$?
  local still_exists=0; [[ -d "$a" ]] && still_exists=1
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] && [[ "$out" == *"Model 'Org/Missing' not found"* ]] && [[ "$out" != *"Removed Org/A"* ]] && [[ "$still_exists" -eq 1 ]]
}

test_rm_reports_delete_failure() {
  local tmp fake_bin out d hub status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  hub="${tmp}/home/.cache/huggingface/hub"
  d="${hub}/models--Org--Stuck"; mkdir -p "${d}/snapshots/1"
  chmod a-w "$hub"
  out=$(printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ASSUME_INTERACTIVE=1 "$SPARK" rm Org/Stuck 2>&1) && status=0 || status=$?
  chmod u+w "$hub"
  local still_exists=0; [[ -d "$d" ]] && still_exists=1
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] && [[ "$out" == *"Failed to remove Org/Stuck"* ]] && [[ "$out" != *"Removed Org/Stuck"* ]] && [[ "$still_exists" -eq 1 ]]
}

test_rm_not_found() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" rm Org/Missing </dev/null 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"not found in cache"* ]]
}

test_logs_ollama_message() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama "$SPARK" logs 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"shared service"* ]] && [[ "$out" == *"journalctl"* ]]
}

test_logs_vllm_no_container() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm "$SPARK" logs Org/Model </dev/null 2>&1) || true
  rm -rf "$tmp"
  [[ "$out" == *"No container found"* ]]
}

test_config_set_and_show() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin set_out show_out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  set_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" config auto-update on 2>&1)
  show_out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" config 2>&1)
  rm -rf "$tmp"
  [[ "$set_out" == *"Auto-update enabled"* ]] && [[ "$show_out" == *"auto-update: true"* ]]
}

test_update_check_accepts_zero_padded_month() {
  local tmp fake_bin out status
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  cat > "${fake_bin}/date" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  +%F) printf '2026-08-24\n' ;;
  +%y) printf '26\n' ;;
  +%m) printf '08\n' ;;
  *) /bin/date "$@" ;;
esac
EOF
  chmod +x "${fake_bin}/date"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    SPARK_VLLM_IMAGE="nvcr.io/nvidia/vllm:26.07-py3" \
    "$SPARK" config 2>&1) && status=0 || status=$?
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] && [[ "$out" == *"Configuration:"* ]] &&
    [[ "$out" != *"invalid octal number"* ]]
}

test_update_prompts_workspace_tool_updates_one_by_one() {
  local tmp fake_bin out current_tag compose_log nemo_log
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  current_tag="$(date +%y.%m)-py3"
  mkdir -p "${tmp}/home/.config/spark/workspace"
  cat > "${tmp}/home/.config/spark/workspace/secrets.env" <<ENV
WORKSPACE_POSTGRES_IMAGE=postgres:17
WORKSPACE_VIKUNJA_IMAGE=vikunja/vikunja:latest
WORKSPACE_N8N_IMAGE=docker.n8n.io/n8nio/n8n:latest
HERMES_MODEL=Org/Alpha
HERMES_LITELLM_MODEL=vllm/Org/Alpha
HERMES_CONTEXT_LENGTH=65536
HERMES_MAX_TOKENS=512
HERMES_REASONING_EFFORT=none
HERMES_LITELLM_BASE_URL=http://127.0.0.1:4000/v1
HERMES_DASHBOARD_PORT=18789
HERMES_POLICY_TIER=restricted
HERMES_URL=https://hermes.test-tailnet.ts.net
ENV
  : > "${tmp}/home/.config/spark/workspace/docker-compose.yml"
  cat > "${fake_bin}/curl" <<EOF
#!/usr/bin/env bash
printf 'VERSION="%s"\\n' "$SPARK_VERSION"
EOF
  chmod +x "${fake_bin}/curl"
  out=$(printf 'y\ny\ny\ny\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:${current_tag}" \
    FAKE_COMPOSE_FILE="${tmp}/compose.log" \
    FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_NEMOHERMES_UPDATE_CHECK=$'Current NemoHermes version: 0.0.55\nLatest maintained version: 0.0.78\nUpdate available:         yes' \
    "$SPARK" update 2>&1)
  compose_log=$(cat "${tmp}/compose.log" 2>/dev/null || echo "")
  nemo_log=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"Available update actions:"* ]] &&
    [[ "$out" == *"Postgres image: postgres:17"* ]] &&
    [[ "$out" == *"Vikunja image: vikunja/vikunja:latest"* ]] &&
    [[ "$out" == *"n8n image: docker.n8n.io/n8nio/n8n:latest"* ]] &&
    [[ "$out" == *"NemoHermes:"* ]] &&
    [[ "$out" != *"Tailscale self-update check"* ]] &&
    [[ "$compose_log" == *"pull postgres"* ]] &&
    [[ "$compose_log" == *"pull vikunja"* ]] &&
    [[ "$compose_log" == *"pull n8n"* ]] &&
    [[ "$compose_log" == *"up -d --remove-orphans"* ]] &&
    [[ "$nemo_log" == *"hermes rebuild"* ]] &&
    [[ "$nemo_log" == *"NEMOCLAW_ENDPOINT_URL=http://host.openshell.internal:4000/v1"* ]] &&
    [[ "$nemo_log" == *"NEMOCLAW_MODEL=vllm/Org/Alpha"* ]] &&
    [[ "$nemo_log" == *"NEMOCLAW_NO_GPU=1"* ]] &&
    [[ "$nemo_log" == *"NEMOCLAW_SANDBOX_GPU=0"* ]] &&
    [[ "$nemo_log" == *"COMPATIBLE_API_KEY=dummy"* ]]
}

test_update_skips_images_already_at_remote_digest() {
  local tmp fake_bin out compose_log digest
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  mkdir -p "${tmp}/home/.config/spark/workspace"
  printf '%s\n' \
    'WORKSPACE_TASK_MANAGER=vikunja' \
    'WORKSPACE_POSTGRES_IMAGE=postgres:18' \
    'WORKSPACE_VIKUNJA_IMAGE=vikunja/vikunja:latest' \
    'WORKSPACE_N8N_IMAGE=docker.n8n.io/n8nio/n8n:latest' \
    > "${tmp}/home/.config/spark/workspace/secrets.env"
  : > "${tmp}/home/.config/spark/workspace/docker-compose.yml"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_DOCKER_LOCAL_DIGEST="$digest" FAKE_DOCKER_REMOTE_DIGEST="$digest" \
    FAKE_COMPOSE_FILE="${tmp}/compose.log" "$SPARK" update --postgresql --task-manager --n8n 2>&1)
  compose_log=$(cat "${tmp}/compose.log" 2>/dev/null || true)
  rm -rf "$tmp"
  [[ "$out" == *"Postgres image is up to date"* ]] &&
    [[ "$out" == *"Vikunja image is up to date"* ]] &&
    [[ "$out" == *"n8n image is up to date"* ]] &&
    [[ "$out" == *$'Available update actions:\n    none'* ]] &&
    [[ "$compose_log" != *"pull"* ]]
}

test_update_parses_human_buildx_digest_output() {
  local tmp fake_bin out digest remote_output
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  remote_output=$'Name: docker.io/library/postgres:17\nMediaType: application/vnd.oci.image.index.v1+json\nDigest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  mkdir -p "${tmp}/home/.config/spark/workspace"
  printf '%s\n' \
    'WORKSPACE_TASK_MANAGER=todoist' \
    'WORKSPACE_POSTGRES_IMAGE=postgres:17' \
    > "${tmp}/home/.config/spark/workspace/secrets.env"
  : > "${tmp}/home/.config/spark/workspace/docker-compose.yml"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_DOCKER_LOCAL_DIGEST="$digest" FAKE_DOCKER_REMOTE_OUTPUT="$remote_output" \
    "$SPARK" update --postgresql 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"Postgres image is up to date (postgres:17)"* ]] &&
    [[ "$out" != *"Could not check latest Postgres image"* ]]
}

test_update_uses_supported_nemohermes_check_command() {
  local tmp fake_bin out nemo_log
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  nemo_log="${tmp}/nemohermes.log"
  out=$(printf 'n\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_NEMOHERMES_FILE="$nemo_log" \
    FAKE_NEMOHERMES_UPDATE_CHECK=$'Current NemoHermes version: 0.0.55\nLatest maintained version: 0.0.78\nUpdate available:         yes' \
    "$SPARK" update --nemohermes 2>&1)
  [[ -n "$out" ]]
  grep -qx 'update --check' "$nemo_log"
  local status=$?
  rm -rf "$tmp"
  return "$status"
}

test_update_checks_active_super_productivity_release() {
  local tmp fake_bin out curl_log
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  curl_log="${tmp}/curl.log"
  mkdir -p "${tmp}/home/.config/spark/workspace"
  printf '%s\n' \
    'WORKSPACE_TASK_MANAGER=super-productivity' \
    'WORKSPACE_SUPER_PRODUCTIVITY_VERSION=v18.15.1' \
    'WORKSPACE_SUPERSYNC_IMAGE=spark/supersync:18.15.1' \
    > "${tmp}/home/.config/spark/workspace/secrets.env"
  : > "${tmp}/home/.config/spark/workspace/docker-compose.yml"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$FAKE_CURL_FILE"\nprintf '\''{"tag_name":"v18.16.0"}\\n'\''\n' > "${fake_bin}/curl"
  chmod +x "${fake_bin}/curl"
  out=$(printf 'n\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_CURL_FILE="$curl_log" \
    "$SPARK" update --task-manager 2>&1)
  [[ "$out" == *"Super Productivity: v18.15.1 → v18.16.0"* ]] &&
    grep -q 'super-productivity/super-productivity/releases/latest' "$curl_log"
  local status=$?
  rm -rf "$tmp"
  return "$status"
}

test_update_rebuilds_active_super_productivity_release() {
  local tmp log status calls
  tmp=$(mktemp -d)
  mkdir -p "${tmp}/home/.config/spark/workspace"
  printf '%s\n' \
    'HERMES_MODEL=Org/Alpha' \
    'N8N_OWNER_FIRST_NAME=massimo' \
    'SUPER_PRODUCTIVITY_USER_EMAIL=m@example.com' \
    'N8N_BASIC_AUTH_USER=m@example.com' \
    > "${tmp}/home/.config/spark/workspace/secrets.env"
  log="${tmp}/calls"
  HOME="${tmp}/home" SPARK_OS_OVERRIDE=Linux SPARK_ARCH_OVERRIDE=aarch64 \
    SPARK_ACCEL=cpu SPARK_BACKEND=ollama SPARK_TEST_LOG="$log" bash -c '
      source "$1"
      workspace_setup() {
        printf "version=%s\nsync=%s\nelectron=%s\nargs=%s\n" \
          "$SPARK_WORKSPACE_SUPER_PRODUCTIVITY_VERSION" \
          "$SPARK_WORKSPACE_SUPERSYNC_IMAGE" \
          "$SPARK_WORKSPACE_SUPER_PRODUCTIVITY_ELECTRON_IMAGE" "$*" \
          > "$SPARK_TEST_LOG"
      }
      workspace_update_super_productivity_release v18.16.0
    ' _ "$SPARK"
  status=$?
  calls=$(cat "$log" 2>/dev/null || true)
  rm -rf "$tmp"
  [[ "$status" -eq 0 ]] &&
    [[ "$calls" == *"version=v18.16.0"* ]] &&
    [[ "$calls" == *"sync=spark/supersync:18.16.0"* ]] &&
    [[ "$calls" == *"electron=spark/super-productivity-electron:18.16.0"* ]] &&
    [[ "$calls" == *"args=--yes --task-manager super-productivity --model Org/Alpha"* ]]
}

test_update_flags_limit_checks_and_actions() {
  local tmp fake_bin out compose_log old_digest new_digest
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  old_digest="sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  new_digest="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  mkdir -p "${tmp}/home/.config/spark/workspace"
  printf '%s\n' \
    'WORKSPACE_TASK_MANAGER=vikunja' \
    'WORKSPACE_POSTGRES_IMAGE=postgres:18' \
    'WORKSPACE_VIKUNJA_IMAGE=vikunja/vikunja:latest' \
    'WORKSPACE_N8N_IMAGE=docker.n8n.io/n8nio/n8n:latest' \
    > "${tmp}/home/.config/spark/workspace/secrets.env"
  : > "${tmp}/home/.config/spark/workspace/docker-compose.yml"
  out=$(printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_DOCKER_LOCAL_DIGEST="$old_digest" FAKE_DOCKER_REMOTE_DIGEST="$new_digest" \
    FAKE_COMPOSE_FILE="${tmp}/compose.log" "$SPARK" update --postgresql 2>&1)
  compose_log=$(cat "${tmp}/compose.log" 2>/dev/null || true)
  rm -rf "$tmp"
  [[ "$out" == *"Postgres image: postgres:18"* ]] &&
    [[ "$out" != *"Vikunja image:"* ]] &&
    [[ "$out" != *"n8n image:"* ]] &&
    [[ "$out" != *"NemoHermes"* ]] &&
    [[ "$compose_log" == *"pull postgres"* ]] &&
    [[ "$compose_log" != *"pull vikunja"* ]] &&
    [[ "$compose_log" != *"pull n8n"* ]]
}

test_update_solo_alias_checks_only_spark() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  printf '#!/usr/bin/env bash\nprintf '\''VERSION="99.0.0"\\n'\''\n' > "${fake_bin}/curl"
  chmod +x "${fake_bin}/curl"
  out=$(printf 'n\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" update --solo 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"spark CLI: v${SPARK_VERSION} → v99.0.0"* ]] &&
    [[ "$out" != *"NGC vLLM"* ]] &&
    [[ "$out" != *"Postgres"* ]] &&
    [[ "$out" != *"NemoHermes"* ]]
}

test_update_does_not_suggest_spark_downgrade() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  printf '#!/usr/bin/env bash\nprintf '\''VERSION="0.0.1"\\n'\''\n' > "${fake_bin}/curl"
  chmod +x "${fake_bin}/curl"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" update --spark 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"spark CLI is up to date (v${SPARK_VERSION})"* ]] &&
    [[ "$out" == *$'Available update actions:\n    none'* ]]
}

test_update_nemohermes_failure_explains_rebuild_env() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  cat > "${fake_bin}/curl" <<EOF
#!/usr/bin/env bash
printf 'VERSION="%s"\\n' "$SPARK_VERSION"
EOF
  chmod +x "${fake_bin}/curl"
  out=$(printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:$(date +%y.%m)-py3" \
    FAKE_NEMOHERMES_UPDATE_CHECK=$'Current NemoHermes version: 0.0.55\nLatest maintained version: 0.0.78\nUpdate available:         yes' \
    FAKE_NEMOHERMES_EXIT=9 \
    "$SPARK" update 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"Failed to update NemoHermes sandbox"* ]] &&
    [[ "$out" == *"workspace inference env"* ]] &&
    [[ "$out" == *"external provider"* ]]
}

test_update_nemohermes_rebuild_uses_stored_compatible_key() {
  local tmp fake_bin nemo_log
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark/workspace"
  cat > "${tmp}/home/.config/spark/workspace/secrets.env" <<ENV
HERMES_LITELLM_MODEL=vllm/Org/Alpha
HERMES_CONTEXT_LENGTH=65536
HERMES_MAX_TOKENS=512
HERMES_REASONING_EFFORT=none
HERMES_LITELLM_BASE_URL=http://127.0.0.1:4000/v1
COMPATIBLE_API_KEY=stored-compatible-key
ENV
  cat > "${fake_bin}/curl" <<EOF
#!/usr/bin/env bash
printf 'VERSION="%s"\\n' "$SPARK_VERSION"
EOF
  chmod +x "${fake_bin}/curl"
  printf 'y\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:$(date +%y.%m)-py3" \
    FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_NEMOHERMES_UPDATE_CHECK=$'Current NemoHermes version: 0.0.55\nLatest maintained version: 0.0.78\nUpdate available:         yes' \
    "$SPARK" update >/dev/null 2>&1
  nemo_log=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$nemo_log" == *"COMPATIBLE_API_KEY=stored-compatible-key"* ]]
}

test_update_does_not_suggest_ngc_downgrade() {
  local tmp fake_bin out current_tag
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  current_tag="$(date +%y.%m)-py3"
  cat > "${fake_bin}/curl" <<EOF
#!/usr/bin/env bash
printf 'VERSION="%s"\\n' "$SPARK_VERSION"
EOF
  chmod +x "${fake_bin}/curl"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:${current_tag}" \
    "$SPARK" update </dev/null 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"NGC vLLM is up to date (${current_tag})"* ]] &&
    [[ "$out" != *"NGC vLLM: ${current_tag} →"* ]]
}

test_models_recommend_vllm() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_ACCEL=cuda-unified \
    SPARK_TOTAL_MEM_GB=121 "$SPARK" models recommend 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"Recommended models"* ]] &&
    [[ "$out" == *"RedHatAI/Qwen3.6-35B-A3B-NVFP4"* ]] &&
    [[ "$out" == *"spark run"* ]]
}

test_uninstall_purge_removes_state() {
  local tmp fake_bin out gone
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark/workspace" \
    "${tmp}/home/.local/share/spark/workspace" \
    "${tmp}/home/.cache/huggingface/hub/models--Org--Alpha/snapshots/1"
  printf '%s\n' 'x' > "${tmp}/home/.config/spark/workspace/secrets.env"
  printf '%s\n' 'services: {}' > "${tmp}/home/.config/spark/workspace/docker-compose.yml"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" uninstall --yes --purge-models --keep-binary 2>&1)
  [[ ! -e "${tmp}/home/.config/spark" && ! -e "${tmp}/home/.local/share/spark/workspace" && ! -e "${tmp}/home/.cache/huggingface/hub/models--Org--Alpha" ]] && gone=1 || gone=0
  rm -rf "$tmp"
  [[ "$gone" -eq 1 ]] && [[ "$out" == *"spark-managed state removed"* ]]
}

test_reinstall_dry_run() {
  local tmp fake_bin out mutated=0
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" reinstall --dry-run --yes --purge-models 2>&1)
  [[ ! -d "${tmp}/home/.config/spark" ]] && mutated=1
  rm -rf "$tmp"
  [[ "$mutated" -eq 0 ]] && [[ "$out" == *"spark reinstall dry run"* ]] && [[ "$out" == *"would run: spark setup --yes"* ]]
}

test_gateway_stop_when_none() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" gateway stop 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"No running gateway"* ]]
}

test_gateway_status_running() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark"
  printf '%s\n' '{"enabled":true,"port":4000,"providers":{"vllm":{"enabled":true}}}' > "${tmp}/home/.config/spark/gateway.json"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_NAMES='spark-litellm\n' "$SPARK" gateway status 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"gateway running"* ]] && [[ "$out" == *"vLLM"* ]]
}

test_status_ollama_lists() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  mkdir -p "${tmp}/home/.config/spark"
  printf '%s\n' '{"enabled":true,"port":4000,"providers":{"ollama":{"enabled":true}}}' > "${tmp}/home/.config/spark/gateway.json"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    FAKE_DOCKER_INFO_EXIT=0 FAKE_NAMES='spark-litellm\n' FAKE_OLLAMA_UP=1 \
    FAKE_LITELLM_MODELS='{"data":[{"id":"ollama_chat/qwen3:30b"}]}' \
    FAKE_OLLAMA_PS="NAME\tID\nqwen3:30b\tabc\n" "$SPARK" status 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"Served models"* ]] && [[ "$out" == *"qwen3:30b"* ]] &&
    [[ "$out" == *"Direct:  http://localhost:11434/api"* ]] &&
    [[ "$out" == *"Gateway: http://localhost:4000/v1 · model ollama_chat/qwen3:30b · routed"* ]] &&
    [[ "$out" == *"Engine: Ollama"* ]] &&
    [[ "$out" != *"Agent workspace"* ]]
}

test_stop_ollama_unloads() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    FAKE_OLLAMA_PS="NAME\tID\nqwen3:30b\tabc\n" "$SPARK" stop qwen3:30b 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"Unloaded qwen3:30b"* ]]
}

run_test "architecture command maps core boundaries" test_architecture_command_maps_core_boundaries
run_test "single-file build matches modules" test_single_file_build_matches_modules
run_test "source guard loads functions without dispatch" test_source_guard_loads_without_dispatch
run_test "workspace generates Super Productivity alternative" test_super_productivity_workspace_files
run_test "workspace generates Todoist alternative" test_todoist_workspace_files
run_test "workspace preserves custom Super Productivity pins" test_super_productivity_custom_pins_are_preserved
run_test "workspace reconciles pre-baseline SuperSync migrations" test_supersync_reconciles_pre_baseline_migration_history
run_test "workspace baseline reconciliation is idempotent" test_supersync_baseline_reconciliation_is_idempotent
run_test "workspace baseline reconciliation fails closed without history" test_supersync_baseline_reconciliation_fails_closed_without_history
run_test "workspace checks SuperSync user through stdin SQL" test_supersync_user_ready_uses_stdin_query
run_test "SuperSync setup creates initial passkey enrollment URL" test_supersync_initial_passkey_enrollment_url
run_test "SuperSync access is shown only in a temporary pager" test_super_productivity_sync_access_uses_temporary_pager
run_test "Super Productivity onboarding verifies two-way sync" test_super_productivity_onboarding_verifies_round_trip
run_test "Super Productivity onboarding retries verification in place" test_super_productivity_onboarding_retries_verification_in_place
run_test "Workspace summary shows Super Productivity resume guidance" test_workspace_summary_uses_super_productivity_resume_hint
run_test "Super Productivity onboarding requires an interactive terminal" test_super_productivity_onboarding_requires_interactive_terminal
run_test "workspace preserves legacy Postgres mount" test_workspace_preserves_legacy_postgres_mount
run_test "Super Productivity rejects insecure ports mode" test_super_productivity_rejects_http_ports_mode
run_test "workspace always asks and confirms task manager migration" test_workspace_interactive_task_manager_selector
run_test "workspace requires task manager in non-interactive setup" test_workspace_requires_explicit_noninteractive_task_manager
run_test "workspace detects remote task manager" test_workspace_remote_task_manager_detection
run_test "workspace distinguishes persisted and requested task managers" test_workspace_persisted_task_manager_ignores_runtime_override
run_test "workspace scopes Vikunja secret guard to Vikunja data" test_workspace_vikunja_secret_is_manager_scoped
run_test "workspace selects abandoned task manager for teardown" test_workspace_selects_abandoned_task_manager_for_teardown
run_test "workspace task manager teardown removes images" test_workspace_task_manager_teardown_removes_images
run_test "workspace task manager teardown covers services and data" test_workspace_task_manager_teardown_covers_services_and_data
run_test "workspace task manager teardown removes Hermes access" test_workspace_task_manager_teardown_removes_hermes_access
run_test "workspace task manager teardown drops database and role" test_workspace_task_manager_teardown_drops_database_and_role
run_test "workspace task manager teardown waits and retries" test_workspace_task_manager_teardown_waits_and_retries
run_test "workspace task manager teardown covers all transitions" test_workspace_task_manager_teardown_covers_all_transitions
run_test "workspace task manager teardown rejects broad paths" test_workspace_remove_managed_path_rejects_broad_targets
run_test "doctor reports missing NGC image without aborting" test_doctor_reports_no_ngc_image
run_test "doctor skips blocked NGC vLLM image" test_doctor_skips_blocked_ngc_vllm_image
run_test "SPARK_VLLM_IMAGE overrides detected image" test_vllm_image_override_wins
run_test "alias create preserves dash-prefixed arguments" test_alias_create_preserves_dash_prefixed_args
run_test "captured alias pins image/env and accepts safe overrides" test_alias_capture_replays_image_env_and_operational_overrides
run_test "alias capture rejects secret-bearing vLLM flags" test_alias_capture_rejects_secret_flags
run_test "guided alias backend mismatch fails closed" test_alias_backend_mismatch_fails_closed
run_test "built-in bundle catalog is embedded and valid" test_bundle_catalog_embeds_and_validates_builtin
run_test "bundle validation requires every patch to be declared and applied" test_bundle_validation_requires_declared_applied_patches
run_test "bundle sync validates the Git catalog and generated executable" test_bundle_sync_checks_git_catalog
run_test "bundle submit previews new and updated changes" test_bundle_submit_dry_run_prepares_new_and_updated_changes
run_test "bundle submit opens a confirmed draft PR" test_bundle_submit_opens_confirmed_draft_pr
run_test "bundle submit uses a fork without write permission" test_bundle_submit_uses_fork_without_write_permission
run_test "external bundle imports and every run checks Docker build cache" test_bundle_imports_external_folder_and_run_builds_with_docker_cache
run_test "bundle run resolves defaults and dynamic options" test_bundle_run_resolves_defaults_and_dynamic_options
run_test "alias create stores bundle plus adjustments" test_alias_create_from_bundle_stores_bundle_and_adjustments
run_test "doctor reports bad HF cache permissions" test_doctor_reports_bad_hf_cache_permissions
run_test "setup --check reports incomplete setup" test_setup_check_reports_incomplete
run_test "setup --check reports Tailscale Funnel" test_setup_check_reports_tailscale_funnel
run_test "doctor reports Tailscale Funnel risk" test_doctor_reports_tailscale_funnel
run_test "doctor supports JSON, quiet, and failure exit codes" test_doctor_json_quiet_and_exit_codes
run_test "invalid --port fails during validation" test_invalid_port_fails_before_side_effects
run_test "dry-run uses JSON profiles without executing model data" test_dry_run_uses_json_profile_safely
run_test "docker run failure shows actionable error" test_docker_run_failure_shows_error
run_test "corrupt profile JSON reports error" test_corrupt_profile_reports_error
run_test "total memory detection returns a positive value" test_total_mem_detection_positive
run_test "memory reserved by need (weights + KV) → fraction" test_need_based_fraction
run_test "kv-cache-dtype fp8 halves KV cache" test_fp8_halves_kv
run_test "KV cache read from nested text_config" test_text_config_nested
run_test "missing KV fields warns without aborting" test_missing_kv_fields_warns_not_aborts
run_test "capacity verification aborts when it does not fit" test_capacity_verification_aborts
run_test "port auto-assignment skips a busy port" test_port_auto_skips_busy
run_test "gateway YAML has per-model entries plus wildcard" test_gateway_yaml_per_model
run_test "missing model with --no-pull errors clearly" test_missing_model_no_pull_errors
run_test "missing model with --dry-run errors clearly" test_missing_model_dry_run_errors
run_test "auto-pull: fits → downloads and starts" test_autopull_fits_downloads_and_starts
run_test "auto-pull: does not fit → downloads without starting" test_autopull_no_fit_download_only
run_test "stop <model> stops only that model" test_stop_specific_model
run_test "stop --all stops every model" test_stop_all
run_test "down stops models and gateway" test_down_stops_models_and_gateway
run_test "stop with no arg and many models asks which" test_stop_ambiguous_requires_target
run_test "status renders served models clearly" test_status_renders_served_models
run_test "status supports JSON, quiet, and operational exit codes" test_status_json_quiet_and_exit_codes
run_test "dashboard web writes product UI" test_dashboard_web_once_writes_product_ui
run_test "dashboard terminal renders product snapshot" test_dashboard_terminal_still_renders_snapshot
run_test "gateway add/remove toggles a provider" test_gateway_add_remove_provider
run_test "pull (vllm) reports ready" test_pull_vllm_ready
run_test "pull routes to Ollama on the ollama backend" test_pull_ollama_routes
run_test "list shows downloaded models" test_list_shows_models
run_test "list marks partial models" test_list_marks_partial_models
run_test "list ignores stale incomplete blobs" test_list_ignores_stale_incomplete_blobs
run_test "list reports empty cache" test_list_empty
run_test "rm removes the right model dir" test_rm_removes_the_right_dir
run_test "rm removes multiple models" test_rm_removes_multiple_models
run_test "rm missing model deletes none" test_rm_missing_model_deletes_none
run_test "rm reports delete failure" test_rm_reports_delete_failure
run_test "rm errors on a model not in cache" test_rm_not_found
run_test "logs on ollama points to the service logs" test_logs_ollama_message
run_test "logs errors when no container exists" test_logs_vllm_no_container
run_test "config sets and shows auto-update" test_config_set_and_show
run_test "update check accepts zero-padded month" test_update_check_accepts_zero_padded_month
run_test "update prompts workspace tool updates one by one" test_update_prompts_workspace_tool_updates_one_by_one
run_test "update skips images already at remote digest" test_update_skips_images_already_at_remote_digest
run_test "update parses human Buildx digest output" test_update_parses_human_buildx_digest_output
run_test "update uses supported NemoHermes check command" test_update_uses_supported_nemohermes_check_command
run_test "update checks active Super Productivity release" test_update_checks_active_super_productivity_release
run_test "update rebuilds active Super Productivity release" test_update_rebuilds_active_super_productivity_release
run_test "update flags limit checks and actions" test_update_flags_limit_checks_and_actions
run_test "update solo alias checks only spark" test_update_solo_alias_checks_only_spark
run_test "update does not suggest spark downgrade" test_update_does_not_suggest_spark_downgrade
run_test "update NemoHermes failure explains rebuild env" test_update_nemohermes_failure_explains_rebuild_env
run_test "update NemoHermes rebuild uses stored compatible key" test_update_nemohermes_rebuild_uses_stored_compatible_key
run_test "update does not suggest NGC downgrade" test_update_does_not_suggest_ngc_downgrade
run_test "models recommend suggests vLLM models" test_models_recommend_vllm
run_test "uninstall --purge-models removes spark state" test_uninstall_purge_removes_state
run_test "reinstall --dry-run plans clean setup" test_reinstall_dry_run
run_test "gateway stop reports when none running" test_gateway_stop_when_none
run_test "gateway status shows running + providers" test_gateway_status_running
run_test "status (ollama) lists pulled models" test_status_ollama_lists
run_test "stop (ollama) unloads a model" test_stop_ollama_unloads
run_test "detect: Apple Silicon → metal/ollama" test_detect_metal_on_apple_silicon
run_test "detect: arm64 NVIDIA → cuda-unified/vllm" test_detect_cuda_unified_on_arm_nvidia
run_test "detect: x86_64 NVIDIA → cuda-discrete/vllm" test_detect_cuda_discrete_on_x86_nvidia
run_test "detect: no GPU → cpu/ollama" test_detect_cpu_without_gpu
run_test "discrete GPU reserves from VRAM pool" test_discrete_uses_vram_pool
run_test "ollama run (dry) plans pull + gateway route" test_ollama_dry_run_plans_pull
run_test "ollama run pulls and enables gateway" test_ollama_run_pulls_and_enables_gateway
run_test "ollama oversized model warns and aborts on no" test_ollama_oversized_warns_aborts
run_test "ollama oversized model continues on yes" test_ollama_oversized_continue_yes
run_test "ollama backend blocks vLLM-only model" test_ollama_blocks_vllm_only_model
run_test "vllm backend blocks ollama-style tag" test_vllm_blocks_ollama_tag
run_test "dry-run shows fit options without aborting" test_dryrun_shows_fit_options
run_test "dry-run live available caps auto-fit" test_dryrun_live_available_caps_auto_fit
run_test "menu: choosing fp8 relaunches at 2x context" test_menu_choose_fp8_relaunches
run_test "menu: choosing auto relaunches at the auto context" test_menu_choose_auto_relaunches
run_test "menu: cancel aborts without starting" test_menu_cancel_aborts
run_test "auto-pull menu downloads + starts at chosen context" test_autopull_menu_downloads_at_choice
run_test "--mem too high suggests a smaller --mem" test_mem_override_suggests_mem
run_test "per-container --memory limit present on unified" test_mem_limit_present_unified
run_test "per-container --memory limit absent on discrete" test_mem_limit_absent_discrete
run_test "per-container --memory limit absent with --no-mem-limit" test_mem_limit_absent_with_flag
run_test "vLLM runs as host user with user cache" test_vllm_runs_as_host_user_with_user_cache
run_test "per-container --memory limit honors warmup headroom env" test_mem_limit_headroom_env
run_test "default max-num-seqs cap is 100 (announced)" test_max_num_seqs_default
run_test "--max-num-seqs overrides the default" test_max_num_seqs_override
run_test "startup retries Mamba failure with lower --max-num-seqs" test_startup_retry_mamba
run_test "startup retries warmup OOM with more headroom" test_startup_retry_oom
run_test "unrecoverable startup aborts without retry" test_startup_unrecoverable_aborts
run_test "--no-wait launches without supervising" test_startup_no_wait
run_test "enforce-eager auto for MoE, not for dense" test_enforce_eager_auto_for_moe
run_test "HF MoE NVFP4 emits Marlin + atomic add" test_hf_moe_nvfp4_emits_marlin_atomic
run_test "HF inspector maps compressed-tensors NVFP4" test_hf_inspector_compressed_tensors_nvfp4_tag
run_test "HF inspector maps ModelOpt HF quant NVFP4" test_hf_inspector_modelopt_hf_quant_nvfp4_tag
run_test "HF inspector prefers recommended multiline command" test_hf_inspector_prefers_recommended_multiline_command_from_readme
run_test "HF inspector tools needs explicit tool-calling signal" test_hf_inspector_tools_requires_tool_calling_signal
run_test "Qwen3.5 uses qwen3_coder tool parser" test_qwen35_uses_qwen3_coder_tool_parser
run_test "Gemma4 uses gemma4 reasoning and tool parsers" test_gemma4_uses_gemma4_tool_and_reasoning_parsers
run_test "text-only uses vLLM JSON multimodal limit" test_text_only_uses_vllm_json_multimodal_limit
run_test "HF card recommended context wins" test_hf_card_context_wins
run_test "HF MTP auto-enables when supported" test_hf_mtp_auto_enables_when_supported
run_test "HF MTP raises memory floor" test_hf_mtp_raises_memory_floor
run_test "HF recommended command maps stream interval" test_hf_stream_interval_from_recommended_command
run_test "HF recommended command maps quantization" test_hf_quantization_from_recommended_command
run_test "HF recommended official image uses its entrypoint" test_hf_recommended_official_image_entrypoint
run_test "HF recommended image falls back to local README" test_hf_recommended_image_falls_back_to_local_readme
run_test "MTP batched tokens override HF command" test_mtp_batched_tokens_overrides_recommended_command
run_test "Blackwell single-stream MTP uses flashinfer_cutlass + stream64" test_blackwell_single_stream_mtp_uses_flashinfer_cutlass_and_stream64
run_test "HF MTP launch sets batched tokens" test_hf_mtp_launch_sets_batched_tokens
run_test "HF KV FP8 question/recommendation" test_hf_kv_fp8_question_and_recommendation
run_test "KV FP8 override does not persist to profile" test_kv_fp8_override_does_not_persist_to_profile
run_test "dry-run explain shows HF source and flags" test_dry_run_explain_shows_hf_and_flags
run_test "CLI overrides win over HF metadata" test_hf_metadata_cli_overrides_win
run_test "calibrate dry-run lists candidate configs" test_calibrate_dry_run_lists_candidates
run_test "calibrate saves best config and run uses it" test_calibrate_saves_best_and_run_uses_it
run_test "stale profile schema auto-refreshes on run" test_profile_schema_autoregen
run_test "CUDA-graph calibration: try / stay-eager / use-graphs" test_cudagraph_calibration
run_test "warmup cache migrates legacy single-peak entries" test_warmup_legacy_migration
run_test "budget blocks stacking past total − OS reserve" test_budget_blocks_when_stacking
run_test "budget blocks a single model over the limit" test_budget_blocks_single_model
run_test "budget is larger on discrete (smaller OS reserve)" test_budget_larger_on_discrete
run_test "gateway routes Ollama via host.docker.internal on macOS" test_gateway_ollama_route_mac
run_test "gateway routes Ollama via localhost on Linux" test_gateway_ollama_route_linux
run_test "doctor runs Ollama checks on the ollama backend" test_doctor_ollama_backend
run_test "setup --host (ollama) reports ready" test_host_check_ollama_ready
run_test "setup --host (vllm) flags a missing GPU" test_host_check_vllm_no_gpu
run_test "setup --host flags missing OS hardening" test_host_check_hardening_missing
run_test "setup --host passes with hardening present" test_host_check_hardening_present
run_test "swap reconciled by total active swap" test_swap_reconcile_by_total
run_test "swap ready state is a no-op" test_swap_ready_no_mutation
run_test "swap trusts swapon when free reports zero" test_swap_swapon_wins_when_free_reports_zero
run_test "swap fixes swappiness only" test_swap_wrong_swappiness_reconciles
run_test "swap creates missing spark top-up" test_swap_missing_file_creates_topup
run_test "swap activates existing inactive spark file" test_swap_existing_inactive_file_activates
run_test "swap recreates active unused wrong-size file" test_swap_active_unused_wrong_size_recreates
run_test "swap refuses to resize active used file" test_swap_active_used_wrong_size_fails_safely
run_test "spark status shows live memory" test_status_live_memory
run_test "setup picker [1] routes to this machine" test_setup_picker_routes_to_host
run_test "setup --host never disables password SSH" test_setup_host_no_disable_password
run_test "setup --server installs the same set (parity)" test_setup_server_check_parity
run_test "setup rejects unknown flags" test_setup_unknown_flag_fails
run_test "setup --full --check runs workspace phase" test_setup_full_check_runs_workspace_phase
run_test "setup --full continues after swap reconcile" test_setup_full_continues_after_swap_reconcile
run_test "help text tracks current CLI" test_help_text_tracks_current_cli
run_test "workspace help renders only as ws" test_workspace_help_and_command
run_test "workspace lifecycle start/stop replaces down" test_workspace_lifecycle_commands
run_test "workspace restart orders stop then start" test_workspace_restart_orders_stop_then_start
run_test "workspace Hermes start uses official lifecycle" test_workspace_hermes_start_uses_official_lifecycle
run_test "workspace bridge waits for delayed readiness" test_workspace_bridge_waits_for_delayed_readiness
run_test "workspace dashboard proxy rewrites Host on loopback" test_workspace_dashboard_proxy_rewrites_host_on_loopback
run_test "workspace listener check allows OpenShell gateway bridge" test_workspace_listener_check_allows_only_openshell_gateway_bridge
run_test "workspace model recovery disables MTP" test_workspace_model_start_disables_mtp_for_reliable_recovery
run_test "workspace model recovery enables tool calling" test_workspace_model_restarts_without_tool_calling
run_test "workspace model requires expected tool parser" test_workspace_model_tool_calling_requires_expected_parser
run_test "workspace Hermes uses balanced CLI toolsets" test_workspace_hermes_toolsets_are_balanced
run_test "workspace status uses Tailscale Services config" test_workspace_status_uses_tailscale_services_config
run_test "workspace restores OpenShell Hermes container name" test_workspace_restores_openshell_hermes_name
run_test "workspace setup --check does not write files" test_workspace_check_no_mutation
run_test "workspace setup --check preserves existing config" test_workspace_check_existing_config_no_mutation
run_test "workspace setup --check reports missing Compose plugin" test_workspace_check_reports_missing_compose_plugin
run_test "workspace setup model picker uses spark list data" test_workspace_model_tui_uses_list
run_test "workspace setup rejects partial model" test_workspace_rejects_partial_model
run_test "workspace setup waits for Hermes model" test_workspace_setup_waits_for_model
run_test "workspace setup rejects invalid Tailscale mode" test_workspace_setup_rejects_bad_tailscale_mode
run_test "workspace setup rejects invalid Docker image refs" test_workspace_setup_rejects_bad_image_ref
run_test "workspace setup rejects multiline secrets" test_workspace_setup_rejects_multiline_secret
run_test "workspace setup writes compose services without spark prefix" test_workspace_setup_writes_compose_names
run_test "workspace setup fast-paths healthy workspace" test_workspace_setup_healthy_fast_path_no_mutation
run_test "workspace setup repairs compose drift without Hermes onboard" test_workspace_setup_repairs_compose_drift_without_hermes_onboard
run_test "workspace setup backs up and normalizes invalid env" test_workspace_setup_backs_up_and_normalizes_invalid_env
run_test "workspace setup refuses missing secret with data" test_workspace_setup_refuses_missing_secret_with_data
run_test "workspace setup fails when Hermes onboard fails" test_workspace_setup_fails_when_hermes_onboard_fails
run_test "workspace setup updates stale NemoHermes" test_workspace_setup_updates_stale_nemohermes
run_test "workspace setup stops when NemoHermes update fails" test_workspace_setup_stops_when_nemohermes_update_fails
run_test "workspace derives tailnet from Tailscale self DNSName" test_workspace_tailnet_from_self_dnsname
run_test "workspace setup requires tailnet URLs" test_workspace_setup_requires_tailnet_urls
run_test "workspace ports mode requires MagicDNS URLs" test_workspace_ports_requires_magicdns_urls
run_test "workspace supports Tailscale MagicDNS ports fallback" test_workspace_tailscale_ports_fallback
run_test "workspace setup updates old Tailscale for Services" test_workspace_setup_updates_old_tailscale_for_services
run_test "workspace setup defaults to services from ports workspace" test_workspace_setup_defaults_to_services_from_ports_workspace
run_test "workspace setup reports missing Tailscale Services HITL" test_workspace_setup_reports_missing_tailscale_services_hitl
run_test "workspace setup --yes does not fallback when Services are disabled" test_workspace_setup_yes_does_not_fallback_when_services_disabled
run_test "workspace setup reports pending Tailscale Service approval" test_workspace_setup_reports_tailscale_service_pending_approval
run_test "workspace waits for delayed Tailscale Service approval" test_workspace_waits_for_delayed_tailscale_service_approval
run_test "workspace setup reports missing Tailscale tag" test_workspace_setup_reports_missing_tailscale_tag
run_test "workspace setup reports missing Tailscale operator" test_workspace_setup_reports_missing_tailscale_operator
run_test "workspace setup interactively offers ports fallback when Services are disabled" test_workspace_setup_interactive_offers_ports_fallback_when_services_disabled
run_test "workspace setup explicit Services does not fall back to ports" test_workspace_setup_explicit_services_does_not_fall_back_to_ports
run_test "workspace setup blocks Tailscale Funnel" test_workspace_setup_blocks_tailscale_funnel
run_test "workspace setup resets Tailscale Funnel with flag" test_workspace_setup_resets_tailscale_funnel_with_flag
run_test "workspace setup --check reports Funnel without reset" test_workspace_setup_check_reports_funnel_without_reset
run_test "workspace setup repairs shared Postgres runtime" test_workspace_setup_repairs_shared_postgres_runtime
run_test "workspace setup fails when Vikunja token creation fails" test_workspace_setup_fails_when_vikunja_token_creation_fails
run_test "workspace setup waits for Vikunja CLI" test_workspace_setup_waits_for_vikunja_cli
run_test "workspace setup creates Hermes bot" test_workspace_setup_creates_hermes_bot
run_test "workspace setup requires Hermes Vikunja API access" test_workspace_setup_requires_hermes_vikunja_api_access
run_test "workspace setup resolves Unicode Vikunja user ID" test_workspace_setup_resolves_unicode_vikunja_user_id
run_test "workspace setup shares projects with Hermes bot" test_workspace_setup_shares_projects_with_hermes_bot
run_test "workspace rejects regular-user token for Hermes" test_workspace_rejects_regular_user_token_for_hermes
run_test "workspace rejects bot owned by another user" test_workspace_rejects_bot_owned_by_another_user
run_test "workspace setup never persists human password on Vikunja failure" test_workspace_setup_never_persists_human_password_on_vikunja_failure
run_test "workspace setup preserves existing secrets" test_workspace_setup_preserves_existing_secrets
run_test "workspace setup missing required values does not pollute env" test_workspace_setup_missing_required_values_do_not_pollute_env
run_test "workspace setup generates, prints, and forgets human passwords" test_workspace_setup_generates_prints_and_forgets_passwords
run_test "workspace setup accepts password flags and files" test_workspace_setup_accepts_password_flags_and_files
run_test "workspace setup prompts for existing Vikunja password" test_workspace_setup_prompts_for_existing_vikunja_password
run_test "workspace credentials command is removed" test_workspace_credentials_command_removed
run_test "workspace setup rejects removed SMTP" test_workspace_setup_rejects_removed_smtp
run_test "workspace setup removes legacy SMTP" test_workspace_setup_removes_legacy_smtp
run_test "workspace recover changes Vikunja password" test_workspace_recover_vikunja
run_test "workspace recover changes n8n password" test_workspace_recover_n8n
run_test "workspace recover fails after two login attempts" test_workspace_recover_n8n_fails_after_two_login_attempts
run_test "workspace recover requires supported n8n" test_workspace_recover_n8n_requires_supported_version
run_test "workspace setup repairs polluted required env values" test_workspace_setup_repairs_polluted_required_env_values
run_test "workspace setup cleans polluted env before missing value abort" test_workspace_setup_cleans_polluted_env_before_missing_value_abort
run_test "workspace setup --remote delegates to remote spark" test_workspace_remote_delegates
run_test "workspace setup --remote delegates credentials safely" test_workspace_remote_delegates_credentials
run_test "workspace setup --remote --check does not forward credentials" test_workspace_remote_check_does_not_forward_credentials
run_test "workspace doctor --remote delegates doctor" test_workspace_doctor_remote_delegates_doctor
run_test "workspace doctor --strict --remote delegates doctor" test_workspace_doctor_remote_delegates_strict
run_test "workspace doctor checklist passes" test_workspace_doctor_checklist_passes
run_test "workspace doctor flags stale NemoHermes release" test_workspace_doctor_flags_stale_nemohermes_release
run_test "workspace setup keeps Hermes dashboard on loopback" test_workspace_setup_keeps_hermes_dashboard_on_loopback
run_test "workspace doctor --strict checks pinned images only" test_workspace_doctor_strict_checks_pinned_images
run_test "workspace doctor --strict flags latest images" test_workspace_doctor_strict_flags_latest_images
run_test "workspace doctor --json emits structured checks" test_workspace_doctor_json
run_test "workspace doctor quiet and unconfigured summary" test_workspace_doctor_quiet_and_unconfigured_summary
run_test "workspace status renders containers and Agent workspace" test_workspace_status_renders_containers_and_agent_workspace
run_test "workspace status supports JSON, quiet, and containers" test_workspace_status_json_quiet_and_containers
run_test "workspace doctor flags public host listener" test_workspace_doctor_flags_public_host_listener
run_test "workspace doctor rejects public bind addr allowlist" test_workspace_doctor_rejects_public_bind_addr_allowlist
run_test "workspace doctor rejects non-Tailscale host listener allowlist" test_workspace_doctor_rejects_non_tailscale_host_listener_allowlist
run_test "workspace doctor rejects public Compose bind" test_workspace_doctor_rejects_public_compose_bind
run_test "workspace doctor rejects non-Tailscale ports bind" test_workspace_doctor_rejects_non_tailscale_ports_bind
run_test "workspace doctor flags public Docker port" test_workspace_doctor_flags_public_docker_port
run_test "workspace doctor flags Vikunja doctor failure" test_workspace_doctor_flags_vikunja_doctor_failure
run_test "workspace doctor accepts writable Vikunja group mismatch" test_workspace_doctor_accepts_writable_vikunja_group_mismatch
run_test "workspace doctor flags stale Vikunja token status" test_workspace_doctor_flags_stale_vikunja_token_status
run_test "workspace doctor requires Vikunja user/email same row" test_workspace_doctor_requires_vikunja_user_and_email_same_row
run_test "workspace doctor rejects Vikunja user substring match" test_workspace_doctor_rejects_vikunja_user_substring_match
run_test "workspace doctor rejects manual localhost URLs" test_workspace_doctor_rejects_manual_localhost_urls
run_test "workspace doctor flags public config dir" test_workspace_doctor_flags_public_config_dir
run_test "workspace doctor flags stale service URLs" test_workspace_doctor_flags_stale_service_urls
run_test "workspace doctor rejects wrong tailnet URLs" test_workspace_doctor_rejects_wrong_tailnet_urls
run_test "workspace doctor rejects stale ports URLs" test_workspace_doctor_rejects_stale_ports_urls
run_test "workspace doctor rejects stale ports DNS name" test_workspace_doctor_rejects_stale_ports_dns_name
run_test "workspace doctor flags stale n8n owner status" test_workspace_doctor_flags_stale_n8n_owner_status
run_test "workspace doctor flags stored human password" test_workspace_doctor_flags_stored_human_password
run_test "workspace doctor flags duplicate credentials" test_workspace_doctor_flags_duplicate_credentials
run_test "workspace doctor flags invalid secrets env" test_workspace_doctor_flags_invalid_secrets_env
run_test "workspace doctor flags invalid service env" test_workspace_doctor_flags_invalid_service_env
run_test "workspace doctor flags wrong n8n cookie mode" test_workspace_doctor_flags_wrong_n8n_cookie_mode
run_test "workspace doctor flags non-idempotent Postgres init" test_workspace_doctor_flags_non_idempotent_postgres_init
run_test "workspace doctor flags missing Postgres runtime DB" test_workspace_doctor_flags_missing_postgres_runtime_db
run_test "workspace doctor flags missing LiteLLM route" test_workspace_doctor_flags_missing_litellm_route
run_test "workspace doctor flags LiteLLM smoke failure" test_workspace_doctor_flags_litellm_smoke_failure
run_test "workspace doctor flags wrong NemoHermes route" test_workspace_doctor_flags_wrong_nemohermes_route
run_test "workspace doctor flags NemoHermes doctor failure" test_workspace_doctor_flags_nemohermes_doctor_failure
run_test "workspace doctor flags missing Tailscale Service registration" test_workspace_doctor_flags_missing_tailscale_service_registration
run_test "workspace doctor flags Tailscale Serve disabled" test_workspace_doctor_flags_tailscale_serve_disabled
run_test "workspace doctor flags Tailscale Service host not advertised" test_workspace_doctor_flags_tailscale_service_host_not_advertised
run_test "workspace doctor flags wrong NemoClaw policy" test_workspace_doctor_flags_wrong_nemoclaw_policy
run_test "workspace doctor flags wrong Hermes dashboard URL" test_workspace_doctor_flags_wrong_hermes_dashboard_url
run_test "workspace doctor flags missing Tailscale Service config" test_workspace_doctor_flags_missing_tailscale_service_config
run_test "workspace doctor flags Tailscale Funnel enabled" test_workspace_doctor_flags_tailscale_funnel_enabled
run_test "workspace doctor rejects public Tailscale Service target" test_workspace_doctor_rejects_public_tailscale_service_target
run_test "workspace doctor rejects swapped Tailscale Service ports" test_workspace_doctor_rejects_swapped_tailscale_service_ports
run_test "workspace doctor accepts multiline Tailscale Service JSON" test_workspace_doctor_accepts_multiline_tailscale_service_json
run_test "workspace doctor accepts Tailscale services endpoint JSON" test_workspace_doctor_accepts_tailscale_services_endpoint_json
run_test "workspace doctor flags invalid compose config" test_workspace_doctor_flags_invalid_compose_config
run_test "workspace doctor flags missing runtime hardening" test_workspace_doctor_flags_missing_runtime_hardening
run_test "workspace backup writes manifest and verifies" test_workspace_backup_manifest_and_verify
run_test "workspace backup requires configured workspace" test_workspace_backup_requires_config
run_test "workspace backup --verify rejects extra args" test_workspace_backup_verify_rejects_extra_args
run_test "workspace logs requires configured workspace" test_workspace_logs_requires_config
run_test "workspace backup --verify flags missing Hermes marker" test_workspace_backup_verify_flags_missing_hermes_marker
run_test "workspace backup --verify flags public backup file" test_workspace_backup_verify_flags_public_backup_file
run_test "workspace backup --verify flags checksum mismatch" test_workspace_backup_verify_flags_checksum_mismatch
run_test "workspace backup --verify flags missing checksum entry" test_workspace_backup_verify_flags_missing_checksum_entry
run_test "workspace backup --verify flags unexpected checksum entry" test_workspace_backup_verify_flags_unexpected_checksum_entry
run_test "workspace removed commands are unknown" test_workspace_removed_commands_are_unknown
run_test "workspace setup accepts Todoist token and creates Hermes label" test_workspace_setup_accepts_todoist_token
run_test "workspace setup fails when Todoist Hermes label cannot be created" test_workspace_setup_fails_when_todoist_label_creation_fails
run_test "workspace setup rejects multiline Todoist token" test_workspace_setup_rejects_multiline_todoist_token
run_test "workspace setup rejects removed Vikunja token flag" test_workspace_setup_rejects_removed_vikunja_token_flag
run_test "workspace setup rerun bootstraps n8n owner" test_workspace_setup_rerun_bootstraps_n8n_owner
run_test "workspace setup uses only n8n 2.x login field" test_workspace_setup_uses_only_n8n_2x_login_field

if [[ "$test_list_only" == "1" ]]; then
  (( selected > 0 ))
  exit
fi

printf "\n%d passed, %d failed (%d selected, %d eligible, %d discovered; suite=%s; shard=%d/%d)\n" \
  "$passed" "$failed" "$selected" "$eligible" "$discovered" "$test_suite" \
  "$((test_shard_index + 1))" "$test_shard_total"
(( selected > 0 && failed == 0 ))
