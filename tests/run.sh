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
        if [[ ! -t 0 ]]; then
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
            printf '%b' "${FAKE_VIKUNJA_USER_LIST:-| 1 | massimo | m@example.com | active |\n| 2 | hermes | hermes@spark.invalid | active |\n}" ;;
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
  run)
    [[ -n "${FAKE_DOCKER_ARGS_FILE:-}" ]] && printf '%s\n' "$args" >> "${FAKE_DOCKER_ARGS_FILE}"
    exit "${FAKE_DOCKER_RUN_EXIT:-0}"
    ;;
  inspect)
    # Adaptive-startup tests: vary by attempt (= number of `run` lines captured so far).
    _att=0
    [[ -n "${FAKE_DOCKER_ARGS_FILE:-}" && -f "${FAKE_DOCKER_ARGS_FILE}" ]] && _att=$(grep -c '^run ' "${FAKE_DOCKER_ARGS_FILE}" 2>/dev/null || echo 0)
    case "$args" in
      *State.Status*)
        if [[ -n "${FAKE_RETRY:-}" && "${_att}" -le 1 ]]; then echo "exited"
        else echo "${FAKE_STATE_STATUS:-running}"; fi ;;
      *State.OOMKilled*)
        if [[ "${FAKE_RETRY:-}" == "oom" && "${_att}" -le 1 ]]; then echo "true"
        else echo "${FAKE_OOMKILLED:-false}"; fi ;;
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
    # cgroup memory reads for `spark status` live block.
    case "$args" in
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
case "$*" in
  *https://vikunja.test-tailnet.ts.net/api/v1/info*) exit "${FAKE_TAILSCALE_VIKUNJA_EXIT:-0}" ;;
  *https://n8n.test-tailnet.ts.net/healthz*) exit "${FAKE_TAILSCALE_N8N_EXIT:-0}" ;;
  *https://hermes.test-tailnet.ts.net/*) exit "${FAKE_TAILSCALE_HERMES_EXIT:-0}" ;;
  *http://sparkbox.test-tailnet.ts.net:3456/api/v1/info*) exit "${FAKE_TAILSCALE_VIKUNJA_EXIT:-0}" ;;
  *http://sparkbox.test-tailnet.ts.net:5678/healthz*) exit "${FAKE_TAILSCALE_N8N_EXIT:-0}" ;;
  *http://sparkbox.test-tailnet.ts.net:18789/*) exit "${FAKE_TAILSCALE_HERMES_EXIT:-0}" ;;
  *:3456/api/v1/info*) exit "${FAKE_VIKUNJA_INFO_EXIT:-0}" ;;
  *:3456/api/v1/login*) echo '{"token":"jwt_hermes"}'; exit "${FAKE_VIKUNJA_LOGIN_EXIT:-0}" ;;
  *:3456/api/v1/routes*) echo '{"tasks":{"read_all":{},"create":{},"update":{},"delete":{}},"projects":{"read_all":{},"create":{},"update":{},"delete":{}},"comments":{"read_all":{},"create":{},"update":{},"delete":{}},"labels":{"read_all":{},"create":{},"update":{},"delete":{}},"webhooks":{"read_all":{},"create":{},"update":{},"delete":{}}}'; exit "${FAKE_VIKUNJA_ROUTES_EXIT:-0}" ;;
  *:3456/api/v1/tokens*) [[ -n "${FAKE_CURL_FILE:-}" ]] && printf '%s\n' "$*" >> "${FAKE_CURL_FILE}"; echo "{\"token\":\"${FAKE_VIKUNJA_CREATED_TOKEN:-vk_auto_hermes}\"}"; exit "${FAKE_VIKUNJA_TOKEN_CREATE_EXIT:-0}" ;;
  *:3456/api/v1/user*) echo "${FAKE_VIKUNJA_USER_JSON:-{\"username\":\"hermes\",\"email\":\"hermes@spark.invalid\"}}"; exit "${FAKE_VIKUNJA_USER_EXIT:-0}" ;;
  *:5678/healthz*) exit "${FAKE_N8N_HEALTH_EXIT:-0}" ;;
  *:5678/rest/owner/setup*) [[ -n "${FAKE_N8N_OWNER_MARKER:-}" ]] && : > "$FAKE_N8N_OWNER_MARKER"; echo '{"data":{"id":"owner"}}'; exit "${FAKE_N8N_OWNER_EXIT:-0}" ;;
  *:5678/rest/login*)
    if [[ "${FAKE_N8N_LOGIN_FORBID_EMAIL_FIELD:-0}" == "1" && "$*" == *'"email"'* ]]; then
      echo '{"code":"email_field_forbidden"}'
      exit 400
    fi
    if [[ "${FAKE_N8N_LOGIN_REQUIRE_EMAIL_OR_LDAP:-0}" == "1" && "$*" != *"emailOrLdapLoginId"* ]]; then
      echo '{"code":"invalid_type","path":["emailOrLdapLoginId"],"message":"Required"}'
      exit 400
    fi
    echo '{"data":{"id":"owner"}}'
    if [[ "${FAKE_N8N_LOGIN_AFTER_OWNER:-0}" == "1" && -n "${FAKE_N8N_OWNER_MARKER:-}" && -e "$FAKE_N8N_OWNER_MARKER" ]]; then
      exit 0
    fi
    exit "${FAKE_N8N_LOGIN_EXIT:-0}" ;;
  *:8642/v1/models*) echo "${FAKE_HERMES_MODELS:-{\"data\":[{\"id\":\"hermes-agent\"}]}"; exit "${FAKE_HERMES_LOCAL_API_EXIT:-0}" ;;
  */v1/models*) [[ "${FAKE_VLLM_READY:-1}" == "1" ]] && { echo "${FAKE_LITELLM_MODELS:-{\"data\":[{\"id\":\"vllm/Org/Alpha\"}]}"; exit 0; }; exit 7 ;;
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
rt="${FAKE_RAM_TOTAL_GB:-121}"; ru="${FAKE_RAM_USED_GB:-40}"; rf="${FAKE_RAM_FREE_GB:-50}"; ra="${FAKE_RAM_AVAIL_GB:-78}"
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
      echo "${FAKE_TAILSCALE_STATUS_JSON:-{\"MagicDNSSuffix\":\"test-tailnet.ts.net.\"}}"
      exit 0
    fi
    exit "${FAKE_TAILSCALE_STATUS_EXIT:-1}" ;;
  serve)
    if [[ "${2:-}" == "get-config" && "${3:-}" == "--all" ]]; then
      echo "${FAKE_TAILSCALE_SERVE_CONFIG:-svc:vikunja 127.0.0.1:3456\nsvc:n8n 127.0.0.1:5678\nsvc:hermes 127.0.0.1:18789}"
      exit "${FAKE_TAILSCALE_GET_CONFIG_EXIT:-0}"
    fi
    [[ "${2:-}" == "status" ]] && exit 0
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
case "$*" in
  *dashboard-url*) echo "${FAKE_NEMOHERMES_DASHBOARD_URL:-http://127.0.0.1:18789}" ;;
  *"inference get --json"*) echo "${FAKE_NEMOHERMES_INFERENCE_JSON:-{\"provider\":\"compatible-endpoint\",\"model\":\"vllm/Org/Alpha\"}}" ;;
  *"inference get"*) echo "${FAKE_NEMOHERMES_INFERENCE_TEXT:-Provider: compatible-endpoint Model: vllm/Org/Alpha}" ;;
  *"policy-explain --json"*) echo "${FAKE_NEMOHERMES_POLICY_JSON:-{\"tier\":\"restricted\",\"appliedPresets\":[]}}" ;;
  *"policy-explain"*) echo "${FAKE_NEMOHERMES_POLICY_TEXT:-Policy tier: restricted}" ;;
  *"policy-list"*) echo "${FAKE_NEMOHERMES_POLICY_LIST:-restricted}" ;;
  *"channels status --channel whatsapp --json"*) echo "${FAKE_WHATSAPP_STATUS_JSON:-{\"verdict\":\"healthy\"}}" ;;
  *doctor*) exit "${FAKE_NEMOHERMES_DOCTOR_EXIT:-0}" ;;
  *status*) echo "${FAKE_NEMOHERMES_STATUS:-Hermes ready}" ;;
  *logs*) echo "Hermes logs" ;;
