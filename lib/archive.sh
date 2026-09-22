#!/usr/bin/env bash
# shellcheck disable=SC2034  # RUNLOG_DIRECTION and the ARCHIVE_* globals are
# read from the other files sourced at runtime
set -euo pipefail

# ── Path conversion helpers ───────────────────────────────────────────────────

# Converts a DB path (container-absolute, under IMMICH_DB_LIBRARY_PREFIX) to host path.
db_path_to_host_path() {
  local db_path="$1"
  printf '%s\n' "${db_path/#"$IMMICH_DB_LIBRARY_PREFIX"/"$IMMICH_UPLOAD_LOCATION/library"}"
}

# Converts a host library path to its DB path (container-absolute).
host_path_to_db_path() {
  local host_path="$1"
  printf '%s\n' "${host_path/#"$IMMICH_UPLOAD_LOCATION/library"/"$IMMICH_DB_LIBRARY_PREFIX"}"
}

# ── Destination path builder ──────────────────────────────────────────────────

# Builds the archive destination host path for a host source path, keeping the
# whole subpath after <user folder>/ whatever the storage template's depth.
#
# Returns 1 and echoes NOTHING unless the source has the form
# <upload location>/library/<user folder>/<rest>, with both parts non-empty.
archive_build_dest_path() {
  local src_host_path="$1"
  local library_prefix="$IMMICH_UPLOAD_LOCATION/library/"

  [[ "$src_host_path" == "$library_prefix"* ]] || return 1
  local relative="${src_host_path#"$library_prefix"}"
  local user_folder="${relative%%/*}"
  local rest="${relative#"$user_folder/"}"
  # `rest == relative` means the strip found no "<folder>/" to remove: the path
  # names a file sitting directly in library/, under no user folder.
  [[ -n "$user_folder" && -n "$rest" && "$rest" != "$relative" ]] || return 1

  local mapped_name="${USER_MAP["$user_folder"]:-$user_folder}"

  printf '%s/%s/%s\n' "$ARCHIVE_DEST_PATH" "$mapped_name" "$rest"
}

# Assets an unfinished run journal still owns. Filled by archive_reconcile and
# read by the candidate loop, which leaves them alone.
declare -A ARCHIVE_IN_FLIGHT=()

# Bytes the last move actually took off the library disk, read off the
# filesystem. An output of _archive_move_file, summed by the candidate loop after
# every asset, and reset at each of its entry points so that a failed move never
# reports the previous asset's figure.
ARCHIVE_LAST_FREED_BYTES=0

# How many entries THIS run put into a state that needs a person: `bloque` and
# `divergent`, and only those — `abandonne` means the asset left Immich, which is
# its owner's decision. Counted as written during the run and not as found in
# runs/, so the non-zero exit falls on the run that produced the problem.
ARCHIVE_TERMINAL_COUNT=0

# ── Primitives shared by both directions ──────────────────────────────────────
#
# Archiving and rolling back write on different sides. On the way out, `cp -p` on
# the host: the external storage belongs to the invoking user. On the way back
# the target is inside the library, which belongs to the container's user, so the
# write goes through `docker exec`.
#
# The discipline is the same in both directions and lives here, in one place:
# write, push it out of the cache, read it back, compare it against the
# fingerprint taken before anything moved, and only then let the caller remove
# the other copy — plus a refusal to overwrite an occupied path.

# Writes <src> to <dst>, on the side named by <side>, and proves the result
# carries <expected_sha> before returning 0. The copy is read back through the
# side it was written on, so a container-side write is also proved visible to
# Immich. Leaves nothing behind on failure: 0 written and verified, 1 otherwise.
_transfer_and_verify() {
  local side="$1" src="$2" dst="$3" expected_sha="$4"
  local back=""

  case "$side" in
    host)
      if ! cp -p -- "$src" "$dst"; then
        log_error "Copy failed: $src → $dst"
        rm -f -- "$dst"
        return 1
      fi
      # Flushed before it is verified, so the fingerprint is taken of what is on
      # the storage and not of what is still in memory.
      file_flush "$dst"
      back=$(file_fingerprint "$dst") || back=""
      ;;
    container)
      if ! $DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" \
             mkdir -p "$(dirname "$dst")" </dev/null; then
        log_error "Could not create the folder inside the container: $(dirname "$dst")"
        return 1
      fi
      if ! $DOCKER_CMD exec -i "$IMMICH_SERVER_CONTAINER" \
             sh -c 'cat > "$1"' _ "$dst" < "$src"; then
        log_error "Could not write the file inside the container: $dst"
        $DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" rm -f "$dst" </dev/null || true
        return 1
      fi
      # `cat` piped to the host's sha256sum: only cat is assumed to exist in the
      # Immich image.
      back=$($DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" cat -- "$dst" </dev/null \
             | sha256sum | cut -d' ' -f1) || back=""
      ;;
    *)
      log_error "Internal error: unknown transfer side '$side'."
      return 1 ;;
  esac

  if [[ "$back" != "$expected_sha" ]]; then
    log_error "What was written does not match the recorded fingerprint: $dst"
    # The partial file goes, on whichever side it was written. The other copy is
    # still in place, so nothing is lost.
    case "$side" in
      host)      rm -f -- "$dst" ;;
      container) $DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" rm -f "$dst" </dev/null || true ;;
    esac
    log_error "The incomplete file was removed; the other copy is still in place."
    return 1
  fi
  return 0
}

# Says what is already sitting at <path>, against the fingerprint expected there:
#   0  nothing there — go ahead and write
#   1  already there and identical — no need to write, and nothing to refuse
#   2  already there and DIFFERENT, or impossible to compare — refuse
#
# Only a matching fingerprint earns the 1, which is what lets a caller skip the
# copy, point the database at that file and delete the other copy.
_refuse_if_occupied() {
  local path="$1" expected_sha="$2"
  [[ -e "$path" ]] || return 0
  local current
  current=$(file_fingerprint "$path") || return 2
  [[ "$current" == "$expected_sha" ]] && return 1
  return 2
}

# ── Per-asset pipeline, journalled and resumable ──────────────────────────────

