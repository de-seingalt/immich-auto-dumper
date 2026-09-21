#!/usr/bin/env bash
set -euo pipefail

# ── Internal helpers ──────────────────────────────────────────────────────────

# Diagnostic convention, used by every function below that can fail to reach
# something:
#
#   0  success, the result can be used
#   1  a legitimate negative answer — absent, empty, not covered
#   2  no conclusion possible — dependency unreachable, permission denied, timeout
#
# The audit found that every one of its false "all clear" verdicts came from the
# same place: a function that could not tell 1 from 2 and answered 1. "The database
# did not answer" and "the schema has changed" produced the identical message,
# which invited the operator to edit a tool that writes to their database while the
# container was merely stopped. Never turn an uncertainty into a negative.

# `psql -c` never reads stdin, but `docker exec -i` keeps stdin open and drains it.
# When called inside a `while read … done < <(…)` loop, that stdin IS the loop's
# input pipe — docker would swallow the remaining rows and the loop would stop after
# the first iteration. Redirect from /dev/null so the loop's input is left intact.
#
# Returns 2, never a silently empty result, when the query could not run: the caller
# must be able to tell "no rows" from "no database". Standard error is left to flow
# through to the caller, which is where psql explains itself.
# Column separator for multi-column results. psql's default under -A is '|', which
# a file path is free to contain: a directory called "we|ird" split into three
# fields, bash read a truncated parent directory and a size that was not a number,
# and that directory was silently never archived. No path can hold \x01.
DB_FIELD_SEP=$'\x01'

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

