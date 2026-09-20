<img src="docs/icon.svg" width="180" alt="immich-auto-dumper icon" align="left">
<br><br><br><br>

# immich-auto-dumper

**Your [Immich](https://immich.app/) server disk is filling up ? Your photos don't have to leave Immich.**

Your self-hosted Immich server has probably a limited disk space: the photo library only ever
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
  No `sudo`, no changes to your Immich installation or its configuration.

> ### ⚠️ This tool writes directly to Immich's database
>
> Immich's API cannot relocate a file, so `immich-auto-dumper` talks to Immich's
> PostgreSQL database directly: it reads your users, libraries and assets, and for each
> asset it moves it updates that asset's path and the library it belongs to. It changes
> nothing else in the database, and no Immich API key is involved.
>
> This is a deliberate trade-off you should be aware of before installing: **an Immich
> upgrade that changes the database schema can break the tool.** Two safeguards limit
> the damage — every run first checks that the columns it relies on still exist and
> aborts if they don't, and it refuses to archive unless a database dump less than
> 7 days old is present. After upgrading Immich, run `immich-auto-dumper test_run`
> (which changes nothing) before letting it run again.

Curious how it works under the hood? Read the [technical documentation](docs/TECHNICAL.md).

---

## How to set it up

### What you need

- Linux with Immich deployed via **Docker Compose** (Ubuntu 22.04+ / Debian 12+ tested),
  and your user in the `docker` group.
- **A tested Immich version.** Because the tool talks to Immich's database directly, it is
  verified against specific releases rather than assumed to work with any of them:

  | Immich | Status |
  |---|---|
  | **v3.2.0** | Tested end to end (September 2026) — schema check, archiving, library adoption, DB-dump mirroring. |
  | **v2.7.5** | Tested end to end. |

  Versions in between are expected to work — no schema change affecting the columns the
  tool relies on was introduced — but have not been exercised. Whatever your version,
  run `immich-auto-dumper test_run` after every Immich upgrade before re-enabling the
  scheduled jobs; it changes nothing and tells you immediately if the database no longer
  matches what the tool expects.
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
**confirm** rather than type. You choose:

1. **Where to archive** — the external folder mounted into the Immich container.
2. **Two sizes on a visual gauge**: the limit that triggers archiving (`MAX`) and the
   size the library shrinks back to (`TARGET`).
3. **A free-disk safety net** (`FREE`): archiving also triggers if total free disk
   space drops below this, even while the library is still under `MAX` — protection
   against other things on the same disk (the database, Docker, logs...) filling it
   up before the library ever gets the chance. On by default, sized from your disk;
   enter `0` to disable it.
4. **How many database dumps to keep** on the external storage. Immich rotates the
   dumps it writes locally; this tool rotates its own copies. The wizard reads
   Immich's own number and suggests it, so mirroring never drops a dump Immich
   still has.
5. **A folder name per user** on that storage (suggested automatically, from the
   import path Immich already uses for that user when there is one).

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

**Re-running `setup` later never makes you redo everything.** With a config already in
place it opens on a review instead of the questionnaire: it shows your saved settings,
checks them against the current version of the tool and your live Immich (containers
still there, folders still there, every Immich user still mapped, paths still matching),
tells you whether the scheduled jobs are running right now, and only then offers to
reconfigure. Settings added by a newer version of the tool can be appended with their
defaults without touching anything else.

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
| `dump_now` | Archive now **if** the library exceeds `MAX` or free disk drops below `FREE`. |
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
