# The archiving engine

`archive_run()` (`lib/archive.sh`), end to end. Back to the
[technical index](../TECHNICAL.md) · user-facing version:
[how archiving works](../guide/archiving.md).

## Decide first, act afterwards

Measuring the library and reading the thresholds **writes nothing**, so the whole decision
is taken before anything irreversible can happen.

That split is not a stylistic preference. It is what lets **one** gate stand in front of
every act that touches a photo or a database row — reconciliation included. Reconciliation
used to run above the recent-dump check; it drives the very same pipeline (copy, UPDATE
`originalPath`, adopt into the external library, delete the source), yet it was exempt from
the safety net that check exists to be. On the cron path, an asset left its internal library
for good and the run then announced "nothing to archive" and exited 0.

## Pre-flight, in order

| # | Step | On failure |
|---|---|---|
| 1 | `check_prereqs()` (`lib/utils.sh`) — Docker reachable as this user, `bc` and `sha256sum` present, the database answering, the schema valid | exits |
| 2 | `check_archive_dest_ready()` — the [storage marker](external-storage.md) | `1` ends quietly (exit 0), `2` exits non-zero |
| 3 | `guard_path_consistency()` — see below | refuses the run |
| 4 | `acquire_lock()` — see below | ends quietly if another run holds it |
| 5 | `TARGET` must be configured (and `MAX` for an unforced run) | refuses the run |
| 6 | **The gate** — a recent, usable dump | refuses the run |

Two orderings inside step 1 matter. The database is asked **before** the schema, so a
container that merely needs starting gets its own message: a stopped database once
surfaced as "Schema check failed … update this script if needed", an invitation to edit a
tool that writes to that database. And the Immich version is logged first, so a schema
failure in the log can be tied to the upgrade that introduced it.

Unrecognised arguments end the run rather than being dropped. `dump_now --force --dryrun`
once archived **for real**, with no `DRY-RUN` prefix anywhere in its output — the one typo
the flag exists to protect against.

## The two triggers

An unforced run fires on **either** condition:

- the **measured size** of `UPLOAD_LOCATION/library` (`dir_size_bytes()`, `du -sb`,
  apparent size) exceeds `ARCHIVE_LIBRARY_MAX_MB`, or
- the **total free disk space** on that filesystem drops below `ARCHIVE_MIN_FREE_MB`
  (0 = disabled).

The second exists because the first assumes the library is the only thing that can fill the
disk. On a shared filesystem, unrelated data — Postgres, Docker, logs — can fill it
instead, and the library-size trigger would never fire on its own.

Archiving is driven by the library's own footprint rather than by whole-disk usage, which is
what makes the MAX/TARGET pair mean something stable.

`--force` bypasses both triggers and **still stops at TARGET**. The target is the floor of
every run, automatic or forced; nothing archives below it.

