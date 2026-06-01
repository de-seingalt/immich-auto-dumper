#!/usr/bin/env bash
set -euo pipefail

backup_db_run() {
  check_prereqs

  if ! check_archive_dest_mounted; then
    log_warn "Stockage externe non monté ($ARCHIVE_DEST_PATH) — backup BDD ignoré."
    return 0
  fi

  local src_dir="$IMMICH_UPLOAD_LOCATION/backups"
  if [[ ! -d "$src_dir" ]]; then
    log_warn "Dossier source introuvable : $src_dir"
    return 0
  fi

  local files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find "$src_dir" -maxdepth 1 -type f -print0)

  if (( ${#files[@]} == 0 )); then
    log_warn "Aucun fichier de backup dans $src_dir."
    return 0
  fi

  local dest_dir="$ARCHIVE_DEST_PATH/.immich-backup"
  mkdir -p "$dest_dir"

  for src in "${files[@]}"; do
    local filename
    filename=$(basename "$src")
    cp "$src" "$dest_dir/$filename"
    log_info "Backup copié : $filename"
  done

  # Rotation : supprime les fichiers les plus anciens au-delà de BACKUP_RETENTION.
  local all_backups=()
  while IFS= read -r -d '' f; do
    all_backups+=("$f")
  done < <(find "$dest_dir" -maxdepth 1 -type f -print0 | xargs -0 ls -t --zero)

  local count=${#all_backups[@]}
  if (( count > BACKUP_RETENTION )); then
    local to_delete=$(( count - BACKUP_RETENTION ))
    for (( i = count - to_delete; i < count; i++ )); do
      log_info "Rotation : suppression de $(basename "${all_backups[$i]}")"
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

  log_info "Backup BDD : ${#kept[@]} fichier(s) conservé(s), $(bytes_to_human "$total_bytes") au total."
}