# Verifies that required tables and columns exist in the Immich schema.
# Returns 0 when the schema matches, 1 when columns are genuinely missing, and 2
# when the database could not be questioned at all — the distinction the previous
# version could not make, and the reason a stopped container was reported as a
# schema change.
db_check_schema() {
  local expected_asset_columns=(
    "id" "originalPath" "isOffline" "isExternal" "libraryId"
    "deletedAt" "ownerId" "visibility" "fileCreatedAt"
  )
  local expected_exif_columns=("assetId" "fileSizeInByte")
  # Used by the external-library adoption in db_update_asset_path and by
  # db_get_external_libraries — a rework of the library table must abort here,
  # at pre-flight, not mid-archive.
  local expected_library_columns=("id" "ownerId" "importPaths" "deletedAt")

  local missing=()
  local table cols col rc

  # One query per table, each of which must actually run. A query that fails says
  # nothing about the schema, so it stops the check instead of contributing an
  # empty column list — which is what made every column look missing.
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

# Returns ownerId|storageLabel|importPath for every Immich external library, one
# row per import path. `importPaths` is a text[]; the LEFT JOIN LATERAL unnest keeps
# libraries with an empty array (path field is then empty). Used by setup to
# pre-fill each user's destination folder from an already-configured import path.
db_get_external_libraries() {
  _db_exec "SELECT l.\"ownerId\", u.\"storageLabel\", p
            FROM \"library\" l
            JOIN \"user\" u ON u.\"id\" = l.\"ownerId\"
            LEFT JOIN LATERAL unnest(l.\"importPaths\") AS p ON true
            WHERE l.\"deletedAt\" IS NULL
            ORDER BY u.\"name\";"
}

# Echoes how many database dumps Immich itself keeps in UPLOAD_LOCATION/backups
# (its backup.database.keepLastAmount setting), or nothing when that number is not
# readable from the DB. Immich only stores the keys an admin actually changed in
# system_metadata, so an empty answer means "still on Immich's own default" (14 at
# the time of writing) — or that the setting comes from an IMMICH_CONFIG_FILE, which
# lives outside the DB. Best-effort and never fatal: used by setup to suggest a
# BACKUP_RETENTION that does not silently drop dumps Immich still has locally.
db_immich_backup_keep_last() {
  local v
  v=$(_db_exec "SELECT \"value\" #>> '{backup,database,keepLastAmount}'
                FROM \"system_metadata\" WHERE \"key\" = 'system-config';" 2>/dev/null | head -1 || true)
  # 1 or more, not 0: `^[0-9]+$` let a zero through, and a suggested retention of 0
  # written into config.conf makes every mirroring run delete all of its own dumps.
  [[ "$v" =~ ^[1-9][0-9]*$ ]] && printf '%s\n' "$v"
  return 0
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
  # regexp_replace below treats this as a regex anchor, so escape regex metachars first.
  escaped_library_prefix=$(_db_escape "$(_db_escape_regex "${IMMICH_DB_LIBRARY_PREFIX}/")")
  local escaped_archive_prefix
  escaped_archive_prefix=$(_db_escape "$(_db_escape_like "${ARCHIVE_CONTAINER_PATH}")")
  # Same prefix again, escaped for LIKE this time. The selection used to offer
  # every internal asset whatever its path, including one living outside
  # IMMICH_DB_LIBRARY_PREFIX — for which split_part returns an empty user folder
  # and no destination can be built at all. Not offering it is better than
  # refusing it one layer later.
  local escaped_like_prefix
  escaped_like_prefix=$(_db_escape "$(_db_escape_like "${IMMICH_DB_LIBRARY_PREFIX}")")

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
      AND a.\"originalPath\" LIKE '${escaped_like_prefix}/%' ESCAPE '\\'
      AND a.\"originalPath\" NOT LIKE '${escaped_archive_prefix}%' ESCAPE '\\'
    GROUP BY user_folder, parent_dir
    ORDER BY MIN(a.\"fileCreatedAt\") ASC;"
}

# Updates originalPath for an asset AND its library membership. When the new path
# falls under an import path of an external library owned by the asset's owner, the
# asset is adopted into that library (libraryId set, isExternal=true) so Immich's
# periodic library scan matches the existing row instead of re-importing the file
# as a duplicate asset. When no library covers the path (including the rollback to
# the internal library), the asset reverts to a plain upload asset (libraryId NULL,
# isExternal=false). Sets DB_UPDATE_IS_EXTERNAL to the resulting state ('t'/'f').
# Returns 0 on success, 1 on failure.
db_update_asset_path() {
  local asset_id="$1"
  local new_path="$2"
  DB_UPDATE_IS_EXTERNAL=""

  local escaped_id escaped_path
  escaped_id=$(_db_escape "$asset_id")
  escaped_path=$(_db_escape "$new_path")

  # rtrim + '/%' matches import paths with or without a trailing slash, without
  # letting '/external_library/Test' claim '/external_library/Test2/...'.
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

# Echoes "<trashed|live> <originalPath>" for one asset. Echoes nothing (0) when the
# asset no longer exists at all, and returns 2 when the database could not answer.
#
# The flag comes first and contains no space, so the path that follows keeps every
# character it has. It is spelled out by a CASE rather than cast from the boolean:
# `::text` renders true/false while psql DISPLAYS t/f, and comparing against the
# display form silently treated every trashed asset as live.
#
# Used when resuming a journalled operation: Immich lives between runs, so the
# database is re-read and has to agree before anything irreversible happens.
db_asset_position() {
  local escaped out rc=0
  escaped=$(_db_escape "$1")
  out=$(_db_exec "SELECT CASE WHEN \"deletedAt\" IS NOT NULL THEN 'trashed' ELSE 'live' END
                         || ' ' || \"originalPath\"
                  FROM \"asset\" WHERE \"id\" = '${escaped}';") || rc=$?
  (( rc == 0 )) || return 2
  printf '%s' "$(printf '%s\n' "$out" | head -1)"
}

# Echoes 't' when an external library of the asset's owner covers <path>, 'f'
# otherwise. Read-only preview of the adoption decision above — used by dry runs
# to surface a missing external library before any real archiving is attempted.
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

# ── Path consistency (case B detection — read-only) ───────────────────────────
#
# Immich's DB is the source of truth; these functions only READ it to detect that
# the external library path changed in Immich and that our config is now stale.

# Echoes the internal library prefix (/.../library) derived from a current,
# non-archived asset. 1 when no asset can serve as a sample (a legitimate answer:
# an empty library), 2 when the database could not be questioned.
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

# Echoes the number of active assets we archived (under ARCHIVE_CONTAINER_PATH)
# that Immich currently reports offline. Meaningful as a "container path changed"
# signal ONLY when the external storage is ready (files physically present).
# Echoes "<live>|<trashed>": how many of the assets we archived Immich currently
# reports offline, split by whether it has also put them in the trash.
#
# Counting only the live ones made the check blind exactly when it mattered. Immich
# marks an asset offline and moves it to the trash in the SAME operation — that is
# what happened to 12 133 assets on 11 September — so the window in which the old
# query could see anything lasted seconds. The same three assets read as
# INCONSISTENT and then, moments later, as OK.
#
# The feared false positive, someone deleting archived photos on purpose, is ruled
# out by `isOffline = true`: a deliberately deleted asset is not offline. It is the
# conjunction that signals the failure, and nothing needs remembering between runs.
#
# Returns 2 rather than an empty string when the counts cannot be obtained: an
# absent number used to read as "nothing offline", i.e. as good news.
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

# Read-only consistency check between our config and Immich's DB reality.
# Echoes a human-readable report and returns 1 on inconsistency, 0 if consistent,
# 2 if the database could not answer — because "no inconsistency found" and "found
# nothing at all" are the two verdicts this check must never confuse. A caller that
# treated 2 as 0 would let an archive run start blind.
# The offline-archived signal must only be trusted when the storage is ready
# (callers gate on check_archive_dest_ready first).
db_check_path_consistency() {
  local issues=() rc=0

  local current_prefix
  current_prefix=$(db_current_library_prefix) || rc=$?
  if (( rc == 2 )); then
    printf 'The Immich database did not answer; nothing could be verified.\n'
    return 2
  fi
  # rc == 1 simply means no asset to derive a prefix from: nothing to compare.
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
