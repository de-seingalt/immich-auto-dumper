#!/usr/bin/env bash
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
archive_build_dest_path() {
  local src_host_path="$1"
  local library_prefix="$IMMICH_UPLOAD_LOCATION/library/"

  local relative="${src_host_path#"$library_prefix"}"
  local user_folder="${relative%%/*}"
  local rest="${relative#"$user_folder/"}"

  local mapped_name="${USER_MAP["$user_folder"]:-$user_folder}"

  printf '%s/%s/%s\n' "$ARCHIVE_DEST_PATH" "$mapped_name" "$rest"
}

# ── File move helpers ─────────────────────────────────────────────────────────

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

  local try=$(( attempts + 1 ))
  # Records the entry as it now stands and gives back the right return code. An
  # entry that has used up its tries is parked rather than retried every night.
  # Defined here on purpose: bash scopes dynamically, so it reads the caller's
  # locals instead of taking ten arguments that would only ever be those.
  _park() {
    local etat="$1"
    if [[ "$etat" != "divergent" && "$etat" != "abandonne" ]] && (( try >= RUNLOG_MAX_ATTEMPTS )); then
      log_error "Asset $asset_id has failed $try times — parked as blocked, it will not be retried."
      runlog_record "" "$asset_id" bloque "$try" "$size" "$sha" "$src_host" "$src_db" "$dst_host" "$dst_db"
      return 2
    fi
    runlog_record "" "$asset_id" "$etat" "$try" "$size" "$sha" "$src_host" "$src_db" "$dst_host" "$dst_db"
    case "$etat" in
      divergent|abandonne) return 2 ;;
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

  # ── → copie ─────────────────────────────────────────────────────────────────
  if [[ -z "$state" || "$state" == "prevu" ]]; then
    runlog_record "" "$asset_id" prevu "$try" "$size" "$sha" "$src_host" "$src_db" "$dst_host" "$dst_db"

    local need_copy=true
    if [[ -e "$dst_host" ]]; then
      # Concluding "already archived" means skipping the copy, pointing the database
      # at this file and deleting the source. Size equality was the proof, and it is
      # not one: a foreign file of the same byte count was accepted and the original
      # photo deleted in its favour. Only a matching fingerprint earns it.
      #
      # The call must not be bare: files_are_identical answers 1 and 2 for cases we
      # handle, and under `set -e` a bare call would abort the whole run instead.
      local identical=0
      files_are_identical "$src_host" "$dst_host" || identical=$?
      case $identical in
        0) log_warn "Already at destination, identity verified: $dst_host — updating DB only."
           need_copy=false ;;
        1) log_error "Destination exists with DIFFERENT content: $dst_host"
           log_error "Another file already occupies that path — asset skipped, source kept."
           log_error "Two users mapped to the same folder in USER_MAP is the usual cause."
           _park prevu; return $? ;;
        *) log_error "Cannot compare source and destination: $dst_host — asset skipped, source kept."
           log_error "One of the two files is unreadable; the storage may be down."
           _park prevu; return $? ;;
      esac
    fi

    if "$need_copy"; then
      mkdir -p "$(dirname "$dst_host")" 2>/dev/null || true
      # A failed or interrupted cp (full disk, dead mount) can leave a PARTIAL file
      # that a mere existence check would accept — and the source would then be
      # deleted. Both the exit code and the copied content are checked before
      # anything irreversible happens.
      if ! cp "$src_host" "$dst_host"; then
        log_error "Copy failed: $src_host → $dst_host"
        rm -f "$dst_host"
        _park prevu; return $?
      fi
      local copied=0
      files_are_identical "$src_host" "$dst_host" || copied=$?
      if (( copied != 0 )); then
        log_error "The copy does not match its source: $dst_host — removed, asset skipped."
        rm -f "$dst_host"
        _park prevu; return $?
      fi
    fi

    runlog_record "" "$asset_id" copie "$try" "$size" "$sha" "$src_host" "$src_db" "$dst_host" "$dst_db"
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

    runlog_record "" "$asset_id" base_a_jour "$try" "$size" "$sha" "$src_host" "$src_db" "$dst_host" "$dst_db"
    state="base_a_jour"
  fi

  # ── base_a_jour → source_supprimee ──────────────────────────────────────────
  if [[ "$state" == "base_a_jour" ]]; then
    if ! _archive_remove_source "$src_host" "$src_db" "$sha"; then
      # The archive itself succeeded: the asset points at the copy and is readable.
      # Only the cleanup is outstanding, so the entry stays pending rather than
      # being treated as a failure of the move.
      _park base_a_jour; return $?
    fi
    runlog_record "" "$asset_id" source_supprimee "$try" "$size" "$sha" "$src_host" "$src_db" "$dst_host" "$dst_db"
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

  local dst_host
  dst_host=$(archive_build_dest_path "$src_host_path")
  local dst_db="${dst_host/#"$ARCHIVE_DEST_PATH"/"$ARCHIVE_CONTAINER_PATH"}"
  local src_db
  src_db=$(host_path_to_db_path "$src_host_path")

  if "$dry_run"; then
    if [[ -e "$dst_host" ]]; then
      local identical=0
      files_are_identical "$src_host_path" "$dst_host" || identical=$?
      case $identical in
        0) log_info "DRY-RUN: would UPDATE DB only for asset $asset_id → $dst_db (identical copy already there)" ;;
        1) log_warn "DRY-RUN: destination already holds a DIFFERENT file — the real run would SKIP this asset: $dst_host" ;;
        *) log_warn "DRY-RUN: cannot compare source and destination — the real run would SKIP this asset: $dst_host" ;;
      esac
    else
      log_info "DRY-RUN: would copy $src_host_path → $dst_host"
      log_info "DRY-RUN: would UPDATE asset $asset_id originalPath → $dst_db"
    fi
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
archive_reconcile() {
  local -a files=()
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
        runlog_record "" "$asset" bloque "$attempts" "$size" "$sha" "$src" "$src_db" "$dst" "$dst_db"
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

  log_info "Resume: $resumed completed, $skipped postponed to the next run, $stuck needing attention."
  return 0
}

