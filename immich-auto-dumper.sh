#!/usr/bin/env bash
set -euo pipefail

# Resolve through a possible symlink (e.g. ~/.local/bin/immich-auto-dumper) so the
# lib/, config.conf and cron/ paths below are found relative to the real install
# dir, not the symlink's directory. Cron and PATH invocations go through that link.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.conf"

source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/db.sh"
source "$SCRIPT_DIR/lib/backup_db.sh"
source "$SCRIPT_DIR/lib/archive.sh"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# Ensure USER_MAP exists even if a hand-edited config dropped its declaration, so
# `${USER_MAP[x]:-...}` lookups don't trip set -u. Declaring an existing assoc array
# does not clear it.
declare -A USER_MAP 2>/dev/null || true

# ── Helpers ───────────────────────────────────────────────────────────────────

_usage() {
  cat <<'EOF'
Usage: immich-auto-dumper <command> [--dry-run]

Commands:
  setup      Interactive configuration wizard (creates or updates config.conf)
  status     Show service status, disk usage, and last operations
  start      Enable cron jobs
  stop       Disable cron jobs and wait for any running operation to finish
  dump_now   Force an immediate archive run until the target size is reached
  sync_now   Force an immediate copy of DB backups to external storage
  test_run   Simulate dump_now + sync_now without making any changes (implies --dry-run)
  uninstall  Remove the tool's local footprint (keeps Immich and external storage intact)

Flags:
  --dry-run  Suppress all destructive operations (cp, rm, DB UPDATE).
             Compatible with dump_now and sync_now.
EOF
}

_require_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    printf 'Error: config.conf not found. Run: immich-auto-dumper setup\n' >&2
    exit 1
  fi
}

# Generates a random storage id (no external dependency).
_new_storage_id() { cat /proc/sys/kernel/random/uuid; }

# Absolute path used in cron lines: prefer the stable ~/.local/bin symlink created by
# install.sh, and fall back to the script's own location. Cron has a minimal PATH, so
# a bare command name would not resolve.
_resolve_self_bin() {
  local link="$HOME/.local/bin/immich-auto-dumper"
  if [[ -x "$link" ]]; then
    printf '%s\n' "$link"
  else
    printf '%s\n' "$SCRIPT_DIR/immich-auto-dumper.sh"
  fi
}

# Wizard dialog title prefix, so every step is clearly part of the same flow.
_wiz_title() { printf 'immich-auto-dumper Setup — %s' "$1"; }

# True if the configured Immich Postgres container answers a trivial query. Requires
# IMMICH_DB_CONTAINER / IMMICH_DB_USER / IMMICH_DB_NAME to be set first.
_db_reachable() { _db_exec "SELECT 1;" &>/dev/null; }

# Interactive liveness gate before writing the storage marker: makes sure the
# storage is actually active, so we never write the marker into an empty local
# mount point. Auto-detects when possible (findmnt) and only asks when ambiguous.
# Returns 0 when it is safe to write, 1 when the user chose to skip.
_ensure_storage_live() {
  local dest="$1"
  if archive_dest_is_mounted "$dest"; then
    return 0   # confident: active non-root mount
  fi
  ui_menu "External storage" \
    "\"$dest\" is not detected as a separate active mount point.\n\nIs it a plain local folder, or a remote/removable mount (rclone, NFS, SMB, external disk) that needs to be active before archiving?" \
    local "Local folder on this machine" \
    mount "Remote / removable mount (must be active)" || return 1
  if [[ "$UI_VALUE" == "local" ]]; then
    return 0
  fi
  while true; do
    if ! ui_yesno "External storage" \
      "Storage is not mounted yet.\n\nMount it now, then choose Yes to re-check.\nChoose No to skip creating the marker for now." ; then
      return 1
    fi
    if archive_dest_is_mounted "$dest"; then
      return 0
    fi
    ui_info "External storage" "Still not detected as an active mount. Check the mount and try again."
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
    ui_info "External storage" "Storage recognized: the marker matches your config. No change needed."
    STORAGE_ID_RESULT="$config_id"
    return 0
  fi

  if [[ -n "$found_id" && "$found_id" != "$config_id" ]]; then
    ui_menu "Storage marker conflict" \
      "A different storage marker is already present here.\n\n  on storage : $found_id\n  in config  : ${config_id:-<none>}\n\nWhat should I do?" \
      adopt  "Adopt the id already on the storage (recommended)" \
      keep   "Keep the config id and overwrite the storage marker" \
      cancel "Leave the marker unchanged" || UI_VALUE="adopt"
    case "$UI_VALUE" in
      keep)
        local id="${config_id:-$(_new_storage_id)}"
        if _ensure_storage_live "$dest" && write_archive_marker "$id"; then
          ui_info "External storage" "Marker overwritten with the config id."
          STORAGE_ID_RESULT="$id"
        else
          ui_info "External storage" "Could not write the marker — keeping the id already on the storage."
          STORAGE_ID_RESULT="$found_id"
        fi
        ;;
      cancel)
        ui_info "External storage" "Marker left unchanged."
        STORAGE_ID_RESULT="${config_id:-$found_id}"
        ;;
      *)
        ui_info "External storage" "Adopted the id already present on the storage."
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
        ui_info "External storage" "Storage relocated — marker re-created at the new location (same id)."
      else
        ui_info "External storage" "Storage initialized — marker created."
      fi
    else
      ui_info "External storage" "WARNING: could not write the marker (read-only or inactive mount?).\n\nArchiving stays paused until the marker exists."
    fi
  else
    ui_info "External storage" "Storage not active now — marker NOT created.\nMount it and re-run setup."
  fi
  STORAGE_ID_RESULT="$id"
  return 0
}

