# orcd-restic

Parallel, per-user [restic](https://restic.net/) backups of large multi-user
filesystems to Wasabi S3 buckets.

Each top-level directory under the source (typically one per user) is backed up
into its **own restic repository** inside the bucket, so users can be backed up,
expired, pruned, and restored independently and in parallel.

```text
SOURCE                    BUCKET (Wasabi)
/home/alice      ->       s3://orcd-backup-home/home3/alice    (restic repo)
/home/bob        ->       s3://orcd-backup-home/home3/bob      (restic repo)
/home/carol      ->       s3://orcd-backup-home/home3/carol    (restic repo)
```

## Scripts

| Script | Backend | Status |
| --- | --- | --- |
| `restic_backup_s3.sh` | restic native S3 backend, talks directly to Wasabi | **recommended** |
| `restic_backup.sh` | restic local backend over an rclone VFS mount | legacy |

### Why the native S3 backend?

restic's *local* backend writes every pack file under a temporary name
(`data/xx/<hash>-tmp-<n>`) and then renames it. S3 has no rename, so an rclone
mount emulates it as server-side `COPY` + `DELETE`. The result: **every uploaded
pack also produces one deleted object of the same size** (~17 MB each in
practice). On Wasabi, objects deleted before the minimum storage period are
billed as *timed deleted storage* — in our case this silently accumulated tens
of TB of "deleted storage" charges. The native S3 backend uploads each object
once under its final key: no rename, no `COPY`, no `DELETE`, and none of the VFS
dir-cache lock flakiness of the mount.

## Requirements

- bash >= 4.3, `flock`, GNU `find`
- restic >= 0.17 (`--retry-lock`, `--skip-if-unchanged`); tested with 0.19.
  `REPACK_SMALLER_THAN` requires restic >= 0.18; on 0.19 the exit-code-aware retry
  logic relies on `backup` exit 3 / SIGINT exit 130 being reported distinctly.
- rclone (only to verify the in-bucket root dir, and for the legacy script's mount)
- Wasabi credentials in `/root/.config/rclone/rclone.conf`, e.g.:

```ini
[wasabi]
type = s3
provider = Wasabi
access_key_id = ...
secret_access_key = ...
endpoint = s3.us-east-1.wasabisys.com
```

`restic_backup_s3.sh` reads the keys and endpoint from this file (single source
of truth); no separate AWS config is needed.

## Usage

```text
restic_backup_s3.sh [options]

  -z <level>                  Compression level (auto|off|fastest|better|max, default: auto)
  -s|--source <dir>           Source directory containing per-user dirs
  -b|--bucket <bucket[/pfx]>  Destination bucket (default: orcd-backup-home)
  -R|--root-dir <dir>         REQUIRED root dir inside the bucket (e.g. home3);
                              must already exist unless ALLOW_NEW_ROOT=1
  -u|--user <name>            Run for this user only (repeatable: -u alice -u bob)
  -n|--no-flock               Bypass the global lock (requires -u); takes per-user locks
  -r|--run                    Execute the backup
  -f|--forget                 Apply retention policy (snapshots only, no data reclaim)
  -p|--prune                  Reclaim unreferenced data (expensive; run monthly)
```

`-r`, `-f`, `-p` may be combined; order is always backup → forget → prune.

### Examples

```bash
# Nightly: backup + retention for all users
restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -r -f

# Monthly: reclaim space (respect Wasabi minimum storage period)
restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -p

# Ad hoc, one user only
restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -u alice -r -f

# Ad hoc while the scheduled full run is in progress
restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -u alice -n -r

# First-ever run against a new root dir
ALLOW_NEW_ROOT=1 restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -r
```

### Suggested cron schedule

```cron
# nightly backup + forget at 04:00
0 4 * * *  /root/bin/restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -r -f >> /var/log/restic_backup.log 2>&1
# monthly prune, 1st of the month at 12:00
0 12 1 * * /root/bin/restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -p   >> /var/log/restic_prune.log  2>&1
```

## Environment overrides

| Variable | Default | Purpose |
| --- | --- | --- |
| `MAX_JOBS` | `90` | Parallel per-user jobs |
| `PACK_SIZE` | `64` | `--pack-size` (MiB); larger packs = fewer objects on Wasabi |
| `RETRY_LOCK` | `5m` | restic `--retry-lock`: wait for competing repo locks |
| `RETRIES` / `RETRY_DELAY` | `2` / `15` | Extra attempts per target / seconds between them |
| `MAX_UNUSED` | `unlimited` | Prune `--max-unused` (`unlimited` = no unused-space repack, fastest) |
| `MAX_REPACK_SIZE` | unset | Prune `--max-repack-size` cap per run |
| `REPACK_SMALLER_THAN` | unset | Prune `--repack-smaller-than` (e.g. `1B` to suppress small-pack repacking; see note below) |
| `S3_CONNECTIONS` | `5` | restic `-o s3.connections` per process |
| `S3_ENDPOINT` | from rclone.conf | Wasabi endpoint URL |
| `RCLONE_CONF` | `/root/.config/rclone/rclone.conf` | Where keys/endpoint are read from |
| `RCLONE_REMOTE` | `wasabi` | rclone.conf section to read |
| `RESTIC_CACHE_DIR` | derived | restic metadata cache (see below) |
| `PASS_FILE` | `~/.backup_pass` | restic repository password file |
| `TMP` | `/db/temp` | Lock files, failure log, per-user logs (`$TMP/log/`) |
| `ALLOW_NEW_ROOT` | `0` | `1` = skip the root-dir-exists check (first run) |

### Cache directory convention

The restic metadata cache is derived from the bucket name —
`orcd-backup-<x>` → `/stage/backup/<x>/001/restic-cache`:

| Bucket | Cache dir |
| --- | --- |
| `orcd-backup-home` | `/stage/backup/home/001/restic-cache` |
| `orcd-backup-software` | `/stage/backup/software/001/restic-cache` |
| `orcd-backup-pool` | `/stage/backup/pool/001/restic-cache` |

## Safety mechanisms

1. **Root-dir check** — refuses to run if `-R <dir>` contains no objects in the
   bucket, so a typo cannot silently start a brand-new tree and re-upload
   everything (`ALLOW_NEW_ROOT=1` overrides for genuine first runs).
2. **Single-instance lock** — one `flock` per bucket+root prevents overlapping
   full runs. `-n` (with `-u`) downgrades it to per-user locks for ad hoc runs.
3. **Repo detection before init** — `restic init` is only called when the repo
   is genuinely absent; transient errors are never mistaken for "missing repo".
4. **Per-target failure tracking** — failures are collected from the parallel
   jobs; the script reports a summary and exits non-zero if any target failed.
5. **Lock retry + unlock-between-retries** — transient repo-lock collisions are
   absorbed (`--retry-lock`) instead of failing the target. Non-transient failures
   (`backup` exit 3 = missing/unreadable source path; exit 130 = SIGINT) fail fast
   without burning retries; they are still reported in the failure summary.

## Retention and Wasabi billing

Defaults: `--keep-daily 30 --keep-weekly 4 --keep-monthly 3 --keep-within 30d`.

`--keep-within 30d` guarantees no snapshot younger than 30 days is removed, so
by the time the monthly `prune` deletes pack files they are past Wasabi's
30-day minimum storage period (reserved capacity). **Pay-as-you-go accounts
have a 90-day minimum** — raise retention accordingly or accept timed
deleted-storage charges.

`forget` (cheap, metadata-only) and `prune` (expensive, deletes/repacks data)
are deliberately separate modes: forget nightly, prune monthly.

**restic >= 0.19 small-pack repacking:** restic 0.19 repacks small pack files more
aggressively *by default*. This consolidation is independent of `--max-unused`, so
even with `MAX_UNUSED=unlimited` a prune downloads + re-uploads more small packs than
on 0.17/0.18 — extra bandwidth and S3/Wasabi request + deleted-storage cost on every
prune. Set `REPACK_SMALLER_THAN` to pin the behavior: a small value (e.g. `1B`)
suppresses small-pack repacking (cheapest prune, but small packs accumulate over time);
a larger value consolidates more (higher upfront cost, fewer objects). Always confirm
the repack volume with `restic prune --dry-run` before settling on a value.

## Interactive use over the rclone mount

Keeping the rclone mounts for browsing/restores is fine — **reads are
harmless**. Avoid restic *write* operations (backup/forget/prune) through the
mount: any pack written via the mount goes through the tmp-rename path and
generates deleted-storage charges. For pure queries, skip the repo lock
entirely:

```bash
restic --no-lock -r /mnt/wasabi_backup_home/home3/alice snapshots
```

Set once in `/etc/profile.d/restic.sh` for convenience:

```bash
export RESTIC_PASSWORD_FILE=/root/.backup_pass
export RESTIC_CACHE_DIR=/stage/backup/restic-cache
```

## Restore

```bash
# list snapshots for a user
restic -r s3:https://s3.us-east-1.wasabisys.com/orcd-backup-home/home3/alice \
    --password-file /root/.backup_pass snapshots

# restore the latest snapshot
restic -r s3:https://s3.us-east-1.wasabisys.com/orcd-backup-home/home3/alice \
    --password-file /root/.backup_pass restore latest --target /home/restore/alice
```

## Logs

Per-user logs are written to `$TMP/log/` (default `/db/temp/log/`) as
`<bucket-component>-<root>_<user>-{backup,forget,prune,init}.log`. The script
prints a failure summary and exits `1` if any target failed, `0` otherwise.
