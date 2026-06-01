#!/usr/bin/env bash
set -euo pipefail

readonly LOCK_FILE="/tmp/immich-auto-dumper.lock"

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

  # LOG_DIR peut venir de config.conf, évalué à l'appel et non à la source.
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

# ── Prérequis ─────────────────────────────────────────────────────────────────

check_prereqs() {
  local missing=()
  for cmd in docker jq bc curl; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    log_error "Dépendances manquantes : ${missing[*]}"
    log_error "Installez-les avant de continuer."
    exit 1
  fi
}

# ── Stockage externe ───────────────────────────────────────────────────────────

check_archive_dest_mounted() {
  if mountpoint -q "$ARCHIVE_DEST_PATH"; then
    return 0
  fi
  return 1
}

# ── Disque ────────────────────────────────────────────────────────────────────

disk_usage_percent() {
  local path="$1"
  df --output=pcent "$path" | tail -1 | tr -d ' %'
}

bytes_to_human() {
  local bytes="$1"
  if (( bytes < 1024 )); then
    printf '%d o\n' "$bytes"
  elif (( bytes < 1048576 )); then
    printf '%.1f Ko\n' "$(echo "scale=1; $bytes / 1024" | bc)"
  elif (( bytes < 1073741824 )); then
    printf '%.1f Mo\n' "$(echo "scale=1; $bytes / 1048576" | bc)"
  else
    printf '%.2f Go\n' "$(echo "scale=2; $bytes / 1073741824" | bc)"
  fi
}

# ── Lock ──────────────────────────────────────────────────────────────────────

acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(cat "$LOCK_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      log_warn "Une opération est déjà en cours (PID $pid)."
      return 1
    fi
    # PID mort : lock orphelin, on le nettoie
    log_warn "Lock orphelin trouvé (PID $pid), nettoyage."
    rm -f "$LOCK_FILE"
  fi

  printf '%d\n' "$$" > "$LOCK_FILE"
}

release_lock() {
  rm -f "$LOCK_FILE"
}
