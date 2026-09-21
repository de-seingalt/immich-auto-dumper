#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# immich-auto-dumper installer / updater.
#
# Always brings the install up to the latest origin/main, then hands off to the
# setup wizard (which owns the ~/.local/bin symlink). On an install that already has
# a config.conf, setup opens on a review of that config — checks, summary and cron
# status — not on the step-by-step, so handing off is always the right move here.
#
#   Nothing installed yet  : clones origin/main (the `curl ... | bash` path).
#   Installation present    : asks whether to update keeping the local config,
#                             update and reset the local config, or cancel.
#                             A non-git directory (e.g. files copied in by hand)
#                             is adopted into git, then synced to origin/main.
#
# config.conf and logs are git-ignored, so a plain update never touches them;
# "reset config" explicitly backs config.conf up to config.conf.bak and removes
# it so the wizard regenerates a fresh one.
#
# Usage:
#   install.sh [-y|--yes]
#     -y, --yes   Assume "yes": non-interactive update, keeping the local config.
#   Env overrides: INSTALL_DIR, REPO, BRANCH (defaults to main), ASSUME_YES=1
# ──────────────────────────────────────────────────────────────────────────────

INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/share/immich-auto-dumper}"
REPO="${REPO:-https://github.com/de-seingalt/immich-auto-dumper.git}"
BRANCH="${BRANCH:-main}"
ASSUME_YES="${ASSUME_YES:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) sed -n '4,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