# ── Rollback ──────────────────────────────────────────────────────────────────

# Copies a file back INTO the library through the container, which owns it, and
# verifies the result by reading it back out. Only `cat` is assumed to exist in
# the Immich image. 0 restored and verified, 1 otherwise.
_archive_restore_file() {
  local dst_host="$1" src_db="$2" expected_sha="$3"

  if ! $DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" \
         mkdir -p "$(dirname "$src_db")" </dev/null; then
    log_error "Could not create the library folder inside the container: $(dirname "$src_db")"
    return 1
  fi
  if ! $DOCKER_CMD exec -i "$IMMICH_SERVER_CONTAINER" \
         sh -c 'cat > "$1"' _ "$src_db" < "$dst_host"; then
    log_error "Could not write the file back into the library: $src_db"
    return 1
  fi
  local back
  back=$($DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" cat -- "$src_db" </dev/null \
         | sha256sum | cut -d' ' -f1) || back=""
  if [[ "$back" != "$expected_sha" ]]; then
    log_error "The restored file does not match its recorded fingerprint: $src_db"
    log_error "Nothing else was changed; the external copy is still in place."
    return 1
  fi
  return 0
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
  runlog_open "rollback" || true

  local asset etat attempts size sha src src_db dst dst_db
  local undone=0 refused=0
  while IFS="$RUNLOG_SEP" read -r asset etat attempts size sha src src_db dst dst_db; do
    [[ -n "$asset" ]] || continue
    if [[ "$etat" == "illisible" ]]; then
      log_error "Entry for asset $asset cannot be read — skipped."
      refused=$(( refused + 1 )); continue
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

    if ! _archive_restore_file "$dst" "$src_db" "$sha"; then
      refused=$(( refused + 1 )); continue
    fi
    if ! db_update_asset_path "$asset" "$src_db"; then
      log_error "File restored but the database could not be pointed back at it: $src_db"
      log_error "The external copy is KEPT so the asset still has a file behind it."
      refused=$(( refused + 1 ))
      runlog_record "" "$asset" divergent 1 "$size" "$sha" "$src" "$src_db" "$dst" "$dst_db"
      continue
    fi
    rm -f -- "$dst"
    runlog_record "" "$asset" source_supprimee 1 "$size" "$sha" "$dst" "$dst_db" "$src" "$src_db"
    undone=$(( undone + 1 ))
  done < <(runlog_read "$file")

  runlog_close
  runlog_rotate
  release_lock

  log_info "Rollback of $(basename "$file"): $undone asset(s) brought back, $refused refused."
  (( refused == 0 ))
}

# Moves sidecar files (XMP, JSON) alongside an asset to external storage.
# Sidecars are not tracked in the DB — filesystem-only operation.
_archive_move_sidecar() {
  local src_host_path="$1"
  local dry_run="${2:-false}"

  local base="${src_host_path%.*}"
  local candidates=(
    "${src_host_path}.xmp"
    "${src_host_path}.json"
    "${base}.xmp"
    "${base}.json"
  )

  for sidecar in "${candidates[@]}"; do
    [[ -f "$sidecar" ]] || continue

    local dst_sidecar
    dst_sidecar=$(archive_build_dest_path "$sidecar")

    if "$dry_run"; then
      log_info "DRY-RUN: would move sidecar $sidecar → $dst_sidecar"
      continue
    fi

    mkdir -p "$(dirname "$dst_sidecar")"
    if cp "$sidecar" "$dst_sidecar" && stat "$dst_sidecar" &>/dev/null; then
      # Same ownership constraint as the asset: remove the source via the container.
      $DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" rm -f "$(host_path_to_db_path "$sidecar")" </dev/null \
        || log_warn "Sidecar copied but could not remove source: $sidecar"
    else
      log_warn "Failed to move sidecar: $sidecar"
    fi
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

archive_run() {
  local dry_run=false force=false
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

  # Phase one of every real run: finish what earlier runs started. It comes BEFORE
  # the thresholds are even looked at, because a half-archived asset is a liability
  # whether or not the library is over its limit today. It is deliberately not a
  # reason to refuse a fresh archive either: the moment the disk fills up is exactly
  # when the tool has to keep working.
  if "$dry_run"; then
    local pending blocked divergent unreadable nfiles oldest
    read -r pending blocked divergent unreadable nfiles oldest < <(runlog_summary)
    if (( nfiles > 0 )); then
      log_info "DRY-RUN: $nfiles earlier run(s) left work behind ($pending to resume, $blocked blocked, $divergent divergent, $unreadable unreadable); a real run would resume them first."
    fi
  else
    archive_reconcile
    # Rotated here too: most nightly runs end a few lines below with "nothing to
    # archive", and would otherwise never get round to it.
    runlog_rotate
  fi

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

  if "$force"; then
    # Manual forced dump: bypass the MAX trigger but still respect the target floor.
    log_info "Forced archive: ignoring MAX threshold, archiving down to target $(bytes_to_human "$target_bytes")."
    if (( lib_bytes <= target_bytes )); then
      log_info "Library already at or below target — nothing to archive."
      release_lock
      return 0
    fi
  else
    if (( max_bytes <= 0 )); then
      log_error "Archive size limit is not configured — run: immich-auto-dumper setup"
      release_lock
      return 1
    fi
    if (( lib_bytes <= max_bytes )) && ! "$low_free_disk"; then
      log_info "Library within limit (max $(bytes_to_human "$max_bytes")) and free disk above floor — nothing to archive."
      release_lock
      return 0
    fi
    if (( lib_bytes > max_bytes )); then
      log_info "Archive triggered: library exceeds max $(bytes_to_human "$max_bytes")."
    else
      log_info "Archive triggered: free disk ($(bytes_to_human "$disk_free_bytes_now")) below safety floor ($(bytes_to_human "$min_free_bytes")), even though the library is within its max."
    fi
  fi

  # Safety: never modify the database unless a recent (<7 days) Immich DB backup
  # exists. Archiving rewrites "originalPath" rows, so a fresh dump is the safety net.
  # Skipped in dry-run: it writes nothing, and test_run must still preview candidates.
  if ! "$dry_run" && ! find "$IMMICH_UPLOAD_LOCATION/backups" -type f -mtime -7 2>/dev/null | grep -q .; then
    log_error "No recent DB backup (<7 days) in $IMMICH_UPLOAD_LOCATION/backups — archive aborted."
    release_lock
    return 1
  fi

  local bytes_to_free=$(( lib_bytes - target_bytes ))

  log_info "Need to free $(bytes_to_human "$bytes_to_free") — selecting oldest directories first:"

  # Opened only now that there is actually something to archive: a journal file per
  # nightly no-op run would push the ones that matter out of the retention window.
  "$dry_run" || runlog_open "run" || true

  local freed_bytes=0

  while IFS='|' read -r user_folder parent_dir folder_size; do
    [[ -z "$user_folder" ]] && continue

    log_info "Candidate directory: $parent_dir (user: $user_folder, $(bytes_to_human "${folder_size:-0}"))"

    local dir_ok=0 dir_ko=0
    while IFS='|' read -r asset_id original_path_db file_size; do
      [[ -z "$asset_id" ]] && continue

      local src_host
      src_host=$(db_path_to_host_path "$original_path_db")

      if ! _archive_move_file "$asset_id" "$src_host" "db_update_asset_path" "$dry_run"; then
        log_error "Asset skipped: $asset_id ($original_path_db)"
        dir_ko=$(( dir_ko + 1 ))
        continue
      fi

      _archive_move_sidecar "$src_host" "$dry_run" || true

      dir_ok=$(( dir_ok + 1 ))
      freed_bytes=$(( freed_bytes + ${file_size:-0} ))
    done < <(db_get_folder_assets "$parent_dir")

    # "Directory archived" used to be printed whatever happened, so a directory
    # whose every asset had just failed was reported, at INFO, as archived — with
    # its full size, as if that space had been freed. Say what actually happened.
    if "$dry_run"; then
      log_info "DRY-RUN: would archive directory: $parent_dir — $(bytes_to_human "${folder_size:-0}") ($dir_ok asset(s))"
    elif (( dir_ok == 0 )); then
      log_error "Directory NOT archived: $parent_dir — all $dir_ko asset(s) failed."
    elif (( dir_ko > 0 )); then
      log_warn "Directory partially archived: $parent_dir — $dir_ok done, $dir_ko failed."
    else
      log_info "Directory archived: $parent_dir — $(bytes_to_human "${folder_size:-0}") ($dir_ok asset(s))"
    fi

    # Check threshold only after completing the current directory, never mid-directory.
    if (( freed_bytes >= bytes_to_free )); then
      break
    fi
  done < <(db_get_archive_candidates)

  if ! "$dry_run"; then
    runlog_close
    runlog_rotate
  fi
  release_lock
  # A simulation must never log a line that reads as work done: `status` reports the
  # last "Archive complete" as history, so an unmarked dry run used to show an
  # archive that never happened, along with space it never freed.
  if "$dry_run"; then
    log_info "DRY-RUN: would free $(bytes_to_human "$freed_bytes") in total. Nothing was moved."
  else
    log_info "Archive complete. Freed: $(bytes_to_human "$freed_bytes")."
  fi
}
