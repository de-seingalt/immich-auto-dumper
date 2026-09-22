#!/usr/bin/env bash
set -euo pipefail

# Mirrors Immich's database dumps to <storage>/.immich-backup/ and rotates the
# copies down to BACKUP_RETENTION. Never reads or writes the Immich database.
backup_db_run() {
  local dry_run=false
  local arg src i
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=true ;;
      # An unrecognised flag ends the run rather than being dropped.
      *)
        log_error "Unknown argument for the backup run: '$arg' — nothing was done."
        return 1
        ;;
    esac
  done

  # Retention is validated before anything is copied, and an unusable value ends
  # the whole run — including a dry run, which would otherwise report on a policy
  # it cannot apply. No default stands in for it.
  local retention="${BACKUP_RETENTION:-}"
  if ! [[ "$retention" =~ ^[1-9][0-9]*$ ]]; then
    log_error "BACKUP_RETENTION must be a whole number of dumps to keep, 1 or more (found '${retention}')."
    log_error "Nothing was copied or deleted. Fix it in config.conf — run: immich-auto-dumper setup"
    return 1
  fi

  check_prereqs

  # Storage availability, read off the marker. Absent storage ends the run
  # quietly; a state that cannot be established exits non-zero. The
  # path-consistency guard is not run here.
  local dest_state=0
  check_archive_dest_ready || dest_state=$?
  case $dest_state in
    0) ;;
    1) return 0 ;;
    *) return 1 ;;
  esac

  local src_dir="$IMMICH_UPLOAD_LOCATION/backups"
  if [[ ! -d "$src_dir" ]]; then
    log_warn "Backup source directory not found: $src_dir"
    return 0
  fi

  # Hidden files are skipped: only real dumps are mirrored.
  local files=()
  local f
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$src_dir" -maxdepth 1 -type f ! -name '.*' -print0)

  if (( ${#files[@]} == 0 )); then
    log_warn "No backup files found in $src_dir."
    return 0
  fi

  local dest_dir="$ARCHIVE_DEST_PATH/.immich-backup"

  if "$dry_run"; then
    log_info "DRY-RUN: would create $dest_dir if missing"
    for src in "${files[@]}"; do
      local dr_name dr_src_size dr_dst_size
      dr_name=$(basename "$src")
      # A dump can vanish between the listing and here.
      dr_src_size=$(stat --format='%s' "$src" 2>/dev/null || echo -1)
      if (( dr_src_size < 0 )); then
        log_info "DRY-RUN: would skip $dr_name (it has gone since the listing)"
        continue
      fi
      dr_dst_size=$(stat --format='%s' "$dest_dir/$dr_name" 2>/dev/null || echo -1)
      if [[ "$dr_dst_size" == "$dr_src_size" ]]; then
        log_info "DRY-RUN: would skip $dr_name (already mirrored)"
      else
        log_info "DRY-RUN: would copy $dr_name → $dest_dir/"
      fi
    done
    log_info "DRY-RUN: would apply retention policy (keep $retention database archive files)"
    return 0
  fi

  # Taken here and not above: the dry run writes nothing and needs no lock.
  if ! acquire_lock; then
    return 0
  fi

  # Bare, this aborted the whole command under `set -e` while holding the lock,
  # with nothing said about why. There is no copy to make without the directory,
  # so it is a clean refusal rather than a warning.
  if ! mkdir -p "$dest_dir" 2>/dev/null; then
    log_error "Cannot create the destination folder for the database dumps: $dest_dir"
    release_lock
    return 1
  fi

  # A destination of the same size counts as the same dump, already mirrored, and
  # is left alone. A size comparison and not a fingerprint: nothing is deleted on
  # the strength of this answer. The copy this run makes is fingerprinted below.
  local copied=0 skipped=0
  for src in "${files[@]}"; do
    local filename src_size dst_size
    filename=$(basename "$src")
    # A dump listed a moment ago can be gone by the time it is measured: -1 marks
    # it and it is skipped, rather than being read as a size of zero.
    src_size=$(stat --format='%s' "$src" 2>/dev/null || echo -1)
    if (( src_size < 0 )); then
      log_warn "Dump vanished before it could be copied (Immich's own rotation?), skipped: $filename"
      continue
    fi
    dst_size=$(stat --format='%s' "$dest_dir/$filename" 2>/dev/null || echo -1)

    if [[ "$dst_size" == "$src_size" ]]; then
      skipped=$(( skipped + 1 ))
      continue
    fi
    # Present with a different size: a truncated copy, overwritten.
    if (( dst_size >= 0 )); then
      log_warn "Re-copying $filename: size mismatch (local $src_size B, storage $dst_size B)"
    fi

    if ! cp -p "$src" "$dest_dir/$filename"; then
      log_error "Failed to copy $filename to the external storage."
      rm -f "$dest_dir/$filename"
      continue
    fi
    # Flushed, then proved identical to the dump before it counts as mirrored.
    file_flush "$dest_dir/$filename"
    local same=0
    files_are_identical "$src" "$dest_dir/$filename" || same=$?
    if (( same != 0 )); then
      log_error "The copy of $filename does not match the dump — removed, not counted as mirrored."
      rm -f "$dest_dir/$filename"
      continue
    fi
    log_info "Backup copied: $filename"
    copied=$(( copied + 1 ))
  done

  if (( skipped > 0 )); then
    log_info "Backup: $skipped file(s) already mirrored, $copied copied."
  fi

  # Retention: keep the newest BACKUP_RETENTION dumps, delete the rest. Ordered by
  # FILENAME, never by mtime — dump names begin with a timestamp, so lexicographic
  # order is chronological order.
  local all_backups=()
  local f
  while IFS= read -r -d '' f; do
    all_backups+=("$f")
  done < <(find "$dest_dir" -maxdepth 1 -type f ! -name '.*' -print0 | LC_ALL=C sort -z)

  local count=${#all_backups[@]}
  if (( count > retention )); then
    local to_delete=$(( count - retention ))
    # Oldest first after the sort: delete the head, keep the tail.
    for (( i = 0; i < to_delete; i++ )); do
      log_info "Rotation: removing $(basename "${all_backups[$i]}")"
      rm -f "${all_backups[$i]}"
    done
  fi

  local kept=()
  while IFS= read -r -d '' f; do
    kept+=("$f")
  done < <(find "$dest_dir" -maxdepth 1 -type f ! -name '.*' -print0)

  local total_bytes=0
  for f in "${kept[@]}"; do
    local size
    # A file gone since the listing contributes nothing to the total.
    size=$(stat --format='%s' "$f" 2>/dev/null || echo 0)
    total_bytes=$(( total_bytes + size ))
  done

  release_lock

  log_info "DB backup: ${#kept[@]} file(s) retained, $(bytes_to_human "$total_bytes") total."
}