# Where Immich currently says the asset is, read against what the journal
# expects. Echoes one of:
#   absent       the asset is gone, or in the trash — the user has decided
#   source       still at the recorded source
#   destination  already at the recorded destination
#   divergent    somewhere else entirely (template migration, dump restore…)
#   inconnu      the database did not answer
_archive_db_position() {
  local asset_id="$1" src_db="$2" dst_db="$3"
  local row rc=0
  row=$(db_asset_position "$asset_id") || rc=$?
  if (( rc != 0 )); then printf 'inconnu'; return 0; fi
  if [[ -z "$row" ]]; then printf 'absent'; return 0; fi
  local deleted="${row%% *}" path="${row#* }"
  if [[ "$deleted" == "trashed" ]]; then printf 'absent'; return 0; fi
  case "$path" in
    "$src_db") printf 'source' ;;
    "$dst_db") printf 'destination' ;;
    *)         printf 'divergent' ;;
  esac
}

# Removes the source through the container, which owns the library files.
# Refuses unless the file still carries the fingerprint recorded before the copy.
# 0 removed, or already gone; 1 refused or failed.
_archive_remove_source() {
  local src_host="$1" src_db="$2" sha="$3"

  if [[ ! -e "$src_host" ]]; then
    return 0
  fi
  local current
  if ! current=$(file_fingerprint "$src_host"); then
    log_error "Cannot fingerprint the source before removing it: $src_host — kept."
    return 1
  fi
  if [[ "$current" != "$sha" ]]; then
    log_error "The source changed since it was copied: $src_host — kept, nothing removed."
    return 1
  fi
  if ! $DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" rm -f "$src_db" </dev/null; then
    log_warn "Archived OK but could not remove the source in the container: $src_db"
    return 1
  fi
  return 0
}

# Points the database back at the source after a step failed past the update.
# 0 the database is back on the source, 1 it is not.
_archive_restore_db() {
  local update_fn="$1" asset_id="$2" src_db="$3"
  "$update_fn" "$asset_id" "$src_db" >/dev/null 2>&1
}

# Drives one asset from wherever the journal left it to source_supprimee.
# Every transition is written down BEFORE the act it describes.
#   0  the asset is archived
#   1  skipped, to be retried by a later run
#   2  terminal: recorded as bloque, divergent or abandonne
_archive_process_asset() {
  local asset_id="$1" src_host="$2" dst_host="$3" src_db="$4" dst_db="$5"
  local sha="$6" size="$7" state="$8" attempts="$9" update_fn="${10}"

  # Zero until a source is really deleted.
  ARCHIVE_LAST_FREED_BYTES=0

  local try=$(( attempts + 1 ))
  # Records the entry in the state it has reached and echoes this function's
  # return code for it. An entry that has used up its tries becomes `bloque`.
  # Nested, so that bash's dynamic scoping gives it the caller's locals rather
  # than ten arguments that would only ever be those.
  _park() {
    local etat="$1"
    if [[ "$etat" != "divergent" && "$etat" != "abandonne" ]] && (( try >= RUNLOG_MAX_ATTEMPTS )); then
      log_error "Asset $asset_id has failed $try times — parked as blocked, it will not be retried."
      # `|| true`: runlog_record reports its own failure, and nothing follows
      # this record that its absence could authorise.
      runlog_record "" "$asset_id" bloque "$try" "$size" "$sha" "$src_host" "$src_db" "$dst_host" "$dst_db" || true
      ARCHIVE_TERMINAL_COUNT=$(( ARCHIVE_TERMINAL_COUNT + 1 ))
      return 2
    fi
    runlog_record "" "$asset_id" "$etat" "$try" "$size" "$sha" "$src_host" "$src_db" "$dst_host" "$dst_db" || true
    case "$etat" in
      divergent) ARCHIVE_TERMINAL_COUNT=$(( ARCHIVE_TERMINAL_COUNT + 1 )); return 2 ;;
      abandonne) return 2 ;;
      *) return 1 ;;
    esac
  }

  # On a resumed entry, the database is asked again and has to agree with the
  # journal before anything irreversible happens.
  if [[ -n "$state" ]]; then
    local position
    position=$(_archive_db_position "$asset_id" "$src_db" "$dst_db")
    case "$position" in
      absent)
        log_warn "Asset $asset_id is gone from Immich (deleted or in the trash) — abandoned, nothing to resume."
        _park abandonne; return $? ;;
      divergent)
        log_error "Asset $asset_id now points somewhere else in Immich — left untouched and flagged."
        log_error "A storage-template migration or a restored dump does that. Resolve it by hand."
        _park divergent; return $? ;;
      inconnu)
        log_error "Could not read the state of asset $asset_id in Immich — skipped, nothing touched."
        _park "$state"; return $? ;;
      destination)
        # The update went through, so only the source removal can be left.
        [[ "$state" == "prevu" || "$state" == "copie" ]] && state="base_a_jour" ;;
      source)
        # The database points at the source, so any later step was undone.
        [[ "$state" == "base_a_jour" ]] && state="copie" ;;
    esac
  fi

  # Each of the three transitions below is written down BEFORE the act it
  # describes, and a record that cannot be written stops that act. Those cases
  # return 1 instead of parking the entry: nothing was attempted, so the attempt
  # counter must not move.

  # ── → copie ─────────────────────────────────────────────────────────────────
  if [[ -z "$state" || "$state" == "prevu" ]]; then
    if ! runlog_record "" "$asset_id" prevu "$try" "$size" "$sha" "$src_host" "$src_db" "$dst_host" "$dst_db"; then
      log_error "Cannot write the run journal — asset $asset_id skipped, nothing touched."
      return 1
    fi

    # Not a bare call: _refuse_if_occupied answers 1 and 2 for cases handled
    # below, which under `set -e` would abort the run.
    local occupied=0
    _refuse_if_occupied "$dst_host" "$sha" || occupied=$?
    local need_copy=true
    case $occupied in
      0) ;;
      1) log_warn "Already at destination, identity verified: $dst_host — updating DB only."
         need_copy=false ;;
      *) log_error "Destination exists with DIFFERENT content, or cannot be read: $dst_host"
         log_error "Another file already occupies that path — asset skipped, source kept."
         log_error "Two users mapped to the same folder in USER_MAP is the usual cause."
         _park prevu; return $? ;;
    esac

    if "$need_copy"; then
      mkdir -p "$(dirname "$dst_host")" 2>/dev/null || true
      # The write, the flush, the read-back and the cleanup of a partial file all
      # live in _transfer_and_verify, whose `cp -p` keeps the timestamps.
      if ! _transfer_and_verify host "$src_host" "$dst_host" "$sha"; then
        _park prevu; return $?
      fi
    fi

    if ! runlog_record "" "$asset_id" copie "$try" "$size" "$sha" "$src_host" "$src_db" "$dst_host" "$dst_db"; then
      log_error "Cannot write the run journal — asset $asset_id skipped before the database update."
      log_error "The copy at $dst_host is left in place; the database still points at the source, so the asset is intact."
      return 1
    fi
    state="copie"
  fi

  # ── copie → base_a_jour ─────────────────────────────────────────────────────
  if [[ "$state" == "copie" ]]; then
    if ! "$update_fn" "$asset_id" "$dst_db"; then
      log_error "DB update failed (asset $asset_id): $dst_db"
      _park copie; return $?
    fi

    # Two conditions on the result, either of which undoes the update: the asset
    # is adopted by an external library, and the copy is visible from inside the
    # container.
    local fault=""
    if [[ "${DB_UPDATE_IS_EXTERNAL:-}" == "f" ]]; then
      fault="No external library in Immich covers $dst_db for this asset's owner (a library scan would re-import it as a duplicate). Create it in Immich: Administration → Libraries."
    elif ! $DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" test -f "$dst_db" </dev/null; then
      fault="The copy is not visible from inside the Immich container: $dst_db"
    fi

    if [[ -n "$fault" ]]; then
      log_error "$fault"
      if _archive_restore_db "$update_fn" "$asset_id" "$src_db"; then
        # Back where it started, so the copy serves no purpose.
        rm -f "$dst_host"
        log_error "Asset $asset_id left as it was; it will be retried on the next run."
        _park prevu; return $?
      fi
      # The restore failed, so the database still points at the copy and the copy
      # is KEPT: the asset has a file behind it, in a state that needs a person.
      log_error "Could not put the database back on the source for asset $asset_id."
      log_error "The copy at $dst_host is KEPT — the database points at it, so the asset is intact."
      log_error "Undo this run with: immich-auto-dumper rollback ${RUNLOG_ID:-<run-id>}"
      _park divergent; return $?
    fi

    if ! runlog_record "" "$asset_id" base_a_jour "$try" "$size" "$sha" "$src_host" "$src_db" "$dst_host" "$dst_db"; then
      log_error "Cannot write the run journal — asset $asset_id left with the database on the copy, source kept."
      log_error "The asset is intact and readable; the next run will finish removing the source."
      return 1
    fi
    state="base_a_jour"
  fi

  # ── base_a_jour → source_supprimee ──────────────────────────────────────────
  if [[ "$state" == "base_a_jour" ]]; then
    # What the library loses is what the filesystem says about the file about to
    # be deleted, measured now, while it is still there.
    local freed_now=0
    if [[ -e "$src_host" ]]; then
      freed_now=$(stat --format='%s' "$src_host" 2>/dev/null || echo 0)
    fi
    if ! _archive_remove_source "$src_host" "$src_db" "$sha"; then
      # The archive succeeded — the asset points at the copy and is readable —
      # and only the cleanup is outstanding, so the entry stays pending.
      _park base_a_jour; return $?
    fi
    ARCHIVE_LAST_FREED_BYTES="$freed_now"
    # The one record written after its act rather than before it, so its failure
    # is only a warning: the next run re-reads the database, finds the asset at
    # its destination and finishes cleanly.
    runlog_record "" "$asset_id" source_supprimee "$try" "$size" "$sha" "$src_host" "$src_db" "$dst_host" "$dst_db" || true
  fi

  return 0
}

