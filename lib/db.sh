#!/usr/bin/env bash
set -euo pipefail

# ── Internal helpers ──────────────────────────────────────────────────────────

_db_exec() {
  $DOCKER_CMD exec -i "$IMMICH_DB_CONTAINER" psql \
    -U "$IMMICH_DB_USER" -d "$IMMICH_DB_NAME" -t -A -c "$1"
}

# Escapes single quotes for SQL string literals.
_db_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# Escapes LIKE wildcards so a path is matched literally. Backslash is the escape
# char; the result must be used with `ESCAPE '\'`. Apply BEFORE _db_escape.
_db_escape_like() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/%/\\%/g' -e 's/_/\\_/g'
}

# ── Schema validation ─────────────────────────────────────────────────────────

# Verifies that required tables and columns exist in the Immich schema.
# Returns 1 and logs errors if anything is missing.
db_check_schema() {
  local expected_asset_columns=(
    "id" "originalPath" "isOffline" "isExternal" "libraryId"
    "deletedAt" "ownerId" "visibility" "fileCreatedAt"
  )
  local expected_exif_columns=("assetId" "fileSizeInByte")

  local missing=()

  local asset_cols
  asset_cols=$(_db_exec "SELECT column_name FROM information_schema.columns WHERE table_name='asset';" 2>/dev/null || true)
  for col in "${expected_asset_columns[@]}"; do
    if ! printf '%s\n' "$asset_cols" | grep -qx "$col"; then
      missing+=("asset.$col")
    fi
  done

  local exif_cols
  exif_cols=$(_db_exec "SELECT column_name FROM information_schema.columns WHERE table_name='asset_exif';" 2>/dev/null || true)
  for col in "${expected_exif_columns[@]}"; do
    if ! printf '%s\n' "$exif_cols" | grep -qx "$col"; then
      missing+=("asset_exif.$col")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    log_error "Schema check failed. Missing columns: ${missing[*]}"
    log_error "Check your Immich version and update this script if needed."
    return 1
  fi
  return 0
}

# ── Library prefix detection ──────────────────────────────────────────────────

# Queries a sample asset to detect and set IMMICH_DB_LIBRARY_PREFIX.
db_detect_library_prefix() {
  local sample_path
  sample_path=$(_db_exec "SELECT \"originalPath\" FROM \"asset\" LIMIT 1;" 2>/dev/null | head -1 || true)

  if [[ -z "$sample_path" ]]; then
    log_warn "No assets found in database — cannot auto-detect IMMICH_DB_LIBRARY_PREFIX."
    return 1
  fi

  local prefix
  prefix=$(printf '%s' "$sample_path" | sed 's|\(/[^/]*/library\)/.*|\1|')

  if [[ "$prefix" == "$sample_path" ]]; then
    log_warn "Could not extract library prefix from path: $sample_path"
    return 1
  fi

  IMMICH_DB_LIBRARY_PREFIX="$prefix"
  return 0
}

# ── Public functions ──────────────────────────────────────────────────────────

# Returns id|name|storageLabel for all users, ordered by creation date.
db_get_users() {
  _db_exec "SELECT \"id\", \"name\", \"storageLabel\" FROM \"user\" ORDER BY \"createdAt\";"
}

# Returns id|originalPath|fileSizeInByte for all active assets in a given parent directory.
# parent_dir_db_path is the exact DB path of the folder (no trailing slash).
db_get_folder_assets() {
  local parent_dir_db_path="$1"
  local escaped_prefix
  escaped_prefix=$(_db_escape "$(_db_escape_like "$parent_dir_db_path")")

  _db_exec "SELECT a.\"id\", a.\"originalPath\", e.\"fileSizeInByte\"
            FROM \"asset\" a
            LEFT JOIN \"asset_exif\" e ON a.\"id\" = e.\"assetId\"
            WHERE a.\"originalPath\" LIKE '${escaped_prefix}/%' ESCAPE '\\'
              AND a.\"deletedAt\" IS NULL
              AND a.\"isOffline\" = false
              AND a.\"isExternal\" = false;"
}

