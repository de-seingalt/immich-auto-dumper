#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# immich-auto-dumper installer / updater.
#
# Fresh machine : clones the repo, links the binary, runs the setup wizard.
# Existing copy : detects it, asks whether to update, and (on yes) force-syncs
#                 the working tree to the chosen branch — discarding local edits
#                 to tracked files. Your config.conf and logs are git-ignored and
#                 are therefore left untouched.
#
# Usage:
#   install.sh [-y|--yes] [-b|--branch <name>]
#     -y, --yes            Assume "yes" to prompts (non-interactive update).
#     -b, --branch <name>  Install / update from this git branch.
#   Env overrides: INSTALL_DIR, REPO, BRANCH, ASSUME_YES=1
# ──────────────────────────────────────────────────────────────────────────────

INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/share/immich-auto-dumper}"
REPO="${REPO:-https://github.com/de-seingalt/immich-auto-dumper.git}"
BRANCH="${BRANCH:-}"
BIN_LINK="${HOME}/.local/bin/immich-auto-dumper"
ASSUME_YES="${ASSUME_YES:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)    ASSUME_YES=1 ;;
    -b|--branch) BRANCH="${2:-}"; shift ;;
    --branch=*)  BRANCH="${1#*=}" ;;
    -h|--help)   sed -n '4,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

_check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    printf 'Error: "%s" is required but not found. Install it and try again.\n' "$1" >&2
    exit 1
  fi
}
_check_cmd git

# Ask a yes/no question on the controlling terminal, working even under
# `curl ... | bash` (where stdin is the script, not the keyboard). With --yes it
# returns yes; with no terminal available it returns no (never auto-overwrite).
_confirm() {
  local prompt="$1" ans=""
  [[ "$ASSUME_YES" == "1" ]] && return 0
  if [[ -r /dev/tty ]]; then
    read -r -p "$prompt [y/N] " ans </dev/tty || ans=""
  else
    return 1
  fi
  [[ "$ans" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}

_git() { git -C "$INSTALL_DIR" "$@"; }

# Force the working tree to exactly match origin/<branch>, discarding local edits
# to tracked files. Ignored files (config.conf, logs) are left intact.
_sync_to_branch() {
  local target="$1"
  _git fetch --prune origin
  if ! _git rev-parse --verify --quiet "origin/${target}" >/dev/null; then
    printf 'Error: branch "%s" was not found on origin.\n' "$target" >&2
    exit 1
  fi
  _git checkout -f -B "$target" "origin/${target}"
  _git reset --hard "origin/${target}"
  printf 'Updated to %s (%s).\n' "$target" "$(_git rev-parse --short HEAD)"
}

if [[ -d "$INSTALL_DIR/.git" ]]; then
  # Ignore executable-bit changes so the chmod below never dirties the tree and
  # blocks future updates (this was the cause of "local changes would be
  # overwritten by merge: immich-auto-dumper.sh").
  _git config core.fileMode false || true

  local_branch=$(_git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  target="${BRANCH:-$local_branch}"
  [[ -z "$target" || "$target" == "HEAD" ]] && target="main"

  printf 'Existing installation found in %s (branch: %s).\n' "$INSTALL_DIR" "${local_branch:-unknown}"
  if _confirm "Update it now from origin/${target}? Local changes to tracked files will be discarded (config.conf is kept)."; then
    _sync_to_branch "$target"
  else
    printf 'Left unchanged.\n'
  fi
else
  printf 'Installing immich-auto-dumper into %s...\n' "$INSTALL_DIR"
  git clone "$REPO" "$INSTALL_DIR"
  _git config core.fileMode false || true
  [[ -n "$BRANCH" ]] && _sync_to_branch "$BRANCH"
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

# Configuration. Always run on a fresh install; for an existing config, ask first
# (the wizard is safe to re-run — it re-detects everything and can be aborted).
run_setup=1
if [[ -f "$INSTALL_DIR/config.conf" ]]; then
  if _confirm "Re-run the configuration wizard now?"; then run_setup=1; else run_setup=0; fi
fi

if [[ "$run_setup" == "1" ]]; then
  if [[ -r /dev/tty ]]; then
    printf '\nLaunching configuration wizard...\n\n'
    "$BIN_LINK" setup </dev/tty
  else
    printf '\nInstalled. Run "immich-auto-dumper setup" to configure.\n'
  fi
else
  printf '\nDone. Run "immich-auto-dumper setup" anytime to reconfigure.\n'
fi
