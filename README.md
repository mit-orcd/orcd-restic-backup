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

  -r, -f and -p may be combined; at least one is required.
  Order when combined: backup -> forget -> prune.

Environment overrides:
  MAX_UNUSED        Prune --max-unused value (default: unlimited = no repack, fastest)
  MAX_REPACK_SIZE   Prune --max-repack-size value (default: unset = no cap)
  ALLOW_ROOT_FS=1   Bypass the destination mount-point safety check
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
| `MAX_JOBS`     | `180`                        | edit script    | Max parallel per-user jobs. Tuned to saturate the backup host.     |
| `MAX_UNUSED`   | `unlimited`                  | `MAX_UNUSED`   | Prune `--max-unused`. `unlimited` = no repacking (fast/cheap).     |
| `MAX_REPACK_SIZE` | _(unset)_                 | `MAX_REPACK_SIZE` | Prune `--max-repack-size`; caps repack volume per run when set. |
| `RETRIES`      | `2`                          | `RETRIES`      | Extra attempts per target after the first (unlock between tries).  |
| `RETRY_DELAY`  | `15`                         | `RETRY_DELAY`  | Seconds to wait between attempts.                                  |
| `TMP`          | `/db/temp`                   | `TMP`          | Working dir for logs, lock files, and the failure log.             |
| `PASS_FILE`    | `$HOME/.backup_pass`         | `PASS_FILE`    | restic password file used for all repos.                           |
| `RESTIC`       | `/usr/local/bin/restic`      | `RESTIC`       | Path to the restic binary.                                         |
| `ALLOW_ROOT_FS`| `0`                          | `ALLOW_ROOT_FS`| Set to `1` to bypass the destination mount-point safety check.     |

> Retention (`KEEP_DAILY`/`KEEP_WEEKLY`) and `MAX_JOBS` are not exposed as flags; edit the
> script to change them.

## How it works

### Per-user repositories

Users are discovered (sorted) with:

```bash
find -L "$SOURCE" -maxdepth 1 -mindepth 1 -type d ! -name "restore*" -printf '%f\n' | sort
```

For each user, the repository is `DESTINATION/<user>`. On backup, the repo is created on
first use (`restic init`) if it does not already exist (detected via `restic cat config`).

### Backup mode (`-r`)

For each user the script:

1. `cd`s into `SOURCE` and backs up the relative path `./<user>`.
2. Ensures the repo exists (init if missing).
3. Removes stale locks (`restic unlock`).
4. Runs `restic backup --tag backup-<timestamp> --compression <level> --verbose --skip-if-unchanged`.

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

All targets are processed by a shared runner that launches background jobs and throttles to
`MAX_JOBS` concurrent jobs using `wait -n`. The default of `180` is intentionally high to
fully utilize a dedicated backup server handling thousands of targets.

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
