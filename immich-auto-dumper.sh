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
Usage: immich-auto-dumper <command> [--dry-run]

Commands:
  setup      Interactive configuration wizard (creates or updates config.conf)
  status     Show service status, disk usage, and last operations
  start      Enable cron jobs
  stop       Disable cron jobs and wait for any running operation to finish
  dump_now   Force an immediate archive run until the low threshold is reached
  sync_now   Force an immediate copy of DB backups to external storage
  test_run   Simulate dump_now + sync_now without making any changes (implies --dry-run)

Flags:
  --dry-run  Suppress all destructive operations (cp, rm, DB UPDATE).
             Compatible with dump_now and sync_now.
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
    printf 'Error: config.conf not found. Run: immich-auto-dumper setup\n' >&2
    exit 1
  fi
}

# Generates a random storage id (no external dependency).
_new_storage_id() { cat /proc/sys/kernel/random/uuid; }

# Interactive liveness gate before writing the storage marker: makes sure the
# storage is actually active, so we never write the marker into an empty local
# mount point. Auto-detects when possible (findmnt) and only asks when ambiguous.
# Returns 0 when it is safe to write, 1 when the user chose to skip.
_ensure_storage_live() {
  local dest="$1"
  if archive_dest_is_mounted "$dest"; then
    return 0   # confident: active non-root mount
  fi
  printf '  "%s" is not detected as a separate active mount point.\n' "$dest"
  local kind
  kind=$(_ask "  Is it a local folder, or a remote mount (rclone/NFS/SMB/external disk) that should be active? [local/mount]" "local")
  if [[ "$kind" == "local" ]]; then
    return 0
  fi
  while true; do
    local ans
    ans=$(_ask "  Not mounted. Mount it now, then press Enter to re-check (or 's' to skip marker creation)" "")
    [[ "$ans" == "s" || "$ans" == "S" ]] && return 1
    if archive_dest_is_mounted "$dest"; then
      return 0
    fi
    echo "  Still not detected as an active mount."
  done
}

# Reconciles the storage marker for the destination. Handles install, relocation,
# recognition and conflict (case A). Sets the global STORAGE_ID_RESULT.
# Prompts/echo go to the terminal (not captured) — we use a global on purpose.
_resolve_storage_marker() {
  local dest="$1" config_id="$2"
  local marker="${dest%/}/.immich-auto-dumper.id"
  local found_id
  found_id=$(timeout 10 cat "$marker" 2>/dev/null || true)

  # Make write_archive_marker (which uses the global) target this destination.
  ARCHIVE_DEST_PATH="$dest"

  if [[ -n "$config_id" && "$found_id" == "$config_id" ]]; then
    echo "Storage recognized (marker matches config). No change."
    STORAGE_ID_RESULT="$config_id"
    return 0
  fi

  if [[ -n "$found_id" && "$found_id" != "$config_id" ]]; then
    echo "A different storage marker is already present here:"
    printf '  in storage : %s\n' "$found_id"
    printf '  in config  : %s\n' "${config_id:-<none>}"
    local choice
    choice=$(_ask "Adopt found id [a], keep config id and overwrite [k], or cancel [c]?" "a")
    case "$choice" in
      k|K)
        local id="${config_id:-$(_new_storage_id)}"
        if _ensure_storage_live "$dest" && write_archive_marker "$id"; then
          echo "Marker overwritten with config id."
          STORAGE_ID_RESULT="$id"
        else
          echo "Could not write marker — keeping the id already on the storage."
          STORAGE_ID_RESULT="$found_id"
        fi
        ;;
      c|C)
        echo "Marker left unchanged."
        STORAGE_ID_RESULT="${config_id:-$found_id}"
        ;;
      *)
        echo "Adopted the id already present on the storage."
        STORAGE_ID_RESULT="$found_id"
        ;;
    esac
    return 0
  fi

  # No marker at destination: fresh install, relocation to an empty target, or
  # storage temporarily offline.
  local id="${config_id:-$(_new_storage_id)}"
  if _ensure_storage_live "$dest"; then
    if write_archive_marker "$id"; then
      if [[ -n "$config_id" ]]; then
        echo "Storage relocated — marker re-created at the new location (same id)."
      else
        echo "Storage initialized — marker created."
      fi
    else
      echo "WARNING: could not write the marker (read-only or inactive mount?)."
      echo "         Archiving stays paused until the marker exists."
    fi
  else
    echo "Storage not active now — marker NOT created. Mount it and re-run setup."
  fi
  STORAGE_ID_RESULT="$id"
  return 0
}

