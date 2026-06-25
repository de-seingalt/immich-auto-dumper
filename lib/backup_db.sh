#!/usr/bin/env bash
set -euo pipefail

backup_db_run() {
  local dry_run=false
  [[ "${1:-}" == "--dry-run" ]] && dry_run=true

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
      log_info "DRY-RUN: would copy $(basename "$src") → $dest_dir/"
    done
    log_info "DRY-RUN: would apply retention policy (keep $BACKUP_RETENTION database archive files)"
    return 0
  fi

  mkdir -p "$dest_dir"

  for src in "${files[@]}"; do
    local filename
    filename=$(basename "$src")
    cp "$src" "$dest_dir/$filename"
    log_info "Backup copied: $filename"
  done

  # Retention: delete oldest files beyond BACKUP_RETENTION.
  local all_backups=()
  while IFS= read -r -d '' f; do
    all_backups+=("$f")
  done < <(find "$dest_dir" -maxdepth 1 -type f -print0 | xargs -0 ls -t --zero)

  local count=${#all_backups[@]}
  if (( count > BACKUP_RETENTION )); then
    local to_delete=$(( count - BACKUP_RETENTION ))
    for (( i = count - to_delete; i < count; i++ )); do
      log_info "Rotation: removing $(basename "${all_backups[$i]}")"
      rm -f "${all_backups[$i]}"
    done
  fi

  local kept=()
  while IFS= read -r -d '' f; do
    kept+=("$f")
  done < <(find "$dest_dir" -maxdepth 1 -type f -print0)

  local total_bytes=0
  for f in "${kept[@]}"; do
    local size
    size=$(stat --format='%s' "$f")
    total_bytes=$(( total_bytes + size ))
  done

  log_info "DB backup: ${#kept[@]} file(s) retained, $(bytes_to_human "$total_bytes") total."
}
