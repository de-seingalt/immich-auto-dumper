# Development history

What has been exercised, what has been fixed, and what is still known not to hold. Back to
the [technical index](../TECHNICAL.md).

This page is the **only** place in the documentation that looks backwards. Every other page
describes the tool as it is now; if you find a "used to" anywhere else, it is there because
the defect explains a guard that would otherwise look arbitrary.

## Immich versions exercised

The tool talks to Immich's database directly, so it is verified against specific releases
rather than assumed to work with any of them.

| Immich | Status |
|---|---|
| **v3.2.0** | Exercised end to end (September 2026): schema check, archiving, library adoption, resumption, rollback, DB-dump mirroring. |
| **v2.7.5** | Exercised end to end. |

Versions in between are expected to work — no schema change affecting the columns the tool
relies on was introduced — but have not been exercised.

Whatever your version, run `immich-auto-dumper test_run` after every Immich upgrade before
re-enabling the scheduled jobs. It changes nothing and reports immediately if the database
no longer matches what the tool expects. See
[schema validation](../TECHNICAL.md#schema-validation) for what that check does and does
not cover.

One finding worth recording, because it constrains the design: **Immich v3.2.0 does not
track sidecars in its database.** There is no `%sidecar%` column in any table, and
`asset_file` carries only `preview` and `thumbnail` rows. Immich locates sidecars by naming
convention when it scans. That is why the tool has to
[move them itself](archiving.md#sidecars), and why the journal cannot describe them.

## Hardening passes

Newest first. Each line is a pass, not a commit.

**Documentation** (September 2026) — The comment convention changed: a comment describes
what the thing it sits above does, in the present tense, and nothing else. Comment lines
fell by roughly a third. The technical documentation was brought up to the code it
documents and split into this set of pages, and the user guide was written.

**Finishing pass** (September 2026, `f848c78`…`3ae58f4`) — Ten batches. A recent dump became
a precondition demanded **once**, in front of every irreversible step including the
resumption of an earlier run, which had been exempt from it. The journal became a condition
of the work rather than a companion to it: a run that cannot open one no longer archives at
all. A silent database stopped reading as an empty library. The rollback was held to the
same discipline as the outward direction, stopped being replayable, and learned to bring
sidecars back. `config.conf` stopped dying on its own punctuation. Dialogs stopped cropping
their last lines. Runs began reporting what they left behind through their exit code.

**Audit corrections** (September 2026, `82368ed`…`d08f55e`) — Twelve corrections following a
data-safety audit and a campaign of tests against a real Immich. File identity became a
fingerprint rather than a size. The lock became uncrossable. `config.conf` stopped being
executed. "Answered no" and "did not answer" became different answers throughout. Each step
of an archive began to be written down before it was taken. Freed space began to be measured
rather than inferred from metadata. Dates, neighbouring files and paths containing a `|`
stopped being lost.

**Setup ergonomics and dump rotation** (September 2026, `6120eed`…`22fca18`) — Re-running
`setup` began opening on a review of the saved config instead of replaying the whole
questionnaire. Dump rotation stopped ordering by mtime, which had let it delete the dumps it
had just copied. A dry run stopped logging an archive that never happened. The direct
database connection was disclosed prominently in the README.

**Free-disk safety net** (September 2026, `6deafc9`, `b0dbed0`) — A second, independent
trigger, so archiving still fires when unrelated data on the same filesystem is what fills
the disk.

**Pipeline hardening** (July 2026, `b5a001a`…`3b5d0fd`) — Copies began having their exit
code and size checked before the source was deleted. Archived assets began being adopted
into their external library, which is what stops Immich's scan re-importing them as
duplicates. The `library` table joined the schema check, and the running Immich version
began being logged.

**Storage marker and path-consistency guard** (June 2026, `daffc54`) — Availability became
agnostic to the storage type, by writing a marker on the storage itself. A read-only check
began detecting that Immich's own paths had drifted from the configuration.

**No privileges** (June 2026, `07c265f`) — The `sudo docker` fallback was dropped. The tool
runs strictly as the invoking user.

Earlier commits cover the initial implementation, the setup wizard and its gauge, the
uninstaller, and the move to a home-directory install.

## Classes of defect fixed

Grouped by shape rather than listed one by one, because the shape is what recurs. Each links
to the guard that now prevents it.

- **An uncertainty rendered as a negative.** A dependency that could not be reached answered
  "no" instead of "I cannot tell", and every false all-clear the audit found came from that
  single confusion. → [the diagnostic convention](../TECHNICAL.md#the-diagnostic-convention)
- **Size taken for proof of identity.** A foreign file of the same byte count was accepted
  as an already-archived copy, and the original photo was deleted in its favour. →
  [file identity](external-storage.md#file-identity)
- **An exit code discarded by a process substitution.** `while … done < <(query)` throws the
  query's status away, so a database that stopped answering read as "nothing left to
  archive" — and the cron reported success every night. →
  [capture, check, then iterate](archiving.md#capture-check-then-iterate)
- **A misspelled safety flag ignored.** An unrecognised argument was collected and dropped,
  so `dump_now --force --dryrun` archived for real. Unknown flags now stop the run. →
  [pre-flight](archiving.md#pre-flight-in-order)
- **Configuration executed instead of read.** `config.conf` was `source`d, which made every
  value in it a command — for every invocation, including the read-only ones and the
  uninstaller's, and usually from cron. →
  [config.conf is data, never code](configuration.md#configconf-is-data-never-code)
- **A guarantee that only held in one direction.** Archiving refused to overwrite an occupied
  path; the rollback did not. Both directions now go through the same two primitives. →
  [rollback](rollback.md#the-two-directions-are-not-mirror-images)
- **Two safety nets that failed together, silently.** A dialog sized by logical lines was
  cropped by whiptail, and because the computed height stayed under the terminal cap the
  scroll fallback was not triggered either. →
  [dialog geometry](interactive-layer.md#dialog-geometry)
- **A recovery step whose result was not checked.** The database restore after a failed move
  was attempted and its answer ignored, and the copy was deleted regardless — turning a
  recoverable failure into an asset with no file and an unreferenced original. →
  [the per-asset pipeline](archiving.md#reaching-base_a_jour)
- **Metadata trusted over the filesystem.** Freed space was summed from Immich's
  `fileSizeInByte`; with those rows missing the total was zero, the stopping condition never
  became true, and a run asked to free 178 KB moved 1.2 MB. →
  [accounting](archiving.md#accounting)
- **An mtime believed on storage that cannot report one.** Rotation by modification time
  ranked freshly copied dumps as the oldest and deleted them mid-upload. →
  [retention orders by filename](database-backups.md#retention-orders-by-filename-never-by-mtime)
- **A report that described the intention rather than the outcome.** "Directory archived" was
  printed whatever happened, with the directory's full size, as if that space had been
  freed. → [accounting](archiving.md#accounting)

## What is tested, and how

- **Pure functions** — path building, size parsing, config parsing, file identity, the
  journal parser — are covered by a suite of assertions that is **not shipped**: an end
  user has no use for it, and it lives outside the repository.
- **There is no CI.** Nobody runs anything for you.
- **`shellcheck -S warning -x`** is expected to be clean on all eleven shell files. The
  seven `# shellcheck disable=…` directives in the tree are load-bearing.
- **Destructive behaviour** — real archiving, interruption at each journalled step, a
  rollback, a storage pulled out mid-run, a database stopped mid-query, a write-back mount —
  is exercised against a **disposable virtual machine** running a real Immich, restored from
  a snapshot between campaigns. Never against an installation holding real photos.
- **The whiptail backend cannot be tested through a pipe.** It requires a real terminal, and
  two defects hid there until someone looked at one. See
  [the note on testing this](interactive-layer.md#a-note-on-testing-this).

## Known limitations

- **On a write-back mount, "archived" means "handed to the mount".** `cp`, `sync -d` and a
  fingerprint read-back can all succeed while the file has not reached the backend; the read
  is served by the local cache. The tool stops where rclone takes over. →
  [write-back mounts](external-storage.md#write-back-mounts)
- **The schema check verifies column presence, not semantics.** An additive migration, or a
  change of meaning with unchanged names, is not detected. →
  [schema validation](../TECHNICAL.md#schema-validation)
- **An entry left `bloque` or `divergent` needs a human.** Nothing resolves it
  automatically, and the run file survives until an operator deals with it and deletes it.
  → [the nine states](journal.md#the-nine-states)
- **Immich must be running** for `setup` to configure anything, since it configures itself
  from the live install.
- **Sidecars carry no recorded fingerprint.** On a rollback their verification proves the
  transfer was intact, not that they were never edited on the storage since. →
  [sidecars on the way back](rollback.md#sidecars-on-the-way-back)
- **Container detection takes the first match.** It names every candidate when there is more
  than one, but it does not ask. →
  [where the values come from](configuration.md#where-the-values-come-from)
- **One Immich install per configuration.** There is no notion of profiles.