# Moves one asset to the external storage and updates its DB path. Works out the
# destination and the fingerprint, then hands over to the journalled pipeline
# above — or, under <dry_run>, reports what that pipeline would do.
# Returns 0 archived, 1 skipped, 2 terminal failure.
_archive_move_file() {
  local asset_id="$1"
  local src_host_path="$2"
  local update_fn="$3"
  local dry_run="${4:-false}"

  # Reset here as well as in the pipeline below, which the early returns in this
  # function never reach.
  ARCHIVE_LAST_FREED_BYTES=0

  local dst_host
  if ! dst_host=$(archive_build_dest_path "$src_host_path"); then
    log_error "Asset $asset_id is not under $IMMICH_UPLOAD_LOCATION/library/<user folder>/ — skipped, nothing touched: $src_host_path"
    log_error "Only assets inside a user's folder of the internal library can be archived; there is no destination to build for this one."
    return 1
  fi
  local dst_db="${dst_host/#"$ARCHIVE_DEST_PATH"/"$ARCHIVE_CONTAINER_PATH"}"
  local src_db
  src_db=$(host_path_to_db_path "$src_host_path")

  if "$dry_run"; then
    # What a real run would take off the library disk, which the caller sums to
    # decide where the simulation stops.
    local would_free=0
    if [[ -e "$dst_host" ]]; then
      local identical=0
      files_are_identical "$src_host_path" "$dst_host" || identical=$?
      case $identical in
        0) log_info "DRY-RUN: would UPDATE DB only for asset $asset_id → $dst_db (identical copy already there)"
           # No copy to make, and the source still goes.
           would_free=$(stat --format='%s' "$src_host_path" 2>/dev/null || echo 0) ;;
        1) log_warn "DRY-RUN: destination already holds a DIFFERENT file — the real run would SKIP this asset: $dst_host" ;;
        *) log_warn "DRY-RUN: cannot compare source and destination — the real run would SKIP this asset: $dst_host" ;;
      esac
    else
      log_info "DRY-RUN: would copy $src_host_path → $dst_host"
      log_info "DRY-RUN: would UPDATE asset $asset_id originalPath → $dst_db"
      would_free=$(stat --format='%s' "$src_host_path" 2>/dev/null || echo 0)
    fi
    ARCHIVE_LAST_FREED_BYTES="$would_free"
    # `|| true`: on this preview path a mute database costs one advisory line,
    # never the listing of candidates.
    if [[ "$(db_asset_would_be_external "$asset_id" "$dst_db" || true)" == "f" ]]; then
      log_warn "DRY-RUN: no external library in Immich covers $dst_db for this asset's owner — the real run would SKIP this asset (Immich's library scan would otherwise re-import it as a duplicate). Create the external library first (see setup)."
    fi
    return 0
  fi

  # An asset whose paths cannot be journalled is refused, rather than moved on
  # the strength of a record a later run would have to guess at.
  if ! runlog_path_is_recordable "$src_host_path" "$dst_host" "$src_db" "$dst_db"; then
    log_error "Asset $asset_id has a path containing a line break — skipped, it cannot be journalled safely."
    return 1
  fi

  # Taken BEFORE anything moves: this fingerprint is what later authorises
  # deleting the source, and what a rollback checks the restored file against.
  local sha size
  if ! sha=$(file_fingerprint "$src_host_path"); then
    log_error "Cannot read the source to fingerprint it: $src_host_path — asset skipped."
    return 1
  fi
  size=$(stat --format='%s' "$src_host_path" 2>/dev/null || echo 0)

  _archive_process_asset "$asset_id" "$src_host_path" "$dst_host" "$src_db" "$dst_db" \
                         "$sha" "$size" "" 0 "$update_fn"
}

