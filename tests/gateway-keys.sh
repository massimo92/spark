#!/usr/bin/env bash
# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export SPARK_BACKEND=vllm SPARK_ACCEL=cpu SPARK_GATEWAY_READY_ATTEMPTS=1
source "$ROOT/spark"
TEST_ROOT=$(mktemp -d)
fixture_pid=''
trap '[[ -z "$fixture_pid" ]] || kill "$fixture_pid" 2>/dev/null || true; rm -rf "$TEST_ROOT"' EXIT
mkdir "$TEST_ROOT/runtime"
printf 'sk-%064d\n' 1 > "$TEST_ROOT/runtime/admin"
touch "$TEST_ROOT/runtime/running"
python3 "$ROOT/tests/fixtures/virtual_keys.py" "$TEST_ROOT/runtime" > "$TEST_ROOT/fixture.log" 2>&1 & fixture_pid=$!
for ((attempt=0; attempt<50; attempt++)); do [[ ! -s "$TEST_ROOT/runtime/port" ]] || break; sleep 0.1; done
[[ -s "$TEST_ROOT/runtime/port" ]] || { cat "$TEST_ROOT/fixture.log"; exit 1; }
SPARK_CONFIG_DIR="$TEST_ROOT/config" GATEWAY_CONFIG="$TEST_ROOT/config/gateway.json" WORKSPACE_ENV_FILE="$TEST_ROOT/absent.env"
gateway_save_config "$(jq -nc --argjson port "$(cat "$TEST_ROOT/runtime/port")" '{enabled:true,port:$port,providers:{}}')"
gateway_auth_key() { cat "$TEST_ROOT/runtime/admin"; }
gateway_capabilities() { return 0; }
gateway_database_client_hashes() { jq '[.keys | to_entries[] | select(.value.user_id=="spark-clients") | .key] | sort' "$TEST_ROOT/runtime/database.json"; }
gateway_running_state() { [[ -f "$TEST_ROOT/runtime/running" ]]; }
gateway_sync_locked() { touch "$TEST_ROOT/runtime/running"; }
gateway_auth_terminal() { return 0; }
docker() {
  case "$1" in
    info) return 0 ;; inspect) printf 'virtual-keys\n' ;;
    stop) [[ ! -f "$TEST_ROOT/runtime/fail-stop" ]] || return 1; rm -f "$TEST_ROOT/runtime/running" ;;
    *) return 1 ;;
  esac
}
curl() { printf '%s\n' "$*" >> "$TEST_ROOT/curl.argv"; command curl "$@"; }
assert_private() {
  ! grep -rF "$1" "$SPARK_CONFIG_DIR"
  ! grep -F "$1" "$TEST_ROOT/runtime/database.json" "$TEST_ROOT/curl.argv"
}
gateway_auth_ensure
out=$(gateway_virtual_ensure 2>&1)
token=$(printf '%s\n' "$out" | sed -n '/^sk-/p')
[[ "$token" =~ ^sk-[a-f0-9]{64}$ ]]
[[ "$(printf '%s\n' "$out" | grep -c '^sk-')" == 1 ]]
gateway_auth_ready && gateway_virtual_validate "$token"
assert_private "$token"
printf 'ok - initial inference token appears once; files and DB contain no raw token\n'
out=$(gateway_virtual_ensure 2>&1)
[[ "$out" != *"$token"* ]]
if out=$(gateway_auth_command show 2>&1); then exit 1; fi
[[ "$out" != *"$token"* && "$out" == *'Usage: spark gateway auth <status|rotate|reset>'* ]]
out=$(gateway_auth_command status)
[[ "$out" == 'authentication: configured' ]]
printf 'ok - setup/status cannot recover tokens; removed show uses unknown-command handling\n'
gateway_virtual_validate "$token"
printf 'ok - inference token cannot access key-management endpoints\n'
old="$token"
out=$(gateway_auth_command rotate 2>&1)
token=$(printf '%s\n' "$out" | sed -n '/^sk-/p')
[[ "$token" != "$old" && "$out" != *"$old"* ]]
[[ "$(printf '%s\n' "$out" | grep -c '^sk-')" == 1 ]]
gateway_virtual_validate "$token"
! gateway_virtual_validate "$old"
assert_private "$token"
printf 'ok - rotation revokes old key immediately and displays replacement once\n'
gateway_auth_terminal() { return 1; }
before=$(gateway_database_client_hashes)
if out=$(gateway_auth_command rotate 2>&1); then exit 1; fi
[[ "$before" == "$(gateway_database_client_hashes)" && "$out" != *sk-* ]]
gateway_auth_terminal() { return 0; }
printf 'ok - redirected/noninteractive rotation fails before changing credentials\n'
old="$token"
gateway_save_config "$(gateway_load_config | jq 'del(.auth)')"
out=$(gateway_auth_command reset 2>&1)
token=$(printf '%s\n' "$out" | sed -n '/^sk-/p')
gateway_virtual_validate "$token"
! gateway_virtual_validate "$old"
assert_private "$token"
printf 'ok - lost token and lost local metadata recover through DB hashes\n'
touch "$TEST_ROOT/runtime/fail-after-commit"
if out=$(gateway_auth_command rotate 2>&1); then exit 1; fi
[[ "$out" != *sk-* && ! -e "$TEST_ROOT/runtime/running" ]]
! gateway_auth_ready
old="$token"
out=$(gateway_auth_command reset 2>&1)
token=$(printf '%s\n' "$out" | sed -n '/^sk-/p')
gateway_virtual_validate "$token"
! gateway_virtual_validate "$old"
assert_private "$token"
printf 'ok - ambiguous API commit stops gateway; reset recovers without restoring old keys\n'
# Migrate a legacy master key into a restricted inference key, without redisplay.
printf '{"keys":{},"users":{}}' > "$TEST_ROOT/runtime/database.json"
gateway_save_config "$(gateway_load_config | jq 'del(.auth)')"
gateway_env_set LITELLM_MASTER_KEY "$token"
out=$(gateway_virtual_ensure 2>&1)
[[ "$out" != *"$token"* ]]
gateway_virtual_validate "$token"
assert_private "$token"
printf 'ok - legacy token migrates to a hash and is removed from gateway.env\n'
touch "$TEST_ROOT/runtime/invalid-busy"
SPARK_GATEWAY_READY_ATTEMPTS=2 gateway_wait_ready
[[ ! -f "$TEST_ROOT/runtime/invalid-busy" ]]
touch "$TEST_ROOT/runtime/accept-anonymous"
! gateway_wait_ready 2>/dev/null
rm "$TEST_ROOT/runtime/accept-anonymous"
printf 'ok - readiness retries database errors and fails on actual anonymous access\n'
printf '{"keys":{},"users":{}}' > "$TEST_ROOT/runtime/database.json"
gateway_save_config "$(gateway_load_config | jq 'del(.auth)')"
gateway_auth_terminal() { return 1; }
out=$(gateway_virtual_ensure 2>&1)
gateway_auth_ready
[[ "$out" != *sk-* && "$out" == *'only its hash'* ]]
gateway_auth_terminal() { return 0; }
out=$(gateway_auth_command reset 2>&1)
token=$(printf '%s\n' "$out" | sed -n '/^sk-/p')
gateway_virtual_validate "$token"
assert_private "$token"
printf 'ok - unattended setup retains only an unrecoverable hash; interactive reset shows a new token\n'
hashes_implementation=$(declare -f gateway_database_client_hashes)
gateway_database_client_hashes() { return 1; }
if out=$(gateway_auth_command reset 2>&1); then exit 1; fi
[[ ! -e "$TEST_ROOT/runtime/running" && "$out" != *sk-* ]]
! gateway_auth_ready
eval "$hashes_implementation"
old="$token"
out=$(gateway_auth_command reset 2>&1)
token=$(printf '%s\n' "$out" | sed -n '/^sk-/p')
gateway_virtual_validate "$token"
! gateway_virtual_validate "$old"
assert_private "$token"
printf 'ok - incident reset stops the gateway if DB revocation cannot be verified\n'
gateway_database_client_hashes() { return 1; }
touch "$TEST_ROOT/runtime/fail-stop"
if out=$(gateway_auth_command reset 2>&1); then exit 1; fi
[[ -e "$TEST_ROOT/runtime/running" && "$out" == *'NOT confirmed'* && "$out" != *sk-* ]]
rm "$TEST_ROOT/runtime/fail-stop"
eval "$hashes_implementation"
old="$token"
out=$(gateway_auth_command reset 2>&1)
token=$(printf '%s\n' "$out" | sed -n '/^sk-/p')
gateway_virtual_validate "$token"
! gateway_virtual_validate "$old"
assert_private "$token"
printf 'ok - stop failure reports unconfirmed revocation; a later reset recovers safely\n'
printf '12 virtual-key checks passed\n'
