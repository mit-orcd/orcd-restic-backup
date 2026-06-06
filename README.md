# orcd-restic-backup

A Bash wrapper around [restic](https://restic.net/) for backing up a large pool of
per-user directories on a dedicated backup server. Each user directory under a source
pool is backed up into its own restic repository, with backups fanned out in parallel to
saturate the backup host. Retention/pruning is a separate mode so it can run on its own
schedule.

## Overview

For a given `SOURCE` pool (e.g. `/data2/pool/005`), the script:

1. Discovers every immediate subdirectory (one per user), excluding any named `restore*`,
   in sorted order.
2. For each user, targets a dedicated restic repository at `DESTINATION/<user>`.
3. Runs the chosen operation(s) — `backup`, `forget` (retention policy), and/or `prune`
   (data reclamation) — across all users in parallel, throttled to `MAX_JOBS` concurrent
   jobs.
4. Reports a per-run summary and exits non-zero if any target failed.

`forget` and `prune` are intentionally separate modes. `forget` only removes snapshot
references (cheap, metadata-only) and is safe to run frequently. `prune` is what physically
reclaims data and, on remote/object storage, is the slow/expensive step — so it runs on its
own (infrequent) schedule and is tuned to stay safe for very large repositories.

Each source pool maps to one destination root, and the two are processed independently of
other pools. The script is designed to be driven from `cron`.

## Requirements

- **OS:** Linux. The script relies on GNU `find` (`-printf`), GNU `stat` (`stat -c`), and
  `flock` (util-linux). It is not portable to macOS/BSD as-is.
- **restic:** Installed at `/usr/local/bin/restic` by default (override with `RESTIC`).
  A reasonably recent version is required for `--compression` (repo format v2) and
  `--skip-if-unchanged`.
- **Bash:** 4.3+ (uses `wait -n`).
- A restic repository password file (see [Configuration](#configuration)).
- **Adaptive concurrency (`-A`/`--adaptive`) only:** rclone with its remote control enabled on the
  destination mount (`--rc --rc-addr=127.0.0.1:5572 --rc-no-auth`, address configurable via
  `RCLONE_RC_ADDR`), and `python3` for JSON parsing (a `grep`/`sed` fallback is used if absent).
  Not required for the default fixed-`MAX_JOBS` behavior.

## Installation

Place the script somewhere on the backup server and make it executable:

```bash
install -m 0755 restic_backup.sh /root/bin/restic_backup.sh
```

Create the password file used to encrypt/open every repository:

```bash
umask 077
printf '%s' 'your-restic-repo-password' > /root/.backup_pass
```

> All per-user repositories under a destination share the **same** password file.

## Usage

```text
Usage: restic_backup.sh [options]
Options:
  -z <level>                  Set compression level (auto|off|fastest|better|max, default: auto)
  -s|--source <dir>           Set source directory to backup (default: /data2/pool/005)
  -d|--destination <dir>      Set destination root dir to backup (default: /mnt/backup_pool/pool005)
  -r|--run                    Execute the backup
  -f|--forget                 Apply retention policy only (remove snapshots, NO prune)
  -p|--prune                  Reclaim data (prune); safe for large repos, run monthly
  -D|--dist-order             Dispatch backups in a coverage-optimal order from dist_planner.py (default: alphabetical sort)
  -A|--adaptive               Adaptively tune concurrency from rclone upload backlog + memory (default: fixed MAX_JOBS)
  -L|--loop                   Steady-state freshness: repeat the backup pass continuously (implies --skip-unchanged)
  --skip-unchanged            Skip users whose source tree is unchanged since their last backup (cheap find -newer check)

  -r, -f and -p may be combined; at least one is required.
  Order when combined: backup -> forget -> prune.

Environment overrides:
  MAX_UNUSED        Prune --max-unused value (default: unlimited = no repack, fastest)
  MAX_REPACK_SIZE   Prune --max-repack-size value (default: unset = no cap)
  RETRIES           Extra attempts per target after the first (default: 2)
  RETRY_DELAY       Seconds between attempts, with an unlock in between (default: 15)
  ALLOW_ROOT_FS=1   Bypass the destination mount-point safety check
  PYTHON            Python interpreter used for -D|--dist-order (default: python3)
  DIST_PLANNER      Path to dist_planner.py for -D|--dist-order (default: alongside this script)

  Steady-state freshness (-L|--loop, --skip-unchanged):
  SKIP_UNCHANGED    Force skip-unchanged on/off (true/false); overrides the -L auto-enable
  LOOP_INTERVAL     Seconds to sleep between backup cycles in loop mode (default: 60)
  LOOP_MAX_CYCLES   Stop after N loop cycles; 0 = infinite (default: 0)
  STATE_DIR         Where per-user last-backup markers live (default: ${TMP}/state)

  Adaptive concurrency (-A|--adaptive) tuning:
  MIN_JOBS          Concurrency floor in adaptive mode (default: 8); MAX_JOBS is the ceiling
  GOV_INTERVAL      Governor sample period in seconds (default: 20)
  GOV_STEP          Additive-increase step in jobs when backlog is low (default: 8)
  RCLONE_BIN        rclone binary used for rc calls (default: rclone)
  RCLONE_RC_ADDR    rclone --rc address of the mount (default: 127.0.0.1:5572)
  CACHE_DIR         Optional df-fallback path for backlog if rc is unavailable (default: unset = skip)
  CACHE_MAX_BYTES   vfs cache ceiling in bytes (default: 8796093022208 = 8 TiB)
  CACHE_HIGH        Back-off watermark, percent of CACHE_MAX_BYTES (default: 70)
  CACHE_LOW         Grow watermark, percent of CACHE_MAX_BYTES (default: 40)
  MEM_FLOOR_KB      Back off if MemAvailable falls below this many KiB (default: 8388608 = ~8 GiB)
  MEMINFO           Path to meminfo for the memory signal (default: /proc/meminfo)
```

At least one of `-r`, `-f`, or `-p` must be given, otherwise usage is printed and the script
exits with status `1`. When more than one is given they always run in the order
backup → forget → prune.

### Examples

Run a backup of a pool:

```bash
/root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -r
```

Backup and apply retention policy (recommended nightly job — no data reclamation):

```bash
/root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -r -f
```

Reclaim data (recommended monthly job; default skips repacking for speed/safety):

```bash
/root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -p
```

Prune while capping repack volume per run (chip away incrementally over several runs):

```bash
MAX_REPACK_SIZE=50G /root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -p
```

Override compression for one run:

```bash
/root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -r -z max
```

Backup in a coverage-optimal order (so an interrupted run still spans the whole alphabet):

```bash
/root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -r -D
```

Backup with adaptive concurrency (steer in-flight jobs from the rclone upload backlog instead of
a fixed `MAX_JOBS`; requires rclone `--rc` enabled on the mount — see below):

```bash
/root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -r -A
```

Run as a steady-state freshness daemon (loop forever, skipping users whose data has not changed
since their last backup so each cycle is fast and changed files are captured within ~one cycle):

```bash
/root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -r -L
```

Run a single pass that skips unchanged users (no looping — e.g. a frequent cron job):

```bash
/root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -r --skip-unchanged
```

## Configuration

The following defaults are set at the top of the script. Several can be overridden via
environment variables (defaults shown):

| Setting        | Default                      | Env override   | Description                                                        |
| -------------- | ---------------------------- | -------------- | ------------------------------------------------------------------ |
| `SOURCE`       | `/data2/pool/005`            | `-s` flag      | Pool whose immediate subdirectories (users) are backed up.         |
| `DESTINATION`  | `/mnt/backup_pool/pool005`   | `-d` flag      | Root under which per-user repos (`DESTINATION/<user>`) live.        |
| `COMPRESSION`  | `auto`                       | `-z` flag      | restic compression level (`auto`/`off`/`fastest`/`better`/`max`).  |
| `KEEP_DAILY`   | `14`                         | edit script    | Daily snapshots kept by `forget`.                                  |
| `KEEP_WEEKLY`  | `2`                          | edit script    | Weekly snapshots kept by `forget`.                                 |
| `MAX_JOBS`     | `180`                        | edit script    | Max parallel per-user jobs (the **ceiling** in adaptive mode). Tuned to saturate the backup host. |
| `MAX_UNUSED`   | `unlimited`                  | `MAX_UNUSED`   | Prune `--max-unused`. `unlimited` = no repacking (fast/cheap).     |
| `MAX_REPACK_SIZE` | _(unset)_                 | `MAX_REPACK_SIZE` | Prune `--max-repack-size`; caps repack volume per run when set. |
| `RETRIES`      | `2`                          | `RETRIES`      | Extra attempts per target after the first (unlock between tries).  |
| `RETRY_DELAY`  | `15`                         | `RETRY_DELAY`  | Seconds to wait between attempts.                                  |
| `TMP`          | `/db/temp`                   | `TMP`          | Working dir for logs, lock files, and the failure log.             |
| `PASS_FILE`    | `$HOME/.backup_pass`         | `PASS_FILE`    | restic password file used for all repos.                           |
| `RESTIC`       | `/usr/local/bin/restic`      | `RESTIC`       | Path to the restic binary.                                         |
| `ALLOW_ROOT_FS`| `0`                          | `ALLOW_ROOT_FS`| Set to `1` to bypass the destination mount-point safety check.     |
| `PYTHON`       | `python3`                    | `PYTHON`       | Python interpreter used for `-D`/`--dist-order` planning.          |
| `DIST_PLANNER` | `dist_planner.py` (alongside the script) | `DIST_PLANNER` | Path to the ordering helper used by `-D`/`--dist-order`. |
| `MIN_JOBS`     | `8`                          | `MIN_JOBS`     | Concurrency **floor** in adaptive mode (`-A`); ignored otherwise.  |
| `GOV_INTERVAL` | `20`                         | `GOV_INTERVAL` | Governor sample period in seconds (`-A`).                          |
| `GOV_STEP`     | `8`                          | `GOV_STEP`     | Additive-increase step (jobs) when backlog is low (`-A`).          |
| `RCLONE_BIN`   | `rclone`                     | `RCLONE_BIN`   | rclone binary used for the `rc vfs/stats` backlog query (`-A`).    |
| `RCLONE_RC_ADDR` | `127.0.0.1:5572`           | `RCLONE_RC_ADDR` | Address of the mount's rclone remote control (`--rc`) (`-A`).   |
| `CACHE_DIR`    | _(unset)_                    | `CACHE_DIR`    | Optional `df` fallback path for the backlog if `rc` is unreachable (`-A`). |
| `CACHE_MAX_BYTES` | `8796093022208` (8 TiB)   | `CACHE_MAX_BYTES` | vfs cache ceiling in bytes; backlog % is measured against this (`-A`). |
| `CACHE_HIGH`   | `70`                         | `CACHE_HIGH`   | Back-off watermark, percent of `CACHE_MAX_BYTES` (`-A`).           |
| `CACHE_LOW`    | `40`                         | `CACHE_LOW`    | Grow watermark, percent of `CACHE_MAX_BYTES` (`-A`).               |
| `MEM_FLOOR_KB` | `8388608` (~8 GiB)           | `MEM_FLOOR_KB` | Back off if `MemAvailable` falls below this many KiB (`-A`).       |
| `MEMINFO`      | `/proc/meminfo`              | `MEMINFO`      | Path to meminfo for the memory signal (override for testing) (`-A`). |
| `SKIP_UNCHANGED` | `false`                    | `SKIP_UNCHANGED` | Force change-detection skipping on/off (`true`/`false`); overrides the `-L` auto-enable. |
| `LOOP_INTERVAL`  | `60`                       | `LOOP_INTERVAL`  | Seconds to sleep between backup cycles in loop mode (`-L`).      |
| `LOOP_MAX_CYCLES`| `0`                        | `LOOP_MAX_CYCLES`| Stop the backup loop after N cycles; `0` = infinite (`-L`).      |
| `STATE_DIR`      | `${TMP}/state`             | `STATE_DIR`      | Root for per-user last-backup markers (`-L`/`--skip-unchanged`). |

> Retention (`KEEP_DAILY`/`KEEP_WEEKLY`) and `MAX_JOBS` are not exposed as flags; edit the
> script to change them. The adaptive-governor knobs above only take effect with `-A`/`--adaptive`.
> The freshness knobs (`SKIP_UNCHANGED`/`LOOP_INTERVAL`/`LOOP_MAX_CYCLES`/`STATE_DIR`) only take
> effect with `-L`/`--skip-unchanged`.

## How it works

### Per-user repositories

Users are discovered (sorted) with:

```bash
find -L "$SOURCE" -maxdepth 1 -mindepth 1 -type d ! -name "restore*" -printf '%f\n' | sort
```

For each user, the repository is `DESTINATION/<user>`. On backup, the repo is created on
first use (`restic init`) if it does not already exist (detected via `restic cat config`).

### Distribution-aware ordering (`-D`/`--dist-order`)

By default, users are dispatched in plain alphabetical order. With many thousands of targets,
an interrupted run (or one that does not finish its window) therefore covers only the front of
the alphabet (A–F…), leaving later initials untouched until the next run.

`-D`/`--dist-order` is an **opt-in** alternative that asks the bundled helper
`dist_planner.py` for a *coverage-optimal* dispatch order instead. The planner:

- Buckets user directories by their first letter (the same `restore*`-excluding set the backup
  discovers), and **weights each bucket purely by the count of directories** in it. It assumes
  every per-user directory is roughly the same size, so cost ≈ count.
- Emits a **proportional interleave** (`dist_planner.py <SOURCE> --emit-order`): each bucket is
  drained at a rate proportional to its size, so **any prefix of the run mirrors the full
  first-letter distribution**. If the run is interrupted, the portion completed is a
  representative slice across the whole alphabet rather than just the earliest letters.

Only the **order** changes. The execution engine is identical — the same shared runner still
launches background jobs and throttles to `MAX_JOBS` with the same retry-with-unlock behavior.

The feature is designed to never jeopardize a backup: if `-D` is requested but Python or the
planner is missing, or the planner errors / produces no output, the script logs a warning and
**falls back to the default `find … | sort`** order. Without `-D`, behavior is exactly the
sorted `find` described above.

The interpreter and planner path are configurable via `PYTHON` and `DIST_PLANNER`. The same
helper can be run manually for analysis:

```bash
python3 dist_planner.py /data2/pool/005            # human-readable distribution + worker-plan report
python3 dist_planner.py /data2/pool/005 --json     # the same plan as JSON
python3 dist_planner.py /data2/pool/005 --emit-order  # the dispatch order -D would use, one name per line
```

### Backup mode (`-r`)

For each user the script:

1. *(only with `--skip-unchanged`/`-L`)* checks the per-user marker and **skips the user entirely
   if its source tree is unchanged** since the last successful backup (see
   [Steady-state freshness](#steady-state-freshness--l--loop---skip-unchanged)).
2. `cd`s into `SOURCE` and backs up the relative path `./<user>`.
3. Ensures the repo exists (init if missing).
4. Removes stale locks (`restic unlock`).
5. Runs `restic backup --tag backup-<timestamp> --compression <level> --verbose --skip-if-unchanged`.
6. *(only with `--skip-unchanged`/`-L`)* on success, writes the user's freshness marker.

Backup mode does **not** forget or prune.

### Forget mode (`-f`)

Applies the retention policy for each existing repo — removes snapshots only, **no data
reclamation**:

```bash
restic forget --keep-daily 14 --keep-weekly 2
```

This is metadata-only and cheap, so it is safe to run on every backup. Missing repositories
are skipped.

### Prune mode (`-p`)

Physically reclaims data no longer referenced by any snapshot, for each existing repo:

```bash
restic prune --max-unused unlimited [--max-repack-size <MAX_REPACK_SIZE>]
```

This is the expensive operation on remote/object storage, because repacking partially-used
pack files requires downloading and re-uploading data. To keep it safe for very large
repositories:

- **`--max-unused unlimited` (default)** skips repacking entirely — restic only deletes pack
  files that are 100% unreferenced. This minimizes time and bandwidth; space is reclaimed
  **lazily** as packs become fully unused over successive runs. Set `MAX_UNUSED=0` (or e.g.
  `5%`) if you instead want aggressive repacking to minimize stored size.
- **`MAX_REPACK_SIZE`** (optional) caps how much data a single run will repack, so you can
  chip away incrementally across multiple runs rather than risk a run that won't finish.

Prune is intended to run on its own, infrequent schedule. Missing repositories are skipped.

### Parallelism

All targets are processed by a shared runner (`run_parallel`) that launches background jobs and
throttles to a concurrency cap using `wait -n`. By default the cap is the fixed `MAX_JOBS` (180,
intentionally high to fully utilize a dedicated backup server handling thousands of targets).
With `-A`/`--adaptive` the cap becomes dynamic — see below — but the default behavior is exactly
the fixed `MAX_JOBS` and carries **zero** governor overhead.

### Adaptive concurrency (`-A`/`--adaptive`)

When the destination is an rclone FUSE mount of object storage (e.g. Wasabi) with
`vfs_cache_mode=writes`, the real bottleneck during a large seed is the **upload backlog**: data
is written to the local vfs cache faster than rclone can upload it to the remote. If the cache
fills toward its `vfs_cache_max_size`, throughput collapses and lock errors get worse. A fixed
`MAX_JOBS` cannot react to this.

`-A`/`--adaptive` is an **opt-in** alternative in which a lightweight background **governor**
steers the number of in-flight jobs based primarily on that upload backlog, with available memory
as a secondary safety clamp. `MAX_JOBS` becomes the **ceiling** and `MIN_JOBS` the **floor**.

How it works:

- **Backlog signal (primary).** Every `GOV_INTERVAL` seconds the governor queries the mount's
  rclone remote control: `rclone rc --rc-addr=$RCLONE_RC_ADDR --rc-no-auth vfs/stats` and reads
  `diskCache.bytesUsed` (the data resident in the vfs cache, which includes what is still queued
  for upload). It computes `pct = 100 * bytesUsed / CACHE_MAX_BYTES`. JSON is parsed with
  `python3` when available, otherwise via a `grep`/`sed` fallback.
- **`df` fallback.** If the `rc` call fails **and** `CACHE_DIR` is set, the governor approximates
  the backlog from `df -kP "$CACHE_DIR"` used bytes. (`df` is used rather than `du`, which would
  be far too slow over a multi-terabyte cache.)
- **Memory signal (secondary).** It reads `MemAvailable` from `MEMINFO` (`/proc/meminfo`).
- **AIMD control.** Each tick it recomputes a target concurrency:
  - if `pct >= CACHE_HIGH` **or** `MemAvailable < MEM_FLOOR_KB` → **multiplicative decrease**
    (`target = target / 2`),
  - else if `pct < CACHE_LOW` → **additive increase** (`target = target + GOV_STEP`),
  - else → **hold**.

  The target is always clamped to `[MIN_JOBS, MAX_JOBS]`. It is published atomically to a state
  file (`$TMP/.gov_target.<sfx>`); `run_parallel` reads it before launching each job. Lowering
  the cap simply **stops launching** new jobs until the in-flight count drops below the new cap —
  it never kills running jobs; raising it lets more launch, up to `MAX_JOBS`. Each tick is logged
  to `$TMP/log/<sfx>_governor.log` as `ts pct=NN memAvailKB=NN target=NN`.

The governor is designed to **never break a backup**: if both the `rc` query and the `df` fallback
fail, it logs a single warning, holds the last target steady (never below `MIN_JOBS`), and the run
continues. It is started before dispatch and torn down at the end and on `EXIT`/`INT`/`TERM`.

> **Requires rclone `--rc`.** Adaptive mode needs the rclone remote control enabled on the mount
> (e.g. `--rc --rc-addr=127.0.0.1:5572 --rc-no-auth`). The address is configurable via
> `RCLONE_RC_ADDR`. Without `--rc` (and without a `CACHE_DIR` `df` fallback) the governor cannot
> read the backlog and holds concurrency steady at a safe value rather than failing.

### Steady-state freshness (`-L`/`--loop`, `--skip-unchanged`)

Seeding all ~7000 per-user repositories for the first time is expensive (~120h). Once seeded,
incremental backups are cheap, so the goal shifts to **minimizing the latency between a user adding
a file and that file being backed up**. Two **opt-in** mechanisms address this, and **neither
changes the default behavior** — without these flags the script does exactly one pass over all
users with no skipping and no state/marker requirement.

#### `--skip-unchanged` — cheap change detection

Before backing up a user, the script checks whether that user's source tree has changed since its
**last successful backup**, and skips it entirely if not — **no `restic` invocation, no `init`, no
`unlock`, no Wasabi lock churn**. Skipping the untouched majority is what keeps each cycle fast, so
the users who *did* change get re-backed up quickly.

The check is deliberately cheap:

- Each successful backup writes a per-user marker at `${STATE_DIR}/<sfx>/<user>.last` containing a
  unix timestamp. The timestamp recorded is the moment captured **just before** the change-scan and
  backup begin — not after — so a file added *while* the backup is running is still seen as newer on
  the next cycle and is not missed.
- Change detection runs a **short-circuiting** scan of the source side:

```bash
find "${SOURCE}/<user>" -newermt "@<marker-ts>" -print -quit
```

  `-quit` makes `find` stop at the **first** entry newer than the marker, so in the common case
  (one new file, or nothing new) it does O(1) work rather than walking the whole tree. If `find`
  prints anything, the user changed; if it prints nothing, the user is unchanged and is skipped.

The check is **fail-safe**: a missing marker (never backed up), a garbled marker, or any `find`
error all cause the user to be treated as **changed** (backed up). It can never cause a real backup
to be skipped by mistake. Markers are written atomically (`.tmp` then `mv -f`). The marker directory
`${STATE_DIR}/<sfx>` is created once at startup, and **only** when skipping is active — default
single-pass runs touch no state at all.

#### `-L`/`--loop` — continuous re-cycling

`-L` repeats the **backup** pass continuously (forget/prune remain single-shot). Each cycle:

1. **Re-discovers** the user list (so directories added between cycles are picked up — using the
   same discovery, including `-D` ordering, as a normal run),
2. runs the backup pass, then
3. logs a one-line summary `=== Backup cycle N for <sfx> done: total=… skipped=… failed=… ===`,
4. sleeps `LOOP_INTERVAL` seconds, and repeats until `LOOP_MAX_CYCLES` is reached
   (`0` = infinite).

Looping **implies `--skip-unchanged`** (otherwise every cycle would re-backup every user and hammer
Wasabi). You can override this with the `SKIP_UNCHANGED` environment variable, which always wins —
set `SKIP_UNCHANGED=false` to loop without skipping, or `SKIP_UNCHANGED=true` to skip without
looping. Combined, looping + skipping means **a changed file is captured within roughly one cycle**
while unchanged users cost almost nothing.

**Failure tracking in loop mode.** The per-cycle failure log is **reset at the start of each
cycle**, so a transient failure in one cycle does not permanently mark the whole run as failed;
each cycle reports its own failures in its summary line. When the loop ends (finite
`LOOP_MAX_CYCLES`), the script's final summary/exit status reflects the **last** cycle. An infinite
loop (`LOOP_MAX_CYCLES=0`) runs as a daemon and is stopped via `INT`/`TERM` (the `EXIT` trap still
tears down the governor).

**Governor interaction.** If `-A`/`--adaptive` is combined with `-L`, the governor is started
**once** before the loop and stopped **once** after it (and by the `EXIT`/`INT`/`TERM` trap) — it
spans the entire loop rather than being torn down and recreated each cycle.

## Safety features

- **Mount check (`#1`):** Before any writes, the script resolves the mount point of
  `DESTINATION` (`stat -c '%m'`). If it resolves to `/`, the backup volume is presumed not
  mounted and the run aborts to avoid silently filling the root disk. Override with
  `ALLOW_ROOT_FS=1`.
- **Single-instance lock (`#2`):** A per-destination `flock` (`$TMP/.restic_backup.<sfx>.lock`)
  prevents two runs against the same destination pool from overlapping and corrupting
  repositories. Different pools (different destinations) can still run concurrently.
- **Failure tracking (`#3`):** Background jobs cannot easily propagate exit codes, so each
  failed target appends a line to a per-run failure log. At the end the script prints a
  summary and exits non-zero if anything failed, so monitoring sees real status.
- **Retry with unlock:** Each per-user restic operation runs through a retry wrapper
  (`RETRIES` attempts, `RETRY_DELAY` seconds apart, with `restic unlock` between tries). This
  absorbs the transient lock-file errors that can occur when the repository lives on an
  rclone/s3fs FUSE mount — e.g. `unable to refresh lock: chmod ...: no such file or
  directory`, caused by the mount's directory cache briefly surfacing a lock object that is
  already deleted on the remote, or leftovers from a killed run. A target is only counted as
  failed after all attempts are exhausted.

## Logs and exit codes

- Per-user logs are written under `$TMP/log/` (default `/db/temp/log/`):
  - `<sfx>_<user>-init.log` — repository initialization output.
  - `<sfx>_<user>-backup.log` — backup output.
  - `<sfx>_<user>-forget.log` — forget (retention policy) output.
  - `<sfx>_<user>-prune.log` — prune (data reclamation) output.

  where `<sfx>` is the last path component of `DESTINATION` (e.g. `pool005`). Logs are
  overwritten on each run.

- **Exit codes:**
  - `0` — all operations completed successfully.
  - `1` — usage error, another run already in progress, destination not mounted, or one or
    more targets failed (a summary of failed targets is printed).

## Scheduling

Because backup, forget, and prune are independent modes, the recommended pattern is frequent
backups with retention applied each run, and infrequent data reclamation. Example `crontab`
(run as `root`):

```cron
# Nightly backup + retention policy at 01:00 (cheap; no data reclamation)
0 1 1-30 * *  /root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -r -f

# Monthly prune on the 1st at 04:00 (data reclamation)
0 4 1 * *     /root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -p
```

The single-instance lock makes overlapping invocations safe to schedule — a second run
against the same destination will exit immediately rather than run concurrently.

### Why prune runs monthly

If your object-storage backend enforces a minimum storage duration (e.g. Wasabi's 30-day
minimum), data deleted before that period is still billed for the full minimum. Pruning more
often than the minimum yields no storage savings and triggers early-deletion charges plus
repack churn. Running `prune` roughly every 30 days — at or beyond the storage minimum —
aligns physical deletion with the billing floor. Meanwhile `forget` (run nightly) keeps the
snapshot list reflecting the retention policy continuously.

## Restoring

Each user has a standalone restic repository, so restores use restic directly. For example:

```bash
restic -r /mnt/backup_pool/pool005/<user> --password-file /root/.backup_pass snapshots
restic -r /mnt/backup_pool/pool005/<user> --password-file /root/.backup_pass restore latest --target /path/to/restore
```

> Directories named `restore*` in the source pool are excluded from backups.

## Notes and caveats

- Backup and forget do not reclaim data; ensure a `prune` schedule (`-p`) is in place or
  repositories will grow indefinitely.
- With the default `MAX_UNUSED=unlimited`, prune does not repack, so space is reclaimed
  lazily (whole packs only). This is the safe/fast choice for large repos on object storage;
  set `MAX_UNUSED=0` if you need to minimize stored size at the cost of repacking.
- Prune locks each repository while it runs (per-repo; other users still back up). For very
  large repos, use `MAX_REPACK_SIZE` to bound per-run work so prune fits your maintenance
  window.
- All repositories under a destination share one password file.
- **rclone/s3fs mount + lock errors:** When the destination is an rclone (or s3fs) FUSE mount
  of object storage (e.g. Wasabi), restic's local backend can intermittently fail on lock
  files (`unable to refresh lock: chmod ...: no such file or directory`). This is caused by
  the mount's directory cache surfacing a lock object that is already gone on the remote (or
  leftovers from a killed run), not by repository corruption. The script's retry-with-unlock
  wrapper absorbs these. To reduce them at the source, keep the mount's directory cache short
  — for an rclone mount, add mount options such as
  `dir_cache_time=5s,attr_timeout=1s,poll_interval=10s` (the default `dir_cache_time` is 5
  minutes, which is the main culprit).
- Per-user logs are overwritten each run; capture cron output (or copy logs) if you need
  history for diagnosing intermittent failures.
- `--compression` requires repositories in format v2; `--skip-if-unchanged` requires a
  recent restic. `--max-unused`/`--max-repack-size` require restic ≥ 0.12.
