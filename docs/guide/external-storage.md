# Preparing the external storage

The step that has to be right before anything else works. Back to the
[user guide](../GUIDE.md) · previous: [installation](installation.md) · next:
[configuration](configuration.md).

## What the tool needs

Two things, and **both** of them:

1. The storage is **mounted on the host and into the Immich server container**.
2. It is **registered in Immich as an external library**, with one import path per user,
   assigned to that user.

The first lets the tool write there. The second is what makes Immich keep showing the
photos after they move. With only the first, archived photos disappear from Immich's
timeline and get re-imported as duplicates at the next library scan.

The wizard checks and reports on both, but it can only do the first for you.

## Mounting it

Add a bind mount to your Immich `docker-compose.yml`, on the `immich-server` service:

```yaml
services:
  immich-server:
    volumes:
      - ${UPLOAD_LOCATION}:/data
      - /mnt/external:/external_library      # ← the storage
```

Then recreate the container (`docker compose up -d`). Here `/mnt/external` is the path on
your machine and `/external_library` is the path Immich sees; both appear in your
configuration, as `ARCHIVE_DEST_PATH` and `ARCHIVE_CONTAINER_PATH`.

A few notes:

- **`:ro` is allowed.** A read-only mount stops *Immich* from writing to the library, which
  many people want. It does not stop this tool, which writes through the host filesystem
  rather than through Docker. The wizard therefore does not filter on it.
- **Your user must be able to write to the host path.** That is verified during setup, when
  the storage marker is written.
- **Any storage type works**: a local folder, a second disk, a USB drive, a NAS over NFS or
  SMB, a cloud drive mounted with rclone. Read
  [removable and remote storage](#removable-and-remote-storage) below if it is not always
  connected.

## Registering the external library in Immich

**This is the step people skip.** In Immich: **Administration → Libraries → Create
library**, then for each user:

1. Choose **External library** and set its **owner** to that user.
2. Add an **import path** pointing inside the mount, one folder per user — for example
   `/external_library/Alice` for Alice.
3. Save.

Use the *container* path (`/external_library/…`), because that is what Immich sees.

The folder name you use here is the same one you will give the wizard for that user, and
the wizard reads your import paths to pre-fill it. If you set the libraries up first, the
wizard mostly fills itself in.

If some users have no library yet, the wizard prints the exact path to add for each of them
at the end of setup. **Do that before the first real dump.** Until then, archiving refuses
those users' photos rather than moving them — which is the right outcome, since moving them
without a library would create duplicates.

### Why it matters this much

When the tool moves a photo, it rewrites the asset's path and **adopts** the asset into the
external library whose import path covers the new location. That adoption is what makes
Immich's periodic library scan recognise the file as an asset it already knows, instead of
importing it again as a new one.

With no library covering the destination, the tool undoes its own database change and skips
the asset. It will not archive into a location Immich does not know about. See
[the one write](../TECHNICAL.md#the-one-write).

## The storage marker

The first time you run `setup`, the tool writes a small file at the root of the storage:

```
/mnt/external/.immich-auto-dumper.id
```

It contains a random identifier, also saved in your configuration. Before every run, the
tool reads it back — and reads it **again from inside the Immich container**.

That is how it tells "the storage is there" from "the mount point is an empty folder",
which look identical otherwise. It is also how it catches the nastier case: the host can
see the storage perfectly while the container is holding a dead mount. When that happens
the tool refuses to run and tells you to restart the Immich server container.

**Do not delete the marker**, and do not copy it onto a different disk. If it is missing,
the tool assumes the storage is not connected and does nothing. If it holds a different
identifier, the tool assumes this is not your storage and does nothing.

**The marker travels with the data**, which is a feature: if you move the storage to a
different path or a different machine, just re-run `setup`. It recognises the marker and
updates the path.

## Removable and remote storage

A storage that is simply not there is a **normal state**, not an error. The run ends
quietly, writes nothing, and picks up next time. You can unplug a USB disk between runs.

Two things to know if your storage is a cloud mount (rclone, and similar):

- **Register the mount before Immich starts**, and make sure it comes back before the
  container does. A mount replaced underneath a running container leaves the container on
  the old, dead one — the tool detects this and refuses to run, but a restart of
  `immich_server` is what fixes it.
- **"Archived" means "handed to the mount".** On a write-back mount, the file may still be
  uploading when the tool considers it written; every check it can make passes, honestly,
  on a file the remote does not have yet. The tool stops where rclone's job begins — see
  [write-back mounts](../technical/external-storage.md#write-back-mounts) for exactly what
  is and is not guaranteed.

## How much space

The tool moves data off your Immich disk onto this one, so plan for the difference between
your current library size and the `TARGET` you will choose, plus room to grow. `status`
reports both numbers once you are configured.

The database dumps are mirrored here too, in `.immich-backup/`, and you choose how many to
keep — see [database backups](database-backups.md).

## Checking it worked

After setup, `immich-auto-dumper status` should say:

```
External storage     : ready  (/mnt/external)
Path consistency     : OK
```

Anything else is covered in [troubleshooting](troubleshooting.md).

---

Next: [answering the setup wizard](configuration.md).
