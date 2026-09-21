# External storage and file identity

How the tool decides the destination is really there, and how it decides two files are
really the same. Back to the [technical index](../TECHNICAL.md) · user-facing version:
[preparing the external storage](../guide/external-storage.md).

These two questions look separate and are not. Both answer the same thing — *is what I
think I wrote actually there, and can Immich see it?* — and both run into the same limit
on a write-back mount.

## Why a marker file

An inactive mount point is an **empty local directory**. Nothing distinguishes "the disk is
mounted and the folder is empty" from "the disk is not mounted" by looking at the path.

And nothing in Immich's configuration can help: a Docker bind mount attaches a **path**,
not a device. `- /mnt/external:/external_library` follows whatever happens to be at
`/mnt/external`, whatever that is, whenever it changes. So Immich never names or verifies a
volume, and neither can the tool by reading Immich.

Hence a marker written on the storage itself. It travels with the data, which also means
moving the storage to a new host path only requires re-running `setup`.

- `ARCHIVE_MARKER_NAME` = `.immich-auto-dumper.id`, at the root of `ARCHIVE_DEST_PATH`.
- Its content is a random UUID, also stored in `config.conf` as `ARCHIVE_STORAGE_ID`.
- `write_archive_marker()` (`lib/utils.sh`) writes it and reads it back, returning 1 when
  either fails — a read-only or inactive mount.

The check is therefore agnostic to the storage type: a local directory, an OS mount, a
FUSE/rclone mount, NFS, an intermittently-attached USB disk.

## The five verdicts

