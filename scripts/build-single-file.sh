#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT_DIR}/spark"
CHECK=0

case "${1:-}" in
  --check) CHECK=1 ;;
  "") ;;
  *) printf 'Usage: %s [--check]\n' "$0" >&2; exit 2 ;;
esac

MODULES=(
  "src/00_bootstrap.sh"
  "src/commands/05_bundle.sh"
  "src/commands/10_runtime.sh"
  "src/commands/20_dashboard.sh"
  "src/commands/30_status_doctor.sh"
  "src/commands/40_setup.sh"
  "src/commands/50_workspace.sh"
  "src/commands/60_product.sh"
  "src/lib/70_gateway_update.sh"
  "src/90_main.sh"
)

tmp="$(mktemp "${OUT}.tmp.XXXXXX")"
cleanup() { [[ -z "${tmp:-}" ]] || rm -f "$tmp"; }
trap cleanup EXIT

emit_builtin_bundle_assets() {
  local root="${ROOT_DIR}/bundles" asset rel encoded index
  index="$(mktemp)"
  if [[ -d "$root" ]]; then
    while IFS= read -r asset; do
      rel="${asset#"${root}"/}"
      encoded=$(base64 < "$asset" | tr -d '\n')
      printf '%s\t%s\n' "$rel" "$encoded" >> "$index"
    done < <(find "$root" -type f | LC_ALL=C sort)
  fi
  {
    printf "spark_builtin_bundle_assets() { cat <<'__SPARK_BUNDLE_ASSETS__'\n"
    cat "$index"
    printf '__SPARK_BUNDLE_ASSETS__\n}\n'
  } >> "$tmp"
  rm -f "$index"
}

for module in "${MODULES[@]}"; do
  path="${ROOT_DIR}/${module}"
  [[ -f "$path" ]] || { printf 'Missing module: %s\n' "$module" >&2; exit 1; }
  [[ "$module" != "src/commands/05_bundle.sh" ]] || emit_builtin_bundle_assets
  cat "$path" >> "$tmp"
done

if [[ "$CHECK" == "1" ]]; then
  cmp -s "$tmp" "$OUT" || {
    printf 'spark is out of sync with src modules. Run: scripts/build-single-file.sh\n' >&2
    exit 1
  }
  exit 0
fi

chmod +x "$tmp"
mv "$tmp" "$OUT"
tmp=""
printf 'Built %s from %d modules\n' "$OUT" "${#MODULES[@]}"
