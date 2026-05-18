#!/usr/bin/env bash
set -euo pipefail

# spark installer — downloads the spark script to /usr/local/bin

REPO="massimo92/spark"
INSTALL_DIR="/usr/local/bin"
BINARY="spark"

printf "Installing spark...\n"

tmp_file=$(mktemp "${TMPDIR:-/tmp}/spark.XXXXXX")
trap 'rm -f "$tmp_file"' EXIT

# Download
curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/spark" -o "$tmp_file"

if ! IFS= read -r first_line < "$tmp_file" || [[ "$first_line" != "#!/usr/bin/env bash" ]]; then
  printf "Downloaded file does not look like the spark executable.\n" >&2
  exit 1
fi

chmod +x "$tmp_file"

# Install
if [[ -w "$INSTALL_DIR" ]]; then
  mv "$tmp_file" "${INSTALL_DIR}/${BINARY}"
else
  sudo mv "$tmp_file" "${INSTALL_DIR}/${BINARY}"
fi
trap - EXIT

printf "✓ spark installed to %s/%s\n" "$INSTALL_DIR" "$BINARY"
printf "  Run: spark setup\n"
