#!/usr/bin/env bash
set -euo pipefail

# ── Operations journal ────────────────────────────────────────────────────────
#
# Each step of an asset's move is written down before it is taken, so that a run
# which is interrupted, or which gives up on an asset, leaves a record precise
# enough for the next run to pick that asset up — and to undo it on request.
#
# The journal is a memo, never an authority: the database is re-read before every
# irreversible act and has to agree with what the journal expects.
#
# One file per run under $LOG_DIR/runs/, its state carried by the extension:
#   run-20260920T020000.active   in progress
#   run-20260920T020000.done     finished, everything completed
#   run-20260920T020000.failed   finished with entries left behind
# An .active file found while this process holds the lock belongs to a run that
# was killed: a dying process cannot rename its own file.
#
# Records are JSON, one per line. A line that does not parse makes its asset
# untouchable rather than guessed at. Each record is pushed to the disk as it is
# written (_runlog_flush).

# Where records are appended right now. Reconciliation retargets it at each older
# file it works through, so a resumed transition lands in the run it belongs to.
RUNLOG_FILE=""
RUNLOG_ID=""
# The file THIS process opened, which reconciliation never changes. Only this one
# may be discarded when it turns out to hold nothing.
RUNLOG_OWN_FILE=""

# Beyond this many tries, an entry is parked as `bloque` and never retried.
RUNLOG_MAX_ATTEMPTS=5
# How many completed run files to keep. The ones holding unfinished work are never
# deleted automatically.
RUNLOG_KEEP_DONE=30

# Field separator used when handing parsed records back to callers. No path can
# contain it.
RUNLOG_SEP=$'\x01'

# Which way the operation this run records is going: `archive` or `rollback`.
# Written into every record, and read back with `archive` as the default, so a
# journal written before the field existed stays valid.
RUNLOG_DIRECTION="archive"

# States an entry can carry:
#   prevu             decided, nothing done yet
#   copie             written at the far end, database not yet pointed at it
#   base_a_jour       database points at the far end, other copy still present
#   source_supprimee  finished
#   annule            finished, then undone by a rollback of this very run
#   bloque            gave up after RUNLOG_MAX_ATTEMPTS tries — needs a person
#   divergent         Immich disagrees with the journal — needs a person
#   abandonne         the asset left Immich; nothing left to resume
#   illisible         the record could not be parsed; authorises nothing

# Echoes the directory the run journals live in.
runlog_dir() {
  printf '%s/runs\n' "${LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/immich-auto-dumper}"
}

# ── JSON, written and read by this tool only ──────────────────────────────────

# Escapes a backslash and a double quote for a JSON string. Those two and no
# others are ever produced.
_runlog_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# Exact inverse of the above, in a single left-to-right pass.
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

# Echoes the unescaped string value of <key> in one record; 1 when it is absent.
_runlog_field() {
  local line="$1" key="$2"
  local re='"'"$key"'":"((\\.|[^"\\])*)"'
  [[ "$line" =~ $re ]] || return 1
  _runlog_unescape "${BASH_REMATCH[1]}"
}

