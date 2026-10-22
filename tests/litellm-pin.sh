#!/usr/bin/env bash
# Based on spark by Massimo Angelini - https://github.com/massimo92/spark
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TASK_ROOT=$(mktemp -d)
trap 'rm -rf "$TASK_ROOT"' EXIT
export SPARK_BACKEND=vllm SPARK_ACCEL=cpu SPARK_TOTAL_MEM_GB=64
task_home="$TASK_ROOT/home"
mkdir -p "$task_home/.config/spark" "$task_home/.local/bin" "$TASK_ROOT/bin"
pin_file="$task_home/.config/spark/litellm-image"
pin="ghcr.io/berriai/litellm@sha256:$(printf '%064d' 1)"
printf '%s\n' "$pin" > "$pin_file"
cp "$ROOT/spark" "$task_home/.local/bin/spark"
cat > "$TASK_ROOT/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -eu
out=''
while [[ $# -gt 0 ]]; do
  case "$1" in -o) out="$2"; shift ;; esac
  shift
done
if [[ -n "$out" ]]; then cp "$PIN_TEST_CANDIDATE" "$out"; else cat "$PIN_TEST_CANDIDATE"; fi
CURL
cat > "$TASK_ROOT/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PIN_TEST_DOCKER_LOG"
exit 97
DOCKER
chmod +x "$TASK_ROOT/bin/"*
export PIN_TEST_DOCKER_LOG="$TASK_ROOT/docker.log"
export PATH="$task_home/.local/bin:$TASK_ROOT/bin:$PATH"

image_from() {
  HOME="$task_home" bash -c 'source "$1" || exit 1; printf "%s\n" "$LITELLM_IMAGE"' _ "$1"
}
[[ "$(image_from "$ROOT/spark")" == "$pin" ]]
printf 'ok - persisted pin overrides bundled image\n'

for version in 99.0.0 100.0.0; do
  candidate="$TASK_ROOT/spark-$version"
  sed -e "s/^VERSION=.*/VERSION=\"$version\"/" \
    -e 's|^LITELLM_IMAGE=.*|LITELLM_IMAGE="ghcr.io/berriai/litellm:future-tag"|' \
    "$ROOT/spark" > "$candidate"
  printf 'y\n' | HOME="$task_home" PIN_TEST_CANDIDATE="$candidate" \
    "$task_home/.local/bin/spark" update --spark > "$TASK_ROOT/update.log" 2>&1
  grep -q "^VERSION=\"$version\"$" "$task_home/.local/bin/spark"
  [[ "$(image_from "$task_home/.local/bin/spark")" == "$pin" ]]
  [[ "$(cat "$pin_file")" == "$pin" ]]
done
printf 'ok - two real CLI replacements preserve pin despite new defaults\n'

legacy="$TASK_ROOT/legacy"
printf '#!/usr/bin/env bash\nVERSION="101.0.0"\n' > "$legacy"
cp "$task_home/.local/bin/spark" "$TASK_ROOT/before"
printf 'y\n' | HOME="$task_home" PIN_TEST_CANDIDATE="$legacy" \
  "$task_home/.local/bin/spark" update --spark > "$TASK_ROOT/legacy.log" 2>&1
cmp "$TASK_ROOT/before" "$task_home/.local/bin/spark"
grep -q 'does not support the LiteLLM image pin' "$TASK_ROOT/legacy.log"
printf 'ok - incompatible CLI update leaves installed executable intact\n'

if HOME="$task_home" PIN_TEST_CANDIDATE="$legacy" bash "$ROOT/install.sh" > "$TASK_ROOT/install.log" 2>&1; then
  printf 'not ok - installer accepted an incompatible release\n' >&2; exit 1
fi
cmp "$TASK_ROOT/before" "$task_home/.local/bin/spark"
printf 'ok - installer rejects incompatible release before replacement\n'

# Exercise the automatic-update branch with a simulated interactive check.
HOME="$task_home" PIN_TEST_CANDIDATE="$legacy" bash -c '
  source "$1"
  get_update_config() { case "$1" in auto_update) echo true ;; esac; }
  save_update_config() { :; }
  detect_ngc_image() { :; }
  eval "$(declare -f check_for_updates | sed "/\[\[ ! -t 1 \]\]/d")"
  check_for_updates
' _ "$task_home/.local/bin/spark" > "$TASK_ROOT/auto.log" 2>&1
cmp "$TASK_ROOT/before" "$task_home/.local/bin/spark"
grep -q 'does not support the LiteLLM image pin' "$TASK_ROOT/auto.log"
printf 'ok - automatic update rejects incompatible release\n'

printf '$(touch %s)\n' "$TASK_ROOT/should-not-exist" > "$pin_file"
if image_from "$ROOT/spark" > "$TASK_ROOT/invalid.log" 2>&1; then exit 1; fi
grep -q 'Invalid LiteLLM image pin' "$TASK_ROOT/invalid.log"
[[ ! -e "$TASK_ROOT/should-not-exist" ]]
: > "$pin_file"
if image_from "$ROOT/spark" > /dev/null 2>&1; then exit 1; fi
printf '%s\n%s\n' "$pin" "$pin" > "$pin_file"
if image_from "$ROOT/spark" > /dev/null 2>&1; then exit 1; fi
printf 'ok - invalid, empty and multiline pins fail without fallback or execution\n'
rm "$pin_file"
[[ "$(image_from "$ROOT/spark")" == ghcr.io/berriai/litellm@sha256:* ]]
[[ ! -s "$PIN_TEST_DOCKER_LOG" ]]
printf 'ok - unpinned default works; no Docker commands or service changes\n'
