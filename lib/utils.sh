#!/usr/bin/env bash
set -euo pipefail

# Lock path of the file-based lock older versions used. Removed when the
# directory lock below is taken.
readonly LEGACY_LOCK_FILE="/tmp/immich-auto-dumper.lock"

# Docker command used throughout. The tool runs as the invoking user and never
# escalates privileges.
DOCKER_CMD="docker"

# ── Logging ──────────────────────────────────────────────────────────────────

# Writes one timestamped line at <level> to the terminal — coloured on a TTY,
# errors on stderr — and appends it to the log file.
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

  # A log directory that cannot be written skips file logging; it never aborts
  # the run. The default lives under the user's XDG state dir.
  local log_file="${LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper}/immich-auto-dumper.log"
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || return 0
  printf '%s\n' "$line" >> "$log_file" 2>/dev/null || return 0

  # Truncated to its last LOG_MAX_LINES lines once it grows past them.
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

# True when docker answers as the current user. Non-fatal, for callers that must
# not exit — status among them.
probe_docker_cmd() {
  docker ps &>/dev/null
}

# Logs why docker is unreachable and how to fix it without sudo.
_docker_access_advice() {
  if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    # Already in the group: the daemon is down, or the membership has not taken
    # effect in this session yet.
    log_error "Cannot reach the Docker daemon although '$USER' is in the docker group."
    log_error "Check the daemon is running (systemctl status docker), or open a new"
    log_error "session if you joined the docker group during this one."
  else
    log_error "Cannot run docker as '$USER'. This tool runs without sudo on purpose."
    log_error "Grant your user direct Docker access, then re-login:"
    log_error "  sudo usermod -aG docker $USER"
  fi
}

# Same probe, but exits with the advice above when docker does not answer.
detect_docker_cmd() {
  if ! probe_docker_cmd; then
    _docker_access_advice
    exit 1
  fi
}

