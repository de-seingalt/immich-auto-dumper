# Configuring the tool

The setup wizard, screen by screen. Back to the [user guide](../GUIDE.md) · previous:
[external storage](external-storage.md) · next: [archiving](archiving.md).

```bash
immich-auto-dumper setup
```

No arguments, and safe to run as many times as you like. It is the only thing that writes
your configuration file.

**Immich must be running.** The wizard configures itself from your live installation, so if
Immich is down it says so and changes nothing.

## What it works out on its own

You confirm rather than type. The wizard reads your running Immich and finds:

- the Immich server and PostgreSQL containers, and the database name and user;
- Immich's upload location on this machine, and the path prefix it stores in its database;
- every external library mounted into the server container;
- the import paths you already configured in Immich, per user — which become the suggested
  folder names.

If more than one container matches, it takes the first and **tells you which ones it saw**,
so you can spot a wrong guess here rather than discover it later against the wrong database.

## The screens

### 1. External library

Shows the host path and the container path it found, and asks you to confirm. If you have
several, you pick one.

If it finds none, setup stops and explains what to add — go back to
[external storage](external-storage.md).

### 2. MAX ▼ — start archiving above

The size your library may reach before archiving begins.

### 3. MIN ▲ — archive down to

The size each run brings the library back to. Must be below MAX. Archiving never goes below
it, on any run.

Both screens show the same gauge, on the scale of your whole disk:

```
Immich library now: 142.3 GB (31%)  ·  disk used: 256 GB (56%)  ·  disk total: 460 GB  ·  free space: 204 GB
                                                  ▼
├▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒██████████░░░░░░░░░░░░░░░░░░░┄┄┄┄┄┤
                              ▲
▼ MAX = 200.00 GB   archiving STARTS when the library grows past this
▲ MIN = 150.00 GB   each run brings the library back DOWN to this
█ current library   ▒ other data   ░ headroom up to MAX   ┄ free
```

`█` is your library now, `▒` is everything else on the same disk, `░` is the room the
library still has before MAX, `┄` is free space.

A confirmation screen follows, so you can reset both values and start over.

**MAX cannot exceed free disk + your current library size.** Beyond that the disk fills
before MAX is ever reached, and archiving would never trigger. The wizard refuses such a
value and says what the ceiling is.

### 4. FREE ▽ — the free-disk safety net

A second, independent trigger: archiving also runs when **total free disk space** falls
below this, even while the library is still under MAX.

It exists because MAX assumes your library is the only thing filling the disk. Postgres,
Docker images and logs share it, and they can fill it first — in which case the library
trigger would never fire on its own.

On by default, at 10% of the disk (between 2 and 20 GB). Enter `0` to switch it off. If you
enter something below the recommendation, it asks you to confirm rather than silently
accepting it.

### 5. How many database dumps to keep

How many of Immich's own database dumps to keep on the external storage.

The wizard reads the number Immich keeps locally and suggests the same. **Keeping at least
as many means a dump is never dropped from your external copy while Immich still has it
locally.** If you choose fewer, it says so and lets you decide.

See [database backups](database-backups.md).

### 6. A folder per user

One screen per Immich user: the sub-folder on the external storage where that user's
archived photos go.

It pre-fills the answer from — in order — your existing configuration, the import path
Immich already uses for that user, then the user's name. It also lists the folders already
on the storage, so you can reuse a consistent name.

> **Two users must never share one folder.** Their libraries would merge into it, and the
> same relative path below it would name two different photos. The wizard refuses a folder
> already taken and tells you who has it.

An empty answer is refused too: archiving into the root of the external library would mix
everyone's photos together and leave no per-user path to register in Immich.

### 7. Confirmation

The whole configuration on one screen, including where each user's photos will go. Nothing
has been written yet — cancelling here leaves everything as it was.

Choosing **Validate config** writes the file.

### 8. Scheduling

Finally it shows what is scheduled right now and offers what fits — see
[scheduling](scheduling.md). You can decline and do it later with
`immich-auto-dumper start`.

## Sizes you can type

| You type | Means |
|---|---|
| `200` | 200 GiB — a bare number is read as gigabytes |
| `1.5G` or `1.5GB` | 1.5 GiB |
| `500M` | 500 MiB |
| `2T` | 2 TiB |
| `80%` | 80% of the disk (or of MAX, on the MIN screen) |
| `1,5G` | same as `1.5G` — a comma decimal separator is accepted |
| `0` | on the FREE screen only: disable the safety net |

## After the wizard

It prints a summary that stays on your terminal, listing the folders it created and — if
any user still has no external library in Immich — **the exact import path to add for
each**. Do that before the first real dump.

Then:

```bash
immich-auto-dumper test_run
```

See [trying it first](archiving.md#trying-it-first).

## Re-running setup later

Running `setup` again **never makes you redo everything.**

With a configuration already in place it opens on a review instead of the questionnaire:

1. **Your configuration**, as saved, including where each user's photos are archived and
   whether the scheduled jobs are running right now.
2. **The verdict** of checking it against this version of the tool and your live Immich,
   in three groups:
   - things that **no longer hold** — a missing setting, a container that is gone, an
     Immich user with no folder, two users sharing one, paths that have drifted;
   - settings this version **added** that your file does not mention yet, which can be
     appended with their defaults without touching anything else;
   - **for information** — the storage is currently unmounted, Docker is unreachable,
     Immich keeps more dumps than you mirror. Not errors.
3. **The choice**: keep this config, reconfigure step by step, or quit. Step-by-step is
   only recommended when something actually failed.

Choosing **keep** never rewrites an answer you already gave. It only offers to append the
new settings, then reviews the schedule.

This review works **even when Immich or Docker is down**: it runs before the tool needs
Docker, so you can always look at your settings and manage the schedule. Checks that need
a live Immich then simply report that they could not be made — which is not the same as
passing.

## Editing config.conf by hand

You can. It lives at `~/.local/share/immich-auto-dumper/config.conf` and it is read as
plain data, never executed.

The user mapping looks like this:

```
USER_MAP.alice=Alice
USER_MAP.bob=Bob
```

The part after `USER_MAP.` is Immich's storage label for that user, or its UUID when the
storage label is empty. The value is a folder inside the external library.

Every setting is validated when the file is read, and a bad value is reported **with its
line number**. A setting the tool cannot use stops it from running rather than being
guessed at — so a typo is loud, not silent. `setup` repairs the file if you would rather
not.

The full reference is in [the technical documentation](../technical/configuration.md).

---

Next: [how archiving works](archiving.md).