esac
exit "${FAKE_NEMOHERMES_EXIT:-0}"
EOF
  chmod +x "${dir}/nemohermes"

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
*"export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH; spark ws setup --yes --model Org/Alpha --tailscale-mode ports --postgres-image postgres:18.1 --vikunja-image vikunja/vikunja:1.2.3 --n8n-image docker.n8n.io/n8nio/n8n:1.100.0"*) echo "remote workspace with creds ok" ;;
  *"export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH; spark ws setup --check --model Org/Alpha --tailscale-mode ports --postgres-image postgres:18.1 --vikunja-image vikunja/vikunja:1.2.3 --n8n-image docker.n8n.io/n8nio/n8n:1.100.0"*) echo "remote workspace with opts ok" ;;
  *"export PATH=\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH; spark ws setup --check --model Org/Alpha"*) echo "remote workspace ok" ;;
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

run_test() {
  local name="$1"
  shift

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

test_doctor_reports_no_ngc_image() {
  local tmp fake_bin output
  tmp=$(mktemp -d)
  fake_bin="${tmp}/bin"
  make_fake_bin "$fake_bin"

  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" doctor 2>&1)
  rm -rf "$tmp"

  [[ "$output" == *"NGC container: vLLM image not pulled"* ]] &&
    [[ "$output" == *"checks passed"* ]]
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

  [[ "$output" == *"HF cache permissions: not writable"* ]] &&
    [[ "$output" == *"Fix manually"* ]]
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

  [[ "$output" == *"Tailscale Funnel: active public exposure"* ]]
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

  [[ "$output" == *"KV cache:  12.0 GB"* ]] &&
    [[ "$output" == *"Weights:   14.0 GB"* ]] &&
    [[ "$output" == *"--gpu-memory-utilization 0.23"* ]] &&
    [[ "$output" == *"--max-model-len 131072"* ]]
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

  [[ "$output" == *"KV cache:  6.0 GB"* ]] &&
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
    [[ "$output" == *"Needs:      28.1 GB"* ]] &&
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

test_status_renders_table() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin output
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; mkdir -p "${tmp}/home"
  output=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 FAKE_MANAGED="$TWO_MODELS" \
    "$SPARK" status 2>&1)
  rm -rf "$tmp"
  [[ "$output" == *"MODEL"* ]] && [[ "$output" == *"NEED"* ]] && [[ "$output" == *"WEIGHTS"* ]] &&
    [[ "$output" == *"org/Alpha"* ]] && [[ "$output" == *"Memory (GB):"* ]]
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
    FAKE_SWAPFILE_USED_MIB=0 FAKE_SWAPPINESS=10 "$SPARK" doctor 2>&1 || true)
  rm -rf "$tmp"
  [[ "$setup_out" == *"Swap: on (131072MiB total) via swapon (free=0MiB)"* ]] &&
    [[ "$setup_out" == *"failed=0"* ]] &&
    [[ "$doctor_out" == *"Swap: on (131072MiB total) via swapon (free=0MiB)"* ]] &&
    [[ "$doctor_out" != *"Swap/swappiness not configured"* ]]
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
    [[ "$out" == *"reserved 80.1"* ]] && [[ "$out" == *"now 84.0"* ]] && [[ "$out" == *"peak 90.0"* ]]
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

test_workspace_setup_rejects_bad_tailscale_mode() {
  local out status
  set +e
  out=$("$SPARK" ws setup --tailscale-mode public </dev/null 2>&1); status=$?
  set -e
  [[ "$status" -ne 0 ]] && [[ "$out" == *"--tailscale-mode must be 'services' or 'ports'"* ]]
}

test_workspace_setup_rejects_bad_image_ref() {
  local tmp out status mutated=0
  tmp=$(mktemp -d)
  set +e
  out=$(HOME="${tmp}/home" "$SPARK" ws setup --check --model Org/Alpha \
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
    "$SPARK" ws setup --yes --model Org/Alpha 2>&1)
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
    FAKE_TAILSCALE_STATUS_EXIT=0 "$SPARK" ws setup --check --model Org/Alpha 2>&1)
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  before=$(cat "$env_file")
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_VIKUNJA_USER_EXIT=1 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --check --model Org/Alpha 2>&1)
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
    "$SPARK" ws setup --check --model Org/Alpha 2>&1)
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
    FAKE_TAILSCALE_STATUS_EXIT=0 "$SPARK" ws setup --check 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"Choose the model Hermes will use"* ]] && [[ "$out" == *"Org/Alpha"* ]] && [[ "$out" == *"Org/Beta"* ]]
}

test_workspace_setup_starts_model_detached() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Org/Alpha" "$KV_CONFIG"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_TOTAL_MEM_GB=121 \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.05-py3" FAKE_NAMES='spark-litellm\n' \
    "$SPARK" ws setup --yes --model Org/Alpha 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"Container '"*"started"* ]] &&
    [[ "$out" == *"Logs: "*"spark logs Org/Alpha"* ]] &&
    [[ "$out" != *"waiting for it to serve"* ]]
}