# Pre-flight shared by every operation that touches Immich: docker reachable as
# this user, the external commands present, the database answering and its schema
# the one this tool expects. Logs the running Immich version. Exits on any
# failure, before anything has been done.
check_prereqs() {
  detect_docker_cmd

  local missing=() cmd
  # bc for byte arithmetic, sha256sum to prove two files identical before either
  # of them is deleted.
  for cmd in bc sha256sum; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    log_error "Missing dependencies: ${missing[*]}"
    log_error "Install them before continuing."
    exit 1
  fi

  # IMMICH_SOURCE_REF is the exact release baked into the image at build time;
  # IMMICH_VERSION, the fallback, is only the compose-file tag the user pinned.
  local immich_version
  immich_version=$($DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" sh -c \
    'printenv IMMICH_SOURCE_REF || printenv IMMICH_VERSION' 2>/dev/null </dev/null || true)
  log_info "Immich version: ${immich_version:-unknown}"

  # Asked before the schema, so that a database which is merely down gets its own
  # answer rather than being reported as a schema change.
  if ! _db_reachable; then
    log_error "The Immich database did not answer (container '${IMMICH_DB_CONTAINER}')."
    log_error "Nothing was checked and nothing was changed. Is the container running?"
    log_error "  docker ps --filter name=${IMMICH_DB_CONTAINER}"
    exit 1
  fi

  if ! db_check_schema; then
    exit 1
  fi
}

# ── External storage availability ─────────────────────────────────────────────
#
# The destination is verified through a MARKER file on the external storage
# itself, which makes the check agnostic to the storage type: local directory, OS
# mount, FUSE/rclone, NFS, an intermittently-attached disk. An inactive mount
# point is an empty local directory, and carries no marker.

# Name of the marker file placed at the root of ARCHIVE_DEST_PATH.
readonly ARCHIVE_MARKER_NAME=".immich-auto-dumper.id"

# Reads the marker and says what it found, following the diagnostic convention:
#
#   0  the storage is there, is the expected volume, and Immich can see it too
#   1  a clear negative — no marker (storage absent), or another volume's marker
#   2  no conclusion — the read timed out, the marker is there but unreadable, or
#      the host can read it and the Immich container cannot
#
# Echoes nothing, and sets _ARCHIVE_DEST_REASON for callers that explain
# themselves.
_ARCHIVE_DEST_REASON=""
_archive_dest_state() {
  local marker="${ARCHIVE_DEST_PATH%/}/$ARCHIVE_MARKER_NAME"
  local id rc=0
  # Bounded, since a dead FUSE/rclone mount hangs on read. timeout's own exit
  # code 124 is what tells a hang from a missing file.
  id=$(timeout 10 cat -- "$marker" 2>/dev/null) || rc=$?

  if (( rc == 124 )); then
    _ARCHIVE_DEST_REASON="reading '$marker' timed out after 10s — the mount is not answering"
    return 2
  fi

  if (( rc == 0 )); then
    if [[ -z "$id" ]]; then
      _ARCHIVE_DEST_REASON="marker '$marker' is present but empty — the volume cannot be identified"
      return 2
    fi
    if [[ -n "${ARCHIVE_STORAGE_ID:-}" && "$id" != "$ARCHIVE_STORAGE_ID" ]]; then
      # Another volume's marker answers 1, the same code as no marker at all:
      # in both cases the destination is not the one this configuration
      # describes, and the only safe response is to act on nothing.
      _ARCHIVE_DEST_REASON="marker id does not match ARCHIVE_STORAGE_ID — wrong volume mounted?"
      return 1
    fi
    # The host seeing the storage is not Immich seeing it, so the marker is read
    # again from inside the container. Only asked when Docker answers at all,
    # since a Docker that is down is a fault of its own.
    if [[ -n "${IMMICH_SERVER_CONTAINER:-}" && -n "${ARCHIVE_CONTAINER_PATH:-}" ]] \
       && probe_docker_cmd 2>/dev/null; then
      local seen_by_container
      seen_by_container=$(timeout 15 $DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" \
        cat "${ARCHIVE_CONTAINER_PATH%/}/$ARCHIVE_MARKER_NAME" 2>/dev/null </dev/null || true)
      if [[ "$seen_by_container" != "$id" ]]; then
        _ARCHIVE_DEST_REASON="readable from this host but NOT from the Immich container at ${ARCHIVE_CONTAINER_PATH%/} — mount replaced under the container? Restart it: docker restart $IMMICH_SERVER_CONTAINER"
        return 2
      fi
    fi
    _ARCHIVE_DEST_REASON=""
    return 0
  fi

  # The read failed without hanging: the marker is either absent — the storage is
  # not mounted — or present and unreadable, which is the fault. The existence
  # test is bounded too, since the mount may be sick.
  if timeout 5 ls -d -- "$marker" >/dev/null 2>&1; then
    _ARCHIVE_DEST_REASON="marker '$marker' exists but cannot be read — permissions, or a failing mount"
    return 2
  fi
  _ARCHIVE_DEST_REASON="marker '$marker' is missing — is the storage mounted/connected?"
  return 1
}

# Quiet form of the state above, for status and probes: 0 ready, 1 absent or
# wrong volume, 2 unknown. Writes nothing.
archive_dest_ready() {
  _archive_dest_state
}

# Logging form, for the operations that write: the same codes, with the reason
# logged. Never exits — what a 1 and a 2 mean is the caller's to decide.
check_archive_dest_ready() {
  local state=0
  _archive_dest_state || state=$?
  case $state in
    0) return 0 ;;
    1) log_error "External storage not ready: ${_ARCHIVE_DEST_REASON}"
       return 1 ;;
    *) log_error "External storage state undetermined: ${_ARCHIVE_DEST_REASON}"
       log_error "Refusing to act on a destination that cannot be verified."
       return 2 ;;
  esac
}

# True when <path> is backed by an active non-root mount — a separate device, a
# network or FUSE filesystem. False when it resolves to the root filesystem: a
# plain local folder, or a mount that is currently down. `findmnt --target` also
# covers a mount at a parent directory. Used by setup alone.
archive_dest_is_mounted() {
  local path="$1"
  command -v findmnt &>/dev/null || return 1
  local target
  target=$(findmnt -nro TARGET --target "$path" 2>/dev/null | tail -1)
  [[ -n "$target" && "$target" != "/" ]]
}