# ── setup ─────────────────────────────────────────────────────────────────────

_setup() {
  ui_detect
  ui_banner "immich-auto-dumper — configuration"
  ui_info "Welcome" \
    "This wizard will configure immich-auto-dumper.\n\nEach question shows a suggested value (auto-detected when possible) that you can accept or edit. Choose Cancel at any prompt to abort without writing anything.\n\nSizes accept GB, MB or a percentage of the disk — e.g. 200, 1.5G, 500M, 80%."

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
  local backup_retention="${BACKUP_RETENTION:-14}"
  local log_dir="${LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper}"
  local log_max_lines="${LOG_MAX_LINES:-1000}"

  # Archive boundaries, internally in MiB. Honor either the new *_MB keys or the
  # deprecated *_GB keys when seeding the defaults from an existing config.
  local def_max_mb="${ARCHIVE_LIBRARY_MAX_MB:-}" def_target_mb="${ARCHIVE_LIBRARY_TARGET_MB:-}"
  [[ -z "$def_max_mb"    && -n "${ARCHIVE_LIBRARY_MAX_GB:-}"    ]] && def_max_mb=$(( ARCHIVE_LIBRARY_MAX_GB * 1024 ))
  [[ -z "$def_target_mb" && -n "${ARCHIVE_LIBRARY_TARGET_GB:-}" ]] && def_target_mb=$(( ARCHIVE_LIBRARY_TARGET_GB * 1024 ))

  # Auto-detect active Immich containers so the defaults are pre-filled.
  local detected
  detected=$($DOCKER_CMD ps --format '{{.Names}}' 2>/dev/null || true)
  local d_db d_server
  d_db=$(printf '%s\n' "$detected" | grep -i 'postgres\|immich.*db\|db.*immich' | head -1 || true)
  d_server=$(printf '%s\n' "$detected" | grep -i 'immich.server\|immich-server' | head -1 || true)
  [[ -n "$d_db" ]] && db_container="$d_db"
  [[ -n "$d_server" ]] && server_container="$d_server"

  ui_section "Docker containers"
  ui_input "$(_wiz_title "PostgreSQL container")" \
    "Name of the Immich PostgreSQL container.\n\n${d_db:+Auto-detected from running containers.}" \
    "$db_container" || { ui_info "Setup" "Cancelled. Nothing written."; return 0; }
  db_container="$UI_VALUE"
  ui_input "$(_wiz_title "immich_server container")" \
    "Name of the Immich server container.\n\n${d_server:+Auto-detected from running containers.}" \
    "$server_container" || { ui_info "Setup" "Cancelled. Nothing written."; return 0; }
  server_container="$UI_VALUE"

  # Expose the DB connection settings as globals so the lib/db.sh helpers
  # (_db_reachable, db_detect_library_prefix, db_get_users, db_check_schema...) can be
  # reused below instead of re-implementing inline psql calls.
  IMMICH_DB_CONTAINER="$db_container"
  IMMICH_DB_USER="$db_user"
  IMMICH_DB_NAME="$db_name"

  ui_section "Immich storage"
  ui_input "$(_wiz_title "Upload location")" \
    "Host path of Immich's UPLOAD_LOCATION (the folder that contains library/, backups/, ...).\n\nThis is read from your Immich docker-compose .env file." \
    "$upload_location" || { ui_info "Setup" "Cancelled. Nothing written."; return 0; }
  upload_location="$UI_VALUE"

  ui_section "External storage"
  ui_input "$(_wiz_title "External storage (host path)")" \
    "Host path where archived photos and DB backups are written (your big/cold disk or remote mount)." \
    "$archive_dest" || { ui_info "Setup" "Cancelled. Nothing written."; return 0; }
  archive_dest="$UI_VALUE"
  ui_input "$(_wiz_title "External storage (container path)")" \
    "The SAME external storage, but as seen from inside the immich_server container (its mount point in docker-compose)." \
    "$archive_container_path" || { ui_info "Setup" "Cancelled. Nothing written."; return 0; }
  archive_container_path="$UI_VALUE"

  # Establishes/recognizes the storage identity (install, relocation, conflict).
  local storage_id
  STORAGE_ID_RESULT=""
  _resolve_storage_marker "$archive_dest" "${ARCHIVE_STORAGE_ID:-}"
  storage_id="$STORAGE_ID_RESULT"
  # Keep the global in sync so later readiness/consistency checks use this id.
  ARCHIVE_STORAGE_ID="$storage_id"

  ui_section "Library prefix detection"
  # Auto-detect IMMICH_DB_LIBRARY_PREFIX from a sample asset path (reuses lib/db.sh).
  local detected_prefix="" prefix_note=""
  if _db_reachable && db_detect_library_prefix 2>/dev/null; then
    detected_prefix="$IMMICH_DB_LIBRARY_PREFIX"
  fi
  if [[ -n "$detected_prefix" ]]; then
    prefix_note="Auto-detected from the Immich database: $detected_prefix"
    [[ -z "$db_library_prefix" ]] && db_library_prefix="$detected_prefix"
  else
    prefix_note="Could not auto-detect (DB unreachable or no assets yet). Using the common default."
    [[ -z "$db_library_prefix" ]] && db_library_prefix="/data/library"
  fi
  ui_input "$(_wiz_title "DB library prefix")" \
    "Absolute prefix of asset paths stored in the Immich DB (originalPath).\n\n$prefix_note" \
    "$db_library_prefix" || { ui_info "Setup" "Cancelled. Nothing written."; return 0; }
  db_library_prefix="$UI_VALUE"

  ui_section "User → folder mapping"
  declare -A new_user_map=()
  local users_raw=""
  if _db_reachable; then
    users_raw=$(db_get_users 2>/dev/null || true)
  fi
  if [[ -n "$users_raw" ]]; then
    while IFS='|' read -r uid name storage_label; do
      [[ -z "$uid" ]] && continue
      local key="${storage_label:-$uid}"
      local current_mapped="${USER_MAP["$key"]:-}"
      local default_folder="${current_mapped:-${storage_label:-$name}}"
      ui_input "$(_wiz_title "Folder for $name")" \
        "Destination folder on the external storage for this user's photos.\n\nUser        : $name\nstorageLabel: ${storage_label:-<empty>}\nDB key      : $key" \
        "$default_folder" || { ui_info "Setup" "Cancelled. Nothing written."; return 0; }
      new_user_map["$key"]="$UI_VALUE"
    done <<< "$users_raw"
  else
    ui_info "$(_wiz_title "User mapping")" \
      "No Immich users found (DB unreachable or empty).\n\nUSER_MAP will be left empty. Re-run setup once Immich is running to populate it."
  fi

  ui_section "Archive boundaries (library size)"
  # Show the current footprint and the host disk so the user can pick sensible limits.
  local lib_path="${upload_location}/library"
  local cur_lib_bytes=0 disk_total=0 disk_free=0
  [[ -d "$lib_path" ]] && cur_lib_bytes=$(dir_size_bytes "$lib_path")
  if [[ -n "$upload_location" && -d "$upload_location" ]]; then
    disk_total=$(disk_total_bytes "$upload_location")
    disk_free=$(disk_free_bytes "$upload_location")
  fi
  local lib_line="Current library size : $(bytes_to_human "${cur_lib_bytes:-0}")"
  local disk_line
  if (( disk_total > 0 )); then
    disk_line="Disk hosting it      : $(bytes_to_human "$disk_total") total, $(bytes_to_human "$disk_free") free"
  else
    disk_line="Disk hosting it      : unknown (set an existing upload path to enable % and hints)"
  fi

  local max_mb=""
  while true; do
    ui_input "$(_wiz_title "Max library size")" \
      "$lib_line\n$disk_line\n\nArchiving STARTS when the library grows past this size.\nAccepted: 200 (GB) · 1.5G · 500M · 80%" \
      "$(mb_to_input "${def_max_mb:-0}")" || { ui_info "Setup" "Cancelled. Nothing written."; return 0; }
    max_mb=$(parse_size_to_mb "$UI_VALUE" "$disk_total")
    if [[ -n "$max_mb" ]] && (( max_mb > 0 )); then
      break
    fi
    ui_info "Invalid value" "Enter a positive size.\nExamples: 200, 1.5G, 500M, 80% (the % needs a detectable disk)."
  done

  # Suggest a sensible target (75% of max) when none is set or it is no longer valid.
  if [[ -z "$def_target_mb" ]] || (( def_target_mb >= max_mb )); then
    def_target_mb=$(( max_mb * 3 / 4 ))
  fi
  local target_mb=""
  while true; do
    ui_input "$(_wiz_title "Target library size")" \
      "Max is $(mb_to_human "$max_mb").\n\nAfter archiving, the library is brought back DOWN to this size.\nMust be smaller than the max.\nAccepted: 150 (GB) · 1G · 500M · 60%" \
      "$(mb_to_input "$def_target_mb")" || { ui_info "Setup" "Cancelled. Nothing written."; return 0; }
    target_mb=$(parse_size_to_mb "$UI_VALUE" "$disk_total")
    if [[ -n "$target_mb" ]] && (( target_mb > 0 && target_mb < max_mb )); then
      break
    fi
    ui_info "Invalid value" "The target must be a positive size BELOW the max ($(mb_to_human "$max_mb"))."
  done

  ui_section "DB backup"
  ui_input "$(_wiz_title "DB backups to keep")" \
    "How many Immich database backup files to keep before the oldest are rotated out." \
    "$backup_retention" || { ui_info "Setup" "Cancelled. Nothing written."; return 0; }
  backup_retention="$UI_VALUE"

  ui_section "Logs"
  ui_input "$(_wiz_title "Log directory")" \
    "Where to write the tool's log file (must be writable without sudo)." \
    "$log_dir" || { ui_info "Setup" "Cancelled. Nothing written."; return 0; }
  log_dir="$UI_VALUE"
  ui_input "$(_wiz_title "Log max lines")" \
    "Maximum number of lines kept in the log file (older lines are trimmed)." \
    "$log_max_lines" || { ui_info "Setup" "Cancelled. Nothing written."; return 0; }
  log_max_lines="$UI_VALUE"

  # Schema / path-consistency checks (non-blocking). Make the helpers see the values
  # entered in this wizard.
  IMMICH_DB_LIBRARY_PREFIX="$db_library_prefix"
  ARCHIVE_CONTAINER_PATH="$archive_container_path"
  if _db_reachable; then
    if ! db_check_schema 2>/dev/null; then
      ui_info "Schema check" "WARNING: Schema check failed — the Immich DB schema may have changed.\n\nReview the script before using it against this Immich version."
    fi
    # Case B: surface an external-library path change recorded in Immich's DB.
    if archive_dest_ready 2>/dev/null; then
      local consistency_report
      if ! consistency_report=$(db_check_path_consistency 2>/dev/null); then
        ui_info "Path consistency" "NOTE: Immich DB path inconsistency detected:\n\n$(printf '%s\n' "$consistency_report" | sed 's/^/  - /')\n\nMake sure the external (container) path matches the external library path now configured in Immich."
      fi
    fi
  fi

  # ── Summary & confirmation ──────────────────────────────────────────────────
  local summary
  printf -v summary '%s\n' \
    "Review your configuration:" \
    "" \
    "PostgreSQL container : $db_container" \
    "immich_server        : $server_container" \
    "Upload location      : $upload_location" \
    "DB library prefix    : $db_library_prefix" \
    "External (host)      : $archive_dest" \
    "External (container) : $archive_container_path" \
    "Storage id           : $storage_id" \
    "Archive starts above : $(mb_to_human "$max_mb")" \
    "Archive down to      : $(mb_to_human "$target_mb")" \
    "DB backups kept      : $backup_retention" \
    "Log directory        : $log_dir" \
    "Log max lines        : $log_max_lines"
  if (( ${#new_user_map[@]} > 0 )); then
    summary+=$'\nUser → folder:\n'
    for k in "${!new_user_map[@]}"; do
      summary+="  $k -> ${new_user_map[$k]}"$'\n'
    done
  fi
  summary+=$'\nWrite this to config.conf?'

  if ! ui_yesno "Confirm configuration" "$summary" no; then
    ui_info "Setup" "Cancelled. Nothing written."
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

# --- Archive boundaries (library size, in MiB; 1 GiB = 1024 MiB) ---
# Archiving starts when library/ exceeds MAX and runs until it drops to TARGET.
ARCHIVE_LIBRARY_MAX_MB=${max_mb}
ARCHIVE_LIBRARY_TARGET_MB=${target_mb}

# --- DB backup ---
BACKUP_RETENTION=${backup_retention}

# --- User → external folder mapping ---
${user_map_block}
# --- Logs ---
LOG_DIR="${log_dir}"
LOG_MAX_LINES=${log_max_lines}
CONF

  ui_info "Done" "config.conf written successfully."

  if ui_yesno "Cron jobs" "Install the scheduled cron jobs now so archiving and DB backups run automatically?" no; then
    _start
  fi
}

# ── status ────────────────────────────────────────────────────────────────────

_status() {
  echo "=== immich-auto-dumper status ==="

  local library_path="${IMMICH_UPLOAD_LOCATION:-}/library"
  if [[ -d "$library_path" ]]; then
    local lib_bytes disk_total disk_free
    lib_bytes=$(dir_size_bytes "$library_path")
    disk_total=$(disk_total_bytes "${IMMICH_UPLOAD_LOCATION}")
    disk_free=$(disk_free_bytes "${IMMICH_UPLOAD_LOCATION}")
    # Boundaries are stored in MiB; honor the deprecated *_GB keys for old configs.
    local s_max_mb="${ARCHIVE_LIBRARY_MAX_MB:-}" s_target_mb="${ARCHIVE_LIBRARY_TARGET_MB:-}"
    [[ -z "$s_max_mb"    && -n "${ARCHIVE_LIBRARY_MAX_GB:-}"    ]] && s_max_mb=$(( ARCHIVE_LIBRARY_MAX_GB * 1024 ))
    [[ -z "$s_target_mb" && -n "${ARCHIVE_LIBRARY_TARGET_GB:-}" ]] && s_target_mb=$(( ARCHIVE_LIBRARY_TARGET_GB * 1024 ))
    printf 'Library size         : %s  [max: %s — target: %s]\n' \
      "$(bytes_to_human "$lib_bytes")" \
      "${s_max_mb:+$(mb_to_human "$s_max_mb")}" "${s_target_mb:+$(mb_to_human "$s_target_mb")}"
    printf 'Disk (library FS)    : %s total, %s free\n' \
      "$(bytes_to_human "${disk_total:-0}")" "$(bytes_to_human "${disk_free:-0}")"
  else
    printf 'Library size         : unavailable (%s not found)\n' "$library_path"
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

  local log_file="${LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper}/immich-auto-dumper.log"
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

  # Render the template with the real binary path and log directory, so cron does not
  # depend on PATH or on a fixed /usr/local/bin or /var/log location.
  local bin logdir rendered
  bin=$(_resolve_self_bin)
  logdir="${LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper}"
  mkdir -p "$logdir" 2>/dev/null || true
  rendered=$(sed -e "s|__BIN__|${bin}|g" -e "s|__LOGDIR__|${logdir}|g" "$crontab_example")

  # Re-enable any entries a previous 'stop' commented out (symmetric to disable_cron),
  # then append any that are still missing. Without the un-comment step, a commented
  # line would match the substring check below and 'start' after 'stop' would no-op.
  # Only un-comment lines whose payload looks like a cron schedule (starts with a
  # digit, '*' or '@'), so a plain user comment mentioning immich-auto-dumper is
  # never turned into an invalid crontab line.
  local current
  current=$(crontab -l 2>/dev/null | sed 's|^#\([0-9*@].*immich-auto-dumper.*\)|\1|' || true)

  local new_entries=""
  while IFS= read -r line; do
    [[ "$line" =~ ^# || -z "$line" ]] && continue
    if ! printf '%s\n' "$current" | grep -qF -- "$line"; then
      new_entries+="$line"$'\n'
    fi
  done <<< "$rendered"

  if [[ -z "$new_entries" ]]; then
    printf '%s\n' "$current" | crontab -
    echo "Cron jobs enabled."
    return 0
  fi

  printf '%s\n%s' "$current" "$new_entries" | crontab -
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

  # setup creates the config; uninstall must work even when no config exists.
  if [[ "$cmd" != "setup" && "$cmd" != "uninstall" && -n "$cmd" ]]; then
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
    uninstall)
      # Hand off to the standalone uninstaller (self-relocates before deleting the
      # install dir). Pass through any -y/--yes flag.
      exec bash "$SCRIPT_DIR/uninstall.sh" "${args[@]:1}"
      ;;
    *)
      _usage
      [[ -z "$cmd" ]] && exit 0 || exit 1
      ;;
  esac
}

main "$@"
