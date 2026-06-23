#!/usr/bin/env bash
set -euo pipefail

# Resolve through a possible symlink (e.g. ~/.local/bin/immich-auto-dumper) so the
# lib/, config.conf and cron/ paths below are found relative to the real install
# dir, not the symlink's directory. Cron and PATH invocations go through that link.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.conf"

source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/detect.sh"
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
  ui_banner "immich-auto-dumper — guided setup"

  # Detect docker command first; everything below depends on it.
  detect_docker_cmd

  # The whole questionnaire can be restarted from the final confirmation screen
  # ("RE-RUN CONFIGURATION STEPS"), so wrap it in a loop. `break` proceeds to
  # writing the config, `continue` restarts, and any cancel/abort returns.
  while true; do

  # ── 1. Containers (auto-detected) ───────────────────────────────────────────
  detect_immich_containers
  local db_container="$DET_DB_CONTAINER" server_container="$DET_SERVER_CONTAINER"
  if [[ -z "$server_container" || -z "$db_container" ]]; then
    ui_info "Immich not found" \
      "Could not find the running Immich containers (server and/or PostgreSQL).\n\nimmich-auto-dumper configures itself from your live Immich install, so Immich must be running.\n\nStart Immich, then run setup again. Nothing was changed."
    return 0
  fi

  # DB credentials — read from the server container env when Immich exposes them.
  detect_db_credentials "$server_container"
  local db_user="${DET_DB_USER:-${IMMICH_DB_USER:-postgres}}"
  local db_name="${DET_DB_NAME:-${IMMICH_DB_NAME:-immich}}"
  IMMICH_DB_CONTAINER="$db_container"
  IMMICH_DB_USER="$db_user"
  IMMICH_DB_NAME="$db_name"

  ui_info "Immich detected" \
    "Found your Immich installation:\n\n  server container   : $server_container\n  postgres container : $db_container\n  database           : $db_name (user: $db_user)\n\nThe next steps confirm what the wizard detected from this install."

  # ── 2. Library prefix (from the DB) and upload mount (from docker) ───────────
  local db_library_prefix=""
  if _db_reachable && db_detect_library_prefix 2>/dev/null; then
    db_library_prefix="$IMMICH_DB_LIBRARY_PREFIX"
  fi

  detect_upload_mount "$server_container" "$db_library_prefix"
  local upload_location="$DET_UPLOAD_LOCATION"
  # Derive the DB prefix from the upload mount when the DB held no sample asset.
  if [[ -z "$db_library_prefix" && -n "$DET_UPLOAD_CONTAINER" ]]; then
    db_library_prefix="${DET_UPLOAD_CONTAINER%/}/library"
  fi
  [[ -z "$db_library_prefix" ]] && db_library_prefix="/usr/src/app/upload/library"
  IMMICH_DB_LIBRARY_PREFIX="$db_library_prefix"

  # ── 3. External library — REQUIRED ──────────────────────────────────────────
  # immich-auto-dumper moves photos into an Immich external library that Immich
  # keeps reading. With no external library it has nothing to do and cannot work.
  # The Docker mount mode (:ro) is not a filter here — see detect_external_libraries.
  # Host-side write access is verified later when the storage marker is written.
  local -a ext_raw=() ext_list=()
  mapfile -t ext_raw < <(detect_external_libraries "$server_container" "$DET_UPLOAD_CONTAINER")
  local e
  for e in "${ext_raw[@]}"; do [[ -n "$e" ]] && ext_list+=("$e"); done

  if (( ${#ext_list[@]} == 0 )); then
    ui_info "No external library found" \
      "No Immich *external library* is mounted in '$server_container'.\n\nThis tool moves photos OUT of Immich's internal library and INTO an external library that Immich still reads. Without one, it has nothing to archive to and cannot run.\n\nAdd an external library to your Immich docker-compose (a host bind-mount, then register it in Immich's admin UI), and run setup again.\n\nNothing was changed and no jobs were scheduled."
    return 0
  fi

  local archive_dest="" archive_container_path=""
  if (( ${#ext_list[@]} == 1 )); then
    IFS='|' read -r archive_dest archive_container_path <<< "${ext_list[0]}"
    if ! ui_yesno "External library" \
      "Detected one Immich external library — archived photos will be moved here:\n\n  host path      : $archive_dest\n  container path : $archive_container_path\n\nUse this external library?"; then
      ui_info "Setup" "Cancelled — nothing was written and no jobs were scheduled."
      return 0
    fi
  else
    # Several external libraries: let the user choose the destination.
    local -a menu_args=()
    local idx=1 host cont
    for e in "${ext_list[@]}"; do
      IFS='|' read -r host cont <<< "$e"
      menu_args+=("$idx" "$host  →  $cont")
      idx=$(( idx + 1 ))
    done
    ui_menu "Choose external library" \
      "Your Immich install has several external libraries. Pick the one immich-auto-dumper should move archived photos into:" \
      "${menu_args[@]}" || { ui_info "Setup" "Cancelled — nothing was written and no jobs were scheduled."; return 0; }
    IFS='|' read -r archive_dest archive_container_path <<< "${ext_list[$(( UI_VALUE - 1 ))]}"
  fi
  ARCHIVE_CONTAINER_PATH="$archive_container_path"

  # ── 4. Confirm the upload location (host path of the internal library) ───────
  if [[ -z "$upload_location" || ! -d "$upload_location" ]]; then
    ui_input "$(_wiz_title "Immich upload location")" \
      "Could not auto-detect Immich's upload location on this host (the folder that holds library/, backups/, thumbs/...).\n\nEnter it manually, or leave empty to abort." \
      "$upload_location" || { ui_info "Setup" "Cancelled — nothing was written and no jobs were scheduled."; return 0; }
    upload_location="$UI_VALUE"
  fi
  if [[ -z "$upload_location" || ! -d "$upload_location/library" ]]; then
    if ! ui_yesno "Upload location unusable" \
      "'$upload_location' does not look like an Immich upload location (no library/ folder found).\n\nWithout it the current library size cannot be measured and archiving cannot run.\n\nContinue anyway? (Choose No to abort without writing or scheduling anything.)" no; then
      ui_info "Setup" "Aborted — nothing was written and no jobs were scheduled."
      return 0
    fi
  fi
  IMMICH_UPLOAD_LOCATION="$upload_location"

  # ── 5. Storage marker (install / relocation / conflict) ─────────────────────
  local storage_id
  STORAGE_ID_RESULT=""
  _resolve_storage_marker "$archive_dest" "${ARCHIVE_STORAGE_ID:-}"
  storage_id="$STORAGE_ID_RESULT"
  ARCHIVE_STORAGE_ID="$storage_id"

  # ── 6. Archive boundaries with a visual disk gauge ──────────────────────────
  local cur_lib_bytes=0 disk_total=0 disk_free=0 disk_used=0
  [[ -d "$upload_location/library" ]] && cur_lib_bytes=$(dir_size_bytes "$upload_location/library")
  if [[ -n "$upload_location" && -d "$upload_location" ]]; then
    disk_total=$(disk_total_bytes "$upload_location")
    disk_free=$(disk_free_bytes "$upload_location")
    disk_used=$(( disk_total - disk_free )); (( disk_used < 0 )) && disk_used=0
  fi

  # Seed sensible defaults: from an existing config, else from the disk size.
  local def_max_mb="${ARCHIVE_LIBRARY_MAX_MB:-}" def_target_mb="${ARCHIVE_LIBRARY_TARGET_MB:-}"
  [[ -z "$def_max_mb"    && -n "${ARCHIVE_LIBRARY_MAX_GB:-}"    ]] && def_max_mb=$(( ARCHIVE_LIBRARY_MAX_GB * 1024 ))
  [[ -z "$def_target_mb" && -n "${ARCHIVE_LIBRARY_TARGET_GB:-}" ]] && def_target_mb=$(( ARCHIVE_LIBRARY_TARGET_GB * 1024 ))
  if [[ -z "$def_max_mb" || "$def_max_mb" -le 0 ]]; then
    if (( disk_total > 0 )); then
      def_max_mb=$(( disk_total * 80 / 100 / 1048576 ))
    else
      def_max_mb=$(( 200 * 1024 ))
    fi
  fi
  (( def_max_mb > 0 )) || def_max_mb=$(( 200 * 1024 ))
  if [[ -z "$def_target_mb" ]] || (( def_target_mb <= 0 || def_target_mb >= def_max_mb )); then
    def_target_mb=$(( def_max_mb * 3 / 4 ))
  fi

  local max_mb="$def_max_mb" target_mb="$def_target_mb" gauge v
  while true; do
    gauge=$(render_library_gauge "$disk_total" "$disk_used" "$cur_lib_bytes" "$max_mb" "$target_mb")
    ui_input "$(_wiz_title "MAX — start archiving above")" \
      "$gauge\n\nMAX: when the library grows ABOVE this, archiving begins.\nEnter a size — 200, 1.5G, 500M, or 80% of the disk." \
      "$(mb_to_input "$max_mb")" || { ui_info "Setup" "Cancelled — nothing was written and no jobs were scheduled."; return 0; }
    v=$(parse_size_to_mb "$UI_VALUE" "$disk_total")
    if [[ -z "$v" ]] || (( v <= 0 )); then
      ui_info "Invalid value" "Enter a positive size, e.g. 200, 1.5G, 500M, 80% (the % needs a detectable disk)."
      continue
    fi
    max_mb="$v"
    (( target_mb >= max_mb )) && target_mb=$(( max_mb * 3 / 4 ))

    gauge=$(render_library_gauge "$disk_total" "$disk_used" "$cur_lib_bytes" "$max_mb" "$target_mb")
    ui_input "$(_wiz_title "MIN — archive down to")" \
      "$gauge\n\nMIN: after archiving, the library is reduced back DOWN to this size.\nMust be below MAX ($(mb_to_human "$max_mb"))." \
      "$(mb_to_input "$target_mb")" || { ui_info "Setup" "Cancelled — nothing was written and no jobs were scheduled."; return 0; }
    v=$(parse_size_to_mb "$UI_VALUE" "$disk_total")
    if [[ -z "$v" ]] || (( v <= 0 || v >= max_mb )); then
      ui_info "Invalid value" "MIN must be a positive size BELOW MAX ($(mb_to_human "$max_mb"))."
      continue
    fi
    target_mb="$v"

    gauge=$(render_library_gauge "$disk_total" "$disk_used" "$cur_lib_bytes" "$max_mb" "$target_mb")
    if ui_yesno "Confirm boundaries" \
         "$gauge\n\nMAX = $(ui_em "$(mb_to_human "$max_mb")")    MIN = $(ui_em "$(mb_to_human "$target_mb")")\n\nKeep these boundaries, or reset and enter them again?" \
         yes "Keep these" "Reset the values"; then
      break
    fi
  done

  # ── 7. User → folder mapping (auto-suggested) ───────────────────────────────
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
      # Default to the human-readable user name, not the storageLabel (which is
      # often an opaque value for users other than the first admin).
      local default_folder="${current_mapped:-$name}"
      ui_input "$(_wiz_title "Folder for $name")" \
        "Sub-folder name on the external library for this user's archived photos.\n\nUser        : $name\nstorageLabel: ${storage_label:-<empty>}" \
        "$default_folder" || { ui_info "Setup" "Cancelled — nothing was written and no jobs were scheduled."; return 0; }
      new_user_map["$key"]="$UI_VALUE"
    done <<< "$users_raw"
  fi

  # Advanced knobs keep sensible defaults (or existing config); no extra prompts.
  local backup_retention="${BACKUP_RETENTION:-14}"
  local log_dir="${LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper}"
  local log_max_lines="${LOG_MAX_LINES:-1000}"

  # Schema / path-consistency checks (non-blocking).
  if _db_reachable; then
    if ! db_check_schema 2>/dev/null; then
      ui_info "Schema check" "WARNING: Schema check failed — the Immich DB schema may have changed.\n\nReview the script before using it against this Immich version."
    fi
    if archive_dest_ready 2>/dev/null; then
      local consistency_report
      if ! consistency_report=$(db_check_path_consistency 2>/dev/null); then
        ui_info "Path consistency" "NOTE: Immich DB path inconsistency detected:\n\n$(printf '%s\n' "$consistency_report" | sed 's/^/  - /')\n\nMake sure the external library path still matches the one configured in Immich."
      fi
    fi
  fi

  # ── 8. Summary & confirmation ───────────────────────────────────────────────
  # Two groups: values auto-detected from Immich, and values the user typed.
  # The latter are emphasized (bold in text mode) because a wrong manual value
  # is what can actually break the script, so they deserve a careful re-read.
  local summary
  printf -v summary '%s\n' \
    "THE SCRIPT WILL BE SET UP WITH THESE PARAMETERS." \
    "" \
    "Auto-detected from your Immich install:" \
    "  Immich server      : $server_container" \
    "  PostgreSQL         : $db_container ($db_name / $db_user)" \
    "  Upload location    : $upload_location" \
    "  Internal library   : $db_library_prefix" \
    "  External library   : $archive_dest" \
    "    (container path)    $archive_container_path" \
    "" \
    "You entered these — please double-check (a wrong value can break archiving):"
  summary+="  Start archiving at : $(ui_em "$(mb_to_human "$max_mb")")"$'\n'
  summary+="  Archive down to    : $(ui_em "$(mb_to_human "$target_mb")")"$'\n'
  if (( ${#new_user_map[@]} > 0 )); then
    summary+="  Folder per user:"$'\n'
    for k in "${!new_user_map[@]}"; do
      summary+="    $k -> $(ui_em "${new_user_map[$k]}")"$'\n'
    done
  fi

  ui_menu "Confirm configuration" "$summary" \
    validate "VALIDATE SETUP" \
    rerun    "RE-RUN CONFIGURATION STEPS" \
    abort    "ABORT SETUP" \
    || { ui_info "Setup" "Cancelled — nothing was written and no jobs were scheduled."; return 0; }
  case "$UI_VALUE" in
    validate) break ;;
    rerun)    continue ;;
    abort)    ui_info "Setup" "Aborted — nothing was written and no jobs were scheduled."; return 0 ;;
  esac

  done   # end of the restartable questionnaire loop

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
