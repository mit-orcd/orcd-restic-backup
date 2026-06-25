#!/bin/bash
#
# Native S3-backend variant of restic_backup.sh: talks to the object store DIRECTLY via
# restic's s3: backend instead of through the rclone VFS mount. This eliminates the temp-file
# write+rename of restic's local backend, which on an S3 mount becomes PUT+COPY+DELETE
# and generates "deleted storage" charges roughly equal to every byte uploaded.
# The s3 backend PUTs each object once under its final name: no renames, no VFS cache,
# no stale dir-cache lock errors.
#
# Repo layout is IDENTICAL to the mount-based script: existing repos created under
# /mnt/wasabi_backup_home/<user> are the same objects as s3:.../orcd-backup-home/<user>,
# so this is a drop-in switch (both scripts must not run concurrently on the same repos;
# they use different lock-file names, so rely on scheduling for that).
#
# CLOUD PROVIDERS: the script is vendor-agnostic via -c|--cloud (default: aws).
#   -c wasabi : credentials/endpoint read from the [wasabi] section of rclone.conf
#               (single source of truth with the mount); env vars override.
#   -c aws    : nothing is read from rclone.conf. Credentials come from the standard
#               AWS mechanisms restic understands natively (AWS_ACCESS_KEY_ID/
#               AWS_SECRET_ACCESS_KEY, or AWS_PROFILE + ~/.aws/credentials); the
#               endpoint is the regional AWS one derived from AWS_REGION/
#               AWS_DEFAULT_REGION (default us-east-1). S3_ENDPOINT overrides.
# Everything restic-side (backup, forget/keep retention, prune, locks, retry, cache)
# is plain restic and behaves IDENTICALLY on both providers.
#
## RUN example (backup): /root/bin/restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -r
## RUN example (forget): /root/bin/restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -f
## RUN example (prune) : /root/bin/restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -p
## RUN example (ad hoc, single user):
##                        /root/bin/restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -u alice -r -f
## RUN example (ad hoc while the scheduled run is in progress; bypasses the global lock,
##              takes per-user locks instead; only valid together with -u):
##                        /root/bin/restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -u alice -n -r
##
## The provider defaults to aws, so the examples above need AWS credentials in the
## environment (AWS_PROFILE, or AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY) and AWS_REGION
## set to the bucket's region, e.g.:
##                        AWS_PROFILE=backup AWS_REGION=us-east-1 \
##                        /root/bin/restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -r
## RUN example (Wasabi) : /root/bin/restic_backup_s3.sh -c wasabi -s /home -b orcd-backup-home -R home3 -r
##
## -R is the REQUIRED root dir inside the bucket (the old mount-based equivalent of
##  -d /mnt/wasabi_backup_home/home3). It must already exist in the bucket (i.e. contain at
## least one object) or the script refuses to run, so a typo cannot silently start a brand
## new backup tree / full re-upload. First-ever run: set ALLOW_NEW_ROOT=1 to create it.
##
## Typical schedule: nightly backup+forget (-r -f); monthly prune (-p, >= storage minimum).
############################################################################################
TMP="${TMP:-/db/temp}"

LOG=${TMP}/log

mkdir -p "${LOG}"

cd "${TMP}" || exit 1

# Retention (restic forget --keep-*). Provider-independent: identical snapshots are kept on
# Wasabi and AWS. KEEP_WITHIN additionally protects every snapshot younger than that age.
# Vendor billing note (does not change behavior, only why the defaults are what they are):
#   Wasabi reserved capacity has a 30-day minimum storage period (pay-as-you-go: 90 days) —
#   objects deleted earlier are still billed and show as "deleted storage";
#   AWS S3 Standard has no minimum (S3-IA/Glacier classes do).
KEEP_DAILY="${KEEP_DAILY:-7}"

KEEP_WEEKLY="${KEEP_WEEKLY:-1}"

KEEP_MONTHLY="${KEEP_MONTHLY:-0}"

KEEP_WITHIN="${KEEP_WITHIN:-7d}"

PASS_FILE="${PASS_FILE:-$HOME/.backup_pass}"

COMPRESSION="auto"

SOURCE="/data2/pool/005"

# Cloud provider: aws (default) or wasabi. Also settable via -c|--cloud.
CLOUD="${CLOUD:-aws}"

# AWS region (cloud=aws only): used to derive the regional endpoint when S3_ENDPOINT is not
# set, and exported for restic/rclone. AWS_DEFAULT_REGION is honored as a fallback.
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

