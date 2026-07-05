#!/usr/bin/env bash
set -euo pipefail

# spark installer — downloads the spark script to ~/.local/bin

REPO="massimo92/spark"
INSTALL_DIR="${HOME}/.local/bin"
DATA_DIR="${HOME}/.local/share/spark"
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
mkdir -p "$INSTALL_DIR"
mv "$tmp_file" "${INSTALL_DIR}/${BINARY}"
trap - EXIT

mkdir -p "${DATA_DIR}/scripts"
curl -fsSL "https://raw.githubusercontent.com/${REPO}/main/scripts/hf_model_inspect.py" -o "${DATA_DIR}/scripts/hf_model_inspect.py"
chmod +x "${DATA_DIR}/scripts/hf_model_inspect.py"

# Ensure ~/.local/bin is in PATH
if [[ ":$PATH:" != *":${INSTALL_DIR}:"* ]]; then
  shell_rc="${HOME}/.bashrc"
  [[ -n "${ZSH_VERSION:-}" ]] && shell_rc="${HOME}/.zshrc"
  if ! grep -q '.local/bin' "$shell_rc" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$shell_rc"
    printf "  Added ~/.local/bin to PATH in %s\n" "$(basename "$shell_rc")"
  fi
  export PATH="${INSTALL_DIR}:${PATH}"
fi

# Clean up old system-level install if it exists
if [[ -f "/usr/local/bin/${BINARY}" ]]; then
  printf "  Found old install at /usr/local/bin/%s\n" "$BINARY"
  if [[ -w "/usr/local/bin/${BINARY}" ]]; then
    rm -f "/usr/local/bin/${BINARY}"
    printf "  Removed /usr/local/bin/%s\n" "$BINARY"
  elif command -v sudo >/dev/null 2>&1; then
    sudo rm -f "/usr/local/bin/${BINARY}" 2>/dev/null \
      && printf "  Removed /usr/local/bin/%s\n" "$BINARY" \
      || printf "  Could not remove /usr/local/bin/%s — remove it manually\n" "$BINARY"
  else
    printf "  Could not remove /usr/local/bin/%s — remove it manually\n" "$BINARY"
  fi
fi

printf "✓ spark installed to %s/%s\n" "$INSTALL_DIR" "$BINARY"
printf "✓ Hugging Face inspector installed to %s/scripts/hf_model_inspect.py\n" "$DATA_DIR"
printf "  Run: spark setup\n"