test_workspace_setup_writes_compose_names() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out compose init tailscale_calls nemo_calls curl_calls env postgres_env vikunja_env n8n_env workspace_mode compose_mode gateway_mode litellm_mode
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_FILE="${tmp}/tailscale.log" \
    FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_CURL_FILE="${tmp}/curl.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --yes --model Org/Alpha 2>&1 || true)
  compose=$(cat "${tmp}/home/.config/spark/workspace/docker-compose.yml" 2>/dev/null || echo "")
  init=$(cat "${tmp}/home/.config/spark/workspace/init-db.sh" 2>/dev/null || echo "")
  tailscale_calls=$(cat "${tmp}/tailscale.log" 2>/dev/null || echo "")
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  curl_calls=$(cat "${tmp}/curl.log" 2>/dev/null || echo "")
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  postgres_env=$(cat "${tmp}/home/.config/spark/workspace/postgres.env" 2>/dev/null || echo "")
  vikunja_env=$(cat "${tmp}/home/.config/spark/workspace/vikunja.env" 2>/dev/null || echo "")
  n8n_env=$(cat "${tmp}/home/.config/spark/workspace/n8n.env" 2>/dev/null || echo "")
  workspace_mode=$(stat -c '%a' "${tmp}/home/.config/spark/workspace" 2>/dev/null || stat -f '%Lp' "${tmp}/home/.config/spark/workspace" 2>/dev/null || echo "")
  compose_mode=$(stat -c '%a' "${tmp}/home/.config/spark/workspace/docker-compose.yml" 2>/dev/null || stat -f '%Lp' "${tmp}/home/.config/spark/workspace/docker-compose.yml" 2>/dev/null || echo "")
  gateway_mode=$(stat -c '%a' "${tmp}/home/.config/spark/gateway.json" 2>/dev/null || stat -f '%Lp' "${tmp}/home/.config/spark/gateway.json" 2>/dev/null || echo "")
  litellm_mode=$(stat -c '%a' "${tmp}/home/.config/spark/litellm_config.yaml" 2>/dev/null || stat -f '%Lp' "${tmp}/home/.config/spark/litellm_config.yaml" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"Workspace complete"* ]] && [[ "$compose" == *"  vikunja:"* ]] &&
    [[ "$compose" == *"  postgres:"* ]] && [[ "$compose" == *"  n8n:"* ]] &&
    [[ "$compose" == *"postgres.env"* ]] && [[ "$compose" == *"vikunja.env"* ]] &&
    [[ "$compose" == *"n8n.env"* ]] && [[ "$compose" != *"secrets.env"* ]] &&
    [[ "$compose" == *"image: postgres:18"* ]] &&
    [[ "$compose" == *"image: vikunja/vikunja:latest"* ]] &&
    [[ "$compose" == *"image: docker.n8n.io/n8nio/n8n:latest"* ]] &&
    [[ "$compose" != *"vikunja-db"* ]] && [[ "$compose" != *"n8n-db"* ]] &&
    [[ "$compose" != *"spark-vikunja"* ]] && [[ "$init" == *"CREATE DATABASE vikunja"* ]] &&
    [[ "$init" == *"CREATE DATABASE n8n"* ]] && [[ "$init" == *"WHERE NOT EXISTS"* ]] &&
    [[ "$init" == *"ALTER USER vikunja"* ]] && [[ "$init" == *"ALTER USER n8n"* ]] &&
    [[ "$(grep -c 'no-new-privileges:true' <<< "$compose")" -ge 3 ]] &&
    [[ "$(grep -c 'init: true' <<< "$compose")" -ge 3 ]] &&
    [[ "$(grep -c 'stop_grace_period: 30s' <<< "$compose")" -ge 3 ]] &&
    [[ "$(grep -c 'max-size: "10m"' <<< "$compose")" -ge 3 ]] &&
    [[ "$(grep -c 'max-file: "5"' <<< "$compose")" -ge 3 ]] &&
    [[ "$tailscale_calls" == *"serve --bg --service=svc:vikunja --https=443 --yes http://127.0.0.1:3456"* ]] &&
    [[ "$nemo_calls" == *"onboard --non-interactive --yes-i-accept-third-party-software --yes --no-gpu --control-ui-port 18789"* ]] &&
    [[ "$nemo_calls" == *"NEMOCLAW_AGENT=hermes"* ]] &&
    [[ "$nemo_calls" == *"NEMOCLAW_PREFERRED_API=openai-completions"* ]] &&
    [[ "$nemo_calls" == *"NEMOCLAW_LOCAL_INFERENCE_TIMEOUT=300"* ]] &&
    [[ "$nemo_calls" == *"NEMOCLAW_SANDBOX_READY_TIMEOUT=600"* ]] &&
    [[ "$nemo_calls" == *"NEMOCLAW_NO_GPU=1"* ]] &&
    [[ "$nemo_calls" == *"NEMOCLAW_SANDBOX_GPU=0"* ]] &&
    [[ "$nemo_calls" == *"CHAT_UI_URL=https://hermes.test-tailnet.ts.net"* ]] &&
    [[ "$curl_calls" == *'"expires_at":"2099-12-31T23:59:59Z"'* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=services"* ]] &&
    [[ "$env" == *"HERMES_DASHBOARD_PORT=18789"* ]] &&
    [[ "$env" == *"HERMES_LITELLM_MODEL=vllm/Org/Alpha"* ]] &&
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
    [[ "$env" == *"VIKUNJA_HERMES_USER_STATUS=exists"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_API_TOKEN=vk_auto_hermes"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_API_STATUS=verified"* ]] &&
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes 2>&1)
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes 2>&1)
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  printf '%s\n' 'POSTGRES_PASSWORD=duplicate' 'BROKEN LINE' >> "$env_file"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_BACKUP_SUFFIX=testbackup \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --yes 2>&1)
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes 2>&1)
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
    "$SPARK" ws setup --yes --model Org/Alpha 2>&1)
  status=$?
  set -e
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Hermes onboarding failed"* ]] &&
    [[ "$out" == *"Workspace incomplete"* ]] &&
    [[ "$env" == *"HERMES_ONBOARD_STATUS=manual"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$env" == *"VIKUNJA_URL=https://vikunja.test-tailnet.ts.net"* ]] &&
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
    "$SPARK" ws setup --yes --model Org/Alpha 2>&1)
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
    "$SPARK" ws setup --yes --model Org/Alpha --tailscale-mode ports 2>&1)
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
    "$SPARK" ws setup --yes --model Org/Alpha --tailscale-mode ports \
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
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
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
    "$SPARK" ws setup --yes --model Org/Alpha 2>&1 || true)
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  tailscale_calls=$(cat "${tmp}/tailscale.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"Tailscale is older than 1.86; attempting update"* ]] &&
    [[ "$out" == *"Tailscale updated"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=services"* ]] &&
    [[ "$tailscale_calls" == *"update"* ]] &&
    [[ "$tailscale_calls" == *"serve --bg --service=svc:vikunja"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha --tailscale-mode ports >/dev/null 2>&1 || true
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_STATUS_JSON='{"MagicDNSSuffix":"test-tailnet.ts.net.","Self":{"DNSName":"sparkbox.test-tailnet.ts.net.","TailscaleIPs":["100.64.0.10","fd7a:115c:a1e0::10"]}}' \
    FAKE_TAILSCALE_IP=100.64.0.10 FAKE_TAILSCALE_FILE="${tmp}/tailscale.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --yes --model Org/Alpha 2>&1 || true)
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  tailscale_calls=$(cat "${tmp}/tailscale.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"Tailscale Services configured"* || "$out" == *"Workspace drift detected; reconciling"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=services"* ]] &&
    [[ "$env" == *"VIKUNJA_URL=https://vikunja.test-tailnet.ts.net"* ]] &&
    [[ "$env" == *"N8N_URL=https://n8n.test-tailnet.ts.net"* ]] &&
    [[ "$env" == *"HERMES_URL=https://hermes.test-tailnet.ts.net"* ]] &&
    [[ "$tailscale_calls" == *"serve --bg --service=svc:vikunja --https=443 --yes http://127.0.0.1:3456"* ]] &&
    [[ "$tailscale_calls" == *"serve --bg --service=svc:n8n --https=443 --yes http://127.0.0.1:5678"* ]] &&
    [[ "$tailscale_calls" == *"serve --bg --service=svc:hermes --https=443 --yes http://127.0.0.1:18789"* ]]
}

test_workspace_setup_skips_hermes_when_services_fail() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out status env nemo_calls vikunja_env n8n_env
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_TAILSCALE_SERVE_EXIT=1 FAKE_TAILSCALE_GET_CONFIG_EXIT=1 FAKE_TAILSCALE_SERVE_CONFIG='not-configured' FAKE_NEMOHERMES_FILE="${tmp}/nemohermes.log" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --yes --model Org/Alpha 2>&1)
  status=$?
  set -e
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  vikunja_env=$(cat "${tmp}/home/.config/spark/workspace/vikunja.env" 2>/dev/null || echo "")
  n8n_env=$(cat "${tmp}/home/.config/spark/workspace/n8n.env" 2>/dev/null || echo "")
  nemo_calls=$(cat "${tmp}/nemohermes.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Could not configure Tailscale Services automatically"* ]] &&
    [[ "$out" == *"Hermes onboarding skipped until Tailscale private access is configured"* ]] &&
    [[ "$env" == *"WORKSPACE_TAILSCALE_MODE=manual"* ]] &&
    grep -qx 'VIKUNJA_URL=' <<< "$env" &&
    grep -qx 'N8N_URL=' <<< "$env" &&
    grep -qx 'HERMES_URL=' <<< "$env" &&
    grep -qx 'VIKUNJA_SERVICE_PUBLICURL=' <<< "$vikunja_env" &&
    grep -qx 'N8N_HOST=' <<< "$n8n_env" &&
    grep -qx 'N8N_PROTOCOL=http' <<< "$n8n_env" &&
    grep -qx 'N8N_SECURE_COOKIE=false' <<< "$n8n_env" &&
    grep -qx 'N8N_EDITOR_BASE_URL=' <<< "$n8n_env" &&
    grep -qx 'WEBHOOK_URL=' <<< "$n8n_env" &&
    [[ "$env" == *"HERMES_ONBOARD_STATUS=manual"* ]] &&
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
    "$SPARK" ws setup --yes --model Org/Alpha 2>&1)
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
    "$SPARK" ws setup --yes --model Org/Alpha --funnel-action reset 2>&1)
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
    "$SPARK" ws setup --check --model Org/Alpha 2>&1)
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  calls=$(cat "${tmp}/compose-exec.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$calls" == *"CREATE USER vikunja"* ]] &&
    [[ "$calls" == *"CREATE DATABASE vikunja"* ]] &&
    [[ "$calls" == *"CREATE USER n8n"* ]] &&
    [[ "$calls" == *"CREATE DATABASE n8n"* ]]
}

