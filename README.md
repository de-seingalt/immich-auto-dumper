<p align="center">
  <img src="docs/icon.svg" width="180" alt="immich-auto-dumper icon">
</p>

# immich-auto-dumper

**Your [Immich](https://immich.app/) disk is filling up. Your photos don't have to leave Immich.**

Every self-hosted Immich server has the same quiet problem: the photo library only ever
grows, and one day the disk is full. The usual fixes are painful — buy a bigger disk,
delete memories, or move files around by hand and break your timeline.

`immich-auto-dumper` gives you a third option: it quietly moves your **oldest** photos
and videos onto external storage — a NAS, a cloud drive mounted with rclone, a spare
disk — while Immich keeps showing them **exactly as before**. Same timeline, same
albums, same faces, same metadata. Nothing is deleted, nothing disappears; your photos
just live somewhere cheaper.

- 🗄️ **Set it and forget it** — pick a size limit; whenever the library grows past it,
  the oldest photos are moved until it's back under control.
- 🖼️ **Invisible in Immich** — archived photos stay fully browsable; they're served
  from their new location.
- 📦 **Database backups too** — Immich's own PostgreSQL dumps are mirrored to the same
  external storage, with retention.
- 🔒 **Careful by design** — every file is copied and verified before the original is
  removed; if the storage is unplugged or anything looks wrong, the run safely skips.
  No `sudo`, no Immich API key, no modification of your Immich install.

Curious how it works under the hood? Read the [technical documentation](docs/TECHNICAL.md).

---

## How to set it up

### What you need

- Linux with Immich deployed via **Docker Compose** (Ubuntu 22.04+ / Debian 12+ tested),
  and your user in the `docker` group.
- External storage **mounted on the host and into the Immich server container**, and
  registered in Immich as an **external library** — the setup wizard walks you through
  every step of this.
- Standard tools: `docker`, `bc`, `df`, `du` (all preinstalled on most systems).

### Step 1 — Install

```bash
curl -fsSL https://raw.githubusercontent.com/de-seingalt/immich-auto-dumper/main/install.sh | bash
```

This installs to `~/.local/share/immich-auto-dumper` and starts the setup wizard.
It also creates the `immich-auto-dumper` command in `~/.local/bin` (the wizard prints
the `PATH` line to add if needed). If the command isn't found afterwards, run:
`bash ~/.local/share/immich-auto-dumper/immich-auto-dumper.sh setup`

### Step 2 — Answer the wizard

```bash
immich-auto-dumper setup
```

The wizard detects your running Immich (containers, database, folders) and asks you to
**confirm** rather than type. You choose three things:

1. **Where to archive** — the external folder mounted into the Immich container.
2. **A folder name per user** on that storage (suggested automatically).
3. **Two sizes on a visual gauge**: the limit that triggers archiving (`MAX`) and the
   size the library shrinks back to (`TARGET`).

```
Immich library now: 142.3 GB (31%)  ·  disk used: 256 GB (56%)  ·  disk total: 460 GB  ·  free space: 204 GB
                                                  ▼
├▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒██████████░░░░░░░░░░░░░░░░░░░┄┄┄┄┄┤
                              ▲
▼ MAX = 200.00 GB   archiving STARTS when the library grows past this
▲ MIN = 150.00 GB   each run brings the library back DOWN to this
█ current library   ▒ other data   ░ headroom up to MAX   ┄ free
```

Sizes accept GB (`200`, `1.5G`), MB (`500M`) or percentages (`80%`). Everything is
saved to `config.conf` — re-run `setup` any time to change it.

If some of your users don't have their external library registered in Immich yet, the
wizard prints the exact path to add in **Administration → Libraries**. Do this before
the first dump.

### Step 3 — Do a blank run

```bash
immich-auto-dumper test_run
```

This simulates a full archiving run and prints exactly which files *would* move and
what *would* change — without touching anything. Read it, and if it matches what you
expect:

### Step 4 — Turn it on

```bash
immich-auto-dumper start
```

That's it. A cron job now checks your library daily at 02:00 and mirrors the DB backups
weekly. Check on it any time:

```bash
immich-auto-dumper status
```

---

## Commands at a glance

```
immich-auto-dumper <command> [--dry-run] [--force]
```

| Command | What it does |
|---|---|
| `setup` | Configuration wizard (safe to re-run any time). |
| `status` | Library size, storage readiness, backups, cron state, last runs. |
| `start` / `stop` | Enable / disable the scheduled runs. |
| `dump_now` | Archive now **if** the library exceeds `MAX`. |
| `dump_now --force` | Archive now regardless of `MAX`, down to `TARGET`. |
| `sync_now` | Mirror the DB backups to external storage now. |
| `test_run` | Full simulation — shows what would happen, changes nothing. |
| `uninstall` | Remove the tool (your photos, Immich and the storage are untouched). |

`--dry-run` can be added to `dump_now`/`sync_now` to preview a single operation.

## Good to know

- **Unplugged disk / dropped mount?** The run notices and skips — nothing is ever
  written into an empty mount point. It resumes when the storage is back.
- **A safety net is required**: archiving only runs if Immich produced a database
  backup in the last 7 days (enable Immich's scheduled backups — they're on by default).
- **After an Immich upgrade**, run `immich-auto-dumper test_run` once: if the new
  version changed its database layout, the tool refuses to run and tells you, rather
  than guessing.
- **Logs** live in `~/.local/state/immich-auto-dumper/`.

## Updating

Re-run the installer — it updates in place and asks what to do with your existing
configuration (keep it, reset it, or cancel). Non-interactive:
`~/.local/share/immich-auto-dumper/install.sh --yes`

## Uninstall

```bash
immich-auto-dumper uninstall      # add -y to skip the confirmation
```

Removes only the tool itself (command, install directory, cron entries, logs). Your
Immich install, database, and everything on the external storage — archived photos and
DB backups included — are left exactly as they are.
