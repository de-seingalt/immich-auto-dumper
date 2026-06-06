#!/usr/bin/env bash
set -euo pipefail

# immich-auto-dumper — uninstaller.
# Removes ONLY the tool's own local footprint: the ~/.local/bin symlink, the
# install directory (which holds config.conf), the cron entries, the log dir and
# the lock file. It NEVER touches Immich (DB, assets, containers) nor anything on
# the external storage (the .immich-auto-dumper.id marker, .immich-backup/ and the
# archived photos) — those archived files are live Immich assets. Because external
# storage is never touched, this can run with the external library offline.

# This script lives inside the directory it must delete. Bash may re-read the file
# while running, so we relocate a copy to a temp path and re-exec from there before
# removing anything. INSTALL_DIR carries the original location across the re-exec.
if [[ "${IAD_RELOCATED:-}" != "1" ]]; then
  src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  tmp_self="$(mktemp)"
  cp -- "${BASH_SOURCE[0]}" "$tmp_self"
  IAD_RELOCATED=1 INSTALL_DIR="$src_dir" TMP_SELF="$tmp_self" \
    exec bash "$tmp_self" "$@"
fi

INSTALL_DIR="${INSTALL_DIR:?relocation failed: INSTALL_DIR unset}"
TMP_SELF="${TMP_SELF:-}"
BIN_LINK="${HOME}/.local/bin/immich-auto-dumper"
LOCK_FILE="/tmp/immich-auto-dumper.lock"

assume_yes=false
[[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]] && assume_yes=true

# Resolve LOG_DIR from the real config if present, else the XDG default — matches
# the default used by lib/utils.sh and config.conf.example.
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper"
if [[ -f "$INSTALL_DIR/config.conf" ]]; then
  # shellcheck source=/dev/null
  cfg_log_dir="$(source "$INSTALL_DIR/config.conf" 2>/dev/null; printf '%s' "${LOG_DIR:-}")"
  [[ -n "$cfg_log_dir" ]] && LOG_DIR="$cfg_log_dir"
fi

printf 'This will remove immich-auto-dumper from your system:\n'
printf '  - symlink     : %s\n' "$BIN_LINK"
printf '  - install dir : %s  (includes config.conf)\n' "$INSTALL_DIR"
printf '  - cron entries: lines matching "immich-auto-dumper"\n'
printf '  - logs        : %s\n' "$LOG_DIR"
printf '  - lock file   : %s\n' "$LOCK_FILE"
printf '\n'
printf 'It will NOT touch Immich (database, assets, containers) nor anything on the\n'
printf 'external storage (.immich-auto-dumper.id, .immich-backup/, archived photos).\n'
printf 'The external library may be offline — nothing there is read or written.\n\n'

if ! "$assume_yes"; then
  read -r -p "Proceed? [y/N]: " answer
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo "Cancelled. Nothing was removed."
    [[ -n "$TMP_SELF" ]] && rm -f -- "$TMP_SELF"
    exit 0
  fi
fi

# 1. Remove cron entries (delete the lines entirely; guard the empty-crontab case).
if crontab -l 2>/dev/null | grep -q 'immich-auto-dumper'; then
  remaining="$(crontab -l 2>/dev/null | grep -v 'immich-auto-dumper' || true)"
  if [[ -n "$remaining" ]]; then
    printf '%s\n' "$remaining" | crontab -
  else
    crontab -r 2>/dev/null || true
  fi
  echo "Removed cron entries."
fi

# 2. Remove the symlink, but only if it actually points into our install dir, so we
#    never delete an unrelated file that happens to share the name.
if [[ -L "$BIN_LINK" ]]; then
  target="$(readlink -f "$BIN_LINK" 2>/dev/null || true)"
  if [[ "$target" == "$INSTALL_DIR"/* ]]; then
    rm -f -- "$BIN_LINK"
    echo "Removed symlink: $BIN_LINK"
  else
    echo "Left symlink in place (does not point into $INSTALL_DIR): $BIN_LINK"
  fi
fi

# 3. Remove the log directory.
if [[ -d "$LOG_DIR" ]]; then
  rm -rf -- "$LOG_DIR"
  echo "Removed logs: $LOG_DIR"
fi

# 4. Remove the lock file.
rm -f -- "$LOCK_FILE"

# 5. Remove the install directory last (safe now that we run from a temp copy).
if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf -- "$INSTALL_DIR"
  echo "Removed install dir: $INSTALL_DIR"
fi

echo
echo "immich-auto-dumper uninstalled."
echo "Kept intact on external storage (if any): .immich-auto-dumper.id marker,"
echo ".immich-backup/ DB dumps, and all archived photos — they remain valid Immich assets."

# 6. Remove our own temp copy.
[[ -n "$TMP_SELF" ]] && rm -f -- "$TMP_SELF"
exit 0