# ── Reconciliation ────────────────────────────────────────────────────────────

# Picks up what earlier runs left unfinished, driving each pending entry through
# the same pipeline as a fresh archive. Echoes nothing and logs what it does.
# Each old run file is appended to in place and then renamed, so one run's
# history stays in one file.
#
# Fills ARCHIVE_IN_FLIGHT with the assets the remaining unfinished journals still
# own, which the selection below leaves alone: a second entry for one asset would
# start its own attempt counter at one, and the ceiling that parks a hopeless
# asset would never bite.
archive_reconcile() {
  ARCHIVE_IN_FLIGHT=()
  local -a files=()
  local f
  while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(runlog_unfinished_files)
  (( ${#files[@]} > 0 )) || return 0

  log_info "Resuming unfinished work from ${#files[@]} earlier run(s)."

  local file previous asset etat attempts size sha src src_db dst dst_db rc
  local resumed=0 skipped=0 stuck=0
  previous="$RUNLOG_FILE"
  for file in "${files[@]}"; do
    # Retargeted, so each transition is appended to the file it belongs to.
    RUNLOG_FILE="$file"
    while IFS="$RUNLOG_SEP" read -r asset etat attempts size sha src src_db dst dst_db; do
      [[ -n "$asset" ]] || continue
      if [[ "$etat" == "illisible" ]]; then
        log_error "Entry for asset $asset in $(basename "$file") cannot be read — left alone, nothing touched."
        stuck=$(( stuck + 1 ))
        continue
      fi
      runlog_is_pending "$etat" || continue
      if (( attempts >= RUNLOG_MAX_ATTEMPTS )); then
        # Parked explicitly rather than stepped over, so the journal says the
        # entry has been given up on and status counts it as needing a decision.
        log_error "Asset $asset has failed $attempts times — parked as blocked, it will not be retried."
        runlog_record "" "$asset" bloque "$attempts" "$size" "$sha" "$src" "$src_db" "$dst" "$dst_db" || true
        ARCHIVE_TERMINAL_COUNT=$(( ARCHIVE_TERMINAL_COUNT + 1 ))
        stuck=$(( stuck + 1 ))
        continue
      fi
      rc=0
      _archive_process_asset "$asset" "$src" "$dst" "$src_db" "$dst_db" \
                             "$sha" "$size" "$etat" "$attempts" db_update_asset_path || rc=$?
      case $rc in
        0) # The sidecars go where their asset went. archive_run does this for a
           # fresh candidate; without it here, an asset finished by a resume ends
           # up external while its .xmp and .json stay in the library, and nothing
           # looks at them again — the entry is no longer pending, and the asset
           # is no longer a candidate. Safe after the source was removed: the
           # candidates are derived from the path, and only the sidecars
           # themselves are tested for existence. Never a dry run: reconciliation
           # is not reached at all when one is asked for.
           _archive_move_sidecar "$src" false || true
           resumed=$(( resumed + 1 )) ;;
        1) skipped=$(( skipped + 1 )) ;;
        *) stuck=$((   stuck   + 1 )) ;;
      esac
    done < <(runlog_read "$file")
    runlog_close "$file"
  done
  RUNLOG_FILE="$previous"

  # What is left, re-read after the renaming. An entry that did not complete
  # keeps its asset until a later run finishes it, or an operator resolves it and
  # removes the run file.
  local f2
  while IFS= read -r f2; do
    [[ -n "$f2" ]] || continue
    while IFS="$RUNLOG_SEP" read -r asset etat _; do
      [[ -n "$asset" ]] || continue
      case "$etat" in
        # `annule` among them: a rollback put that asset back in the library, so
        # it is an ordinary candidate again.
        source_supprimee|abandonne|annule) ;;
        *) ARCHIVE_IN_FLIGHT["$asset"]=1 ;;
      esac
    done < <(runlog_read "$f2")
  done < <(runlog_unfinished_files)

  log_info "Resume: $resumed completed, $skipped postponed to the next run, $stuck needing attention."
  return 0
}

# ── Rollback ──────────────────────────────────────────────────────────────────

# Puts a file back INTO the library, through the shared primitives and so under
# the same discipline as the way out. <src_host> is the library path seen from
# the host, used only to look at what is already there; the write goes through
# the container. 0 restored, or already correctly there; 1 refused or failed.
_archive_restore_file() {
  local dst_host="$1" src_host="$2" src_db="$3" expected_sha="$4"

  local occupied=0
  _refuse_if_occupied "$src_host" "$expected_sha" || occupied=$?
  case $occupied in
    0) ;;
    1) # Already back, and proved to be the right file.
       return 0 ;;
    *) log_error "A DIFFERENT file already occupies the library path, or it cannot be read: $src_db"
       log_error "Refused rather than overwritten — the archived copy is untouched."
       return 1 ;;
  esac

  _transfer_and_verify container "$dst_host" "$src_db" "$expected_sha"
}

# The sidecar candidates for an asset, derived from its path: "<path>.xmp",
# "<path>.json" and the same two with the extension stripped from the FILE NAME,
# not from the whole path. Echoed one per line and deduplicated, since for an
# asset with no extension the two forms name the same file.
_sidecar_candidates() {
  local path="$1"
  local folder base_name
  folder=$(dirname "$path")
  base_name=$(basename "$path")
  local base="$folder/${base_name%.*}"
  printf '%s\n' "${path}.xmp" "${path}.json" "${base}.xmp" "${base}.json" \
    | awk '!seen[$0]++'
}

