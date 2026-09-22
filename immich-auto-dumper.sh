#!/usr/bin/env bash
set -euo pipefail

# Resolved through a possible symlink — ~/.local/bin/immich-auto-dumper, which
# the cron lines and a PATH invocation go through — so lib/, config.conf and
# cron/ are found in the real install directory.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.conf"

source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/detect.sh"
source "$SCRIPT_DIR/lib/db.sh"
source "$SCRIPT_DIR/lib/runlog.sh"
source "$SCRIPT_DIR/lib/backup_db.sh"
source "$SCRIPT_DIR/lib/archive.sh"

# Declared here and filled by the loader, so a `${USER_MAP[x]:-…}` lookup never
# trips set -u even when the config maps nobody.
declare -A USER_MAP=()

# False when config.conf exists but could not be read whole. Every command other
# than setup and uninstall then refuses to run.
CONFIG_LOADED=true
if [[ -f "$CONFIG_FILE" ]]; then
  config_load "$CONFIG_FILE" || CONFIG_LOADED=false
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

# Prints the logo and the command reference.
_usage() {
  ui_logo
  cat <<'EOF'
Usage: immich-auto-dumper <command> [--dry-run] [--force]

Commands:
  setup      Interactive configuration wizard (creates or updates config.conf)
  status     Show service status, disk usage, and last operations
  start      Enable cron jobs
  stop       Disable cron jobs and wait for any running operation to finish
  dump_now   Archive when the library exceeds MAX, down to TARGET (used by cron).
             Add --force to dump now regardless of MAX (still stops at TARGET).
  sync_now   Force an immediate copy of DB backups to external storage
  test_run   Verbose simulation of a forced dump + sync_now (implies --dry-run --force)
  rollback   Undo one archive run: bring its files back into the Immich library and
             point the database at them again. Takes a run id, as listed by status.
             Never happens on its own — it is a decision, on one identified run.
             Add --dry-run to see what would come back, and what would be refused,
             without restoring anything.
  uninstall  Remove the tool's local footprint (keeps Immich and external storage intact)

Flags:
  --dry-run  Suppress all destructive operations (cp, rm, DB UPDATE).
             Compatible with dump_now, sync_now and rollback.
  --force    Manual override for dump_now: ignore the MAX threshold and archive
             down to TARGET even if the library is below MAX.
EOF
}

# Exits when there is no config.conf at all.
_require_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    printf 'Error: config.conf not found. Run: immich-auto-dumper setup\n' >&2
    exit 1
  fi
}

# Echoes a random storage id, with no external dependency.
_new_storage_id() { cat /proc/sys/kernel/random/uuid; }

# Echoes the absolute path the cron lines invoke: the stable ~/.local/bin
# symlink, or the script's own location when that link is missing. Cron has a
# minimal PATH, which a bare command name would not resolve against.
_resolve_self_bin() {
  local link="$HOME/.local/bin/immich-auto-dumper"
  if [[ -x "$link" ]]; then
    printf '%s\n' "$link"
  else
    printf '%s\n' "$SCRIPT_DIR/immich-auto-dumper.sh"
  fi
}

