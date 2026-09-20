#!/usr/bin/env bash
set -euo pipefail

backup_db_run() {
  local dry_run=false
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry_run=true ;;
      # Same reasoning as archive_run: a flag that is not recognised is a typo, and
      # the previous test (only ever comparing $1 to --dry-run) turned a misspelled
      # "--dryrun" into a real run.
      *)
        log_error "Unknown argument for the backup run: '$arg' — nothing was done."
        return 1
        ;;
    esac
  done

  # Retention decides how many mirrored dumps survive the run, so an unusable value
  # is checked BEFORE anything is copied — and before the dry run reports on a
  # policy it could not apply. An empty or zero value deleted every dump on the
  # external storage and logged it at INFO, which a cron mail reads as a success;
  # a non-numeric one crashed mid-rotation. This value is also re-read from disk
  # between runs, so validating it at load time alone would not cover a hand edit.
  #
  # Refusing the whole run is deliberate. Copying while the rotation is broken piles
  # dumps up for ever, and an invalid retention means the configuration needs fixing,
  # not that a default should quietly stand in for it.
  local retention="${BACKUP_RETENTION:-}"
  if ! [[ "$retention" =~ ^[1-9][0-9]*$ ]]; then
    log_error "BACKUP_RETENTION must be a whole number of dumps to keep, 1 or more (found '${retention}')."
    log_error "Nothing was copied or deleted. Fix it in config.conf — run: immich-auto-dumper setup"
    return 1
  fi

  check_prereqs

  # Storage availability — agnostic to the storage type (marker-based).
  # Note: we intentionally do NOT run the path-consistency guard here — mirroring
  # DB dumps stays useful (and safe, it never touches the Immich DB) even while an
  # external library path change is being resolved.
  if ! check_archive_dest_ready; then
    return 0
  fi

  local src_dir="$IMMICH_UPLOAD_LOCATION/backups"
  if [[ ! -d "$src_dir" ]]; then
    log_warn "Backup source directory not found: $src_dir"
    return 0
  fi

  # Skip hidden marker files (e.g. Immich's `.immich`) — only mirror real dumps.
  local files=()
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
      dr_src_size=$(stat --format='%s' "$src")
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

  # Mirroring took no lock at all, so two overlapping `sync_now` could run `cp`
  # onto the same destination file and rotate the same directory underneath each
  # other. The dry run above needs none — it writes nothing.
  if ! acquire_lock; then
    return 0
  fi

  mkdir -p "$dest_dir"

  # Dumps are immutable and their name carries their timestamp, so a destination file
  # of the same size IS the same dump, already mirrored. Skipping it keeps each run
  # proportional to what is actually new instead of re-uploading the whole retention
  # window every time — which on a metered or write-back mount is the difference
  # between a few MB and a full GB, and avoids rewriting files the storage may still
  # be flushing from the previous run.
  local copied=0 skipped=0
  for src in "${files[@]}"; do
    local filename src_size dst_size
    filename=$(basename "$src")
    src_size=$(stat --format='%s' "$src")
    dst_size=$(stat --format='%s' "$dest_dir/$filename" 2>/dev/null || echo -1)

    if [[ "$dst_size" == "$src_size" ]]; then
      skipped=$(( skipped + 1 ))
      continue
    fi
    # Present but a different size: a previous copy was truncated (interrupted run,
    # full storage, cancelled upload). Overwrite it rather than keep a corrupt dump.
    if (( dst_size >= 0 )); then
      log_warn "Re-copying $filename: size mismatch (local $src_size B, storage $dst_size B)"
    fi

    cp "$src" "$dest_dir/$filename"
    log_info "Backup copied: $filename"
    copied=$(( copied + 1 ))
  done

  if (( skipped > 0 )); then
    log_info "Backup: $skipped file(s) already mirrored, $copied copied."
  fi

  # Retention: keep the newest BACKUP_RETENTION dumps, delete the rest.
  #
  # Ordering is by FILENAME, never by mtime. Dump names start with an ISO-like
  # timestamp (immich-db-backup-YYYYMMDDTHHMMSS-...), so lexicographic order is
  # chronological order — and unlike mtime, it cannot be misreported by the storage.
  # On a write-back mount (rclone --vfs-write-back, NFS async...) a file whose upload
  # is still pending has no known modification time and the mount answers with a
  # placeholder date. An mtime-based rotation then sees the dumps it has just copied
  # as the oldest on the volume and deletes them, cancelling their upload in flight.
  local all_backups=()
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
    size=$(stat --format='%s' "$f")
    total_bytes=$(( total_bytes + size ))
  done

  release_lock

  log_info "DB backup: ${#kept[@]} file(s) retained, $(bytes_to_human "$total_bytes") total."
}