# Echoes the numeric value of <key> in one record; 1 when it is absent.
_runlog_num() {
  local line="$1" key="$2"
  local re='"'"$key"'":([0-9]+)'
  [[ "$line" =~ $re ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}

# False as soon as one of the paths given holds a line break, which would split a
# record across two lines. Records carry no encoding for one.
runlog_path_is_recordable() {
  local p
  for p in "$@"; do
    [[ "$p" == *$'\n'* || "$p" == *$'\r'* ]] && return 1
  done
  return 0
}

# ── Writing ───────────────────────────────────────────────────────────────────

# Opens a run file named "<kind>-<timestamp>.active" and sets RUNLOG_FILE,
# RUNLOG_ID and RUNLOG_OWN_FILE. Returns 1 when the directory or the file cannot
# be written, leaving those three empty; what that means is the caller's to
# decide. Never called for a dry run.
runlog_open() {
  local dir
  dir=$(runlog_dir)
  mkdir -p "$dir" 2>/dev/null || {
    log_warn "Cannot create the run journal directory: $dir"
    RUNLOG_FILE=""; RUNLOG_ID=""
    return 1
  }
  RUNLOG_ID="${1:-run}-$(date '+%Y%m%dT%H%M%S')"
  RUNLOG_FILE="$dir/$RUNLOG_ID.active"
  # Braced so that 2>/dev/null is in place before the redirection that may fail:
  # bash sets redirections up left to right.
  { : > "$RUNLOG_FILE"; } 2>/dev/null || {
    log_warn "Cannot write the run journal: $RUNLOG_FILE"
    RUNLOG_FILE=""; RUNLOG_ID=""
    return 1
  }
  RUNLOG_OWN_FILE="$RUNLOG_FILE"
  return 0
}

# Pushes the journal out of the page cache: `sync -d` on that one small local
# file, with no fallback to a global sync.
_runlog_flush() { sync -d -- "$1" 2>/dev/null || true; }

# runlog_record <file> <asset> <etat> <attempts> <size> <sha> <src> <src_db> <dst> <dst_db>
# Appends one record to <file>, or to the current run when <file> is empty, and
# flushes it. Returns non-zero when the record could not be written, which the
# callers standing in front of an irreversible step check before acting. A silent
# no-op when no journal is open at all.
runlog_record() {
  local file="${1:-$RUNLOG_FILE}"
  [[ -n "$file" ]] || return 0
  local asset="$2" etat="$3" attempts="$4" size="$5" sha="$6"
  local src="$7" src_db="$8" dst="$9" dst_db="${10}"
  # Braced for the same reason as in runlog_open.
  if ! { printf '{"ts":"%s","sens":"%s","asset":"%s","etat":"%s","tentatives":%d,"taille":%d,"sha":"%s","src":"%s","src_db":"%s","dst":"%s","dst_db":"%s"}\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$RUNLOG_DIRECTION" \
    "$(_runlog_escape "$asset")" "$etat" "$attempts" "$size" "$(_runlog_escape "$sha")" \
    "$(_runlog_escape "$src")" "$(_runlog_escape "$src_db")" \
    "$(_runlog_escape "$dst")" "$(_runlog_escape "$dst_db")" \
    >> "$file"; } 2>/dev/null
  then
    log_warn "Could not append to the run journal $file."
    return 1
  fi
  _runlog_flush "$file"
  return 0
}

# States an entry can still be moved on from. Anything else is terminal.
runlog_is_pending() {
  case "$1" in
    prevu|copie|base_a_jour) return 0 ;;
    *) return 1 ;;
  esac
}

# Renames <file> (default: the current run) to .done, or to .failed when entries
# are left behind. The rename is atomic, so the outcome is never half-recorded.
runlog_close() {
  local file="${1:-$RUNLOG_FILE}"
  [[ -n "$file" && -f "$file" ]] || return 0
  # An empty journal this process opened is discarded. The test is against
  # RUNLOG_OWN_FILE and not RUNLOG_FILE, which reconciliation retargets: a run
  # file left by an earlier invocation is never deleted here, whatever it holds.
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
      source_supprimee|abandonne|annule) ;;
      *) left=$(( left + 1 )) ;;
    esac
  done < <(runlog_read "$file")
  local target="$base.done"
  (( left > 0 )) && target="$base.failed"
  # A file already carrying its target name is left alone: reconciliation closes
  # the files it worked through, and one still holding pending entries keeps the
  # name it had. `mv` refuses to rename a file onto itself.
  if [[ "$file" == "$target" ]]; then
    [[ "$file" == "$RUNLOG_FILE"     ]] && RUNLOG_FILE=""
    [[ "$file" == "$RUNLOG_OWN_FILE" ]] && RUNLOG_OWN_FILE=""
    return 0
  fi
  # A rename that fails leaves the file .active, which the next run reads as a
  # killed run.
  if ! mv -f -- "$file" "$target" 2>/dev/null; then
    log_warn "Could not rename the run journal $file to $(basename "$target")."
    log_warn "It stays .active, so the next run will treat it as a killed run and pick its entries up again."
    return 0
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
      # To stderr: this function's stdout is the record stream its callers parse.
      log_warn "Unreadable record in $(basename "$file") — ignored: ${line:0:80}" >&2
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

# Echoes the run files that still hold unfinished work — .active and .failed —
# oldest first.
runlog_unfinished_files() {
  local dir
  dir=$(runlog_dir)
  [[ -d "$dir" ]] || return 0
  find "$dir" -maxdepth 1 -type f \( -name '*.active' -o -name '*.failed' \) 2>/dev/null \
    | LC_ALL=C sort
}

# Echoes "pending blocked divergent unreadable files oldest_id" across every
# unfinished run file.
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
          # An entry that has used up its tries counts as blocked, whatever its
          # state says: it will not be picked up again.
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
# by NAME, never by mtime: the timestamp in the name makes lexicographic order
# chronological. .active and .failed are never touched.
runlog_rotate() {
  local dir
  dir=$(runlog_dir)
  [[ -d "$dir" ]] || return 0
  local -a done_files=()
  local f
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

# Echoes the direction a journal records: "archive" for a run that moved files
# out to the external storage, "rollback" for one that brought them back.
#
# Read from the first record that names it rather than from the file name, which
# an operator can rename, and falling back to the name only for a journal that
# holds no readable record at all. An empty answer means neither could be
# established, which a caller standing in front of a destructive step must treat
# as a refusal and not as an "archive".
runlog_sens() {
  local file="$1" line sens=""
  [[ -f "$file" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    sens=$(_runlog_field "$line" sens) || sens=""
    if [[ -n "$sens" ]]; then
      printf '%s' "$sens"
      return 0
    fi
  done < "$file"
  # No record names it — an .active journal opened and never written to. The id
  # is then the only evidence there is.
  local base; base=$(basename "$file")
  case "$base" in
    rollback-*) printf 'rollback' ;;
    run-*)      printf 'archive'  ;;
  esac
  return 0
}

# Resolves a run id given by the operator to its file, whatever its state.
# Echoes the path, or nothing and 1 when there is no single match.
runlog_resolve() {
  local id="$1" dir
  dir=$(runlog_dir)
  local -a hits=()
  local ext
  # 'done' is quoted: unquoted it reads as the loop keyword (shellcheck SC1010).
  for ext in active failed 'done'; do
    [[ -f "$dir/$id.$ext" ]] && hits+=("$dir/$id.$ext")
  done
  # The bare file name is accepted too, as status prints it.
  [[ -f "$dir/$id" ]] && hits+=("$dir/$id")
  (( ${#hits[@]} == 1 )) || return 1
  printf '%s' "${hits[0]}"
}
