#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Auto-detection of Immich settings from the running Docker installation.
#
# immich-auto-dumper exists only to move photos out of Immich's internal library
# and into an Immich *external library* that Immich keeps reading. Every value it
# needs is therefore already defined by the running Immich install: container
# names, the upload location, the external library mounts, the DB credentials and
# the asset path prefix. These helpers read that ground truth (via `docker
# inspect` and the database) so the wizard can pre-fill — and usually fully
# determine — each value, asking the user only to confirm or to choose between
# real alternatives.
#
# All functions set DET_* globals and/or echo results; none are interactive.
# ──────────────────────────────────────────────────────────────────────────────

# Raw "Type|Source|Destination" line per mount of a container.
#
# Note: only host paths (Source) and container paths (Destination) are read. A
# Docker ":ro" mount mode is deliberately ignored — it restricts the *container*
# (so the Immich app cannot write to an external library), but immich-auto-dumper
# moves files through the *host* filesystem, not through Docker. Whether the tool
# can write there is a host-side question, verified during setup when the storage
# marker file is written into ARCHIVE_DEST_PATH.
_inspect_mounts() {
  $DOCKER_CMD inspect \
    --format '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' \
    "$1" 2>/dev/null || true
}

# detect_immich_containers
# Sets DET_SERVER_CONTAINER and DET_DB_CONTAINER (empty when not found).
detect_immich_containers() {
  DET_SERVER_CONTAINER=""; DET_DB_CONTAINER=""
  local names
  names=$($DOCKER_CMD ps --format '{{.Names}}' 2>/dev/null || true)
  DET_DB_CONTAINER=$(printf '%s\n' "$names" \
    | grep -iE 'postgres|pgvecto|immich.*(db|database)|(db|database).*immich' | head -1 || true)
  DET_SERVER_CONTAINER=$(printf '%s\n' "$names" \
    | grep -iE 'immich[_-]?server' | head -1 || true)
  # Fallback: a lone immich* container that is not the database is the server.
  if [[ -z "$DET_SERVER_CONTAINER" ]]; then
    DET_SERVER_CONTAINER=$(printf '%s\n' "$names" \
      | grep -i 'immich' | grep -ivE 'postgres|redis|pgvecto|database|valkey|ml|machine' | head -1 || true)
  fi
}

# detect_db_credentials <server_container>
# Sets DET_DB_USER / DET_DB_NAME from the server container environment when Immich
# exposes them (DB_USERNAME / DB_DATABASE_NAME); empty otherwise.
detect_db_credentials() {
  DET_DB_USER=""; DET_DB_NAME=""
  local env
  env=$($DOCKER_CMD inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null || true)
  DET_DB_USER=$(printf '%s\n'  "$env" | sed -n 's/^DB_USERNAME=//p'      | head -1)
  DET_DB_NAME=$(printf '%s\n'  "$env" | sed -n 's/^DB_DATABASE_NAME=//p' | head -1)
}

# detect_upload_mount <server_container> [<db_library_prefix>]
# Sets DET_UPLOAD_LOCATION (host path) and DET_UPLOAD_CONTAINER (container path)
# for Immich's UPLOAD_LOCATION mount. Returns 1 if it cannot be determined.
detect_upload_mount() {
  local container="$1" prefix="${2:-}"
  DET_UPLOAD_LOCATION=""; DET_UPLOAD_CONTAINER=""
  local mounts type src dst
  mounts=$(_inspect_mounts "$container")

  # Best signal: the mount whose container path is the parent of the DB library
  # prefix (e.g. prefix /data/library -> mount dest /data).
  if [[ -n "$prefix" ]]; then
    local want="${prefix%/library}"
    while IFS='|' read -r type src dst; do
      [[ "$type" == "bind" ]] || continue
      if [[ "$dst" == "$want" ]]; then
        DET_UPLOAD_LOCATION="$src"; DET_UPLOAD_CONTAINER="$dst"; return 0
      fi
    done <<< "$mounts"
  fi

  # Canonical Immich upload destinations: modern images bind to /data, older ones
  # to /usr/src/app/upload.
  while IFS='|' read -r type src dst; do
    [[ "$type" == "bind" ]] || continue
    if [[ "$dst" == "/data" || "$dst" == "/usr/src/app/upload" ]]; then
      DET_UPLOAD_LOCATION="$src"; DET_UPLOAD_CONTAINER="$dst"; return 0
    fi
  done <<< "$mounts"

  # Last resort: a bind mount whose host side actually holds a library/ folder.
  while IFS='|' read -r type src dst; do
    [[ "$type" == "bind" ]] || continue
    if [[ -n "$src" && -d "$src/library" ]]; then
      DET_UPLOAD_LOCATION="$src"; DET_UPLOAD_CONTAINER="$dst"; return 0
    fi
  done <<< "$mounts"

  return 1
}

# detect_external_libraries <server_container> <upload_container_path>
# Echoes one "host_path|container_path" line per external-library candidate:
# bind mounts that are neither the upload mount nor Immich/system internals.
#
# The Docker mount mode (:ro / :rw) is intentionally NOT used to filter: ":ro"
# only stops the Immich container from writing (often set on purpose). This tool
# writes through the host filesystem, so host-side write access is what matters,
# and that is verified when the storage marker is written during setup.
detect_external_libraries() {
  local container="$1" upload_dst="$2"
  local mounts type src dst
  mounts=$(_inspect_mounts "$container")
  while IFS='|' read -r type src dst; do
    [[ "$type" == "bind" ]] || continue
    [[ -z "$src" || -z "$dst" ]] && continue
    [[ -n "$upload_dst" && "$dst" == "$upload_dst" ]] && continue
    case "$dst" in
      /usr/src/app|/usr/src/app/*) continue ;;   # Immich application internals
      /etc/localtime|/etc/timezone) continue ;;  # common read-only system binds
      /dev/*|/proc/*|/sys/*|/run/*) continue ;;
    esac
    case "$src" in
      /etc/localtime|/etc/timezone) continue ;;
    esac
    printf '%s|%s\n' "$src" "$dst"
  done <<< "$mounts"
}
