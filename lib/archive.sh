#!/usr/bin/env bash
# shellcheck disable=SC2034  # RUNLOG_DIRECTION and the ARCHIVE_* globals are
# read from lib/runlog.sh and from the main script, both sourced at runtime
# through $SCRIPT_DIR, which shellcheck cannot follow.
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

# Builds the archive destination host path for a given host source path.
# Preserves the full subpath after <user_folder>/, regardless of storage template depth.
#
# Returns 1 and prints NOTHING when the source is not of the form
# <upload location>/library/<user folder>/<rest>, both parts non-empty. It used
# to assume that shape: a path from outside the library left user_folder empty,
# asked USER_MAP[""] — a bad array subscript, printed to stderr and swallowed by
# the `:-` — and produced "/mnt/external//var/other/a.jpg", a double slash
# followed by the absolute source path. That is exactly the shape Immich's
# library scan does not recognise, the one _sanitize_folder exists to prevent
# elsewhere. The SQL selection no longer offers such an asset; this is the guard
# that still holds if another caller ever appears, the same double cover as F3.
archive_build_dest_path() {
  local src_host_path="$1"
  local library_prefix="$IMMICH_UPLOAD_LOCATION/library/"

  [[ "$src_host_path" == "$library_prefix"* ]] || return 1
  local relative="${src_host_path#"$library_prefix"}"
  local user_folder="${relative%%/*}"
  local rest="${relative#"$user_folder/"}"
  # `rest == relative` means the strip found no "<folder>/" to remove, i.e. the
  # path names a file sitting directly in library/ with no user folder at all.
  [[ -n "$user_folder" && -n "$rest" && "$rest" != "$relative" ]] || return 1

  local mapped_name="${USER_MAP["$user_folder"]:-$user_folder}"

  printf '%s/%s/%s\n' "$ARCHIVE_DEST_PATH" "$mapped_name" "$rest"
}

# Assets an unfinished run journal still owns, filled by archive_reconcile and
# read by the candidate loop. Declared here so both see the same array.
declare -A ARCHIVE_IN_FLIGHT=()

# Bytes the last move actually took off the library disk. It is an OUTPUT of
# _archive_move_file, not of its callee, and the candidate loop sums it after
# every asset. Only _archive_process_asset used to set it, and a dry run never
# reaches that function — so the first simulation with real work to do died on
# `ARCHIVE_LAST_FREED_BYTES: unbound variable`, since an unbound name inside
# $(( )) kills the shell under `set -u` whatever the caller wraps it in. Seeded
# here so no path can leave it unset, and reset at each entry point below so a
# failed move can never report the previous asset's figure.
ARCHIVE_LAST_FREED_BYTES=0

# Entries this run put into a state that needs a human: `bloque` and `divergent`,
# and only those. `abandonne` is not one — the asset simply left Immich, which is
# its owner's decision, not a failure.
#
# Counted as WRITTEN DURING THIS RUN rather than as found in runs/, deliberately.
# Counting what is present would leave the light red night after night, since a
# divergent entry survives until an operator deletes the run file. Counted this
# way the non-zero exit falls exactly once, on the run that produced the problem:
# archive_reconcile skips the states that are not resumable, so no later run
# writes them again.
ARCHIVE_TERMINAL_COUNT=0

# ── Primitives shared by both directions ──────────────────────────────────────
#
# Archiving and rolling back are not mirror images — the mechanics differ by who
# owns the files. On the way out, `cp -p` on the host is enough: the external
# storage belongs to the invoking user. On the way back the target is inside the
# library, which belongs to the container's root, and this tool never uses sudo,
# so the write goes through `docker exec`. Two implementations, not a swap of two
# variables.
#
# What IS the same in both directions is the discipline: write, push it out of
# the cache, read it back, compare it against the fingerprint taken before
# anything moved, and only then let the caller remove the other copy. That lives
# here, in one place, so that both directions are held to it — and so that the
# guard against overwriting an occupied path, which archiving had and rolling
# back did not, now covers both.

# Writes <src> to <dst>, on the side named by <side>, and proves the result
# carries <expected_sha> before returning 0. Reads the copy back through the same
# side it was written on: for the container that also proves Immich can see what
# we just wrote, which is the whole lesson of the 11 September incident.
# Leaves nothing behind on failure. 0 written and verified, 1 otherwise.
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
      # Flushed BEFORE it is verified, so the fingerprint is taken of what is on
      # the storage rather than of what is still in memory.
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
      # Only `cat` is assumed to exist in the Immich image.
      back=$($DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" cat -- "$dst" </dev/null \
             | sha256sum | cut -d' ' -f1) || back=""
      ;;
    *)
      log_error "Internal error: unknown transfer side '$side'."
      return 1 ;;
  esac

  if [[ "$back" != "$expected_sha" ]]; then
    log_error "What was written does not match the recorded fingerprint: $dst"
    # An interrupted or truncated write leaves a PARTIAL file that a mere
    # existence check would accept — and the other copy would then be deleted.
    # It goes, on both sides: nothing is lost, the original is still there.
    case "$side" in
      host)      rm -f -- "$dst" ;;
      container) $DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" rm -f "$dst" </dev/null || true ;;
    esac
    log_error "The incomplete file was removed; the other copy is still in place."
    return 1
  fi
  return 0
}

