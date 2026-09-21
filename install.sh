#!/usr/bin/env bash
set -euo pipefail

# immich-auto-dumper installer / updater. Clones the repository on a first
# install, brings an existing one up to origin/<BRANCH> afterwards, then hands
# off to the setup wizard. The help text is in _usage.

INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/share/immich-auto-dumper}"
REPO="${REPO:-https://github.com/de-seingalt/immich-auto-dumper.git}"
BRANCH="${BRANCH:-main}"
ASSUME_YES="${ASSUME_YES:-0}"

# Prints the help text, in full. A heredoc and not a slice of the comment block
# above, whose line numbers a single added line was enough to shift.
_usage() {
  cat <<'EOF'
immich-auto-dumper installer / updater.

Usage:
  install.sh [-y|--yes]
  install.sh -h|--help

Options:
  -y, --yes     Assume "yes": non-interactive update, keeping the local config.
  -h, --help    Show this help and exit.

Environment overrides:
  INSTALL_DIR   Where to install  (default: ~/.local/share/immich-auto-dumper)
  REPO          Repository to clone from
  BRANCH        Branch to track   (default: main)
  ASSUME_YES    Set to 1, same as --yes

What it does:
  Nothing installed yet   Clones the repository into INSTALL_DIR. This is the
                          "curl ... | bash" path.
  Installation present    Asks whether to update keeping the local config,
                          update and reset it, or cancel. A directory that is
                          not a git checkout is adopted into git first.

  config.conf and the logs are git-ignored, so a plain update never touches
  them. Resetting the config backs it up to config.conf.bak and removes it, so
  the wizard writes a fresh one.

  It then runs "immich-auto-dumper setup", which owns the ~/.local/bin symlink.
  With --yes, or with no terminal to answer it, that step is skipped.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)  ASSUME_YES=1 ;;
    -h|--help) _usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n\n' "$1" >&2; _usage >&2; exit 1 ;;
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

# True when /dev/tty can actually be opened — tested by opening it.
_have_tty() { { : </dev/tty; } 2>/dev/null; }

_git() { git -C "$INSTALL_DIR" "$@"; }

# True when INSTALL_DIR holds no installation yet: absent, or an empty directory.
_dir_is_empty() {
  [[ ! -e "$INSTALL_DIR" ]] && return 0
  [[ -d "$INSTALL_DIR" && -z "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]
}

# Lists the local edits to tracked files that the update is about to discard, and
# asks whether to go on. Under -y / ASSUME_YES, or with no terminal, it lists them
# and continues. Ignored files (config.conf, logs) are never concerned.
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
  # Executable-bit changes are ignored from here on.
  _git config core.fileMode false || true
  printf 'Updated to %s (%s).\n' "$BRANCH" "$(_git rev-parse --short HEAD)"
}

# Adopts an existing, non-git INSTALL_DIR into git: a repo initialised in place,
# with origin pointed at REPO. The caller syncs it afterwards.
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

# Hands off to the wizard, which creates config.conf and owns the ~/.local/bin
# symlink. Skipped under --yes and when there is no terminal to answer it.
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