test_workspace_setup_manual_token_fallback() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out env
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_VIKUNJA_TOKEN_CREATE_EXIT=1 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --yes --model Org/Alpha 2>&1 || true)
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"Create a Vikunja API token for user 'hermes' in the UI"* ]] &&
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  count=$(cat "${tmp}/vikunja-count" 2>/dev/null || echo 0)
  rm -rf "$tmp"
  [[ "$count" -ge 2 ]] &&
    [[ "$env" == *"VIKUNJA_HUMAN_USER_STATUS=exists"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_USER_STATUS=exists"* ]] &&
    [[ "$env" != *"VIKUNJA_HUMAN_PASSWORD=secret123"* ]]
}

test_workspace_setup_creates_hermes_with_valid_email() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin calls
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_COMPOSE_EXEC_FILE="${tmp}/compose-exec.log" \
    FAKE_VIKUNJA_USER_LIST='| 1 | massimo | m@example.com | active |\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  calls=$(cat "${tmp}/compose-exec.log" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$calls" == *"user create -u hermes -e hermes@spark.invalid"* ]] &&
    [[ "$calls" != *"hermes@local"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha 2>&1 || true)
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"Vikunja user not verified: massimo"* ]] &&
    [[ "$env" == *"VIKUNJA_HUMAN_PASSWORD="* ]] &&
    [[ "$env" != *"VIKUNJA_HUMAN_PASSWORD=secret123"* ]] &&
    [[ "$env" == *"VIKUNJA_HUMAN_USER_STATUS=manual"* ]]
}

test_workspace_setup_preserves_existing_secrets() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env_file pg_before vdb_before n8n_before token_after pg_after vdb_after n8n_after
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  pg_before=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$env_file")
  vdb_before=$(sed -n 's/^VIKUNJA_DATABASE_PASSWORD=//p' "$env_file")
  n8n_before=$(sed -n 's/^DB_POSTGRESDB_PASSWORD=//p' "$env_file")
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=changed123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=changed456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --yes --model Org/Alpha --vikunja-token vk_keep >/dev/null 2>&1 || true
  pg_after=$(sed -n 's/^POSTGRES_PASSWORD=//p' "$env_file")
  vdb_after=$(sed -n 's/^VIKUNJA_DATABASE_PASSWORD=//p' "$env_file")
  n8n_after=$(sed -n 's/^DB_POSTGRESDB_PASSWORD=//p' "$env_file")
  token_after=$(sed -n 's/^VIKUNJA_HERMES_API_TOKEN=//p' "$env_file")
  rm -rf "$tmp"
  [[ -n "$pg_before" ]] && [[ "$pg_before" == "$pg_after" ]] &&
    [[ "$vdb_before" == "$vdb_after" ]] &&
    [[ "$n8n_before" == "$n8n_after" ]] &&
    [[ "$token_after" == "vk_keep" ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha </dev/null 2>&1)
  status=$?
  set -e
  [[ -f "$env_file" ]] && env=$(cat "$env_file")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Workspace username is required"* ]] &&
    [[ "$env" != *"✗"* ]] &&
    [[ "$env" != *"is required"* ]]
}

test_workspace_setup_ignores_password_overrides_and_generates_secrets() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out env human_pass n8n_pass
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD='bad"secret' SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD='bad"secret' FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --yes --model Org/Alpha </dev/null 2>&1 || true)
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  human_pass=$(sed -n 's/^VIKUNJA_HUMAN_RECOVERY_PASSWORD=//p' <<< "$env")
  n8n_pass=$(sed -n 's/^N8N_BASIC_AUTH_PASSWORD=//p' <<< "$env")
  rm -rf "$tmp"
  [[ "$out" == *"SPARK_WORKSPACE_VIKUNJA_PASSWORD is ignored"* ]] &&
    [[ "$out" == *"SPARK_WORKSPACE_N8N_PASSWORD is ignored"* ]] &&
    [[ -n "$human_pass" ]] &&
    [[ -n "$n8n_pass" ]] &&
    [[ "$human_pass" != 'bad"secret' ]] &&
    [[ "$n8n_pass" != 'bad"secret' ]] &&
    [[ "$human_pass" != "$n8n_pass" ]] &&
    [[ "$env" == *"VIKUNJA_HUMAN_PASSWORD="* ]] &&
    [[ "$env" != *"VIKUNJA_HUMAN_PASSWORD=bad"* ]]
}

test_workspace_setup_interactive_shared_credentials() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin input env n8n_env calls user human_pass n8n_pass
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  user=$(whoami)
  input=$'y\nm@example.com\n'
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm SPARK_ASSUME_INTERACTIVE=1 \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_COMPOSE_EXEC_FILE="${tmp}/compose-exec.log" \
    FAKE_NAMES='spark-litellm\n' \
    FAKE_VIKUNJA_USER_LIST='| 2 | hermes | hermes@spark.invalid | active |\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --model Org/Alpha <<< "$input" >/dev/null 2>&1 || true
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  n8n_env=$(cat "${tmp}/home/.config/spark/workspace/n8n.env" 2>/dev/null || echo "")
  calls=$(cat "${tmp}/compose-exec.log" 2>/dev/null || echo "")
  human_pass=$(sed -n 's/^VIKUNJA_HUMAN_RECOVERY_PASSWORD=//p' <<< "$env")
  n8n_pass=$(sed -n 's/^N8N_BASIC_AUTH_PASSWORD=//p' <<< "$env")
  rm -rf "$tmp"
  [[ "$env" == *"VIKUNJA_HUMAN_USERNAME=${user}"* ]] &&
    [[ "$env" == *"VIKUNJA_HUMAN_EMAIL=m@example.com"* ]] &&
    [[ "$env" == *"VIKUNJA_HUMAN_RECOVERY_PASSWORD="* ]] &&
    [[ "$env" == *"N8N_BASIC_AUTH_USER=m@example.com"* ]] &&
    [[ -n "$human_pass" ]] &&
    [[ -n "$n8n_pass" ]] &&
    [[ "$human_pass" != "$n8n_pass" ]] &&
    [[ "$n8n_env" == *"N8N_BASIC_AUTH_USER=m@example.com"* ]] &&
    [[ "$n8n_env" == *"N8N_BASIC_AUTH_PASSWORD=${n8n_pass}"* ]] &&
    [[ "$calls" == *"user create -u ${user} -e m@example.com -p ${human_pass}"* ]]
}