# Says what is already sitting at <path>, against the fingerprint we expect:
#   0  nothing there — go ahead and write
#   1  already there and identical — no need to write, and nothing to refuse
#   2  already there and DIFFERENT, or impossible to compare — refuse
#
# Concluding "already archived" means skipping the copy, pointing the database at
# that file and deleting the source. Size equality was the proof, and it is not
# one: a foreign file of the same byte count was accepted and the original photo
# deleted in its favour. Only a matching fingerprint earns it.
#
# The rollback did not have this guard at all: it wrote over the library path
# with `cat >` without looking at what was there.
_refuse_if_occupied() {
  local path="$1" expected_sha="$2"
  [[ -e "$path" ]] || return 0
  local current
  current=$(file_fingerprint "$path") || return 2
  [[ "$current" == "$expected_sha" ]] && return 1
  return 2
}

# ── Per-asset pipeline, journalled and resumable ──────────────────────────────

# Where Immich currently says the asset is, answered against what the journal
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

# Removes the source through the container: library files belong to the container's
# UID (usually root) and this tool never uses sudo. Refuses unless the file still
# has the fingerprint recorded before the copy — if it changed, the source is no
# longer the photo we archived and deleting it would destroy something else.
# 0 removed (or already gone), 1 refused or failed.
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

# Puts the database back on the source after a step failed past the update, and
# says whether it worked. The old code ignored that answer and deleted the copy
# regardless: when the restore had failed, the database pointed at a path whose
# file had just been removed, and the source became an orphan nothing referenced.
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

  # Bytes this call actually removed from the library, read off the disk. Zero
  # until a source is really deleted.
  ARCHIVE_LAST_FREED_BYTES=0

  local try=$(( attempts + 1 ))
  # Records the entry as it now stands and gives back the right return code. An
  # entry that has used up its tries is parked rather than retried every night.
  # Defined here on purpose: bash scopes dynamically, so it reads the caller's
  # locals instead of taking ten arguments that would only ever be those.
  _park() {
    local etat="$1"
    if [[ "$etat" != "divergent" && "$etat" != "abandonne" ]] && (( try >= RUNLOG_MAX_ATTEMPTS )); then
      log_error "Asset $asset_id has failed $try times — parked as blocked, it will not be retried."
      # `|| true`: runlog_record reports its own failure, and parking is the
      # last thing left to record — failing it must not kill the run.
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

  # Immich is the source of truth and lives between runs: whatever the journal
  # remembers, the database is asked again and has to agree before anything
  # irreversible happens.
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
        # The update had gone through; only the source removal can be left.
        [[ "$state" == "prevu" || "$state" == "copie" ]] && state="base_a_jour" ;;
      source)
        # The database still points at the source, so any later step was undone.
        [[ "$state" == "base_a_jour" ]] && state="copie" ;;
    esac
  fi

  # Each of the three transitions below is written down BEFORE the act it
  # describes, and a record that cannot be written stops that act. `return 1`
  # rather than `_park` on purpose: _park would write to the same journal (and
  # fail in the same way), and above all nothing has been attempted, so the
  # attempt counter must not move.

  # ── → copie ─────────────────────────────────────────────────────────────────
  if [[ -z "$state" || "$state" == "prevu" ]]; then
    if ! runlog_record "" "$asset_id" prevu "$try" "$size" "$sha" "$src_host" "$src_db" "$dst_host" "$dst_db"; then
      log_error "Cannot write the run journal — asset $asset_id skipped, nothing touched."
      return 1
    fi

    # The call must not be bare: _refuse_if_occupied answers 1 and 2 for cases we
    # handle, and under `set -e` a bare call would abort the whole run instead.
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
      # -p keeps the timestamps: without it every archived photo arrived on the
      # external storage dated the day it was archived, losing the only file-level
      # trace of when it was taken. The write, the flush, the read-back and the
      # cleanup of a partial file all live in _transfer_and_verify now.
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

    # The asset must end up ADOPTED by an external library: an archived asset left
    # as an upload asset gets re-imported as a duplicate by Immich's periodic
    # library scan, and stays exposed to the storage-template migration job.
    local fault=""
    if [[ "${DB_UPDATE_IS_EXTERNAL:-}" == "f" ]]; then
      fault="No external library in Immich covers $dst_db for this asset's owner (a library scan would re-import it as a duplicate). Create it in Immich: Administration → Libraries."
    elif ! $DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" test -f "$dst_db" </dev/null; then
      fault="The copy is not visible from inside the Immich container: $dst_db"
    fi

    if [[ -n "$fault" ]]; then
      log_error "$fault"
      if _archive_restore_db "$update_fn" "$asset_id" "$src_db"; then
        # Back where we started: the copy is ours and serves no purpose.
        rm -f "$dst_host"
        log_error "Asset $asset_id left as it was; it will be retried on the next run."
        _park prevu; return $?
      fi
      # The restore failed. The database still points at the copy, so the copy is
      # KEPT: removing it is what turned a recoverable failure into an asset with
      # no file and an unreferenced original. The state is consistent, just not the
      # one we wanted, and it needs a human.
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
    # How much the library actually loses is what the filesystem says about the
    # file we are about to delete — measured now, while it is still there. The
    # accounting used to come from Immich's own fileSizeInByte, and when those
    # rows were missing the tool believed it had freed nothing and kept going
    # until the whole library was gone.
    local freed_now=0
    if [[ -e "$src_host" ]]; then
      freed_now=$(stat --format='%s' "$src_host" 2>/dev/null || echo 0)
    fi
    if ! _archive_remove_source "$src_host" "$src_db" "$sha"; then
      # The archive itself succeeded: the asset points at the copy and is readable.
      # Only the cleanup is outstanding, so the entry stays pending rather than
      # being treated as a failure of the move.
      _park base_a_jour; return $?
    fi
    ARCHIVE_LAST_FREED_BYTES="$freed_now"
    # The ONE record written after its act rather than before it, so its
    # failure stays a warning: the next run re-reads the database, finds the
    # asset at its destination and finishes cleanly.
    runlog_record "" "$asset_id" source_supprimee "$try" "$size" "$sha" "$src_host" "$src_db" "$dst_host" "$dst_db" || true
  fi

  return 0
}

