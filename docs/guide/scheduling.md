# Turning it on and off

Back to the [user guide](../GUIDE.md) · previous: [archiving](archiving.md) · next:
[monitoring](monitoring.md).

**Do a [`test_run`](archiving.md#trying-it-first) first** and read it. This page assumes you
have.

## Turning it on

```bash
immich-auto-dumper start
```

That installs two lines in **your own crontab**:

| When | What |
|---|---|
| Daily, 02:00 | `dump_now` — archive if MAX or FREE says so |
| Sunday, 03:00 | `sync_now` — mirror the database dumps |

Both append to `~/.local/state/immich-auto-dumper/cron.log`.

No systemd unit, no system-wide cron file, nothing running as root. Everything is in your
user's crontab, which is also why `uninstall` can remove every trace.

The setup wizard offers this on its last screen, so you may have done it already. Running
`start` again is harmless.

## Turning it off

```bash
immich-auto-dumper stop
```

This **comments the lines out** rather than deleting them, so `start` can put them back
exactly as they were. It then waits up to 60 seconds for any operation already running to
finish, and tells you if it is still going.

Stopping the schedule does not undo anything. Archived photos stay where they are, served
by Immich from the external library.

## Checking what is scheduled

```bash
immich-auto-dumper status
```

```
Cron jobs            : active
```

Three possible answers, and the difference matters:

| | Meaning | To change it |
|---|---|---|
| `active` | running automatically | `stop` |
| `disabled` | the lines are there, commented out — what `stop` leaves | `start` |
| `not installed` | nothing scheduled at all | `start` |

`immich-auto-dumper setup` also shows the current state on its scheduling screen, with the
actual crontab lines, and offers only the actions that make sense for that state — so you
are never asked to install jobs that are already running.

## Changing the times

Edit your crontab directly:

```bash
crontab -e
```

`start` will not overwrite a line that is already there, so your edited schedule survives
`start`, `stop` and updates of the tool. Only the lines that are missing get appended.

Two things to know:

- **Give archiving time.** Verifying every copy by checksum is not instant, especially onto
  a NAS or a cloud mount. An overlapping run is harmless — the second exits quietly on the
  lock — but spacing them out is kinder.
- **Keep them after Immich's own database backup.** Archiving needs a dump less than 7 days
  old, so scheduling a dump right before archiving is one less thing to worry about.

The tool only ever touches lines that look like a schedule — one starting with a digit, `*`
or `@`. A `MAILTO=` line, a `PATH=` line or a comment of your own that happens to mention
`immich-auto-dumper` is left strictly alone by `start`, `stop` and `status`.

## When the tool disables the schedule itself

If a run finds that **Immich's paths no longer match your configuration**, it stops and
comments the cron lines out on its own. `status` then reports:

```
Path consistency     : INCONSISTENT — fix the path in Immich, then run setup
Cron jobs            : disabled (entries commented out — run "immich-auto-dumper start" to re-enable)
```

**This is deliberate, not a malfunction.** A stale configuration acting night after night on
Immich's database is the thing worth preventing. It happens when the external library's path
is changed in Immich, or when archived assets are reported missing while the storage is
reachable.

To get out of it:

1. Fix the path in Immich (**Administration → Libraries**) so it matches again — or, if you
   moved the storage on purpose, leave Immich as it is.
2. Run `immich-auto-dumper setup`. The review screen shows what is now inconsistent and
   updates the configuration.
3. Re-enable the schedule from setup's last screen, or with `start`.

If the message says archived assets are **in Immich's trash**: do not empty it until the
path is fixed. See [troubleshooting](troubleshooting.md).

Note the asymmetry: a check that **failed** disables the schedule; a check that could not be
made at all refuses the run but leaves your schedule alone. A database that did not answer
is no reason to turn off automation.

---

Next: [what `status` tells you](monitoring.md).
