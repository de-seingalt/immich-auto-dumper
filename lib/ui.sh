#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# UI abstraction layer.
#
# Provides a single set of interactive primitives used by the setup wizard. When
# `whiptail` is available and we are attached to a terminal, prompts are rendered
# as native dialog boxes (arrow-key navigation, pre-filled defaults, colors).
# Otherwise we fall back to colored plain-text prompts that work everywhere
# (bare TTY, SSH, minimal images) with no extra dependency.
#
# All prompts return their result in the global UI_VALUE and use exit status 0
# for "confirmed" / 1 for "cancelled", so callers can react to a cancel without
# the value being swallowed by a command-substitution subshell.
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

# Pleasant newt theme so the whiptail dialogs are not the default red.
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

# Detect the best available backend. whiptail needs an interactive terminal on
# stdout to draw into.
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

# ui_info <title> <text>  — purely informational message.
ui_info() {
  local title="$1" text="$2"
  if [[ "$UI_BACKEND" == "whiptail" ]]; then
    whiptail --title "$title" --msgbox "$text" 16 "$_UI_W" || true
  else
    printf '%b\n' "$text"
  fi
}

# ui_em <text>  — emphasize a value the user must double-check (manually entered
# ones, which can break the script). Real bold in the text backend; whiptail
# cannot style body text, so it is wrapped in guillemets to still stand out.
ui_em() {
  if [[ "$UI_BACKEND" == "text" ]]; then
    printf '%s%s%s' "$C_BOLD" "$1" "$C_RESET"
  else
    printf '«%s»' "$1"
  fi
}

# ui_note <text>  — light inline note (text backend prints dim; whiptail no-op,
# since the same info is embedded into the relevant dialog's body text).
ui_note() {
  [[ "$UI_BACKEND" == "text" ]] && printf '%b\n' "${C_DIM}$1${C_RESET}"
  return 0
}

# Estimate a whiptail box height that fits <body> without a scrollbar. Counts both
# real newlines and literal "\n" sequences (whiptail renders both as breaks), adds
# <extra> rows for borders/buttons/input field, and caps to the terminal height.
_wt_height() {
  local body="$1" extra="${2:-7}"
  local real lit lines h maxh
  real=$(awk 'END{print NR}' <<< "$body")
  lit=$(grep -o '\\n' <<< "$body" | wc -l)
  lines=$(( real + lit ))
  h=$(( lines + extra ))
  maxh=$(( ${LINES:-24} - 1 ))
  (( maxh < 10 )) && maxh=23
  (( h > maxh )) && h=$maxh
  (( h < 8 )) && h=8
  printf '%s' "$h"
}

