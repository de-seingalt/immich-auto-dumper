# Configuration and auto-detection

How `config.conf` is read, what each setting may hold, and where its values come from.
Back to the [technical index](../TECHNICAL.md) · user-facing version:
[configuring the tool](../guide/configuration.md).

## config.conf is data, never code

The file used to be `source`d. That made every value in it executable: a
`ARCHIVE_DEST_PATH="/mnt/external/$(whoami)"` ran that command, and so would anything else
written there. It ran for **every** command — including `status`, which announces itself as
read-only, including the uninstaller *before* its confirmation prompt, and most often from
cron, unattended.

So the file is parsed. A line is a setting and a value; the setting must be one the tool
knows; the value must match what that setting is allowed to hold; and **nothing in it is
ever evaluated**. That non-interpretation is the entire point.

What is stripped, as punctuation rather than interpreted:

- one layer of surrounding quotes, single or double;
- a whole line whose first non-blank character is `#`. Only a whole line: a `#` after a
  value is an ordinary character of that value, because a folder or a path may legitimately
  contain one and truncating it silently would be a worse failure than refusing it. A
  setting that swallowed an end-of-line comment is therefore rejected on its own merits,
  with a hint naming the cause;
- a UTF-8 byte-order mark, on the first line only — anywhere else those bytes are part of
  a real name, and an unknown setting is exactly what they are. A BOM is invisible, so the
  refusal it caused sent people looking in the wrong place entirely.

The only substitutions are a leading `~/` or `$HOME/` in a path setting, rewritten as
text. Exactly those two prefixes, because a config copied from the shipped example carried
`$HOME` there.

`config_load()` and `config_set()` live in `lib/config.sh`. Every fault is reported, **by
line number**, rather than only the first: one bad line must not hide the next four. A
setting assigned twice keeps the later value with a warning — "last one wins" is a
reasonable convention and refusing would break configurations that work today, but the
backfill below appends to the end of the file, which makes this precisely a place where a
second assignment turns up.

## Per-setting validation

| Setting | Accepted form |
|---|---|
| `IMMICH_UPLOAD_LOCATION`, `IMMICH_DB_LIBRARY_PREFIX`, `ARCHIVE_DEST_PATH`, `ARCHIVE_CONTAINER_PATH` | an absolute path |
| `LOG_DIR` | an absolute path; a relative one warns and falls back to the XDG default |
| `IMMICH_DB_CONTAINER`, `IMMICH_SERVER_CONTAINER` | a Docker container name |
| `IMMICH_DB_NAME`, `IMMICH_DB_USER` | a PostgreSQL identifier |
| `ARCHIVE_STORAGE_ID` | 4–64 plain characters, **or empty** |
| `ARCHIVE_LIBRARY_MAX_MB`, `ARCHIVE_LIBRARY_TARGET_MB`, `BACKUP_RETENTION`, `LOG_MAX_LINES` | a whole number of 1 or more |
| `ARCHIVE_MIN_FREE_MB` | a whole number of **0** or more |
| `USER_MAP.<key>` | a folder name inside the external library |
| anything else | rejected by name |

Two of those exceptions are deliberate and narrow:

- **`ARCHIVE_MIN_FREE_MB` may be zero**, and nothing else may. Zero turns the free-disk
  trigger off, which is a legitimate choice — when the *user* makes it. See
  `_recommended_min_free_mb()` below for why a *default* may never be zero.
- **`ARCHIVE_STORAGE_ID` may be empty**, and nothing else may. Empty means "accept
  whatever marker the storage carries", i.e. do not pin the destination to one volume.

`LOG_DIR` is the one path setting that falls back instead of refusing: where the log file
goes is not worth refusing to start over, and an older shipped example put a shell
expansion there.

## Essential settings

The nine keys in `_CFG_ESSENTIAL_KEYS` identify *this particular* Immich install and have
no safe default:

```
IMMICH_UPLOAD_LOCATION  IMMICH_DB_LIBRARY_PREFIX  IMMICH_DB_CONTAINER
IMMICH_SERVER_CONTAINER IMMICH_DB_NAME            IMMICH_DB_USER
ARCHIVE_DEST_PATH       ARCHIVE_CONTAINER_PATH    ARCHIVE_STORAGE_ID
```

A config missing one of these is broken, not merely old, so their absence is a **refusal
at load**: `CONFIG_LOADED` stays false and every command exits rather than act on half a
configuration. Two of them left empty were once enough for a run to report success while
archiving nothing.

`setup` and `uninstall` stay reachable in that state, on purpose — they are exactly what a
broken configuration needs.

## The user mapping

One line per user, written by `setup` and editable by hand:

```
USER_MAP.<key>=<folder>
```

The key is the user's Immich `storageLabel`, or its UUID when the storage label is empty.
The value is a folder inside the external library. There is no array declaration: the file
is read and not executed, and `declare -A` was the last thing in it that needed a shell to
make sense.

The value is pasted into `${ARCHIVE_DEST_PATH%/}/<folder>/…`, so an absolute path and any
`..` component are refused: no legitimate folder name needs to send archived photos outside
the external library.

**Two users must never share one folder.** Their libraries merge into it, and one relative
path below it then names two different photos. The tool refuses such an asset rather than
destroying it, but the run stalls on every collision — so both the wizard and the review
screen refuse the state up front.

A config written by an earlier version carries `declare -A USER_MAP` followed by
`USER_MAP["alice"]="Alice"` lines. Those are read as data like everything else and
normalised to the form above, so an existing install keeps working; `setup` rewrites the
file in the current format the next time it runs, and the review screen says so as a note.

## Where the values come from

Every value the tool needs is already defined by the running Immich install, so
`lib/detect.sh` reads that ground truth via `docker inspect` and the database, and the
wizard asks the user only to confirm or to choose between real alternatives.

| Function | Reads |
|---|---|
| `detect_immich_containers()` | running container names, by pattern |
| `detect_db_credentials()` | `DB_USERNAME` / `DB_DATABASE_NAME` from the server container's environment |
| `detect_upload_mount()` | Immich's `UPLOAD_LOCATION` bind mount |
| `detect_external_libraries()` | every bind mount that could be an external library |
| `db_detect_library_prefix()` | `IMMICH_DB_LIBRARY_PREFIX`, from a sample asset's path |
| `db_get_external_libraries()` | the import paths already configured in Immich |

The upload mount is found in three passes: the mount whose container path is the parent of
the DB library prefix (`/data/library` → `/data`), then the canonical destinations
(`/data` on current images, `/usr/src/app/upload` on older ones), then any bind mount whose
host side actually holds a `library/` folder.

**The Docker mount mode is deliberately not a filter.** `:ro` restricts the *container*, so
the Immich app cannot write to an external library — which is often set on purpose. This
tool writes through the *host* filesystem, not through Docker. Whether it can write there is
a host-side question, answered when the storage marker is written during setup.

**Container detection takes the first match, but not silently.** On a host running two
Postgres containers — two projects side by side is ordinary — the first simply won and
nothing said there had been a choice. The wizard now names every candidate and says which
way it went, so a wrong guess is visible there rather than discovered later against the
wrong database. A proper menu is the right answer the day this happens for real.

## The review screen

`setup` is the only writer of `config.conf`, and it is expected to be re-run — after an
update, or just to check where things stand. Walking the full questionnaire every time
pushes the user to re-answer questions they cannot remember, on a tool that rewrites paths
in Immich's database. So with a config already present, `_setup()` opens on
`_setup_review()` instead: the saved settings (`_config_summary()`), the verdict
(`_config_check()`), then a three-way choice between keeping the config, reconfiguring step
by step, and quitting. The step-by-step is only *recommended* — first in the menu — when a
check actually failed.

