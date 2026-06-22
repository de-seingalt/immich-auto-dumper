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

# ui_note <text>  — light inline note (text backend prints dim; whiptail no-op,
# since the same info is embedded into the relevant dialog's body text).
ui_note() {
  [[ "$UI_BACKEND" == "text" ]] && printf '%b\n' "${C_DIM}$1${C_RESET}"
  return 0
}

# ui_input <title> <body> <default>  — free-text entry with a pre-filled default.
# Sets UI_VALUE; returns 1 if the user cancelled.
ui_input() {
  local title="$1" body="$2" default="${3:-}"
  if [[ "$UI_BACKEND" == "whiptail" ]]; then
    local out rc=0
    out=$(whiptail --title "$title" --inputbox "$body" 16 "$_UI_W" "$default" 3>&1 1>&2 2>&3) || rc=$?
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

# ui_yesno <title> <body> [default]  — default is "yes" unless "no" is passed.
# Returns 0 for yes, 1 for no/cancel.
ui_yesno() {
  local title="$1" body="$2" default="${3:-yes}"
  if [[ "$UI_BACKEND" == "whiptail" ]]; then
    local defflag=()
    [[ "$default" == "no" ]] && defflag=(--defaultno)
    whiptail --title "$title" "${defflag[@]}" --yesno "$body" --scrolltext 20 "$_UI_W"
    return $?
  else
    printf '%b\n' "${C_CYAN}${body}${C_RESET}"
    local hint="[Y/n]"; [[ "$default" == "no" ]] && hint="[y/N]"
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
    local n=$(( $# / 2 )) out rc=0
    out=$(whiptail --title "$title" --menu "$body" 18 "$_UI_W" "$n" "$@" 3>&1 1>&2 2>&3) || rc=$?
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
  local lib_c used_c min_c max_c
  _gcol "$lib_bytes";  lib_c=$_c
  _gcol "$disk_used";  used_c=$_c; (( used_c < lib_c )) && used_c=$lib_c
  _gcol "$min_bytes";  min_c=$_c
  _gcol "$max_bytes";  max_c=$_c

  local g_full g_other g_empty g_mk g_lb g_rb
  if (( GAUGE_UTF )); then
    g_full='█'; g_other='▒'; g_empty='░'; g_mk='▼'; g_lb='├'; g_rb='┤'
  else
    g_full='#'; g_other='+'; g_empty='-'; g_mk='v'; g_lb='['; g_rb=']'
  fi

  local bar="" i
  for (( i = 0; i < W; i++ )); do
    if   (( i < lib_c  )); then bar+="$g_full"
    elif (( i < used_c )); then bar+="$g_other"
    else                        bar+="$g_empty"; fi
  done

  # Marker row above the bar (one leading space aligns with the left border g_lb).
  # Single arrows only — MIN is always left of MAX, so they never need text labels
  # that could collide when the two boundaries are close on the disk scale.
  local mrow; printf -v mrow '%*s' "$W" ''
  (( min_mb > 0 )) && _gauge_place mrow "$min_c" "$g_mk"
  (( max_mb > 0 )) && _gauge_place mrow "$max_c" "$g_mk"

  # Legend.
  local lib_pct=0 used_pct=0
  if (( disk_total > 0 )); then
    lib_pct=$(( lib_bytes * 100 / disk_total ))
    used_pct=$(( disk_used * 100 / disk_total ))
  fi

  printf 'Immich library now: %s (%d%%)   ·   disk used: %s (%d%%)   ·   disk total: %s\n' \
    "$(bytes_to_human "$lib_bytes")" "$lib_pct" \
    "$(bytes_to_human "$disk_used")" "$used_pct" \
    "$(bytes_to_human "$disk_total")"
  printf ' %s\n'   "$mrow"
  printf '%s%s%s\n' "$g_lb" "$bar" "$g_rb"
  if (( min_mb > 0 )); then
    printf '%s MIN = %-9s archive DOWN to this size\n'        "$g_mk" "$(mb_to_human "$min_mb")"
  fi
  if (( max_mb > 0 )); then
    printf '%s MAX = %-9s START archiving when library exceeds this\n' "$g_mk" "$(mb_to_human "$max_mb")"
  fi
  printf '%s library (kept on fast disk)   %s other data   %s free\n' \
    "$g_full" "$g_other" "$g_empty"
}
