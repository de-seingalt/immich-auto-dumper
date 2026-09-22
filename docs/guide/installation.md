# Installing, updating, uninstalling

Back to the [user guide](../GUIDE.md). Next step: [external storage](external-storage.md).

## What you need

- **Linux with Immich deployed via Docker Compose** (Ubuntu 22.04+ / Debian 12+ exercised),
  and your user in the `docker` group. The tool never uses `sudo`; if it cannot reach the
  Docker daemon directly it tells you how to fix that and stops.
- **A tested Immich version.** Because the tool talks to Immich's database directly, it is
  verified against specific releases: see
  [Immich versions exercised](../technical/history.md#immich-versions-exercised).
- **External storage**, mounted on the host *and* into the Immich server container, and
  registered in Immich as an **external library**. This is the next page, and the tool
  cannot do it for you.
- **Standard tools**: `docker`, `bc`, `sha256sum`, `df`, `du`, `crontab`. All are
  preinstalled on most systems. Pre-flight checks for `bc` and `sha256sum` explicitly and
  names them if they are missing.

`whiptail` is optional. With it, the wizard draws dialog boxes; without it, the same
questions are asked as plain text.

## Installing

```bash
curl -fsSL https://raw.githubusercontent.com/de-seingalt/immich-auto-dumper/main/install.sh | bash
```

This clones the tool into `~/.local/share/immich-auto-dumper` and launches the setup
wizard. It also creates the `immich-auto-dumper` command in `~/.local/bin`.

If that directory is not on your `PATH`, the wizard prints the line to add:

```bash
echo 'export PATH="${HOME}/.local/bin:${PATH}"' >> ~/.bashrc && source ~/.bashrc
```

Until then you can still run it by full path:

```bash
bash ~/.local/share/immich-auto-dumper/immich-auto-dumper.sh setup
```

Nothing is installed system-wide, and nothing runs as root.

## Updating

Re-run the installer. It updates in place and asks what to do with your configuration:

```bash
~/.local/share/immich-auto-dumper/install.sh
```

| Choice | Effect |
|---|---|
| **Update, keep my config.conf** (default) | the code is brought up to date, your settings are untouched |
| **Update and reset config.conf** | your config is copied to `config.conf.bak` and removed, so the wizard builds a fresh one |
| **Cancel** | nothing changes |

Non-interactively — for a script or a cron job — `--yes` takes the config-preserving
update and skips the wizard:

```bash
~/.local/share/immich-auto-dumper/install.sh --yes
```

Your `config.conf` and your logs are never touched by a plain update.

**If you patched the tool yourself**, the installer lists the modified files before
discarding them and asks whether to continue. Under `--yes`, or with no terminal to answer,
it lists them and proceeds — so check that list if you keep local changes.

After updating, it is worth running `immich-auto-dumper setup` once: it opens on a
[review of your configuration](configuration.md#re-running-setup-later) and offers to add
any settings the new version introduced.

## Uninstalling

```bash
immich-auto-dumper uninstall        # add -y to skip the confirmation
```

It prints exactly what it is about to remove and waits for you to confirm.

**What goes:**

- the `~/.local/bin/immich-auto-dumper` symlink — only if it actually points into the
  install directory;
- the install directory, which holds `config.conf`;
- the crontab lines;
- the log directory, and the lock inside it.

**What stays, untouched:**

- Immich itself — its database, its assets, its containers, its configuration;
- everything on the external storage: the `.immich-auto-dumper.id` marker, the
  `.immich-backup/` dumps, and **every archived photo**.

That last point is the important one. Your archived photos are **live Immich assets**
served from the external library. Removing this tool does not orphan them, and Immich keeps
displaying them exactly as before. The tool simply stops moving new ones.

The external storage may even be offline while you uninstall: nothing there is read or
written.

If you want to bring archived photos back into the internal library first, do that
**before** uninstalling — see [undoing an archive run](undoing-a-run.md), which needs the
tool and its journals.

## Where things live

| | Path |
|---|---|
| The tool | `~/.local/share/immich-auto-dumper/` |
| The command | `~/.local/bin/immich-auto-dumper` |
| Your settings | `~/.local/share/immich-auto-dumper/config.conf` |
| Logs | `~/.local/state/immich-auto-dumper/` |
| Run journals | `~/.local/state/immich-auto-dumper/runs/` |
| Cron output | `~/.local/state/immich-auto-dumper/cron.log` |

`config.conf` is editable by hand. It is read as plain data and never executed, so nothing
in it can run, and comments belong on their own line — see
[the settings reference](../technical/configuration.md).

---

Next: [preparing the external storage](external-storage.md).
