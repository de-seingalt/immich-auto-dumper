#!/usr/bin/env bash
# shellcheck disable=SC2034  # the C_* colours and UI_VALUE are this file's output
# ──────────────────────────────────────────────────────────────────────────────
# UI abstraction layer: the interactive primitives the setup wizard is built on.
#
# Two backends. With `whiptail` available and a terminal on stdout, prompts are
# native dialog boxes; otherwise they are coloured plain-text prompts, which need
# no extra dependency.
#
# Every prompt leaves its result in the global UI_VALUE and returns 0 for
# "confirmed", 1 for "cancelled".
# ──────────────────────────────────────────────────────────────────────────────

# ── Color palette (text fallback) ─────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m';  C_BOLD=$'\033[1m';   C_DIM=$'\033[2m'
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'; C_MAGENTA=$'\033[0;35m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_MAGENTA=''
fi

# Colour theme applied to every whiptail dialog.
export NEWT_COLORS='
root=,blue
border=white,blue
window=,blue
shadow=,black
title=yellow,blue
button=black,white
actbutton=white,blue
compactbutton=white,blue
checkbox=,blue
actcheckbox=blue,white
entry=white,blue
label=white,blue
listbox=white,blue
actlistbox=black,white
textbox=white,blue
acttextbox=black,white
helpline=white,blue
roottext=white,blue
emptyscale=white,gray
fullscale=white,cyan
'

# Selected backend: "whiptail" or "text". Set by ui_detect.
UI_BACKEND="text"

# Picks the backend: whiptail when it is installed and stdout is a terminal for
# it to draw into, text otherwise.
ui_detect() {
  if command -v whiptail &>/dev/null && [[ -t 1 ]]; then
    UI_BACKEND="whiptail"
  else
    UI_BACKEND="text"
  fi
}

# Hold the result of the last successful prompt.
UI_VALUE=""

# Standard dialog geometry.
readonly _UI_W=78

# ── Primitives ────────────────────────────────────────────────────────────────

# ui_logo  — ASCII splash for an interactive entry point. Printed to the raw
# terminal, whichever backend is in use.
ui_logo() {
  printf '%s' "$C_CYAN"
  cat <<'EOF'
                             ___
 +====================+     /::/|
 | immich-auto-dumper |   /::/  / .__
 +====================+ /::/   /__|[_I___,
                       /::/.-./___I__.-~;|
 auto-free library    |__|`(_)--------(_)"
to external storage.::::::..
       .........:::::::::::::..
EOF
  printf '%s' "$C_RESET"
}

# ui_banner <title>  — wizard header (text backend only; whiptail uses titles).
ui_banner() {
  if [[ "$UI_BACKEND" == "text" ]]; then
    printf '%s%s== %s ==%s\n\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET"
  fi
}

# ui_section <name>  — visually separates a group of related questions.
ui_section() {
  if [[ "$UI_BACKEND" == "text" ]]; then
    printf '\n%s── %s ──%s\n' "$C_BOLD$C_BLUE" "$1" "$C_RESET"
  fi
}

# ui_info <title> <text>  — informational message, the box sized to its body.
ui_info() {
  local title="$1" text="$2"
  if [[ "$UI_BACKEND" == "whiptail" ]]; then
    local flags=()
    _wt_geometry "$text" 7
    # A body taller than the terminal is made scrollable rather than clipped.
    (( _UI_CLIPPED )) && flags+=(--scrolltext)
    whiptail --title "$title" "${flags[@]}" --msgbox "$text" "$_UI_HEIGHT" "$_UI_W" || true
  else
    printf '%b\n' "$text"
  fi
}

# ui_em <text>  — emphasises a value in a dialog body: bold in the text backend,
# wrapped in guillemets under whiptail, which cannot style body text.
ui_em() {
  if [[ "$UI_BACKEND" == "text" ]]; then
    printf '%s%s%s' "$C_BOLD" "$1" "$C_RESET"
  else
    printf '«%s»' "$1"
  fi
}

# ui_note <text>  — inline note, printed dim by the text backend and a no-op
# under whiptail.
ui_note() {
  [[ "$UI_BACKEND" == "text" ]] && printf '%b\n' "${C_DIM}$1${C_RESET}"
  return 0
}

# Box geometry for a whiptail dialog. _wt_geometry sets _UI_HEIGHT, the height
# that fits <body> plus <extra> rows of borders, buttons and input field, and
# _UI_CLIPPED, 1 when the terminal height capped it and the caller must make the
# box scrollable.
#
# Every caller calls it directly, and none wraps it in a command substitution:
# `h=$(_wt_height …)` used to run it in a subshell, where it set _UI_CLIPPED on a
# copy of the variable that died with the subshell. The flag was always 0 on the
# way back, so three of the four dialogs clipped their body in silence. There is
# no echoing wrapper left to reintroduce that.
_UI_HEIGHT=8
_UI_CLIPPED=0

# Terminal height in rows, asked of the terminal itself: $LINES is set by
# interactive shells only, and is empty inside a script. 24 when it cannot say.
_ui_term_lines() {
  local n="${LINES:-}"
  [[ "$n" =~ ^[0-9]+$ ]] || n=$( { tput lines; } 2>/dev/null || true )
  [[ "$n" =~ ^[0-9]+$ ]] || n=$( { stty size; } 2>/dev/null | cut -d' ' -f1 || true )
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 10 )) || n=24
  printf '%s' "$n"
}
# Sets _UI_ROWS to the number of rows one logical line occupies once whiptail has
# wrapped it to <width>. Wrapped on words, as whiptail does: a word that does not
# fit starts a new row, one longer than the box is broken across rows, and an
# empty line still occupies one row.
#
# `read -ra` splits into words without expanding a `*` against the filesystem.
# The answer goes into a global and not to stdout, which saves a subshell per
# line.
_UI_ROWS=1
_wt_rows() {
  local text="$1" width="$2"
  (( width < 1 )) && width=1
  # `read -ra` drops the leading blanks and collapses every run of them, so a
  # line that aligns a column with spaces — which nearly every body here does —
  # comes out of the packing loop far shorter than whiptail draws it. The
  # literal line already needs this many rows, blanks included, and the packed
  # count is only allowed to raise that number, never to lower it.
  local raw=$(( (${#text} + width - 1) / width ))
  local -a words=()
  read -ra words <<< "$text"
  if (( ${#words[@]} == 0 )); then
    _UI_ROWS=$(( raw > 1 ? raw : 1 ))
    return 0
  fi
  local rows=0 col=0 word len
  for word in "${words[@]}"; do
    len=${#word}
    if (( col > 0 && col + 1 + len <= width )); then
      col=$(( col + 1 + len ))
      continue
    fi
    # Starts a fresh row, and spans several when it is longer than the box.
    rows=$(( rows + (len + width - 1) / width ))
    col=$(( len % width ))
    (( col == 0 )) && col=$width
  done
  (( rows < raw )) && rows=$raw
  (( rows < 1 )) && rows=1
  _UI_ROWS=$rows
}

_wt_geometry() {
  local body="$1" extra="${2:-7}"
  local lines h maxh
  _UI_CLIPPED=0

  # The rows counted are the WRAPPED ones whiptail draws, not the logical lines
  # it is given. Pure parameter expansion and builtins, with no subprocess per
  # dialog; ${#word} counts characters and not bytes under a UTF-8 locale, so
  # accents and the ▼/▲ markers measure correctly.
  #
  # whiptail renders a literal "\n" as a break exactly like a real one, so the
  # two are normalised before counting.
  local normalised="${body//\\n/$'\n'}"
  local usable=$(( _UI_W - 4 ))
  (( usable < 1 )) && usable=1

  local -a logical=()
  mapfile -t logical <<< "$normalised"

  lines=0
  local line
  for line in "${logical[@]}"; do
    _wt_rows "$line" "$usable"
    lines=$(( lines + _UI_ROWS ))
  done
  (( lines < 1 )) && lines=1

  h=$(( lines + extra ))
  maxh=$(( $(_ui_term_lines) - 1 ))
  (( h > maxh )) && { h=$maxh; _UI_CLIPPED=1; }
  (( h < 8 )) && h=8
  _UI_HEIGHT="$h"
}
# ui_input <title> <body> <default>  — free-text entry with a pre-filled default.
# Sets UI_VALUE; returns 1 if the user cancelled.
ui_input() {
  local title="$1" body="$2" default="${3:-}"
  if [[ "$UI_BACKEND" == "whiptail" ]]; then
    local out rc=0 flags=()
    _wt_geometry "$body" 8
    (( _UI_CLIPPED )) && flags+=(--scrolltext)
    out=$(whiptail --title "$title" "${flags[@]}" --inputbox "$body" "$_UI_HEIGHT" "$_UI_W" "$default" 3>&1 1>&2 2>&3) || rc=$?
    (( rc == 0 )) || return 1
    UI_VALUE="$out"
  else
    printf '%b\n' "${C_CYAN}${body}${C_RESET}"
    local ans
    if [[ -n "$default" ]]; then
      read -r -p "  ${C_BOLD}>${C_RESET} ${C_GREEN}[${default}]${C_RESET}: " ans || return 1
    else
      read -r -p "  ${C_BOLD}>${C_RESET} : " ans || return 1
    fi
    UI_VALUE="${ans:-$default}"
  fi
  return 0
}

# ui_yesno <title> <body> [default] [yes_label] [no_label]
# default is "yes" unless "no" is passed. Optional button labels rename Yes/No.
# Returns 0 for yes, 1 for no/cancel.
ui_yesno() {
  local title="$1" body="$2" default="${3:-yes}" yes_label="${4:-}" no_label="${5:-}"
  if [[ "$UI_BACKEND" == "whiptail" ]]; then
    local flags=()
    _wt_geometry "$body" 6
    (( _UI_CLIPPED )) && flags+=(--scrolltext)
    [[ "$default" == "no" ]] && flags+=(--defaultno)
    [[ -n "$yes_label" ]] && flags+=(--yes-button "$yes_label")
    [[ -n "$no_label"  ]] && flags+=(--no-button "$no_label")
    whiptail --title "$title" "${flags[@]}" --yesno "$body" "$_UI_HEIGHT" "$_UI_W"
    return $?
  else
    printf '%b\n' "${C_CYAN}${body}${C_RESET}"
    local hint
    if [[ -n "$yes_label$no_label" ]]; then
      hint="[y=${yes_label:-yes} / n=${no_label:-no}]"
    else
      hint="[Y/n]"; [[ "$default" == "no" ]] && hint="[y/N]"
    fi
    local ans
    read -r -p "  ${C_BOLD}>${C_RESET} ${hint}: " ans || return 1
    ans="${ans:-$default}"
    [[ "$ans" =~ ^([Yy]|yes)$ ]]
  fi
}

# ui_menu <title> <body> <tag1> <label1> [<tag2> <label2> ...]
# Sets UI_VALUE to the chosen tag; returns 1 if cancelled.
ui_menu() {
  local title="$1" body="$2"; shift 2
  if [[ "$UI_BACKEND" == "whiptail" ]]; then
    local n=$(( $# / 2 )) out rc=0 flags=()
    _wt_geometry "$body" $(( n + 7 ))
    (( _UI_CLIPPED )) && flags+=(--scrolltext)
    out=$(whiptail --title "$title" "${flags[@]}" --menu "$body" "$_UI_HEIGHT" "$_UI_W" "$n" "$@" 3>&1 1>&2 2>&3) || rc=$?
    (( rc == 0 )) || return 1
    UI_VALUE="$out"
  else
    printf '%b\n' "${C_CYAN}${body}${C_RESET}"
    local -a tags=() labels=()
    while (( $# )); do tags+=("$1"); labels+=("$2"); shift 2; done
    local i
    for i in "${!tags[@]}"; do
      printf '   %s%d)%s %s  %s(%s)%s\n' \
        "$C_BOLD" "$(( i + 1 ))" "$C_RESET" "${labels[$i]}" "$C_DIM" "${tags[$i]}" "$C_RESET"
    done
    local choice
    read -r -p "  ${C_BOLD}>${C_RESET} [1]: " choice || return 1
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#tags[@]} )); then
      UI_VALUE="${tags[$(( choice - 1 ))]}"
    else
      UI_VALUE="${tags[0]}"
    fi
  fi
  return 0
}

# ── Size parsing & formatting ─────────────────────────────────────────────────
#
# Every archive boundary is stored as an integer number of MEBIBYTES, which keeps
# bash integer arithmetic usable while still accepting a fractional-GB input
# (0.5 GB = 512 MiB). 1 GiB = 1024 MiB, 1 MiB = 1024^2 bytes.

# parse_size_to_mb <input> [<total_bytes>]
# Accepts "200" (bare = GiB), "1.5G"/"1.5GB", "500M"/"500MB", "2T" and "80%", a
# comma decimal separator included. Echoes a whole number of MiB, or nothing on a
# parse error and on a "%" with no usable disk total.
parse_size_to_mb() {
  local input="${1// /}" total_bytes="${2:-0}"
  input="${input//,/.}"
  # bc computes and rounds, and its output is printed with %s: printf %f would
  # reject a dotted decimal under a ',' locale.
  local num
  if [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)%$ ]]; then
    num="${BASH_REMATCH[1]}"
    (( total_bytes > 0 )) || return 0
    printf '%s\n' "$(echo "scale=6; v=$total_bytes * $num / 100 / 1048576; scale=0; (v+0.5)/1" | bc)"
  elif [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)([KkMmGgTt])[Bb]?$ ]]; then
    num="${BASH_REMATCH[1]}"
    local mult
    case "${BASH_REMATCH[3]}" in
      [Kk]) mult="1/1024" ;;
      [Mm]) mult="1" ;;
      [Gg]) mult="1024" ;;
      [Tt]) mult="1048576" ;;
    esac
    printf '%s\n' "$(echo "scale=6; v=$num * $mult; scale=0; (v+0.5)/1" | bc)"
  elif [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)$ ]]; then
    # A bare number is read as GiB.
    num="${BASH_REMATCH[1]}"
    printf '%s\n' "$(echo "scale=6; v=$num * 1024; scale=0; (v+0.5)/1" | bc)"
  fi
}

# mb_to_human <mb>  — readable label ("1.50 GB", "512 MB").
mb_to_human() {
  local mb="${1:-0}"
  if (( mb >= 1024 )); then
    printf '%s GB\n' "$(echo "scale=2; $mb / 1024" | bc)"
  else
    printf '%d MB\n' "$mb"
  fi
}

# mb_to_input <mb>  — compact value pre-filling an input box ("200G", "1.5G",
# "512M"), which parse_size_to_mb accepts back verbatim.
mb_to_input() {
  local mb="${1:-0}"
  if (( mb == 0 )); then
    printf ''
  elif (( mb % 1024 == 0 )); then
    printf '%dG\n' "$(( mb / 1024 ))"
  elif (( mb >= 1024 )); then
    # The GB form without its trailing zeros: 1.50 -> 1.5.
    local g; g=$(echo "scale=2; $mb / 1024" | bc)
    g="${g%0}"; g="${g%.}"
    printf '%sG\n' "$g"
  else
    printf '%dM\n' "$mb"
  fi
}

# ── Disk / library gauge ──────────────────────────────────────────────────────
#
# A horizontal bar showing, on the scale of the whole disk, how much of it is
# used, how much the Immich library occupies, and where the MAX (start archiving)
# and MIN (archive down to) boundaries fall.

# Unicode block characters when the locale is UTF-8, plain ASCII otherwise.
if [[ "$(locale charmap 2>/dev/null)" == *UTF-8* \
   || "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" == *[Uu][Tt][Ff]* ]]; then
  GAUGE_UTF=1
else
  GAUGE_UTF=0
fi

# Overwrites, in place, as many characters of the named variable as <text> holds,
# starting at column <col> and clamped so the text never overflows the string.
_gauge_place() {
  local -n _v="$1"; local c="$2" t="$3" len=${#3} w=${#_v}
  (( c + len > w )) && c=$(( w - len ))
  (( c < 0 )) && c=0
  _v="${_v:0:c}${t}${_v:c+len}"
}

# render_library_gauge <disk_total> <disk_used> <lib_bytes> <max_mb> <min_mb> [focus]
# Echoes the multi-line gauge: a header line of figures, the bar with its two
# markers, and a legend. focus ∈ {max,min,""} labels one marker with a "set a …
# value" hint, for a boundary the user has not chosen yet.
render_library_gauge() {
  local disk_total="${1:-0}" disk_used="${2:-0}" lib_bytes="${3:-0}"
  local max_mb="${4:-0}" min_mb="${5:-0}" focus="${6:-}"
  local W=50
  local max_bytes=$(( max_mb * 1048576 )) min_bytes=$(( min_mb * 1048576 ))

  # Scaled to the real disk, or to a padded span around the values when the disk
  # size is unknown.
  local scale="$disk_total"
  if (( scale <= 0 )); then
    scale=$max_bytes
    (( lib_bytes  > scale )) && scale=$lib_bytes
    (( min_bytes  > scale )) && scale=$min_bytes
    (( scale <= 0 )) && scale=$(( 1024 * 1048576 ))
    scale=$(( scale * 5 / 4 ))
  fi

  local _c
  _gcol() { _c=$(( $1 * W / scale )); (( _c < 0 )) && _c=0; (( _c > W )) && _c=W; return 0; }

  # The library is proportional but always at least one block, drawn at the right
  # edge of the used region; other data fills the rest of that region.
  local lib_blocks used_c
  _gcol "$lib_bytes"; lib_blocks=$_c; (( lib_blocks < 1 )) && lib_blocks=1
  _gcol "$disk_used"; used_c=$_c; (( used_c < lib_blocks )) && used_c=$lib_blocks
  (( used_c > W )) && used_c=$W
  local lib_start=$(( used_c - lib_blocks )) lib_end=$used_c

  # Both thresholds are library sizes, so their columns are measured from the
  # start of the library block, offset by the other data already on the disk.
  local other_bytes=$(( disk_used - lib_bytes )); (( other_bytes < 0 )) && other_bytes=0
  local min_c max_c
  _gcol $(( other_bytes + max_bytes )); max_c=$_c
  _gcol $(( other_bytes + min_bytes )); min_c=$_c
  (( max_c < lib_end )) && max_c=$lib_end   # MAX can never sit left of the current size
  (( min_c > max_c   )) && min_c=$max_c

  local g_full g_other g_grow g_free g_dn g_up g_lb g_rb
  if (( GAUGE_UTF )); then
    g_full='█'; g_other='▒'; g_grow='░'; g_free='┄'; g_dn='▼'; g_up='▲'; g_lb='├'; g_rb='┤'
  else
    g_full='#'; g_other='+'; g_grow='.'; g_free='-'; g_dn='v'; g_up='^'; g_lb='['; g_rb=']'
  fi

  # Four bands: other data ▒, current library █, headroom up to MAX ░, then free.
  local grow_end=$max_c
  (( max_mb <= 0 )) && grow_end=$lib_end   # no MAX configured: no headroom band
  (( grow_end < lib_end )) && grow_end=$lib_end
  local bar="" i
  for (( i = 0; i < W; i++ )); do
    if   (( i < lib_start )); then bar+="$g_other"
    elif (( i < lib_end   )); then bar+="$g_full"
    elif (( i < grow_end  )); then bar+="$g_grow"
    else                           bar+="$g_free"; fi
  done

  # Marker columns. A defined value sits one cell back, over the last filled cell
  # of its band. An undefined one (0) gets a placeholder: MAX at the far right
  # minus one block, MIN on the leftmost cell of the library block. MAX (▼) rides
  # above the bar, MIN (▲) below it.
  local max_mk min_mk
  if (( max_mb > 0 )); then max_mk=$(( max_c > 0 ? max_c - 1 : 0 )); else max_mk=$(( W - 2 )); fi
  if (( min_mb > 0 )); then min_mk=$(( min_c > 0 ? min_c - 1 : 0 )); else min_mk=$lib_start; fi
  (( max_mk < 0 )) && max_mk=0
  (( min_mk < 0 )) && min_mk=0

  local toprow botrow
  printf -v toprow '%*s' "$W" ''
  printf -v botrow '%*s' "$W" ''
  _gauge_place toprow "$max_mk" "$g_dn"
  _gauge_place botrow "$min_mk" "$g_up"

  # The marker named by <focus> carries a label, dropped when it does not fit.
  if [[ "$focus" == "max" ]]; then
    local lbl='set a MAX value ->'
    (( max_mk >= ${#lbl} )) && _gauge_place toprow $(( max_mk - ${#lbl} )) "$lbl"
    _gauge_place toprow "$max_mk" "$g_dn"
  elif [[ "$focus" == "min" ]]; then
    local lbl='<- set a MIN value'
    (( min_mk + 1 + ${#lbl} <= W )) && _gauge_place botrow $(( min_mk + 1 )) "$lbl"
    _gauge_place botrow "$min_mk" "$g_up"
  fi

  local lib_pct=0 used_pct=0
  if (( disk_total > 0 )); then
    lib_pct=$(( lib_bytes * 100 / disk_total ))
    used_pct=$(( disk_used * 100 / disk_total ))
  fi

  local disk_free=$(( disk_total - disk_used )); (( disk_free < 0 )) && disk_free=0
  printf 'Immich library now: %s (%d%%)   ·   disk used: %s (%d%%)   ·   disk total: %s   ·   free space: %s\n' \
    "$(bytes_to_human "$lib_bytes")" "$lib_pct" \
    "$(bytes_to_human "$disk_used")" "$used_pct" \
    "$(bytes_to_human "$disk_total")" \
    "$(bytes_to_human "$disk_free")"
  printf ' %s\n'    "$toprow"
  printf '%s%s%s\n' "$g_lb" "$bar" "$g_rb"
  printf ' %s\n'    "$botrow"
  (( max_mb > 0 )) && printf '%s MAX = %-9s archiving STARTS when the library grows past this\n' "$g_dn" "$(mb_to_human "$max_mb")"
  (( min_mb > 0 )) && printf '%s MIN = %-9s each run brings the library back DOWN to this\n'     "$g_up" "$(mb_to_human "$min_mb")"
  printf '%s current library   %s other data   %s headroom up to MAX   %s free\n' "$g_full" "$g_other" "$g_grow" "$g_free"
}
