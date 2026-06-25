# immich-auto-dumper

**Keep your [Immich](https://immich.app/) server's disk from filling up — automatically, safely, without losing a single photo.**

Self-hosted Immich stores every original photo and video on one disk. Over time that
library only grows. `immich-auto-dumper` gives you two hands-off backup policies:

- 📦 **Database backups** — mirrors the PostgreSQL dumps Immich already produces onto your
  external storage, with retention.
- 🗄️ **Photo archiving** — when the library grows past a size you choose, it moves the
  **oldest** photos onto external storage (a NAS, an rclone/NFS mount, a second disk…) and
  updates Immich so they stay fully browsable. Nothing is deleted, nothing is hidden from
  Immich, no metadata is lost.

It runs **strictly as your user, never `sudo`**, talks to Immich only through Docker and
the database, and treats Immich as the source of truth — it never rewrites the database to
"fix" a path behind Immich's back.

---

## How it works in one picture

Immich can read photos from an **external library** (a folder mounted into its container
that it scans alongside the main upload library). This tool moves your oldest assets into
that external library and points Immich's `originalPath` at the new location — so from
Immich's side, the photo simply lives somewhere else now.

```
                 disk fills up
   ┌─────────────────────────────────┐
   │  Immich UPLOAD_LOCATION/library  │   ← internal library (precious, fast disk)
   └─────────────────────────────────┘
                 │  oldest photos moved when library > MAX,
                 │  down to TARGET — DB updated atomically
                 ▼
   ┌─────────────────────────────────┐
   │     External storage            │   ← NAS / rclone / NFS / spare disk
   │  .immich-backup/   (DB dumps)   │
   │  Alice/ 2021/… 2022/…           │   ← archived photos, still live in Immich
   │  Bob/   2020/…                  │
   └─────────────────────────────────┘
```

---

## Requirements

- Linux with Immich deployed via **Docker Compose** (Ubuntu 22.04+/Debian 12+ tested).
- External storage **mounted on the host and into the Immich server container**, and
  registered in Immich as an **external library** (the wizard guides you).
- Runtime tools: `docker`, `bc`, `df`, `du`. `psql` runs inside Immich's Postgres
  container. No `sudo`, no Immich API key.
- Optional: `whiptail` (present on most Debian/Ubuntu) gives the wizard native dialogs;
  without it you get equivalent colored text prompts.
- `curl` is only used by the one-line installer below.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/de-seingalt/immich-auto-dumper/main/install.sh | bash
```

Installs to `~/.local/share/immich-auto-dumper` from the latest `main`, then launches the
setup wizard. The wizard creates the `~/.local/bin/immich-auto-dumper` symlink (and prints
the `PATH` line to add if `~/.local/bin` isn't on your `PATH`). Pick another directory with
`INSTALL_DIR=…`.

**Updating** — re-run the installer; it detects the existing copy and asks what to do with
your config: update keeping `config.conf`, update and reset it (your old one is saved to
`config.conf.bak`), or cancel. Either way it force-syncs to the latest `main`
(`git reset --hard`); gitignored logs are kept. A directory whose files were copied in by
hand (not a git checkout) is adopted into git first. Non-interactive (updates, keeps
config): `~/.local/share/immich-auto-dumper/install.sh --yes`.

## Configure

```bash
immich-auto-dumper setup
```

The wizard is **detection-first** — it inspects your running containers and database and
asks you to *confirm*, not to look up:

- Immich server & Postgres containers, DB name/user, the upload location, and the
  `originalPath` prefix — all auto-detected.
- The **external folder** mounted into the server container (read from the Docker config)
  to archive into.
- **Per-user destination folders.** For each Immich user it suggests a folder name,
  **pre-filled from that user's existing external library** when one already points into
  the archive path. It then **creates the folders** on the storage if missing (an Immich
  external library can only point at a path that exists) and prints the exact
  container path to register for any user that still needs it.
- **The size boundaries**, set together on a visual disk gauge:

```
Immich library now: 142.3 GB (31%)  ·  disk used: 256 GB (56%)  ·  disk total: 460 GB  ·  free space: 204 GB
                                                  ▼
├▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒██████████░░░░░░░░░░░░░░░░░░░┄┄┄┄┄┤
                              ▲
▼ MAX = 200.00 GB   archiving STARTS when the library grows past this
▲ MIN = 150.00 GB   each run brings the library back DOWN to this
█ current library   ▒ other data   ░ headroom up to MAX   ┄ free
```

Sizes accept whole or fractional **GB** (`200`, `1.5G`), **MB** (`500M`) or a **percentage**:
`MAX` as a percentage is taken on the **whole disk** (`80%`); `MIN` as a percentage is taken
on **MAX** (`75%` = three-quarters of MAX). `MAX` is capped at the space the library can
ever use (free disk + current library) — a larger value is rejected, since the disk would
fill before archiving could trigger.

Values are written to `config.conf` (gitignored). Re-run `setup` any time to update them;
see `config.conf.example` for the full structure.

## Commands

```
immich-auto-dumper <command> [--dry-run] [--force]
```

| Command | What it does |
|---|---|
| `setup` | Interactive configuration wizard (creates or updates `config.conf`). |
| `status` | Library size, disk space, external-storage readiness, path consistency, backups, cron, last runs. |
| `start` | Enable the cron jobs (daily archiving, weekly DB-backup copy). |
| `stop` | Disable the cron jobs and wait for any running operation to finish. |
| `dump_now` | Archive **if** the library exceeds `MAX`, down to `TARGET`. This is what the cron runs. |
| `dump_now --force` | Manual dump: **ignore `MAX`** and archive down to `TARGET` now. |
| `sync_now` | Copy the Immich DB dumps to external storage now. |
| `test_run` | **Verbose dry run** of a forced dump + backup sync — shows exactly what would move, changes nothing. |
| `uninstall` | Remove the tool's local footprint (keeps Immich and the external storage intact). |

**Flags** — `--dry-run` suppresses every destructive operation (`cp`, `rm`, DB `UPDATE`);
`--force` is the manual override for `dump_now` described above.

## External storage & availability

```
/mnt/external/
  .immich-auto-dumper.id   ← storage marker (proves the right storage is mounted)
  .immich-backup/          ← DB dumps (mirror of UPLOAD_LOCATION/backups/)
  Alice/ 2022/06/…         ← archived photos, per user — still live Immich assets
  Bob/   2023/04/…
```

The storage can be **any** kind Immich treats as an external library — a local folder, an
OS mount, an rclone/FUSE/NFS mount, or a removable disk. The tool is agnostic: at `setup`
it writes a marker (`.immich-auto-dumper.id`) **on the storage itself** and checks it before
every run.

- Storage **not available** (disk unplugged, mount dropped)? The run is **skipped without
  writing anything** and resumes next time — nothing is ever copied into an empty mount point.
- **Moved** the external library to a new host path? Just re-run `setup`: the marker travels
  with the data and is recognized (or re-created for a new target).
- The library path changed **inside Immich** (container side)? The tool detects the
  mismatch, **pauses the cron jobs**, and asks you to fix it in Immich and re-run `setup`.
  It never rewrites Immich's database.

## What makes archiving safe

Archiving is driven by the **measured size of `UPLOAD_LOCATION/library`** (`du`) — unrelated
data on the same filesystem never affects it. The unit is each asset's **immediate parent
directory**, whatever your Immich storage template is; a directory is never left
half-archived. Before any database change, a recent (< 7 days) Immich DB backup must exist
in `UPLOAD_LOCATION/backups/`, or the run aborts.

For every file moved:

1. Copy to external storage.
2. Verify the destination file exists.
3. Update `originalPath` in the database (transaction).
4. Verify the file is reachable from the Immich server container.
5. Delete the source **through the Immich server container** — the library files are owned
   by the container's user, so deletion is delegated to it instead of using `sudo`.

If any step fails, the database is rolled back and the destination copy removed; the source
stays intact. Because `originalPath` is updated *before* the source is deleted, Immich finds
each file at its new path on its next scheduled library scan — no rescan is triggered, no
Immich API call is made, no metadata is lost. XMP/JSON sidecars are moved alongside their
asset.

## Logs

```
~/.local/state/immich-auto-dumper/immich-auto-dumper.log   # operations
~/.local/state/immich-auto-dumper/cron.log                 # cron output
```

Honors `$XDG_STATE_HOME`; override with `LOG_DIR` in `config.conf`. Must be writable by the
user running the tool (no `sudo`).

## Uninstall

```bash
immich-auto-dumper uninstall      # add -y to skip the confirmation
```

Removes **only** the local footprint: the `~/.local/bin` symlink, the install directory
(including `config.conf`), the cron entries, the logs and the lock file. It **never** touches
Immich (database, assets, containers) or anything on the external storage — the marker, the
`.immich-backup/` dumps and the archived photos all remain, because those archived files are
live Immich assets. For the same reason it's safe to run with the external library offline.
Reinstall any time with the one-line installer.
