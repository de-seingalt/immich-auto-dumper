# Database backups

Keeping a copy of Immich's database dumps on the external storage. Back to the
[user guide](../GUIDE.md).

## What this does, and what it does not

Immich dumps its own PostgreSQL database on a schedule, into its upload location:

```
<upload location>/backups/immich-db-backup-20260920T020000-....sql.gz
```

This tool **copies** those dumps to your external storage:

```
<storage>/.immich-backup/
```

and keeps the newest `BACKUP_RETENTION` of them there.

**It does not create dumps.** If Immich is not making any, there is nothing to mirror — and
archiving will refuse to run anyway, since it
[requires a recent dump](archiving.md#the-backup-precondition). Enable Immich's scheduled
database backups; they are on by default.

It never reads or writes the database itself, which is why it keeps working even while an
external-library path problem is being sorted out.

## Why bother

Your photos end up in two places: Immich's internal library and the external storage. The
database is the thing that knows which photo is where — including every path this tool
rewrote. A dump sitting only on the machine whose disk was filling up is not much of a
safety net.

## How many to keep

`BACKUP_RETENTION`, chosen during [setup](configuration.md#5-how-many-database-dumps-to-keep).

The wizard reads how many Immich keeps locally and suggests the same number, because
**keeping at least as many means a dump is never dropped from your external copy while
Immich still has it locally.** Keep fewer and the oldest ones exist in one place only —
which the wizard warns about and `status` reports as a note.

The two counts are independent: Immich rotates its dumps, this tool rotates its copies.

## Running it

```bash
immich-auto-dumper sync_now              # mirror now
immich-auto-dumper sync_now --dry-run    # show what would be copied
```

The scheduled job does this weekly, Sunday at 03:00 — see [scheduling](scheduling.md).

A dump already on the storage at the same size is skipped, so a run only transfers what is
new. That matters on a metered or slow connection: without it, every run would re-upload the
whole retention window.

Each copy is verified after it is written. A copy that does not match the dump is removed
rather than counted — a dump that is only nearly there looks like a safety net and is not.

If `BACKUP_RETENTION` is invalid — empty, zero, or not a number — the whole run refuses and
copies and deletes **nothing**. A retention of zero would delete every mirrored dump, so no
default quietly stands in for a broken value. Fix it with `setup`.

## Checking

```
DB backups           : 5 file(s) in .immich-backup/
Last DB backup       : 2026-09-20 03:00:12 — 5 file(s) retained, 412.7 MB total.
```

See [monitoring](monitoring.md).

## Restoring one

That is Immich's job, not this tool's. The files in `.immich-backup/` are ordinary Immich
database dumps, untouched — follow
[Immich's own restore procedure](https://immich.app/docs/administration/backup-and-restore)
and point it at one of them.

Two things to keep in mind if you ever do:

- **Restore the database and the files together.** A dump older than your last archive run
  points at paths as they were then; photos archived since will look absent to Immich. If
  that happens, `status` reports the path inconsistency and tells you not to empty the
  trash — see [troubleshooting](troubleshooting.md).
- **Run `immich-auto-dumper status` afterwards** to confirm the tool and Immich still agree.

## A note on cloud storage

If your external storage is a write-back mount (rclone and similar), a freshly copied dump
may still be uploading when the run finishes. The tool never reasons about modification
times on external storage for exactly this reason — see
[the technical page](../technical/database-backups.md#retention-orders-by-filename-never-by-mtime).

---

Back to the [user guide](../GUIDE.md) · [monitoring](monitoring.md).