# Wasabi settings (cloud=wasabi only). Credentials and endpoint are read from the same rclone
# config the mount uses, so there is a single source of truth for keys. Override via env.
RCLONE_CONF="${RCLONE_CONF:-/root/.config/rclone/rclone.conf}"
RCLONE_REMOTE="${RCLONE_REMOTE:-wasabi}"
RCLONE_BIN="${RCLONE_BIN:-rclone}"      # used only to verify the root dir exists in the bucket
BUCKET="${BUCKET:-orcd-backup-home}"
ROOT_DIR=""                             # REQUIRED (-R): root dir inside the bucket, e.g. home3

# Set ALLOW_NEW_ROOT=1 to bypass the "root dir exists in bucket" safety check (first run only).
ALLOW_NEW_ROOT="${ALLOW_NEW_ROOT:-0}"
S3_ENDPOINT="${S3_ENDPOINT:-}"          # autodetected from rclone.conf if empty
S3_CONNECTIONS="${S3_CONNECTIONS:-5}"   # restic-internal parallel connections per process

RESTIC="${RESTIC:-/usr/local/bin/restic}"

# Restic's metadata cache is kept off the root FS and is derived from the bucket name AFTER
# argument parsing: orcd-backup-<x>  ->  /stage/backup/<x>/001/restic-cache
# (e.g. orcd-backup-home -> /stage/backup/home/001/restic-cache,
#       orcd-backup-software -> /stage/backup/software/001/restic-cache).
# Override explicitly with RESTIC_CACHE_DIR.

MAX_JOBS="${MAX_JOBS:-101}"

# Pack size in MiB (restic >= 0.14). Larger packs = far fewer objects on Wasabi, which
# reduces object churn, per-object overhead and "deleted storage" from lock/tmp turnover.
PACK_SIZE="${PACK_SIZE:-64}"

# Native lock retry (restic >= 0.16): wait up to this long for a competing lock to go away
# before failing. Complements (and mostly replaces) the manual unlock/sleep retry below.
RETRY_LOCK="${RETRY_LOCK:-5m}"

# Prune tuning. On remote/object storage (e.g. Wasabi) repacking partially-used pack files
# requires download + re-upload and is slow/expensive. MAX_UNUSED=unlimited skips repacking
# and only deletes fully-unreferenced packs (fast, minimal bandwidth); space is reclaimed
# lazily as packs become fully unused. MAX_REPACK_SIZE optionally caps repack volume per run
# (set e.g. 50G to chip away incrementally; empty = no cap). See restic docs "Customize pruning".
MAX_UNUSED="${MAX_UNUSED:-unlimited}"
MAX_REPACK_SIZE="${MAX_REPACK_SIZE:-}"

# Small-pack repacking (restic >= 0.18 flag; restic >= 0.19 repacks small packs MORE
# aggressively by default). This consolidation is INDEPENDENT of --max-unused, so on remote
# object storage it adds download+re-upload (bandwidth + S3 request / Wasabi "deleted storage"
# cost) to every prune even with --max-unused unlimited. Set REPACK_SMALLER_THAN to pin the
# behavior explicitly instead of inheriting the (version-dependent) default:
#   - a small value (e.g. 1B) effectively suppresses small-pack repacking -> cheapest prune,
#     but small packs accumulate over time (more objects, more per-object overhead);
#   - a larger value (e.g. 16M) consolidates more -> higher upfront prune cost, fewer objects.
# Empty = inherit restic's default. Always confirm the repack volume with `prune --dry-run`
# before settling on a value. See restic docs "Customize pruning".
REPACK_SMALLER_THAN="${REPACK_SMALLER_THAN:-}"

# Retry handling for transient network/S3 errors. RETRIES = additional attempts after the
# first; RETRY_DELAY = seconds between them, with an unlock in between.
RETRIES="${RETRIES:-2}"
RETRY_DELAY="${RETRY_DELAY:-15}"

RUN=false
FORGET=false
PRUNE=false

# Ad hoc target list from -u/--user; empty = enumerate all users under SOURCE.
USERS_CLI=()