# immich-auto-dumper rollback <run-id> [--dry-run] — undoes one identified
# archive run, and is never automatic.
#
# Every entry that completed is walked backwards: copy in, verify, point the
# database at the source, remove the external copy. Under the same guards as
# archiving, and any asset whose current state does not match what the journal
# says is refused and reported. Returns non-zero when anything was refused.
#
# --dry-run walks the same entries and runs the same three checks, which are all
# reads, and stops at the first write. So the preview answers the question that
# matters before an irreversible command: not what this run archived, but
# whether undoing it would be accepted today.
archive_rollback() {
  local dry_run=false run_id="" arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=true ;;
      # As in archive_run: an unrecognised flag ends the command rather than
      # being dropped, which is exactly how --dry-run used to be lost here.
      -*)
        log_error "Unknown argument for the rollback: '$arg' — nothing was done."
        return 1
        ;;
      *)
        if [[ -n "$run_id" ]]; then
          log_error "Only one run can be rolled back at a time ('$run_id' then '$arg') — nothing was done."
          return 1
        fi
        run_id="$arg"
        ;;
    esac
  done

  if [[ -z "$run_id" ]]; then
    log_error "Which run? Usage: immich-auto-dumper rollback <run-id>"
    log_error "Run ids are listed by: immich-auto-dumper status"
    return 1
  fi

  local file
  if ! file=$(runlog_resolve "$run_id"); then
    log_error "No single run journal matches '$run_id' in $(runlog_dir)."
    return 1
  fi

  check_prereqs

  local dest_state=0
  check_archive_dest_ready || dest_state=$?
  if (( dest_state != 0 )); then
    log_error "The external storage must be reachable to bring files back — rollback refused."
    return 1
  fi

  if ! acquire_lock; then
    return 1
  fi

  "$dry_run" && log_info "DRY-RUN: nothing will be restored, removed, or written to the DB."
  log_info "Rolling back $(basename "$file")."
  # The rollback keeps a journal of its own, leaving the original run's file as
  # the record of what that run did. A dry run opens none: it has nothing to
  # record, and an empty rollback journal would show up in status as a rollback
  # that happened.
  RUNLOG_DIRECTION="rollback"
  "$dry_run" || runlog_open "rollback" || true

  # What a refusal is called depends on whether it already happened. A preview
  # that said "refused, nothing touched" would read as a rollback that ran.
  local tag="" verb="refused"
  if "$dry_run"; then tag="DRY-RUN: "; verb="would be refused"; fi

  local asset etat attempts size sha src src_db dst dst_db
  local undone=0 refused=0 already=0
  while IFS="$RUNLOG_SEP" read -r asset etat attempts size sha src src_db dst dst_db; do
    [[ -n "$asset" ]] || continue
    if [[ "$etat" == "illisible" ]]; then
      log_error "Entry for asset $asset cannot be read — skipped."
      refused=$(( refused + 1 )); continue
    fi
    # Undone already, by an earlier rollback of THIS run, which is what stops one
    # run being rolled back twice — the database pointing at the recorded
    # destination cannot tell this run's work from a later run's. Counted apart
    # and not as a refusal: there is simply nothing left to undo.
    if [[ "$etat" == "annule" ]]; then
      already=$(( already + 1 )); continue
    fi
    # Only entries that actually completed have anything to undo.
    [[ "$etat" == "source_supprimee" ]] || continue

    # A refusal below touches nothing, so it is logged and not journalled: there
    # is no unfinished work for status to report.
    local position
    position=$(_archive_db_position "$asset" "$src_db" "$dst_db")
    if [[ "$position" != "destination" ]]; then
      log_error "${tag}Asset $asset is not where this run left it (Immich says: $position) — $verb, nothing touched."
      refused=$(( refused + 1 ))
      continue
    fi

    local current=""
    if ! current=$(file_fingerprint "$dst"); then
      log_error "${tag}Cannot read the archived copy of asset $asset: $dst — $verb."
      refused=$(( refused + 1 )); continue
    fi
    if [[ "$current" != "$sha" ]]; then
      log_error "${tag}The archived copy of asset $asset has changed since it was written: $dst — $verb."
      refused=$(( refused + 1 ))
      continue
    fi

    # Everything above this line reads; everything below it writes. So the
    # preview stops exactly here, having already run the three checks that
    # decide whether the real rollback would accept this asset.
    if "$dry_run"; then
      log_info "DRY-RUN: would restore asset $asset → $src"
      undone=$(( undone + 1 ))
      continue
    fi

    if ! _archive_restore_file "$dst" "$src" "$src_db" "$sha"; then
      refused=$(( refused + 1 )); continue
    fi
    if ! db_update_asset_path "$asset" "$src_db"; then
      log_error "File restored but the database could not be pointed back at it: $src_db"
      log_error "The external copy is KEPT so the asset still has a file behind it."
      refused=$(( refused + 1 ))
      runlog_record "" "$asset" divergent 1 "$size" "$sha" "$src" "$src_db" "$dst" "$dst_db" || true
      continue
    fi
    rm -f -- "$dst"
    _rollback_sidecars "$dst" "$src"
    runlog_record "" "$asset" source_supprimee 1 "$size" "$sha" "$dst" "$dst_db" "$src" "$src_db" || true
    # Written into the ORIGINAL run's journal, one entry at a time: a rollback
    # that was only partly accepted marks nothing beyond the entries it
    # completed, and can be run again once the refusals are dealt with.
    RUNLOG_DIRECTION="archive"
    runlog_record "$file" "$asset" annule "$attempts" "$size" "$sha" "$src" "$src_db" "$dst" "$dst_db" || true
    RUNLOG_DIRECTION="rollback"
    undone=$(( undone + 1 ))
  done < <(runlog_read "$file")

  if ! "$dry_run"; then
    runlog_close
    runlog_rotate
  fi
  release_lock
  RUNLOG_DIRECTION="archive"

  local already_note=""
  (( already > 0 )) && already_note=", $already already undone by an earlier rollback"
  # Worded apart from the real summary, which reads as history: a simulation must
  # never leave a line in the log that says work was done.
  if "$dry_run"; then
    log_info "DRY-RUN: would bring back $undone asset(s) of $(basename "$file"), $refused refused${already_note}. Nothing was moved."
  else
    log_info "Rollback of $(basename "$file"): $undone asset(s) brought back, $refused refused${already_note}."
  fi
  (( refused == 0 ))
}

