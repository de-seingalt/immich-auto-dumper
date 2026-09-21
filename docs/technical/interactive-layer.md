# The interactive layer

`lib/ui.sh`: the prompts the setup wizard is built on, and the disk gauge. Back to the
[technical index](../TECHNICAL.md) · user-facing version:
[configuring the tool](../guide/configuration.md).

## Two backends, no hard dependency

`ui_detect()` picks `whiptail` when it is installed **and** `[[ -t 1 ]]` — it needs an
interactive terminal on stdout to draw into. Otherwise every prompt falls back to coloured
plain text, which works on a bare TTY, over SSH and in a minimal image with nothing extra
installed.

The primitives are `ui_info()`, `ui_input()`, `ui_yesno()`, `ui_menu()`, plus
`ui_logo()`, `ui_banner()`, `ui_section()`, `ui_em()` and `ui_note()` for presentation.
`NEWT_COLORS` is exported once so the dialogs are not the default red.

**Every prompt leaves its result in the global `UI_VALUE`** and returns 0 for confirmed, 1
for cancelled. That is deliberate: a command substitution would put the value in a subshell,
and the caller could not then tell a cancellation from an empty answer. The wizard treats
every cancellation as "nothing was written and no jobs were scheduled", and says so.

`ui_em()` marks a value the user should double-check. The text backend can make it bold;
whiptail cannot style body text, so it is wrapped in guillemets to still stand out.
`ui_note()` is a no-op under whiptail, where the same information is embedded in the
dialog's body instead.

## Dialog geometry

A whiptail box is given an explicit height. Too small and it **silently cuts the end of the
body off**; too large and it is taller than the screen.

`_wt_geometry()` sets `_UI_HEIGHT` — the height that fits the body plus `extra` rows for
borders, buttons and any input field — and `_UI_CLIPPED`, which is 1 when the terminal
height capped it and the caller should pass `--scrolltext`. `_wt_height()` is the echoing
wrapper for callers that only need the height.

### It counts the rows whiptail draws

This is the part that was wrong, and the shape of the defect is worth keeping:

> The height counted **logical** lines while whiptail renders **wrapped** ones. A body of 8
> logical lines that wrapped to 11 was given a box sized for 8, and whiptail cut the end
> off. And because the computed height stayed *under* the terminal cap, `_UI_CLIPPED` stayed
> 0 and `--scrolltext` was not added either. **Both safety nets failed together, and
> silently.**

On the real config-review screen that turned "For information:" into a heading followed by
nothing — and the same mechanism can swallow the `CFG_PROBLEMS` list, which is the blocking
problems the screen exists to show.

`_wt_rows()` therefore wraps on words as whiptail does: a word that does not fit starts a
new row, a word longer than the box is broken across rows, and an empty line still occupies
one row. Three implementation notes:

- It is pure parameter expansion and builtins — **no subprocess per dialog**, which was the
  point of the version it replaced. The answer goes into the global `_UI_ROWS` rather than
  stdout, because a command substitution would fork a subshell per *line*.
- `read -ra` rather than an unquoted expansion, so a body containing `*` is split into words
  without being expanded against the filesystem.
- `${#word}` counts **characters and not bytes** under a UTF-8 locale, so the accents and
  the `▼`/`▲` markers of the summary are measured correctly.

A literal `\n` in a body is normalised to a real newline before counting, because whiptail
renders both as a break.

### The terminal height is asked of the terminal

`_ui_term_lines()` tries `$LINES`, then `tput lines`, then `stty size`, then 24.

`$LINES` is set by **interactive** shells only, so inside a script it is almost always
empty — and `${LINES:-24}` silently pinned every box to 24 rows. On a shorter terminal the
dialog was then taller than the screen.

### A note on testing this

The whiptail backend never runs in a redirected test. `ui_detect()` requires `[[ -t 1 ]]`,
so `printf … | script setup` goes through the text backend and exercises neither
`_wt_geometry()` nor any dialog. Two defects survived that way until someone looked at a
real terminal.

## Sizes

Every archive boundary is stored as an integer number of **mebibytes**, which keeps bash
integer arithmetic usable while still accepting a fractional-GB input (0.5 GB = 512 MiB).
1 GiB = 1024 MiB, 1 MiB = 1024² bytes.

| Function | Does |
|---|---|
| `parse_size_to_mb()` | accepts `200` (bare = GiB), `1.5G`/`1.5GB`, `500M`, `2T`, `80%`, and a comma decimal separator; echoes a whole number of MiB, or nothing on a parse error |
| `mb_to_human()` | a readable label: `1.50 GB`, `512 MB` |
| `mb_to_input()` | a compact value to pre-fill an input box: `200G`, `1.5G`, `512M` |
| `bytes_to_human()` (`lib/utils.sh`) | `512 B`, `1.5 KB`, `12.3 MB`, `1.25 GB` |

`mb_to_input()`'s output is accepted back by `parse_size_to_mb()` verbatim, which is what
makes a pre-filled default safe to simply accept — see
[the whole-GiB rounding](configuration.md#boundaries-defaults-and-the-disk-ceiling).

A `%` is taken on the whole disk for MAX and on MAX for MIN, since MAX is the library's
largest permitted size. A `%` with no detectable disk total echoes nothing, and the caller
reports an invalid value rather than computing from zero.

**`bc` computes and rounds, and its output is printed with `%s`.** Passing a dotted decimal
to `printf %f` fails under a locale whose decimal separator is a comma (`fr_FR`): "invalid
number". Both `parse_size_to_mb()` and the human formatters avoid `%f` for that reason.

## The disk gauge

`render_library_gauge()` echoes the multi-line visualisation the wizard shows while the
boundaries are being chosen: a header line of figures, the bar with its two markers, and a
legend.

```
Immich library now: 142.3 GB (31%)  ·  disk used: 256 GB (56%)  ·  disk total: 460 GB  ·  free space: 204 GB
                                                  ▼
├▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒██████████░░░░░░░░░░░░░░░░░░░┄┄┄┄┄┤
                              ▲
▼ MAX = 200.00 GB   archiving STARTS when the library grows past this
▲ MIN = 150.00 GB   each run brings the library back DOWN to this
█ current library   ▒ other data   ░ headroom up to MAX   ┄ free
```

Four bands on the scale of the whole disk: other data, the current library, the headroom up
to MAX, then free space. The library band is proportional but always at least one block, and
is drawn at the right edge of the used region so it sits directly against the free space.

Both thresholds are *library sizes*, so their columns are measured from the start of the
library band, offset by the other data already on the disk. That way each marker tracks its
real value on the disk scale, independently of how few cells the current size spans.

When the disk size is unknown — an upload path that is not local — the bar falls back to a
padded span around the values, so it still says something rather than rendering empty.

`focus` labels one marker with a "set a … value" hint and gives an undefined boundary a
placeholder position, so the first pass through the wizard shows the user which arrow they
are moving. The label is dropped when it would not fit rather than overlapping the bar's
edges.

Unicode block characters are used when the locale is UTF-8, with a plain-ASCII fallback
(`#`, `+`, `.`, `-`, `v`, `^`) otherwise. `_gauge_place()` overwrites characters of a row
in place, clamped so nothing overflows the bar's width.

## Further

- [Configuration](configuration.md) — the review screen these dialogs render
- [Configuring the tool](../guide/configuration.md) — the wizard from the user's side
