# Scheduling

How `start` and `stop` manage the user's crontab. Back to the
[technical index](../TECHNICAL.md) · user-facing version:
[turning it on and off](../guide/scheduling.md).

## Why the user's crontab

No systemd unit, no system-wide cron file, no privileges. The tool runs as the invoking
user and schedules itself the same way, which means `start` and `stop` work without `sudo`
and an uninstall can remove every trace it left.

The cost is that cron has a **minimal PATH**, so a bare command name would not resolve.
`_resolve_self_bin()` (`immich-auto-dumper.sh`) therefore prefers the stable
`~/.local/bin/immich-auto-dumper` symlink and falls back to the script's own location. The
symlink is owned by `setup`, not by the installer, so it is re-established every time the
user configures — even when the tool was copied into place by hand.

## The template

`cron/crontab.example` carries two placeholder lines:

```
0 2 * * * __BIN__ dump_now >> __LOGDIR__/cron.log 2>&1
0 3 * * 0 __BIN__ sync_now >> __LOGDIR__/cron.log 2>&1
```

`_render_cron_lines()` substitutes `__BIN__` and `__LOGDIR__` and keeps only the schedule
lines, dropping the template's own comments. It returns 1 when the template is missing,
which `_start()` reports rather than installing nothing in silence.

So: archiving daily at 02:00, dump mirroring weekly on Sunday at 03:00. Changing the times
means editing the crontab directly; `start` will not overwrite a line that is already
there.

## Three states, never a boolean

`cron_state()` (`lib/utils.sh`) echoes one of three answers, and **every caller branches on
all three** rather than on true/false:

| State | Meaning |
|---|---|
| `active` | at least one live (uncommented) immich-auto-dumper schedule |
| `disabled` | schedule lines present but commented out — what `stop` leaves behind |
| `absent` | no immich-auto-dumper schedule at all |

The middle state is why the distinction exists. `disabled` and `absent` look the same to a
boolean and need different actions from the user: one is re-enabled by `start`, the other
was never installed. `status` says which, and the wizard's schedule screen offers the
action that fits the state — so nobody is asked to "install the cron jobs" while those jobs
are already running.

`cron_entries()` echoes the lines themselves, live and commented out, for display.

## What counts as a schedule line

**A line whose payload begins with a digit, `*` or `@`.**

All four cron-touching functions agree on that definition: `cron_state()`,
`cron_entries()`, `_start()`'s un-comment step, and `disable_cron()`. A line that merely
*mentions* the tool — a `MAILTO=` or a `PATH=` naming its path, a user's own comment — is
therefore never read as a job, turned into one, or commented out.

That agreement is load-bearing. `disable_cron()` used to match the substring
`immich-auto-dumper` alone, so `stop` commented out such a line too — while `start`'s
un-comment pattern requires the schedule payload, so it could not restore it. The line
stayed disabled for good, and a `PATH=` line disappearing from a crontab is not something
anyone goes looking for.

## `start` un-comments before appending

`_start()` does two things, in this order:

1. Re-enable any entries a previous `stop` commented out, with
   `sed 's|^#\([0-9*@].*immich-auto-dumper.*\)|\1|'` — the exact inverse of what
   `disable_cron()` writes.
2. Append any rendered line not already present.

Without step 1, `start` after `stop` would **do nothing**: a commented line still matches
the substring check in step 2, so every entry would look present and none would be
re-enabled. The message distinguishes the two outcomes — "Cron jobs enabled." when nothing
needed appending, "Cron jobs installed." when something did.

`_stop()` mirrors it: `disable_cron()` reports on live schedules alone, so the two
"nothing to do" cases are told apart rather than claiming the crontab holds no entry when
it simply holds no *enabled* one. It then waits up to 60 s for a running operation to
release the [lock](archiving.md#mutual-exclusion), and warns if it is still running.

## Autonomous disabling

`guard_path_consistency()` may comment the entries out on its own, when Immich's paths no
longer match the configuration. That is a **deliberate stop**, not a failure of cron: a
stale configuration must not keep acting night after night.

Getting out of it is a two-step, and both the log and `status` say so: fix the external
library path in Immich, then run `setup` — which reviews the config and offers to re-enable
the schedule from its own screen.

An *unverified* consistency check (a `2`) refuses the run but leaves the cron alone: a
database that did not answer is not a reason to disable a schedule.

## Uninstalling

`uninstall.sh` deletes the lines entirely rather than commenting them, and guards the
empty-crontab case: removing the last line calls `crontab -r` instead of piping an empty
file, which some cron implementations reject.

## Further

- [The archiving engine](archiving.md) — what `dump_now` runs
- [Database-dump mirroring](database-backups.md) — what `sync_now` runs
- [Failure modes](failure-modes.md)