# Brings an asset's sidecars back alongside it. They are not in the journal, so
# they are DERIVED from the destination path, as they were derived from the
# source path on the way out.
#
# No fingerprint was recorded for them when they were archived, so the check
# below is against the archived copy read now: it proves the transfer intact, not
# that the sidecar was never edited on the storage since. A file already in the
# library at that path is still never overwritten unless it is identical.
_rollback_sidecars() {
  local dst_asset="$1" src_asset="$2"
  local ext_sidecar rel lib_sidecar lib_db sha
  while IFS= read -r ext_sidecar; do
    [[ -f "$ext_sidecar" ]] || continue
    # A sidecar sits beside its asset on both sides, so its library path is the
    # asset's library path with the same trailing difference.
    rel="${ext_sidecar#"$dst_asset"}"
    if [[ "$rel" != "$ext_sidecar" ]]; then
      lib_sidecar="${src_asset}${rel}"                 # "<asset>.xmp" form
    else
      lib_sidecar="${src_asset%.*}${ext_sidecar#"${dst_asset%.*}"}"   # "<base>.xmp" form
    fi
    lib_db=$(host_path_to_db_path "$lib_sidecar")
    if ! sha=$(file_fingerprint "$ext_sidecar"); then
      log_warn "Cannot read the archived sidecar, left where it is: $ext_sidecar"
      continue
    fi
    if ! _archive_restore_file "$ext_sidecar" "$lib_sidecar" "$lib_db" "$sha"; then
      log_warn "Sidecar not brought back, archived copy kept: $ext_sidecar"
      continue
    fi
    rm -f -- "$ext_sidecar"
  done < <(_sidecar_candidates "$dst_asset")
}

# Moves an asset's sidecars (XMP, JSON) to the external storage alongside it.
# Sidecars are not tracked in the database, so this is a filesystem-only
# operation.
_archive_move_sidecar() {
  local src_host_path="$1"
  local dry_run="${2:-false}"

  # Derived by the same helper the rollback uses, so what goes out and what comes
  # back are decided in one place.
  local -a candidates=()
  mapfile -t candidates < <(_sidecar_candidates "$src_host_path")

  local sidecar
  for sidecar in "${candidates[@]}"; do
    [[ -f "$sidecar" ]] || continue

    local dst_sidecar
    if ! dst_sidecar=$(archive_build_dest_path "$sidecar"); then
      log_warn "Sidecar is not under a user folder of the internal library — left where it is: $sidecar"
      continue
    fi

    if "$dry_run"; then
      log_info "DRY-RUN: would move sidecar $sidecar → $dst_sidecar"
      continue
    fi

    # Through the same primitives as the asset: the source is only removed once
    # the copy is proved identical.
    local sc_sha
    if ! sc_sha=$(file_fingerprint "$sidecar"); then
      log_warn "Cannot read sidecar to fingerprint it, source kept: $sidecar"
      continue
    fi
    # Guarded like the asset's own mkdir: bare, a destination that has gone
    # read-only or vanished between the two copies would abort the whole run
    # here under `set -e`, in the middle of an archive, leaving the journal
    # .active with no closing summary. Every other filesystem failure on this
    # path keeps the source and moves on, and so does this one.
    if ! mkdir -p "$(dirname "$dst_sidecar")" 2>/dev/null; then
      log_warn "Cannot create the destination folder for the sidecar, source kept: $dst_sidecar"
      continue
    fi
    if ! _transfer_and_verify host "$sidecar" "$dst_sidecar" "$sc_sha"; then
      log_warn "Sidecar not archived, source kept: $sidecar"
      continue
    fi
    # Removed through the container, which owns it, as with the asset.
    $DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" rm -f "$(host_path_to_db_path "$sidecar")" </dev/null \
      || log_warn "Sidecar copied but could not remove source: $sidecar"
  done
}

# ── Main function ─────────────────────────────────────────────────────────────

# Refuses the run when Immich's paths no longer match this config, and when they
# could not be verified at all. On an inconsistency it also comments the cron
# entries out. The database is never rewritten to reconcile the two: the path is
# fixed in Immich, then setup is re-run. Returns 0 consistent, 1 otherwise.
guard_path_consistency() {
  local report state=0
  report=$(db_check_path_consistency) || state=$?
  if (( state == 0 )); then
    return 0
  fi
  if (( state >= 2 )); then
    # Neither consistent nor inconsistent, but unverified — refused all the same.
    log_error "Path consistency could not be verified — archiving refused:"
    log_error "  - $report"
    return 1
  fi
  log_error "Path inconsistency detected — Immich DB no longer matches config:"
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && log_error "  - $line"
  done <<< "$report"
  if disable_cron; then
    log_error "Cron jobs disabled to avoid acting on a stale configuration."
  fi
  log_error "Fix the external library path in Immich, then run: immich-auto-dumper setup"
  return 1
}

# True when Immich's backup folder holds at least one dump that could actually be
# restored: a non-hidden file, larger than 1 KiB, modified in the last 7 days.
# Size and age rather than a name pattern, which would tie this tool to a naming
# convention of Immich's.
_recent_usable_dump() {
  local f size
  while IFS= read -r -d '' f; do
    size=$(stat --format='%s' "$f" 2>/dev/null || echo 0)
    if (( size > 1024 )); then
      return 0
    fi
  done < <(find "$IMMICH_UPLOAD_LOCATION/backups" -maxdepth 1 -type f \
             ! -name '.*' -mtime -7 -print0 2>/dev/null)
  return 1
}

