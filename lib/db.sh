#!/usr/bin/env bash
set -euo pipefail

# ── Helper interne ─────────────────────────────────────────────────────────────

_db_exec() {
  docker exec -i "$IMMICH_DB_CONTAINER" psql \
    -U "$IMMICH_DB_USER" -d "$IMMICH_DB_NAME" -t -A -c "$1"
}

# Échappe les apostrophes pour SQL ('' à la place de ').
_db_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# ── Fonctions publiques ────────────────────────────────────────────────────────

db_get_users() {
  _db_exec "SELECT id, name, storage_label FROM users ORDER BY created_at;"
}

# Retourne id|original_path|file_size pour tous les assets d'un dossier mensuel.
db_get_month_folder_assets() {
  local user_folder="$1"
  local year="$2"
  local month="$3"

  local escaped_prefix
  escaped_prefix=$(_db_escape "${IMMICH_UPLOAD_LOCATION}/library/${user_folder}/${year}/${month}/")

  _db_exec "SELECT id, original_path, file_size
            FROM assets
            WHERE original_path LIKE '${escaped_prefix}%'
              AND is_offline = false
              AND is_trashed = false;"
}

# Retourne user_folder|year|month|total_size, triés par date ASC.
# Exclut les assets déjà archivés, hors-ligne ou à la corbeille.
db_get_archive_candidates() {
  local escaped_archive_prefix
  escaped_archive_prefix=$(_db_escape "${ARCHIVE_CONTAINER_PATH}")

  local escaped_library_prefix
  escaped_library_prefix=$(_db_escape "${IMMICH_UPLOAD_LOCATION}/library/")

  _db_exec "
    SELECT
      split_part(
        regexp_replace(original_path, '^${escaped_library_prefix}', ''),
        '/', 1
      ) AS user_folder,
      split_part(
        regexp_replace(original_path, '^${escaped_library_prefix}', ''),
        '/', 2
      ) AS year,
      split_part(
        regexp_replace(original_path, '^${escaped_library_prefix}', ''),
        '/', 3
      ) AS month,
      SUM(file_size) AS total_size
    FROM assets
    WHERE original_path NOT LIKE '${escaped_archive_prefix}%'
      AND is_offline = false
      AND is_trashed = false
    GROUP BY user_folder, year, month
    ORDER BY year ASC, month ASC;"
}

# Met à jour original_path dans une transaction. Retourne 0 si succès, 1 si échec.
db_update_asset_path() {
  local asset_id="$1"
  local new_path="$2"

  local escaped_id escaped_path
  escaped_id=$(_db_escape "$asset_id")
  escaped_path=$(_db_escape "$new_path")

  if _db_exec "BEGIN;
               UPDATE assets SET original_path='${escaped_path}' WHERE id='${escaped_id}';
               COMMIT;" &>/dev/null; then
    return 0
  else
    return 1
  fi
}

# Met à jour sidecar_path dans une transaction. Retourne 0 si succès, 1 si échec.
db_update_sidecar_path() {
  local asset_id="$1"
  local new_path="$2"

  local escaped_id escaped_path
  escaped_id=$(_db_escape "$asset_id")
  escaped_path=$(_db_escape "$new_path")

  if _db_exec "BEGIN;
               UPDATE assets SET sidecar_path='${escaped_path}' WHERE id='${escaped_id}';
               COMMIT;" &>/dev/null; then
    return 0
  else
    return 1
  fi
}

# Retourne sidecar_path si non null, sinon chaîne vide.
db_get_sidecar_path() {
  local asset_id="$1"
  local escaped_id
  escaped_id=$(_db_escape "$asset_id")

  local result
  result=$(_db_exec "SELECT COALESCE(sidecar_path, '')
                     FROM assets
                     WHERE id='${escaped_id}';")
  printf '%s\n' "$result"
}
