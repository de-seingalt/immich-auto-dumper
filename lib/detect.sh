#!/usr/bin/env bash
# shellcheck disable=SC2034  # the DET_* globals are this file's output
# Reads Immich's settings off the running Docker installation: container names,
# upload location, external-library mounts, DB credentials, asset path prefix.
# Every function sets DET_* globals and/or echoes its result; none is interactive.

# Field separator for the mount listing below. No path can contain \x01.
DET_FIELD_SEP=$'\x01'

# Echoes one "Type<SEP>Source<SEP>Destination" line per mount of a container.
# Only the host path (Source) and the container path (Destination) are read; the
# mount mode is not.
_inspect_mounts() {
  $DOCKER_CMD inspect \
    --format '{{range .Mounts}}{{.Type}}{{printf "\x01"}}{{.Source}}{{printf "\x01"}}{{.Destination}}{{"\n"}}{{end}}' \
    "$1" 2>/dev/null || true
}

# Sets DET_SERVER_CONTAINER and DET_DB_CONTAINER (empty when not found), plus
# DET_DB_CANDIDATES / DET_SERVER_CANDIDATES: every running container that matched,
# newline-separated. The first match wins; the caller reports the candidates.
DET_DB_CANDIDATES=""; DET_SERVER_CANDIDATES=""
detect_immich_containers() {
  DET_SERVER_CONTAINER=""; DET_DB_CONTAINER=""
  DET_DB_CANDIDATES="";    DET_SERVER_CANDIDATES=""
  local names
  names=$($DOCKER_CMD ps --format '{{.Names}}' 2>/dev/null || true)
  DET_DB_CANDIDATES=$(printf '%s\n' "$names" \
    | grep -iE 'postgres|pgvecto|immich.*(db|database)|(db|database).*immich' || true)
  DET_DB_CONTAINER=$(printf '%s\n' "$DET_DB_CANDIDATES" | grep -v '^$' | head -1 || true)
  DET_SERVER_CANDIDATES=$(printf '%s\n' "$names" \
    | grep -iE 'immich[_-]?server' || true)
  # Fallback: a lone immich* container that is not the database is the server.
  if [[ -z "$DET_SERVER_CANDIDATES" ]]; then
    DET_SERVER_CANDIDATES=$(printf '%s\n' "$names" \
      | grep -i 'immich' | grep -ivE 'postgres|redis|pgvecto|database|valkey|ml|machine' || true)
  fi
  DET_SERVER_CONTAINER=$(printf '%s\n' "$DET_SERVER_CANDIDATES" | grep -v '^$' | head -1 || true)
}

# Echoes how many non-empty lines a candidates list holds.
detect_candidate_count() {
  printf '%s\n' "$1" | grep -cv '^$' || true
}

# detect_db_credentials <server_container>
# Sets DET_DB_USER / DET_DB_NAME from the server container's environment
# (DB_USERNAME / DB_DATABASE_NAME); empty when it does not expose them.
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

  # First try: the mount whose container path is the parent of the DB library
  # prefix (prefix /data/library -> mount dest /data).
  if [[ -n "$prefix" ]]; then
    local want="${prefix%/library}"
    while IFS="$DET_FIELD_SEP" read -r type src dst; do
      [[ "$type" == "bind" ]] || continue
      if [[ "$dst" == "$want" ]]; then
        DET_UPLOAD_LOCATION="$src"; DET_UPLOAD_CONTAINER="$dst"; return 0
      fi
    done <<< "$mounts"
  fi

  # Canonical Immich upload destinations: modern images bind to /data, older ones
  # to /usr/src/app/upload.
  while IFS="$DET_FIELD_SEP" read -r type src dst; do
    [[ "$type" == "bind" ]] || continue
    if [[ "$dst" == "/data" || "$dst" == "/usr/src/app/upload" ]]; then
      DET_UPLOAD_LOCATION="$src"; DET_UPLOAD_CONTAINER="$dst"; return 0
    fi
  done <<< "$mounts"

  # Last resort: a bind mount whose host side actually holds a library/ folder.
  while IFS="$DET_FIELD_SEP" read -r type src dst; do
    [[ "$type" == "bind" ]] || continue
    if [[ -n "$src" && -d "$src/library" ]]; then
      DET_UPLOAD_LOCATION="$src"; DET_UPLOAD_CONTAINER="$dst"; return 0
    fi
  done <<< "$mounts"

  return 1
}

# detect_external_libraries <server_container> <upload_container_path>
# Echoes one "host_path<SEP>container_path" line per external-library candidate:
# bind mounts that are neither the upload mount nor Immich/system internals. The
# mount mode is not part of the filter.
detect_external_libraries() {
  local container="$1" upload_dst="$2"
  local mounts type src dst
  mounts=$(_inspect_mounts "$container")
  while IFS="$DET_FIELD_SEP" read -r type src dst; do
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
    printf '%s%s%s\n' "$src" "$DET_FIELD_SEP" "$dst"
  done <<< "$mounts"
}