test_workspace_credentials_show_outputs_recovery_secrets() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env out human_pass n8n_pass
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  human_pass=$(sed -n 's/^VIKUNJA_HUMAN_RECOVERY_PASSWORD=//p' <<< "$env")
  n8n_pass=$(sed -n 's/^N8N_BASIC_AUTH_PASSWORD=//p' <<< "$env")
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws credentials show 2>&1)
  rm -rf "$tmp"
  [[ -n "$human_pass" ]] &&
    [[ -n "$n8n_pass" ]] &&
    [[ "$out" == *"spark ws credentials"* ]] &&
    [[ "$out" == *"recovery password: ${human_pass}"* ]] &&
    [[ "$out" == *"recovery password: ${n8n_pass}"* ]]
}

test_workspace_credentials_reset_rotates_local_secrets() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env n8n_env old_human old_n8n old_token new_human new_n8n new_token compose_exec
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_EMAIL=m@example.com FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env")
  old_human=$(sed -n 's/^VIKUNJA_HUMAN_RECOVERY_PASSWORD=//p' <<< "$env")
  old_n8n=$(sed -n 's/^N8N_BASIC_AUTH_PASSWORD=//p' <<< "$env")
  old_token=$(sed -n 's/^VIKUNJA_HERMES_API_TOKEN=//p' <<< "$env")
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" ws credentials reset vikunja >/dev/null 2>&1
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' FAKE_COMPOSE_EXEC_FILE="${tmp}/compose-exec.log" \
    "$SPARK" ws credentials reset n8n >/dev/null 2>&1
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_VIKUNJA_CREATED_TOKEN=vk_rotated_hermes \
    "$SPARK" ws credentials reset hermes >/dev/null 2>&1
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env")
  n8n_env=$(cat "${tmp}/home/.config/spark/workspace/n8n.env")
  compose_exec=$(cat "${tmp}/compose-exec.log" 2>/dev/null || echo "")
  new_human=$(sed -n 's/^VIKUNJA_HUMAN_RECOVERY_PASSWORD=//p' <<< "$env")
  new_n8n=$(sed -n 's/^N8N_BASIC_AUTH_PASSWORD=//p' <<< "$env")
  new_token=$(sed -n 's/^VIKUNJA_HERMES_API_TOKEN=//p' <<< "$env")
  rm -rf "$tmp"
  [[ -n "$old_human" ]] &&
    [[ -n "$old_n8n" ]] &&
    [[ -n "$old_token" ]] &&
    [[ -n "$new_human" ]] &&
    [[ -n "$new_n8n" ]] &&
    [[ -n "$new_token" ]] &&
    [[ "$old_human" != "$new_human" ]] &&
    [[ "$old_n8n" != "$new_n8n" ]] &&
    [[ "$old_token" != "$new_token" ]] &&
    [[ "$new_token" == "vk_rotated_hermes" ]] &&
    [[ "$n8n_env" == *"N8N_BASIC_AUTH_PASSWORD=${new_n8n}"* ]] &&
    [[ "$env" == *"VIKUNJA_HUMAN_USER_STATUS=manual"* ]] &&
    [[ "$env" == *"N8N_OWNER_SETUP_STATUS=exists"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_API_STATUS=verified"* ]] &&
    [[ "$compose_exec" == *"n8n user-management:reset"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha 2>&1 || true)
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
    "$SPARK" ws setup --yes --model Org/Alpha </dev/null 2>&1)
  status=$?
  set -e
  env=$(cat "$env_file")
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Ignoring invalid stored n8n admin/basic-auth password"* ]] &&
    [[ "$out" == *"Workspace username is required"* ]] &&
    [[ "$env" != *"✗"* ]] &&
    [[ "$env" != *"is required"* ]]
}

test_workspace_remote_delegates() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_REMOTE_SPARK_VERSION="$SPARK_VERSION" \
    "$SPARK" ws setup --check --remote me@10.0.0.5 --model Org/Alpha \
      --tailscale-mode ports --postgres-image postgres:18.1 \
      --vikunja-image vikunja/vikunja:1.2.3 --n8n-image docker.n8n.io/n8nio/n8n:1.100.0 2>&1 || true)
  rm -rf "$tmp"
  [[ "$out" == *"Installed spark CLI v${SPARK_VERSION}"* ]] && [[ "$out" == *"remote workspace with opts ok"* ]]
}

test_workspace_remote_delegates_credentials() {
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" FAKE_REMOTE_SPARK_VERSION="$SPARK_VERSION" \
    "$SPARK" ws setup --yes --remote me@10.0.0.5 --model Org/Alpha \
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
    "$SPARK" ws setup --check --remote me@10.0.0.5 --model Org/Alpha \
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  rm -rf "$tmp"
    [[ "$out" == *"Workspace doctor passed"* ]] &&
    [[ "$out" == *"[x] Compose service running: postgres"* ]] &&
    [[ "$out" == *"[x] Human Vikunja password is not stored"* ]] &&
    [[ "$out" == *"[x] Scoped service env files exist and are 0600"* ]] &&
    [[ "$out" == *"[x] Docker Compose config is valid"* ]] &&
    [[ "$out" == *"[x] Compose uses scoped env files, not full secrets.env"* ]] &&
    [[ "$out" == *"[x] Compose image refs are recorded and used"* ]] &&
    [[ "$out" == *"[x] Compose applies runtime hardening and log rotation"* ]] &&
    [[ "$out" == *"[x] Shared Postgres initializes Vikunja and n8n DBs"* ]] &&
    [[ "$out" == *"[x] Vikunja HTTP endpoint ready"* ]] &&
    [[ "$out" == *"[x] n8n HTTP endpoint ready"* ]] &&
    [[ "$out" == *"[x] Workspace URLs configured"* ]] &&
    [[ "$out" == *"[x] Workspace credentials are unique per service"* ]] &&
    [[ "$out" == *"[x] Vikunja human user exists"* ]] &&
    [[ "$out" == *"[x] Vikunja hermes user exists"* ]] &&
    [[ "$out" == *"[x] Vikunja hermes API token works"* ]] &&
    [[ "$out" == *"[x] n8n hardened for private agent workflows"* ]] &&
    [[ "$out" == *"[x] n8n owner/admin login ready"* ]] &&
    [[ "$out" == *"[x] Tailscale supports selected private access mode"* ]] &&
    [[ "$out" == *"[x] Tailscale private access configured for vikunja, n8n, hermes"* ]] &&
    [[ "$out" == *"[x] Tailscale mode is Services or ports"* ]] &&
    [[ "$out" == *"[x] Tailscale workspace URLs respond"* ]] &&
    [[ "$out" == *"[x] No workspace/gateway port is published on 0.0.0.0"* ]] &&
    [[ "$out" == *"[x] Host listeners for workspace/gateway are loopback-only"* ]] &&
    [[ "$out" == *"[x] Shared Postgres runtime has Vikunja and n8n roles/databases"* ]] &&
    [[ "$out" == *"[x] LiteLLM exposes Hermes model route"* ]] &&
    [[ "$out" == *"[x] Vikunja internal doctor passes"* ]] &&
    [[ "$out" == *"[x] Hermes NemoClaw uses restricted policy and private API port"* ]] &&
    [[ "$out" == *"[x] NemoHermes sandbox doctor passes"* ]] &&
    [[ "$out" == *"[x] NemoHermes inference route uses selected LiteLLM model"* ]] &&
    [[ "$out" == *"[x] Hermes private API URL is reachable"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --strict --model Org/Alpha 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"Workspace doctor passed"* ]] &&
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --json --model Org/Alpha)
  rm -rf "$tmp"
  printf '%s' "$out" | jq -e '
    .ok == true and
    .failed == 0 and
    .model == "Org/Alpha" and
    ([.checks[] | select(.label == "LiteLLM exposes Hermes model route" and .ok == true)] | length == 1) and
    ([.checks[] | select(.label == "NemoHermes inference route uses selected LiteLLM model" and .ok == true)] | length == 1) and
    ([.checks[] | select(.label == "Tailscale workspace URLs respond" and .ok == true)] | length == 1)
  ' >/dev/null
}

