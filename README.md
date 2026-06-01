# orcd-restic-backup

A Bash wrapper around [restic](https://restic.net/) for backing up a large pool of
per-user directories on a dedicated backup server. Each user directory under a source
pool is backed up into its own restic repository, with backups fanned out in parallel to
saturate the backup host. Retention/pruning is a separate mode so it can run on its own
schedule.

## Overview

For a given `SOURCE` pool (e.g. `/data2/pool/005`), the script:

1. Discovers every immediate subdirectory (one per user), excluding any named `restore*`.
2. For each user, targets a dedicated restic repository at `DESTINATION/<user>`.
3. Runs the chosen operation (`backup` and/or `forget --prune`) across all users in
   parallel, throttled to `MAX_JOBS` concurrent jobs.
4. Reports a per-run summary and exits non-zero if any target failed.

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
  -p|--prune                  Execute forget/prune only (retention maintenance)

  -r and -p may be combined; at least one is required.
  ALLOW_ROOT_FS=1 env var bypasses the destination mount-point safety check.
```

At least one of `-r` or `-p` must be given, otherwise usage is printed and the script exits
with status `1`.

### Examples

Run a backup of a pool:

```bash
/root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -r
```

Run retention/prune only (no new snapshots created):

```bash
/root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -p
```

Back up and prune in the same invocation (backup first, then prune):

```bash
/root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -r -p
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
| `TMP`          | `/db/temp`                   | `TMP`          | Working dir for logs, lock files, and the failure log.             |
| `PASS_FILE`    | `$HOME/.backup_pass`         | `PASS_FILE`    | restic password file used for all repos.                           |
| `RESTIC`       | `/usr/local/bin/restic`      | `RESTIC`       | Path to the restic binary.                                         |
| `ALLOW_ROOT_FS`| `0`                          | `ALLOW_ROOT_FS`| Set to `1` to bypass the destination mount-point safety check.     |

> Retention (`KEEP_DAILY`/`KEEP_WEEKLY`) and `MAX_JOBS` are not exposed as flags; edit the
> script to change them.

## How it works

### Per-user repositories

Users are discovered with:

```bash
find -L "$SOURCE" -maxdepth 1 -mindepth 1 -type d ! -name "restore*" -printf '%f\n'
```

For each user, the repository is `DESTINATION/<user>`. On backup, the repo is created on
first use (`restic init`) if it does not already exist (detected via `restic cat config`).

### Backup mode (`-r`)

For each user the script:

1. `cd`s into `SOURCE` and backs up the relative path `./<user>`.
2. Ensures the repo exists (init if missing).
3. Removes stale locks (`restic unlock`).
4. Runs `restic backup --tag backup-<timestamp> --compression <level> --verbose --skip-if-unchanged`.

Backup mode does **not** prune. Repositories grow until a prune run is performed.

### Prune mode (`-p`)

For each user with an existing repo:

```bash
restic forget --keep-daily 14 --keep-weekly 2 --prune
```

Missing repositories are skipped. Because backup and prune are separate modes, they can be
scheduled independently (see [Scheduling](#scheduling)).

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

## Logs and exit codes

- Per-user logs are written under `$TMP/log/` (default `/db/temp/log/`):
  - `<sfx>_<user>-init.log` — repository initialization output.
  - `<sfx>_<user>-backup.log` — backup output.
  - `<sfx>_<user>-prune.log` — forget/prune output.

  where `<sfx>` is the last path component of `DESTINATION` (e.g. `pool005`). Logs are
  overwritten on each run.

- **Exit codes:**
  - `0` — all operations completed successfully.
  - `1` — usage error, another run already in progress, destination not mounted, or one or
    more targets failed (a summary of failed targets is printed).

## Scheduling

Because backup and prune are independent modes, a common pattern is frequent backups with
less frequent pruning. Example `crontab` (run as `root`):

```cron
# Nightly backup at 01:00
0 1 * * *  /root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -r

# Weekly prune on Sunday at 04:00
0 4 * * 0  /root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -p
```

The single-instance lock makes overlapping invocations safe to schedule — a second run
against the same destination will exit immediately rather than run concurrently.

## Restoring

Each user has a standalone restic repository, so restores use restic directly. For example:

```bash
restic -r /mnt/backup_pool/pool005/<user> --password-file /root/.backup_pass snapshots
restic -r /mnt/backup_pool/pool005/<user> --password-file /root/.backup_pass restore latest --target /path/to/restore
```

> Directories named `restore*` in the source pool are excluded from backups.

## Notes and caveats

- Backup mode does not prune; ensure a prune schedule is in place or repositories will grow
  indefinitely.
- All repositories under a destination share one password file.
- Per-user logs are overwritten each run; capture cron output (or copy logs) if you need
  history for diagnosing intermittent failures.
- `--compression` requires repositories in format v2; `--skip-if-unchanged` requires a
  recent restic.
