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

# Moves one asset file to external storage and updates its DB path.
# If destination already exists with the same size, treats it as already archived
# (updates DB + removes source, no copy). If sizes differ, logs error and returns 1.
# Returns 0 on success, 1 on any unrecoverable error.
_archive_move_file() {
  local asset_id="$1"
  local src_host_path="$2"
  local update_fn="$3"
  local dry_run="${4:-false}"

  local dst_host
  dst_host=$(archive_build_dest_path "$src_host_path")
  local dst_db="${dst_host/#"$ARCHIVE_DEST_PATH"/"$ARCHIVE_CONTAINER_PATH"}"

  local already_archived=false

  if [[ -e "$dst_host" ]]; then
    local src_size dst_size
    src_size=$(stat --format='%s' "$src_host_path" 2>/dev/null || echo 0)
    dst_size=$(stat --format='%s' "$dst_host" 2>/dev/null || echo 0)

    if [[ "$src_size" == "$dst_size" ]]; then
      log_warn "Already at destination (same size): $dst_host — updating DB only."
      already_archived=true
    else
      log_error "Conflict: destination exists with different size: $dst_host (src=${src_size}B dst=${dst_size}B)"
      return 1
    fi
  fi

  if "$dry_run"; then
    if "$already_archived"; then
      log_info "DRY-RUN: would UPDATE DB only for asset $asset_id → $dst_db"
    else
      log_info "DRY-RUN: would copy $src_host_path → $dst_host"
      log_info "DRY-RUN: would UPDATE asset $asset_id originalPath → $dst_db"
    fi
    return 0
  fi

  if ! "$already_archived"; then
    mkdir -p "$(dirname "$dst_host")"
    # A failed or interrupted cp (full disk, dead mount) can leave a PARTIAL file
    # that a mere existence check would accept — and the source would then be
    # deleted. Verify the exit code AND that the copied size matches the source
    # before anything irreversible happens.
    if ! cp "$src_host_path" "$dst_host"; then
      log_error "Copy failed: $src_host_path → $dst_host"
      rm -f "$dst_host"
      return 1
    fi
    local copied_src_size copied_dst_size
    copied_src_size=$(stat --format='%s' "$src_host_path" 2>/dev/null || echo -1)
    copied_dst_size=$(stat --format='%s' "$dst_host" 2>/dev/null || echo -2)
    if [[ "$copied_src_size" != "$copied_dst_size" ]]; then
      log_error "Size mismatch after copy (src=${copied_src_size}B dst=${copied_dst_size}B): $dst_host"
      rm -f "$dst_host"
      return 1
    fi
  fi

  if ! "$update_fn" "$asset_id" "$dst_db"; then
    log_error "DB update failed (asset $asset_id): $dst_db"
    if ! "$already_archived"; then rm -f "$dst_host"; fi
    return 1
  fi

  if ! $DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" test -f "$dst_db" </dev/null; then
    log_error "File not accessible from container: $dst_db"
    "$update_fn" "$asset_id" "$(host_path_to_db_path "$src_host_path")" || true
    if ! "$already_archived"; then rm -f "$dst_host"; fi
    return 1
  fi

  # Library files are owned by the container's UID (often root), so the unprivileged
  # host user can't remove them. Delete through the container that owns them — no
  # sudo. The copy + DB update already succeeded, so a failed cleanup is non-fatal:
  # the asset now points to the destination; the source just lingers as an orphan.
  local src_db
  src_db=$(host_path_to_db_path "$src_host_path")
  if ! $DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" rm -f "$src_db" </dev/null; then
    log_warn "Archived OK but could not remove source in container: $src_db"
  fi
  return 0
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
  local report
  if report=$(db_check_path_consistency); then
    return 0
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
    esac
  done

  check_prereqs

  # Storage availability — agnostic to the storage type (marker-based).
  if ! check_archive_dest_ready; then
    return 0
  fi

  # Case B: external library path changed in Immich → pause, never touch the DB.
  if ! guard_path_consistency; then
    return 1
  fi

  if ! acquire_lock; then
    return 0
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
    if (( lib_bytes <= max_bytes )); then
      log_info "Library within limit (max $(bytes_to_human "$max_bytes")) — nothing to archive."
      release_lock
      return 0
    fi
    log_info "Archive triggered: library exceeds max $(bytes_to_human "$max_bytes")."
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

  local freed_bytes=0

  while IFS='|' read -r user_folder parent_dir folder_size; do
    [[ -z "$user_folder" ]] && continue

    log_info "Candidate directory: $parent_dir (user: $user_folder, $(bytes_to_human "${folder_size:-0}"))"

    while IFS='|' read -r asset_id original_path_db file_size; do
      [[ -z "$asset_id" ]] && continue

      local src_host
      src_host=$(db_path_to_host_path "$original_path_db")

      if ! _archive_move_file "$asset_id" "$src_host" "db_update_asset_path" "$dry_run"; then
        log_error "Asset skipped: $asset_id ($original_path_db)"
        continue
      fi

      _archive_move_sidecar "$src_host" "$dry_run" || true

      freed_bytes=$(( freed_bytes + ${file_size:-0} ))
    done < <(db_get_folder_assets "$parent_dir")

    log_info "Directory archived: $parent_dir — $(bytes_to_human "${folder_size:-0}")"

    # Check threshold only after completing the current directory, never mid-directory.
    if (( freed_bytes >= bytes_to_free )); then
      break
    fi
  done < <(db_get_archive_candidates)

  release_lock
  log_info "Archive complete. Freed: $(bytes_to_human "$freed_bytes")."
}
