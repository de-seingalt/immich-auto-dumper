#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.conf"

source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/db.sh"
source "$SCRIPT_DIR/lib/backup_db.sh"
source "$SCRIPT_DIR/lib/archive.sh"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

_usage() {
  cat <<'EOF'
Usage: immich-auto-dumper <commande>

Commandes :
  setup     Configuration assistée (création ou mise à jour de config.conf)
  status    État du service, espace disque, dernières opérations
  start     Active les crons
  stop      Désactive les crons, attend la fin de l'opération en cours
  dump_now  Force un archivage immédiat jusqu'au seuil bas
  sync_now  Force une copie immédiate des backups BDD vers le stockage externe
EOF
}

_ask() {
  local prompt="$1"
  local default="${2:-}"
  local answer
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer
  else
    read -r -p "$prompt: " answer
  fi
  printf '%s\n' "${answer:-$default}"
}

_require_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    printf 'Erreur : config.conf introuvable. Lancez : immich-auto-dumper setup\n' >&2
    exit 1
  fi
}

# ── setup ─────────────────────────────────────────────────────────────────────

_setup() {
  echo "=== immich-auto-dumper — configuration ==="
  echo

  local db_container="${IMMICH_DB_CONTAINER:-immich_postgres}"
  local server_container="${IMMICH_SERVER_CONTAINER:-immich_server}"
  local upload_location="${IMMICH_UPLOAD_LOCATION:-}"
  local db_name="${IMMICH_DB_NAME:-immich}"
  local db_user="${IMMICH_DB_USER:-postgres}"
  local api_url="${IMMICH_API_URL:-http://localhost:2283}"
  local api_key="${IMMICH_API_KEY:-}"
  local archive_dest="${ARCHIVE_DEST_PATH:-}"
  local archive_container_path="${ARCHIVE_CONTAINER_PATH:-}"
  local threshold_high="${ARCHIVE_THRESHOLD_HIGH:-60}"
  local threshold_low="${ARCHIVE_THRESHOLD_LOW:-40}"
  local backup_retention="${BACKUP_RETENTION:-14}"
  local log_dir="${LOG_DIR:-/var/log/immich-auto-dumper}"
  local log_max_lines="${LOG_MAX_LINES:-1000}"

  # Détection des conteneurs Docker Immich actifs
  local detected
  detected=$(docker ps --format '{{.Names}}' 2>/dev/null || true)
  local d_db d_server
  d_db=$(printf '%s\n' "$detected" | grep -i 'postgres\|immich.*db\|db.*immich' | head -1 || true)
  d_server=$(printf '%s\n' "$detected" | grep -i 'immich.server\|immich-server' | head -1 || true)
  [[ -n "$d_db" ]] && db_container="$d_db"
  [[ -n "$d_server" ]] && server_container="$d_server"

  echo "── Conteneurs Docker ──"
  db_container=$(_ask    "Conteneur PostgreSQL"     "$db_container")
  server_container=$(_ask "Conteneur immich_server" "$server_container")

  echo
  echo "── Stockage Immich ──"
  upload_location=$(_ask "IMMICH_UPLOAD_LOCATION (chemin hôte)" "$upload_location")

  echo
  echo "── Stockage externe ──"
  archive_dest=$(_ask           "ARCHIVE_DEST_PATH (chemin hôte)"             "$archive_dest")
  archive_container_path=$(_ask "ARCHIVE_CONTAINER_PATH (chemin dans le conteneur)" "$archive_container_path")

  echo
  echo "── API Immich ──"
  api_url=$(_ask "IMMICH_API_URL" "$api_url")
  api_key=$(_ask "IMMICH_API_KEY" "$api_key")

  echo
  echo "── Correspondance utilisateurs → dossiers ──"

  declare -A new_user_map=()

  if docker exec -i "$db_container" psql -U "$db_user" -d "$db_name" -t -A \
       -c "SELECT 1;" &>/dev/null 2>&1; then
    local users_raw
    users_raw=$(docker exec -i "$db_container" psql \
      -U "$db_user" -d "$db_name" -t -A \
      -c "SELECT id, name, storage_label FROM users ORDER BY created_at;" 2>/dev/null || true)

    if [[ -n "$users_raw" ]]; then
      echo "Utilisateurs détectés :"
      while IFS='|' read -r uid name storage_label; do
        [[ -z "$uid" ]] && continue
        local key="${storage_label:-$uid}"
        local current_mapped="${USER_MAP["$key"]:-}"
        local default_folder="${current_mapped:-${storage_label:-$name}}"
        printf '  %-36s  %s  (storage_label: %s)\n' "$uid" "$name" "${storage_label:-<vide>}"
        local folder
        folder=$(_ask "  Dossier pour \"$name\" (clé BDD: $key)" "$default_folder")
        new_user_map["$key"]="$folder"
      done <<< "$users_raw"
    else
      echo "Aucun utilisateur trouvé — USER_MAP laissée vide."
      echo "Relancez 'setup' une fois Immich démarré pour la remplir."
    fi
  else
    echo "Impossible de joindre la BDD — USER_MAP laissée vide."
    echo "Relancez 'setup' une fois Immich démarré pour la remplir."
  fi

  echo
  echo "── Seuils d'archivage ──"
  threshold_high=$(_ask "ARCHIVE_THRESHOLD_HIGH (% déclenchement)" "$threshold_high")
  threshold_low=$(_ask  "ARCHIVE_THRESHOLD_LOW (% cible)"          "$threshold_low")

  echo
  echo "── Backup BDD ──"
  backup_retention=$(_ask "BACKUP_RETENTION (fichiers à conserver)" "$backup_retention")

  echo
  echo "── Logs ──"
  log_dir=$(_ask       "LOG_DIR"       "$log_dir")
  log_max_lines=$(_ask "LOG_MAX_LINES" "$log_max_lines")

  echo
  echo "── Récapitulatif ──"
  printf '  %-26s = %s\n' \
    IMMICH_DB_CONTAINER     "$db_container" \
    IMMICH_SERVER_CONTAINER "$server_container" \
    IMMICH_UPLOAD_LOCATION  "$upload_location" \
    IMMICH_DB_NAME          "$db_name" \
    IMMICH_DB_USER          "$db_user" \
    IMMICH_API_URL          "$api_url" \
    IMMICH_API_KEY          "${api_key:0:8}..." \
    ARCHIVE_DEST_PATH       "$archive_dest" \
    ARCHIVE_CONTAINER_PATH  "$archive_container_path" \
    ARCHIVE_THRESHOLD_HIGH  "$threshold_high" \
    ARCHIVE_THRESHOLD_LOW   "$threshold_low" \
    BACKUP_RETENTION        "$backup_retention" \
    LOG_DIR                 "$log_dir" \
    LOG_MAX_LINES           "$log_max_lines"

  if [[ ${#new_user_map[@]} -gt 0 ]]; then
    echo "  USER_MAP :"
    for k in "${!new_user_map[@]}"; do
      printf '    ["%s"] = "%s"\n' "$k" "${new_user_map[$k]}"
    done
  fi

  echo
  local confirm
  confirm=$(_ask "Écrire config.conf ? [o/N]" "N")
  if [[ "$confirm" != "o" && "$confirm" != "O" ]]; then
    echo "Annulé."
    return 0
  fi

  local user_map_block="declare -A USER_MAP"$'\n'
  for k in "${!new_user_map[@]}"; do
    user_map_block+="USER_MAP[\"${k}\"]=\"${new_user_map[$k]}\""$'\n'
  done

  cat > "$CONFIG_FILE" <<CONF
# immich-auto-dumper — configuration
# Généré le $(date '+%Y-%m-%d %H:%M:%S')

# --- Immich ---
IMMICH_UPLOAD_LOCATION="${upload_location}"
IMMICH_DB_CONTAINER="${db_container}"
IMMICH_SERVER_CONTAINER="${server_container}"
IMMICH_DB_NAME="${db_name}"
IMMICH_DB_USER="${db_user}"
IMMICH_API_URL="${api_url}"
IMMICH_API_KEY="${api_key}"

# --- Stockage externe ---
ARCHIVE_DEST_PATH="${archive_dest}"
ARCHIVE_CONTAINER_PATH="${archive_container_path}"

# --- Archivage photos ---
ARCHIVE_THRESHOLD_HIGH=${threshold_high}
ARCHIVE_THRESHOLD_LOW=${threshold_low}

# --- Backup BDD ---
BACKUP_RETENTION=${backup_retention}

# --- Correspondance userID/storage_label → nom de dossier ---
${user_map_block}
# --- Logs ---
LOG_DIR="${log_dir}"
LOG_MAX_LINES=${log_max_lines}
CONF

  echo "config.conf écrit."
  echo

  local install_cron
  install_cron=$(_ask "Installer les crons ? [o/N]" "N")
  if [[ "$install_cron" == "o" || "$install_cron" == "O" ]]; then
    _start
  fi
}

# ── status ────────────────────────────────────────────────────────────────────

_status() {
  echo "=== immich-auto-dumper status ==="

  local library_path="${IMMICH_UPLOAD_LOCATION:-}/library"
  if [[ -d "$library_path" ]]; then
    local usage
    usage=$(disk_usage_percent "$library_path/")
    printf 'Espace library/      : %s%% utilisé  [seuil haut: %s%% — seuil bas: %s%%]\n' \
      "$usage" "${ARCHIVE_THRESHOLD_HIGH:-?}" "${ARCHIVE_THRESHOLD_LOW:-?}"
  else
    printf 'Espace library/      : indisponible (%s absent)\n' "$library_path"
  fi

  if check_archive_dest_mounted 2>/dev/null; then
    printf 'Stockage externe     : monté  (%s)\n' "${ARCHIVE_DEST_PATH:-?}"
  else
    printf 'Stockage externe     : NON MONTÉ  (%s)\n' "${ARCHIVE_DEST_PATH:-?}"
  fi

  local backup_dir="${ARCHIVE_DEST_PATH:-}/.immich-backup"
  if [[ -d "$backup_dir" ]]; then
    local n
    n=$(find "$backup_dir" -maxdepth 1 -type f | wc -l)
    printf 'Backups BDD          : %s fichier(s) dans .immich-backup/\n' "$n"
  else
    printf 'Backups BDD          : dossier .immich-backup/ absent\n'
  fi

  local cron_status="inactifs"
  if crontab -l 2>/dev/null | grep 'immich-auto-dumper' | grep -qv '^#' 2>/dev/null; then
    cron_status="actifs"
  fi
  printf 'Crons                : %s\n' "$cron_status"

  local log_file="${LOG_DIR:-/var/log/immich-auto-dumper}/immich-auto-dumper.log"
  if [[ -f "$log_file" ]]; then
    local last_archive last_backup
    last_archive=$(grep 'Archivage terminé' "$log_file" | tail -1 || true)
    last_backup=$(grep 'Backup BDD :' "$log_file" | tail -1 || true)

    if [[ -n "$last_archive" ]]; then
      local ts detail
      ts=$(printf '%s' "$last_archive" | grep -oP '(?<=\[)[^\]]+' | head -1)
      detail=$(printf '%s' "$last_archive" | sed 's/.*Archivage terminé\. //')
      printf 'Dernière archive     : %s — %s\n' "$ts" "$detail"
    else
      printf 'Dernière archive     : aucune\n'
    fi

    if [[ -n "$last_backup" ]]; then
      local ts2 detail2
      ts2=$(printf '%s' "$last_backup" | grep -oP '(?<=\[)[^\]]+' | head -1)
      detail2=$(printf '%s' "$last_backup" | sed 's/.*Backup BDD : //')
      printf 'Dernier backup BDD   : %s — %s\n' "$ts2" "$detail2"
    else
      printf 'Dernier backup BDD   : aucun\n'
    fi
  else
    printf 'Dernière archive     : log absent\n'
    printf 'Dernier backup BDD   : log absent\n'
  fi

  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(cat "$LOCK_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      printf 'Lock                 : actif (PID %s)\n' "$pid"
    else
      printf 'Lock                 : orphelin (PID %s mort)\n' "$pid"
    fi
  else
    printf 'Lock                 : inactif\n'
  fi
}

# ── start ─────────────────────────────────────────────────────────────────────

_start() {
  local crontab_example="$SCRIPT_DIR/cron/crontab.example"
  if [[ ! -f "$crontab_example" ]]; then
    printf 'Fichier crontab.example introuvable : %s\n' "$crontab_example" >&2
    return 1
  fi

  local current_crontab
  current_crontab=$(crontab -l 2>/dev/null || true)

  local new_entries=""
  while IFS= read -r line; do
    [[ "$line" =~ ^# || -z "$line" ]] && continue
    if ! printf '%s\n' "$current_crontab" | grep -qF "$line"; then
      new_entries+="$line"$'\n'
    fi
  done < "$crontab_example"

  if [[ -z "$new_entries" ]]; then
    echo "Les crons sont déjà installés."
    return 0
  fi

  printf '%s\n%s' "$current_crontab" "$new_entries" | crontab -
  echo "Crons installés."
}

# ── stop ──────────────────────────────────────────────────────────────────────

_stop() {
  local current_crontab
  current_crontab=$(crontab -l 2>/dev/null || true)

  if printf '%s\n' "$current_crontab" | grep -q 'immich-auto-dumper' 2>/dev/null; then
    printf '%s\n' "$current_crontab" \
      | sed 's|^\([^#].*immich-auto-dumper.*\)|#\1|' \
      | crontab -
    echo "Crons désactivés."
  else
    echo "Aucune entrée immich-auto-dumper dans le crontab."
  fi

  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(cat "$LOCK_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "Opération en cours (PID $pid), attente (max 60s)..."
      local elapsed=0
      while [[ -f "$LOCK_FILE" ]] && kill -0 "$pid" 2>/dev/null && (( elapsed < 60 )); do
        sleep 2
        elapsed=$(( elapsed + 2 ))
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo "Avertissement : l'opération n'est pas terminée après 60s." >&2
      else
        echo "Opération terminée."
      fi
    fi
  fi
}

# ── Point d'entrée ────────────────────────────────────────────────────────────

main() {
  local cmd="${1:-}"

  if [[ "$cmd" != "setup" && "$cmd" != "" ]]; then
    _require_config
  fi

  case "$cmd" in
    setup)    _setup ;;
    status)   _status ;;
    start)    _start ;;
    stop)     _stop ;;
    dump_now) archive_run ;;
    sync_now) backup_db_run ;;
    *)        _usage; [[ -z "$cmd" ]] && exit 0 || exit 1 ;;
  esac
}

main "$@"