`_archive_dest_state()` (`lib/utils.sh`) reads the marker and follows the
[diagnostic convention](../TECHNICAL.md#the-diagnostic-convention). It sets
`_ARCHIVE_DEST_REASON` for callers that explain themselves, and echoes nothing.

| Situation | Code | Decision |
|---|---|---|
| Marker present, matching, and visible from the container | `0` | proceed |
| No marker at all — the storage is absent | `1` | end quietly, write nothing |
| The marker belongs to another volume | `1` | same: act on nothing |
| The read timed out, or the marker is present but unreadable | `2` | fault: refuse and report |
| Readable from the host but **not** from the Immich container | `2` | fault: refuse and report |

The read is bounded by `timeout 10`, because a dead FUSE or rclone mount **hangs** on read
rather than failing. `timeout`'s own exit code 124 is what tells a hang from a missing file.
The follow-up existence test is bounded too (`timeout 5`), for the same reason.

Two callers wrap it:

- `archive_dest_ready()` — the quiet form, for `status` and probes. Writes nothing.
- `check_archive_dest_ready()` — the same codes with the reason logged, for the operations
  that write. It never exits: what a `1` and a `2` mean is the caller's to decide.

### Why "wrong volume" is a 1 and not a code of its own

Both `1` answers mean the destination is not the one this configuration describes, and the
only safe response to either is to act on nothing — which is what a `1` already produces:
the run ends quietly, the lock is never taken, not a single file is touched.

Splitting them would buy a more precise label in `status` and nothing else, because the
action would stay identical. The real question a distinct code invites — *how does an
operator get out of this state without suspending the schedule?* — has no answer here, for
the bind-mount reason above. That is a piece of work of its own, not a return code.

### The host seeing the storage is not Immich seeing it

This is the row worth dwelling on, and it cost a real incident.

The host read the marker fine. `ls` on the host listed every file. Meanwhile the Immich
container answered `Transport endpoint is not connected`: the mount had been replaced
underneath the running container, and the container was still holding the old, dead one.
The tool reported itself green, archived nothing, and alerted nobody.

Worse, while the two diverge they can show **identical content** — as long as the old
process serving the container's mount is alive, both sides serve the same backend. No
comparison of content detects that phase. Only a file created on one side and looked for on
the other reveals the gap.

So when the host-side read succeeds, the marker is read **again from inside the
container**, and a mismatch is a `2`. The message names the remedy:
`docker restart <server container>`.

This is only asked when Docker answers at all — a Docker that is down is a fault of its
own, reported in its own right, and must not masquerade as a storage problem.

### Liveness at setup

`archive_dest_is_mounted()` is a separate, best-effort signal used by `setup` alone, to
decide whether to auto-create the marker: true when the path is backed by an active
non-root mount (a separate device, a network or FUSE filesystem), false when it resolves to
the root filesystem — a plain local folder, or a mount that is currently down.

`findmnt --target` is used rather than `mountpoint -q` because it also covers a mount at a
*parent* directory. When the answer is ambiguous the wizard asks rather than guesses, which
is what keeps the marker out of an empty mount point.

## File identity

Whenever the tool concludes that two files are "the same" it is **about to delete one of
them**, so the conclusion has to be earned.

**Size equality does not earn it.** A foreign file that happened to match the source byte
count was accepted as an already-archived copy, the database was pointed at it, and the
original photo was deleted in its favour. Only a matching SHA-256 earns it.

The cost is real — on a remote mount this reads the whole file back — and it is the price of
the guarantee. The alternative was measured, and it destroys photos.

| Function | Answers |
|---|---|
| `file_fingerprint()` | the SHA-256 of a file, or fails; **never an empty digest**, so a successful return can be trusted |
| `files_are_identical()` | `0` identical, `1` different, `2` undeterminable |
| `_refuse_if_occupied()` (`lib/archive.sh`) | `0` nothing there, `1` there and identical, `2` there and different — or uncomparable |

`files_are_identical()`'s third code is the whole point. The version it replaced compared
two `stat` calls that had **both failed**, read `0 == 0`, and concluded "identical".
Callers are expected to treat `2` as "touch nothing", never as a yes.

`_refuse_if_occupied()` guards both directions of a move — see
[archiving](archiving.md) and [rollback](rollback.md). Archiving had it and the rollback did
not: the rollback wrote over the library path with `cat >` without looking at what was
there.

## Flushing, and what it guarantees

`file_flush()` pushes a freshly written file out of the page cache **before** anything is
verified against it and, above all, before any source is deleted.

When `cp` returns, the data may only be in memory. A size check then reports the right
number — it is reading that same cache — so the copy looks complete and the source gets
deleted; a power cut in between leaves a truncated file and no original. `sync -d` flushes
just that file where it is supported, otherwise the whole filesystem: slower, never wrong.

On a local disk, a USB drive or a mounted NAS, **the file is on the medium when this
returns.**

### Write-back mounts

On a write-back mount — rclone with `--vfs-write-back`, async NFS — it is not, and this is a
documented constraint of use rather than a defect.

Measured behaviour: `cp -p`, then `sync -d`, then a **fingerprint read-back** all succeed
while the file has not yet reached the backend. The read is served by the local VFS cache,
which uploads some seconds later. Every check the tool can make passes, honestly, on a file
that is not there yet.

So on such a mount, **"archived" means "handed to the mount"**. The tool stops where rclone
takes over: rclone is a mature project that manages its own cache and its own local/remote
integrity, and it is not this tool's place to re-verify it. What the tool does guarantee is
that it never deletes a source before its own checks pass.

Two corollaries:

- **Never trust an mtime read from such a storage.** A file whose upload is still pending
  has no known modification time and the mount answers with a placeholder date far in the
  past. This is why the dump rotation and the journal retention both order **by name** —
  see [database backups](database-backups.md).
- The window is *narrowed*, not closed. On a local or USB target it is closed.

The journal makes a deliberately different trade: `_runlog_flush()` uses `sync -d` on the
journal file alone, **without** the fallback to a global `sync`. Losing a journal line costs
traceability, not a photo, and a global sync on a busy host would cost far more.

## Further

- [The archiving engine](archiving.md), which these primitives serve
- [Rollback](rollback.md), held to the same discipline in the other direction
- [Database backups](database-backups.md), and the mtime problem in full
- [Failure modes](failure-modes.md)