# One archiving run: pre-flight, the decision to archive or not, the resumption
# of earlier runs, then the candidate directories, oldest first, until the
# library is back down to its target. Returns non-zero when the run was refused,
# when it left entries needing a decision, or when a directory could not be read.
archive_run() {
  local dry_run=false force=false
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=true ;;
      --force)   force=true ;;
      # An unrecognised argument ends the run rather than being dropped.
      *)
        log_error "Unknown argument for the archive run: '$arg' — nothing was done."
        return 1
        ;;
    esac
  done

  check_prereqs

  # Storage that is simply not there is an ordinary state for a removable or
  # remote volume, and the run ends quietly. Storage whose state cannot be
  # established exits non-zero, so a cron run reports it.
  local dest_state=0
  check_archive_dest_ready || dest_state=$?
  case $dest_state in
    0) ;;
    1) return 0 ;;
    *) return 1 ;;
  esac

  if ! guard_path_consistency; then
    return 1
  fi

  if ! acquire_lock; then
    return 0
  fi

  # Per-run, so the exit code below reflects what THIS run produced.
  ARCHIVE_TERMINAL_COUNT=0

  # ── Decide first, act afterwards ────────────────────────────────────────────
  #
  # Measuring the library and reading the thresholds writes nothing, so the whole
  # decision is taken before anything irreversible can happen — which is what
  # lets one gate stand in front of every act that touches a photo or a row,
  # reconciliation included.

  # Archiving is driven by the measured size of library/ against absolute
  # boundaries, independently of any unrelated data on the same filesystem. The
  # boundaries are stored in MiB; the deprecated *_GB keys are still honoured.
  local lib_bytes
  lib_bytes=$(dir_size_bytes "$IMMICH_UPLOAD_LOCATION/library")
  local max_mb="${ARCHIVE_LIBRARY_MAX_MB:-}" target_mb="${ARCHIVE_LIBRARY_TARGET_MB:-}"
  [[ -z "$max_mb"    && -n "${ARCHIVE_LIBRARY_MAX_GB:-}"    ]] && max_mb=$(( ARCHIVE_LIBRARY_MAX_GB * 1024 ))
  [[ -z "$target_mb" && -n "${ARCHIVE_LIBRARY_TARGET_GB:-}" ]] && target_mb=$(( ARCHIVE_LIBRARY_TARGET_GB * 1024 ))
  local max_bytes=$(( ${max_mb:-0} * 1048576 ))
  local target_bytes=$(( ${target_mb:-0} * 1048576 ))

  # The second, independent trigger: total free disk space below its floor, even
  # with the library under MAX. Zero or unset disables it.
  local min_free_mb="${ARCHIVE_MIN_FREE_MB:-0}"
  local min_free_bytes=$(( min_free_mb * 1048576 ))
  local disk_free_bytes_now=0
  (( min_free_bytes > 0 )) && disk_free_bytes_now=$(disk_free_bytes "$IMMICH_UPLOAD_LOCATION")
  local low_free_disk=false
  (( min_free_bytes > 0 && disk_free_bytes_now < min_free_bytes )) && low_free_disk=true

  "$dry_run" && log_info "DRY-RUN: nothing will be copied, removed, or written to the DB."
  log_info "Library size: $(bytes_to_human "$lib_bytes")  [max: $(bytes_to_human "$max_bytes") — target: $(bytes_to_human "$target_bytes")]"

  # The target is the floor of every run, automatic or forced, so it is required.
  if (( target_bytes <= 0 )); then
    log_error "Archive target size is not configured — run: immich-auto-dumper setup"
    release_lock
    return 1
  fi

  # Whether this run has anything to archive and, when it has not, the line that
  # says why. Worked out here and acted on further down, so the gate below sees
  # the verdict before a single file has moved.
  local will_archive=false idle_reason=""
  if "$force"; then
    # A forced dump ignores the MAX trigger and still stops at the target.
    log_info "Forced archive: ignoring MAX threshold, archiving down to target $(bytes_to_human "$target_bytes")."
    if (( lib_bytes <= target_bytes )); then
      idle_reason="Library already at or below target — nothing to archive."
    else
      will_archive=true
    fi
  else
    if (( max_bytes <= 0 )); then
      log_error "Archive size limit is not configured — run: immich-auto-dumper setup"
      release_lock
      return 1
    fi
    if (( lib_bytes <= max_bytes )) && ! "$low_free_disk"; then
      idle_reason="Library within limit (max $(bytes_to_human "$max_bytes")) and free disk above floor — nothing to archive."
    else
      will_archive=true
      if (( lib_bytes > max_bytes )); then
        log_info "Archive triggered: library exceeds max $(bytes_to_human "$max_bytes")."
      else
        log_info "Archive triggered: free disk ($(bytes_to_human "$disk_free_bytes_now")) below safety floor ($(bytes_to_human "$min_free_bytes")), even though the library is within its max."
      fi
    fi
  fi

  # Work left behind by an earlier run counts as work to do: resuming it moves
  # files and rewrites rows exactly as archiving does.
  local has_unfinished=false
  [[ -n "$(runlog_unfinished_files)" ]] && has_unfinished=true

  # ── The gate ────────────────────────────────────────────────────────────────
  #
  # Archiving rewrites "originalPath" rows, and a recent Immich dump is what
  # makes those rewrites recoverable. Demanded once, here, in front of both the
  # fresh archive and the resumption of an earlier one.
  #
  # It only fires when there is something to do, so an install whose Immich
  # backup job is broken does not log an error every night it has nothing to
  # archive. Waiting for a dump loses nothing: every state an entry can be parked
  # in holds both a file and a row that point at each other.
  #
  # A dry run is exempt, since it writes nothing.
  if "$will_archive" || "$has_unfinished"; then
    if ! "$dry_run" && ! _recent_usable_dump; then
      log_error "No recent, usable DB backup (<7 days) in $IMMICH_UPLOAD_LOCATION/backups — nothing was archived and no unfinished run was resumed."
      log_error "Immich writes its dumps there; check its backup job before archiving again."
      release_lock
      return 1
    fi
  fi

  # Outside the gate: deleting old `.done` journals touches no photo and no row,
  # so a run refused for want of a dump still does its housekeeping. Skipped in a
  # dry run, which writes nothing at all.
  "$dry_run" || runlog_rotate

  # Phase one of every real run: finish what earlier runs started, before the
  # thresholds are acted on. A dry run reports the outstanding work instead.
  if "$dry_run"; then
    local pending blocked divergent unreadable nfiles
    # The sixth field, the oldest run's id, is status's to report.
    read -r pending blocked divergent unreadable nfiles _ < <(runlog_summary)
    if (( nfiles > 0 )); then
      log_info "DRY-RUN: $nfiles earlier run(s) left work behind ($pending to resume, $blocked blocked, $divergent divergent, $unreadable unreadable); a real run would resume them first."
    fi
  else
    archive_reconcile
  fi

  if ! "$will_archive"; then
    log_info "$idle_reason"
    release_lock
    # Reconciliation ran just above and may have parked something terminal, which
    # a run ending here reports all the same.
    if (( ARCHIVE_TERMINAL_COUNT > 0 )); then
      log_error "$ARCHIVE_TERMINAL_COUNT asset(s) ended this run blocked or divergent — each one needs a decision. See: immich-auto-dumper status"
      return 1
    fi
    return 0
  fi

  local bytes_to_free=$(( lib_bytes - target_bytes ))

  log_info "Need to free $(bytes_to_human "$bytes_to_free") — selecting oldest directories first:"

  # Opened only now that there is something to archive, so a nightly no-op run
  # leaves no journal file. A journal that cannot be opened stops the run before
  # anything is touched: without one, a run is neither resumable nor undoable.
  if ! "$dry_run"; then
    if ! runlog_open "run"; then
      log_error "Cannot open a run journal in $(runlog_dir) — nothing was archived."
      log_error "Without it a run is neither resumable nor undoable, and a journal directory that refuses writes usually means the disk holding Immich is full, read-only or failing."
      local df_line
      df_line=$(df -h -- "${LOG_DIR:-$HOME}" 2>/dev/null | tail -1 || true)
      [[ -n "$df_line" ]] && log_error "  df ${LOG_DIR:-$HOME}: $df_line"
      release_lock
      return 1
    fi
  fi

  local freed_bytes=0
  # Directories the database refused to list, reported in the closing line.
  local dirs_failed=0

  # Captured, checked, THEN iterated, never iterated as a process substitution:
  # `while … done < <(db_get_archive_candidates)` discards the function's exit
  # code, and a database that stopped answering would read as no rows — as
  # "nothing left to archive". Iterating an array also leaves stdin alone.
  local candidates_raw cand_rc=0
  candidates_raw=$(db_get_archive_candidates) || cand_rc=$?
  if (( cand_rc != 0 )); then
    log_error "Could not read the list of directories to archive — the database stopped answering."
    log_error "Nothing was archived. This is NOT 'nothing to do'."
    "$dry_run" || runlog_close
    release_lock
    return 1
  fi
  local -a candidates=()
  [[ -n "$candidates_raw" ]] && mapfile -t candidates <<< "$candidates_raw"

  local row user_folder parent_dir folder_size
  for row in "${candidates[@]}"; do
    IFS="$DB_FIELD_SEP" read -r user_folder parent_dir folder_size <<< "$row"
    [[ -z "$user_folder" ]] && continue

    log_info "Candidate directory: $parent_dir (user: $user_folder, $(bytes_to_human "${folder_size:-0}"))"

    # Same treatment for the inner query, where a failure costs one directory:
    # logged, counted as not processed, and never announced as archived.
    local assets_raw asset_rc=0
    assets_raw=$(db_get_folder_assets "$parent_dir") || asset_rc=$?
    if (( asset_rc != 0 )); then
      log_error "Could not list the assets of $parent_dir — the database stopped answering. Directory left untouched."
      dirs_failed=$(( dirs_failed + 1 ))
      continue
    fi
    local -a assets=()
    [[ -n "$assets_raw" ]] && mapfile -t assets <<< "$assets_raw"

    local dir_ok=0 dir_ko=0 dir_held=0 dir_freed=0
    local arow asset_id original_path_db
    for arow in "${assets[@]}"; do
      # The third field, Immich's own fileSizeInByte, is dropped: it is only good
      # enough to sort the candidates, and what a move frees is read off the disk.
      IFS="$DB_FIELD_SEP" read -r asset_id original_path_db _ <<< "$arow"
      [[ -z "$asset_id" ]] && continue

      # Already spoken for by an unfinished run, which reconciliation above owns.
      # Counted rather than merely skipped, so that a directory whose every asset
      # is held is reported as held and not as failed.
      if [[ -n "${ARCHIVE_IN_FLIGHT[$asset_id]:-}" ]]; then
        dir_held=$(( dir_held + 1 ))
        continue
      fi

      local src_host
      src_host=$(db_path_to_host_path "$original_path_db")

      if ! _archive_move_file "$asset_id" "$src_host" "db_update_asset_path" "$dry_run"; then
        log_error "Asset skipped: $asset_id ($original_path_db)"
        dir_ko=$(( dir_ko + 1 ))
        continue
      fi

      _archive_move_sidecar "$src_host" "$dry_run" || true

      dir_ok=$(( dir_ok + 1 ))
      # What the filesystem lost, not what Immich's metadata claims.
      dir_freed=$((   dir_freed   + ARCHIVE_LAST_FREED_BYTES ))
      freed_bytes=$(( freed_bytes + ARCHIVE_LAST_FREED_BYTES ))
    done

    # One closing line per directory, naming which of the five outcomes it had.
    local held_note=""
    (( dir_held > 0 )) && held_note=" ($dir_held more held by an unfinished run)"
    if "$dry_run"; then
      log_info "DRY-RUN: would archive directory: $parent_dir — $(bytes_to_human "$dir_freed") ($dir_ok asset(s))${held_note}"
    elif (( dir_ok == 0 && dir_ko == 0 && dir_held > 0 )); then
      # Nothing was tried here: every asset belongs to a journal waiting on
      # something, which is not a failure of this directory.
      log_warn "Directory left alone: $parent_dir — $dir_held asset(s) held by an unfinished run awaiting a decision. See: immich-auto-dumper status"
    elif (( dir_ok == 0 && dir_ko == 0 )); then
      log_info "Nothing left to archive in $parent_dir."
    elif (( dir_ok == 0 )); then
      log_error "Directory NOT archived: $parent_dir — all $dir_ko asset(s) failed.${held_note}"
    elif (( dir_ko > 0 )); then
      log_warn "Directory partially archived: $parent_dir — $dir_ok done ($(bytes_to_human "$dir_freed") freed), $dir_ko failed.${held_note}"
    else
      log_info "Directory archived: $parent_dir — $(bytes_to_human "$dir_freed") freed ($dir_ok asset(s))${held_note}"
    fi

    # The stopping condition, tested between directories and never inside one. A
    # real run MEASURES the library again; a dry run, which moved nothing, adds
    # up what it said it would free.
    if "$dry_run"; then
      (( freed_bytes >= bytes_to_free )) && break
    else
      lib_bytes=$(dir_size_bytes "$IMMICH_UPLOAD_LOCATION/library")
      if (( lib_bytes <= target_bytes )); then
        log_info "Library back down to $(bytes_to_human "$lib_bytes") — target reached, stopping."
        break
      fi
    fi
  done

  if ! "$dry_run"; then
    runlog_close
    runlog_rotate
  fi
  release_lock

  local unread_note=""
  (( dirs_failed > 0 )) && unread_note=" $dirs_failed directory(ies) could not be read and were left untouched."

  # A simulation's closing line carries the DRY-RUN prefix and never the wording
  # `status` reads back as an archive that happened.
  if "$dry_run"; then
    log_info "DRY-RUN: would free $(bytes_to_human "$freed_bytes") in total. Nothing was moved.${unread_note}"
    return 0
  fi

  log_info "Archive complete. Freed: $(bytes_to_human "$freed_bytes").${unread_note}"

  # The exit code says whether this run left something that needs a person.
  if (( ARCHIVE_TERMINAL_COUNT > 0 )); then
    log_error "$ARCHIVE_TERMINAL_COUNT asset(s) ended this run blocked or divergent — each one needs a decision. See: immich-auto-dumper status"
    return 1
  fi
  # A directory the database would not list ends the run non-zero too.
  (( dirs_failed == 0 ))
}
