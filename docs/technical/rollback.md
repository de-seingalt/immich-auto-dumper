# Rollback

`archive_rollback()` (`lib/archive.sh`): undoing one identified archive run. Back to the
[technical index](../TECHNICAL.md) · user-facing version:
[undoing an archive run](../guide/undoing-a-run.md).

## Why it takes a run id

Bringing files back is a **decision**, taken on one identified run. There is no "undo the
last one", and nothing triggers it automatically — not a failed run, not a threshold, not
the cron. `status` prints the run ids; `runlog_resolve()` maps one to its file whatever its
state, and accepts the bare file name too, so pasting what `status` printed just works.

## The two directions are not mirror images

The mechanics differ by **who owns the files**.

- On the way out, `cp -p` on the host is enough: the external storage belongs to the
  invoking user.
- On the way back the target is inside the library, which belongs to the container's user,
  and this tool never uses `sudo` — so the write goes through `docker exec`.

Two implementations, not a swap of two variables.

What **is** the same in both directions is the discipline, and it lives in one place so that
both are held to it:

| Primitive | Does |
|---|---|
| `_refuse_if_occupied()` | refuse an occupied path unless what is there is already the right file |
| `_transfer_and_verify()` | write, flush, read back through the same side, compare against the fingerprint taken before anything moved |

`_transfer_and_verify container …` reads the copy back **from inside the container**, which
also proves Immich can see what was just written — the whole lesson of the dead-mount
incident described in [external storage](external-storage.md#the-host-seeing-the-storage-is-not-immich-seeing-it).
Only `cat` is assumed to exist in the Immich image; the digest is computed on the host side
of the pipe.

Archiving had the occupied-path guard and the rollback did not: it wrote over the library
path with `cat >` without looking at what was there.

## Pre-flight

1. A run id, resolved to exactly one file.
2. `check_prereqs()`.
3. `check_archive_dest_ready()` — the storage must be **reachable**, since that is where
   the files are. Any non-zero refuses.
4. `acquire_lock()` — the same lock as an archive run, so the two can never overlap.

The rollback keeps **its own journal** (`RUNLOG_DIRECTION=rollback`): it is an operation in
its own right, and the original file stays a truthful record of what that run did.

## What it walks, and what it refuses

Only entries that actually completed — state `source_supprimee` — have anything to undo.
Every other state is skipped, except two that are handled explicitly.

For each entry, in order:

| Check | On failure |
|---|---|
| The record parses | skipped, counted as a refusal |
| The entry is not already `annule` | counted apart — nothing left to undo |
| Immich says the asset is at the recorded **destination** | refused: it is not where this run left it |
| The archived copy still carries the recorded fingerprint | refused: the copy has changed since it was written |
| `_archive_restore_file()` puts it back and verifies it | refused: the archived copy is untouched |
| `db_update_asset_path()` points the database at the source | refused, entry recorded `divergent` |

Then, and only then: the external copy is removed and the sidecars are brought back.

**A refusal is not a state to carry forward.** Nothing was touched, so there is no
unfinished work to record; it belongs in the log, where it is already spelled out. Writing
it into the journal would leave `status` reporting a decision as pending for ever.

The one exception is the last row: if the file is restored but the database **cannot** be
pointed back at it, the external copy is **KEPT** so the asset still has a file behind it,
and the entry is recorded `divergent`. Same asymmetry as
[the archiving direction](archiving.md#reaching-base_a_jour), for the same reason.

`archive_rollback()` returns non-zero if it refused anything, so a partly accepted rollback
is visible to whatever invoked it and can be re-run once the cause is dealt with.

## The `annule` state

Each undone entry is recorded `annule` in the **original** run's journal — not in the
rollback's own.

Without it, the only question asked was "does the database point at the recorded
destination?", and that question **cannot tell this run's work from a later run's**. If run
B re-archived the same assets to the same paths, replaying rollback A undid B's work
instead, left B's journal claiming a job that no longer existed, and could be repeated
indefinitely.

Writing into the original run's journal does not falsify that run's account of what it did —
it extends it with what happened to it afterwards, which makes it more faithful, not less.
One entry at a time, so a rollback that was only partly accepted marks nothing beyond the
entries it completed.

`annule` also releases the asset: reconciliation does **not** hold it in
`ARCHIVE_IN_FLIGHT`, because it is back in the library and is an ordinary candidate again.

## Sidecars on the way back

`_rollback_sidecars()` re-derives the candidates from the destination path with
`_sidecar_candidates()`, exactly as they were derived from the source path on the way out,
and reconstructs each library path by the trailing difference — the sidecar sits beside its
asset on both sides.

**Honest about what that is worth.** No fingerprint was recorded for these files when they
were archived, so the check is against the archived copy read *now*: it proves the transfer
was intact, not that the sidecar was not edited on the storage since. That is strictly
better than abandoning it, and it is all the journal allows.

A file already present in the library at that path is never overwritten unless it is
identical — the same discipline as the asset. A sidecar that cannot be read, or cannot be
brought back, leaves the archived copy in place and warns.

## Further

- [The operations journal](journal.md) — the states this reads
- [The archiving engine](archiving.md) — the outward direction
- [Undoing an archive run](../guide/undoing-a-run.md) — for the operator