# -n/--no-flock: bypass the global per-bucket+root single-instance lock. Only allowed
# together with -u; per-user locks are taken instead so two runs can never operate on the
# same user repo concurrently.
NO_FLOCK=false

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -z <level>                  Set compression level (auto|off|fastest|better|max, default: auto)"
    echo "  -c|--cloud <provider>       Cloud provider: aws|wasabi (default: ${CLOUD})"
    echo "                              aws:    keys from AWS_PROFILE or AWS_ACCESS_KEY_ID/"
    echo "                                      AWS_SECRET_ACCESS_KEY; endpoint from AWS_REGION"
    echo "                              wasabi: keys/endpoint from rclone.conf [${RCLONE_REMOTE}] section"
    echo "  -s|--source <dir>           Set source directory to backup (default: ${SOURCE})"
    echo "  -b|--bucket <bucket[/pfx]>  Set destination bucket (and optional prefix) (default: ${BUCKET})"
    echo "  -R|--root-dir <dir>         REQUIRED: root dir inside the bucket (e.g. home3);"
    echo "                              must already exist in the bucket unless ALLOW_NEW_ROOT=1"
    echo "  -u|--user <name>            Run for this user only (repeatable: -u alice -u bob);"
    echo "                              default: all dirs under the source (except restore*)"
    echo "  -n|--no-flock               Bypass the global single-instance lock (requires -u);"
    echo "                              per-user locks are taken instead. Lets an ad hoc run"
    echo "                              proceed while a scheduled full run is in progress."
    echo "  -r|--run                    Execute the backup"
    echo "  -f|--forget                 Apply retention policy only (remove snapshots, NO prune)"
    echo "  -p|--prune                  Reclaim data (prune); safe for large repos, run monthly"
    echo ""
    echo "  -r, -f and -p may be combined; at least one is required."
    echo "  Order when combined: backup -> forget -> prune."
    echo ""
    echo "Environment overrides:"
    echo "  CLOUD             Same as -c (default: aws)"
    echo "  RCLONE_CONF       [wasabi] rclone config file holding the keys (default: /root/.config/rclone/rclone.conf)"
    echo "  RCLONE_REMOTE     [wasabi] rclone remote name to read keys/endpoint from (default: wasabi)"
    echo "  AWS_PROFILE       [aws] profile in ~/.aws/credentials used by restic (env_auth)"
    echo "  AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY"
    echo "                    Explicit keys; override rclone.conf (wasabi) / AWS_PROFILE (aws)"
    echo "  AWS_REGION        [aws] region for the endpoint (default: AWS_DEFAULT_REGION or us-east-1)"
    echo "  S3_ENDPOINT       Endpoint URL (default: wasabi: from rclone.conf; aws: regional"
    echo "                    https://s3.<region>.amazonaws.com). Set explicitly for other S3 vendors."
    echo "  S3_CONNECTIONS    restic -o s3.connections per process (default: 5)"
    echo "  RESTIC_CACHE_DIR  restic metadata cache (default: derived from bucket name,"
    echo "                    orcd-backup-<x> -> /stage/backup/<x>/001/restic-cache)"
    echo "  MAX_JOBS          Parallel per-user jobs (default: 101)"
    echo "  PACK_SIZE         Backup --pack-size in MiB (default: 64)"
    echo "  RETRY_LOCK        restic --retry-lock duration (default: 5m, restic >= 0.16)"
    echo "  MAX_UNUSED        Prune --max-unused value (default: unlimited = no repack, fastest)"
    echo "  MAX_REPACK_SIZE   Prune --max-repack-size value (default: unset = no cap)"
    echo "  REPACK_SMALLER_THAN  Prune --repack-smaller-than value, e.g. 1B to suppress small-pack"
    echo "                    repacking (restic >= 0.19 repacks small packs aggressively by default;"
    echo "                    default: unset = inherit restic's default). Verify with prune --dry-run."
    echo "  KEEP_DAILY/KEEP_WEEKLY/KEEP_MONTHLY/KEEP_WITHIN"
    echo "                    Retention policy (defaults: 30/4/3/30d); identical on all providers"
    echo "  RETRIES           Extra attempts per target after the first (default: 2)"
    echo "  RETRY_DELAY       Seconds between attempts, with an unlock in between (default: 15)"
    echo "  ALLOW_NEW_ROOT=1  Bypass the root-dir-exists-in-bucket safety check (first run)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -z|--compress)
            COMPRESSION="$2"
            shift 2
            ;;
        -c|--cloud)
            CLOUD="$2"
            shift 2
            ;;
        -s|--source)
            SOURCE="$2"
            shift 2
            ;;
        -b|--bucket)
            BUCKET="$2"
            shift 2
            ;;
        -R|--root-dir)
            ROOT_DIR="$2"
            shift 2
            ;;
        -u|--user)
            USERS_CLI+=("$2")
            shift 2
            ;;
        -n|--no-flock)
            NO_FLOCK=true
            shift
            ;;
        -r|--run)
            RUN=true
            shift
            ;;
        -f|--forget)
            FORGET=true
            shift
            ;;
        -p|--prune)
            PRUNE=true
            shift
            ;;
        *)
            usage
            ;;
    esac