# Writes the storage marker at the root of ARCHIVE_DEST_PATH and reads it back.
# Returns 1 when either fails: a read-only or inactive mount.
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

# Echoes what the tool's crontab entries are currently doing:
#   active   — at least one live (uncommented) immich-auto-dumper schedule
#   disabled — schedules present but commented out, as `stop` leaves them
#   absent   — no immich-auto-dumper schedule at all
# Only a line whose payload starts like a cron schedule — a digit, '*' or '@' —
# counts as one. The commented form matched here is the one disable_cron writes
# and `start` reverses.
cron_state() {
  local current
  current=$(crontab -l 2>/dev/null || true)
  if printf '%s\n' "$current" | grep -qE '^[0-9*@].*immich-auto-dumper'; then
    printf 'active\n'
  elif printf '%s\n' "$current" | grep -qE '^#[0-9*@].*immich-auto-dumper'; then
    printf 'disabled\n'
  else
    printf 'absent\n'
  fi
}

# Echoes the tool's crontab schedules, live and commented out, for display.
cron_entries() {
  crontab -l 2>/dev/null | grep -E '^#?[0-9*@].*immich-auto-dumper' || true
}

# Comments out the tool's live schedule lines in the current user's crontab.
# Returns 0 when live schedules were found and disabled, 1 when there were none.
# Touches only schedule lines, the set cron_state reports on and `start`
# re-enables.
disable_cron() {
  local current
  current=$(crontab -l 2>/dev/null || true)
  if printf '%s\n' "$current" | grep -qE '^[0-9*@].*immich-auto-dumper'; then
    printf '%s\n' "$current" \
      | sed 's|^\([0-9*@].*immich-auto-dumper.*\)|#\1|' \
      | crontab -
    return 0
  fi
  return 1
}

# ── File identity ─────────────────────────────────────────────────────────────
#
# Two files count as the same only when their SHA-256 match, never on their size.
# On a remote mount that reads the whole file back.

# Echoes the SHA-256 of <file>, or fails (1) when it cannot be computed. Never
# echoes an empty digest, so a successful return can be trusted.
file_fingerprint() {
  local f="$1" h
  h=$(sha256sum -- "$f" 2>/dev/null | cut -d' ' -f1) || return 1
  [[ -n "$h" ]] || return 1
  printf '%s' "$h"
}

# 0 when <a> and <b> are byte-for-byte identical, 1 when they differ, 2 when it
# cannot be determined: an unreadable file, a dead mount, a timeout. Callers are
# expected to treat 2 as "touch nothing", never as a yes.
files_are_identical() {
  local a="$1" b="$2" ha hb
  ha=$(file_fingerprint "$a") || return 2
  hb=$(file_fingerprint "$b") || return 2
  [[ "$ha" == "$hb" ]]
}

# Pushes a freshly written file out of the page cache, before it is verified and
# before any source is deleted. `sync -d` flushes that one file where it is
# supported, and the whole filesystem otherwise.
#
# On a local disk, a USB drive or a mounted NAS the file is on the medium when
# this returns. On a write-back mount (rclone, async NFS) it is not: the upload
# may still be pending, and a read-back is served by the local cache.
file_flush() {
  sync -d -- "$1" 2>/dev/null || sync 2>/dev/null || true
}

# ── Disk ──────────────────────────────────────────────────────────────────────

# Apparent size of a directory — the sum of its file sizes — in bytes, and 0 when
# it is absent or unreadable.
dir_size_bytes() {
  local path="$1"
  [[ -d "$path" ]] || { printf '0\n'; return 0; }
  # Captured, then validated: du can exit non-zero while still printing a partial
  # total. Exactly one integer is echoed, whatever happens.
  local size
  size=$(du -sb "$path" 2>/dev/null | cut -f1) || true
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  printf '%s\n' "$size"
}

# Total and available size, in bytes, of the filesystem hosting <path>. Echo 0
# when the path is empty or missing, which callers read as "no disk info".
#
# POSIX `df -kP`: 1K blocks and the portable column layout, which guarantees one
# data line even when the device name is long enough to wrap.
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

