# Database-dump mirroring

`backup_db_run()` (`lib/backup_db.sh`). Back to the [technical index](../TECHNICAL.md) ·
user-facing version: [database backups](../guide/database-backups.md).

## What it is, and what it is not

Immich dumps its own database into `UPLOAD_LOCATION/backups/` and rotates those dumps
itself. This function **copies** them to `<storage>/.immich-backup/` and rotates its own
copies. It never creates a dump, and it never touches the database.

Because it never touches the database, it deliberately **skips the
[path-consistency guard](archiving.md#the-path-consistency-guard)**: mirroring dumps stays
safe and useful while an external-library path change is being resolved — arguably it is
exactly then that you want a copy of the database off-machine.

It does take the [lock](archiving.md#mutual-exclusion). Mirroring took none at all, so two
overlapping `sync_now` could `cp` onto the same destination file and rotate the same
directory underneath each other. A dry run needs none, since it writes nothing.

## Retention is validated first

`BACKUP_RETENTION` decides how many mirrored dumps survive the run, so an unusable value is
checked **before anything is copied** — and before a dry run reports on a policy it could
not apply.

- An empty or zero value deleted every dump on the external storage and logged it at INFO,
  which a cron mail reads as a success.
- A non-numeric one crashed mid-rotation.

**Refusing the whole run is deliberate.** Copying while the rotation is broken piles dumps
up for ever, and an invalid retention means the configuration needs fixing — not that a
default should quietly stand in for it.

The value is re-read from disk between runs, so validating it at load time alone would not
cover a hand edit.

## Copying

Hidden files are skipped, so Immich's own `.immich` marker is not mirrored as though it were
a dump.

**A destination of the same size is treated as the same dump, already mirrored, and left
alone.** Dumps are immutable and their name carries their timestamp. Skipping keeps each run
proportional to what is actually new instead of re-uploading the whole retention window
every time — which on a metered or write-back mount is the difference between a few MB and a
full GB, and avoids rewriting files the storage may still be flushing from the previous run.

This is deliberately a **size** comparison and not a fingerprint, unlike everywhere else the
tool decides two files are the same. The reasoning is narrow and worth stating:

- Nothing is deleted on the strength of this answer. At worst a dump is re-copied.
- A fingerprint would mean reading the entire retention window back from the remote every
  single run.
- What a fingerprint *does* guard is the copy this run makes, and that one **is** checked:
  `file_flush()` then `files_are_identical()`, right after it is written. A copy that does
  not match is removed and not counted as mirrored. A dump that is only nearly there is
  worse than an absent one — it looks like a safety net and is not.

A destination present with a **different** size is a truncated leftover — an interrupted
run, a full storage, a cancelled upload — and is overwritten rather than kept.

A dump that has vanished between the listing and the `stat` is **skipped**, not counted as
zero. Immich rotates its own dumps, so a file listed a moment ago can be gone by the time it
is measured; unguarded, that killed the script under `set -e` in the middle of mirroring.
And a size of 0 would never match the destination, so the dump would be re-copied for ever.

## Retention orders by filename, never by mtime

Dump names start with a timestamp (`immich-db-backup-YYYYMMDDTHHMMSS-…`), so lexicographic
order is chronological order — and unlike mtime, a name cannot be misreported by the
storage.

**This is not a stylistic choice.** On a write-back mount (rclone `--vfs-write-back`, async
NFS…) a file whose upload is still pending has no known modification time, and the mount
answers with a placeholder date far in the past.

An mtime-based rotation then ranks the dumps it has **just copied** as the oldest on the
volume and deletes them — cancelling their upload in flight, silently, while the log still
reports every file as copied. The result is a storage that reports N dumps retained and
holds none of the recent ones.

Treat any mtime read from external storage as unreliable. Compare names and sizes instead.
The [journal retention](journal.md#retention) follows the same discipline for the same
reason.

Sorting is `LC_ALL=C` so the order does not depend on the locale, and oldest-first after the
sort: the head is deleted, the tail kept.

## Reporting

The closing line — `DB backup: N file(s) retained, S total.` — is what
[`status`](../guide/monitoring.md) reads back as the last mirroring. A dry run never emits
that wording.

Totalling the retained files guards the `stat` the same way, for the same reason: a file
that disappeared between the listing and the total contributes nothing rather than ending
the run.

## Further

- [External storage and file identity](external-storage.md) — the flush, and what a
  write-back mount does not guarantee
- [Scheduling](scheduling.md) — `sync_now` runs weekly by default
- [Configuration](configuration.md) — how `setup` suggests `BACKUP_RETENTION`