done

if ! $RUN && ! $FORGET && ! $PRUNE; then
    usage
fi

# Normalize/validate the cloud provider.
CLOUD="${CLOUD,,}"
case "${CLOUD}" in
    wasabi|aws) : ;;
    *)
        echo "ERROR: unsupported cloud provider '${CLOUD}' (supported: wasabi, aws)."
        usage
        ;;
esac

# Normalize and require the in-bucket root dir.
ROOT_DIR="${ROOT_DIR#/}"; ROOT_DIR="${ROOT_DIR%/}"
if [ -z "${ROOT_DIR}" ]; then
    echo "ERROR: root dir inside the bucket is required (-R <dir>, e.g. -R home3)."
    usage
fi

# -n is only safe for targeted runs: without -u it would allow two full runs to overlap.
if $NO_FLOCK && [ "${#USERS_CLI[@]}" -eq 0 ]; then
    echo "ERROR: -n|--no-flock requires at least one -u <user>."
    usage
fi

############################################################################################
# #0 Preflight: fail fast on missing prerequisites instead of N parallel confusing errors.
############################################################################################
if [ ! -x "${RESTIC}" ]; then
    echo "ERROR: restic binary not found/executable at '${RESTIC}'."
    exit 1
fi

if [ ! -r "${PASS_FILE}" ]; then
    echo "ERROR: password file '${PASS_FILE}' is missing or unreadable."
    exit 1
fi

if [ ! -d "${SOURCE}" ]; then
    echo "ERROR: source directory '${SOURCE}' does not exist."
    exit 1
fi

# rclone.conf is only the credential source for wasabi, and only when the keys are not
# already supplied via environment. aws mode never touches rclone.conf.
if [ "${CLOUD}" = "wasabi" ] && { [ -z "${AWS_ACCESS_KEY_ID}" ] || [ -z "${AWS_SECRET_ACCESS_KEY}" ] || [ -z "${S3_ENDPOINT}" ]; }; then
    if [ ! -r "${RCLONE_CONF}" ]; then
        echo "ERROR: rclone config '${RCLONE_CONF}' is missing or unreadable."
        echo "       (Needed to read Wasabi keys/endpoint; or set AWS_ACCESS_KEY_ID,"
        echo "       AWS_SECRET_ACCESS_KEY and S3_ENDPOINT explicitly.)"
        exit 1
    fi
fi

# Derive the restic cache dir from the bucket name: orcd-backup-<x> -> /stage/backup/<x>/001/restic-cache.
# A bucket not matching the orcd-backup-* convention falls back to its full name as <x>.
BUCKET_BASE="${BUCKET%%/*}"                 # strip any optional key prefix after the bucket name
COMPONENT="${BUCKET_BASE#orcd-backup-}"
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/stage/backup/${COMPONENT}/001/restic-cache}"

mkdir -p "${RESTIC_CACHE_DIR}" || { echo "ERROR: cannot create cache dir ${RESTIC_CACHE_DIR}"; exit 1; }

