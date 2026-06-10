#!/bin/bash
#
# Native S3-backend variant of restic_backup.sh: talks to Wasabi DIRECTLY via restic's
# s3: backend instead of through the rclone VFS mount. This eliminates the temp-file
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
## RUN example (backup): /root/bin/restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -r
## RUN example (forget): /root/bin/restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -f
## RUN example (prune) : /root/bin/restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -p
## RUN example (ad hoc, single user):
##                        /root/bin/restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -u alice -r -f
## RUN example (ad hoc while the scheduled run is in progress; bypasses the global lock,
##              takes per-user locks instead; only valid together with -u):
##                        /root/bin/restic_backup_s3.sh -s /home -b orcd-backup-home -R home3 -u alice -n -r
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

# Wasabi with reserved capacity has a 30-day minimum storage period. Objects deleted before
# 30 days are still billed for the full period and show as "deleted" in Wasabi's dashboard.
# (Pay-as-you-go accounts have a 90-day minimum; if applicable, raise retention accordingly.)
KEEP_DAILY=30

KEEP_WEEKLY=4

KEEP_MONTHLY=3

PASS_FILE="${PASS_FILE:-$HOME/.backup_pass}"

COMPRESSION="auto"

SOURCE="/data2/pool/005"

# Wasabi/S3 settings. Credentials and endpoint are read from the same rclone config the
# mount uses, so there is a single source of truth for keys. Override any of these via env.
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

MAX_JOBS="${MAX_JOBS:-90}"

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
    echo "  RCLONE_CONF       rclone config file holding the Wasabi keys (default: /root/.config/rclone/rclone.conf)"
    echo "  RCLONE_REMOTE     rclone remote name to read keys/endpoint from (default: wasabi)"
    echo "  S3_ENDPOINT       Wasabi endpoint URL (default: autodetected from rclone.conf)"
    echo "  S3_CONNECTIONS    restic -o s3.connections per process (default: 5)"
    echo "  RESTIC_CACHE_DIR  restic metadata cache (default: derived from bucket name,"
    echo "                    orcd-backup-<x> -> /stage/backup/<x>/001/restic-cache)"
    echo "  MAX_JOBS          Parallel per-user jobs (default: 90)"
    echo "  PACK_SIZE         Backup --pack-size in MiB (default: 64)"
    echo "  RETRY_LOCK        restic --retry-lock duration (default: 5m, restic >= 0.16)"
    echo "  MAX_UNUSED        Prune --max-unused value (default: unlimited = no repack, fastest)"
    echo "  MAX_REPACK_SIZE   Prune --max-repack-size value (default: unset = no cap)"
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

if [ ! -r "${RCLONE_CONF}" ]; then
    echo "ERROR: rclone config '${RCLONE_CONF}' is missing or unreadable."
    exit 1
fi

# Derive the restic cache dir from the bucket name: orcd-backup-<x> -> /stage/backup/<x>/001/restic-cache.
# A bucket not matching the orcd-backup-* convention falls back to its full name as <x>.
BUCKET_BASE="${BUCKET%%/*}"                 # strip any optional key prefix after the bucket name
COMPONENT="${BUCKET_BASE#orcd-backup-}"
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/stage/backup/${COMPONENT}/001/restic-cache}"

mkdir -p "${RESTIC_CACHE_DIR}" || { echo "ERROR: cannot create cache dir ${RESTIC_CACHE_DIR}"; exit 1; }

############################################################################################
# #1 Credentials/endpoint: read the [${RCLONE_REMOTE}] section of rclone.conf so the keys
# live in exactly one place. restic's s3 backend takes them from the environment.
############################################################################################
rclone_conf_get() {
    # rclone_conf_get <key> -> value of "key = value" inside the [$RCLONE_REMOTE] section
    awk -F'=' -v section="${RCLONE_REMOTE}" -v key="$1" '
        /^\[/      { in_sec = ($0 == "[" section "]") }
        in_sec && $1 ~ "^[ \t]*" key "[ \t]*$" {
            sub(/^[ \t]+/, "", $2); sub(/[ \t\r]+$/, "", $2); print $2; exit
        }' "${RCLONE_CONF}"
}

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-$(rclone_conf_get access_key_id)}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-$(rclone_conf_get secret_access_key)}"

if [ -z "${S3_ENDPOINT}" ]; then
    S3_ENDPOINT="$(rclone_conf_get endpoint)"
fi
# Normalize: restic wants a URL; rclone.conf often stores a bare hostname.
case "${S3_ENDPOINT}" in
    http://*|https://*) : ;;
    *) S3_ENDPOINT="https://${S3_ENDPOINT}" ;;
esac

if [ -z "${AWS_ACCESS_KEY_ID}" ] || [ -z "${AWS_SECRET_ACCESS_KEY}" ] || [ -z "${S3_ENDPOINT#https://}" ]; then
    echo "ERROR: could not determine S3 credentials/endpoint from '${RCLONE_CONF}' section [${RCLONE_REMOTE}]."
    echo "       Set AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and S3_ENDPOINT explicitly."
    exit 1
fi

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
    first=$("${RCLONE_BIN}" --config "${RCLONE_CONF}" lsf --max-depth 1 \
            "${RCLONE_REMOTE}:${BUCKET%/}/${ROOT_DIR}" 2>/dev/null | head -n 1)

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
# network/S3 errors and leftover locks from killed runs.
# --repo, --password-file, s3.connections and --retry-lock are appended automatically.
# Usage: retry_restic <repo> <logfile> -- <restic args...>
retry_restic() {
    local repo="$1"
    local logfile="$2"
    shift 2
    [ "$1" = "--" ] && shift

    local attempt=1
    local max=$((RETRIES + 1))
    : > "${logfile}"

    while :; do
        if [ "${attempt}" -gt 1 ]; then
            printf '\n--- retry %d/%d ---\n' "$((attempt - 1))" "${RETRIES}" >> "${logfile}"
        fi
        if "${RESTIC}" "$@" --repo "${repo}" --password-file "${PASS_FILE}" -o "s3.connections=${S3_CONNECTIONS}" --retry-lock "${RETRY_LOCK}" >> "${logfile}" 2>&1; then
            return 0
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
    # --keep-within 30d ensures no snapshot younger than 30 days is ever removed,
    # preventing pack files from being eligible for prune before Wasabi's minimum storage period
    # (30 days under reserved capacity).
    local FORGET_OPTS="--keep-daily ${KEEP_DAILY} --keep-weekly ${KEEP_WEEKLY} --keep-monthly ${KEEP_MONTHLY} --keep-within 30d --group-by paths --compact"

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

    if ! "${RESTIC}" cat config --repo "${REPO}" --password-file "${PASS_FILE}" -o "s3.connections=${S3_CONNECTIONS}" > /dev/null 2>&1; then
        echo "Skipping prune for ${USER}: repository not found at ${REPO}"
        return 0
    fi

    echo "Starting prune for user: ${USER} (max-unused=${MAX_UNUSED}${MAX_REPACK_SIZE:+, max-repack-size=${MAX_REPACK_SIZE}})"

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