# Returns user_folder|parent_dir|total_size for archive candidates, ordered by path ASC.
# Groups by the immediate parent directory of each asset (template-agnostic).
db_get_archive_candidates() {
  local escaped_library_prefix
  escaped_library_prefix=$(_db_escape "${IMMICH_DB_LIBRARY_PREFIX}/")
  local escaped_archive_prefix
  escaped_archive_prefix=$(_db_escape "$(_db_escape_like "${ARCHIVE_CONTAINER_PATH}")")

  # Order by the oldest capture date in each directory so the genuinely oldest photos
  # are archived first, regardless of the storage template (template-agnostic). The
  # ordering key is an aggregate and need not appear in the SELECT list.
  _db_exec "
    SELECT
      split_part(
        regexp_replace(a.\"originalPath\", '^${escaped_library_prefix}', ''),
        '/', 1
      ) AS user_folder,
      substring(a.\"originalPath\" from '^(.+)/[^/]+\$') AS parent_dir,
      SUM(e.\"fileSizeInByte\") AS total_size
    FROM \"asset\" a
    LEFT JOIN \"asset_exif\" e ON a.\"id\" = e.\"assetId\"
    WHERE a.\"deletedAt\" IS NULL
      AND a.\"isOffline\" = false
      AND a.\"isExternal\" = false
      AND a.\"originalPath\" NOT LIKE '${escaped_archive_prefix}%' ESCAPE '\\'
    GROUP BY user_folder, parent_dir
    ORDER BY MIN(a.\"fileCreatedAt\") ASC;"
}

# Updates originalPath for an asset in a transaction. Returns 0 on success, 1 on failure.
db_update_asset_path() {
  local asset_id="$1"
  local new_path="$2"

  local escaped_id escaped_path
  escaped_id=$(_db_escape "$asset_id")
  escaped_path=$(_db_escape "$new_path")

  if _db_exec "BEGIN;
               UPDATE \"asset\" SET \"originalPath\"='${escaped_path}' WHERE \"id\"='${escaped_id}';
               COMMIT;" &>/dev/null; then
    return 0
  else
    return 1
  fi
}

# ── Path consistency (case B detection — read-only) ───────────────────────────
#
# Immich's DB is the source of truth; these functions only READ it to detect that
# the external library path changed in Immich and that our config is now stale.

# Echoes the internal library prefix (/.../library) derived from a current,
# non-archived asset. Empty if undeterminable.
db_current_library_prefix() {
  local sample
  sample=$(_db_exec "SELECT \"originalPath\" FROM \"asset\"
                     WHERE \"originalPath\" LIKE '%/library/%'
                       AND \"deletedAt\" IS NULL
                     LIMIT 1;" 2>/dev/null | head -1 || true)
  [[ -z "$sample" ]] && return 0
  printf '%s' "$sample" | sed 's|\(/[^/]*/library\)/.*|\1|'
}

# Echoes the number of active assets we archived (under ARCHIVE_CONTAINER_PATH)
# that Immich currently reports offline. Meaningful as a "container path changed"
# signal ONLY when the external storage is ready (files physically present).
db_count_offline_archived() {
  local escaped
  escaped=$(_db_escape "$(_db_escape_like "${ARCHIVE_CONTAINER_PATH%/}")")
  _db_exec "SELECT count(*) FROM \"asset\"
            WHERE \"deletedAt\" IS NULL
              AND \"isOffline\" = true
              AND \"originalPath\" LIKE '${escaped}/%' ESCAPE '\\';" 2>/dev/null | head -1
}

# Read-only consistency check between our config and Immich's DB reality.
# Echoes a human-readable report and returns 1 on inconsistency, 0 if consistent.
# The offline-archived signal must only be trusted when the storage is ready
# (callers gate on check_archive_dest_ready first).
db_check_path_consistency() {
  local issues=()

  local current_prefix
  current_prefix=$(db_current_library_prefix)
  if [[ -n "$current_prefix" && -n "${IMMICH_DB_LIBRARY_PREFIX:-}" \
        && "$current_prefix" != "$IMMICH_DB_LIBRARY_PREFIX" ]]; then
    issues+=("Internal library prefix changed in DB: config='${IMMICH_DB_LIBRARY_PREFIX}' but DB shows '${current_prefix}'.")
  fi

  local offline
  offline=$(db_count_offline_archived)
  if [[ "$offline" =~ ^[0-9]+$ ]] && (( offline > 0 )); then
    issues+=("${offline} archived asset(s) under '${ARCHIVE_CONTAINER_PATH}' are offline while the storage is reachable — the external library path likely changed in Immich.")
  fi

  if (( ${#issues[@]} > 0 )); then
    printf '%s\n' "${issues[@]}"
    return 1
  fi
  return 0
}
