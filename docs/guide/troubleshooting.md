# Troubleshooting

Organised by what you saw. Back to the [user guide](../GUIDE.md). For the full
event-by-event behaviour, see
[failure modes](../technical/failure-modes.md).

Two rules that answer a lot of questions before you get to the list:

- **Nothing is ever deleted before its copy is verified.** When the tool is unsure, it stops
  and keeps both sides. An asset it complains about is parked, not damaged.
- **"not verified" is not "OK".** A check that could not be made taught you nothing.

## Installation

### `immich-auto-dumper: command not found`

`~/.local/bin` is not on your `PATH`:

```bash
echo 'export PATH="${HOME}/.local/bin:${PATH}"' >> ~/.bashrc && source ~/.bashrc
```

Meanwhile: `bash ~/.local/share/immich-auto-dumper/immich-auto-dumper.sh status`.

### `Cannot run docker as 'you'. This tool runs without sudo on purpose.`

Your user needs direct Docker access:

```bash
sudo usermod -aG docker "$USER"
```

Then **log out and back in** — group membership does not apply to your current session.

If the message instead says you *are* in the `docker` group, either the daemon is not
running (`systemctl status docker`) or you joined the group during this session.

### `Missing dependencies: sha256sum`

Install it (it is in `coreutils` on most systems). The tool checks for `bc` and `sha256sum`
explicitly, because it refuses to decide two files are identical without a checksum.

## Storage

### `External storage not ready: marker '…' is missing`

The storage is not mounted, or not mounted where the configuration expects it.

For a removable or remote disk this is **normal** — the run skips and writes nothing. Plug
it back in and the next run continues.

If it should be there: check the host mount, then check the marker file exists at the root
of the storage. Do not recreate it by hand; re-run `setup`, which recognises the situation.

### `readable from this host but NOT from the Immich container`

The mount was **replaced underneath the running container**. The host sees the new one, the
container is still holding the old, dead one.

```bash
docker restart immich_server
```

Then `immich-auto-dumper status` to confirm. This is the case the marker exists to catch; it
is invisible to any check that only looks from the host, and the two sides can even show
identical content while they have already diverged.

If it keeps happening, make sure the mount comes up **before** the Immich containers do.

### `marker id does not match ARCHIVE_STORAGE_ID — wrong volume mounted?`

Something else is mounted at that path. The tool refuses to write into it, which is the
point.

Mount the right storage. If you deliberately moved to a new disk, re-run `setup` — it finds
the marker conflict and asks whether to adopt the id already on the storage or keep the one
in your config.

### `marker '…' exists but cannot be read` / `reading '…' timed out after 10s`

A failing or hanging mount, or a permissions problem. Unlike a missing marker this is
treated as a **fault**: the run refuses and exits non-zero rather than quietly skipping.

Check the mount by hand (`ls`, `stat` on the marker). For a FUSE or rclone mount, remount
it.

## Archiving

### `No recent, usable DB backup (<7 days) in …/backups`

Archiving will not rewrite database rows without a recent dump to fall back on.

Enable Immich's scheduled database backups (**Administration → Settings → Backup**); they
are on by default. Then check the folder actually has one — the tool wants a real dump, not
Immich's tiny `.immich` marker file, so a folder that looks non-empty may still have no
usable dump in it.

This also blocks **resuming** an unfinished run, on purpose: resuming moves files and
rewrites rows just like a fresh archive.

### `Schema check FAILED — Immich DB schema may have changed`

An Immich upgrade changed its database layout, and the tool refuses to touch it.