cat <<'EOF'
                             ___
 +====================+     /::/|
 | immich-auto-dumper |   /::/  / .__
 +====================+ /::/   /__|[_I___,
                       /::/.-./___I__.-~;|
 auto-free library    |__|`(_)--------(_)"
to external storage.::::::..
       .........:::::::::::::..
EOF

_check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    printf 'Error: "%s" is required but not found. Install it and try again.\n' "$1" >&2
    exit 1
  fi
}
_check_cmd git

# True only when /dev/tty can actually be opened. `[[ -r /dev/tty ]]` is not enough:
# the device node exists and tests readable even in a process with no controlling
# terminal (`ssh host 'cmd'`, a cron job, a pipeline), where every open() then fails
# with "No such device or address" — which used to abort the installer right where it
# hands off to the wizard. Trying the open is the only reliable test.
_have_tty() { { : </dev/tty; } 2>/dev/null; }

_git() { git -C "$INSTALL_DIR" "$@"; }

# True when INSTALL_DIR holds no installation yet (absent or empty). Such a dir is
# safe to `git clone` into; anything else is treated as an existing installation.
_dir_is_empty() {
  [[ ! -e "$INSTALL_DIR" ]] && return 0
  [[ -d "$INSTALL_DIR" && -z "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]
}

# Force the working tree to exactly match origin/<BRANCH>, discarding local edits to
# tracked files. Ignored files (config.conf, logs) are left intact.
#
# Those edits used to go without a word. config.conf is git-ignored so it was
# never at risk, but a patched lib/ or a hand-fixed script was — and the person
# who made the change is exactly the person who needs to hear about it. In
# interactive use it asks; under -y / ASSUME_YES it goes ahead and lists what it
# discarded, because the documented non-interactive path must not start waiting
# for an answer nobody is there to give.
_warn_local_changes() {
  local dirty
  dirty=$(_git status --porcelain --untracked-files=no 2>/dev/null || true)
  [[ -n "$dirty" ]] || return 0

  printf '\nLocal changes to tracked files in %s:\n' "$INSTALL_DIR" >&2
  printf '%s\n' "$dirty" | sed 's/^/  /' >&2
  printf 'Updating to origin/%s will discard them. (config.conf and logs are not affected.)\n' "$BRANCH" >&2

  if [[ "$ASSUME_YES" == "1" ]] || ! _have_tty; then
    printf 'Continuing anyway (non-interactive): the changes above are being discarded.\n' >&2
    return 0
  fi
  local ans=""
  read -r -p "Discard them and continue? [y/N] " ans </dev/tty || ans=""
  if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
    printf 'Left unchanged.\n'
    exit 0
  fi
}

_sync_to_branch() {
  _git fetch --prune origin
  if ! _git rev-parse --verify --quiet "origin/${BRANCH}" >/dev/null; then
    printf 'Error: branch "%s" was not found on origin.\n' "$BRANCH" >&2
    exit 1
  fi
  _warn_local_changes
  _git checkout -f -B "$BRANCH" "origin/${BRANCH}"
  _git reset --hard "origin/${BRANCH}"
  # Ignore executable-bit changes so the chmod below never dirties the tree and
  # blocks future updates.
  _git config core.fileMode false || true
  printf 'Updated to %s (%s).\n' "$BRANCH" "$(_git rev-parse --short HEAD)"
}

# Adopt an existing, non-git INSTALL_DIR into git: init a repo in place, point it at
# origin, then sync. Existing tracked files are overwritten by origin/main; ignored
# files (config.conf) are untouched.
_adopt_into_git() {
  printf 'Existing files are not a git checkout — adopting them into git...\n'
  _git init -q
  if _git remote get-url origin &>/dev/null; then
    _git remote set-url origin "$REPO"
  else
    _git remote add origin "$REPO"
  fi
}

# Three-way prompt for an existing installation. Echoes one of: update / reset /
# cancel. With --yes (or no terminal) it defaults to a config-preserving update.
_ask_update_choice() {
  if [[ "$ASSUME_YES" == "1" ]] || ! _have_tty; then
    printf 'update\n'; return 0
  fi
  local ans=""
  {
    printf 'An existing installation was found in %s.\n' "$INSTALL_DIR"
    printf 'It will be updated to the latest origin/%s. Choose what to do with your config:\n' "$BRANCH"
    printf '  [1] Update, keep my config.conf            (default)\n'
    printf '  [2] Update and reset config.conf           (backed up to config.conf.bak)\n'
    printf '  [3] Cancel\n'
  } >/dev/tty
  read -r -p "Your choice [1/2/3] " ans </dev/tty || ans=""
  case "$ans" in
    2) printf 'reset\n' ;;
    3) printf 'cancel\n' ;;
    *) printf 'update\n' ;;
  esac
}

if _dir_is_empty; then
  # Fresh install (the `curl ... | bash` path): clone straight from origin.
  printf 'Installing immich-auto-dumper into %s...\n' "$INSTALL_DIR"
  git clone --branch "$BRANCH" "$REPO" "$INSTALL_DIR"
  _git config core.fileMode false || true
else
  choice="$(_ask_update_choice)"
  case "$choice" in
    cancel)
      printf 'Left unchanged.\n'
      exit 0
      ;;
    reset)
      if [[ -f "$INSTALL_DIR/config.conf" ]]; then
        cp -f "$INSTALL_DIR/config.conf" "$INSTALL_DIR/config.conf.bak"
        rm -f "$INSTALL_DIR/config.conf"
        printf 'Saved your previous config to %s and reset it.\n' "$INSTALL_DIR/config.conf.bak"
      fi
      ;;
  esac

  [[ -d "$INSTALL_DIR/.git" ]] || _adopt_into_git
  _sync_to_branch
fi

chmod +x "$INSTALL_DIR/immich-auto-dumper.sh"

# Configuration. The wizard creates config.conf and owns the ~/.local/bin symlink.
# When a config already exists, setup opens on a review screen instead of the
# step-by-step: it validates the saved config against this version of the tool and
# the live Immich, shows it back, reports the cron status, and only then offers to
# reconfigure. So it is always worth launching interactively — there is no blind
# "re-run the wizard?" question here any more. --yes and a missing terminal still
# skip it, since neither can answer the review.
if [[ "$ASSUME_YES" != "1" ]] && _have_tty; then
  if [[ -f "$INSTALL_DIR/config.conf" ]]; then
    printf '\nChecking your configuration...\n\n'
  else
    printf '\nLaunching configuration wizard...\n\n'
  fi
  "$INSTALL_DIR/immich-auto-dumper.sh" setup </dev/tty
else
  printf '\nInstalled. Run "immich-auto-dumper setup" to configure.\n'
fi
