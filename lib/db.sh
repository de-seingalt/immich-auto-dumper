#!/usr/bin/env bash
set -euo pipefail

# ── Internal helpers ──────────────────────────────────────────────────────────

# Diagnostic convention, followed by every function here that can fail to reach
# something:
#
#   0  success, the result can be used
#   1  a legitimate negative answer — absent, empty, not covered
#   2  no conclusion possible — dependency unreachable, permission denied, timeout

# Column separator for multi-column results, in place of psql's '|' under -A. No
# path can hold \x01.
DB_FIELD_SEP=$'\x01'

# Runs one SQL statement in the Postgres container and echoes its rows. Returns 2,
# never an empty result, when the query could not run, so a caller can tell "no
# rows" from "no database"; psql's own stderr flows through. stdin comes from
# /dev/null, because `docker exec -i` would otherwise drain the caller's loop.
_db_exec() {
  local out rc=0
  out=$($DOCKER_CMD exec -i "$IMMICH_DB_CONTAINER" psql \
          -U "$IMMICH_DB_USER" -d "$IMMICH_DB_NAME" -t -A -F "$DB_FIELD_SEP" \
          -c "$1" </dev/null) || rc=$?
  (( rc == 0 )) || return 2
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out"
  fi
  return 0
}

# True if the configured Immich Postgres container answers a trivial query.
# Requires IMMICH_DB_CONTAINER / IMMICH_DB_USER / IMMICH_DB_NAME to be set first.
_db_reachable() { _db_exec "SELECT 1;" &>/dev/null; }

# Escapes single quotes for SQL string literals.
_db_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# Escapes LIKE wildcards so a path is matched literally. Backslash is the escape
# char; the result must be used with `ESCAPE '\'`. Apply BEFORE _db_escape.
_db_escape_like() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/%/\\%/g' -e 's/_/\\_/g'
}

# Escapes POSIX-regex metacharacters so a path is matched literally inside a
# regexp_replace/`~` pattern. Apply BEFORE _db_escape (same ordering as _db_escape_like).
_db_escape_regex() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/[][(){}.*+?^$|]/\\&/g'
}

# ── Schema validation ─────────────────────────────────────────────────────────

