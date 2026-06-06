#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/share/immich-auto-dumper}"
REPO="https://github.com/de-seingalt/immich-auto-dumper.git"
BIN_LINK="${HOME}/.local/bin/immich-auto-dumper"

_check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    printf 'Error: "%s" is required but not found. Install it and try again.\n' "$1" >&2
    exit 1
  fi
}

_check_cmd git

if [[ -d "$INSTALL_DIR/.git" ]]; then
  printf 'Updating immich-auto-dumper in %s...\n' "$INSTALL_DIR"
  git -C "$INSTALL_DIR" pull --ff-only
else
  printf 'Installing immich-auto-dumper into %s...\n' "$INSTALL_DIR"
  git clone "$REPO" "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/immich-auto-dumper.sh"

mkdir -p "${HOME}/.local/bin"
if [[ -L "$BIN_LINK" || -e "$BIN_LINK" ]]; then
  rm -f "$BIN_LINK"
fi
ln -s "$INSTALL_DIR/immich-auto-dumper.sh" "$BIN_LINK"
printf 'Symlink created: %s -> %s\n' "$BIN_LINK" "$INSTALL_DIR/immich-auto-dumper.sh"

if [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
  printf '\nWARNING: ~/.local/bin is not in your PATH.\n'
  printf 'Add this line to ~/.bashrc or ~/.profile, then restart your shell:\n'
  printf '  export PATH="${HOME}/.local/bin:${PATH}"\n'
fi

printf '\nInstallation complete. Launching configuration wizard...\n\n'
"$BIN_LINK" setup
