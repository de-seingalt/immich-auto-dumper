#!/usr/bin/env bash
set -euo pipefail

# ── Operations journal ────────────────────────────────────────────────────────
#
# Archiving an asset is four steps — copy, update the database, check the result,
# delete the source — and only the whole sequence is safe. When it broke in the
# middle, the tool improvised: it tried to put the database back and, whether that
# worked or not, deleted the copy. A test that made the restore fail left the
# database pointing at a path with no file, and the source photo sitting in the
# library with nothing referencing it.
#
# So each step is written down before it is taken. A run that is interrupted, or
# that gives up on an asset, leaves a record precise enough for the next run to
# pick the asset up where it was left — and precise enough to undo it on request.
#
# The journal is a MEMO, never an authority. Immich keeps living between runs: the
# database is re-read before every irreversible act and has to agree with what the
# journal expects, or nothing is touched. Immich remains the source of truth; this
# file only remembers what this tool was in the middle of doing.
#
# One file per run under $LOG_DIR/runs/, the state carried by the extension so it
# can never be half-written:
#   run-20260920T020000.active   in progress
#   run-20260920T020000.done     finished, everything completed
#   run-20260920T020000.failed   finished with entries left behind
# An .active file found while we hold the lock is, by construction, a run that was
# killed — a dying process cannot rename its own file.
#
# Records are JSON, one per line, so the file stays readable by a person and by
# anything else. A line that does not parse makes its asset untouchable rather
# than guessed at: an unreadable memo authorises nothing.
#
# Honest limit: records are appended without fsync. A killed process, a restarted
# container or a reboot keep them (they are in the page cache); a power cut can
# lose the last lines — but a power cut also loses the operation they describe.

# Where records are appended right now. Reconciliation retargets it at each older
# file it works through, so that a resumed transition lands in the run it belongs to.
RUNLOG_FILE=""
RUNLOG_ID=""
# The file THIS process opened, which reconciliation never changes. Only this one
# may be discarded when it turns out to hold nothing.
RUNLOG_OWN_FILE=""

# Beyond this many tries an entry is parked as `bloque`. Without a ceiling, an
# asset that can never succeed would be retried every night and drown the entries
# that still can.
RUNLOG_MAX_ATTEMPTS=5
# How many completed run files to keep. Their only use is rollback, whose value
# fades; the ones that represent unfinished work are never deleted automatically.
RUNLOG_KEEP_DONE=30

# Field separator used when handing parsed records back to callers. Chosen because
# no path can contain it.
RUNLOG_SEP=$'\x01'

runlog_dir() {
  printf '%s/runs\n' "${LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper}"
}

# ── JSON, written and read by this tool only ──────────────────────────────────