# Moves one asset file to external storage and updates its DB path. Thin entry
# point: works out the destination and the fingerprint, then hands over to the
# journalled pipeline. Returns 0 archived, 1 skipped, 2 terminal failure.
_archive_move_file() {
  local asset_id="$1"
  local src_host_path="$2"
  local update_fn="$3"
  local dry_run="${4:-false}"

  # Reset at the entry point, not only in the journalled pipeline below: every
  # early return in this function (dry run, unrecordable path, unreadable source)
  # ends the call without ever reaching it.
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
    # What a real run would take off the library disk. It was left at zero for
    # every asset, so a simulation reported "would free 0 B" whatever it was
    # about to move, and its stop-at-target test — which compares that same
    # total against what has to be freed — could never become true: every
    # candidate directory got announced, where a real run stops after two.
    local would_free=0
    if [[ -e "$dst_host" ]]; then
      local identical=0
      files_are_identical "$src_host_path" "$dst_host" || identical=$?
      case $identical in
        0) log_info "DRY-RUN: would UPDATE DB only for asset $asset_id → $dst_db (identical copy already there)"
           # No copy to make, but the source still goes.
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
    # Preview path: `|| true` on purpose. A mute database here costs this one
    # advisory line, and a simulation must still list its candidates. See the
    # note in _config_check for the whole family.
    if [[ "$(db_asset_would_be_external "$asset_id" "$dst_db" || true)" == "f" ]]; then
      log_warn "DRY-RUN: no external library in Immich covers $dst_db for this asset's owner — the real run would SKIP this asset (Immich's library scan would otherwise re-import it as a duplicate). Create the external library first (see setup)."
    fi
    return 0
  fi

  # A path holding a newline would split one journal record over two lines and make
  # the whole file ambiguous. Refusing the asset is safer than writing a record that
  # a later run would have to guess at.
  if ! runlog_path_is_recordable "$src_host_path" "$dst_host" "$src_db" "$dst_db"; then
    log_error "Asset $asset_id has a path containing a line break — skipped, it cannot be journalled safely."
    return 1
  fi

  # The fingerprint is taken BEFORE anything moves: it is what later authorises
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