# Creates or repairs the ~/.local/bin/immich-auto-dumper symlink, and warns when
# that directory is not in PATH. Owned by setup, so the link is re-established
# every time the user configures, however the tool was put in place. Prints only
# when it actually (re)creates the link.
_ensure_symlink() {
  local target link current
  target="$(readlink -f "$SCRIPT_DIR/immich-auto-dumper.sh")"
  link="$HOME/.local/bin/immich-auto-dumper"
  # Bare, this took the whole wizard down under `set -e` before anything was
  # saved. The link is a convenience — the tool runs perfectly well when called
  # by its path — so a home that cannot be written to is said out loud and the
  # rest of setup carries on.
  if ! mkdir -p "$HOME/.local/bin" 2>/dev/null; then
    printf '\033[31mWARNING: cannot create %s/.local/bin — no symlink was made.\033[0m\n' "$HOME"
    printf '\033[31mThe tool still runs from: %s\033[0m\n' "$target"
    return 0
  fi

  current=""
  [[ -e "$link" || -L "$link" ]] && current="$(readlink -f "$link" 2>/dev/null || true)"
  if [[ "$current" != "$target" ]]; then
    rm -f "$link"
    ln -s "$target" "$link"
    printf 'Symlink created: %s -> %s\n' "$link" "$target"
  fi

  if [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
    printf '\033[31mWARNING: ~/.local/bin is not in your PATH.\033[0m\n'
    printf '\033[31mTo use the command immich-auto-dumper, run:\033[0m\n'
    printf '\033[31m%s\033[0m\n' 'echo '"'"'export PATH="${HOME}/.local/bin:${PATH}"'"'"' >> ~/.bashrc && source ~/.bashrc'
  fi
}

# Echoes a wizard dialog title, prefixed so every step reads as one flow.
_wiz_title() { printf 'immich-auto-dumper Setup — %s' "$1"; }

# Normalises a USER_MAP sub-folder: surrounding slashes trimmed, repeated ones
# collapsed. Inner slashes are kept, since an Immich import path may be nested
# ("/external_library/family/alice" -> "family/alice").
#
# The value is pasted into "${ARCHIVE_DEST_PATH%/}/$folder/…", and Immich stores
# its import paths with a trailing slash, so a folder taken from one as-is would
# put a double slash into asset.originalPath — where Immich's own library scan
# records the single-slash form and re-imports the file as a duplicate.
_sanitize_folder() {
  local f="$1"
  while [[ "$f" == *//* ]]; do f="${f//\/\///}"; done
  f="${f#/}"; f="${f%/}"
  printf '%s' "$f"
}

# Echoes a two-level directory tree of the external library, indented, with the
# tool's own hidden directories left out. Nothing when the path is empty or
# unreadable.
_ext_library_tree() {
  local dest="$1"
  [[ -d "$dest" ]] || return 0
  (cd "$dest" && find . -mindepth 1 -maxdepth 2 -type d \
     ! -path './.immich-backup*' ! -name '.*' 2>/dev/null \
     | LC_ALL=C sort | sed -e 's|^\./||' -e 's|[^/]*/|  |g')
}

# Establishes that the storage is live before the marker is written into it,
# which keeps the marker out of an inactive mount point. Detected with findmnt
# where that is conclusive, and asked otherwise.
# Returns 0 when it is safe to write, 1 when the user chose to skip.
_ensure_storage_live() {
  local dest="$1"
  if archive_dest_is_mounted "$dest"; then
    return 0   # an active non-root mount: conclusive
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

# Settles the storage marker for a destination, across the four cases: a fresh
# install, a relocation, a storage already recognised, and a marker that belongs
# to another volume. Sets STORAGE_ID_RESULT — a global, since this function's
# output is the dialogs it draws on the terminal.
_resolve_storage_marker() {
  local dest="$1" config_id="$2"
  local marker="${dest%/}/.immich-auto-dumper.id"
  local found_id
  found_id=$(timeout 10 cat "$marker" 2>/dev/null || true)

  # write_archive_marker writes to the global, so it is pointed here first.
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

  # No marker at the destination: a fresh install, a relocation to an empty
  # target, or storage that is offline right now.
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

# Echoes the recommended free-disk floor, in MiB, for the filesystem holding
# <path>: 10% of the disk, clamped between 2 and 20 GiB and rounded down to a
# whole GiB, which round-trips exactly through mb_to_input. A disk size that
# cannot be read falls back to the same 2 GiB floor, never to 0 — zero is a value
# only the user chooses, since it turns the free-disk trigger off.
_recommended_min_free_mb() {
  local path="$1" total=0 mb=2048
  [[ -n "$path" && -d "$path" ]] && total=$(disk_total_bytes "$path")
  if (( total > 0 )); then
    mb=$(( total * 10 / 100 / 1048576 ))
    mb=$(( mb / 1024 * 1024 ))
    (( mb < 2048 ))  && mb=2048
    (( mb > 20480 )) && mb=20480
  fi
  printf '%s' "$mb"
}

# The archive boundaries as the config holds them, in MiB, and 0 when neither the
# *_MB key nor the deprecated *_GB one gives a usable number.
_cfg_max_mb() {
  local v="${ARCHIVE_LIBRARY_MAX_MB:-}"
  [[ -z "$v" && "${ARCHIVE_LIBRARY_MAX_GB:-}" =~ ^[0-9]+$ ]] && v=$(( ARCHIVE_LIBRARY_MAX_GB * 1024 ))
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  printf '%s' "$v"
}
_cfg_target_mb() {
  local v="${ARCHIVE_LIBRARY_TARGET_MB:-}"
  [[ -z "$v" && "${ARCHIVE_LIBRARY_TARGET_GB:-}" =~ ^[0-9]+$ ]] && v=$(( ARCHIVE_LIBRARY_TARGET_GB * 1024 ))
  [[ "$v" =~ ^[0-9]+$ ]] || v=0
  printf '%s' "$v"
}

# ── Config review (existing installation) ─────────────────────────────────────
#
# With a config.conf already present, setup opens on a review of it: the saved
# settings, checked against this version of the tool and against the live Immich,
# shown back before anything is offered.

# Settings with a safe default, which a config written by an older version can be
# topped up with in place. The keys that have no default are in
# _CFG_ESSENTIAL_KEYS, in lib/config.sh, next to the loader that enforces them.
_CFG_BACKFILL_KEYS=(ARCHIVE_MIN_FREE_MB BACKUP_RETENTION LOG_DIR LOG_MAX_LINES)

# Essential settings that are allowed to carry no value. ARCHIVE_STORAGE_ID is
# the only one: empty, it accepts whatever marker the storage carries instead of
# pinning the destination to one volume. The loader says so explicitly
# (lib/config.sh), and config.conf.example ships it empty with "Leave empty;
# setup fills it in" written next to it — so reporting it as a blocking problem
# sent anyone who followed that instruction to a review screen accusing their
# own example file.
_CFG_EMPTY_OK_KEYS=(ARCHIVE_STORAGE_ID)

# True when <key> may legitimately hold no value.
_cfg_empty_ok() {
  local k
  for k in "${_CFG_EMPTY_OK_KEYS[@]}"; do
    [[ "$k" == "$1" ]] && return 0
  done
  return 1
}

# Filled by _config_check: blocking findings, settings absent since an older
# version, and remarks that need no action. CFG_USER_NAME holds the Immich user
# names, so the summary can label USER_MAP keys that are often opaque UUIDs.
CFG_PROBLEMS=(); CFG_OUTDATED=(); CFG_NOTES=()
declare -A CFG_USER_NAME=()

# True when config.conf itself assigns <key> — not when the variable merely holds
# a value from the environment or from a default elsewhere in the script.
_config_has_key() { grep -qE "^[[:space:]]*${1}=" "$CONFIG_FILE" 2>/dev/null; }

# Echoes the number of entries in USER_MAP, including 0 for an array that is
# declared but unset, which `${#USER_MAP[@]}` would abort on under `set -u`.
_user_map_count() {
  local n=0
  [[ -n "${USER_MAP[*]+x}" ]] && n=${#USER_MAP[@]}
  printf '%s' "$n"
}

# Checks the saved config against this version of the tool and the live Immich,
# filling CFG_PROBLEMS, CFG_OUTDATED, CFG_NOTES and CFG_USER_NAME. A docker or a
# database that cannot be reached downgrades a verdict to a note and never
# invents a problem. Always returns 0.
_config_check() {
  # Whatever the loader refused is a config problem like any other, and belongs
  # on the same screen.
  CFG_PROBLEMS=("${CFG_LOAD_PROBLEMS[@]}")
  CFG_OUTDATED=(); CFG_NOTES=(); CFG_USER_NAME=()

  if "$CFG_LEGACY_USER_MAP"; then
    CFG_NOTES+=("The user mapping still uses the old 'declare -A USER_MAP' form. It is read correctly; finishing this setup rewrites it in the current format.")
  fi

  local k
  for k in "${_CFG_ESSENTIAL_KEYS[@]}"; do
    if ! _config_has_key "$k"; then
      CFG_PROBLEMS+=("$k is missing from config.conf.")
    elif [[ -z "${!k:-}" ]] && ! _cfg_empty_ok "$k"; then
      CFG_PROBLEMS+=("$k is empty.")
    fi
  done

  for k in "${_CFG_BACKFILL_KEYS[@]}"; do
    _config_has_key "$k" || CFG_OUTDATED+=("$k")
  done

  local max_mb target_mb
  max_mb=$(_cfg_max_mb); target_mb=$(_cfg_target_mb)
  if (( max_mb <= 0 )); then
    CFG_PROBLEMS+=("No archiving threshold set (ARCHIVE_LIBRARY_MAX_MB).")
  elif (( target_mb <= 0 || target_mb >= max_mb )); then
    CFG_PROBLEMS+=("Archive-down-to size must be a positive size BELOW the $(mb_to_human "$max_mb") threshold.")
  fi

  local retention="${BACKUP_RETENTION:-}"
  if _config_has_key BACKUP_RETENTION && ! [[ "$retention" =~ ^[1-9][0-9]*$ ]]; then
    CFG_PROBLEMS+=("BACKUP_RETENTION must be a positive whole number (found '${retention}').")
  fi

  # An empty map is caught here, without the database; the per-user check further
  # down needs it.
  if (( $(_user_map_count) == 0 )); then
    CFG_PROBLEMS+=("No user → folder mapping (USER_MAP is empty): archiving has no destination folder to use.")
  else
    # A folder with a stray leading/trailing/double slash builds paths like
    # "/external_library/Alice//2020/…" into asset.originalPath, which Immich's own
    # library scan does not recognize as the file it sees.
    local mk clean
    for mk in "${!USER_MAP[@]}"; do
      clean=$(_sanitize_folder "${USER_MAP[$mk]}")
      if [[ "$clean" != "${USER_MAP[$mk]}" ]]; then
        CFG_PROBLEMS+=("USER_MAP[\"$mk\"]=\"${USER_MAP[$mk]}\" has a stray slash: archived paths would contain a double slash Immich cannot match. It should be \"${clean}\".")
      fi
    done

    # Two users pointed at one folder archive into the same tree, where a single
    # relative path names two different photos. An archive run refuses such an
    # asset rather than destroying it, and stalls on every collision; this screen
    # is where the config can still be fixed.
    local key_a key_b
    local -a seen_keys=("${!USER_MAP[@]}")
    local i j
    for (( i = 0; i < ${#seen_keys[@]}; i++ )); do
      for (( j = i + 1; j < ${#seen_keys[@]}; j++ )); do
        key_a="${seen_keys[$i]}"; key_b="${seen_keys[$j]}"
        [[ "${USER_MAP[$key_a]}" == "${USER_MAP[$key_b]}" ]] || continue
        CFG_PROBLEMS+=("USER_MAP sends two users to the same folder \"${USER_MAP[$key_a]}\" (keys '$key_a' and '$key_b'): their photos would collide on identical paths. Give each user its own folder.")
      done
    done
  fi

  if [[ -n "${IMMICH_UPLOAD_LOCATION:-}" && ! -d "${IMMICH_UPLOAD_LOCATION}/library" ]]; then
    CFG_PROBLEMS+=("Upload location '${IMMICH_UPLOAD_LOCATION}' has no library/ folder any more.")
  fi

  # Storage that is unreachable right now is a state and only a note: a removable
  # or remote mount is allowed to be down. A destination path that does not exist
  # on this host at all is a problem.
  if [[ -n "${ARCHIVE_DEST_PATH:-}" ]]; then
    local dest_state=0
    archive_dest_ready 2>/dev/null || dest_state=$?
    if (( dest_state == 0 )); then
      CFG_NOTES+=("External storage is reachable and its marker matches this config.")
    elif [[ ! -d "$ARCHIVE_DEST_PATH" ]]; then
      CFG_PROBLEMS+=("External library path '${ARCHIVE_DEST_PATH}' does not exist on this host.")
    elif (( dest_state >= 2 )); then
      # Not "not plugged in": something is answering badly.
      CFG_PROBLEMS+=("External storage state could not be established — ${_ARCHIVE_DEST_REASON}.")
    else
      CFG_NOTES+=("External storage not reachable right now (${_ARCHIVE_DEST_REASON}) — archiving stays paused until it is back.")
    fi
  fi

  if ! probe_docker_cmd 2>/dev/null; then
    CFG_NOTES+=("Docker is not reachable, so the configured containers could not be verified.")
    return 0
  fi

  local running name
  running=$($DOCKER_CMD ps --format '{{.Names}}' 2>/dev/null || true)
  for k in IMMICH_SERVER_CONTAINER IMMICH_DB_CONTAINER; do
    name="${!k:-}"
    [[ -z "$name" ]] && continue
    printf '%s\n' "$running" | grep -qx -- "$name" \
      || CFG_PROBLEMS+=("Container '${name}' (${k}) is not running — stopped, or renamed in your compose file?")
  done

  if ! _db_reachable; then
    CFG_NOTES+=("The Immich database did not answer, so the user mapping and library paths could not be verified.")
    return 0
  fi

  local schema_state=0
  db_check_schema >/dev/null 2>&1 || schema_state=$?
  if (( schema_state == 1 )); then
    CFG_PROBLEMS+=("Immich's database schema no longer matches what this tool expects — review it before archiving again.")
  elif (( schema_state >= 2 )); then
    # A note and not a problem: nothing was learned about the schema.
    CFG_NOTES+=("The schema could not be checked: the database stopped answering.")
  fi

  # Every Immich user needs a destination folder, so one added since the last
  # setup is reported here.
  local users_raw row uid uname label key
  local -a unmapped=()
  # `|| true` absorbs the 2 that means "the database did not answer": this screen
  # must open against a mute Immich, where a user list that cannot be read costs
  # the labels and not the review. Every `|| true` on a setup or preview path in
  # this file reads the same way; nothing on the archiving path absorbs a 2.
  users_raw=$(db_get_users 2>/dev/null || true)
  if [[ -n "$users_raw" ]]; then
    local -a _u=()
    mapfile -t _u <<< "$users_raw"
    for row in "${_u[@]}"; do
      [[ -z "$row" ]] && continue
      IFS="$DB_FIELD_SEP" read -r uid uname label <<< "$row"
      [[ -z "$uid" ]] && continue
      key="${label:-$uid}"
      CFG_USER_NAME["$key"]="$uname"
      [[ -n "${USER_MAP["$key"]:-}" ]] || unmapped+=("$uname")
    done
    # Only when some users ARE mapped: an entirely empty map is reported above.
    (( ${#unmapped[@]} > 0 && $(_user_map_count) > 0 )) \
      && CFG_PROBLEMS+=("No destination folder configured for: ${unmapped[*]} — user(s) added in Immich since the last setup.")
  fi

  # Gated on the storage, which db_check_path_consistency depends on.
  if archive_dest_ready 2>/dev/null; then
    local report consistency_state=0
    report=$(db_check_path_consistency 2>/dev/null) || consistency_state=$?
    if (( consistency_state == 1 )); then
      CFG_PROBLEMS+=("Immich's paths no longer match this config: $(printf '%s' "$report" | tr '\n' ' ')")
    elif (( consistency_state >= 2 )); then
      CFG_NOTES+=("Immich's paths could not be checked: $(printf '%s' "$report" | tr '\n' ' ')")
    fi
  fi

  # Mirroring fewer dumps than Immich keeps locally drops dumps from the external
  # storage while Immich still holds them: a note, not a config error.
  local keep
  keep=$(db_immich_backup_keep_last)
  if [[ -n "$keep" && "$retention" =~ ^[0-9]+$ ]] && (( retention < keep )); then
    CFG_NOTES+=("Immich keeps ${keep} database dumps locally but only ${retention} are mirrored to the external storage.")
  fi
  return 0
}

# Echoes cron_state as one human-readable line.
_cron_state_label() {
  case "$(cron_state)" in
    active)   printf 'ACTIVE — archiving and DB backups run automatically' ;;
    disabled) printf 'DISABLED — entries present in the crontab but commented out' ;;
    *)        printf 'NOT INSTALLED — nothing runs automatically' ;;
  esac
}

# Echoes the saved config as the review screen shows it: one line per setting,
# the live schedule state, and where each user's photos are archived.
_config_summary() {
  local max_mb target_mb min_free
  max_mb=$(_cfg_max_mb); target_mb=$(_cfg_target_mb)
  min_free="${ARCHIVE_MIN_FREE_MB:-0}"
  [[ "$min_free" =~ ^[0-9]+$ ]] || min_free=0

  printf '%s\n' \
    "Immich server      : ${IMMICH_SERVER_CONTAINER:-<not set>}" \
    "PostgreSQL         : ${IMMICH_DB_CONTAINER:-<not set>} (${IMMICH_DB_NAME:-?} / ${IMMICH_DB_USER:-?})" \
    "Upload location    : ${IMMICH_UPLOAD_LOCATION:-<not set>}" \
    "Internal library   : ${IMMICH_DB_LIBRARY_PREFIX:-<not set>}" \
    "External library   : ${ARCHIVE_DEST_PATH:-<not set>}" \
    "  (container path)   ${ARCHIVE_CONTAINER_PATH:-<not set>}" \
    "Start archiving at : ▼ $( (( max_mb > 0 )) && mb_to_human "$max_mb" || printf '<not set>' )" \
    "Archive down to    : ▲ $( (( target_mb > 0 )) && mb_to_human "$target_mb" || printf '<not set>' )" \
    "Free-disk safety   : $( (( min_free > 0 )) && printf 'also archive if free disk < %s' "$(mb_to_human "$min_free")" || printf 'disabled' )" \
    "DB dumps mirrored  : ${BACKUP_RETENTION:-<not set>} kept on the external storage" \
    "Scheduled jobs     : $(_cron_state_label)"

  if (( $(_user_map_count) > 0 )); then
    printf '\nWhere each user'"'"'s photos are archived:\n'
    local k
    for k in "${!USER_MAP[@]}"; do
      printf '  %s : %s\n' "${CFG_USER_NAME[$k]:-$k}" "${ARCHIVE_DEST_PATH%/}/${USER_MAP[$k]}"
    done
  fi
}

# Echoes the value this version uses for a setting absent from an older config.
_config_default_for() {
  case "$1" in
    ARCHIVE_MIN_FREE_MB) _recommended_min_free_mb "${IMMICH_UPLOAD_LOCATION:-}" ;;
    BACKUP_RETENTION)
      local keep=""
      probe_docker_cmd 2>/dev/null && _db_reachable && keep=$(db_immich_backup_keep_last)
      # Validated, not merely defaulted: `${keep:-14}` substitutes for an empty
      # value alone, and a retention of 0 deletes every mirrored dump.
      [[ "$keep" =~ ^[1-9][0-9]*$ ]] || keep=14
      printf '%s' "$keep"
      ;;
    LOG_DIR)       printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper" ;;
    LOG_MAX_LINES) printf '1000' ;;
  esac
}

# Appends the settings in CFG_OUTDATED to config.conf with their defaults, and
# logs each line it wrote. Only ever adds lines, so a value the user edited is
# never rewritten. Through a temporary copy and a rename, like every other write
# to this file.
_config_backfill() {
  local k v tmp="$CONFIG_FILE.tmp"
  cp -f -- "$CONFIG_FILE" "$tmp" || return 1
  {
    printf '\n# --- Added by setup on %s (settings new in this version) ---\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    for k in "${CFG_OUTDATED[@]}"; do
      v=$(_config_default_for "$k")
      case "$k" in
        LOG_DIR) printf '%s="%s"\n' "$k" "$v" ;;
        *)       printf '%s=%s\n'   "$k" "$v" ;;
      esac
    done
  } >> "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$CONFIG_FILE" || { rm -f -- "$tmp"; return 1; }
  for k in "${CFG_OUTDATED[@]}"; do
    log_info "config.conf: added $k=$(_config_default_for "$k") (default for this version)"
  done
}

# Echoes cron/crontab.example with __BIN__ and __LOGDIR__ substituted, keeping
# only its schedule lines. Returns 1 when the template is missing.
_render_cron_lines() {
  local tpl="$SCRIPT_DIR/cron/crontab.example"
  [[ -f "$tpl" ]] || return 1
  local bin logdir
  bin=$(_resolve_self_bin)
  logdir="${LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper}"
  sed -e "s|__BIN__|${bin}|g" -e "s|__LOGDIR__|${logdir}|g" "$tpl" \
    | grep -vE '^[[:space:]]*(#|$)' || true
}

# The wizard's schedule step: shows what is scheduled right now, listing the
# crontab lines, then offers the actions that fit that state and runs the chosen
# one through _start or _stop.
_cron_review() {
  local state entries listing
  state=$(cron_state)
  entries=$(cron_entries)
  listing=""
  [[ -n "$entries" ]] && listing=$'\n\nIn your crontab right now:\n'"$(printf '%s\n' "$entries" | sed 's/^/  /')"

  case "$state" in
    active)
      ui_menu "Scheduled jobs — ACTIVE" \
        "Archiving and DB backups are ALREADY scheduled: they run automatically, nothing to do.${listing}" \
        keep    "Leave them exactly as they are (recommended)" \
        refresh "Re-install the entries (after a move or a log-dir change)" \
        stop    "Disable them (comment them out in the crontab)" || return 0
      case "$UI_VALUE" in
        refresh) _start ;;
        stop)    _stop ;;
      esac
      ;;
    disabled)
      if ui_yesno "Scheduled jobs — DISABLED" \
        "Nothing runs automatically: the entries are in your crontab but commented out, which is what \"immich-auto-dumper stop\" leaves behind.${listing}\n\nRe-enable them now?"; then
        _start
      fi
      ;;
    *)
      local would
      would=$(_render_cron_lines || true)
      [[ -n "$would" ]] && would=$'\n\nEntries that would be added:\n'"$(printf '%s\n' "$would" | sed 's/^/  /')"
      if ui_yesno "Scheduled jobs — NOT INSTALLED" \
        "Nothing is scheduled: archiving and DB backups only run when you launch them by hand.${would}\n\nInstall them now so they run automatically?" no; then
        _start
      fi
      ;;
  esac
}

# The opening screens when a config already exists: the saved settings, the
# verdict of the checks, then the choice. Sets SETUP_REVIEW_CHOICE to keep, full
# or cancel — with the step-by-step recommended first only when a check failed.
SETUP_REVIEW_CHOICE=""
_setup_review() {
  _config_check

  ui_info "Your configuration" \
    "Saved in ${CONFIG_FILE}:"$'\n\n'"$(_config_summary)"

  local verdict
  if (( ${#CFG_PROBLEMS[@]} > 0 )); then
    verdict="Checked against this version of the tool and your live Immich."$'\n\n'
    verdict+="These no longer hold up:"$'\n'
    verdict+="$(printf '%s\n' "${CFG_PROBLEMS[@]}" | sed 's/^/  ! /')"
  else
    verdict="Checked against this version of the tool and your live Immich: every setting is still valid."
  fi
  if (( ${#CFG_OUTDATED[@]} > 0 )); then
    verdict+=$'\n\n'"Settings this version added, still absent from your config (they can be appended with their defaults, without touching the rest):"$'\n  '"${CFG_OUTDATED[*]}"
  fi
  if (( ${#CFG_NOTES[@]} > 0 )); then
    verdict+=$'\n\n'"For information:"$'\n'
    verdict+="$(printf '%s\n' "${CFG_NOTES[@]}" | sed 's/^/  - /')"
  fi
  ui_info "Configuration check" "$verdict"

  local -a menu=()
  if (( ${#CFG_PROBLEMS[@]} > 0 )); then
    menu=(full   "Reconfigure step by step (recommended)"
          keep   "Keep this config as it is anyway"
          cancel "Quit without changing anything")
  else
    menu=(keep   "Keep this config (recommended)"
          full   "Reconfigure step by step anyway"
          cancel "Quit without changing anything")
  fi
  ui_menu "Existing configuration" "What should setup do?" "${menu[@]}" || UI_VALUE="cancel"
  SETUP_REVIEW_CHOICE="$UI_VALUE"
}

# The "keep my config" path: it offers to top up the settings this version added,
# reviews the schedule, and rewrites no answer the user already gave.
_setup_keep() {
  if (( ${#CFG_OUTDATED[@]} > 0 )); then
    local -a lines=()
    local k
    for k in "${CFG_OUTDATED[@]}"; do
      lines+=("  ${k} = $(_config_default_for "$k")")
    done
    if ui_yesno "Add the new settings" \
      "This version has settings your config.conf does not mention yet. They can be appended with their default values, leaving every other line untouched:"$'\n\n'"$(printf '%s\n' "${lines[@]}")"$'\n\n'"Add them now?"; then
      _config_backfill
      ui_info "config.conf updated" "The settings above were appended to ${CONFIG_FILE}. Re-run setup and choose \"Reconfigure step by step\" if you want to pick different values."
    fi
  fi

  _cron_review

  printf '\n========================================\n'
  printf 'immich-auto-dumper: config kept as it is\n'
  printf '========================================\n'
  printf 'Config file    : %s\n' "$CONFIG_FILE"
  printf 'Scheduled jobs : %s\n' "$(_cron_state_label)"
  printf 'Run "immich-auto-dumper status" for the current library size and last operations.\n'
  printf '========================================\n\n'
}

# ── setup ─────────────────────────────────────────────────────────────────────

# The configuration wizard, and the only writer of config.conf. It detects the
# running Immich, asks the user to confirm what it found, writes the file, creates
# each user's destination folder, then reviews the schedule.
_setup() {
  # First, since the cron lines generated later resolve through this symlink.
  _ensure_symlink

  ui_detect
  ui_logo
  ui_banner "immich-auto-dumper — guided setup"

  # An existing config is reviewed first, and before detect_docker_cmd, which
  # exits when the daemon is unreachable: the saved config can be shown and the
  # schedule managed while Immich or Docker is down.
  if [[ -f "$CONFIG_FILE" ]]; then
    _setup_review
    case "$SETUP_REVIEW_CHOICE" in
      keep)   _setup_keep; return 0 ;;
      cancel) ui_info "Setup" "Left unchanged — nothing was written and no jobs were scheduled."; return 0 ;;
    esac
  fi

  # Everything below depends on docker.
  detect_docker_cmd

  # ── 1. Containers (auto-detected) ───────────────────────────────────────────
  detect_immich_containers
  local db_container="$DET_DB_CONTAINER" server_container="$DET_SERVER_CONTAINER"
  if [[ -z "$server_container" || -z "$db_container" ]]; then
    ui_info "Immich not found" \
      "Could not find the running Immich containers (server and/or PostgreSQL).\n\nimmich-auto-dumper configures itself from your live Immich install, so Immich must be running.\n\nStart Immich, then run setup again. Nothing was changed."
    return 0
  fi

  # DB credentials, from the server container's environment when it exposes them.
  detect_db_credentials "$server_container"
  local db_user="${DET_DB_USER:-${IMMICH_DB_USER:-postgres}}"
  local db_name="${DET_DB_NAME:-${IMMICH_DB_NAME:-immich}}"
  IMMICH_DB_CONTAINER="$db_container"
  IMMICH_DB_USER="$db_user"
  IMMICH_DB_NAME="$db_name"

  # Several containers can match the patterns. The first match wins, and the
  # dialog below names the candidates and says which way the choice went.
  local ambiguity="" n_db n_srv
  n_db=$(detect_candidate_count "$DET_DB_CANDIDATES")
  n_srv=$(detect_candidate_count "$DET_SERVER_CANDIDATES")
  if (( n_db > 1 )); then
    ambiguity+=$'\n\n'"$n_db running containers look like a PostgreSQL for Immich:"$'\n'
    ambiguity+="$(printf '%s\n' "$DET_DB_CANDIDATES" | grep -v '^$' | sed 's/^/  - /')"
    ambiguity+=$'\n'"Kept: $db_container. If that is the wrong one, rename the container or fix IMMICH_DB_CONTAINER in config.conf."
    log_warn "Several PostgreSQL candidates ($(printf '%s' "$DET_DB_CANDIDATES" | tr '\n' ' ')) — using '$db_container'."
  fi
  if (( n_srv > 1 )); then
    ambiguity+=$'\n\n'"$n_srv running containers look like the Immich server:"$'\n'
    ambiguity+="$(printf '%s\n' "$DET_SERVER_CANDIDATES" | grep -v '^$' | sed 's/^/  - /')"
    ambiguity+=$'\n'"Kept: $server_container. If that is the wrong one, rename the container or fix IMMICH_SERVER_CONTAINER in config.conf."
    log_warn "Several Immich server candidates ($(printf '%s' "$DET_SERVER_CANDIDATES" | tr '\n' ' ')) — using '$server_container'."
  fi

  ui_info "Immich detected" \
    "Found your Immich installation:\n\n  server container   : $server_container\n  postgres container : $db_container\n  database           : $db_name (user: $db_user)${ambiguity}\n\nThe next steps confirm what the wizard detected from this install."

  # ── 2. Library prefix (from the DB) and upload mount (from docker) ───────────
  local db_library_prefix=""
  if _db_reachable && db_detect_library_prefix 2>/dev/null; then
    db_library_prefix="$IMMICH_DB_LIBRARY_PREFIX"
  fi

  detect_upload_mount "$server_container" "$db_library_prefix"
  local upload_location="$DET_UPLOAD_LOCATION"
  # The DB prefix, derived from the upload mount when the database held no asset
  # to read it from, and hard-coded as a last resort.
  if [[ -z "$db_library_prefix" && -n "$DET_UPLOAD_CONTAINER" ]]; then
    db_library_prefix="${DET_UPLOAD_CONTAINER%/}/library"
  fi
  [[ -z "$db_library_prefix" ]] && db_library_prefix="/usr/src/app/upload/library"
  IMMICH_DB_LIBRARY_PREFIX="$db_library_prefix"

  # ── 3. External library — REQUIRED ──────────────────────────────────────────
  # With no external library mounted into the server container there is nowhere
  # to archive to, and setup stops. Host-side write access is verified further
  # down, when the storage marker is written.
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
    IFS="$DET_FIELD_SEP" read -r archive_dest archive_container_path <<< "${ext_list[0]}"
    if ! ui_yesno "External folder (from Docker)" \
      "Detected one external folder mounted into '$server_container' in Docker config — archived photos will be moved here:\n\n  host path      : $archive_dest\n  container path : $archive_container_path\n\nUse this folder as the archive destination?"; then
      ui_info "Setup" "Cancelled — nothing was written and no jobs were scheduled."
      return 0
    fi
  else
    # Several external libraries: the user picks the destination.
    local -a menu_args=()
    local idx=1 host cont
    for e in "${ext_list[@]}"; do
      IFS="$DET_FIELD_SEP" read -r host cont <<< "$e"
      menu_args+=("$idx" "$host  →  $cont")
      idx=$(( idx + 1 ))
    done
    ui_menu "Choose external library" \
      "Your Immich install has several external libraries. Pick the one immich-auto-dumper should move archived photos into:" \
      "${menu_args[@]}" || { ui_info "Setup" "Cancelled — nothing was written and no jobs were scheduled."; return 0; }
    IFS="$DET_FIELD_SEP" read -r archive_dest archive_container_path <<< "${ext_list[$(( UI_VALUE - 1 ))]}"
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

  # The ceiling MAX is validated against: free disk plus the library's current
  # size, the most it can ever reach before the disk itself fills. 0 when the disk
  # is unknown, which skips that check.
  local lib_cap_mb=0
  (( disk_total > 0 )) && lib_cap_mb=$(( (disk_free + cur_lib_bytes) / 1048576 ))

  # Defaults, taken from an existing config and otherwise from the disk size.
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
  # Held within the ceiling, so the suggestion is never pre-rejected.
  (( lib_cap_mb > 0 && def_max_mb > lib_cap_mb )) && def_max_mb=$lib_cap_mb
  if [[ -z "$def_target_mb" ]] || (( def_target_mb <= 0 || def_target_mb >= def_max_mb )); then
    def_target_mb=$(( def_max_mb * 3 / 4 ))
  fi

  local max_mb="$def_max_mb" target_mb="$def_target_mb" gauge v
  # A boundary seeded from the disk size counts as not yet defined, so its first
  # gauge shows a placeholder marker and a "set a … value" hint.
  local max_user_set=false min_user_set=false
  [[ -n "${ARCHIVE_LIBRARY_MAX_MB:-}${ARCHIVE_LIBRARY_MAX_GB:-}" ]] && max_user_set=true
  [[ -n "${ARCHIVE_LIBRARY_TARGET_MB:-}${ARCHIVE_LIBRARY_TARGET_GB:-}" ]] && min_user_set=true
  while true; do
    local gmax gmin
    "$max_user_set" && gmax="$max_mb" || gmax=0
    "$min_user_set" && gmin="$target_mb" || gmin=0
    # For MAX ▼, a % is taken on the whole disk.
    gauge=$(render_library_gauge "$disk_total" "$disk_used" "$cur_lib_bytes" "$gmax" "$gmin" max)
    ui_input "$(_wiz_title "MAX ▼ — start archiving above")" \
      "$gauge\n\nMAX ▼: when the library grows ABOVE this, archiving begins.\nEnter a size (200, 1.5G, 500M) or a % of the disk (e.g. 80%)." \
      "$(mb_to_input "$max_mb")" || { ui_info "Setup" "Cancelled — nothing was written and no jobs were scheduled."; return 0; }
    v=$(parse_size_to_mb "$UI_VALUE" "$disk_total")
    if [[ -z "$v" ]] || (( v <= 0 )); then
      ui_info "Invalid value" "Enter a positive size, e.g. 200, 1.5G, 500M, 80% (the % needs a detectable disk)."
      continue
    fi
    if (( lib_cap_mb > 0 && v > lib_cap_mb )); then
      ui_info "MAX ▼ too large" "MAX ▼ ($(mb_to_human "$v")) exceeds the space the library can use ($(mb_to_human "$lib_cap_mb") = free disk + current library).\n\nBeyond that the disk fills before MAX is reached and archiving never triggers. Enter a smaller value."
      continue
    fi
    max_mb="$v"; max_user_set=true
    (( target_mb >= max_mb )) && target_mb=$(( max_mb * 3 / 4 ))

    "$min_user_set" && gmin="$target_mb" || gmin=0
    # For MIN ▲, a % is taken on MAX, the library's largest permitted size.
    gauge=$(render_library_gauge "$disk_total" "$disk_used" "$cur_lib_bytes" "$max_mb" "$gmin" min)
    ui_input "$(_wiz_title "MIN ▲ — archive down to")" \
      "$gauge\n\nMIN ▲: after archiving, the library is brought back DOWN to this size.\nEnter a size, or a % of MAX ▼ ($(mb_to_human "$max_mb")). Must be below MAX." \
      "$(mb_to_input "$target_mb")" || { ui_info "Setup" "Cancelled — nothing was written and no jobs were scheduled."; return 0; }
    v=$(parse_size_to_mb "$UI_VALUE" "$(( max_mb * 1048576 ))")
    if [[ -z "$v" ]] || (( v <= 0 || v >= max_mb )); then
      ui_info "Invalid value" "MIN ▲ must be a positive size BELOW MAX ▼ ($(mb_to_human "$max_mb")). A % is taken on MAX."
      continue
    fi
    target_mb="$v"; min_user_set=true

    gauge=$(render_library_gauge "$disk_total" "$disk_used" "$cur_lib_bytes" "$max_mb" "$target_mb")
    if ui_yesno "Confirm boundaries" \
         "$gauge\n\nMAX ▼ = $(ui_em "$(mb_to_human "$max_mb")")    MIN ▲ = $(ui_em "$(mb_to_human "$target_mb")")\n\nKeep these boundaries, or reset and enter them again?" \
         yes "Keep these" "Reset the values"; then
      break
    fi
  done

  # ── 6b. Free-disk safety net ─────────────────────────────────────────────────
  # The second trigger, independent of the MAX above: total free disk space below
  # this floor. On by default, at the value _recommended_min_free_mb computes,
  # and turned off by entering 0.
  local def_min_free_mb
  def_min_free_mb=$(_recommended_min_free_mb "$upload_location")
  local min_free_mb="${ARCHIVE_MIN_FREE_MB:-$def_min_free_mb}"
  while true; do
    ui_input "$(_wiz_title "FREE ▽ — also archive if disk free drops below")" \
      "Independent safety net: even if the library stays under MAX ▼, archiving\nalso triggers when TOTAL free disk space on this filesystem drops below this\nvalue (other processes — DB, Docker, logs — can fill the disk too).\n\nRecommended for this disk: $(mb_to_human "$def_min_free_mb")\nEnter a size, a % of the disk, or 0 to disable this safety net entirely." \
      "$(mb_to_input "$min_free_mb")" || { ui_info "Setup" "Cancelled — nothing was written and no jobs were scheduled."; return 0; }
    if [[ -z "$UI_VALUE" ]]; then
      min_free_mb=0
      break
    fi
    v=$(parse_size_to_mb "$UI_VALUE" "$disk_total")
    if [[ -z "$v" ]]; then
      ui_info "Invalid value" "Enter a positive size, e.g. 2G, 500M, 10% (the % needs a detectable disk), or 0 to disable."
      continue
    fi
    if (( v <= 0 )); then
      min_free_mb=0
      break
    fi
    if (( v < def_min_free_mb )); then
      if ui_yesno "Below recommended floor" \
           "$(mb_to_human "$v") is below the recommended safety floor of $(mb_to_human "$def_min_free_mb") for this disk (computed as 10% of total disk size, between a 2 GB floor and a 20 GB cap).\n\nA smaller value protects less reliably against the disk filling up from unrelated data. Keep $(mb_to_human "$v") anyway, or use the recommended value instead?" \
           yes "Keep $(mb_to_human "$v")" "Use recommended ($(mb_to_human "$def_min_free_mb"))"; then
        min_free_mb="$v"
      else
        min_free_mb="$def_min_free_mb"
      fi
      break
    fi
    min_free_mb="$v"
    break
  done

  # ── 6c. How many DB dumps to mirror ─────────────────────────────────────────
  # Immich rotates the dumps it keeps in UPLOAD_LOCATION/backups; this tool
  # rotates its own copies on the external storage. The two counts are
  # independent, and Immich's is read from its database and offered as the
  # suggested default.
  local immich_keep=""
  _db_reachable && immich_keep=$(db_immich_backup_keep_last)
  local def_retention="${BACKUP_RETENTION:-}"
  [[ "$def_retention" =~ ^[1-9][0-9]*$ ]] || def_retention="${immich_keep:-14}"
  local backup_retention="$def_retention" keep_note
  if [[ -n "$immich_keep" ]]; then
    keep_note="Immich currently keeps $immich_keep dump(s) of its own in $upload_location/backups."
  else
    keep_note="Immich's own retention could not be read (never changed from its default, or set through a config file), so 14 is suggested."
  fi
  while true; do
    ui_input "$(_wiz_title "DB dumps — how many to keep")" \
      "Immich dumps its database regularly; this tool copies those dumps to the external storage and keeps the newest ones there.\n\n${keep_note}\n\nKeeping at least as many as Immich does means a dump is never dropped from the external storage while Immich still has it locally.\n\nHow many dumps should be kept on the external storage?" \
      "$backup_retention" || { ui_info "Setup" "Cancelled — nothing was written and no jobs were scheduled."; return 0; }
    if [[ ! "$UI_VALUE" =~ ^[1-9][0-9]*$ ]]; then
      ui_info "Invalid value" "Enter a whole number of dumps to keep, 1 or more."
      continue
    fi
    backup_retention="$UI_VALUE"
    if [[ -n "$immich_keep" ]] && (( backup_retention < immich_keep )); then
      if ui_yesno "Fewer than Immich keeps" \
           "Keeping $backup_retention dump(s) while Immich keeps $immich_keep means the oldest are deleted from the external storage even though Immich still holds them locally — so those dumps exist in one place only.\n\nKeep $backup_retention anyway, or match Immich?" \
           no "Keep $backup_retention" "Match Immich ($immich_keep)"; then
        break
      fi
      backup_retention="$immich_keep"
    fi
    break
  done

  # ── 7. User → folder mapping (auto-suggested) ───────────────────────────────
  declare -A new_user_map=()
  declare -A user_name_by_key=()
  local -a user_paths=()
  local users_raw=""
  if _db_reachable; then
    # A mute database costs the pre-filled folder suggestions, not the wizard.
    users_raw=$(db_get_users 2>/dev/null || true)
  fi

  # A folder suggestion per user, taken from a library Immich already points under
  # ARCHIVE_CONTAINER_PATH: import path "/external_library/Alice" → folder
  # "Alice". Keyed as USER_MAP is, on storageLabel and otherwise on ownerId. The
  # first matching path wins, and a library with no import path is ignored.
  declare -A prefill_folder=()
  # Every folder that user already has a library for, newline-separated, not just
  # the one suggested: a user may own several libraries, and the report at the end
  # has to know whether the folder actually chosen is among them. Folder names come
  # from _sanitize_folder, so they never contain a newline.
  declare -A prefill_all=()
  if _db_reachable; then
    local libs_raw lrow l_owner l_label l_path l_key l_rel
    libs_raw=$(db_get_external_libraries 2>/dev/null || true)
    if [[ -n "$libs_raw" ]]; then
      local -a _libs=()
      mapfile -t _libs <<< "$libs_raw"
      for lrow in "${_libs[@]}"; do
        [[ -z "$lrow" ]] && continue
        IFS="$DB_FIELD_SEP" read -r l_owner l_label l_path <<< "$lrow"
        [[ -z "$l_path" ]] && continue
        [[ "$l_path" != "${archive_container_path%/}"/* ]] && continue
        l_key="${l_label:-$l_owner}"
        l_rel=$(_sanitize_folder "${l_path#"${archive_container_path%/}"/}")
        [[ -z "$l_rel" ]] && continue
        prefill_all["$l_key"]="${prefill_all["$l_key"]:-}${l_rel}"$'\n'
        [[ -n "${prefill_folder["$l_key"]:-}" ]] && continue
        prefill_folder["$l_key"]="$l_rel"
      done
    fi
  fi
  if [[ -n "$users_raw" ]]; then
    # The rows go into an array first: a `while read … done <<< "$users_raw"`
    # loop would redirect the whole body's stdin to the here-string, and the
    # ui_input prompt below would read EOF instead of the user's answer.
    local -a _users=()
    mapfile -t _users <<< "$users_raw"
    # The folders already on the external library, shown in each prompt.
    local lib_tree tree_note=""
    lib_tree=$(_ext_library_tree "$archive_dest")
    [[ -n "$lib_tree" ]] && tree_note="\n\nFolders currently on the external library:\n${lib_tree}"
    local row uid name storage_label
    for row in "${_users[@]}"; do
      [[ -z "$row" ]] && continue
      IFS="$DB_FIELD_SEP" read -r uid name storage_label <<< "$row"
      [[ -z "$uid" ]] && continue
      local key="${storage_label:-$uid}"
      user_name_by_key["$key"]="$name"
      local current_mapped="${USER_MAP["$key"]:-}"
      local detected="${prefill_folder["$key"]:-}"
      # The pre-filled answer, in order of preference: this config's own choice,
      # a folder detected from the user's Immich library, then the user's name —
      # not the storageLabel, which is often an opaque UUID.
      local default_folder="${current_mapped:-${detected:-$name}}"
      local detected_note=""
      [[ -z "$current_mapped" && -n "$detected" ]] \
        && detected_note="\n\nDetected from this user's Immich external library: ${archive_container_path%/}/$detected"
      local folder_answer=""
      while true; do
        ui_input "$(_wiz_title "Folder for $name")" \
          "Sub-folder name on the external library for this user's archived photos.\n\nUser        : $name\nstorageLabel: ${storage_label:-<empty>}${detected_note}${tree_note}" \
          "$default_folder" || { ui_info "Setup" "Cancelled — nothing was written and no jobs were scheduled."; return 0; }
        folder_answer=$(_sanitize_folder "$UI_VALUE")
        if [[ -z "$folder_answer" ]]; then
          # An empty folder would archive into the root of the external library,
          # leaving no per-user path to register in Immich.
          ui_info "Folder required" "Enter a sub-folder name for $name's archived photos — it cannot be empty."
          continue
        fi
        # Two users sharing one folder merge their libraries into it, where one
        # relative path names two different photos. Refused here, as it is in
        # _config_check.
        local clash="" taken_key
        if [[ -n "${new_user_map[*]+x}" ]]; then
          for taken_key in "${!new_user_map[@]}"; do
            [[ "${new_user_map[$taken_key]}" == "$folder_answer" ]] || continue
            clash="${user_name_by_key[$taken_key]:-$taken_key}"
            break
          done
        fi
        if [[ -n "$clash" ]]; then
          ui_info "Folder already taken" "'$folder_answer' is already the archive folder for $clash.\n\nTwo users cannot share one folder: their photos would land on the same paths, and one would overwrite the other.\n\nChoose a different folder for $name."
          continue
        fi
        break
      done
      new_user_map["$key"]="$folder_answer"
      # The line the summary shows: the user's name and the real archive path,
      # rather than the storageLabel key.
      user_paths+=("  $name : ${archive_dest%/}/$folder_answer")
    done
  fi

  # The log settings are never prompted for: an existing config's values, or
  # these defaults.
  local log_dir="${LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper}"
  local log_max_lines="${LOG_MAX_LINES:-1000}"

  # Schema and path-consistency checks, neither of which blocks the wizard. Only
  # a real mismatch is reported: a mute database says nothing about the schema.
  if _db_reachable; then
    local wiz_schema_state=0
    db_check_schema 2>/dev/null || wiz_schema_state=$?
    if (( wiz_schema_state == 1 )); then
      ui_info "Schema check" "WARNING: Schema check failed — the Immich DB schema may have changed.\n\nReview the script before using it against this Immich version."
    fi
    if archive_dest_ready 2>/dev/null; then
      local consistency_report wiz_consistency_state=0
      consistency_report=$(db_check_path_consistency 2>/dev/null) || wiz_consistency_state=$?
      if (( wiz_consistency_state == 1 )); then
        ui_info "Path consistency" "NOTE: Immich DB path inconsistency detected:\n\n$(printf '%s\n' "$consistency_report" | sed 's/^/  - /')\n\nMake sure the external library path still matches the one configured in Immich."
      fi
    fi
  fi

  # ── 8. Summary & confirmation ───────────────────────────────────────────────
  local summary
  printf -v summary '%s\n' \
    "The script will be set up with these parameters." \
    "" \
    "Immich server      : $server_container" \
    "PostgreSQL         : $db_container ($db_name / $db_user)" \
    "Upload location    : $upload_location" \
    "Internal library   : $db_library_prefix" \
    "External library   : $archive_dest" \
    "  (container path)   $archive_container_path" \
    "Start archiving at : ▼ $(mb_to_human "$max_mb")" \
    "Archive down to    : ▲ $(mb_to_human "$target_mb")" \
    "Free-disk safety   : $(if (( min_free_mb > 0 )); then printf 'also archive if free disk < %s' "$(mb_to_human "$min_free_mb")"; else printf 'disabled'; fi)" \
    "DB dumps mirrored  : $backup_retention kept on the external storage"
  if (( ${#user_paths[@]} > 0 )); then
    summary+=$'\n'
    summary+="Where each user's photos are archived on the external library:"$'\n'
    local p
    for p in "${user_paths[@]}"; do
      summary+="$p"$'\n'
    done
  fi

  if ! ui_yesno "Confirm configuration" "$summary" yes "Validate config" "Cancel and quit"; then
    ui_info "Setup" "Cancelled — nothing was written and no jobs were scheduled."
    return 0
  fi

  # One USER_MAP.<key>=<folder> line per user, and no array declaration:
  # config.conf is read and not executed.
  local user_map_block="" k
  for k in "${!new_user_map[@]}"; do
    user_map_block+="USER_MAP.${k}=${new_user_map[$k]}"$'\n'
  done

  # Written to a temporary file and renamed into place, so an interruption
  # mid-write cannot leave a truncated configuration behind.
  cat > "$CONFIG_FILE.tmp" <<CONF
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

# Also archive (down to TARGET) if total free disk space drops below this,
# regardless of library size — a safety net against other processes filling
# the disk. 0 = disabled.
ARCHIVE_MIN_FREE_MB=${min_free_mb}

# --- DB backup ---
BACKUP_RETENTION=${backup_retention}

# --- User → external folder mapping ---
${user_map_block}
# --- Logs ---
LOG_DIR="${log_dir}"
LOG_MAX_LINES=${log_max_lines}
CONF
  if ! mv -f -- "$CONFIG_FILE.tmp" "$CONFIG_FILE"; then
    rm -f -- "$CONFIG_FILE.tmp"
    ui_info "config.conf NOT written" "Could not put the new configuration in place at ${CONFIG_FILE}.\n\nNothing was changed: your previous configuration is untouched."
    return 1
  fi

  # An Immich external library can only point at a path that already exists, so
  # each user's destination folder is created here. Immich's own configuration is
  # never touched: a user with no library pointed under the archive path gets
  # instructions in the report below.
  local -a fld_created=() fld_existed=() fld_failed=() immich_todo=()
  local k folder host_dir uname cpath
  for k in "${!new_user_map[@]}"; do
    folder="${new_user_map[$k]}"
    [[ -z "$folder" ]] && continue
    uname="${user_name_by_key[$k]:-$k}"
    cpath="${archive_container_path%/}/$folder"
    host_dir="${archive_dest%/}/$folder"
    if [[ ! -d "$archive_dest" ]]; then
      fld_failed+=("$host_dir")
    elif [[ -d "$host_dir" ]]; then
      fld_existed+=("$folder")
    elif mkdir -p "$host_dir" 2>/dev/null; then
      fld_created+=("$folder")
    else
      fld_failed+=("$host_dir")
    fi
    # No library detected pointing at THIS folder: it has to be added in Immich.
    # Asking only whether the user has some library under the archive path would
    # pass a user who was offered one folder and typed another, and the run that
    # followed would park every one of their assets.
    [[ $'\n'"${prefill_all[$k]:-}" != *$'\n'"$folder"$'\n'* ]] \
      && immich_todo+=("$uname  →  $cpath")
  done

  _cron_review

  # On plain stdout, so it survives the whiptail screen and leaves the user a
  # record of the outcome and of any Immich step still to take.
  printf '\n========================================\n'
  printf 'immich-auto-dumper setup: SUCCESS\n'
  printf '========================================\n'
  printf 'Config written : %s\n' "$CONFIG_FILE"
  printf 'Scheduled jobs : %s\n' "$(_cron_state_label)"
  (( ${#fld_created[@]} > 0 )) && printf 'Folders created : %s\n' "${fld_created[*]}"
  (( ${#fld_existed[@]} > 0 )) && printf 'Folders present : %s\n' "${fld_existed[*]}"
  if (( ${#fld_failed[@]} > 0 )); then
    printf 'WARNING — could not create (make them manually, then re-run setup):\n'
    local f; for f in "${fld_failed[@]}"; do printf '  - %s\n' "$f"; done
  fi
  if (( ${#immich_todo[@]} > 0 )); then
    printf '\nACTION REQUIRED in Immich (Administration → Libraries):\n'
    printf 'These users have no external library pointed at the folder chosen for them.\n'
    printf 'For each, add an External Library with the import path below and assign the owner\n'
    printf '(until then, Immich will not display the archived photos):\n'
    local t; for t in "${immich_todo[@]}"; do printf '  - %s\n' "$t"; done
  else
    printf '\nAll users already have an external library pointed at the folder chosen for them.\n'
  fi
  printf '========================================\n\n'
}

# ── status ────────────────────────────────────────────────────────────────────

# Reports the state of everything the tool depends on and of what it last did.
# Writes nothing, and always prints every line, including when a check could not
# be made.
_status() {
  echo "=== immich-auto-dumper status ==="

  local library_path="${IMMICH_UPLOAD_LOCATION:-}/library"
  if [[ -d "$library_path" ]]; then
    local lib_bytes disk_total disk_free
    lib_bytes=$(dir_size_bytes "$library_path")
    disk_total=$(disk_total_bytes "${IMMICH_UPLOAD_LOCATION}")
    disk_free=$(disk_free_bytes "${IMMICH_UPLOAD_LOCATION}")
    # In MiB, with the deprecated *_GB keys honoured.
    local s_max_mb="${ARCHIVE_LIBRARY_MAX_MB:-}" s_target_mb="${ARCHIVE_LIBRARY_TARGET_MB:-}"
    [[ -z "$s_max_mb"    && -n "${ARCHIVE_LIBRARY_MAX_GB:-}"    ]] && s_max_mb=$(( ARCHIVE_LIBRARY_MAX_GB * 1024 ))
    [[ -z "$s_target_mb" && -n "${ARCHIVE_LIBRARY_TARGET_GB:-}" ]] && s_target_mb=$(( ARCHIVE_LIBRARY_TARGET_GB * 1024 ))
    printf 'Library size         : %s  (archives above %s, down to %s)\n' \
      "$(bytes_to_human "$lib_bytes")" \
      "${s_max_mb:+$(mb_to_human "$s_max_mb")}" "${s_target_mb:+$(mb_to_human "$s_target_mb")}"
    printf 'Total free disk space: %s free of %s total\n' \
      "$(bytes_to_human "${disk_free:-0}")" "$(bytes_to_human "${disk_total:-0}")"

    local s_min_free_mb="${ARCHIVE_MIN_FREE_MB:-0}"
    if (( s_min_free_mb > 0 )); then
      printf 'Free-disk safety net : archives if free disk < %s (currently %s free)\n' \
        "$(mb_to_human "$s_min_free_mb")" "$(bytes_to_human "${disk_free:-0}")"
    fi

    # The same ceiling setup validates MAX against, re-checked here: unrelated
    # data on the disk erodes it over time.
    if (( disk_total > 0 && s_max_mb > 0 )) && (( disk_free + lib_bytes < s_max_mb * 1048576 )); then
      if (( s_min_free_mb > 0 )); then
        printf 'WARNING              : library cannot reach its %s max before the disk fills — relying on the free-disk safety net above.\n' \
          "$(mb_to_human "$s_max_mb")"
      else
        printf 'WARNING              : library cannot reach its %s max before the disk fills, and no free-disk safety net is configured — automatic archiving may never trigger. Run: immich-auto-dumper setup\n' \
          "$(mb_to_human "$s_max_mb")"
      fi
    fi
  else
    printf 'Library size         : unavailable (%s not found)\n' "$library_path"
  fi

  local storage_ready=false storage_state=0
  archive_dest_ready 2>/dev/null || storage_state=$?
  case $storage_state in
    0) storage_ready=true
       printf 'External storage     : ready  (%s)\n' "${ARCHIVE_DEST_PATH:-?}" ;;
    1) printf 'External storage     : NOT READY  (%s) — %s\n' "${ARCHIVE_DEST_PATH:-?}" "$_ARCHIVE_DEST_REASON" ;;
    *) printf 'External storage     : UNVERIFIABLE  (%s) — %s\n' "${ARCHIVE_DEST_PATH:-?}" "$_ARCHIVE_DEST_REASON" ;;
  esac

  # Schema and path consistency against Immich's database.
  local schema_state=0
  if ! probe_docker_cmd 2>/dev/null; then
    printf 'Schema check         : not verified (Docker unreachable)\n'
  elif ! _db_reachable; then
    printf 'Schema check         : not verified (Immich database unreachable — is %s running?)\n' "${IMMICH_DB_CONTAINER:-the DB container}"
  else
    db_check_schema >/dev/null 2>&1 || schema_state=$?
    case $schema_state in
      0) printf 'Schema check         : OK\n' ;;
      1) printf 'Schema check         : FAILED — Immich DB schema may have changed, review the script\n' ;;
      *) printf 'Schema check         : not verified (the database stopped answering mid-check)\n' ;;
    esac
  fi

  if ! probe_docker_cmd 2>/dev/null; then
    printf 'Path consistency     : not verified (Docker unreachable)\n'
  elif ! "$storage_ready"; then
    # The offline-asset signal means nothing while the files are unreachable.
    printf 'Path consistency     : not verified (external storage not reachable)\n'
  else
    local consistency_state=0
    db_check_path_consistency >/dev/null 2>&1 || consistency_state=$?
    case $consistency_state in
      0) printf 'Path consistency     : OK\n' ;;
      1) printf 'Path consistency     : INCONSISTENT — fix the path in Immich, then run setup\n' ;;
      *) printf 'Path consistency     : not verified (Immich database unreachable)\n' ;;
    esac
  fi

  local backup_dir="${ARCHIVE_DEST_PATH:-}/.immich-backup"
  if [[ -d "$backup_dir" ]]; then
    local n
    n=$(find "$backup_dir" -maxdepth 1 -type f | wc -l)
    printf 'DB backups           : %s file(s) in .immich-backup/\n' "$n"
  else
    printf 'DB backups           : .immich-backup/ directory absent\n'
  fi

  # "disabled" and "not installed" are reported apart: they need different
  # actions from the user.
  case "$(cron_state)" in
    active)   printf 'Cron jobs            : active\n' ;;
    disabled) printf 'Cron jobs            : disabled (entries commented out — run "immich-auto-dumper start" to re-enable)\n' ;;
    *)        printf 'Cron jobs            : not installed (run "immich-auto-dumper start")\n' ;;
  esac

  local log_file="${LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper}/immich-auto-dumper.log"
  if [[ -f "$log_file" ]]; then
    local last_archive last_backup
    last_archive=$(grep 'Archive complete' "$log_file" | tail -1 || true)
    last_backup=$(grep 'DB backup:' "$log_file" | tail -1 || true)

    if [[ -n "$last_archive" ]]; then
      local ts detail
      # `|| true`: under pipefail a grep matching nothing would fail the
      # assignment and abort status over a cosmetic detail.
      ts=$(printf '%s' "$last_archive" | grep -oP '(?<=\[)[^\]]+' | head -1 || true)
      detail=$(printf '%s' "$last_archive" | sed 's/.*Archive complete\. //')
      printf 'Last archive         : %s — %s\n' "$ts" "$detail"
    else
      printf 'Last archive         : none\n'
    fi

    if [[ -n "$last_backup" ]]; then
      local ts2 detail2
      ts2=$(printf '%s' "$last_backup" | grep -oP '(?<=\[)[^\]]+' | head -1 || true)
      detail2=$(printf '%s' "$last_backup" | sed 's/.*DB backup: //')
      printf 'Last DB backup       : %s — %s\n' "$ts2" "$detail2"
    else
      printf 'Last DB backup       : none\n'
    fi
  else
    printf 'Last archive         : log file absent\n'
    printf 'Last DB backup       : log file absent\n'
  fi

  local lock_info
  lock_info=$(lock_state)
  case "${lock_info%% *}" in
    active) printf 'Lock                 : active (PID %s)\n' "${lock_info#* }" ;;
    stale)  printf 'Lock                 : stale (PID %s dead)\n' "${lock_info#* }" ;;
    *)      printf 'Lock                 : inactive\n' ;;
  esac

  # Unfinished work, without opening a file: whether a run did not complete,
  # since when, how much is waiting and how much is stuck.
  local rl_pending rl_blocked rl_divergent rl_unreadable rl_files rl_oldest
  read -r rl_pending rl_blocked rl_divergent rl_unreadable rl_files rl_oldest < <(runlog_summary)
  if (( rl_files == 0 )); then
    printf 'Unfinished runs      : none\n'
  else
    local since=""
    local oldest_path
    oldest_path="$(runlog_dir)/$rl_oldest"
    [[ -f "$oldest_path" ]] && since=$(date -r "$oldest_path" '+%Y-%m-%d %H:%M' 2>/dev/null || true)
    printf 'Unfinished runs      : %d (oldest: %s%s)\n' \
      "$rl_files" "${rl_oldest%.*}" "${since:+, since $since}"
    printf '                       %d entry(ies) to resume, %d blocked, %d divergent' \
      "$rl_pending" "$rl_blocked" "$rl_divergent"
    (( rl_unreadable > 0 )) && printf ', %d unreadable' "$rl_unreadable"
    printf '\n'
    if (( rl_blocked > 0 || rl_divergent > 0 )); then
      printf '                       Details in %s — blocked and divergent entries need a decision.\n' "$(runlog_dir)"
      printf '                       Their assets stay untouched until you resolve the cause and delete that run file.\n'
    fi
  fi
}

# ── start ─────────────────────────────────────────────────────────────────────

# Installs the schedule: re-enables the entries a previous `stop` commented out,
# then appends any that are still missing.
_start() {
  local rendered logdir
  if ! rendered=$(_render_cron_lines) || [[ -z "$rendered" ]]; then
    printf 'crontab.example not found or empty: %s\n' "$SCRIPT_DIR/cron/crontab.example" >&2
    return 1
  fi
  logdir="${LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper}"
  mkdir -p "$logdir" 2>/dev/null || true

  # The un-comment step, symmetric to disable_cron: without it, a commented line
  # would match the substring check below and `start` after `stop` would do
  # nothing. Only a line whose payload looks like a cron schedule is touched, so
  # a user's own comment naming the tool is never turned into a crontab line.
  local current
  current=$(crontab -l 2>/dev/null | sed 's|^#\([0-9*@].*immich-auto-dumper.*\)|\1|' || true)

  local new_entries="" line
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

# Comments the schedule out and waits, for up to a minute, on any operation
# already running.
_stop() {
  # disable_cron reports on live schedules alone, so the two "nothing to do"
  # cases are told apart here.
  if disable_cron; then
    echo "Cron jobs disabled."
  elif [[ "$(cron_state)" == "disabled" ]]; then
    echo "Cron jobs were already disabled."
  else
    echo "No immich-auto-dumper entries in crontab."
  fi

  local lock_info
  lock_info=$(lock_state)
  if [[ "${lock_info%% *}" == "active" ]]; then
    local pid="${lock_info#* }"
    echo "Operation in progress (PID $pid), waiting (max 60s)..."
    local elapsed=0
    while [[ "$(lock_state)" == "active $pid" ]] && (( elapsed < 60 )); do
      sleep 2
      elapsed=$(( elapsed + 2 ))
    done
    if [[ "$(lock_state)" == "active $pid" ]]; then
      echo "Warning: operation still running after 60s." >&2
    else
      echo "Operation finished."
    fi
  fi
}

# ── Entry point ───────────────────────────────────────────────────────────────

# Parses the flags and the command, refuses to run any command but setup and
# uninstall without a readable config, then dispatches.
main() {
  local dry_run=false
  local force=false
  local cmd=""
  local args=()
  local arg

  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=true ;;
      --force)   force=true ;;
      # Belongs to `uninstall`, which hands it straight to uninstall.sh. Named
      # here so the guard below does not reject it.
      -y|--yes)  args+=("$arg") ;;
      # Any other unrecognised flag stops the run: a misspelled safety flag must
      # never be collected as an argument and ignored.
      -*)
        printf 'Unknown option: %s\n\n' "$arg" >&2
        _usage >&2
        exit 1
        ;;
      *)         args+=("$arg") ;;
    esac
  done

  cmd="${args[0]:-}"

  # setup creates the config, and uninstall works without one, so both stay
  # reachable when a configuration is missing or unreadable. Every other command
  # refuses rather than act on half a configuration.
  if [[ "$cmd" != "setup" && "$cmd" != "uninstall" && -n "$cmd" ]]; then
    _require_config
    if ! "$CONFIG_LOADED"; then
      printf 'Error: config.conf could not be read (see the errors above).\n' >&2
      printf 'Fix those lines, or run: immich-auto-dumper setup\n' >&2
      exit 1
    fi
  fi

  local dry_flag=()
  "$dry_run" && dry_flag=(--dry-run)
  local force_flag=()
  "$force" && force_flag=(--force)

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
      # Threshold-based without --force, and ignoring MAX with it.
      archive_run "${dry_flag[@]}" "${force_flag[@]}"
      ;;
    sync_now)
      backup_db_run "${dry_flag[@]}"
      ;;
    test_run)
      # A forced dump and a dump-sync, both simulated. Forced, so candidates are
      # listed even with the library below MAX, and both halves run whatever the
      # other returns, so neither can hide the other's preview.
      archive_run --force --dry-run || true
      backup_db_run --dry-run || true
      ;;
    rollback)
      # --force has no meaning here: a rollback undoes one run exactly as its
      # journal recorded it, with nothing to override. Refused rather than
      # accepted and dropped, which is the defect --dry-run had.
      if "$force"; then
        printf 'Error: rollback has no --force. It undoes one identified run, as recorded.\n\n' >&2
        _usage >&2
        exit 1
      fi
      # Everything after the command is handed over, not just the first word: a
      # second run id must reach the refusal in archive_rollback rather than be
      # dropped here, which is the same mistake as dropping the flag.
      archive_rollback "${dry_flag[@]}" "${args[@]:1}"
      ;;
    uninstall)
      # Handed to the standalone uninstaller, which relocates itself before
      # deleting the install directory, with any -y/--yes passed through.
      exec bash "$SCRIPT_DIR/uninstall.sh" "${args[@]:1}"
      ;;
    *)
      _usage
      [[ -z "$cmd" ]] && exit 0 || exit 1
      ;;
  esac
}

main "$@"