The review runs **before** `detect_docker_cmd()`, which exits when the daemon is
unreachable: showing a saved config and managing the schedule must keep working while
Immich or Docker is down. Every live check in `_config_check()` is therefore guarded by
`probe_docker_cmd()` / `_db_reachable()` and degrades to a note.

Findings land in three buckets, and the distinction is the whole point of the screen:

| Bucket | Meaning | Effect |
|---|---|---|
| `CFG_PROBLEMS` | a setting no longer holds: a loader refusal, a missing or empty key, `TARGET ≥ MAX`, an invalid `BACKUP_RETENTION`, an empty `USER_MAP`, a stray slash, two users in one folder, a container gone, an Immich user with no folder, path drift, a destination path absent from this host | reconfiguration recommended |
| `CFG_OUTDATED` | keys in `_CFG_BACKFILL_KEYS` absent from the file — a config written by an older version | offered for append-only backfill |
| `CFG_NOTES` | live state, not a config error: storage currently unmounted, Docker or the DB unreachable, the legacy `USER_MAP` form, Immich keeping more dumps than we mirror | informational |

Whatever `config_load()` refused is replayed here from `CFG_LOAD_PROBLEMS`: the log alone
is not where someone running `setup` looks.

Three implementation details of that screen:

- `_config_has_key()` greps `config.conf` rather than testing the variable. A variable can
  be set from the environment or defaulted elsewhere in the script, which would hide a key
  that is genuinely absent from the file.
- `_config_backfill()` only ever **appends** lines — through a temporary copy and a rename,
  like every write to this file — so a value the user edited by hand is never rewritten.
  That is what makes "keep my config" safe to offer at all. It logs each line it wrote,
  because a value that appears in a file on its own is a value nobody chose.
- `_user_map_count()` exists because a config carrying `declare -A USER_MAP` with no
  assignment leaves the array **declared but unset**, and `${#USER_MAP[@]}` on an unset
  array aborts under `set -u` — which is exactly the config that needs reporting on.

## Boundaries, defaults and the disk ceiling

The wizard validates `MAX` against a hard ceiling: **free disk + the library's current
size**, the most the library can ever reach before the disk itself fills. Past that the
disk fills before `MAX` is reached and archiving never fires. `status` re-checks the same
ceiling, because unrelated data erodes it over time, and says whether the free-disk safety
net is there to catch it.

`_recommended_min_free_mb()` is 10% of the disk, clamped between 2 and 20 GiB, rounded
down to a whole GiB. Two deliberate details:

- A disk size that cannot be read falls back to the 2 GiB floor and **never to 0**. Zero
  is a perfectly good value when the user picks it; a *default* choosing it for them
  disabled the safety net while presenting it as the recommended setting.
- The whole-GiB rounding round-trips exactly through `mb_to_input()`, whose two-decimal
  rendering (`10.84G`) otherwise loses a few MiB when parsed back — enough for simply
  accepting the pre-filled default to be flagged "below the recommended floor".

`_config_default_for()` reads Immich's own dump retention for `BACKUP_RETENTION` and
**validates it rather than merely defaulting**: `${keep:-14}` substitutes only for an
*empty* value, so a `0` coming back from Immich would have been written into the user's
config as if it were advice — and a retention of 0 deletes every mirrored dump.

Boundaries are stored in MiB (1 GiB = 1024 MiB) so fractional-GB limits are expressible.
The deprecated `ARCHIVE_LIBRARY_MAX_GB` / `ARCHIVE_LIBRARY_TARGET_GB` keys are still
honoured when the `*_MB` keys are absent, so an old config is read rather than reported
incomplete.

## Further

- [The path model and the diagnostic convention](../TECHNICAL.md)
- [The storage marker](external-storage.md), which `ARCHIVE_STORAGE_ID` pins
- [Configuring the tool](../guide/configuration.md), the same subject from the user's side