# First phase of every real run: pick up what earlier runs left unfinished, before
# looking at thresholds. Deliberately not a separate command — and deliberately not
# a reason to refuse archiving either, because the moment the disk is filling up is
# exactly when the tool must keep working.
#
# Echoes nothing; logs what it does. Each old run file is appended to in place and
# then renamed, so one run's history stays in one file.
#
# Fills ARCHIVE_IN_FLIGHT with the assets an unfinished journal still owns. The
# selection below must leave those alone: an asset that keeps failing is still an
# internal asset, so a fresh run would pick it up again and give it a SECOND entry
# whose attempt counter starts at one — which is how an asset blocked by a foreign
# file at its destination collected four "first attempts" across four runs and
# never reached the ceiling meant to park it.
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
    # Transitions are appended to the file they belong to.
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
        # Park it explicitly rather than stepping over it every night: the journal
        # should say out loud that this entry has been given up on, and status
        # should count it among the ones needing a decision.
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
        0) resumed=$(( resumed + 1 )) ;;
        1) skipped=$(( skipped + 1 )) ;;
        *) stuck=$((   stuck   + 1 )) ;;
      esac
    done < <(runlog_read "$file")
    runlog_close "$file"
  done
  RUNLOG_FILE="$previous"

  # Re-read what is left, after renaming, and claim those assets. An entry that
  # did not complete keeps its asset until either a later run finishes it or an
  # operator resolves it and removes the run file.
  local f2
  while IFS= read -r f2; do
    [[ -n "$f2" ]] || continue
    while IFS="$RUNLOG_SEP" read -r asset etat _; do
      [[ -n "$asset" ]] || continue
      case "$etat" in
        # `annule` included: a rollback put that asset back in the library, so it
        # is an ordinary candidate again and must not stay held for ever.
        source_supprimee|abandonne|annule) ;;
        *) ARCHIVE_IN_FLIGHT["$asset"]=1 ;;
      esac
    done < <(runlog_read "$f2")
  done < <(runlog_unfinished_files)

  log_info "Resume: $resumed completed, $skipped postponed to the next run, $stuck needing attention."
  return 0
}

# ── Rollback ──────────────────────────────────────────────────────────────────

# Puts a file back INTO the library, holding the way back to the same discipline
# as the way out: refuse an occupied path unless what is there is already the
# right file, then write, flush, read back and compare — all of it in the shared
# primitives. 0 restored (or already correctly there), 1 refused or failed.
#
# <src_host> is the library path seen from the host, used only to look at what is
# already there; the write itself goes through the container, which owns it.
_archive_restore_file() {
  local dst_host="$1" src_host="$2" src_db="$3" expected_sha="$4"

  local occupied=0
  _refuse_if_occupied "$src_host" "$expected_sha" || occupied=$?
  case $occupied in
    0) ;;
    1) # Already back, and proven to be the right file. Nothing to write.
       return 0 ;;
    *) log_error "A DIFFERENT file already occupies the library path, or it cannot be read: $src_db"
       log_error "Refused rather than overwritten — the archived copy is untouched."
       return 1 ;;
  esac

  _transfer_and_verify container "$dst_host" "$src_db" "$expected_sha"
}

# The sidecar candidates for an asset, derived from its path exactly as
# _archive_move_sidecar derives them on the way out — including stripping the
# extension from the FILE NAME and not from the whole path (F10). Echoed one per
# line, deduplicated: for an asset with no extension, "<path>.xmp" and
# "<base>.xmp" are the same file.
_sidecar_candidates() {
  local path="$1"
  local folder base_name
  folder=$(dirname "$path")
  base_name=$(basename "$path")
  local base="$folder/${base_name%.*}"
  printf '%s\n' "${path}.xmp" "${path}.json" "${base}.xmp" "${base}.json" \
    | awk '!seen[$0]++'
}

