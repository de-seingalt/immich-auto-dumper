# What `status` tells you

One command, everything you need to know. Back to the [user guide](../GUIDE.md).

```bash
immich-auto-dumper status
```

It reads and writes nothing — safe to run at any time, including while a run is in
progress.

```
=== immich-auto-dumper status ===
Library size         : 142.3 GB  (archives above 200.00 GB, down to 150.00 GB)
Total free disk space: 204 GB free of 460 GB total
Free-disk safety net : archives if free disk < 20.00 GB (currently 204 GB free)
External storage     : ready  (/mnt/external)
Schema check         : OK
Path consistency     : OK
DB backups           : 5 file(s) in .immich-backup/
Cron jobs            : active
Last archive         : 2026-09-20 02:04:11 — Freed: 12.4 GB.
Last DB backup       : 2026-09-20 03:00:12 — 5 file(s) retained, 412.7 MB total.
Lock                 : inactive
Unfinished runs      : none
```

## The most important thing on this page

> **"not verified" is not "OK".**

When a line says a check could not be made, **nothing was learned**. The tool deliberately
refuses to turn "I could not ask" into "everything is fine", because that is precisely how
a broken installation reports itself healthy for weeks.

Read any "not verified" as a question, not as good news.

## Line by line

### Library size

Its measured size, and your two thresholds. This is what drives archiving.

A `WARNING` may follow, saying the library cannot reach its MAX before the disk fills. That
means MAX is now above what the disk can actually give it — usually because other data grew.
If your free-disk safety net is on, it will catch this; if not, automatic archiving may
never trigger, and the line says so. Re-run `setup` to lower MAX.

### Total free disk space / Free-disk safety net

The whole filesystem, not just the library. The safety-net line only appears when FREE is
enabled, and shows the threshold beside the current value.

### External storage

| It says | Meaning |
|---|---|
| `ready` | the marker is there, it is your storage, and Immich can see it too |
| `NOT READY` | the storage is not connected, or a different one is mounted. Normal for a removable disk; runs skip quietly |
| `UNVERIFIABLE` | something is answering badly — a hanging mount, an unreadable marker, or a mount the container cannot see. **This one needs you** |

The reason is printed after the verdict. See [troubleshooting](troubleshooting.md).

### Schema check

Whether Immich's database still has the columns the tool relies on.

`FAILED` means an Immich upgrade changed the layout: stop the scheduled jobs and do not
archive until it is sorted. `not verified` means Docker or the database did not answer —
which says nothing about the schema either way.

### Path consistency

Whether Immich's own paths still match your configuration.

`INCONSISTENT` means the external library path changed in Immich, or archived assets are
reported missing while the storage is reachable. The tool **disables the scheduled jobs on
its own** when it sees this, so a stale configuration cannot keep acting. Fix the path in
Immich, then run `setup`.

If it mentions assets Immich has moved to the trash: **do not empty the trash** until the
path is fixed.

### DB backups

How many dumps are on the external storage. See [database backups](database-backups.md).

### Cron jobs

| It says | Meaning |
|---|---|
| `active` | archiving and mirroring run automatically |
| `disabled` | the lines are in your crontab but commented out — what `stop` leaves behind. `start` re-enables them |
| `not installed` | nothing is scheduled; runs only happen when you launch them |

`disabled` and `not installed` are deliberately different: one you turned off, the other was
never set up. See [scheduling](scheduling.md).

### Last archive / Last DB backup

Taken from the log. `none` means it has not happened yet; `log file absent` means there is no
log at all, which for a fresh install is expected.

A simulated run never appears here. `test_run` cannot leave a line that reads as history.

### Lock

`active` with a PID means a run is in progress right now. `stale` means a previous run died
without cleaning up — harmless, the next run clears it.

### Unfinished runs

The line that tells you whether anything needs you.

```
Unfinished runs      : 2 (oldest: run-20260919T020000, since 2026-09-19 02:00)
                       3 entry(ies) to resume, 1 blocked, 0 divergent
                       Details in /home/you/.local/state/immich-auto-dumper/runs — blocked and divergent entries need a decision.
                       Their assets stay untouched until you resolve the cause and delete that run file.
```

| Category | Meaning | What to do |
|---|---|---|
| **to resume** | the next run will finish these by itself | nothing |
| **blocked** | five attempts failed; the tool has stopped trying | find out why — usually a folder collision or a missing external library |
| **divergent** | Immich disagrees with what the tool recorded | look at that asset before anything else |
| **unreadable** | a journal line could not be parsed | that asset is left alone; the run file needs a look |

**The assets behind all of these are intact.** Each one has both a file and a database row
pointing at each other; the tool has parked it rather than guess. Nothing gets worse while
you decide, and nothing retries a blocked entry behind your back.

Once you have dealt with the cause, delete that run file to clear the entry. A run that
still holds unfinished work is never deleted automatically — removing it would remove the
record of the problem rather than the problem.

## Where the files are

| | Path |
|---|---|
| Log | `~/.local/state/immich-auto-dumper/immich-auto-dumper.log` |
| Cron output | `~/.local/state/immich-auto-dumper/cron.log` |
| Run journals | `~/.local/state/immich-auto-dumper/runs/` |

The log is truncated to its most recent lines, so it will not grow without bound. The run
journals are one file per run, JSON, one record per line — readable, if you want to see
exactly what a run did. The newest 30 completed ones are kept; the ones holding unfinished
work are kept until you remove them.

---

Back to the [user guide](../GUIDE.md) · [troubleshooting](troubleshooting.md) ·
[undoing an archive run](undoing-a-run.md).