test_workspace_status_health_summary() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws status 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"Workspace health"* ]] &&
    [[ "$out" == *"[x] Compose postgres"* ]] &&
    [[ "$out" == *"[x] Vikunja HTTP local"* ]] &&
    [[ "$out" == *"[x] Tailscale URLs"* ]] &&
    [[ "$out" == *"[x] No public listeners"* ]] &&
    [[ "$out" == *"[x] LiteLLM Hermes route"* ]] &&
    [[ "$out" == *"[x] Hermes/NemoClaw"* ]] &&
    [[ "$out" == *"[x] NemoHermes inference route"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha --tailscale-mode ports >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    [[ "$out" == *"[ ] Tailscale private access configured for vikunja, n8n, hermes"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  doctor_output=$'  ✗ Ownership match: directory owned by gid 1000 but Vikunja process is not a member of that group\n  ✓ Writable: yes\n\n1 check(s) failed\n'
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_VIKUNJA_DOCTOR_EXIT=1 FAKE_VIKUNJA_DOCTOR_OUTPUT="$doctor_output" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    [[ "$out" == *"[ ] Vikunja hermes API token works"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha --tailscale-mode ports >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha --tailscale-mode ports >/dev/null 2>&1 || true
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
    [[ "$out" == *"[ ] Tailscale private access configured for vikunja, n8n, hermes"* ]] &&
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_N8N_LOGIN_EXIT=1 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] n8n owner/admin login ready"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    [[ "$out" == *"[ ] Human Vikunja password is not stored"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  env_file="${tmp}/home/.config/spark/workspace/secrets.env"
  secret=$(sed -n 's/^VIKUNJA_HUMAN_RECOVERY_PASSWORD=//p' "$env_file")
  SECRET="$secret" awk '
    /^N8N_BASIC_AUTH_PASSWORD=/ { print "N8N_BASIC_AUTH_PASSWORD=" ENVIRON["SECRET"]; next }
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
    [[ "$out" == *"[ ] Workspace credentials are unique per service"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    [[ "$out" == *"[ ] NemoHermes sandbox doctor passes"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    [[ "$out" == *"[ ] Hermes NemoClaw uses restricted policy and private API port"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    [[ "$out" == *"[ ] Hermes private API URL is reachable"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_TAILSCALE_SERVE_CONFIG='svc:vikunja 127.0.0.1:3456\nsvc:n8n 127.0.0.1:5678' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Tailscale private access configured for vikunja, n8n, hermes"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_TAILSCALE_FUNNEL_EXIT=0 \
    FAKE_TAILSCALE_FUNNEL_STATUS='https://vikunja.example.com\n' \
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_TAILSCALE_SERVE_CONFIG='svc:vikunja 0.0.0.0:3456\nsvc:n8n 127.0.0.1:5678\nsvc:hermes 127.0.0.1:18789' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Tailscale private access configured for vikunja, n8n, hermes"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_TAILSCALE_SERVE_CONFIG='svc:vikunja 127.0.0.1:5678\nsvc:n8n 127.0.0.1:3456\nsvc:hermes 127.0.0.1:18789' \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  status=$?
  set -e
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"[ ] Tailscale private access configured for vikunja, n8n, hermes"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  serve_config=$'{
    "svc:vikunja": { "Handlers": { "/": { "Proxy": "http://127.0.0.1:3456" } } },
    "svc:n8n": { "Handlers": { "/": { "Proxy": "http://127.0.0.1:5678" } } },
    "svc:hermes": { "Handlers": { "/": { "Proxy": "http://127.0.0.1:18789" } } }
  }'
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    FAKE_TAILSCALE_STATUS_EXIT=0 FAKE_NAMES='spark-litellm\n' \
    FAKE_COMPOSE_SERVICES='postgres\nvikunja\nn8n\n' \
    FAKE_TAILSCALE_SERVE_CONFIG="$serve_config" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws doctor --model Org/Alpha 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"Workspace doctor passed"* ]] &&
    [[ "$out" == *"[x] Tailscale private access configured for vikunja, n8n, hermes"* ]]
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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

test_workspace_setup_accepts_vikunja_token() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin env
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_cached_model "${tmp}/home" "Org/Alpha"
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --yes --model Org/Alpha --vikunja-token vk_test >/dev/null 2>&1 || true
  env=$(cat "${tmp}/home/.config/spark/workspace/secrets.env" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$env" == *"VIKUNJA_HERMES_API_TOKEN=vk_test"* ]] &&
    [[ "$env" == *"VIKUNJA_HERMES_API_STATUS=verified"* ]]
}

test_workspace_setup_rejects_multiline_vikunja_token() {
  local tmp fake_bin out status mutated=0
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  set +e
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" \
    "$SPARK" ws setup --yes --model Org/Alpha --vikunja-token $'vk_test\nbad' 2>&1)
  status=$?
  set -e
  [[ -e "${tmp}/home/.config/spark/workspace/secrets.env" ]] && mutated=1
  rm -rf "$tmp"
  [[ "$status" -ne 0 ]] &&
    [[ "$out" == *"Vikunja Hermes API token must be a single line"* ]] &&
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=vllm \
    SPARK_WORKSPACE_VIKUNJA_USERNAME=massimo SPARK_WORKSPACE_VIKUNJA_EMAIL=m@example.com \
    SPARK_WORKSPACE_VIKUNJA_PASSWORD=secret123 SPARK_WORKSPACE_N8N_EMAIL=m@example.com \
    SPARK_WORKSPACE_N8N_PASSWORD=secret456 FAKE_TAILSCALE_STATUS_EXIT=0 \
    FAKE_N8N_LOGIN_EXIT=7 FAKE_N8N_LOGIN_AFTER_OWNER=1 FAKE_N8N_OWNER_MARKER="${tmp}/n8n.owner" \
    FAKE_MANAGED='spark-vllm-alpha\tOrg/Alpha\t8000\t1.0\t1.0\t0.0\n' \
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" ws setup --yes --model Org/Alpha >/dev/null 2>&1 || true
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
    "$SPARK" doctor 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"backend ollama"* ]] && [[ "$out" == *"Ollama service: reachable"* ]] &&
    [[ "$out" == *"Models: 1 pulled"* ]] && [[ "$out" != *"NGC"* ]]
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

# --- Capacity: context menu (auto vs fp8) when a model doesn't fit ---
# 30B: weights 14, KV@128K 12, need 28.1. Reserve 85 -> free 26: doesn't fit at 128K,
# but fits at 64K auto (need 21.6) or 128K fp8 (need 21.6).
# Reserved so the 30B doesn't fit at full context (budget 114 − 88 = 26 GB free), to exercise the
# fit menu — same free as before (when budget was 111 − 85).
RESERVE_85='spark-vllm-big\torg/big\t8000\t88.0\t73.0\t15.0\n'

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
    [[ "$out" == *"Not enough memory"* ]] &&
    [[ "$out" == *"Fits at up to 64K"* ]] &&
    [[ "$out" == *"up to 128K with fp8"* ]] &&
    [[ "$out" == *"docker run"* ]]
}

test_menu_choose_fp8_relaunches() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  printf '2\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_ASSUME_INTERACTIVE=1 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED="$RESERVE_85" FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" run Qwen/Qwen3-30B >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"--max-model-len 131072"* ]] && [[ "$dargs" == *"--kv-cache-dtype fp8"* ]]
}

test_menu_choose_auto_relaunches() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  printf '1\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_ASSUME_INTERACTIVE=1 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED="$RESERVE_85" FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" run Qwen/Qwen3-30B >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"--max-model-len 65536"* ]] && [[ "$dargs" != *"--kv-cache-dtype fp8"* ]]
}

test_menu_cancel_aborts() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  out=$(printf '3\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 \
    SPARK_ASSUME_INTERACTIVE=1 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED="$RESERVE_85" FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" run Qwen/Qwen3-30B 2>&1 || true)
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$out" == *"Aborted"* ]] && [[ -z "$dargs" ]]
}

test_autopull_menu_downloads_at_choice() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin dargs weights downloaded
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"; mkdir -p "${tmp}/home"
  # Not downloaded; sized from metadata. Reserve 85 -> doesn't fit at 128K. Pick option 2 (fp8 128K).
  printf '2\n' | HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_ASSUME_INTERACTIVE=1 \
    SPARK_TOTAL_MEM_GB=121 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED="$RESERVE_85" FAKE_DOCKER_ARGS_FILE="${tmp}/dargs.txt" \
    "$SPARK" run Qwen/Qwen3-30B >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/dargs.txt" 2>/dev/null || echo "")
  weights="${tmp}/home/.cache/huggingface/hub/models--Qwen--Qwen3-30B/snapshots/1/model-00001-of-00001.safetensors"
  downloaded=0; [[ -f "$weights" ]] && downloaded=1
  rm -rf "$tmp"
  [[ "$downloaded" -eq 1 ]] && [[ "$dargs" == *"--max-model-len 131072"* ]] && [[ "$dargs" == *"--kv-cache-dtype fp8"* ]]
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
# 30B NEED 28.1 → 28.1×1.25×1024 = ceil(35968) = 35968 MiB.
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
  # --memory cap = NEED + WARMUP_HEADROOM (default 20): (28.1+20)×1024 = ceil(49254.4) = 49255 MiB.
  # --memory-swap = cap + provisioned swap (64G): 49255 + 65536 = 114791 MiB (lets the load peak
  # spill to swap instead of cgroup-OOMing mid-load).
  [[ "$dargs" == *"--memory 49255m"* ]] && [[ "$dargs" == *"--memory-swap 114791m"* ]]
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
  # SPARK_WARMUP_HEADROOM_GB=30: (28.1+30)×1024 = ceil(59494.4) = 59495 MiB.
  HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-unified \
    SPARK_WARMUP_HEADROOM_GB=30 FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_DOCKER_ARGS_FILE="${tmp}/d.txt" "$SPARK" run Qwen/Qwen3-30B </dev/null >/dev/null 2>&1 || true
  dargs=$(cat "${tmp}/d.txt" 2>/dev/null || echo "")
  rm -rf "$tmp"
  [[ "$dargs" == *"--memory 59495m"* ]] && [[ "$dargs" != *"49255m"* ]]
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
  [[ "$out" == *"Refreshing model profile"* ]] && [[ "$sv" == "2" ]]
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
    schema_version:2, model:$m, generated:"2026-01-01", reasoning_parser:"", tool_call_parser:"",
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
    schema_version:2, model:$m, generated:"2026-01-01", reasoning_parser:"", tool_call_parser:"",
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
    "$SPARK" run Qwen/Qwen3-30B --dry-run </dev/null 2>&1)
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

# Discrete GPUs get a smaller OS reserve (2 → budget 119): the stacking case (108) fits.
test_budget_larger_on_discrete() {
  command -v jq >/dev/null 2>&1 || { printf "skip - jq not installed\n"; return 0; }
  local tmp fake_bin out
  tmp=$(mktemp -d); fake_bin="${tmp}/bin"; make_fake_bin "$fake_bin"
  make_model "${tmp}/home" "Qwen/Qwen3-30B" "$KV_CONFIG"
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_TOTAL_MEM_GB=121 SPARK_ACCEL=cuda-discrete \
    FAKE_DOCKER_IMAGE="nvcr.io/nvidia/vllm:26.04-py3" \
    FAKE_MANAGED='spark-vllm-big\torg/big\t8000\t80.0\t65.0\t15.0\n' \
    "$SPARK" run Qwen/Qwen3-30B --dry-run </dev/null 2>&1)
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
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" "$SPARK" list 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"MODEL"* ]] && [[ "$out" == *"Org/Alpha"* ]] && [[ "$out" == *"Org/Beta"* ]]
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
    FAKE_NEMOHERMES_STATUS=$'Hermes ready\nUpdate:   v2026.5.22 available\n' \
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
    [[ "$nemo_log" == *"NEMOCLAW_ENDPOINT_URL=http://127.0.0.1:4000/v1"* ]] &&
    [[ "$nemo_log" == *"NEMOCLAW_MODEL=vllm/Org/Alpha"* ]] &&
    [[ "$nemo_log" == *"NEMOCLAW_NO_GPU=1"* ]] &&
    [[ "$nemo_log" == *"NEMOCLAW_SANDBOX_GPU=0"* ]] &&
    [[ "$nemo_log" == *"COMPATIBLE_API_KEY=dummy"* ]]
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
    FAKE_NEMOHERMES_STATUS=$'Hermes ready\nUpdate:   v2026.5.22 available\n' \
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
    FAKE_NEMOHERMES_STATUS=$'Hermes ready\nUpdate:   v2026.5.22 available\n' \
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
  out=$(HOME="${tmp}/home" PATH="${fake_bin}:$PATH" SPARK_BACKEND=ollama \
    FAKE_OLLAMA_LIST="NAME\tID\tSIZE\tMOD\nqwen3:30b\tabc\t18\tGB\n" "$SPARK" status 2>&1)
  rm -rf "$tmp"
  [[ "$out" == *"qwen3:30b"* ]] && [[ "$out" == *"Engine: Ollama"* ]]
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
run_test "doctor reports missing NGC image without aborting" test_doctor_reports_no_ngc_image
run_test "doctor reports bad HF cache permissions" test_doctor_reports_bad_hf_cache_permissions
run_test "setup --check reports incomplete setup" test_setup_check_reports_incomplete
run_test "setup --check reports Tailscale Funnel" test_setup_check_reports_tailscale_funnel
run_test "doctor reports Tailscale Funnel risk" test_doctor_reports_tailscale_funnel
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
run_test "stop with no arg and many models asks which" test_stop_ambiguous_requires_target
run_test "status renders a table" test_status_renders_table
run_test "dashboard web writes product UI" test_dashboard_web_once_writes_product_ui
run_test "dashboard terminal renders product snapshot" test_dashboard_terminal_still_renders_snapshot
run_test "gateway add/remove toggles a provider" test_gateway_add_remove_provider
run_test "pull (vllm) reports ready" test_pull_vllm_ready
run_test "pull routes to Ollama on the ollama backend" test_pull_ollama_routes
run_test "list shows downloaded models" test_list_shows_models
run_test "list reports empty cache" test_list_empty
run_test "rm removes the right model dir" test_rm_removes_the_right_dir
run_test "rm removes multiple models" test_rm_removes_multiple_models
run_test "rm missing model deletes none" test_rm_missing_model_deletes_none
run_test "rm reports delete failure" test_rm_reports_delete_failure
run_test "rm errors on a model not in cache" test_rm_not_found
run_test "logs on ollama points to the service logs" test_logs_ollama_message
run_test "logs errors when no container exists" test_logs_vllm_no_container
run_test "config sets and shows auto-update" test_config_set_and_show
run_test "update prompts workspace tool updates one by one" test_update_prompts_workspace_tool_updates_one_by_one
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
run_test "workspace help renders only as ws" test_workspace_help_and_command
run_test "workspace setup --check does not write files" test_workspace_check_no_mutation
run_test "workspace setup --check preserves existing config" test_workspace_check_existing_config_no_mutation
run_test "workspace setup --check reports missing Compose plugin" test_workspace_check_reports_missing_compose_plugin
run_test "workspace setup model picker uses spark list data" test_workspace_model_tui_uses_list
run_test "workspace setup starts Hermes model detached" test_workspace_setup_starts_model_detached
run_test "workspace setup rejects invalid Tailscale mode" test_workspace_setup_rejects_bad_tailscale_mode
run_test "workspace setup rejects invalid Docker image refs" test_workspace_setup_rejects_bad_image_ref
run_test "workspace setup rejects multiline secrets" test_workspace_setup_rejects_multiline_secret
run_test "workspace setup writes compose services without spark prefix" test_workspace_setup_writes_compose_names
run_test "workspace setup fast-paths healthy workspace" test_workspace_setup_healthy_fast_path_no_mutation
run_test "workspace setup repairs compose drift without Hermes onboard" test_workspace_setup_repairs_compose_drift_without_hermes_onboard
run_test "workspace setup backs up and normalizes invalid env" test_workspace_setup_backs_up_and_normalizes_invalid_env
run_test "workspace setup refuses missing secret with data" test_workspace_setup_refuses_missing_secret_with_data
run_test "workspace setup fails when Hermes onboard fails" test_workspace_setup_fails_when_hermes_onboard_fails
run_test "workspace derives tailnet from Tailscale self DNSName" test_workspace_tailnet_from_self_dnsname
run_test "workspace setup requires tailnet URLs" test_workspace_setup_requires_tailnet_urls
run_test "workspace ports mode requires MagicDNS URLs" test_workspace_ports_requires_magicdns_urls
run_test "workspace supports Tailscale MagicDNS ports fallback" test_workspace_tailscale_ports_fallback
run_test "workspace setup updates old Tailscale for Services" test_workspace_setup_updates_old_tailscale_for_services
run_test "workspace setup defaults to services from ports workspace" test_workspace_setup_defaults_to_services_from_ports_workspace
run_test "workspace setup skips Hermes when Services fail" test_workspace_setup_skips_hermes_when_services_fail
run_test "workspace setup blocks Tailscale Funnel" test_workspace_setup_blocks_tailscale_funnel
run_test "workspace setup resets Tailscale Funnel with flag" test_workspace_setup_resets_tailscale_funnel_with_flag
run_test "workspace setup --check reports Funnel without reset" test_workspace_setup_check_reports_funnel_without_reset
run_test "workspace setup repairs shared Postgres runtime" test_workspace_setup_repairs_shared_postgres_runtime
run_test "workspace setup falls back to manual Vikunja token" test_workspace_setup_manual_token_fallback
run_test "workspace setup waits for Vikunja CLI" test_workspace_setup_waits_for_vikunja_cli
run_test "workspace setup creates Hermes with valid email" test_workspace_setup_creates_hermes_with_valid_email
run_test "workspace setup never persists human password on Vikunja failure" test_workspace_setup_never_persists_human_password_on_vikunja_failure
run_test "workspace setup preserves existing secrets" test_workspace_setup_preserves_existing_secrets
run_test "workspace setup missing required values does not pollute env" test_workspace_setup_missing_required_values_do_not_pollute_env
run_test "workspace setup ignores password overrides and generates secrets" test_workspace_setup_ignores_password_overrides_and_generates_secrets
run_test "workspace setup interactive credentials are generated" test_workspace_setup_interactive_shared_credentials
run_test "workspace credentials show outputs recovery secrets" test_workspace_credentials_show_outputs_recovery_secrets
run_test "workspace credentials reset rotates local secrets" test_workspace_credentials_reset_rotates_local_secrets
run_test "workspace setup repairs polluted required env values" test_workspace_setup_repairs_polluted_required_env_values
run_test "workspace setup cleans polluted env before missing value abort" test_workspace_setup_cleans_polluted_env_before_missing_value_abort
run_test "workspace setup --remote delegates to remote spark" test_workspace_remote_delegates
run_test "workspace setup --remote delegates credentials safely" test_workspace_remote_delegates_credentials
run_test "workspace setup --remote --check does not forward credentials" test_workspace_remote_check_does_not_forward_credentials
run_test "workspace doctor --remote delegates doctor" test_workspace_doctor_remote_delegates_doctor
run_test "workspace doctor --strict --remote delegates doctor" test_workspace_doctor_remote_delegates_strict
run_test "workspace doctor checklist passes" test_workspace_doctor_checklist_passes
run_test "workspace doctor --strict checks pinned images only" test_workspace_doctor_strict_checks_pinned_images
run_test "workspace doctor --strict flags latest images" test_workspace_doctor_strict_flags_latest_images
run_test "workspace doctor --json emits structured checks" test_workspace_doctor_json
run_test "workspace status renders health summary" test_workspace_status_health_summary
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
run_test "workspace doctor flags wrong NemoHermes route" test_workspace_doctor_flags_wrong_nemohermes_route
run_test "workspace doctor flags NemoHermes doctor failure" test_workspace_doctor_flags_nemohermes_doctor_failure
run_test "workspace doctor flags wrong NemoClaw policy" test_workspace_doctor_flags_wrong_nemoclaw_policy
run_test "workspace doctor flags wrong Hermes dashboard URL" test_workspace_doctor_flags_wrong_hermes_dashboard_url
run_test "workspace doctor flags missing Tailscale Service config" test_workspace_doctor_flags_missing_tailscale_service_config
run_test "workspace doctor flags Tailscale Funnel enabled" test_workspace_doctor_flags_tailscale_funnel_enabled
run_test "workspace doctor rejects public Tailscale Service target" test_workspace_doctor_rejects_public_tailscale_service_target
run_test "workspace doctor rejects swapped Tailscale Service ports" test_workspace_doctor_rejects_swapped_tailscale_service_ports
run_test "workspace doctor accepts multiline Tailscale Service JSON" test_workspace_doctor_accepts_multiline_tailscale_service_json
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
run_test "workspace setup accepts Vikunja token" test_workspace_setup_accepts_vikunja_token
run_test "workspace setup rejects multiline Vikunja token" test_workspace_setup_rejects_multiline_vikunja_token
run_test "workspace setup rerun bootstraps n8n owner" test_workspace_setup_rerun_bootstraps_n8n_owner
run_test "workspace setup uses only n8n 2.x login field" test_workspace_setup_uses_only_n8n_2x_login_field

printf "\n%d passed, %d failed\n" "$passed" "$failed"
[[ "$failed" -eq 0 ]]