############################################################################################
# #1 Credentials/endpoint, per provider. restic's s3 backend takes everything from the
# environment, so both branches end with the same contract: S3_ENDPOINT set, and either
# AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY exported or AWS_PROFILE left for restic to use.
############################################################################################
rclone_conf_get() {
    # rclone_conf_get <key> -> value of "key = value" inside the [$RCLONE_REMOTE] section
    awk -F'=' -v section="${RCLONE_REMOTE}" -v key="$1" '
        /^\[/      { in_sec = ($0 == "[" section "]") }
        in_sec && $1 ~ "^[ \t]*" key "[ \t]*$" {
            sub(/^[ \t]+/, "", $2); sub(/[ \t\r]+$/, "", $2); print $2; exit
        }' "${RCLONE_CONF}"
}

case "${CLOUD}" in
    wasabi)
        # Keys/endpoint from rclone.conf (single source of truth with the mount); env overrides.
        export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-$(rclone_conf_get access_key_id)}"
        export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-$(rclone_conf_get secret_access_key)}"

        if [ -z "${S3_ENDPOINT}" ]; then
            S3_ENDPOINT="$(rclone_conf_get endpoint)"
        fi

        if [ -z "${AWS_ACCESS_KEY_ID}" ] || [ -z "${AWS_SECRET_ACCESS_KEY}" ] || [ -z "${S3_ENDPOINT}" ]; then
            echo "ERROR: could not determine S3 credentials/endpoint from '${RCLONE_CONF}' section [${RCLONE_REMOTE}]."
            echo "       Set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and S3_ENDPOINT explicitly."
            exit 1
        fi
        ;;
    aws)
        # Standard AWS credential chain, handled by restic itself (and rclone env_auth for
        # the root-dir check): explicit env keys win; otherwise AWS_PROFILE/~/.aws/credentials.
        # Nothing is read from rclone.conf.
        export AWS_REGION AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION}}"

        if [ -z "${S3_ENDPOINT}" ]; then
            S3_ENDPOINT="https://s3.${AWS_REGION}.amazonaws.com"
        fi

        if [ -z "${AWS_ACCESS_KEY_ID}" ] || [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
            if [ -z "${AWS_PROFILE}" ]; then
                echo "ERROR: no AWS credentials: set AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY,"
                echo "       or AWS_PROFILE pointing at a profile in ~/.aws/credentials."
                exit 1
            fi
            if [ ! -r "${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}" ]; then
                echo "ERROR: AWS_PROFILE='${AWS_PROFILE}' set but '${AWS_SHARED_CREDENTIALS_FILE:-$HOME/.aws/credentials}' is missing or unreadable."
                exit 1
            fi
            export AWS_PROFILE
        fi
        ;;
esac

# Normalize: restic wants a URL; configs often store a bare hostname.
case "${S3_ENDPOINT}" in
    http://*|https://*) : ;;
    *) S3_ENDPOINT="https://${S3_ENDPOINT}" ;;
esac

# Repo prefix; per-user repo = ${REPO_PREFIX}/<user>. Identical object layout to the repos
# previously reached through the rclone mount of the same bucket, e.g.
# /mnt/wasabi_backup_home/home3/<user>  ==  s3:.../orcd-backup-home/home3/<user>
REPO_PREFIX="s3:${S3_ENDPOINT}/${BUCKET%/}/${ROOT_DIR}"

# Lock/log suffix: <bucket-component>-<root-dir>, e.g. home-home3.
SFX="${COMPONENT}-${ROOT_DIR//\//_}"

############################################################################################
# #1b Root-dir safety check (replaces the old "destination mount" check): refuse to run if
# the root dir does not exist in the bucket (= contains no objects). This prevents a typo in
# -b/-R from silently creating a new empty tree and re-uploading every user from scratch.
# Run BEFORE acquiring the lock, like the old mount check.
############################################################################################
check_root_dir_exists() {
    if ! command -v "${RCLONE_BIN}" > /dev/null 2>&1; then
        echo "ERROR: '${RCLONE_BIN}' not found; cannot verify root dir '${ROOT_DIR}' exists in"
        echo "       bucket '${BUCKET}'. Install rclone or set ALLOW_NEW_ROOT=1 to skip the check."
        return 1
    fi

    local first
    if [ "${CLOUD}" = "aws" ]; then
        # On-the-fly rclone remote (no rclone.conf needed): env_auth picks up the same
        # AWS env keys / AWS_PROFILE that restic uses. Endpoint given without scheme to
        # keep the connection string free of ':' (which would require quoting).
        first=$("${RCLONE_BIN}" lsf --max-depth 1 \
                ":s3,provider=AWS,env_auth=true,region=${AWS_REGION},endpoint=${S3_ENDPOINT#*://}:${BUCKET%/}/${ROOT_DIR}" \
                2>/dev/null | head -n 1)
    else
        first=$("${RCLONE_BIN}" --config "${RCLONE_CONF}" lsf --max-depth 1 \
                "${RCLONE_REMOTE}:${BUCKET%/}/${ROOT_DIR}" 2>/dev/null | head -n 1)
    fi

    if [ -z "${first}" ]; then
        echo "ERROR: root dir '${ROOT_DIR}' does not exist (or is empty) in bucket '${BUCKET}'."
        echo "       Refusing to run so a typo cannot start a brand new backup tree."
        echo "       For a genuine first run, set ALLOW_NEW_ROOT=1 to create it."
        return 1
    fi

    return 0
}

if [ "${ALLOW_NEW_ROOT}" != "1" ]; then
    check_root_dir_exists || exit 1
fi