# ui_input <title> <body> <default>  — free-text entry with a pre-filled default.
# Sets UI_VALUE; returns 1 if the user cancelled.
ui_input() {
  local title="$1" body="$2" default="${3:-}"
  if [[ "$UI_BACKEND" == "whiptail" ]]; then
    local out rc=0 h; h=$(_wt_height "$body" 8)
    out=$(whiptail --title "$title" --inputbox "$body" "$h" "$_UI_W" "$default" 3>&1 1>&2 2>&3) || rc=$?
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
    local flags=() h; h=$(_wt_height "$body" 6)
    [[ "$default" == "no" ]] && flags+=(--defaultno)
    [[ -n "$yes_label" ]] && flags+=(--yes-button "$yes_label")
    [[ -n "$no_label"  ]] && flags+=(--no-button "$no_label")
    whiptail --title "$title" "${flags[@]}" --yesno "$body" "$h" "$_UI_W"
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
    local n=$(( $# / 2 )) out rc=0 h
    h=$(_wt_height "$body" $(( n + 7 )))
    out=$(whiptail --title "$title" --menu "$body" "$h" "$_UI_W" "$n" "$@" 3>&1 1>&2 2>&3) || rc=$?
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
# All archive boundaries are stored internally as integer MEBIBYTES (MiB) so that
# bash integer arithmetic keeps working while still allowing fractional GB input
# (e.g. 0.5 GB = 512 MiB). 1 GiB = 1024 MiB, 1 MiB = 1024^2 bytes.

# parse_size_to_mb <input> [<total_bytes>]
# Accepts: "200" (bare = GiB), "1.5G"/"1.5GB", "500M"/"500MB", "2T", "80%".
# A comma decimal separator is accepted ("0,5"). Echoes an integer number of MiB,
# or nothing on a parse error (or a "%" with no usable disk total).
parse_size_to_mb() {
  local input="${1// /}" total_bytes="${2:-0}"
  input="${input//,/.}"
  local num
  if [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)%$ ]]; then
    num="${BASH_REMATCH[1]}"
    (( total_bytes > 0 )) || return 0
    printf '%.0f\n' "$(echo "scale=6; $total_bytes * $num / 100 / 1048576" | bc)"
  elif [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)([KkMmGgTt])[Bb]?$ ]]; then
    num="${BASH_REMATCH[1]}"
    local mult
    case "${BASH_REMATCH[3]}" in
      [Kk]) mult="1/1024" ;;
      [Mm]) mult="1" ;;
      [Gg]) mult="1024" ;;
      [Tt]) mult="1048576" ;;
    esac
    printf '%.0f\n' "$(echo "scale=6; $num * $mult" | bc)"
  elif [[ "$input" =~ ^([0-9]+(\.[0-9]+)?)$ ]]; then
    # Bare number = GiB, for backward compatibility with the old prompts.
    num="${BASH_REMATCH[1]}"
    printf '%.0f\n' "$(echo "scale=6; $num * 1024" | bc)"
  fi
}

# mb_to_human <mb>  — readable label ("1.50 GB", "512 MB").
mb_to_human() {
  local mb="${1:-0}"
  if (( mb >= 1024 )); then
    printf '%.2f GB\n' "$(echo "scale=2; $mb / 1024" | bc)"
  else
    printf '%d MB\n' "$mb"
  fi
}

# mb_to_input <mb>  — compact value to pre-fill an input box ("200G", "1.5G",
# "512M"). The parser accepts the result back verbatim.
mb_to_input() {
  local mb="${1:-0}"
  if (( mb == 0 )); then
    printf ''
  elif (( mb % 1024 == 0 )); then
    printf '%dG\n' "$(( mb / 1024 ))"
  elif (( mb >= 1024 )); then
    # Trim trailing zeros from the GB form (1.50 -> 1.5).
    local g; g=$(echo "scale=2; $mb / 1024" | bc)
    g="${g%0}"; g="${g%.}"
    printf '%sG\n' "$g"
  else
    printf '%dM\n' "$mb"
  fi
}

# ── Disk / library gauge ──────────────────────────────────────────────────────
#
# A horizontal bar visualizing, on the scale of the whole disk, how much of it is
# used, how much the Immich library occupies, and where the MAX (start archiving)
# and MIN (archive down to) boundaries fall. Unicode block characters are used
# when the locale supports UTF-8, with a plain-ASCII fallback otherwise.

if [[ "$(locale charmap 2>/dev/null)" == *UTF-8* \
   || "${LC_ALL:-}${LC_CTYPE:-}${LANG:-}" == *[Uu][Tt][Ff]* ]]; then
  GAUGE_UTF=1
else
  GAUGE_UTF=0
fi