# immich-auto-dumper rollback <run-id> — explicit, never automatic. Bringing files
# back is a decision, taken on one identified run.
#
# Every entry that completed is walked backwards: copy in, verify, point the
# database at the source, remove the external copy. With the same guards as
# archiving — and a refusal, reported, for any asset whose current state does not
# match what the journal says it should be.
archive_rollback() {
  local run_id="${1:-}"
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

  log_info "Rolling back $(basename "$file")."
  # The rollback keeps its own journal: it is an operation in its own right, and
  # the original file stays a truthful record of what that run did.
  RUNLOG_DIRECTION="rollback"
  runlog_open "rollback" || true

  local asset etat attempts size sha src src_db dst dst_db
  local undone=0 refused=0 already=0
  while IFS="$RUNLOG_SEP" read -r asset etat attempts size sha src src_db dst dst_db; do
    [[ -n "$asset" ]] || continue
    if [[ "$etat" == "illisible" ]]; then
      log_error "Entry for asset $asset cannot be read — skipped."
      refused=$(( refused + 1 )); continue
    fi
    # Undone already, by an earlier rollback of THIS run. Without this the same
    # run could be rolled back again and again: the only question asked was "does
    # the database point at the recorded destination?", which cannot tell this
    # run's work from a LATER run that archived the same asset to the same path.
    # Replaying rollback A after run B had re-archived those assets undid B's
    # work instead, left B's journal claiming a job that no longer existed, and
    # could be repeated indefinitely.
    #
    # Counted apart, not as a refusal: nothing is wrong, there is simply nothing
    # left to undo.
    if [[ "$etat" == "annule" ]]; then
      already=$(( already + 1 )); continue
    fi
    # Only entries that actually completed have anything to undo.
    [[ "$etat" == "source_supprimee" ]] || continue

    # A refusal is not a state to carry forward: nothing was touched, so there is
    # no unfinished work to record. It belongs in the log, where it is already
    # spelled out — writing it into the journal would leave status reporting a
    # decision as pending for ever.
    local position
    position=$(_archive_db_position "$asset" "$src_db" "$dst_db")
    if [[ "$position" != "destination" ]]; then
      log_error "Asset $asset is not where this run left it (Immich says: $position) — refused, nothing touched."
      refused=$(( refused + 1 ))
      continue
    fi

    local current=""
    if ! current=$(file_fingerprint "$dst"); then
      log_error "Cannot read the archived copy of asset $asset: $dst — refused."
      refused=$(( refused + 1 )); continue
    fi
    if [[ "$current" != "$sha" ]]; then
      log_error "The archived copy of asset $asset has changed since it was written: $dst — refused."
      refused=$(( refused + 1 ))
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
    # Written into the ORIGINAL run's journal, not this one. It does not falsify
    # that run's account of what it did — it extends it with what happened to it
    # afterwards, which makes it more faithful, not less. A rollback that was
    # only partly accepted marks nothing beyond the entries it completed, so it
    # can be run again once the cause of the refusals is dealt with.
    RUNLOG_DIRECTION="archive"
    runlog_record "$file" "$asset" annule "$attempts" "$size" "$sha" "$src" "$src_db" "$dst" "$dst_db" || true
    RUNLOG_DIRECTION="rollback"
    undone=$(( undone + 1 ))
  done < <(runlog_read "$file")

  runlog_close
  runlog_rotate
  release_lock
  RUNLOG_DIRECTION="archive"

  local already_note=""
  (( already > 0 )) && already_note=", $already already undone by an earlier rollback"
  log_info "Rollback of $(basename "$file"): $undone asset(s) brought back, $refused refused${already_note}."
  (( refused == 0 ))
}

