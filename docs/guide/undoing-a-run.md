# Undoing an archive run

Bringing archived photos back into Immich's internal library. Back to the
[user guide](../GUIDE.md).

```bash
immich-auto-dumper rollback <run-id>
immich-auto-dumper rollback <run-id> --dry-run
```

## What it undoes

**One identified run**, and nothing else.

There is no "undo the last one" and no "undo everything". It never happens on its own — not
after a failed run, not on a threshold, not from cron. Bringing files back is a decision,
taken on one run you have looked at.

For every asset that run finished archiving, it copies the file back into the library,
verifies it, points Immich at it, removes the external copy, and brings the sidecars back
alongside.

## Finding the run id

`status` lists unfinished runs by id:

```
Unfinished runs      : 1 (oldest: run-20260919T020000, since 2026-09-19 02:00)
```

For completed runs, look in the journal directory:

```bash
ls ~/.local/state/immich-auto-dumper/runs/
# run-20260919T020000.done
# run-20260920T020000.done
```

The id is the name without the extension, though pasting the full file name works too:

```bash
immich-auto-dumper rollback run-20260920T020000
```

The newest 30 completed runs are kept, so a run from months ago may no longer be there.

## Looking first

`--dry-run` walks the same run and asks the same three questions of every asset: does
Immich still point where this run left it, is the archived copy still readable, and is it
still the file that was written. Those are reads, so the preview stops at the first write
and tells you what the real rollback would accept and what it would refuse.

```
DRY-RUN: nothing will be restored, removed, or written to the DB.
DRY-RUN: would restore asset 3f2a… → /srv/immich/library/admin/2024/IMG_0042.jpg
DRY-RUN: Asset 9c1e… is not where this run left it (Immich says: source) — would be refused, nothing touched.
DRY-RUN: would bring back 11 asset(s) of run-20260920T020000.done, 1 refused. Nothing was moved.
```

It writes nothing at all: no journal of its own, no mark in the run being previewed, no
file moved. The storage still has to be reachable, since reading the archived copies is
most of what the preview does.

## What you need

- **The external storage must be reachable.** That is where the files are. If it is not,
  the rollback refuses rather than doing half the job.
- Immich should be running, as for any other command.

## What it refuses, and why that is good news

An asset is **refused and reported** when its current state does not match what the run
recorded:

| Situation | Why |
|---|---|
| Immich no longer points at where this run put the asset | something else moved it since — a later archive run, a template migration, a restored dump |
| The asset is gone from Immich, or in the trash | you deleted it; putting the file back would not resurrect it |
| The archived copy's checksum has changed | the file on the storage is no longer the one this run wrote |
| A **different** file already sits at the library path | overwriting it would destroy something |

In every case **nothing is touched** and the archived copy is left exactly as it was. The
run reports how many it brought back and how many it refused, and exits non-zero if it
refused anything.

That is the behaviour you want. A rollback that forced its way through would be a rollback
you could not trust to run at all.

Deal with the cause and **run it again** — it picks up the entries it did not complete.

## Running it twice is safe

Yes. Each asset it brings back is marked as undone in that run's journal, so a second
rollback of the same run sees there is nothing left to do and says so:

```
Rollback of run-20260920T020000.done: 0 asset(s) brought back, 0 refused, 12 already undone by an earlier rollback.
```

This matters more than it sounds. Without that mark, replaying an old rollback after a
*newer* run had re-archived the same photos would undo the newer run's work instead.

## After a rollback

The assets are back in Immich's internal library, taking up space on your Immich disk
again — which means the **next scheduled run may archive them straight back**, if that
pushes the library above MAX.

If you rolled back to keep those photos local, adjust MAX and TARGET with `setup`, or
`stop` the schedule first. Otherwise you will be watching the same photos go out again
tomorrow at 02:00.

Check the result:

```bash
immich-auto-dumper status
```

## A note on sidecars

XMP and JSON sidecars come back with their photo. They are not recorded in the journal
individually — Immich does not track them in its database at all, so the tool finds them by
name next to the asset.

One honest limitation: no checksum was recorded for a sidecar when it was archived, so the
check on the way back proves the copy transferred intact — not that the sidecar was never
edited on the storage in the meantime. A sidecar already in the library is never
overwritten unless it is identical.

---

Back to the [user guide](../GUIDE.md) · [monitoring](monitoring.md) ·
[how it works inside](../technical/rollback.md).
