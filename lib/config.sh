#!/usr/bin/env bash
set -euo pipefail

# ── config.conf, read as data ─────────────────────────────────────────────────
#
# The file used to be `source`d. That made every value in it executable code:
# ARCHIVE_DEST_PATH="/mnt/external/$(whoami)" ran that command, and so would
# anything else written there. It ran for EVERY command — including `status`,
# which announces itself as read-only, and including the uninstaller, before its
# confirmation prompt — and most often from cron, unattended.
#
# So the file is now parsed. A line is a setting and a value; the setting must be
# one this tool knows; the value must match what that setting is allowed to hold;
# and nothing in it is ever evaluated. Quotes are stripped as punctuation, not
# interpreted — that non-interpretation is the entire point.
#
# The same pass closes a second hole the tests found: two essential settings left
# empty let a run go all the way to "complete" while doing nothing. A setting that
# cannot be used is now a refusal at load, named by line number.

# Settings only the wizard can answer: they identify this specific Immich install.
# A config missing one of these is broken, not merely old. Lives here because the
# loader is what enforces their presence.
_CFG_ESSENTIAL_KEYS=(
  IMMICH_UPLOAD_LOCATION IMMICH_DB_LIBRARY_PREFIX IMMICH_DB_CONTAINER
  IMMICH_SERVER_CONTAINER IMMICH_DB_NAME IMMICH_DB_USER
  ARCHIVE_DEST_PATH ARCHIVE_CONTAINER_PATH ARCHIVE_STORAGE_ID
)

# Findings from the last config_load, replayed by _config_check so the setup review
# shows them next to everything else rather than only in the log.
CFG_LOAD_PROBLEMS=()
# True when the file still carries the `declare -A USER_MAP` form, which setup
# rewrites on its next run.
CFG_LEGACY_USER_MAP=false
# Keys the file actually assigned, so "missing" and "set to something unusable"
# stay distinguishable — and so a leftover environment variable cannot stand in
# for a setting the file never gave.
declare -A _CFG_SEEN=()

_cfg_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Literal rewrite of the two prefixes a hand-written path is likely to start with.
# Exactly these two, substituted as text: no expansion of anything else, and no
# evaluation. Configs copied from the shipped example carried "$HOME" here.
_cfg_expand_home() {
  local v="$1"
  case "$v" in
    '~'|'$HOME')         printf '%s' "$HOME" ;;
    '~/'*)               printf '%s%s' "$HOME" "${v#\~}" ;;
    '$HOME/'*)           printf '%s%s' "$HOME" "${v#\$HOME}" ;;
    *)                   printf '%s' "$v" ;;
  esac
}

_cfg_reject() {
  local where="$1" message="$2"
  CFG_LOAD_PROBLEMS+=("config.conf${where:+:$where} — $message")
  log_error "config.conf${where:+:$where} — $message"
}

# Validates one setting and assigns it. Returns 1 on anything unexpected, naming
# the offending line; the caller keeps reading so one bad line does not hide the
# next four.
config_set() {
  local key="$1" value="$2" line="$3"

  # An empty name is not merely an unknown setting. `_CFG_SEEN[""]` is not a
  # valid subscript for an associative array, and under this file's `set -e` that
  # assignment killed config_load where it stood — taking the whole tool with it,
  # since the configuration is loaded at source time. A single line starting with
  # "=" made every command die on a raw bash error, `setup` and `uninstall`
  # included: the two a broken configuration is supposed to leave reachable.
  if [[ -z "$key" ]]; then
    _cfg_reject "$line" "a setting name is missing before the '='."
    return 1
  fi

  # "Last one wins" is a reasonable convention and refusing would break
  # configurations that work today, so this is a warning and not a rejection. But
  # it must be said: _config_backfill appends to the end of the file, which makes
  # this precisely a place where a second assignment turns up, and
  # BACKUP_RETENTION=3 followed by BACKUP_RETENTION=99 used to give 99 in silence.
  if [[ -n "${_CFG_SEEN[$key]:-}" ]]; then
    log_warn "config.conf:$line — $key is set more than once; this later value ('${value}') wins over the earlier one."
  fi

  # Recorded before validation, so a setting the file DID name but named badly is
  # reported as invalid and not, on top of that, as missing. An unrecognised key
  # is never an essential one, so it cannot mask a genuine absence.
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
        # Where the log file goes is not worth refusing to run over, and the
        # example shipped with older versions put a shell expansion here. Warn and
        # fall back rather than leave the user with a tool that will not start.
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
      # Empty is meaningful here and only here: it means "accept whatever marker
      # the storage carries", i.e. do not pin the destination to one volume.
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
      # The one number allowed to be zero: zero disables the free-disk trigger.
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
      # The value is pasted into "${ARCHIVE_DEST_PATH%/}/<folder>/...". An absolute
      # value or a ".." component would send archived photos outside the external
      # library entirely, which no legitimate folder name ever needs to do.
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
    # A UTF-8 byte-order mark belongs to the file, not to the first setting. It
    # is invisible, so the refusal it caused sent people looking in the wrong
    # place entirely: "unknown setting 'IMMICH_UPLOAD_LOCATION'" followed by
    # "IMMICH_UPLOAD_LOCATION is missing". Removed as punctuation, never
    # interpreted — the same treatment already given to surrounding quotes. Only
    # on the first line: anywhere else those bytes are part of a real name, and
    # an unknown setting is exactly what they are.
    (( n == 1 )) && raw="${raw#$'\xEF\xBB\xBF'}"
    line=$(_cfg_trim "$raw")
    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    # The array declaration the previous format required. It carries no value of
    # its own — the entries under it are read one by one — so it is simply noted.
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

    # One layer of surrounding quotes is punctuation and comes off. What is inside
    # is taken literally, whatever it looks like.
    if (( ${#value} >= 2 )); then
      case "$value" in
        \"*\") value="${value:1:-1}" ;;
        \'*\') value="${value:1:-1}" ;;
      esac
    fi

    # Previous format: USER_MAP["admin"]="Photos". Read as data like everything
    # else, so an existing install keeps working; setup rewrites it to
    # USER_MAP.admin=Photos the next time it runs.
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

    config_set "$key" "$value" "$n" || rc=1
  done < "$file"

  # A setting the file never assigns is not covered by any check above. Two of
  # these left empty were enough for a run to report success while archiving
  # nothing, so their absence is a refusal, not a warning.
  local k
  for k in "${_CFG_ESSENTIAL_KEYS[@]}"; do
    [[ -n "${_CFG_SEEN[$k]:-}" ]] && continue
    _cfg_reject "" "$k is missing — the tool cannot tell which Immich install to act on."
    rc=1
  done

  return "$rc"
}
