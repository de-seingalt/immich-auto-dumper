#!/usr/bin/env bash
set -euo pipefail

readonly LOCK_FILE="/tmp/immich-auto-dumper.lock"

# Docker command used throughout. This tool runs strictly as the invoking user and
# never escalates privileges (no sudo): it is a matter of trust for its users.
DOCKER_CMD="docker"

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

  # File logging must never abort the program (set -e). If the log directory is not
  # writable — e.g. the old /var/log default under a non-root, no-sudo install — we
  # simply skip file logging instead of killing the run. Default lives under the
  # user's XDG state dir so it works without privileges.
  local log_file="${LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper}/immich-auto-dumper.log"
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || return 0
  printf '%s\n' "$line" >> "$log_file" 2>/dev/null || return 0

  local max_lines="${LOG_MAX_LINES:-1000}"
  local current_lines
  current_lines=$(wc -l < "$log_file" 2>/dev/null || echo 0)
  if (( current_lines > max_lines )); then
    local tmp
    tmp=$(mktemp 2>/dev/null) || return 0
    if tail -n "$max_lines" "$log_file" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$log_file" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi
}

log_info()  { _log INFO  "$1"; }
log_warn()  { _log WARN  "$1"; }
log_error() { _log ERROR "$1"; }

# ── Prerequisites ─────────────────────────────────────────────────────────────

# Probe whether docker runs as the current (unprivileged) user.
# Non-fatal: returns 0 on success, 1 on failure. Used where exiting is undesirable
# (e.g. status). detect_docker_cmd wraps it and exits on failure.
# This tool never uses sudo: if the user cannot reach the daemon directly, it is
# advised to join the docker group rather than having the script escalate for them.
probe_docker_cmd() {
  docker ps &>/dev/null
}

# Build advice explaining why docker is unreachable and how to fix it without sudo.
_docker_access_advice() {
  if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    # Already in the group: either the daemon is down or the group membership has
    # not taken effect in this session yet.
    log_error "Cannot reach the Docker daemon although '$USER' is in the docker group."
    log_error "Check the daemon is running (systemctl status docker), or open a new"
    log_error "session if you joined the docker group during this one."
  else
    log_error "Cannot run docker as '$USER'. This tool runs without sudo on purpose."
    log_error "Grant your user direct Docker access, then re-login:"
    log_error "  sudo usermod -aG docker $USER"
  fi
}

# Verify docker runs as the current user. Exits on failure with actionable advice.
detect_docker_cmd() {
  if ! probe_docker_cmd; then
    _docker_access_advice
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

  # Log the running Immich version so schema failures in the log can be tied to
  # the exact Immich upgrade that introduced them. Purely informational.
  # IMMICH_SOURCE_REF is baked into the image at build time (exact release, e.g.
  # v2.7.5); IMMICH_VERSION is only the compose-file tag the user pinned (can be
  # a bare major or "release") and serves as fallback.
  local immich_version
  immich_version=$($DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" sh -c \
    'printenv IMMICH_SOURCE_REF || printenv IMMICH_VERSION' 2>/dev/null </dev/null || true)
  log_info "Immich version: ${immich_version:-unknown}"

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

# Apparent size (sum of file sizes) of a directory, in bytes. 0 if absent/unreadable.
# Measures the library directory itself rather than the whole filesystem, so archiving
# is driven by Immich's actual footprint, not by unrelated data on the same disk.
dir_size_bytes() {
  local path="$1"
  [[ -d "$path" ]] || { printf '0\n'; return 0; }
  # Capture then validate. du can exit non-zero (e.g. an unreadable subdir under a
  # no-sudo install) while still printing a partial total; with pipefail that would
  # trip set -e, and chaining `|| printf 0` onto the pipeline would emit a SECOND
  # line on top of du's output, corrupting later arithmetic. Keep one clean integer.
  local size
  size=$(du -sb "$path" 2>/dev/null | cut -f1) || true
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  printf '%s\n' "$size"
}

# Total / available size, in bytes, of the filesystem hosting <path>. Used only to
# show hints and to translate a percentage boundary into an absolute size.
#
# Uses POSIX `df -kP` (1K-blocks, portable column layout) rather than GNU-only
# `df -B1 --output=...`, which silently produced empty output on non-GNU df and
# left the wizard showing "0 B total". The -P "portable" format guarantees one
# data line even when the device name is long enough to wrap. Output is 0 when
# the path is empty/missing so callers can detect "no disk info".
disk_total_bytes() {
  local v
  v=$(df -kP "$1" 2>/dev/null | awk 'NR==2 {printf "%.0f", $2 * 1024}')
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s\n' "$v" || printf '0\n'
}
disk_free_bytes() {
  local v
  v=$(df -kP "$1" 2>/dev/null | awk 'NR==2 {printf "%.0f", $4 * 1024}')
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s\n' "$v" || printf '0\n'
}

bytes_to_human() {
  local bytes="$1"
  # bc does the rounding and prints the decimal string itself (always with a '.'),
  # which is then emitted with %s. Passing bc's dotted output to printf %f would
  # fail under locales whose decimal separator is ',' (e.g. fr_FR): "invalid number".
  if (( bytes < 1024 )); then
    printf '%d B\n' "$bytes"
  elif (( bytes < 1048576 )); then
    printf '%s KB\n' "$(echo "scale=1; $bytes / 1024" | bc)"
  elif (( bytes < 1073741824 )); then
    printf '%s MB\n' "$(echo "scale=1; $bytes / 1048576" | bc)"
  else
    printf '%s GB\n' "$(echo "scale=2; $bytes / 1073741824" | bc)"
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
