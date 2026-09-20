#!/usr/bin/env bash
set -euo pipefail

# Lock path used by versions up to and including the file-based lock. Removed on
# the first run of the new directory lock so it does not linger in /tmp forever.
readonly LEGACY_LOCK_FILE="/tmp/immich-auto-dumper.lock"

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
  # by the removed Immich API integration). bc is used for byte arithmetic,
  # sha256sum to prove two files are the same before deleting either of them.
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

  # Log the running Immich version so schema failures in the log can be tied to
  # the exact Immich upgrade that introduced them. Purely informational.
  # IMMICH_SOURCE_REF is baked into the image at build time (exact release, e.g.
  # v2.7.5); IMMICH_VERSION is only the compose-file tag the user pinned (can be
  # a bare major or "release") and serves as fallback.
  local immich_version
  immich_version=$($DOCKER_CMD exec "$IMMICH_SERVER_CONTAINER" sh -c \
    'printenv IMMICH_SOURCE_REF || printenv IMMICH_VERSION' 2>/dev/null </dev/null || true)
  log_info "Immich version: ${immich_version:-unknown}"

  # Asked before the schema, so the two get different answers. A stopped database
  # container used to surface as "Schema check failed … update this script if
  # needed" — an invitation to edit a tool that writes to that database, over a
  # container that only needed starting.
  if ! _db_reachable; then
    log_error "The Immich database did not answer (container '${IMMICH_DB_CONTAINER}')."
    log_error "Nothing was checked and nothing was changed. Is the container running?"
    log_error "  docker ps --filter name=${IMMICH_DB_CONTAINER}"
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

# Reads the marker and says what it found, following the diagnostic convention:
#
#   0  the storage is there, is the expected volume, and Immich can see it too
#   1  a clear negative — no marker (storage absent), or another volume's marker
#   2  no conclusion — the read timed out, the marker is there but unreadable, or
#      the host can read it and the Immich container cannot
#
# 1 and 2 are not the same situation and must not lead to the same decision: a
# removable disk that is simply unplugged is normal and a run should end quietly,
# while a mount that hangs or denies reads is a fault worth surfacing.
#
# Echoes nothing; _archive_dest_state sets _ARCHIVE_DEST_REASON for callers that
# want to explain themselves.
_ARCHIVE_DEST_REASON=""
_archive_dest_state() {
  local marker="${ARCHIVE_DEST_PATH%/}/$ARCHIVE_MARKER_NAME"
  local id rc=0
  # timeout guards against a dead FUSE/rclone mount that would hang on read. Its
  # own exit code 124 is what tells a hang apart from a missing file.
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
      _ARCHIVE_DEST_REASON="marker id does not match ARCHIVE_STORAGE_ID — wrong volume mounted?"
      return 1
    fi
    # The host seeing the storage is not the same thing as Immich seeing it. In the
    # state that caused the 11 September incident the host read the marker fine
    # while the container answered "Transport endpoint is not connected" — and the
    # tool reported itself green, archived nothing and alerted nobody.
    #
    # Only asked when Docker answers at all: "Docker is down" is a different fault,
    # reported in its own right, and must not masquerade as a storage problem.
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

  # The read failed without hanging: either the marker is not there (the storage
  # is simply not mounted) or it is there and we cannot read it. Only the second
  # is a fault. The existence test is itself bounded, since the mount may be sick.
  if timeout 5 ls -d -- "$marker" >/dev/null 2>&1; then
    _ARCHIVE_DEST_REASON="marker '$marker' exists but cannot be read — permissions, or a failing mount"
    return 2
  fi
  _ARCHIVE_DEST_REASON="marker '$marker' is missing — is the storage mounted/connected?"
  return 1
}

# Quiet predicate for status and probes: 0 ready, 1 absent/wrong volume, 2 unknown.
# Callers that only test truth are unaffected; those that care can read the code.
archive_dest_ready() {
  _archive_dest_state
}

# Logging variant used by destructive operations. Same codes, with the reason
# written to the log. Does not exit — the caller decides what a 1 and a 2 mean
# for it.
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

# Echoes what our crontab entries are currently doing:
#   active   — at least one live (uncommented) immich-auto-dumper schedule
#   disabled — schedules present but commented out (what `stop` leaves behind)
#   absent   — no immich-auto-dumper schedule at all
# Only lines whose payload starts like a cron schedule (digit, '*' or '@') count, so
# a plain user comment mentioning the tool is never reported as a job. The commented
# form matched here is exactly the one disable_cron writes and `start` reverses.
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

# Echoes our crontab schedules (live and commented out), for display to the user.
cron_entries() {
  crontab -l 2>/dev/null | grep -E '^#?[0-9*@].*immich-auto-dumper' || true
}

# Comments out our schedule lines in the current user's crontab.
# Returns 0 if live schedules were found and disabled, 1 if there were none.
#
# Only schedule lines are touched — the same set cron_state reports on and `start`
# re-enables. The pattern used to comment out ANY uncommented line merely containing
# "immich-auto-dumper", so a MAILTO= or PATH= line mentioning the tool's path was
# commented out too; `start`'s un-comment step only restores lines whose payload
# starts with a digit, '*' or '@', so such a line stayed disabled for good.
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
# Whenever the tool concludes that two files are "the same" it is about to delete
# one of them, so the conclusion has to be earned. Size equality is not: a foreign
# file that happened to match the source byte count was accepted as an already
# archived copy, the DB was pointed at it and the original photo deleted.
#
# The cost is real — on a remote mount this reads the whole file back — and it is
# the price of the guarantee. The alternative was measured, and it destroys photos.

