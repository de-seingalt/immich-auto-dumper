# immich-auto-dumper — user guide

Everything you need to install the tool, set it up and live with it. For what happens
inside, see the [technical documentation](TECHNICAL.md).

## What this does

Your Immich library only grows. This tool moves your **oldest** photos and videos onto
external storage — a NAS, a spare disk, a cloud drive mounted with rclone — and points
Immich at their new location, so they stay in your timeline, your albums and your search
results exactly as before.

Nothing is deleted. Every file is copied and verified before the original is removed, and
one archive run can be undone.

## First run, in order

Follow these in sequence. Each page ends by pointing at the next one.

| | Step | Page |
|---|---|---|
| 1 | Install the tool | [installation](guide/installation.md) |
| 2 | **Prepare the external storage** and register it in Immich | [external storage](guide/external-storage.md) |
| 3 | Answer the setup wizard | [configuration](guide/configuration.md) |
| 4 | Do a blank run and read it | [archiving](guide/archiving.md#trying-it-first) |
| 5 | Turn on the scheduled jobs | [scheduling](guide/scheduling.md) |
| 6 | Check on it | [monitoring](guide/monitoring.md) |

**Step 2 is the one people skip**, and skipping it is the single most common reason the tool
does nothing useful. The external storage has to be mounted *and* registered in Immich as an
external library, per user. The wizard tells you what is missing, but it cannot do that part
for you.

## Once it runs

- **Check on it** — [`status`](guide/monitoring.md) in one command: library size, storage,
  the last run, and anything left unfinished.
- **Undo an archive run** — [`rollback`](guide/undoing-a-run.md) brings one run's files back
  into the library.
- **Keep the database dumps mirrored** — [`sync_now`](guide/database-backups.md), which the
  schedule already does weekly.
- **Update the tool** — [re-run the installer](guide/installation.md#updating); it asks what
  to do with your configuration.

## When something looks wrong

Start with [troubleshooting](guide/troubleshooting.md): it is organised by the message you
actually saw.

Two habits worth having:

- **After every Immich upgrade, run `immich-auto-dumper test_run`.** It changes nothing and
  tells you immediately if Immich's database no longer matches what the tool expects.
- **"not verified" is not "OK".** When `status` says a check could not be made, nothing was
  learned — read that line as a question, not as good news.

## Commands

```
immich-auto-dumper <command> [--dry-run] [--force]
```

| Command | What it does | More |
|---|---|---|
| `setup` | Configuration wizard. Safe to re-run at any time; opens on a review of what you already have. | [configuration](guide/configuration.md) |
| `status` | Library size, storage readiness, checks, backups, schedule, last runs, unfinished work. Writes nothing. | [monitoring](guide/monitoring.md) |
| `start` | Install the scheduled jobs. | [scheduling](guide/scheduling.md) |
| `stop` | Disable them, and wait for any running operation to finish. | [scheduling](guide/scheduling.md) |
| `dump_now` | Archive **if** the library exceeds `MAX` or free disk drops below `FREE`. | [archiving](guide/archiving.md) |
| `dump_now --force` | Archive regardless of `MAX`, down to `TARGET`. | [archiving](guide/archiving.md) |
| `sync_now` | Mirror Immich's database dumps to the external storage. | [database backups](guide/database-backups.md) |
| `test_run` | Full simulation of a forced dump plus a mirroring run. Changes nothing. | [archiving](guide/archiving.md#trying-it-first) |
| `rollback <run-id>` | Undo one identified archive run. | [undoing a run](guide/undoing-a-run.md) |
| `uninstall` | Remove the tool. Immich, your photos and the external storage are untouched. | [installation](guide/installation.md#uninstalling) |

**Flags.** `--dry-run` suppresses every copy, deletion and database write; it can be added
to `dump_now` and `sync_now`. `--force` is the manual override for `dump_now` described
above. A flag the tool does not recognise **stops the run** rather than being ignored —
which is what you want from a misspelled `--dry-run`.

`uninstall` also accepts `-y` to skip its confirmation.
