# How archiving works

What triggers a run, what moves, and what to check first. Back to the
[user guide](../GUIDE.md) · previous: [configuration](configuration.md) · next:
[scheduling](scheduling.md).

## The two triggers

A scheduled run archives when **either** of these is true:

- your library has grown **above MAX**, or
- **total free disk space** has fallen **below FREE**.

Then it moves photos until the library is back down to **TARGET** — and stops there. No run
ever takes the library below TARGET.

The second trigger matters more than it looks. MAX watches your library; FREE watches the
whole disk. If Postgres, Docker images or logs are what fill your disk, the library may
still be under MAX while the machine is out of space, and MAX alone would never fire.

If neither is true, the run says so and exits quietly. That is the normal outcome most
nights.

## What moves, and in which order

**Oldest first.** Assets are grouped by the folder they sit in, and the groups are ordered
by the oldest photo each one contains — so your genuinely oldest photos leave first,
whatever storage template Immich uses.

**A whole folder at a time.** The tool finishes a folder, then checks whether the library
has reached TARGET. So a folder is never left half-archived, and a run may overshoot TARGET
slightly rather than stopping mid-folder.

**Sidecars follow their photo.** XMP and JSON files next to an asset are moved with it.

## What does not change in Immich

Nothing you can see. Archived photos keep:

- their place in the timeline, and their date — the file's timestamps are preserved;
- their albums, people, faces and metadata;
- their appearance in search.

Immich serves them from the external library instead of from its internal one. The only
database change is the asset's path and which library it belongs to.

## Trying it first

Always do this before turning anything on:

```bash
immich-auto-dumper test_run
```

It simulates a **forced** run plus a dump-mirroring run and changes nothing at all: no
copy, no deletion, no database write, and no journal.

What it tells you:

- which folders would be archived, and how much each would free;
- the total it would free;
- **whether any user is missing their external library in Immich** — the most common
  blocker, and the one you want to hear about now rather than later;
- whether an earlier run left work behind.

Every line it prints is prefixed `DRY-RUN:`, so nothing it says can be mistaken later for
work that happened.

Read it. If it matches what you expect, go on to [scheduling](scheduling.md).

## Running it by hand

```bash
immich-auto-dumper dump_now              # only if MAX or FREE says so
immich-auto-dumper dump_now --force      # ignore MAX, archive down to TARGET
immich-auto-dumper dump_now --dry-run    # simulate the above
```

`--force` still respects TARGET. It is the way to archive deliberately when you are simply
below MAX and want the space now.

A flag the tool does not recognise **stops the run**. `dump_now --force --dryrun` does not
archive: it refuses, because a misspelled safety flag must never start a real run.

Two runs can never overlap. If one is already in progress, the second exits quietly and
says which process holds the lock.

## The backup precondition

**Archiving refuses to start without an Immich database dump less than 7 days old**, in
Immich's own backup folder.

Archiving rewrites database rows, and a recent dump is what makes that recoverable. Enable
Immich's scheduled database backups — they are on by default — and this takes care of
itself.

The same rule covers **resuming** an unfinished run, which moves files and rewrites rows
exactly as a fresh archive does. And nothing is lost by waiting: an asset left half-moved
always has both a file and a database row pointing at each other.

The message names the folder it looked in. See [troubleshooting](troubleshooting.md).

## If a run is interrupted

Stop it, reboot mid-run, pull the storage out — each asset is left either **fully archived
or fully intact**, never in between. Every step is written down before it is taken, so the
next run picks up where this one stopped.

`status` shows anything outstanding. See [monitoring](monitoring.md) and
[the journal](../technical/journal.md).

## Exit codes

Useful if you watch cron output or wire up an alert:

| Code | Meaning |
|---|---|
| `0` | nothing to do, or everything done, and nothing needs your attention |
| non-zero | the run was refused, or it left something that needs a decision |

"Needs a decision" means an asset the tool has deliberately stopped touching — because
Immich disagrees with what the tool recorded, or because it failed five times. Those assets
are **not** damaged; they are parked. `status` counts them, and
[troubleshooting](troubleshooting.md) explains each case.

A run that finds nothing to do exits `0` and logs one line. It does not complain about a
missing dump on a night it had no work.

## What is in the log

`~/.local/state/immich-auto-dumper/immich-auto-dumper.log`, and `cron.log` beside it for
scheduled runs. Each archive run logs the Immich version it saw, the library size against
the thresholds, one line per candidate folder with what it actually freed, and a closing
`Archive complete. Freed: …` line — which is what `status` reads back as your last archive.

---

Next: [turning it on](scheduling.md) · or [database backups](database-backups.md).