# Echoes the SHA-256 of <file>, or fails (1) if it cannot be computed. Never
# echoes an empty digest: callers must be able to trust a successful return.
file_fingerprint() {
  local f="$1" h
  h=$(sha256sum -- "$f" 2>/dev/null | cut -d' ' -f1) || return 1
  [[ -n "$h" ]] || return 1
  printf '%s' "$h"
}

# 0 if <a> and <b> are byte-for-byte identical, 1 if they differ, 2 if it cannot
# be determined (unreadable file, dead mount, timeout).
#
# The third code is the whole point. The defect this replaces compared two `stat`
# calls that had BOTH failed, read 0 == 0, and concluded "identical". An unknown
# must never collapse into a yes; callers are expected to handle 2 as "do not
# touch anything".
files_are_identical() {
  local a="$1" b="$2" ha hb
  ha=$(file_fingerprint "$a") || return 2
  hb=$(file_fingerprint "$b") || return 2
  [[ "$ha" == "$hb" ]]
}

# Pushes a freshly written file out of the page cache before anything is verified
# against it and, above all, before any source is deleted.
#
# When cp returns, the data may only be in memory. A size check then reports the
# right number — it is reading that same cache — so the copy looks complete and
# the source gets deleted; a power cut in between would leave a truncated file
# and no original. `sync -d` flushes just this file where that is supported,
# otherwise the whole filesystem, which is slower but never wrong.
#
# Honest limit: on an rclone mount this does not guarantee the remote upload has
# finished. It closes the window fully on a local disk, a USB drive or a mounted
# NAS; on a write-back cloud mount it only narrows it.
file_flush() {
  sync -d -- "$1" 2>/dev/null || sync 2>/dev/null || true
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
#
# Two runs must never overlap: they rewrite the same DB rows and copy to the same
# destination. The previous lock tested for a file and then created it, and that
# gap was wide enough to walk through — two simultaneous forced dumps both started
# in one attempt out of five.
#
# `mkdir` closes it: the kernel either creates the directory or fails, with
# nothing in between, and it does not follow a symlink planted at the path.
# `flock` would do as well, but this tool restricts itself to tools present
# everywhere, and mkdir is as universal as it gets.

# The lock lives beside the logs, NOT under $XDG_RUNTIME_DIR: cron runs have no
# runtime dir, so keying the path on it would give the nightly run and a manual
# one two different locks — i.e. no mutual exclusion in exactly the case that
# matters. LOG_DIR is configured, stable and the same in both contexts.
lock_dir_path() {
  printf '%s/immich-auto-dumper.lock.d\n' \
    "${LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper}"
}

# Identifies the boot the recorded PID belongs to. A lock directory on persistent
# storage survives a reboot, after which that PID may well be alive again as an
# unrelated process — which would jam every subsequent run with a bogus "already
# running". Empty when unavailable, in which case the check is simply skipped.
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

# Echoes "active <pid>", "stale <pid>" or "inactive". Read-only: used by status
# and stop, which must report on the lock without ever taking it.
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

acquire_lock() {
  local dir
  dir=$(lock_dir_path)
  mkdir -p -- "$(dirname -- "$dir")" 2>/dev/null || true

  local attempt
  for attempt in 1 2; do
    if mkdir -- "$dir" 2>/dev/null; then
      printf '%d\n' "$$" > "$dir/pid"
      _boot_id > "$dir/boot" 2>/dev/null || true
      # Release on interruption too — nothing used to, so a Ctrl-C left a lock
      # that only the next run's staleness check would clear.
      trap 'release_lock' EXIT
      trap 'release_lock; exit 130' INT TERM
      rm -f -- "$LEGACY_LOCK_FILE" 2>/dev/null || true
      return 0
    fi

    # Someone holds it. The holder writes its PID just after mkdir, so an absent
    # PID file most often means "a run that started microseconds ago" — the very
    # case this rewrite exists to serialise. Give it a moment to appear before
    # declaring the lock orphaned, or two simultaneous starts would each decide
    # the other's fresh lock was stale.
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

    # Orphaned. Claim it by renaming: rename() succeeds for exactly one process,
    # so a loser can never delete the fresh lock the winner just created — which
    # a plain `rm -rf` here would let it do.
    log_warn "Stale lock found (PID ${pid:-unknown}), removing."
    local doomed="$dir.stale.$$"
    if mv -- "$dir" "$doomed" 2>/dev/null; then
      rm -rf -- "$doomed"
    fi
  done

  log_warn "Could not acquire the lock at $dir."
  return 1
}

# Removes the lock only if we are the process holding it. Idempotent, so the
# explicit call and the EXIT trap can both run.
release_lock() {
  local dir
  dir=$(lock_dir_path)
  local pid
  pid=$(cat -- "$dir/pid" 2>/dev/null || true)
  [[ "$pid" == "$$" ]] || return 0
  rm -rf -- "$dir"
}
