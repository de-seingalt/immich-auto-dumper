#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/immich-auto-dumper}"
REPO="https://github.com/de-seingalt/immich-auto-dumper.git"
BIN_LINK="/usr/local/bin/immich-auto-dumper"

_check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    printf 'Erreur : "%s" est requis mais introuvable. Installez-le et relancez.\n' "$1" >&2
    exit 1
  fi
}

_check_cmd git
_check_cmd curl

if [[ -d "$INSTALL_DIR/.git" ]]; then
  printf 'Mise à jour de immich-auto-dumper dans %s...\n' "$INSTALL_DIR"
  git -C "$INSTALL_DIR" pull --ff-only
else
  printf 'Installation de immich-auto-dumper dans %s...\n' "$INSTALL_DIR"
  git clone "$REPO" "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/immich-auto-dumper.sh"

if [[ -L "$BIN_LINK" || -e "$BIN_LINK" ]]; then
  rm -f "$BIN_LINK"
fi
ln -s "$INSTALL_DIR/immich-auto-dumper.sh" "$BIN_LINK"
printf 'Lien symbolique créé : %s → %s\n' "$BIN_LINK" "$INSTALL_DIR/immich-auto-dumper.sh"

printf '\nInstallation terminée. Lancement de la configuration...\n\n'
"$BIN_LINK" setup