############################################################################################
# #2 Single-instance lock: prevent overlapping runs against the same destination bucket.
# Two concurrent runs writing to the same restic repos can corrupt them. The lock is keyed
# on the bucket so different destinations can still run in parallel.
############################################################################################
if ! $NO_FLOCK; then
    LOCK_FILE="${TMP}/.restic_backup.${SFX}.lock"
    exec 200>"${LOCK_FILE}" || { echo "ERROR: cannot open lock file ${LOCK_FILE}"; exit 1; }
    if ! flock -n 200; then
        echo "ERROR: another run for bucket '${BUCKET}' (root '${ROOT_DIR}') is already in progress."
        echo "       For an ad hoc run alongside it, use -n together with -u <user>. Exiting."
        exit 1
    fi
else
    # Global lock bypassed: take a per-user lock for each -u target instead, so two runs can
    # never operate on the same user repo at the same time. The fds (auto-allocated) stay open
    # for the lifetime of the script, holding the locks. Note: a -n run CAN overlap the
    # scheduled full run; concurrent backups of the same repo are tolerated by restic
    # (non-exclusive locks), and exclusive ops (forget/prune) wait via --retry-lock.
    echo "NOTE: global single-instance lock bypassed (-n); using per-user locks."
    for u in "${USERS_CLI[@]}"; do
        ulock="${TMP}/.restic_backup.${SFX}.user.${u// /_}.lock"
        exec {ulock_fd}>"${ulock}" || { echo "ERROR: cannot open lock file ${ulock}"; exit 1; }
        if ! flock -n "${ulock_fd}"; then
            echo "ERROR: another ad hoc run for user '${u}' (${SFX}) is already in progress. Exiting."
            exit 1
        fi
    done
fi

############################################################################################
# #3 Failure tracking: background jobs cannot easily propagate exit codes, so each failed
# target appends its name to a per-run failure log. Short appends (< PIPE_BUF) are atomic on
# POSIX, so concurrent writes from parallel jobs are safe. The script exits non-zero with a
# summary if anything failed.
############################################################################################
FAIL_LOG="${TMP}/.failures.${SFX}.$$"
: > "${FAIL_LOG}"
trap 'rm -f "${FAIL_LOG}"' EXIT

record_failure() {
    echo "$1" >> "${FAIL_LOG}"
}

