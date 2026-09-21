# The operations journal and resumption

How a half-finished move survives an interruption, and how the next run picks it up. Back
to the [technical index](../TECHNICAL.md) · user-facing version:
[what `status` tells you](../guide/monitoring.md).

## Why a journal

Archiving one asset is four steps — copy, update the database, verify the result, delete the
source — and **only the whole sequence is safe.**

When it broke in the middle, the tool improvised: it tried to put the database back and,
whether that worked or not, deleted the copy. A test that made the restore fail left the
database pointing at a path with no file, and the source photo sitting in the library with
nothing referencing it. One asset, two halves, neither usable.

So each step is written down **before** it is taken. A run that is interrupted, or that
gives up on an asset, leaves a record precise enough for the next run to pick that asset up
where it was left — and precise enough to undo it on request.

## The journal is a memo, never an authority

Immich keeps living between runs. Someone may delete the photo, empty the trash, run a
storage-template migration, or restore a dump.

So the database is **re-read before every irreversible act** and has to agree with what the
journal expects. `_archive_db_position()` (`lib/archive.sh`) asks
`db_asset_position()` and answers one of:

| Answer | Meaning |
|---|---|
| `source` | still at the recorded source — any later step was undone |
| `destination` | already at the recorded destination — the update went through |
| `absent` | the asset is gone, or in the trash — the user has decided |
| `divergent` | somewhere else entirely — a template migration, a restored dump |
| `inconnu` | the database did not answer |

Immich remains the source of truth; the journal only remembers what *this tool* was in the
middle of doing. Where the two disagree, the journal loses.

## Files

One file per run under `$LOG_DIR/runs/`, with the outcome carried by the **extension**, so
it can never be half-written:

```
run-20260920T020000.active   in progress
run-20260920T020000.done     finished, everything completed
run-20260920T020000.failed   finished with entries left behind
```