_runlog_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Exact inverse of the above: only \\ and \" are ever produced, so a single
# left-to-right pass is enough and cannot mis-pair them.
_runlog_unescape() {
  local s="$1" out="" i c
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    if [[ "$c" == '\' ]]; then
      i=$(( i + 1 ))
      out+="${s:i:1}"
    else
      out+="$c"
    fi
  done
  printf '%s' "$out"
}

_runlog_field() {
  local line="$1" key="$2"
  local re='"'"$key"'":"((\\.|[^"\\])*)"'
  [[ "$line" =~ $re ]] || return 1
  _runlog_unescape "${BASH_REMATCH[1]}"
}

_runlog_num() {
  local line="$1" key="$2"
  local re='"'"$key"'":([0-9]+)'
  [[ "$line" =~ $re ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

# A newline in a path would split one record across two lines and make the whole
# file ambiguous. No Immich library path contains one; refusing is cheaper than
# inventing an encoding for a case that does not occur.
runlog_path_is_recordable() {
  local p
  for p in "$@"; do
    [[ "$p" == *$'\n'* || "$p" == *$'\r'* ]] && return 1
  done
  return 0
}

# ── Writing ───────────────────────────────────────────────────────────────────

# Opens a run file. Not called for a dry run: a simulation must leave nothing that
# later reads as work done.
runlog_open() {
  local dir
  dir=$(runlog_dir)
  mkdir -p "$dir" 2>/dev/null || {
    log_warn "Cannot create $dir — this run will not be resumable."
    RUNLOG_FILE=""; RUNLOG_ID=""
    return 1
  }
  RUNLOG_ID="${1:-run}-$(date '+%Y%m%dT%H%M%S')"
  RUNLOG_FILE="$dir/$RUNLOG_ID.active"
  : > "$RUNLOG_FILE" 2>/dev/null || {
    log_warn "Cannot write $RUNLOG_FILE — this run will not be resumable."
    RUNLOG_FILE=""; RUNLOG_ID=""
    return 1
  }
  RUNLOG_OWN_FILE="$RUNLOG_FILE"
  return 0
}

# runlog_record <file> <asset> <etat> <attempts> <size> <sha> <src> <src_db> <dst> <dst_db>
# Appends to <file>, or to the current run when <file> is empty. A no-op when no
# journal is open, so the callers need no conditionals.
runlog_record() {
  local file="${1:-$RUNLOG_FILE}"
  [[ -n "$file" ]] || return 0
  local asset="$2" etat="$3" attempts="$4" size="$5" sha="$6"
  local src="$7" src_db="$8" dst="$9" dst_db="${10}"
  printf '{"ts":"%s","asset":"%s","etat":"%s","tentatives":%d,"taille":%d,"sha":"%s","src":"%s","src_db":"%s","dst":"%s","dst_db":"%s"}\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    "$(_runlog_escape "$asset")" "$etat" "$attempts" "$size" "$(_runlog_escape "$sha")" \
    "$(_runlog_escape "$src")" "$(_runlog_escape "$src_db")" \
    "$(_runlog_escape "$dst")" "$(_runlog_escape "$dst_db")" \
    >> "$file" 2>/dev/null || log_warn "Could not append to the run journal $file."
}

# States an entry can still be moved on from. Anything else is terminal.
runlog_is_pending() {
  case "$1" in
    prevu|copie|base_a_jour) return 0 ;;
    *) return 1 ;;
  esac
}

# Renames <file> (default: the current run) to .done or .failed. Atomic, so the
# outcome is never half-recorded. .done only when nothing is left behind.
runlog_close() {
  local file="${1:-$RUNLOG_FILE}"
  [[ -n "$file" && -f "$file" ]] || return 0
  # A run WE opened that recorded nothing has nothing to say, and keeping it would
  # push the runs that do matter out of the retention window. Only ever our own
  # file: a run left behind by an earlier invocation is never deleted here,
  # whatever it holds — that rule is what keeps unfinished work from quietly
  # disappearing. (Reconciliation points RUNLOG_FILE at the files it works
  # through, which is why the test is against RUNLOG_OWN_FILE and not that.)
  if [[ ! -s "$file" && "$file" == "$RUNLOG_OWN_FILE" ]]; then
    rm -f -- "$file" 2>/dev/null || true
    RUNLOG_FILE=""; RUNLOG_OWN_FILE=""
    return 0
  fi
  local base="${file%.*}"
  local etat left=0
  while IFS="$RUNLOG_SEP" read -r _ etat _; do
    [[ -z "$etat" ]] && continue
    case "$etat" in
      source_supprimee|abandonne) ;;
      *) left=$(( left + 1 )) ;;
    esac
  done < <(runlog_read "$file")
  if (( left > 0 )); then
    mv -f -- "$file" "$base.failed" 2>/dev/null || true
  else
    mv -f -- "$file" "$base.done" 2>/dev/null || true
  fi
  [[ "$file" == "$RUNLOG_FILE"     ]] && RUNLOG_FILE=""
  [[ "$file" == "$RUNLOG_OWN_FILE" ]] && RUNLOG_OWN_FILE=""
  return 0
}

# ── Reading ───────────────────────────────────────────────────────────────────

# Echoes the CURRENT state of every asset in <file>, one per line, fields
# separated by RUNLOG_SEP:
#   asset · etat · tentatives · taille · sha · src · src_db · dst · dst_db
# The last record for an asset wins. A record that does not parse is reported as
# etat=illisible with whatever could be read, so callers refuse to act on it
# instead of filling the blanks themselves.
runlog_read() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  local -A seen=()
  local -a order=()
  local line asset etat attempts size sha src src_db dst dst_db

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    asset=$(_runlog_field "$line" asset) || asset=""
    if [[ -z "$asset" ]]; then
      log_warn "Unreadable record in $(basename "$file") — ignored: ${line:0:80}"
      continue
    fi
    etat=$(_runlog_field "$line" etat)          || etat="illisible"
    attempts=$(_runlog_num  "$line" tentatives) || attempts=0
    size=$(_runlog_num      "$line" taille)     || size=0
    sha=$(_runlog_field     "$line" sha)        || etat="illisible"
    src=$(_runlog_field     "$line" src)        || etat="illisible"
    src_db=$(_runlog_field  "$line" src_db)     || etat="illisible"
    dst=$(_runlog_field     "$line" dst)        || etat="illisible"
    dst_db=$(_runlog_field  "$line" dst_db)     || etat="illisible"
    [[ -n "${seen[$asset]:-}" ]] || order+=("$asset")
    seen["$asset"]="${etat}${RUNLOG_SEP}${attempts}${RUNLOG_SEP}${size}${RUNLOG_SEP}${sha}${RUNLOG_SEP}${src}${RUNLOG_SEP}${src_db}${RUNLOG_SEP}${dst}${RUNLOG_SEP}${dst_db}"
  done < "$file"

  for asset in "${order[@]}"; do
    printf '%s%s%s\n' "$asset" "$RUNLOG_SEP" "${seen[$asset]}"
  done
}