# Brings an asset's sidecars back alongside it. They are not in the journal —
# Immich v3.2.0 does not track them in the database at all, it finds them by
# naming convention when it scans — so they are DERIVED from the destination
# path, exactly as they were derived from the source path on the way out.
#
# Honest about what that is worth: no fingerprint was recorded for these files
# when they were archived, so the verification below proves the transfer was
# intact, not that the sidecar was not edited on the storage since. That is
# strictly better than abandoning it, and it is all the journal allows. A file
# already present in the library at that path is never overwritten unless it is
# identical — the same discipline as the asset.
_rollback_sidecars() {
  local dst_asset="$1" src_asset="$2"
  local ext_sidecar rel lib_sidecar lib_db sha
  while IFS= read -r ext_sidecar; do
    [[ -f "$ext_sidecar" ]] || continue
    # The sidecar sits beside the asset on both sides, so its library path is the
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

# Moves sidecar files (XMP, JSON) alongside an asset to external storage.
# Sidecars are not tracked in the DB — filesystem-only operation.
_archive_move_sidecar() {
  local src_host_path="$1"
  local dry_run="${2:-false}"

  # Derived by the same helper the rollback uses, so what goes out and what comes
  # back are decided in one place. It strips the extension from the FILE NAME and
  # not from the whole path (F10), and deduplicates: for an asset with no
  # extension, "<path>.xmp" and "<base>.xmp" are the same file, which a
  # simulation used to announce twice.
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

    # Held to the same standard as the asset, through the same primitives: the
    # source is only removed once the copy is proved identical. The test this
    # replaced — does the destination exist — accepted a truncated file and then
    # deleted the original.
    local sc_sha
    if ! sc_sha=$(file_fingerprint "$sidecar"); then
      log_warn "Cannot read sidecar to fingerprint it, source kept: $sidecar"
      continue
    fi
    mkdir -p "$(dirname "$dst_sidecar")"
    if ! _transfer_and_verify host "$sidecar" "$dst_sidecar" "$sc_sha"; then
      log_warn "Sidecar not archived, source kept: $sidecar"
      continue
    fi
    # Same ownership constraint as the asset: remove the source via the container.
    $DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" rm -f "$(host_path_to_db_path "$sidecar")" </dev/null \
      || log_warn "Sidecar copied but could not remove source: $sidecar"
  done
}

# ── Main function ─────────────────────────────────────────────────────────────

# Aborts (and pauses the cron) when Immich's DB no longer matches our config —
# i.e. the external library path changed in Immich (case B). Immich is the source
# of truth: we never rewrite the DB. The user must fix the path in Immich and
# re-run setup. Returns 1 on inconsistency, 0 otherwise.
guard_path_consistency() {
  local report state=0
  report=$(db_check_path_consistency) || state=$?
  if (( state == 0 )); then
    return 0
  fi
  if (( state >= 2 )); then
    # Not "consistent" and not "inconsistent": unverified. Archiving on an
    # unverified DB is how a stale configuration gets acted on.
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

# True when Immich's backup folder holds at least one recent dump that could
# actually be restored.
#
# The previous test was "any file here, modified in the last 7 days", and the file
# that satisfied it was Immich's own 13-byte `.immich` marker. The last real dump
# was two months old and predated a major-version upgrade, so it was unusable — yet
# the run went ahead and rewrote database rows on the strength of it.
#
# Hidden files are excluded and a plausible size demanded, rather than matching
# `immich-db-backup-*`: a name filter would tie this tool to a convention of
# Immich's that is free to change, which is exactly the coupling that breaks at the
# next upgrade.
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

archive_run() {
  local dry_run=false force=false
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=true ;;
      --force)   force=true ;;
      # An argument this function does not understand used to be dropped in silence.
      # `dump_now --force --dryrun` therefore archived for real — the exact opposite
      # of what the flag was typed for. Refuse rather than guess.
      *)
        log_error "Unknown argument for the archive run: '$arg' — nothing was done."
        return 1
        ;;
    esac
  done

  check_prereqs

  # Storage availability — agnostic to the storage type (marker-based). A storage
  # that is simply not there is an ordinary state for a removable or remote volume:
  # the run ends quietly. A storage whose state cannot be established is not, and
  # exits non-zero so a cron run reports it.
  local dest_state=0
  check_archive_dest_ready || dest_state=$?
  case $dest_state in
    0) ;;
    1) return 0 ;;
    *) return 1 ;;
  esac

  # Case B: external library path changed in Immich → pause, never touch the DB.
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
  # decision is taken before anything irreversible can happen. That split is what
  # lets ONE gate stand in front of every act that touches a photo or a database
  # row — reconciliation included.
  #
  # Reconciliation used to run here, above the recent-dump check. It drives the
  # very same pipeline as a fresh archive (copy, UPDATE originalPath, adopt into
  # the external library, delete the source), yet it was exempt from the safety
  # net that check exists to be: on the cron path, an asset left its internal
  # library for good and the run then announced "nothing to archive" and exited 0.

  # Drive archiving by the library's actual size (du of library/), compared against
  # absolute boundaries. This is independent of any unrelated data sharing the same
  # filesystem. Boundaries are stored in MiB (1 MiB = 1024^2 bytes) so fractional-GB
  # limits are expressible; the deprecated *_GB keys are still honored for configs
  # written before the switch (1 GiB = 1024 MiB).
  local lib_bytes
  lib_bytes=$(dir_size_bytes "$IMMICH_UPLOAD_LOCATION/library")
  local max_mb="${ARCHIVE_LIBRARY_MAX_MB:-}" target_mb="${ARCHIVE_LIBRARY_TARGET_MB:-}"
  [[ -z "$max_mb"    && -n "${ARCHIVE_LIBRARY_MAX_GB:-}"    ]] && max_mb=$(( ARCHIVE_LIBRARY_MAX_GB * 1024 ))
  [[ -z "$target_mb" && -n "${ARCHIVE_LIBRARY_TARGET_GB:-}" ]] && target_mb=$(( ARCHIVE_LIBRARY_TARGET_GB * 1024 ))
  local max_bytes=$(( ${max_mb:-0} * 1048576 ))
  local target_bytes=$(( ${target_mb:-0} * 1048576 ))

  # Free-disk safety net: also archive when total free disk space is low, even if
  # the library itself stayed under MAX — other processes on the same disk can be
  # what's actually filling it up. 0/unset disables this trigger.
  local min_free_mb="${ARCHIVE_MIN_FREE_MB:-0}"
  local min_free_bytes=$(( min_free_mb * 1048576 ))
  local disk_free_bytes_now=0
  (( min_free_bytes > 0 )) && disk_free_bytes_now=$(disk_free_bytes "$IMMICH_UPLOAD_LOCATION")
  local low_free_disk=false
  (( min_free_bytes > 0 && disk_free_bytes_now < min_free_bytes )) && low_free_disk=true

  "$dry_run" && log_info "DRY-RUN: nothing will be copied, removed, or written to the DB."
  log_info "Library size: $(bytes_to_human "$lib_bytes")  [max: $(bytes_to_human "$max_bytes") — target: $(bytes_to_human "$target_bytes")]"

  # The target is the floor: archiving always stops once the library reaches it,
  # never below it — both for automatic and forced runs.
  if (( target_bytes <= 0 )); then
    log_error "Archive target size is not configured — run: immich-auto-dumper setup"
    release_lock
    return 1
  fi

  # Whether this run has candidates to archive, and — when it has none — the line
  # that says why. The verdict is worked out here and acted on further down, so
  # the gate below sees it before a single file has moved.
  local will_archive=false idle_reason=""
  if "$force"; then
    # Manual forced dump: bypass the MAX trigger but still respect the target floor.
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

  # Work left behind by an earlier run counts as work: resuming it moves files and
  # rewrites rows exactly as archiving does.
  local has_unfinished=false
  [[ -n "$(runlog_unfinished_files)" ]] && has_unfinished=true

  # ── The gate ────────────────────────────────────────────────────────────────
  #
  # Archiving rewrites "originalPath" rows, so a recent (<7 days) Immich dump is
  # what makes those rewrites recoverable. Asked ONCE, here, in front of both the
  # fresh archive and the resumption of an earlier one.
  #
  # It only fires when there is something to do. Without that condition an install
  # whose Immich backup job is broken would log an ERROR and exit 1 every night it
  # had nothing to archive — noise in a log that has to stay readable, and noise
  # ends up hiding the signal.
  #
  # Refusing to resume is safe: every state an entry can be parked in is a safe
  # one. At `copie` the file is at the destination and the database still points
  # at the source; at `base_a_jour` the database points at the copy and the source
  # is still on disk. Nothing is lost by waiting for a dump.
  #
  # A dry run is exempt, as before: it writes nothing, and test_run must keep
  # previewing candidates.
  if "$will_archive" || "$has_unfinished"; then
    if ! "$dry_run" && ! _recent_usable_dump; then
      log_error "No recent, usable DB backup (<7 days) in $IMMICH_UPLOAD_LOCATION/backups — nothing was archived and no unfinished run was resumed."
      log_error "Immich writes its dumps there; check its backup job before archiving again."
      release_lock
      return 1
    fi
  fi

  # Deliberately outside the gate: deleting old `.done` journals is the documented
  # retention of finished runs, it touches no photo and no row, and a run refused
  # for want of a dump must not stop doing its housekeeping. Still skipped in a
  # dry run, which writes nothing at all.
  "$dry_run" || runlog_rotate

  # Phase one of every real run: finish what earlier runs started. It comes before
  # the thresholds are acted on, because a half-archived asset is a liability
  # whether or not the library is over its limit today. It is deliberately not a
  # reason to refuse a fresh archive either: the moment the disk fills up is exactly
  # when the tool has to keep working.
  if "$dry_run"; then
    local pending blocked divergent unreadable nfiles
    # The sixth field, the oldest run's id, is not used here — status reports it.
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
    # Reconciliation ran just above and may well have parked something terminal.
    # A run that ends here has still produced that, so it reports it.
    if (( ARCHIVE_TERMINAL_COUNT > 0 )); then
      log_error "$ARCHIVE_TERMINAL_COUNT asset(s) ended this run blocked or divergent — each one needs a decision. See: immich-auto-dumper status"
      return 1
    fi
    return 0
  fi

  local bytes_to_free=$(( lib_bytes - target_bytes ))

  log_info "Need to free $(bytes_to_human "$bytes_to_free") — selecting oldest directories first:"

  # Opened only now that there is actually something to archive: a journal file per
  # nightly no-op run would push the ones that matter out of the retention window.
  #
  # And no longer `|| true`. A run used to archive for real with no journal at
  # all — no resumption, no `rollback`, rc=0, a single WARN for the whole thing.
  # A $LOG_DIR/runs that cannot be written is not a permissions detail: it points
  # at a problem on the disk that carries both this script and Immich — full,
  # remounted read-only, failing. Moving photos at that moment is exactly what
  # must not happen, so the run stops before touching anything.
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
  # Directories the database refused to list. Reported at the end rather than
  # left to be inferred from scrolling back through the log.
  local dirs_failed=0

  # Capture, check, THEN iterate — never iterate a process substitution.
  # `while … done < <(db_get_archive_candidates)` threw away the function's exit
  # code: _db_exec answers 2 when psql could not run, but the loop simply saw no
  # rows and the run reported "Archive complete. Freed: 0 B." with rc=0. A
  # database that stops answering after check_prereqs is indistinguishable from
  # "nothing left to archive" — the library quietly stops being archived and the
  # cron reports success every night. That is the 11 September failure family.
  #
  # Iterating an array also leaves stdin alone, which is why _config_check and
  # _setup already do it this way.
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

    # Same treatment for the inner query, where the failure is per-directory: log
    # it, count the directory as not processed, and above all do not announce it
    # as archived.
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
      # The third field, Immich's own fileSizeInByte, is only good enough to
      # sort the candidates; what a move actually frees is read off the disk.
      IFS="$DB_FIELD_SEP" read -r asset_id original_path_db _ <<< "$arow"
      [[ -z "$asset_id" ]] && continue

      # Already spoken for by an unfinished run: reconciliation above owns it.
      # Taking it again here would open a parallel entry with a fresh attempt
      # counter, and the ceiling that parks a hopeless asset would never bite.
      #
      # Counted, not merely skipped. When a journal held EVERY asset of a
      # directory the inner loop never ran, both counters stayed at zero, and the
      # report read "all 0 asset(s) failed" — an error announced where nothing
      # had even been attempted, which is F9's mistake the other way round.
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
      # What the filesystem lost, not what Immich's metadata claims the file
      # weighs. file_size is only good enough to sort the candidates.
      dir_freed=$((   dir_freed   + ARCHIVE_LAST_FREED_BYTES ))
      freed_bytes=$(( freed_bytes + ARCHIVE_LAST_FREED_BYTES ))
    done

    # "Directory archived" used to be printed whatever happened, so a directory
    # whose every asset had just failed was reported, at INFO, as archived — with
    # its full size, as if that space had been freed. Say what actually happened.
    local held_note=""
    (( dir_held > 0 )) && held_note=" ($dir_held more held by an unfinished run)"
    if "$dry_run"; then
      log_info "DRY-RUN: would archive directory: $parent_dir — $(bytes_to_human "$dir_freed") ($dir_ok asset(s))${held_note}"
    elif (( dir_ok == 0 && dir_ko == 0 && dir_held > 0 )); then
      # Nothing was tried here: every asset belongs to a journal that is waiting
      # on something. That is not a failure, and calling it one sent people
      # looking for a fault that did not exist.
      log_warn "Directory left alone: $parent_dir — $dir_held asset(s) held by an unfinished run awaiting a decision. See: immich-auto-dumper status"
    elif (( dir_ok == 0 && dir_ko == 0 )); then
      log_info "Nothing left to archive in $parent_dir."
    elif (( dir_ok == 0 )); then
      log_error "Directory NOT archived: $parent_dir — all $dir_ko asset(s) failed.${held_note}"
    elif (( dir_ko > 0 )); then
      log_warn "Directory partially archived: $parent_dir — $dir_ok done ($(bytes_to_human "$dir_freed") freed), $dir_ko failed.${held_note}"
    else
      # The size reported is the one the disk gave up, not the one the metadata
      # advertised: with the exif rows missing the latter reads "0 B" for a
      # directory that just freed hundreds of kilobytes.
      log_info "Directory archived: $parent_dir — $(bytes_to_human "$dir_freed") freed ($dir_ok asset(s))${held_note}"
    fi

    # Checked only after completing the current directory, never mid-directory —
    # and checked by MEASURING the library again rather than by adding up what
    # Immich says its files weigh. With the exif rows missing, those sizes summed
    # to zero, the stopping condition was never met, and a run asked to free 178 KB
    # moved 1.2 MB: every directory there was.
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

  # A simulation must never log a line that reads as work done: `status` reports the
  # last "Archive complete" as history, so an unmarked dry run used to show an
  # archive that never happened, along with space it never freed.
  if "$dry_run"; then
    log_info "DRY-RUN: would free $(bytes_to_human "$freed_bytes") in total. Nothing was moved.${unread_note}"
    return 0
  fi

  log_info "Archive complete. Freed: $(bytes_to_human "$freed_bytes").${unread_note}"

  # The exit code says whether this run left something that needs a person. It is
  # not an alert channel — the log is, and it is precise and timestamped. What it
  # buys is an exact status something else can be built on, and alignment with
  # archive_rollback, which already exits non-zero when it refused anything.
  if (( ARCHIVE_TERMINAL_COUNT > 0 )); then
    log_error "$ARCHIVE_TERMINAL_COUNT asset(s) ended this run blocked or divergent — each one needs a decision. See: immich-auto-dumper status"
    return 1
  fi
  # A directory the database would not list is the same family of failure as the
  # candidate list refusing to answer, which already ends the run non-zero.
  (( dirs_failed == 0 ))
}
