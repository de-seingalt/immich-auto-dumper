#!/usr/bin/env bash
set -euo pipefail

readonly LOCK_FILE="/tmp/immich-auto-dumper.lock"

# Global docker command determined by detect_docker_cmd.
DOCKER_CMD=""

# ── Logging ──────────────────────────────────────────────────────────────────

_log() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local line="[$timestamp] [$level] $message"

  if [[ -t 1 ]]; then
    case "$level" in
      INFO)  printf '\033[0;32m%s\033[0m\n' "$line" ;;
      WARN)  printf '\033[0;33m%s\033[0m\n' "$line" ;;
      ERROR) printf '\033[0;31m%s\033[0m\n' "$line" >&2 ;;
    esac
  else
    case "$level" in
      ERROR) printf '%s\n' "$line" >&2 ;;
      *)     printf '%s\n' "$line" ;;
    esac
  fi

  local log_file="${LOG_DIR:-/var/log/immich-auto-dumper}/immich-auto-dumper.log"
  mkdir -p "$(dirname "$log_file")"
  printf '%s\n' "$line" >> "$log_file"

  local max_lines="${LOG_MAX_LINES:-1000}"
  local current_lines
  current_lines=$(wc -l < "$log_file")
  if (( current_lines > max_lines )); then
    local tmp
    tmp=$(mktemp)
    tail -n "$max_lines" "$log_file" > "$tmp"
    mv "$tmp" "$log_file"
  fi
}

log_info()  { _log INFO  "$1"; }
log_warn()  { _log WARN  "$1"; }
log_error() { _log ERROR "$1"; }

# ── Prerequisites ─────────────────────────────────────────────────────────────

# Probe whether docker runs (with or without sudo) and set DOCKER_CMD.
# Non-fatal: returns 0 on success, 1 on failure. Used where exiting is undesirable
# (e.g. status). detect_docker_cmd wraps it and exits on failure.
probe_docker_cmd() {
  if docker ps &>/dev/null; then
    DOCKER_CMD="docker"
  elif sudo docker ps &>/dev/null; then
    DOCKER_CMD="sudo docker"
  else
    return 1
  fi
  return 0
}

# Detect whether docker runs without privileges and set DOCKER_CMD accordingly.
detect_docker_cmd() {
  if ! probe_docker_cmd; then
    log_error "Cannot run docker. Add yourself to the docker group: sudo usermod -aG docker \$USER (then re-login)."
    exit 1
  fi
}

check_prereqs() {
  detect_docker_cmd

  local missing=()
  # Runtime dependencies actually used by the scripts (jq/curl were only needed
  # by the removed Immich API integration). bc is used for byte arithmetic.
  for cmd in bc; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    log_error "Missing dependencies: ${missing[*]}"
    log_error "Install them before continuing."
    exit 1
  fi

  # Validate the Immich DB schema before any operation touches the database.
  if ! db_check_schema; then
    exit 1
  fi
}

# ── External storage availability ─────────────────────────────────────────────
#
# The destination is verified through a MARKER file written on the external
# storage itself, so the check is agnostic to the storage type (local dir, OS
# mount, FUSE/rclone, NFS, intermittently-attached disk...). The marker proves the
# storage is actually reachable: when an "external mount" is not active, its mount
# point is an empty local directory with no marker.

# Name of the marker file placed at the root of ARCHIVE_DEST_PATH.
readonly ARCHIVE_MARKER_NAME=".immich-auto-dumper.id"

# Quiet predicate: returns 0 if the storage is ready (marker present and, when an
# ARCHIVE_STORAGE_ID is configured, matching). No logging — for status/probes.
archive_dest_ready() {
  local marker="${ARCHIVE_DEST_PATH%/}/$ARCHIVE_MARKER_NAME"
  local id
  # timeout guards against a dead FUSE/rclone mount that would hang on read.
  id=$(timeout 10 cat "$marker" 2>/dev/null) || true
  [[ -n "$id" ]] || return 1
  [[ -z "${ARCHIVE_STORAGE_ID:-}" || "$id" == "$ARCHIVE_STORAGE_ID" ]]
}