# Echoes <bytes> as a readable label: "512 B", "1.5 KB", "12.3 MB", "1.25 GB".
bytes_to_human() {
  local bytes="$1"
  # bc rounds and prints the decimal string itself, emitted with %s. printf %f
  # would reject bc's dotted output under a ',' decimal locale.
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
#
# Two runs must never overlap: they rewrite the same DB rows and copy to the same
# destination. The lock is a DIRECTORY, taken with `mkdir`, which either creates
# it or fails with nothing in between and does not follow a symlink planted at
# the path.

# Echoes the lock path, beside the logs and not under $XDG_RUNTIME_DIR, which a
# cron run does not have. LOG_DIR is the same in both contexts.
lock_dir_path() {
  printf '%s/immich-auto-dumper.lock.d\n' \
    "${LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper}"
}

# Identifies the boot the recorded PID belongs to, since a lock directory
# survives a reboot and a PID does not. Empty when unavailable, which skips the
# check in _lock_holder_alive.
_boot_id() {
  cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
}

# True when the recorded holder is still running, from this boot.
_lock_holder_alive() {
  local dir="$1" pid="$2"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  local recorded now
  recorded=$(cat -- "$dir/boot" 2>/dev/null || true)
  now=$(_boot_id)
  [[ -z "$recorded" || -z "$now" || "$recorded" == "$now" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

# Echoes "active <pid>", "stale <pid>" or "inactive". Read-only: it reports on
# the lock without ever taking it.
lock_state() {
  local dir
  dir=$(lock_dir_path)
  [[ -d "$dir" ]] || { printf 'inactive\n'; return 0; }
  local pid
  pid=$(cat -- "$dir/pid" 2>/dev/null || true)
  if _lock_holder_alive "$dir" "$pid"; then
    printf 'active %s\n' "$pid"
  else
    printf 'stale %s\n' "${pid:-unknown}"
  fi
}

# Takes the lock, recording this PID and this boot in it. Returns 0 when it is
# held, 1 when another live run holds it or it could not be taken. A lock found
# orphaned is claimed on the second go.
acquire_lock() {
  local dir
  dir=$(lock_dir_path)
  mkdir -p -- "$(dirname -- "$dir")" 2>/dev/null || true

  # Two goes: the first may find an orphaned lock, the second then claims it.
  local attempt
  # shellcheck disable=SC2034  # the counter bounds the retries, it is never read
  for attempt in 1 2; do
    if mkdir -- "$dir" 2>/dev/null; then
      printf '%d\n' "$$" > "$dir/pid"
      _boot_id > "$dir/boot" 2>/dev/null || true
      # Released on interruption as well as on exit.
      trap 'release_lock' EXIT
      trap 'release_lock; exit 130' INT TERM
      rm -f -- "$LEGACY_LOCK_FILE" 2>/dev/null || true
      return 0
    fi

    # Someone holds it. The holder writes its PID just after mkdir, so an absent
    # PID file is given a moment to appear before the lock is called orphaned.
    local pid
    pid=$(cat -- "$dir/pid" 2>/dev/null || true)
    if [[ -z "$pid" ]]; then
      sleep 1
      pid=$(cat -- "$dir/pid" 2>/dev/null || true)
    fi

    if _lock_holder_alive "$dir" "$pid"; then
      log_warn "Another operation is already running (PID $pid)."
      return 1
    fi

    # Orphaned, and claimed by renaming it aside: rename() succeeds for exactly
    # one process, where a plain `rm -rf` would let a loser delete the winner's
    # fresh lock.
    log_warn "Stale lock found (PID ${pid:-unknown}), removing."
    local doomed="$dir.stale.$$"
    if mv -- "$dir" "$doomed" 2>/dev/null; then
      rm -rf -- "$doomed"
    fi
  done

  log_warn "Could not acquire the lock at $dir."
  return 1
}

# Removes the lock, and only when this process is the one holding it. Idempotent,
# so the explicit call and the EXIT trap can both run.
release_lock() {
  local dir
  dir=$(lock_dir_path)
  local pid
  pid=$(cat -- "$dir/pid" 2>/dev/null || true)
  [[ "$pid" == "$$" ]] || return 0
  rm -rf -- "$dir"
}