Boundaries are in MiB; the deprecated `*_GB` keys are still honoured. See
[configuration](configuration.md#boundaries-defaults-and-the-disk-ceiling).

## The gate: a recent, usable dump

Archiving rewrites `originalPath` rows, so a **database dump younger than 7 days** in
`UPLOAD_LOCATION/backups/` is what makes those rewrites recoverable. It is demanded
**once**, here, in front of both a fresh archive and the resumption of an earlier run.

`_recent_usable_dump()` demands a **non-hidden file larger than 1 KiB**, modified in the
last 7 days:

- The previous test was "any file here, modified in the last 7 days", and the file that
  satisfied it was Immich's own 13-byte `.immich` marker. The last real dump was two months
  old and predated a major-version upgrade, so it was unusable — yet the run went ahead and
  rewrote rows on the strength of it.
- It matches on **size and age, not on a name pattern**. Matching `immich-db-backup-*`
  would tie this tool to a convention of Immich's that is free to change, which is exactly
  the coupling that breaks at the next upgrade.

The gate only fires **when there is something to do**. Without that condition, an install
whose Immich backup job is broken would log an ERROR and exit 1 every night it had nothing
to archive — noise in a log that has to stay readable, and noise ends up hiding the signal.

Refusing to resume is safe: [every resumable state is a safe state](journal.md#the-nine-states).
A dry run is exempt, since it writes nothing and `test_run` must keep previewing.

## Mutual exclusion

Two runs must never overlap: they rewrite the same rows and copy to the same destination.

The lock is a **directory**, created with `mkdir`. The kernel either creates it or fails,
with nothing in between, and it does not follow a symlink planted at the path. The previous
lock tested for a file and *then* created it, and that gap was wide enough to walk through:
two simultaneous forced dumps both started, once in five attempts. `flock` would do as well,
but this tool restricts itself to what is present everywhere, and `mkdir` is as universal
as it gets.

Four details, each of which was a defect:

- **It lives beside the logs, not under `$XDG_RUNTIME_DIR`.** Cron runs have no runtime
  dir, so keying the path on it gave the nightly run and a manual one two different locks —
  no mutual exclusion in exactly the case that matters. `LOG_DIR` is configured, stable, and
  the same in both contexts.
- **It records the holder's PID *and* boot id.** A lock directory on persistent storage
  survives a reboot, after which that PID may well be alive again as an unrelated process,
  jamming every subsequent run with a bogus "already running". `_boot_id()` is empty when
  unavailable, which skips the check rather than breaking it.
- **An orphaned lock is claimed by renaming it aside**, then deleting the renamed copy.
  `rename()` succeeds for exactly one process, so a loser can never delete the fresh lock
  the winner just created — which a plain `rm -rf` here would let it do.
- **An absent PID file is given a second to appear.** The holder writes it just after
  `mkdir`, so an absent one most often means a run that started microseconds ago — the very
  case this exists to serialise. Without the pause, two simultaneous starts would each
  decide the other's fresh lock was stale.

`release_lock()` removes the lock only if this process holds it, and is idempotent, so the
explicit call and the `EXIT` / `INT` / `TERM` traps can all run. Nothing released on
interruption before, so a Ctrl-C left a lock that only the next run's staleness check would
clear.

`lock_state()` is read-only, for `status` and `stop`, which must report on the lock without
ever taking it.

## The path-consistency guard

`guard_path_consistency()` wraps `db_check_path_consistency()` (`lib/db.sh`), which is
read-only. It detects two ways Immich's view can have diverged from the config:

- the internal library prefix derived from a live asset no longer matches
  `IMMICH_DB_LIBRARY_PREFIX`; or
- archived assets under `ARCHIVE_CONTAINER_PATH` are reported **offline** while the storage
  is reachable — the external library path was likely changed in Immich.

The offline count is split into live and trashed, and **both halves count**. Immich marks an
asset offline and moves it to the trash in the *same* operation, so counting only the live
ones made the check blind exactly when it mattered: the same three assets read
`INCONSISTENT` and then, moments later, `OK`. When trashed assets are among them the report
says out loud **not to empty the trash** before the path is fixed — that is how a mass loss
becomes permanent.

The feared false positive — someone deleting archived photos on purpose — is ruled out by
`isOffline = true`: a deliberately deleted asset is not offline. It is the conjunction that
signals the failure, and nothing needs remembering between runs.

The signal is only trustworthy while the storage is reachable (with the files genuinely
absent, every archived asset reads as offline), so every caller gates on
`check_archive_dest_ready()` first.

On an inconsistency the run aborts **and the cron entries are commented out**, so a stale
configuration cannot keep acting. On a `2` — unverified — the run is refused without
touching the cron: archiving on an unverified database is how a stale configuration gets
acted on, but an unanswering database is not a reason to disable a schedule. The tool never
rewrites the database to reconcile the two.

## Candidate selection

`db_get_archive_candidates()` (`lib/db.sh`) groups active assets — `deletedAt IS NULL`, not
offline, not already external, path under `IMMICH_DB_LIBRARY_PREFIX` and not under
`ARCHIVE_CONTAINER_PATH` — by their **immediate parent directory**, and orders groups by
`MIN(fileCreatedAt)`.

That makes the unit of work template-agnostic: the genuinely oldest photos leave first
whatever the storage template, and a directory is never left half-archived, because the
stopping condition is only evaluated *between* directories.

The prefix restriction is itself a guard. The selection used to offer every internal asset
whatever its path, including one living outside `IMMICH_DB_LIBRARY_PREFIX` — for which
`split_part` returns an empty user folder and no destination can be built at all. Not
offering it is better than refusing it one layer later, and the
[shape guard](../TECHNICAL.md#the-shape-guard) still covers it.

### Capture, check, then iterate

The list is captured into a variable, its exit code checked, and *then* iterated as an
array. **Never** `while … done < <(db_get_archive_candidates)`.

That form throws the function's exit code away. `_db_exec()` answers `2` when psql could not
run, but the loop simply sees no rows: the run reports `Archive complete. Freed: 0 B.` with
`rc=0`. A database that stops answering after pre-flight becomes indistinguishable from
"nothing left to archive" — the library quietly stops being archived and the cron reports
success every night.

Iterating an array also leaves stdin alone, which matters wherever a prompt follows.

The same treatment applies to the per-directory query, where the failure is per-directory:
it is logged, the directory is counted in `dirs_failed`, and above all **not announced as
archived**.

## The per-asset pipeline

`_archive_move_file()` works out the destination and the fingerprint, then hands over to
`_archive_process_asset()`, which drives one asset from wherever the journal left it to
`source_supprimee`. Returns 0 archived, 1 skipped (retry later), 2 terminal.

The fingerprint is taken **before anything moves**: it is what later authorises deleting the
source, and what a rollback checks the restored file against.

Each transition is recorded **before** the act it describes, and a record that cannot be
written stops that act. Those cases return 1 rather than parking the entry: nothing was
attempted, so the attempt counter must not move.

### Reaching `prevu`

Record, then ask what is already at the destination with `_refuse_if_occupied()`:

| Answer | Action |
|---|---|
| nothing there | write it |
| there and **identical** | skip the copy, update the database only |
| there and **different**, or uncomparable | skip the asset, keep the source |

The third case is usually two users mapped to the same folder in `USER_MAP`, and the log
says so.

### Reaching `copie`

`_transfer_and_verify host …` copies with `cp -p`, flushes, reads the copy back, and compares
against the recorded fingerprint. A partial file is removed — on whichever side it was
written — and the other copy is still in place, so nothing is lost.

`cp -p` keeps the timestamps. Without `-p`, every archived photo arrived on the external
storage dated the day it was archived, losing the only file-level trace of when it was taken.

### Reaching `base_a_jour`

`db_update_asset_path()` rewrites the path and adopts the asset — see
[the one write](../TECHNICAL.md#the-one-write). Two conditions are then checked, and either
one undoes the update:

1. **An external library must cover the destination** (`DB_UPDATE_IS_EXTERNAL == t`). An
   archived asset left as a plain upload asset gets re-imported as a duplicate by Immich's
   periodic library scan, and stays exposed to the storage-template migration job.
2. **The copy must be visible from inside the container** (`test -f`).

On either fault, `_archive_restore_db()` points the database back at the source. **Its
answer is checked**, and this is the single most important asymmetry in the engine:

- **Restore succeeded** → the copy serves no purpose and is removed. The asset is exactly as
  it was, and will be retried next run.
- **Restore failed** → the copy is **KEPT**. The database points at it, so the asset still
  has a file behind it. The state is consistent, just not the one we wanted, and it needs a
  person: the entry is recorded `divergent` and the log names the `rollback` command.

Removing the copy in that second case is what turned a recoverable failure into an asset
with no file *and* an unreferenced original.

### Reaching `source_supprimee`

`_archive_remove_source()` deletes the source **through the container**, which owns the
library files, and refuses unless the file still carries the fingerprint recorded before the
copy — if it changed, the source is no longer the photo we archived.

A failure here leaves the entry `base_a_jour` rather than treating it as a failure of the
move: the archive itself succeeded, the asset points at the copy and is readable, and only
the cleanup is outstanding.

This is the **one** record written *after* its act rather than before it, so its failure
stays a warning: the next run re-reads the database, finds the asset at its destination and
finishes cleanly.

### Parking

`_park()` records the entry in the state it reached and returns the right code. It is
nested inside `_archive_process_asset()` on purpose: bash scopes dynamically, so it reads
the caller's locals instead of taking ten arguments that would only ever be those.

An entry that reaches `RUNLOG_MAX_ATTEMPTS` becomes `bloque`, except for `divergent` and
`abandonne`, which are already terminal.

## Sidecars

XMP and JSON sidecars are moved alongside their asset and are **not tracked in Immich's
database at all**. Verified against v3.2.0: no `%sidecar%` column in any table, and
`asset_file` carries only `preview`/`thumbnail`. Immich finds them by naming convention when
it scans.

That is why the tool has to move them itself, and why the journal cannot describe them.

`_sidecar_candidates()` derives four names — `<path>.xmp`, `<path>.json`, and the same two
with the extension stripped from the **file name** and not from the whole path — and
deduplicates them, since for an asset with no extension the two forms name the same file (a
simulation used to announce it twice). Both directions use that one helper, so what goes out
and what comes back are decided in one place.

A sidecar is held to the same fingerprint discipline as its asset: the source is only
removed once the copy is proved identical. The test this replaced — does the destination
exist — accepted a truncated file and then deleted the original.

## Accounting

**What a move frees is read off the filesystem**, with `stat` on the source while it is
still there, into `ARCHIVE_LAST_FREED_BYTES`.

Immich's own `fileSizeInByte` is good enough only to *sort* the candidates. With the exif
rows missing, those sizes summed to zero, the stopping condition was never met, and a run
asked to free 178 KB moved 1.2 MB: every directory there was.

For the same reason the stopping condition **re-measures** the library with `du` between
directories, rather than adding up what the metadata advertised.

One closing line per directory names which of five outcomes it had: archived, partially
archived, not archived (every asset failed), nothing left to archive, or left alone because
every asset is held by an unfinished run. "Directory archived" used to be printed whatever
happened, with the directory's full size, as if that space had been freed.

## Dry runs

`--dry-run` (and `test_run`, which implies `--dry-run --force`) suppresses every
destructive operation. Two rules hold it honest:

- **It opens no journal and writes no record.** A simulation must leave nothing that a later
  read takes for work done.
- **No line it logs may read as work done.** `status` reports the last `Archive complete`
  and `DB backup:` lines as history, so every simulated line carries the `DRY-RUN:` prefix
  and different wording. Its closing line says "would free", not "Freed".

A dry run still reports the outstanding work it *would* resume, from `runlog_summary()`, and
still sums what it would free so its stopping condition matches a real run's. A simulation
that announced every candidate directory, where a real run stops after two, is not a
preview.

## Exit code

`archive_run()` returns non-zero when the run was refused, when a directory could not be
read (`dirs_failed`), or when it put at least one entry into `bloque` or `divergent`.

`ARCHIVE_TERMINAL_COUNT` counts entries **written during this run**, not entries present in
`runs/`. Counting what is present would leave the light red night after night, since a
divergent entry survives until an operator deletes the run file. Counted this way, the
non-zero exit falls exactly once, on the run that produced the problem — reconciliation
skips the states that are not resumable, so no later run writes them again.

The exit code is not an alert channel; the log is, and it is precise and timestamped. What
it buys is an exact status something else can be built on, and alignment with
[`archive_rollback()`](rollback.md), which already exits non-zero when it refused anything.

## Further

- [The operations journal](journal.md) — the records this engine writes
- [External storage and file identity](external-storage.md) — the primitives it relies on
- [Rollback](rollback.md) — the same discipline, backwards
- [Failure modes](failure-modes.md)