# Returns 0 if the repository already exists; otherwise tries to initialize it.
# Distinguishes "repo absent" from transient errors to avoid calling init on an existing repo.
ensure_repo() {
    local REPO="$1"
    local USER="$2"

    local out rc
    out=$("${RESTIC}" cat config --repo "${REPO}" --password-file "${PASS_FILE}" -o "s3.connections=${S3_CONNECTIONS}" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then return 0; fi

    # Only init when the repo is genuinely absent; any other failure propagates as-is.
    if echo "${out}" | grep -qiE "no such file|repository does not exist|does not exist, is it accessible|Is there a repository|unable to open config file|key does not exist|404"; then
        "${RESTIC}" init --repo "${REPO}" --password-file "${PASS_FILE}" -o "s3.connections=${S3_CONNECTIONS}" > "${LOG}/${SFX}_${USER}-init.log" 2>&1
        return $?
    fi

    echo "${out}" > "${LOG}/${SFX}_${USER}-init.log"
    return $rc
}

# Run a restic command with retries, clearing locks between attempts. This absorbs transient
# network/S3 errors and leftover locks from killed runs (which surface as generic exit code 1).
# Some exit codes are NOT transient and retrying only wastes an unlock+sleep per attempt, so
# they fail fast (the failure is still reported by the caller). With restic >= 0.19 these are
# reported distinctly (previously masked as exit 0):
#   - backup exit 3 : a source path is missing/unreadable (incomplete snapshot); re-running
#                     yields the same result, so do not retry (Fix #4467).
#   - exit 130      : interrupted by SIGINT (Ctrl-C / shutdown); abort rather than retry (Fix #5258).
# (forget exit 3, "failed to remove snapshots", CAN be a transient backend/lock issue, so it is
#  still retried.)
# --repo, --password-file, s3.connections and --retry-lock are appended automatically.
# Usage: retry_restic <repo> <logfile> -- <restic args...>
retry_restic() {
    local repo="$1"
    local logfile="$2"
    shift 2
    [ "$1" = "--" ] && shift
    local subcmd="$1"

    local attempt=1
    local max=$((RETRIES + 1))
    local rc
    : > "${logfile}"

    while :; do
        if [ "${attempt}" -gt 1 ]; then
            printf '\n--- retry %d/%d ---\n' "$((attempt - 1))" "${RETRIES}" >> "${logfile}"
        fi
        "${RESTIC}" "$@" --repo "${repo}" --password-file "${PASS_FILE}" -o "s3.connections=${S3_CONNECTIONS}" --retry-lock "${RETRY_LOCK}" >> "${logfile}" 2>&1
        rc=$?
        if [ "${rc}" -eq 0 ]; then
            return 0
        fi

        # Non-transient exit codes: retrying cannot help, so fail fast.
        if [ "${rc}" -eq 130 ] || { [ "${subcmd}" = "backup" ] && [ "${rc}" -eq 3 ]; }; then
            echo "  not retrying ${subcmd} for repo ${repo}: exit ${rc} is non-transient (see ${logfile})"
            echo "  not retrying ${subcmd}: exit ${rc} is non-transient" >> "${logfile}"
            return "${rc}"
        fi

        if [ "${attempt}" -ge "${max}" ]; then
            return 1
        fi

        echo "  retry ${attempt}/${RETRIES} for repo ${repo} after failure (see ${logfile}); unlocking and waiting ${RETRY_DELAY}s"
        # Clear stale locks before the next attempt.
        "${RESTIC}" unlock --repo "${repo}" --password-file "${PASS_FILE}" -o "s3.connections=${S3_CONNECTIONS}" > /dev/null 2>&1
        sleep "${RETRY_DELAY}"
        attempt=$((attempt + 1))
    done
}

backup_user() {
    local USER="$1"
    local TS
    TS=$(date +%Y%m%d-%H%M%S)
    local TAG="backup-${TS}"
    local REPO="${REPO_PREFIX}/${USER}"
    local RESTIC_OPTS="--compression ${COMPRESSION} --pack-size ${PACK_SIZE} --verbose --skip-if-unchanged"

    echo "Starting backup for user: ${USER} with compression: ${COMPRESSION}"

    cd "${SOURCE}" || { echo "Failed to cd to ${SOURCE} for user ${USER}"; record_failure "${USER} (cd-source)"; return 1; }

    if ! ensure_repo "${REPO}" "${USER}"; then
        echo "Repo init failed for ${USER}. Check ${LOG}/${SFX}_${USER}-init.log"
        record_failure "${USER} (init)"
        return 1
    fi

    # Remove stale locks only (e.g. from a killed previous run). Safe because the flock above
    # guarantees no other instance of this script is running against the same bucket.
    "${RESTIC}" unlock --repo "${REPO}" --password-file "${PASS_FILE}" -o "s3.connections=${S3_CONNECTIONS}" > /dev/null 2>&1

    if ! retry_restic "${REPO}" "${LOG}/${SFX}_${USER}-backup.log" -- backup --tag "${TAG}" "./${USER}" ${RESTIC_OPTS}; then
        echo "Backup failed for ${SFX} : ${USER}. Check ${LOG}/${SFX}_${USER}-backup.log"
        record_failure "${USER} (backup)"
        return 1
    fi

    echo "Backup completed for ${SFX} : ${USER}. Tag: ${TAG}"
}

# Retention policy only: removes snapshots per the keep-* policy but does NOT reclaim data.
# Cheap (metadata only) and safe to run often (e.g. daily, alongside backups). Does not create
# repos; missing repos are skipped.
forget_user() {
    local USER="$1"
    local REPO="${REPO_PREFIX}/${USER}"
    # --keep-within ${KEEP_WITHIN} ensures no snapshot younger than that is ever removed.
    # Identical on every provider; the default (30d) is sized so packs cannot become eligible
    # for prune before Wasabi's reserved-capacity minimum storage period. On AWS S3 Standard
    # it is simply extra snapshot safety with no billing significance.
    local FORGET_OPTS="--keep-daily ${KEEP_DAILY} --keep-weekly ${KEEP_WEEKLY} --keep-monthly ${KEEP_MONTHLY} --keep-within ${KEEP_WITHIN} --group-by paths --compact"

    if ! "${RESTIC}" cat config --repo "${REPO}" --password-file "${PASS_FILE}" -o "s3.connections=${S3_CONNECTIONS}" > /dev/null 2>&1; then
        echo "Skipping forget for ${USER}: repository not found at ${REPO}"
        return 0
    fi

    echo "Starting forget for user: ${USER}"

    if ! retry_restic "${REPO}" "${LOG}/${SFX}_${USER}-forget.log" -- forget ${FORGET_OPTS}; then
        echo "Forget failed for ${SFX} : ${USER}. Check ${LOG}/${SFX}_${USER}-forget.log"
        record_failure "${USER} (forget)"
        return 1
    fi

    echo "Forget completed for ${SFX} : ${USER}."
}

# Data reclamation: physically removes data no longer referenced by any snapshot. This is the
# expensive operation on remote storage (repacking = download + re-upload), so it is gated to
# its own mode and tuned via MAX_UNUSED/MAX_REPACK_SIZE to stay safe for very large repos.
# Intended to run on a separate, infrequent schedule (e.g. monthly, >= storage minimum).
# Does not create repos; missing repos are skipped.
prune_user() {
    local USER="$1"
    local REPO="${REPO_PREFIX}/${USER}"
    local PRUNE_OPTS="--max-unused ${MAX_UNUSED} --verbose"

    if [ -n "${MAX_REPACK_SIZE}" ]; then
        PRUNE_OPTS="${PRUNE_OPTS} --max-repack-size ${MAX_REPACK_SIZE}"
    fi
    if [ -n "${REPACK_SMALLER_THAN}" ]; then
        PRUNE_OPTS="${PRUNE_OPTS} --repack-smaller-than ${REPACK_SMALLER_THAN}"
    fi

    if ! "${RESTIC}" cat config --repo "${REPO}" --password-file "${PASS_FILE}" -o "s3.connections=${S3_CONNECTIONS}" > /dev/null 2>&1; then
        echo "Skipping prune for ${USER}: repository not found at ${REPO}"
        return 0
    fi

    echo "Starting prune for user: ${USER} (max-unused=${MAX_UNUSED}${MAX_REPACK_SIZE:+, max-repack-size=${MAX_REPACK_SIZE}}${REPACK_SMALLER_THAN:+, repack-smaller-than=${REPACK_SMALLER_THAN}})"

    if ! retry_restic "${REPO}" "${LOG}/${SFX}_${USER}-prune.log" -- prune ${PRUNE_OPTS}; then
        echo "Prune failed for ${SFX} : ${USER}. Check ${LOG}/${SFX}_${USER}-prune.log"
        record_failure "${USER} (prune)"
        return 1
    fi

    echo "Prune completed for ${SFX} : ${USER}."
}

if [ "${#USERS_CLI[@]}" -gt 0 ]; then
    # Ad hoc mode: operate only on the user(s) given via -u. For backup runs the source dir
    # must exist (we would otherwise back up nothing / fail later); for forget/prune-only
    # runs the source dir is not required (the repo-existence check handles missing repos).
    users=("${USERS_CLI[@]}")
    if $RUN; then
        for u in "${users[@]}"; do
            if [ ! -d "${SOURCE}/${u}" ]; then
                echo "ERROR: user directory '${SOURCE}/${u}' does not exist."
                exit 1
            fi
        done
    fi
else
    # Array-based to be safe with unusual directory names (spaces etc.).
    mapfile -t users < <(find -L "${SOURCE}" -maxdepth 1 -mindepth 1 -type d ! -name "restore*" -printf '%f\n' | sort)

    if [ "${#users[@]}" -eq 0 ]; then
        echo "ERROR: no user directories found under '${SOURCE}'."
        exit 1
    fi
fi

# Run the given per-user function across all targets, throttled to MAX_JOBS in parallel.
# Throttle on the actual number of live jobs (robust even when several jobs exit at once,
# where a manual counter combined with 'wait -n' would drift).
run_parallel() {
    local fn="$1"
    local user

    for user in "${users[@]}"; do
        while [ "$(jobs -rp | wc -l)" -ge "${MAX_JOBS}" ]; do
            wait -n
        done
        "${fn}" "${user}" &
    done

    wait
}

if $RUN; then
    echo "=== Backup run for ${SFX} (source ${SOURCE}, repo prefix ${REPO_PREFIX}) ==="
    run_parallel backup_user
fi

if $FORGET; then
    echo "=== Forget run for ${SFX} (source ${SOURCE}) ==="
    run_parallel forget_user
fi

if $PRUNE; then
    echo "=== Prune run for ${SFX} (source ${SOURCE}) ==="
    run_parallel prune_user
fi

############################################################################################
# Final status: report and exit non-zero if any target failed.
############################################################################################
if [ -s "${FAIL_LOG}" ]; then
    fail_count=$(wc -l < "${FAIL_LOG}" | tr -d ' ')
    echo "Completed with ${fail_count} failure(s):"
    sort "${FAIL_LOG}" | sed 's/^/  - /'
    exit 1    # FAIL_LOG removed by the EXIT trap
fi

echo "All operations completed successfully."
exit 0