# ── setup ─────────────────────────────────────────────────────────────────────

_setup() {
  echo "=== immich-auto-dumper — configuration ==="
  echo

  # Detect docker command first; all DB queries below depend on it.
  detect_docker_cmd

  local db_container="${IMMICH_DB_CONTAINER:-immich_postgres}"
  local server_container="${IMMICH_SERVER_CONTAINER:-immich_server}"
  local upload_location="${IMMICH_UPLOAD_LOCATION:-}"
  local db_name="${IMMICH_DB_NAME:-immich}"
  local db_user="${IMMICH_DB_USER:-postgres}"
  local archive_dest="${ARCHIVE_DEST_PATH:-}"
  local archive_container_path="${ARCHIVE_CONTAINER_PATH:-}"
  local db_library_prefix="${IMMICH_DB_LIBRARY_PREFIX:-}"
  local threshold_high="${ARCHIVE_THRESHOLD_HIGH:-60}"
  local threshold_low="${ARCHIVE_THRESHOLD_LOW:-40}"
  local backup_retention="${BACKUP_RETENTION:-14}"
  local log_dir="${LOG_DIR:-/var/log/immich-auto-dumper}"
  local log_max_lines="${LOG_MAX_LINES:-1000}"

  # Auto-detect active Immich containers
  local detected
  detected=$($DOCKER_CMD ps --format '{{.Names}}' 2>/dev/null || true)
  local d_db d_server
  d_db=$(printf '%s\n' "$detected" | grep -i 'postgres\|immich.*db\|db.*immich' | head -1 || true)
  d_server=$(printf '%s\n' "$detected" | grep -i 'immich.server\|immich-server' | head -1 || true)
  [[ -n "$d_db" ]] && db_container="$d_db"
  [[ -n "$d_server" ]] && server_container="$d_server"

  echo "── Docker containers ──"
  db_container=$(_ask    "PostgreSQL container"     "$db_container")
  server_container=$(_ask "immich_server container" "$server_container")

  echo
  echo "── Immich storage ──"
  upload_location=$(_ask "IMMICH_UPLOAD_LOCATION (host path)" "$upload_location")

  echo
  echo "── External storage ──"
  archive_dest=$(_ask           "ARCHIVE_DEST_PATH (host path)"            "$archive_dest")
  archive_container_path=$(_ask "ARCHIVE_CONTAINER_PATH (container path)"  "$archive_container_path")

  echo
  echo "── External storage marker ──"
  # Establishes/recognizes the storage identity (install, relocation, conflict).
  local storage_id
  STORAGE_ID_RESULT=""
  _resolve_storage_marker "$archive_dest" "${ARCHIVE_STORAGE_ID:-}"
  storage_id="$STORAGE_ID_RESULT"
  # Keep the global in sync so later readiness/consistency checks use this id.
  ARCHIVE_STORAGE_ID="$storage_id"

  echo
  echo "── Library prefix detection ──"
  # Try to auto-detect IMMICH_DB_LIBRARY_PREFIX from a sample asset path.
  local detected_prefix=""
  if $DOCKER_CMD exec -i "$db_container" psql \
       -U "$db_user" -d "$db_name" -t -A -c "SELECT 1;" &>/dev/null 2>&1; then
    local sample_path
    sample_path=$($DOCKER_CMD exec -i "$db_container" psql \
      -U "$db_user" -d "$db_name" -t -A \
      -c "SELECT \"originalPath\" FROM \"asset\" LIMIT 1;" 2>/dev/null | head -1 || true)
    if [[ -n "$sample_path" ]]; then
      local candidate
      candidate=$(printf '%s' "$sample_path" | sed 's|\(/[^/]*/library\)/.*|\1|')
      [[ "$candidate" != "$sample_path" ]] && detected_prefix="$candidate"
    fi
  fi

  if [[ -n "$detected_prefix" ]]; then
    printf 'Auto-detected: %s\n' "$detected_prefix"
    [[ -z "$db_library_prefix" ]] && db_library_prefix="$detected_prefix"
  else
    printf 'Could not auto-detect (DB unreachable or no assets yet).\n'
    [[ -z "$db_library_prefix" ]] && db_library_prefix="/data/library"
  fi
  db_library_prefix=$(_ask "IMMICH_DB_LIBRARY_PREFIX" "$db_library_prefix")

  echo
  echo "── User → folder mapping ──"

  declare -A new_user_map=()

  if $DOCKER_CMD exec -i "$db_container" psql \
       -U "$db_user" -d "$db_name" -t -A -c "SELECT 1;" &>/dev/null 2>&1; then
    local users_raw
    users_raw=$($DOCKER_CMD exec -i "$db_container" psql \
      -U "$db_user" -d "$db_name" -t -A \
      -c "SELECT \"id\", \"name\", \"storageLabel\" FROM \"user\" ORDER BY \"createdAt\";" \
      2>/dev/null || true)

    if [[ -n "$users_raw" ]]; then
      echo "Detected users:"
      while IFS='|' read -r uid name storage_label; do
        [[ -z "$uid" ]] && continue
        local key="${storage_label:-$uid}"
        local current_mapped="${USER_MAP["$key"]:-}"
        local default_folder="${current_mapped:-${storage_label:-$name}}"
        printf '  %-36s  %s  (storageLabel: %s)\n' "$uid" "$name" "${storage_label:-<empty>}"
        local folder
        folder=$(_ask "  Folder for \"$name\" (DB key: $key)" "$default_folder")
        new_user_map["$key"]="$folder"
      done <<< "$users_raw"
    else
      echo "No users found — USER_MAP left empty."
      echo "Re-run 'setup' once Immich is running to populate it."
    fi
  else
    echo "Cannot reach DB — USER_MAP left empty."
    echo "Re-run 'setup' once Immich is running to populate it."
  fi

  echo
  echo "── Archive thresholds ──"
  threshold_high=$(_ask "ARCHIVE_THRESHOLD_HIGH (% trigger)" "$threshold_high")
  threshold_low=$(_ask  "ARCHIVE_THRESHOLD_LOW  (% target)"  "$threshold_low")

  echo
  echo "── DB backup ──"
  backup_retention=$(_ask "BACKUP_RETENTION (files to keep)" "$backup_retention")

  echo
  echo "── Logs ──"
  log_dir=$(_ask       "LOG_DIR"       "$log_dir")
  log_max_lines=$(_ask "LOG_MAX_LINES" "$log_max_lines")

  # Schema check (non-blocking warning).
  echo
  IMMICH_DB_CONTAINER="$db_container"
  IMMICH_DB_USER="$db_user"
  IMMICH_DB_NAME="$db_name"
  # Make path-consistency helpers see the values entered in this wizard.
  IMMICH_DB_LIBRARY_PREFIX="$db_library_prefix"
  ARCHIVE_CONTAINER_PATH="$archive_container_path"
  if $DOCKER_CMD exec -i "$db_container" psql \
       -U "$db_user" -d "$db_name" -t -A -c "SELECT 1;" &>/dev/null 2>&1; then
    if ! db_check_schema 2>/dev/null; then
      echo "WARNING: Schema check failed — the Immich DB schema may have changed."
      echo "         Review the script before using it against this Immich version."
    else
      echo "Schema check: OK"
    fi
    # Case B: surface an external-library path change recorded in Immich's DB.
    if archive_dest_ready 2>/dev/null; then
      local consistency_report
      if ! consistency_report=$(db_check_path_consistency 2>/dev/null); then
        echo "NOTE: Immich DB path inconsistency detected:"
        printf '%s\n' "$consistency_report" | sed 's/^/  - /'
        echo "      Make sure ARCHIVE_CONTAINER_PATH above matches the external"
        echo "      library path now configured in Immich."
      fi
    fi
  fi

  echo
  echo "── Summary ──"
  printf '  %-28s = %s\n' \
    IMMICH_DB_CONTAINER      "$db_container" \
    IMMICH_SERVER_CONTAINER  "$server_container" \
    IMMICH_UPLOAD_LOCATION   "$upload_location" \
    IMMICH_DB_LIBRARY_PREFIX "$db_library_prefix" \
    IMMICH_DB_NAME           "$db_name" \
    IMMICH_DB_USER           "$db_user" \
    ARCHIVE_DEST_PATH        "$archive_dest" \
    ARCHIVE_CONTAINER_PATH   "$archive_container_path" \
    ARCHIVE_STORAGE_ID       "$storage_id" \
    ARCHIVE_THRESHOLD_HIGH   "$threshold_high" \
    ARCHIVE_THRESHOLD_LOW    "$threshold_low" \
    BACKUP_RETENTION         "$backup_retention" \
    LOG_DIR                  "$log_dir" \
    LOG_MAX_LINES            "$log_max_lines"

  if [[ ${#new_user_map[@]} -gt 0 ]]; then
    echo "  USER_MAP:"
    for k in "${!new_user_map[@]}"; do
      printf '    ["%s"] = "%s"\n' "$k" "${new_user_map[$k]}"
    done
  fi

  echo
  local confirm
  confirm=$(_ask "Write config.conf? [y/N]" "N")
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Cancelled."
    return 0
  fi

  local user_map_block="declare -A USER_MAP"$'\n'
  for k in "${!new_user_map[@]}"; do
    user_map_block+="USER_MAP[\"${k}\"]=\"${new_user_map[$k]}\""$'\n'
  done

  cat > "$CONFIG_FILE" <<CONF
# immich-auto-dumper — configuration
# Generated on $(date '+%Y-%m-%d %H:%M:%S')

# --- Immich ---
IMMICH_UPLOAD_LOCATION="${upload_location}"
IMMICH_DB_LIBRARY_PREFIX="${db_library_prefix}"
IMMICH_DB_CONTAINER="${db_container}"
IMMICH_SERVER_CONTAINER="${server_container}"
IMMICH_DB_NAME="${db_name}"
IMMICH_DB_USER="${db_user}"

# --- External storage ---
ARCHIVE_DEST_PATH="${archive_dest}"
ARCHIVE_CONTAINER_PATH="${archive_container_path}"
ARCHIVE_STORAGE_ID="${storage_id}"

# --- Archive thresholds ---
ARCHIVE_THRESHOLD_HIGH=${threshold_high}
ARCHIVE_THRESHOLD_LOW=${threshold_low}

# --- DB backup ---
BACKUP_RETENTION=${backup_retention}

# --- User → external folder mapping ---
${user_map_block}
# --- Logs ---
LOG_DIR="${log_dir}"
LOG_MAX_LINES=${log_max_lines}
CONF

  echo "config.conf written."
  echo

  local install_cron
  install_cron=$(_ask "Install cron jobs? [y/N]" "N")
  if [[ "$install_cron" == "y" || "$install_cron" == "Y" ]]; then
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
    printf 'Library space        : %s%% used  [high: %s%% — low: %s%%]\n' \
      "$usage" "${ARCHIVE_THRESHOLD_HIGH:-?}" "${ARCHIVE_THRESHOLD_LOW:-?}"
  else
    printf 'Library space        : unavailable (%s not found)\n' "$library_path"
  fi

  local storage_ready=false
  if archive_dest_ready 2>/dev/null; then
    storage_ready=true
    printf 'External storage     : ready  (%s)\n' "${ARCHIVE_DEST_PATH:-?}"
  else
    printf 'External storage     : NOT READY  (%s)\n' "${ARCHIVE_DEST_PATH:-?}"
  fi

  # Path consistency vs Immich DB (requires docker; best-effort, never fatal).
  if "$storage_ready" && probe_docker_cmd 2>/dev/null; then
    if db_check_path_consistency >/dev/null 2>&1; then
      printf 'Path consistency     : OK\n'
    else
      printf 'Path consistency     : INCONSISTENT — fix the path in Immich, then run setup\n'
    fi
  fi

  local backup_dir="${ARCHIVE_DEST_PATH:-}/.immich-backup"
  if [[ -d "$backup_dir" ]]; then
    local n
    n=$(find "$backup_dir" -maxdepth 1 -type f | wc -l)
    printf 'DB backups           : %s file(s) in .immich-backup/\n' "$n"
  else
    printf 'DB backups           : .immich-backup/ directory absent\n'
  fi

  local cron_status="disabled"
  if crontab -l 2>/dev/null | grep 'immich-auto-dumper' | grep -qv '^#' 2>/dev/null; then
    cron_status="active"
  fi
  printf 'Cron jobs            : %s\n' "$cron_status"

  local log_file="${LOG_DIR:-/var/log/immich-auto-dumper}/immich-auto-dumper.log"
  if [[ -f "$log_file" ]]; then
    local last_archive last_backup
    last_archive=$(grep 'Archive complete' "$log_file" | tail -1 || true)
    last_backup=$(grep 'DB backup:' "$log_file" | tail -1 || true)

    if [[ -n "$last_archive" ]]; then
      local ts detail
      ts=$(printf '%s' "$last_archive" | grep -oP '(?<=\[)[^\]]+' | head -1)
      detail=$(printf '%s' "$last_archive" | sed 's/.*Archive complete\. //')
      printf 'Last archive         : %s — %s\n' "$ts" "$detail"
    else
      printf 'Last archive         : none\n'
    fi

    if [[ -n "$last_backup" ]]; then
      local ts2 detail2
      ts2=$(printf '%s' "$last_backup" | grep -oP '(?<=\[)[^\]]+' | head -1)
      detail2=$(printf '%s' "$last_backup" | sed 's/.*DB backup: //')
      printf 'Last DB backup       : %s — %s\n' "$ts2" "$detail2"
    else
      printf 'Last DB backup       : none\n'
    fi
  else
    printf 'Last archive         : log file absent\n'
    printf 'Last DB backup       : log file absent\n'
  fi

  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(cat "$LOCK_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      printf 'Lock                 : active (PID %s)\n' "$pid"
    else
      printf 'Lock                 : stale (PID %s dead)\n' "$pid"
    fi
  else
    printf 'Lock                 : inactive\n'
  fi
}

# ── start ─────────────────────────────────────────────────────────────────────

_start() {
  local crontab_example="$SCRIPT_DIR/cron/crontab.example"
  if [[ ! -f "$crontab_example" ]]; then
    printf 'crontab.example not found: %s\n' "$crontab_example" >&2
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
    echo "Cron jobs already installed."
    return 0
  fi

  printf '%s\n%s' "$current_crontab" "$new_entries" | crontab -
  echo "Cron jobs installed."
}

# ── stop ──────────────────────────────────────────────────────────────────────

_stop() {
  if disable_cron; then
    echo "Cron jobs disabled."
  else
    echo "No immich-auto-dumper entries in crontab."
  fi

  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(cat "$LOCK_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      echo "Operation in progress (PID $pid), waiting (max 60s)..."
      local elapsed=0
      while [[ -f "$LOCK_FILE" ]] && kill -0 "$pid" 2>/dev/null && (( elapsed < 60 )); do
        sleep 2
        elapsed=$(( elapsed + 2 ))
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo "Warning: operation still running after 60s." >&2
      else
        echo "Operation finished."
      fi
    fi
  fi
}

# ── Entry point ───────────────────────────────────────────────────────────────

main() {
  local dry_run=false
  local cmd=""
  local args=()

  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=true ;;
      *)         args+=("$arg") ;;
    esac
  done

  cmd="${args[0]:-}"

  if [[ "$cmd" != "setup" && -n "$cmd" ]]; then
    _require_config
  fi

  local dry_flag=()
  "$dry_run" && dry_flag=(--dry-run)

  case "$cmd" in
    setup)
      _setup
      ;;
    status)
      _status
      ;;
    start)
      _start
      ;;
    stop)
      _stop
      ;;
    dump_now)
      archive_run "${dry_flag[@]}"
      ;;
    sync_now)
      backup_db_run "${dry_flag[@]}"
      ;;
    test_run)
      archive_run --dry-run
      backup_db_run --dry-run
      ;;
    *)
      _usage
      [[ -z "$cmd" ]] && exit 0 || exit 1
      ;;
  esac
}

main "$@"
