#!/usr/bin/env bash
set -euo pipefail

# ── Helper : construction du chemin de destination ────────────────────────────

archive_build_dest_path() {
  local original_path="$1"
  local prefix="$IMMICH_UPLOAD_LOCATION/library/"

  # Extrait la partie relative après library/
  local relative="${original_path#"$prefix"}"

  local user_folder="${relative%%/*}"
  local rest="${relative#"$user_folder/"}"
  local year="${rest%%/*}"
  local rest2="${rest#"$year/"}"
  local month="${rest2%%/*}"
  local filename="${rest2#"$month/"}"

  local mapped_name="${USER_MAP["$user_folder"]:-$user_folder}"

  printf '%s/%s/%s/%s/%s\n' "$ARCHIVE_DEST_PATH" "$mapped_name" "$year" "$month" "$filename"
}

# ── Helper : déplace un fichier vers le stockage externe ──────────────────────
#
# Paramètres :
#   asset_id   — identifiant de l'asset en BDD
#   src_path   — chemin hôte du fichier (= valeur actuelle en BDD, sert au rollback)
#   update_fn  — nom de la fonction BDD à appeler : db_update_asset_path ou db_update_sidecar_path
#
# Retourne 0 si tout s'est bien passé, 1 en cas d'erreur (src_path inchangé).
_archive_move_file() {
  local asset_id="$1"
  local src_path="$2"
  local update_fn="$3"

  local dst_local
  dst_local=$(archive_build_dest_path "$src_path")
  mkdir -p "$(dirname "$dst_local")"

  cp "$src_path" "$dst_local"

  if ! stat "$dst_local" &>/dev/null; then
    log_error "Vérification échouée après cp : $dst_local"
    rm -f "$dst_local"
    return 1
  fi

  # Traduit le chemin hôte en chemin conteneur pour la BDD et la vérification.
  local dst_container="${dst_local/#"$ARCHIVE_DEST_PATH"/"$ARCHIVE_CONTAINER_PATH"}"

  if ! "$update_fn" "$asset_id" "$dst_container"; then
    log_error "Mise à jour BDD échouée (asset $asset_id) : $dst_container"
    rm -f "$dst_local"
    return 1
  fi

  if ! docker exec "$IMMICH_SERVER_CONTAINER" test -f "$dst_container"; then
    log_error "Fichier inaccessible depuis le conteneur : $dst_container"
    "$update_fn" "$asset_id" "$src_path" || true  # rollback BDD
    rm -f "$dst_local"
    return 1
  fi

  rm -f "$src_path"
  return 0
}

# ── Fonction principale ────────────────────────────────────────────────────────

archive_run() {
  check_prereqs

  if ! check_archive_dest_mounted; then
    log_warn "Stockage externe non monté ($ARCHIVE_DEST_PATH) — archivage ignoré."
    return 0
  fi

  if ! acquire_lock; then
    return 0
  fi

  local usage
  usage=$(disk_usage_percent "$IMMICH_UPLOAD_LOCATION/library/")

  if (( usage < ARCHIVE_THRESHOLD_HIGH )); then
    log_info "Espace suffisant : ${usage}% utilisé (seuil haut : ${ARCHIVE_THRESHOLD_HIGH}%)."
    release_lock
    return 0
  fi

  log_info "Archivage déclenché : ${usage}% utilisé (seuil haut : ${ARCHIVE_THRESHOLD_HIGH}%, cible : ${ARCHIVE_THRESHOLD_LOW}%)."

  local total_kb
  total_kb=$(df --output=size "$IMMICH_UPLOAD_LOCATION" | tail -1 | tr -d ' ')
  local bytes_to_free
  bytes_to_free=$(echo "($usage - $ARCHIVE_THRESHOLD_LOW) * $total_kb * 1024 / 100" | bc)

  local freed_bytes=0

  while IFS='|' read -r user_folder year month folder_size; do
    [[ -z "$user_folder" ]] && continue

    while IFS='|' read -r asset_id original_path file_size; do
      [[ -z "$asset_id" ]] && continue

      if ! _archive_move_file "$asset_id" "$original_path" "db_update_asset_path"; then
        log_error "Asset ignoré : $asset_id ($original_path)"
        continue
      fi

      local sidecar
      sidecar=$(db_get_sidecar_path "$asset_id")
      if [[ -n "$sidecar" ]]; then
        _archive_move_file "$asset_id" "$sidecar" "db_update_sidecar_path" \
          || log_error "Sidecar ignoré pour asset : $asset_id"
      fi

      freed_bytes=$(( freed_bytes + file_size ))
    done < <(db_get_month_folder_assets "$user_folder" "$year" "$month")

    log_info "Dossier archivé : $user_folder/$year/$month — $(bytes_to_human "$folder_size")"

    # Seuil vérifié après chaque dossier complet, jamais en cours.
    if (( freed_bytes >= bytes_to_free )); then
      break
    fi
  done < <(db_get_archive_candidates)

  _archive_trigger_rescan

  release_lock
  log_info "Archivage terminé. Libéré : $(bytes_to_human "$freed_bytes")."
}

# ── Rescan bibliothèque externe ────────────────────────────────────────────────

_archive_trigger_rescan() {
  local lib_id
  lib_id=$(curl -sf \
    -H "x-api-key: $IMMICH_API_KEY" \
    "$IMMICH_API_URL/api/libraries" \
    | jq -r '[.[] | select(.type == "EXTERNAL")] | .[0].id')

  if [[ -z "$lib_id" || "$lib_id" == "null" ]]; then
    log_warn "Bibliothèque externe introuvable via l'API — rescan non déclenché."
    return 0
  fi

  curl -sf -X POST \
    -H "x-api-key: $IMMICH_API_KEY" \
    "$IMMICH_API_URL/api/libraries/$lib_id/scan" &>/dev/null \
    && log_info "Rescan bibliothèque externe déclenché (id: $lib_id)." \
    || log_warn "Échec du déclenchement du rescan (id: $lib_id)."
}