# Echoes the run files that still hold unfinished work, oldest first. .active
# means a run that was killed — we hold the lock, so nothing else is running.
runlog_unfinished_files() {
  local dir
  dir=$(runlog_dir)
  [[ -d "$dir" ]] || return 0
  find "$dir" -maxdepth 1 -type f \( -name '*.active' -o -name '*.failed' \) 2>/dev/null \
    | LC_ALL=C sort
}

# Echoes "pending blocked divergent unreadable files oldest_id" across every
# unfinished run file. Used by status, which must answer without anyone opening a
# file: is there unfinished work, since when, and how much of it is stuck.
runlog_summary() {
  local pending=0 blocked=0 divergent=0 unreadable=0 files=0 oldest=""
  local f etat attempts
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    files=$(( files + 1 ))
    [[ -z "$oldest" ]] && oldest=$(basename "$f")
    while IFS="$RUNLOG_SEP" read -r _ etat attempts _; do
      case "$etat" in
        prevu|copie|base_a_jour)
          # An entry that has used up its tries will never be picked up again,
          # whatever its state says. Counting it as "to resume" would promise
          # something that is not going to happen.
          if (( attempts >= RUNLOG_MAX_ATTEMPTS )); then
            blocked=$(( blocked + 1 ))
          else
            pending=$(( pending + 1 ))
          fi
          ;;
        bloque)                  blocked=$((   blocked    + 1 )) ;;
        divergent)               divergent=$(( divergent  + 1 )) ;;
        illisible)               unreadable=$((unreadable + 1 )) ;;
      esac
    done < <(runlog_read "$f" 2>/dev/null)
  done < <(runlog_unfinished_files)
  printf '%d %d %d %d %d %s\n' "$pending" "$blocked" "$divergent" "$unreadable" "$files" "${oldest:--}"
}

# ── Retention ─────────────────────────────────────────────────────────────────

# Keeps the newest RUNLOG_KEEP_DONE completed runs and deletes the rest. Ordered
# by NAME, never mtime: the timestamp in the name makes lexicographic order
# chronological, and unlike mtime it cannot be misreported by the storage — the
# same discipline the DB-dump rotation already follows.
#
# .active and .failed are never touched. They represent work in abeyance, and
# deleting them would delete the problem rather than the file.
runlog_rotate() {
  local dir
  dir=$(runlog_dir)
  [[ -d "$dir" ]] || return 0
  local -a done_files=()
  while IFS= read -r -d '' f; do
    done_files+=("$f")
  done < <(find "$dir" -maxdepth 1 -type f -name '*.done' -print0 2>/dev/null | LC_ALL=C sort -z)
  local count=${#done_files[@]}
  (( count > RUNLOG_KEEP_DONE )) || return 0
  local i
  for (( i = 0; i < count - RUNLOG_KEEP_DONE; i++ )); do
    rm -f -- "${done_files[$i]}" 2>/dev/null || true
  done
}

# Resolves a run id given by the operator to its file, whatever its state.
# Echoes the path, or nothing and 1 when there is no single match.
runlog_resolve() {
  local id="$1" dir
  dir=$(runlog_dir)
  local -a hits=()
  local ext
  for ext in active failed done; do
    [[ -f "$dir/$id.$ext" ]] && hits+=("$dir/$id.$ext")
  done
  # Allow the bare file name too, so pasting what status printed just works.
  [[ -f "$dir/$id" ]] && hits+=("$dir/$id")
  (( ${#hits[@]} == 1 )) || return 1
  printf '%s' "${hits[0]}"
}