# Verifies that the tables and columns this tool relies on exist in the Immich
# schema. Returns 0 when they all do, 1 when some are missing, and 2 when the
# database could not be questioned at all.
db_check_schema() {
  local expected_asset_columns=(
    "id" "originalPath" "isOffline" "isExternal" "libraryId"
    "deletedAt" "ownerId" "visibility" "fileCreatedAt"
  )
  local expected_exif_columns=("assetId" "fileSizeInByte")
  local expected_library_columns=("id" "ownerId" "importPaths" "deletedAt")

  local missing=()
  local table cols col rc

  # One query per table, each of which must run: a query that fails says nothing
  # about the schema and stops the check, rather than contributing no columns.
  local -A expected=(
    [asset]="${expected_asset_columns[*]}"
    [asset_exif]="${expected_exif_columns[*]}"
    [library]="${expected_library_columns[*]}"
  )
  for table in asset asset_exif library; do
    rc=0
    cols=$(_db_exec "SELECT column_name FROM information_schema.columns WHERE table_name='${table}';" 2>/dev/null) || rc=$?
    if (( rc != 0 )); then
      log_error "Cannot read Immich's schema: the database did not answer."
      log_error "The schema itself was NOT checked — is container '${IMMICH_DB_CONTAINER}' running?"
      log_error "  docker ps --filter name=${IMMICH_DB_CONTAINER}"
      return 2
    fi
    for col in ${expected[$table]}; do
      printf '%s\n' "$cols" | grep -qx -- "$col" || missing+=("${table}.${col}")
    done
  done

  if (( ${#missing[@]} > 0 )); then
    log_error "Schema check failed. Missing columns: ${missing[*]}"
    log_error "Check your Immich version and update this script if needed."
    return 1
  fi
  return 0
}

# ── Library prefix detection ──────────────────────────────────────────────────

# Derives IMMICH_DB_LIBRARY_PREFIX from a sample asset's path and sets it.
# Returns 1 when there is no asset to read, or no prefix in its path.
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

# Echoes id·name·storageLabel for every Immich user, oldest first.
db_get_users() {
  _db_exec "SELECT \"id\", \"name\", \"storageLabel\" FROM \"user\" ORDER BY \"createdAt\";"
}

# Echoes ownerId·storageLabel·importPath for every Immich library, one row per
# import path. `importPaths` is a text[]; the LEFT JOIN LATERAL unnest keeps a
# library with an empty array, whose path field is then empty.
db_get_external_libraries() {
  _db_exec "SELECT l.\"ownerId\", u.\"storageLabel\", p
            FROM \"library\" l
            JOIN \"user\" u ON u.\"id\" = l.\"ownerId\"
            LEFT JOIN LATERAL unnest(l.\"importPaths\") AS p ON true
            WHERE l.\"deletedAt\" IS NULL
            ORDER BY u.\"name\";"
}

# Echoes how many database dumps Immich itself keeps in UPLOAD_LOCATION/backups
# (its backup.database.keepLastAmount), or nothing when that number cannot be read
# from the DB. Immich only stores the keys an admin changed, so an empty answer
# also means "still on Immich's default". Never fatal: always returns 0.
db_immich_backup_keep_last() {
  local v
  v=$(_db_exec "SELECT \"value\" #>> '{backup,database,keepLastAmount}'
                FROM \"system_metadata\" WHERE \"key\" = 'system-config';" 2>/dev/null | head -1 || true)
  # 1 or more: a zero is not a retention this tool can suggest.
  [[ "$v" =~ ^[1-9][0-9]*$ ]] && printf '%s\n' "$v"
  return 0
}

# Echoes id·originalPath·fileSizeInByte for every active internal asset in one
# parent directory, named by its exact DB path with no trailing slash.
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

# Echoes user_folder·parent_dir·total_size, one row per directory to archive.
# Active internal assets only, grouped by their immediate parent directory and
# restricted to paths under IMMICH_DB_LIBRARY_PREFIX.
db_get_archive_candidates() {
  local escaped_library_prefix
  # Anchored in a regexp_replace below, hence the regex escaping.
  escaped_library_prefix=$(_db_escape "$(_db_escape_regex "${IMMICH_DB_LIBRARY_PREFIX}/")")
  local escaped_archive_prefix
  escaped_archive_prefix=$(_db_escape "$(_db_escape_like "${ARCHIVE_CONTAINER_PATH}")")
  # The same prefix again, escaped for LIKE this time.
  local escaped_like_prefix
  escaped_like_prefix=$(_db_escape "$(_db_escape_like "${IMMICH_DB_LIBRARY_PREFIX}")")

  # Ordered by the oldest capture date in each directory, so the oldest photos
  # leave first whatever the storage template. The ordering key is an aggregate
  # and need not appear in the SELECT list.
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
      AND a.\"originalPath\" LIKE '${escaped_like_prefix}/%' ESCAPE '\\'
      AND a.\"originalPath\" NOT LIKE '${escaped_archive_prefix}%' ESCAPE '\\'
    GROUP BY user_folder, parent_dir
    ORDER BY MIN(a.\"fileCreatedAt\") ASC;"
}

# Updates an asset's originalPath and its library membership in one statement.
# When the new path falls under an import path of a library owned by the asset's
# owner, the asset is adopted into that library (libraryId set, isExternal=true);
# when no library covers the path — the rollback into the internal library
# included — it reverts to a plain upload asset (libraryId NULL, isExternal=false).
# Sets DB_UPDATE_IS_EXTERNAL to the resulting state ('t'/'f').
# Returns 0 on success, 1 on failure.
db_update_asset_path() {
  local asset_id="$1"
  local new_path="$2"
  DB_UPDATE_IS_EXTERNAL=""

  local escaped_id escaped_path
  escaped_id=$(_db_escape "$asset_id")
  escaped_path=$(_db_escape "$new_path")

  # rtrim + '/%' matches an import path with or without its trailing slash,
  # without letting '/external_library/Alice' claim '/external_library/Alice2/…'.
  local lib_match="SELECT l.\"id\" FROM \"library\" l
                   WHERE l.\"deletedAt\" IS NULL
                     AND l.\"ownerId\" = a.\"ownerId\"
                     AND EXISTS (SELECT 1 FROM unnest(l.\"importPaths\") ip
                                 WHERE '${escaped_path}' LIKE rtrim(ip, '/') || '/%')"

  local out
  out=$(_db_exec "UPDATE \"asset\" AS a SET
                    \"originalPath\" = '${escaped_path}',
                    \"libraryId\"    = (${lib_match} LIMIT 1),
                    \"isExternal\"   = EXISTS (${lib_match}),
                    \"isOffline\"    = false
                  WHERE a.\"id\" = '${escaped_id}'
                  RETURNING a.\"isExternal\";" 2>/dev/null) || return 1
  DB_UPDATE_IS_EXTERNAL=$(printf '%s' "$out" | head -1)
  [[ -n "$DB_UPDATE_IS_EXTERNAL" ]]
}

# Echoes "<trashed|live> <originalPath>" for one asset. Echoes nothing (0) when
# the asset no longer exists at all, and returns 2 when the database could not
# answer. The flag comes first and holds no space, so the path that follows keeps
# every character it has; it is spelled out by a CASE rather than cast from the
# boolean, since psql displays a boolean as t/f.
db_asset_position() {
  local escaped out rc=0
  escaped=$(_db_escape "$1")
  out=$(_db_exec "SELECT CASE WHEN \"deletedAt\" IS NOT NULL THEN 'trashed' ELSE 'live' END
                         || ' ' || \"originalPath\"
                  FROM \"asset\" WHERE \"id\" = '${escaped}';") || rc=$?
  (( rc == 0 )) || return 2
  printf '%s' "$(printf '%s\n' "$out" | head -1)"
}

# Echoes 't' when a library of the asset's owner covers <path>, 'f' otherwise.
# Read-only preview of the adoption db_update_asset_path would perform.
db_asset_would_be_external() {
  local asset_id="$1"
  local path="$2"
  local escaped_id escaped_path
  escaped_id=$(_db_escape "$asset_id")
  escaped_path=$(_db_escape "$path")
  _db_exec "SELECT EXISTS (SELECT 1 FROM \"library\" l JOIN \"asset\" a
              ON l.\"ownerId\" = a.\"ownerId\"
            WHERE a.\"id\" = '${escaped_id}'
              AND l.\"deletedAt\" IS NULL
              AND EXISTS (SELECT 1 FROM unnest(l.\"importPaths\") ip
                          WHERE '${escaped_path}' LIKE rtrim(ip, '/') || '/%'));" 2>/dev/null | head -1
}

# ── Path consistency (read-only) ──────────────────────────────────────────────
#
# These functions only READ the database, to detect that Immich's own paths no
# longer match this configuration.

# Echoes the internal library prefix (/.../library) derived from a live asset.
# Returns 1 when no asset can serve as a sample, which an empty library is a
# legitimate reason for, and 2 when the database could not be questioned.
db_current_library_prefix() {
  local sample rc=0
  sample=$(_db_exec "SELECT \"originalPath\" FROM \"asset\"
                     WHERE \"originalPath\" LIKE '%/library/%'
                       AND \"deletedAt\" IS NULL
                     LIMIT 1;" 2>/dev/null) || rc=$?
  (( rc == 0 )) || return 2
  sample=$(printf '%s\n' "$sample" | head -1)
  [[ -n "$sample" ]] || return 1
  printf '%s' "$sample" | sed 's|\(/[^/]*/library\)/.*|\1|'
}

# Echoes "<live>|<trashed>": how many of the archived assets under
# ARCHIVE_CONTAINER_PATH Immich currently reports offline, split by whether it has
# also moved them to the trash. Immich marks an asset offline and trashes it in
# the same operation, so both counts belong to the same signal. Returns 2, never
# an empty string, when the counts cannot be obtained.
#
# Only meaningful while the external storage is reachable, which callers check
# first: with the files genuinely absent, every archived asset reads as offline.
db_count_offline_archived() {
  local escaped out rc=0
  escaped=$(_db_escape "$(_db_escape_like "${ARCHIVE_CONTAINER_PATH%/}")")
  out=$(_db_exec "SELECT count(*) FILTER (WHERE \"deletedAt\" IS NULL) || '|' ||
                         count(*) FILTER (WHERE \"deletedAt\" IS NOT NULL)
                  FROM \"asset\"
                  WHERE \"isOffline\" = true
                    AND \"originalPath\" LIKE '${escaped}/%' ESCAPE '\\';" 2>/dev/null) || rc=$?
  (( rc == 0 )) || return 2
  out=$(printf '%s\n' "$out" | head -1)
  [[ "$out" =~ ^[0-9]+\|[0-9]+$ ]] || return 2
  printf '%s' "$out"
}

# Read-only check of this configuration against what Immich's database says.
# Echoes a human-readable report, and returns 0 when consistent, 1 on
# inconsistency, 2 when the database could not answer. Callers must gate it on
# check_archive_dest_ready, which the offline-archived signal below depends on.
db_check_path_consistency() {
  local issues=() rc=0

  local current_prefix
  current_prefix=$(db_current_library_prefix) || rc=$?
  if (( rc == 2 )); then
    printf 'The Immich database did not answer; nothing could be verified.\n'
    return 2
  fi
  # rc == 1 means no asset to derive a prefix from, so nothing to compare.
  if (( rc == 0 )) && [[ -n "$current_prefix" && -n "${IMMICH_DB_LIBRARY_PREFIX:-}" \
        && "$current_prefix" != "$IMMICH_DB_LIBRARY_PREFIX" ]]; then
    issues+=("Internal library prefix changed in DB: config='${IMMICH_DB_LIBRARY_PREFIX}' but DB shows '${current_prefix}'.")
  fi

  local counts
  rc=0
  counts=$(db_count_offline_archived) || rc=$?
  if (( rc != 0 )); then
    printf 'The count of offline archived assets could not be read; nothing could be verified.\n'
    return 2
  fi
  local offline_live="${counts%%|*}" offline_trashed="${counts##*|}"
  if (( offline_live + offline_trashed > 0 )); then
    local detail="${offline_live} still visible"
    (( offline_trashed > 0 )) && detail+=", ${offline_trashed} already moved to the trash by Immich"
    issues+=("$(( offline_live + offline_trashed )) archived asset(s) under '${ARCHIVE_CONTAINER_PATH}' are offline while the storage is reachable (${detail}) — the external library path likely changed in Immich.")
    (( offline_trashed > 0 )) && issues+=("Assets Immich has both marked offline and trashed are how a mass loss starts: do NOT empty the trash before the path is fixed.")
  fi

  if (( ${#issues[@]} > 0 )); then
    printf '%s\n' "${issues[@]}"
    return 1
  fi
  return 0
}