1. `immich-auto-dumper stop`, so nothing runs overnight.
2. Check whether your Immich version is one this tool has been exercised against:
   [Immich versions](../technical/history.md#immich-versions-exercised).
3. Do not archive until it is resolved.

Nothing is broken and nothing is lost — the tool stopped before doing anything.

### `Path inconsistency detected` and the cron went quiet

The tool disabled the schedule on its own, because Immich's paths no longer match your
configuration. That is deliberate. See
[when the tool disables the schedule itself](scheduling.md#when-the-tool-disables-the-schedule-itself).

### `Assets Immich has both marked offline and trashed are how a mass loss starts: do NOT empty the trash`

Take this one literally.

Immich has concluded that archived files are gone and has moved those assets to its trash.
They are not gone — the path stopped matching, or the storage was unreadable when Immich
scanned.

1. **Do not empty the trash.** Emptying it makes the loss permanent.
2. Make the storage reachable again, and check the container can see it
   (`docker exec immich_server ls /external_library`).
3. Fix the external library path in Immich if it changed.
4. Restore the assets from Immich's trash.
5. `immich-auto-dumper status` to confirm the path consistency line is `OK` again.

### `N asset(s) ended this run blocked or divergent — each one needs a decision`

The run finished, but parked some assets rather than guessing about them.

- **blocked** — five attempts failed. Almost always a folder collision (below) or a missing
  external library.
- **divergent** — Immich disagrees with what the tool recorded for that asset: it was moved,
  deleted, or the tool could not finish a step cleanly.

`status` counts them and names the journal directory. **The assets are intact**: each has a
file and a database row pointing at each other. Once you have dealt with the cause, delete
that run file to clear the entry.

### `Destination exists with DIFFERENT content` / `Another file already occupies that path`

Two users are mapped to the same folder, so one relative path names two different photos.

```bash
immich-auto-dumper setup
```

The review screen reports it explicitly (*"USER_MAP sends two users to the same folder"*).
Give each user their own folder. The tool refused the asset rather than overwriting it, so
nothing was lost.

### `No external library in Immich covers … for this asset's owner`

The step from [preparing the external storage](external-storage.md#registering-the-external-library-in-immich).

That user has no Immich external library pointing at their archive folder, so an archived
photo would be re-imported as a duplicate at the next scan. Add it in **Administration →
Libraries** with the container path the message names, and assign it to that user.

`test_run` reports this in advance, which is why it is worth running after every
configuration change.

### `Asset … is not under …/library/<user folder>/ — skipped`

An asset lives somewhere the tool cannot build a destination for — outside the per-user
folder structure. It is skipped and untouched. This is unusual; it normally means Immich's
storage template or library prefix changed.

### `Another operation is already running (PID …)`

Exactly what it says. Two runs must never overlap, so the second exits quietly.

`status` shows the lock and its PID. A `stale` lock means a previous run died; the next run
clears it by itself.

## Configuration

### `config.conf:12 — ARCHIVE_LIBRARY_MAX_MB must be a whole number of 1 or more (found 'abc')`

A hand edit the tool cannot use. The message gives the **line number** and what it expected.

Fix that line, or run `immich-auto-dumper setup` and let the wizard rewrite the file. Until
then, only `setup` and `uninstall` will run — every other command refuses rather than act on
half a configuration.

### `Error: config.conf not found`

Run `immich-auto-dumper setup`.

### `library cannot reach its 200.00 GB max before the disk fills`

MAX is now higher than what the disk can actually give the library (free space plus the
library's current size), usually because other data grew.

- With the free-disk safety net on, it will still catch a filling disk.
- Without it, automatic archiving may **never trigger**. Run `setup` and lower MAX, or turn
  the safety net on.

### `BACKUP_RETENTION must be a whole number of dumps to keep, 1 or more`

`sync_now` refuses the entire run — it copies and deletes nothing — because a retention of
zero would delete every mirrored dump. Fix it with `setup`.

## In Immich

### Archived photos no longer appear in Immich

Check in this order:

1. **Is the storage mounted on the host?** `ls /mnt/external`
2. **Can the container see it?**
   `docker exec immich_server ls /external_library` — if this fails while step 1 worked,
   restart the container.
3. **Is the external library still registered in Immich**, with the right import path and
   owner?
4. `immich-auto-dumper status` — the path-consistency line will usually name the problem.

If Immich has moved those assets to its trash, read
[the trash warning](#assets-immich-has-both-marked-offline-and-trashed-are-how-a-mass-loss-starts-do-not-empty-the-trash)
before doing anything else.

### Duplicate photos appeared after archiving

Archived assets were not adopted into an external library, so Immich's scan imported the
files as new assets.

That means archiving ran without a library covering the destination — which current versions
refuse to do. Add the library (step 3 above), then remove the duplicate assets Immich
created, keeping the original ones.

### Immich shows old dates on archived photos

It should not: file timestamps are preserved when a photo is copied, and Immich's own dates
come from the database, which the tool does not change apart from the path.

If you see this, check whether something else — a sync tool, a backup restore — rewrote the
files on the storage.

## Still stuck

- The log: `~/.local/state/immich-auto-dumper/immich-auto-dumper.log`
- Scheduled runs: `cron.log` beside it
- What a run actually did, step by step:
  `~/.local/state/immich-auto-dumper/runs/` — one JSON record per line
- `immich-auto-dumper test_run` changes nothing and often says plainly what is wrong

---

Back to the [user guide](../GUIDE.md) ·
[failure modes in full](../technical/failure-modes.md).