# Overwrite, in-place, <len(text)> characters of the named variable starting at
# column <col>, clamping so the text never overflows the string width.
_gauge_place() {
  local -n _v="$1"; local c="$2" t="$3" len=${#3} w=${#_v}
  (( c + len > w )) && c=$(( w - len ))
  (( c < 0 )) && c=0
  _v="${_v:0:c}${t}${_v:c+len}"
}

# render_library_gauge <disk_total> <disk_used> <lib_bytes> <max_mb> <min_mb>
# Echoes a multi-line visualization. max_mb / min_mb may be 0 to omit a marker.
render_library_gauge() {
  local disk_total="${1:-0}" disk_used="${2:-0}" lib_bytes="${3:-0}"
  local max_mb="${4:-0}" min_mb="${5:-0}"
  local W=50
  local max_bytes=$(( max_mb * 1048576 )) min_bytes=$(( min_mb * 1048576 ))

  # Scale to the real disk; fall back to a padded span around the values when the
  # disk size is unknown (e.g. upload path not local), so the bar still makes sense.
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

  # Library is proportional but always >=1 block, drawn at the right edge of the
  # used region (just before free); other-data fills the rest of the used region.
  local lib_blocks used_c
  _gcol "$lib_bytes"; lib_blocks=$_c; (( lib_blocks < 1 )) && lib_blocks=1
  _gcol "$disk_used"; used_c=$_c; (( used_c < lib_blocks )) && used_c=$lib_blocks
  (( used_c > W )) && used_c=$W
  local lib_start=$(( used_c - lib_blocks )) lib_end=$used_c

  # Thresholds are library sizes, so they are measured from the START of the
  # library block (i.e. offset by the other-data already on disk). For a single
  # block we simply bracket it — MAX at its end, MIN at its start; with several
  # blocks the markers fall proportionally around the block.
  local other_bytes=$(( disk_used - lib_bytes )); (( other_bytes < 0 )) && other_bytes=0
  local min_c max_c
  if (( lib_blocks <= 1 )); then
    max_c=$lib_end; min_c=$lib_start
  else
    _gcol $(( other_bytes + max_bytes )); max_c=$_c
    _gcol $(( other_bytes + min_bytes )); min_c=$_c
    (( min_c >= max_c )) && min_c=$(( max_c > 0 ? max_c - 1 : 0 ))
  fi

  local g_full g_other g_empty g_dn g_up g_lb g_rb
  if (( GAUGE_UTF )); then
    g_full='█'; g_other='▒'; g_empty='░'; g_dn='▼'; g_up='▲'; g_lb='├'; g_rb='┤'
  else
    g_full='#'; g_other='+'; g_empty='-'; g_dn='v'; g_up='^'; g_lb='['; g_rb=']'
  fi

  local bar="" i
  for (( i = 0; i < W; i++ )); do
    if   (( i < lib_start )); then bar+="$g_other"
    elif (( i < lib_end   )); then bar+="$g_full"
    else                           bar+="$g_empty"; fi
  done

  # MAX marker above the bar (▼), MIN marker below it (▲): distinct symbols on
  # distinct rows, so they never look alike or overlap. One leading space aligns
  # each row with the left border g_lb.
  local toprow botrow
  printf -v toprow '%*s' "$W" ''
  printf -v botrow '%*s' "$W" ''
  (( max_mb > 0 )) && _gauge_place toprow "$max_c" "$g_dn"
  (( min_mb > 0 )) && _gauge_place botrow "$min_c" "$g_up"

  local lib_pct=0 used_pct=0
  if (( disk_total > 0 )); then
    lib_pct=$(( lib_bytes * 100 / disk_total ))
    used_pct=$(( disk_used * 100 / disk_total ))
  fi

  printf 'Immich library now: %s (%d%%)   ·   disk used: %s (%d%%)   ·   disk total: %s\n' \
    "$(bytes_to_human "$lib_bytes")" "$lib_pct" \
    "$(bytes_to_human "$disk_used")" "$used_pct" \
    "$(bytes_to_human "$disk_total")"
  printf ' %s\n'    "$toprow"
  printf '%s%s%s\n' "$g_lb" "$bar" "$g_rb"
  printf ' %s\n'    "$botrow"
  (( max_mb > 0 )) && printf '%s MAX = %-9s archiving STARTS when the library grows past this\n' "$g_dn" "$(mb_to_human "$max_mb")"
  (( min_mb > 0 )) && printf '%s MIN = %-9s each run brings the library back DOWN to this\n'     "$g_up" "$(mb_to_human "$min_mb")"
  printf '%s library   %s other data   %s free\n' "$g_full" "$g_other" "$g_empty"
}
