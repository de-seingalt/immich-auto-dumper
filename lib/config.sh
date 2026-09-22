#!/usr/bin/env bash
# shellcheck disable=SC2034  # the settings assigned below are this file's output
set -euo pipefail

# ── config.conf, read as data ─────────────────────────────────────────────────
#
# config.conf is parsed, never evaluated. A line is a setting and a value; the
# setting must be one this tool knows; the value must match what that setting is
# allowed to hold. Surrounding quotes are stripped as punctuation. A setting that
# cannot be used is a refusal at load, named by line number.

# Settings only the wizard can answer: they identify this Immich install. Their
# absence is a refusal, not a backfill.
_CFG_ESSENTIAL_KEYS=(
  IMMICH_UPLOAD_LOCATION IMMICH_DB_LIBRARY_PREFIX IMMICH_DB_CONTAINER
  IMMICH_SERVER_CONTAINER IMMICH_DB_NAME IMMICH_DB_USER
  ARCHIVE_DEST_PATH ARCHIVE_CONTAINER_PATH ARCHIVE_STORAGE_ID
)

# Findings from the last config_load, read back by _config_check.
CFG_LOAD_PROBLEMS=()
# True when the file carries the `declare -A USER_MAP` form, which setup rewrites
# on its next run.
CFG_LEGACY_USER_MAP=false
# Keys the file actually assigned. Tells "missing" from "set to something
# unusable", and from a name that only exists in the environment.
declare -A _CFG_SEEN=()

# Echoes <s> without its leading and trailing whitespace.
_cfg_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Rewrites a leading "~/" or "$HOME/" as the home directory, substituted as text.
# Exactly those two prefixes; nothing else in the value is touched.
# shellcheck disable=SC2088  # literal patterns to match, not paths to expand
_cfg_expand_home() {
  local v="$1"
  case "$v" in
    '~'|'$HOME')         printf '%s' "$HOME" ;;
    '~/'*)               printf '%s%s' "$HOME" "${v#\~}" ;;
    '$HOME/'*)           printf '%s%s' "$HOME" "${v#\$HOME}" ;;
    *)                   printf '%s' "$v" ;;
  esac
}

# Records a fault in CFG_LOAD_PROBLEMS and logs it, prefixed by <where> when the
# fault has a line number.
_cfg_reject() {
  local where="$1" message="$2"
  CFG_LOAD_PROBLEMS+=("config.conf${where:+:$where} — $message")
  log_error "config.conf${where:+:$where} — $message"
}