An `.active` file found while a run holds the [lock](archiving.md#mutual-exclusion) belongs,
by construction, to a run that was **killed**: a dying process cannot rename its own file.

`runlog_close()` performs the rename, which is atomic. A rename that fails leaves the file
`.active` — the right behaviour, and the right one to keep — but it used to happen in
complete silence, so an operator had no way of knowing why a run that finished cleanly kept
turning up as unfinished. It now warns.

An **empty** journal that this process opened is discarded rather than kept: a file per
nightly no-op run would push the ones that matter out of the retention window. The test is
against `RUNLOG_OWN_FILE` and not `RUNLOG_FILE`, which reconciliation retargets — a run
file left behind by an earlier invocation is never deleted there, whatever it holds. That
rule is what keeps unfinished work from quietly disappearing.

## Records

Records are JSON, one per line, written and read by this tool alone — readable by a person
and by anything else.

```json
{"ts":"2026-09-20T02:00:03+0200","sens":"archive","asset":"…","etat":"copie",
 "tentatives":1,"taille":103278,"sha":"6e3cf3f5…","src":"…","src_db":"…",
 "dst":"…","dst_db":"…"}
```

- `_runlog_escape()` / `_runlog_unescape()` handle exactly two sequences, `\\` and `\"`, so
  a single left-to-right pass cannot mis-pair them.
- `sens` is `archive` or `rollback`. The two directions share the same state vocabulary,
  and "source removed" means opposite things depending on which way the run was going. It
  is a **scalar**, read back with `archive` as the default, so a journal written before the
  field existed stays valid and nothing in the parser has to change. That is also why it is
  not a list of sidecars: this JSON is written and read by hand, and the whole resumption
  depends on that parser.
- `runlog_path_is_recordable()` refuses an asset whose paths contain a line break. That
  would split one record across two lines and make the whole file ambiguous. No Immich
  library path contains one, and refusing is cheaper than inventing an encoding for a case
  that does not occur.

**A line that does not parse makes its asset untouchable** (state `illisible`) rather than
guessed at. An unreadable memo authorises nothing.

`runlog_read()` echoes the *current* state of every asset in a file, last record winning.
Its warning about an unreadable line goes to **stderr**, not stdout: its stdout *is* the
record stream its callers parse, and a log line written there arrives as a bogus record
whose asset name is the message itself.

Each record is flushed as it is written (`_runlog_flush()`), because a memo that only
exists in the page cache does not survive the power cut it is there to protect against.
Four small writes per asset are nothing beside copying the photo. The flush is deliberately
narrow — see [the note on write-back mounts](external-storage.md#write-back-mounts).

`runlog_record()` **returns non-zero when the record could not be written.** It used to warn
and return 0, so the caller went straight on to the irreversible act the record was meant to
describe — the exact opposite of the guarantee this file exists for. The three callers that
stand in front of an irreversible step check the answer and skip the asset.

## The nine states

| State | Meaning | Resumable |
|---|---|---|
| `prevu` | decided, nothing done yet | yes |
| `copie` | written at the far end, database not yet pointed at it | yes |
| `base_a_jour` | database points at the far end, the other copy still present | yes |
| `source_supprimee` | finished | — |
| `annule` | finished, then undone by a rollback of this very run | — |
| `bloque` | gave up after `RUNLOG_MAX_ATTEMPTS` (5) tries — needs a person | no |
| `divergent` | Immich disagrees with the journal — needs a person | no |
| `abandonne` | the asset left Immich; nothing left to resume | no |
| `illisible` | the record could not be parsed; authorises nothing | no |

`runlog_is_pending()` recognises the first three. `bloque` and `divergent` are what make a
run [exit non-zero](archiving.md#exit-code). `abandonne` is **not** one of them: the asset
left Immich, which is its owner's decision, not a failure.

**Every resumable state is a safe state**, which is what lets the
[gate](archiving.md#the-gate-a-recent-usable-dump) refuse to resume without a recent dump.
At `copie` the file is at the destination and the database still points at the source; at
`base_a_jour` the database points at the copy and the source is still on disk. Nothing is
lost by waiting.

## Reconciliation

`archive_reconcile()` (`lib/archive.sh`) is phase one of every real run. It drives each
pending entry through the same pipeline as a fresh archive, retargeting `RUNLOG_FILE` at
each old file so a resumed transition lands in the run it belongs to; each file is appended
to in place and then closed, so one run's history stays in one file.

It comes **before** the thresholds are acted on, because a half-archived asset is a
liability whether or not the library is over its limit today. It is deliberately not a
reason to refuse a fresh archive either: the moment the disk is filling up is exactly when
the tool has to keep working.

An entry that has already used up its tries is **parked explicitly** as `bloque` rather
than stepped over every night: the journal should say out loud that it has been given up
on, and `status` should count it among the ones needing a decision.

### Assets in flight

What remains unfinished afterwards fills `ARCHIVE_IN_FLIGHT`, and the candidate selection
**leaves those assets alone**.

Without that, an asset that keeps failing is still an internal asset, so a fresh run picks
it up again and opens a **second** entry whose attempt counter starts at one. That is how an
asset blocked by a foreign file at its destination collected four "first attempts" across
four runs and never reached the ceiling meant to park it.

`annule` is **not** held: a rollback put that asset back in the library, so it is an
ordinary candidate again and must not stay claimed for ever.

Assets held this way are **counted, not merely skipped**. When a journal held *every* asset
of a directory the inner loop never ran, both counters stayed at zero, and the report read
"all 0 asset(s) failed" — an error announced where nothing had even been attempted.

## Retention

`runlog_rotate()` keeps the newest `RUNLOG_KEEP_DONE` (30) `.done` files and deletes the
rest. Their only use is rollback, whose value fades.

Ordered **by name, never by mtime**: the timestamp in the name makes lexicographic order
chronological, and unlike mtime it cannot be misreported by the storage. Same discipline as
the [dump rotation](database-backups.md#retention-orders-by-filename-never-by-mtime), for
the same reason.

`.active` and `.failed` are **never** touched. They represent work in abeyance, and deleting
them would delete the problem rather than the file.

Rotation runs deliberately *outside* the gate: deleting old `.done` journals touches no
photo and no row, so a run refused for want of a dump still does its housekeeping. A dry
run skips it, since it writes nothing at all.

## Reading a journal by hand

`runlog_resolve()` maps a run id to its file whatever the state, and accepts the bare file
name too, so pasting what `status` printed just works. `runlog_summary()` echoes
`pending blocked divergent unreadable files oldest_id` across every unfinished file, which
is what `status` reports.

An entry that has used up its tries is counted as **blocked** by the summary whatever its
state says: counting it as "to resume" would promise something that is not going to happen.

## Further

- [The archiving engine](archiving.md) — where these records are written
- [Rollback](rollback.md) — where they are read backwards
- [What `status` tells you](../guide/monitoring.md) — the same information, for the operator