# Logging variant used by destructive operations: logs the precise reason and
# returns 1 when the storage is not ready. Does not exit — caller decides.
check_archive_dest_ready() {
  local marker="${ARCHIVE_DEST_PATH%/}/$ARCHIVE_MARKER_NAME"
  local id
  id=$(timeout 10 cat "$marker" 2>/dev/null) || true
  if [[ -z "$id" ]]; then
    log_error "External storage not ready: marker '$marker' missing/unreadable. Is it mounted/connected?"
    return 1
  fi
  if [[ -n "${ARCHIVE_STORAGE_ID:-}" && "$id" != "$ARCHIVE_STORAGE_ID" ]]; then
    log_error "External storage mismatch: marker id != ARCHIVE_STORAGE_ID. Wrong volume mounted?"
    return 1
  fi
  return 0
}

# Best-effort liveness signal used ONLY at setup to decide whether to auto-create
# the marker. Returns 0 if <path> is backed by an active non-root mount (separate
# device / network / FUSE), 1 if it resolves to the root filesystem (plain local
# folder, or a mount that is currently down). findmnt --target also covers the case
# where the mount is at a parent directory (which mountpoint -q would miss).
archive_dest_is_mounted() {
  local path="$1"
  command -v findmnt &>/dev/null || return 1
  local target
  target=$(findmnt -nro TARGET --target "$path" 2>/dev/null | tail -1)
  [[ -n "$target" && "$target" != "/" ]]
}

# Writes the storage marker on the external storage and verifies the read-back.
# Returns 1 if the write or read-back fails (read-only / inactive mount).
write_archive_marker() {
  local id="$1"
  local marker="${ARCHIVE_DEST_PATH%/}/$ARCHIVE_MARKER_NAME"
  mkdir -p "$ARCHIVE_DEST_PATH" 2>/dev/null || true
  printf '%s\n' "$id" > "$marker" 2>/dev/null || return 1
  local back
  back=$(cat "$marker" 2>/dev/null) || true
  [[ "$back" == "$id" ]]
}

# ── Cron control ──────────────────────────────────────────────────────────────

# Comments out immich-auto-dumper entries in the current user's crontab.
# Returns 0 if entries were found and disabled, 1 if none were present.
disable_cron() {
  local current
  current=$(crontab -l 2>/dev/null || true)
  if printf '%s\n' "$current" | grep -q 'immich-auto-dumper' 2>/dev/null; then
    printf '%s\n' "$current" \
      | sed 's|^\([^#].*immich-auto-dumper.*\)|#\1|' \
      | crontab -
    return 0
  fi
  return 1
}

# ── Disk ──────────────────────────────────────────────────────────────────────

disk_usage_percent() {
  local path="$1"
  df --output=pcent "$path" | tail -1 | tr -d ' %'
}

bytes_to_human() {
  local bytes="$1"
  if (( bytes < 1024 )); then
    printf '%d B\n' "$bytes"
  elif (( bytes < 1048576 )); then
    printf '%.1f KB\n' "$(echo "scale=1; $bytes / 1024" | bc)"
  elif (( bytes < 1073741824 )); then
    printf '%.1f MB\n' "$(echo "scale=1; $bytes / 1048576" | bc)"
  else
    printf '%.2f GB\n' "$(echo "scale=2; $bytes / 1073741824" | bc)"
  fi
}

# ── Lock ──────────────────────────────────────────────────────────────────────

acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(cat "$LOCK_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      log_warn "Another operation is already running (PID $pid)."
      return 1
    fi
    # Stale lock — clean it up
    log_warn "Stale lock found (PID $pid), removing."
    rm -f "$LOCK_FILE"
  fi

  printf '%d\n' "$$" > "$LOCK_FILE"
}

release_lock() {
  rm -f "$LOCK_FILE"
}