# Validates one setting and assigns it. Returns 1 on anything unexpected, naming
# the offending line; the caller keeps reading, so every fault is reported.
config_set() {
  local key="$1" value="$2" line="$3"

  # Caught before anything else: an empty name is not a valid subscript for
  # _CFG_SEEN below.
  if [[ -z "$key" ]]; then
    _cfg_reject "$line" "a setting name is missing before the '='."
    return 1
  fi

  # A setting assigned twice keeps the later value, with a warning.
  if [[ -n "${_CFG_SEEN[$key]:-}" ]]; then
    log_warn "config.conf:$line — $key is set more than once; this later value ('${value}') wins over the earlier one."
  fi

  # Recorded before validation, so a setting the file named badly is reported as
  # invalid and not also as missing.
  _CFG_SEEN["$key"]=1

  case "$key" in
    IMMICH_UPLOAD_LOCATION|IMMICH_DB_LIBRARY_PREFIX|ARCHIVE_DEST_PATH|ARCHIVE_CONTAINER_PATH)
      value=$(_cfg_expand_home "$value")
      if [[ "$value" != /* ]]; then
        _cfg_reject "$line" "$key must be an absolute path (found '${value}')."
        return 1
      fi
      printf -v "$key" '%s' "$value"
      ;;

    LOG_DIR)
      value=$(_cfg_expand_home "$value")
      if [[ "$value" != /* ]]; then
        # The one path setting that falls back instead of being refused.
        local fallback="${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper"
        log_warn "config.conf:$line — LOG_DIR is not an absolute path ('${value}'); using $fallback instead."
        value="$fallback"
      fi
      LOG_DIR="$value"
      ;;

    IMMICH_DB_CONTAINER|IMMICH_SERVER_CONTAINER)
      if ! [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
        _cfg_reject "$line" "$key must be a Docker container name (found '${value}')."
        return 1
      fi
      printf -v "$key" '%s' "$value"
      ;;

    IMMICH_DB_NAME|IMMICH_DB_USER)
      if ! [[ "$value" =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]]; then
        _cfg_reject "$line" "$key must be a PostgreSQL identifier (found '${value}')."
        return 1
      fi
      printf -v "$key" '%s' "$value"
      ;;

    ARCHIVE_STORAGE_ID)
      # Empty is allowed here and nowhere else: it accepts whatever marker the
      # storage carries, instead of pinning the destination to one volume.
      if [[ -n "$value" ]] && ! [[ "$value" =~ ^[A-Za-z0-9._-]{4,64}$ ]]; then
        _cfg_reject "$line" "ARCHIVE_STORAGE_ID must be a plain identifier of 4 to 64 characters (found '${value}')."
        return 1
      fi
      ARCHIVE_STORAGE_ID="$value"
      ;;

    ARCHIVE_LIBRARY_MAX_MB|ARCHIVE_LIBRARY_TARGET_MB|ARCHIVE_LIBRARY_MAX_GB|ARCHIVE_LIBRARY_TARGET_GB|BACKUP_RETENTION|LOG_MAX_LINES)
      if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
        _cfg_reject "$line" "$key must be a whole number of 1 or more (found '${value}')."
        return 1
      fi
      printf -v "$key" '%s' "$value"
      ;;

    ARCHIVE_MIN_FREE_MB)
      # The one number allowed to be zero, which disables the free-disk trigger.
      if ! [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]]; then
        _cfg_reject "$line" "ARCHIVE_MIN_FREE_MB must be a whole number of 0 or more (found '${value}')."
        return 1
      fi
      ARCHIVE_MIN_FREE_MB="$value"
      ;;

    USER_MAP.*)
      local map_key="${key#USER_MAP.}"
      if [[ -z "$map_key" ]]; then
        _cfg_reject "$line" "a USER_MAP entry needs a user key, as in USER_MAP.admin=Photos."
        return 1
      fi
      # The value is pasted into "${ARCHIVE_DEST_PATH%/}/<folder>/...", so an
      # absolute path and any ".." component are refused.
      if [[ -z "$value" || "$value" == /* || "$value" == ".." || "$value" == "../"* \
            || "$value" == *"/../"* || "$value" == *"/.." ]]; then
        _cfg_reject "$line" "USER_MAP.$map_key must be a folder name inside the external library (found '${value}')."
        return 1
      fi
      USER_MAP["$map_key"]="$value"
      ;;

    *)
      _cfg_reject "$line" "unknown setting '${key}'."
      return 1
      ;;
  esac

  return 0
}

# Reads config.conf into the settings above. Returns 1 if anything in it is
# unusable, having reported every fault rather than only the first.
config_load() {
  local file="$1"
  local raw line key value map_key
  local n=0 rc=0

  CFG_LOAD_PROBLEMS=()
  CFG_LEGACY_USER_MAP=false
  _CFG_SEEN=()

  # `|| [[ -n "$raw" ]]` so a final line without a trailing newline is still read.
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    n=$(( n + 1 ))
    # A UTF-8 byte-order mark belongs to the file, not to the first setting, and
    # comes off as punctuation. First line only.
    (( n == 1 )) && raw="${raw#$'\xEF\xBB\xBF'}"
    line=$(_cfg_trim "$raw")
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    # The array declaration a legacy config carries. It holds no value of its
    # own, so it is noted and skipped.
    if [[ "$line" == 'declare -A USER_MAP' || "$line" == 'declare -A USER_MAP=()' ]]; then
      CFG_LEGACY_USER_MAP=true
      continue
    fi

    if [[ "$line" != *=* ]]; then
      _cfg_reject "$n" "line is neither a comment nor a 'setting = value' pair."
      rc=1
      continue
    fi

    key=$(_cfg_trim "${line%%=*}")
    value=$(_cfg_trim "${line#*=}")

    # One layer of surrounding quotes comes off as punctuation. What is inside is
    # taken literally, whatever it looks like.
    if (( ${#value} >= 2 )); then
      case "$value" in
        \"*\") value="${value:1:-1}" ;;
        \'*\') value="${value:1:-1}" ;;
      esac
    fi

    # The legacy form, USER_MAP["admin"]="Photos", read as data like everything
    # else and normalised to the USER_MAP.admin=Photos key below.
    if [[ "$key" == 'USER_MAP['*']' ]]; then
      CFG_LEGACY_USER_MAP=true
      map_key="${key#USER_MAP[}"
      map_key="${map_key%]}"
      case "$map_key" in
        \"*\") map_key="${map_key:1:-1}" ;;
        \'*\') map_key="${map_key:1:-1}" ;;
      esac
      key="USER_MAP.$map_key"
    fi

    if ! config_set "$key" "$value" "$n"; then
      rc=1
      # The likeliest reason a value the tool cannot use carries a "#" after a
      # blank: an end-of-line comment, which this file keeps as part of the
      # value. Said here rather than left for the reader to infer from a
      # rejection that quotes the comment back at them.
      [[ "$value" == *[[:space:]]#* ]] && _cfg_reject "$n" \
        "a '#' after a value is part of that value — put comments on their own line."
    fi
  done < "$file"

  # An essential setting the file never assigns is not covered by any check
  # above, so its absence is refused here.
  local k
  for k in "${_CFG_ESSENTIAL_KEYS[@]}"; do
    [[ -n "${_CFG_SEEN[$k]:-}" ]] && continue
    _cfg_reject "" "$k is missing — the tool cannot tell which Immich install to act on."
    rc=1
  done

  return "$rc"
}
