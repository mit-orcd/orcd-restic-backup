# orcd-restic

Parallel, per-user [restic](https://restic.net/) backups of large multi-user
filesystems to **AWS S3** (or, occasionally, Wasabi) buckets.

Each top-level directory under the source (typically one per user) is backed up
into its **own restic repository** inside the bucket, so users can be backed up,
expired, pruned, and restored independently and in parallel.

```text
SOURCE                    BUCKET (AWS S3 / Wasabi)
/home/alice      ->       s3://orcd-backup-home/home3/alice    (restic repo)
/home/bob        ->       s3://orcd-backup-home/home3/bob      (restic repo)
/home/carol      ->       s3://orcd-backup-home/home3/carol    (restic repo)
```

## The script

`restic_backup_s3.sh` uses restic's **native S3 backend**, talking directly to
the object store. It is vendor-agnostic via `-c|--cloud`:

- `-c aws` **(default)** — credentials from the standard AWS chain
  (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` or `AWS_PROFILE`); endpoint derived
  from `AWS_REGION`.
- `-c wasabi` — keys/endpoint from the `[wasabi]` section of `rclone.conf`. Wasabi
  is used only sporadically and is not the primary target.

Everything restic-side (backup, retention, prune, locks, retry, cache) is
identical on both providers; only credential/endpoint resolution differs.

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
- restic >= 0.17 (`--retry-lock`, `--skip-if-unchanged`); **tested with 0.19**.
  `REPACK_SMALLER_THAN` requires restic >= 0.18; the exit-code-aware retry logic
  relies on restic >= 0.19 reporting `backup` exit 3 / SIGINT exit 130 distinctly.
- rclone — used only to verify the in-bucket root dir exists before a run.

### Credentials

**`-c aws` (default)** — nothing is read from rclone.conf. Credentials come from
the standard AWS chain restic understands natively: `AWS_ACCESS_KEY_ID` +
`AWS_SECRET_ACCESS_KEY`, or `AWS_PROFILE` + `~/.aws/credentials`. The endpoint is
the regional AWS one derived from `AWS_REGION` (default `us-east-1`) — **set
`AWS_REGION` to the bucket's actual region** (or override `S3_ENDPOINT`), or the
run fails the root-dir check against the wrong regional endpoint.

**`-c wasabi`** (sporadic use) — keys and endpoint are read from
`/root/.config/rclone/rclone.conf` (single source of truth with the mount); no
separate AWS config is needed:

```ini
[wasabi]
type = s3
provider = Wasabi
access_key_id = ...
secret_access_key = ...
endpoint = s3.us-east-1.wasabisys.com
```

## Usage

```text
restic_backup_s3.sh [options]

  -z <level>                  Compression level (auto|off|fastest|better|max, default: auto)
  -c|--cloud <provider>       Cloud provider: aws|wasabi (default: aws)
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
# Nightly: backup + retention for all users (AWS S3, the default;
# creds via AWS_PROFILE or AWS_ACCESS_KEY_ID/SECRET, AWS_REGION = bucket region)
AWS_PROFILE=backup AWS_REGION=us-east-1 \
  restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -r -f

# Against Wasabi instead (keys read from rclone.conf [wasabi])
restic_backup_s3.sh -c wasabi -s /home -b orcd-backup-home -R home3 -r -f

# Monthly: reclaim unreferenced data (on Wasabi, run no more often than the storage minimum)
AWS_PROFILE=backup AWS_REGION=us-east-1 \
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
# AWS credentials must be present in the cron environment (default provider is aws):
AWS_PROFILE=backup
AWS_REGION=us-east-1

# nightly backup + forget at 04:00
0 4 * * *  /root/bin/restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -r -f >> /var/log/restic_backup.log 2>&1
# monthly prune, 1st of the month at 12:00
0 12 1 * * /root/bin/restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -p   >> /var/log/restic_prune.log  2>&1
```

## Environment overrides

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLOUD` | `aws` | Provider (same as `-c`): `aws` or `wasabi` |
| `MAX_JOBS` | `101` | Parallel per-user jobs |
| `PACK_SIZE` | `64` | `--pack-size` (MiB); larger packs = fewer objects |
| `KEEP_DAILY` / `KEEP_WEEKLY` / `KEEP_MONTHLY` / `KEEP_WITHIN` | `7` / `1` / `0` / `7d` | Retention policy (see below) |
| `RETRY_LOCK` | `5m` | restic `--retry-lock`: wait for competing repo locks |
| `RETRIES` / `RETRY_DELAY` | `2` / `15` | Extra attempts per target / seconds between them |
| `MAX_UNUSED` | `unlimited` | Prune `--max-unused` (`unlimited` = no unused-space repack, fastest) |
| `MAX_REPACK_SIZE` | unset | Prune `--max-repack-size` cap per run |
| `REPACK_SMALLER_THAN` | unset | Prune `--repack-smaller-than` (e.g. `1B` to suppress small-pack repacking; see below) |
| `S3_CONNECTIONS` | `5` | restic `-o s3.connections` per process |
| `S3_ENDPOINT` | provider default | Endpoint URL (wasabi: from rclone.conf; aws: `https://s3.<region>.amazonaws.com`) |
| `RCLONE_CONF` | `/root/.config/rclone/rclone.conf` | `[wasabi]` keys/endpoint source |
| `RCLONE_REMOTE` | `wasabi` | rclone.conf section to read (wasabi mode) |
| `AWS_REGION` | `us-east-1` | aws mode: region for the endpoint (or `AWS_DEFAULT_REGION`) |
| `AWS_PROFILE` | unset | aws mode: profile in `~/.aws/credentials` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | unset | Explicit keys (override rclone.conf / `AWS_PROFILE`) |
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
5. **Lock retry + unlock-between-retries** — transient repo-lock collisions and
   network/S3 errors are absorbed (`--retry-lock` plus an unlock + retry).
   Non-transient failures fail fast instead of wasting retries: `backup` exit 3
   (missing/unreadable source) and exit 130 (SIGINT) are not retried — but are
   still recorded in the failure summary. (`forget` exit 3 is still retried, as it
   can be a transient lock/backend issue.)

## Retention, pruning, and billing

Default policy (all env-overridable):
`--keep-daily 7 --keep-weekly 1 --keep-monthly 0 --keep-within 7d`.

These defaults are tuned for **AWS S3 Standard**, which has no minimum storage
period, so shorter retention directly lowers stored GB-months.

**On Wasabi, raise `KEEP_WITHIN` to at least the minimum storage period** (30
days for reserved capacity, 90 for pay-as-you-go). Otherwise the monthly `prune`
deletes pack files younger than that minimum and they are billed as *timed
deleted storage*. A Wasabi-appropriate policy, for example:

```bash
KEEP_DAILY=30 KEEP_WEEKLY=4 KEEP_MONTHLY=3 KEEP_WITHIN=30d \
  restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -f
```

`forget` (cheap, metadata-only) and `prune` (expensive, deletes/repacks data)
are deliberately separate modes: forget nightly, prune monthly.

### Small-pack repacking (restic >= 0.19)

restic 0.19 repacks small pack files more aggressively *by default*. This
consolidation is independent of `--max-unused`, so even with
`MAX_UNUSED=unlimited` a prune downloads + re-uploads more small packs than on
0.17/0.18 — extra bandwidth and S3 request / Wasabi deleted-storage cost on every
prune. Set `REPACK_SMALLER_THAN` to pin it: a small value (e.g. `1B`) suppresses
small-pack repacking (cheapest prune, but small packs accumulate over time); a
larger value (e.g. `16M`) consolidates more (higher upfront cost, fewer objects).
Confirm the repack volume with `restic prune --dry-run` before settling on a value.

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

For an **AWS** repo, use the regional endpoint and AWS credentials instead, e.g.
`-r s3:https://s3.us-east-1.amazonaws.com/orcd-backup-home/home3/alice` with
`AWS_PROFILE`/`AWS_ACCESS_KEY_ID` exported.

## Logs

Per-user logs are written to `$TMP/log/` (default `/db/temp/log/`) as
`<bucket-component>-<root>_<user>-{backup,forget,prune,init}.log`. The script
prints a failure summary and exits `1` if any target failed, `0` otherwise.
