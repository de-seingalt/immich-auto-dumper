# Failure modes

What the tool does when something goes wrong. Back to the
[technical index](../TECHNICAL.md) · symptom-first version:
[troubleshooting](../guide/troubleshooting.md).

Read this alongside [the diagnostic convention](../TECHNICAL.md#the-diagnostic-convention):
most of the rows below differ from each other only in whether the situation is a legitimate
negative (`1` — act on nothing, exit 0) or an unverifiable one (`2` — refuse and report,
exit non-zero).

## Storage

| Event | Behaviour |
|---|---|
| Storage unplugged, mount down, marker missing | Run ends quietly (`1`), nothing written, the lock is never taken; resumes next time |
| Wrong disk mounted at the path (marker id mismatch) | Run ends quietly (`1`): the destination is not the one this config describes |
| Mount hangs on read | `timeout` fires, `2`, run refused and reported |
| Marker present but unreadable | `2`, run refused and reported |
| Storage visible to the host but **not** to the Immich container | `2`, run refused; the message names `docker restart <server container>` |
| Destination path does not exist on this host at all | reported as a config **problem** by the setup review, not as absent storage |
| Storage is read-only when the marker is written at setup | `setup` says the marker was not created and that archiving stays paused |

## Copying and deleting

| Event | Behaviour |
|---|---|
| Partial copy (disk full, I/O error, dying mount) | Fingerprint mismatch: the partial file is removed on the side it was written, the asset is skipped, the other copy is intact |
| Destination occupied by a **different** file | Asset skipped, source kept. Usually two users in one `USER_MAP` folder, and the log says so |
| Destination occupied by an **identical** file | Copy skipped, database updated only |
| Destination cannot be read to compare | Treated as the "different" case: skipped, nothing touched |
| Source changed since it was fingerprinted | Source **kept**, nothing removed |
| Source cannot be removed through the container | Entry stays `base_a_jour`; the archive succeeded, only the cleanup is outstanding |
| Sidecar cannot be read or copied | Sidecar's source kept, a warning; the asset itself is unaffected |

## Database

| Event | Behaviour |
|---|---|
| Immich schema changed by an upgrade | Every run aborts at pre-flight with the missing columns listed |
| Schema cannot be checked (DB down) | Reported as *not verified*, never as a schema change |
| Database stops answering mid-run | Run aborts non-zero; **never** reported as "nothing to archive" |
| One directory's asset list cannot be read | That directory is left untouched and counted; the run ends non-zero |
| `UPDATE` succeeds but no external library covers the destination | Update undone, asset skipped; a dry run warns in advance |
| `UPDATE` succeeds but the copy is invisible from the container | Update undone, copy removed, asset skipped |
| `UPDATE` cannot be undone after such a fault | Copy **KEPT** — the database points at it, so the asset has a file. Entry `divergent`, exit non-zero, `rollback` named in the log |
| External library path changed in Immich | Run aborts **and the cron is disabled** until `setup` is re-run |
| Path consistency cannot be verified | Run refused, cron left alone |
| Archived assets reported offline **and trashed** | Reported, with an explicit instruction not to empty the trash before fixing the path |

## Journal and resumption

| Event | Behaviour |
|---|---|
| Journal directory cannot be created or written | Run refused **before anything is touched**; a `df` line is logged, since a journal directory that refuses writes usually means the disk carrying Immich is full, read-only or failing |
| A record cannot be written before its step | That step is not taken, the asset is skipped, the attempt counter does **not** move |
| The final record cannot be written after the source is removed | A warning only; the next run re-reads the database and finishes cleanly |
| Journal record unreadable | That asset is left untouched (`illisible`) and never guessed at |
| Journal file cannot be renamed on close | Stays `.active`, which the next run treats as a killed run; warned, no longer silent |
| Asset deleted in Immich mid-flight | Entry `abandonne`; the run does **not** fail on it — the owner decided |
| Asset moved elsewhere in Immich (template migration, restored dump) | Entry `divergent`, untouched, exit non-zero |
| An asset fails 5 times | Parked `bloque`, never retried, counted by `status` |
| Every asset of a directory held by an unfinished run | Directory reported as *left alone*, not as failed |
| Crash mid-run | Lock released by trap or detected stale; the journal resumes each asset where it was left |
| No recent DB backup (< 7 days) | Archiving **and** resumption both refuse to start |

## Locking and concurrency

| Event | Behaviour |
|---|---|
| Concurrent invocation | Second run exits quietly on the directory lock, naming the holding PID |
| Reboot with a lock left behind | Boot id mismatch: the lock is recognised as stale and claimed |
| Holder died without releasing | PID not alive: stale, claimed by renaming aside |
| Two runs race for a stale lock | `rename()` succeeds for exactly one; the loser cannot delete the winner's fresh lock |
| `stop` while an operation is running | Waits up to 60 s, then warns that it is still running |

## Configuration

| Event | Behaviour |
|---|---|
| `config.conf` absent | Every command but `setup` and `uninstall` exits with the setup hint |
| `config.conf` has an invalid line | Every fault reported by line number; `CONFIG_LOADED` false; only `setup` and `uninstall` still run |
| An essential setting missing or empty | Same: a refusal at load, not a warning |
| A setting assigned twice | The later value wins, with a warning |
| `USER_MAP` empty | Reported as a config problem: archiving has no destination folder |
| Two users mapped to one folder | Reported as a config problem by the review, and refused by the wizard |
| A `USER_MAP` folder with a stray slash | Reported, with the corrected value |
| `BACKUP_RETENTION` invalid | `sync_now` refuses the whole run, copying and deleting nothing |
| `TARGET` missing | Archiving refuses |
| `MAX` missing on an unforced run | Archiving refuses; a `--force` run proceeds |
| `MAX` above the disk ceiling | `setup` refuses the value; `status` warns that archiving may never trigger |

## Environment

| Event | Behaviour |
|---|---|
| Docker unreachable as this user | Exits with advice to join the `docker` group, and never escalates |
| Immich containers not running | `setup` says Immich must be running and changes nothing; other commands report the container by name |
| No external library mounted into the server container | `setup` explains the prerequisite and changes nothing |
| `bc` or `sha256sum` missing | Pre-flight exits, naming them |
| Log directory not writable | File logging is skipped; the run continues |
| Storage reports unreliable mtimes (write-back mount) | No effect: names and sizes decide, never mtime |
| A misspelled flag (`--dryrun`) | The run stops rather than proceeding without the safety flag |
| `crontab` empty after uninstall removes the last line | `crontab -r` rather than piping an empty file |

## What the exit codes mean

| Code | From an archive run |
|---|---|
| `0` | nothing to do, or everything done, and nothing needs a person |
| `1` | the run was refused, a directory could not be read, or at least one entry ended `bloque` / `divergent` |

A rollback exits non-zero if it refused **anything**, so a partly accepted rollback is
visible to whatever invoked it.

The exit code is not an alert channel — the log is, and it is precise and timestamped. What
it buys is an exact status something else can be built on.

## Further

- [Troubleshooting](../guide/troubleshooting.md) — the same ground, starting from the
  message you saw
- [The diagnostic convention](../TECHNICAL.md#the-diagnostic-convention)
- [Known limitations](history.md#known-limitations)
