#!/bin/bash
#
## RUN example (backup): /root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -r
## RUN example (forget): /root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -f
## RUN example (prune) : /root/bin/restic_backup.sh -s /data2/pool/005 -d /mnt/backup_pool/pool005 -p
##
## Typical schedule: nightly backup+forget (-r -f); monthly prune (-p, >= storage minimum).
############################################################################################
TMP="${TMP:-/db/temp}"

LOG=${TMP}/log

mkdir -p ${LOG}

cd ${TMP} || exit 1

KEEP_DAILY=14

KEEP_WEEKLY=2

PASS_FILE="${PASS_FILE:-$HOME/.backup_pass}"

COMPRESSION="auto"

SOURCE="/data2/pool/005"
DESTINATION="/mnt/backup_pool/pool005"

RESTIC="${RESTIC:-/usr/local/bin/restic}"

MAX_JOBS=180

# Prune tuning. On remote/object storage (e.g. Wasabi) repacking partially-used pack files
# requires download + re-upload and is slow/expensive. MAX_UNUSED=unlimited skips repacking
# and only deletes fully-unreferenced packs (fast, minimal bandwidth); space is reclaimed
# lazily as packs become fully unused. MAX_REPACK_SIZE optionally caps repack volume per run
# (set e.g. 50G to chip away incrementally; empty = no cap). See restic docs "Customize pruning".
MAX_UNUSED="${MAX_UNUSED:-unlimited}"
MAX_REPACK_SIZE="${MAX_REPACK_SIZE:-}"

RUN=false
FORGET=false
PRUNE=false

# Set ALLOW_ROOT_FS=1 to bypass the "destination not mounted" safety check.
ALLOW_ROOT_FS="${ALLOW_ROOT_FS:-0}"

usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -z <level>                  Set compression level (auto|off|fastest|better|max, default: auto)"
    echo "  -s|--source <dir>           Set source directory to backup (default: ${SOURCE})"
    echo "  -d|--destination <dir>      Set destination root dir to backup (default: ${DESTINATION})"
    echo "  -r|--run                    Execute the backup"
    echo "  -f|--forget                 Apply retention policy only (remove snapshots, NO prune)"
    echo "  -p|--prune                  Reclaim data (prune); safe for large repos, run monthly"
    echo ""
    echo "  -r, -f and -p may be combined; at least one is required."
    echo "  Order when combined: backup -> forget -> prune."
    echo ""
    echo "Environment overrides:"
    echo "  MAX_UNUSED        Prune --max-unused value (default: unlimited = no repack, fastest)"
    echo "  MAX_REPACK_SIZE   Prune --max-repack-size value (default: unset = no cap)"
    echo "  ALLOW_ROOT_FS=1   Bypass the destination mount-point safety check"
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
        -d|--destination)
            DESTINATION="$2"
            shift 2
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

SFX=$(echo ${DESTINATION}|awk -F"/" '{print $NF}')

############################################################################################
# #2 Single-instance lock: prevent overlapping runs against the same destination pool.
# Two concurrent runs writing to the same restic repos can corrupt them. The lock is keyed
# on the destination so different pools can still run in parallel.
############################################################################################
LOCK_FILE="${TMP}/.restic_backup.${SFX}.lock"
exec 200>"${LOCK_FILE}" || { echo "ERROR: cannot open lock file ${LOCK_FILE}"; exit 1; }
if ! flock -n 200; then
    echo "ERROR: another run for destination '${DESTINATION}' is already in progress. Exiting."
    exit 1
fi

############################################################################################
# #1 Destination mount safety check: refuse to run if the destination resolves to the root
# filesystem, which usually means the backup volume is NOT mounted. Without this, restic
# would silently create/write repos on the root disk and fill it.
############################################################################################
check_destination_mounted() {
    local d="${DESTINATION}"

    # Walk up to the nearest path that actually exists (destination may not exist on first run).
    while [ ! -e "${d}" ] && [ "${d}" != "/" ]; do
        d=$(dirname "${d}")
    done

    local mp
    mp=$(stat -c '%m' "${d}" 2>/dev/null)

    if [ -z "${mp}" ]; then
        echo "ERROR: cannot stat destination path '${DESTINATION}'."
        return 1
    fi

    if [ "${mp}" = "/" ]; then
        echo "ERROR: destination '${DESTINATION}' resolves to the root filesystem (mount point '/')."
        echo "       The backup volume does not appear to be mounted. Refusing to run to avoid"
        echo "       filling the root disk. Set ALLOW_ROOT_FS=1 to override."
        return 1
    fi

    return 0
}

if [ "${ALLOW_ROOT_FS}" != "1" ]; then
    check_destination_mounted || exit 1
fi

############################################################################################
# #3 Failure tracking: background jobs cannot easily propagate exit codes, so each failed
# target appends its name to a per-run failure log. Short appends (< PIPE_BUF) are atomic on
# POSIX, so concurrent writes from parallel jobs are safe. The script exits non-zero with a
# summary if anything failed.
############################################################################################
FAIL_LOG="${TMP}/.failures.${SFX}.$$"
: > "${FAIL_LOG}"

record_failure() {
    echo "$1" >> "${FAIL_LOG}"
}

# Returns 0 if the repository already exists; otherwise tries to initialize it.
ensure_repo() {
    local REPO="$1"
    local USER="$2"

    if "${RESTIC}" cat config --repo "${REPO}" --password-file "${PASS_FILE}" > /dev/null 2>&1; then
        return 0
    fi

    "${RESTIC}" init --repo "${REPO}" --password-file "${PASS_FILE}" > "${LOG}/${SFX}_${USER}-init.log" 2>&1
}

backup_user() {
    local USER="$1"
    local TS=$(date +%Y%m%d-%H%M%S)
    local TAG="backup-${TS}"
    local REPO="${DESTINATION}/${USER}"
    local RESTIC_OPTS="--compression ${COMPRESSION} --verbose --skip-if-unchanged"

    echo "Starting backup for user: ${USER} with compression: ${COMPRESSION}"

    cd "${SOURCE}" || { echo "Failed to cd to ${SOURCE} for user ${USER}"; record_failure "${USER} (cd-source)"; return 1; }

    if ! ensure_repo "${REPO}" "${USER}"; then
        echo "Repo init failed for ${USER}. Check ${LOG}/${SFX}_${USER}-init.log"
        record_failure "${USER} (init)"
        return 1
    fi

    # Remove stale locks only. This is safe because the flock above guarantees no other
    # instance of this script is running against the same destination.
    "${RESTIC}" unlock --repo "${REPO}" --password-file "${PASS_FILE}" > /dev/null 2>&1

    if ! "${RESTIC}" backup --repo "${REPO}" --password-file "${PASS_FILE}" --tag "${TAG}" "./${USER}" ${RESTIC_OPTS} > "${LOG}/${SFX}_${USER}-backup.log" 2>&1; then
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
    local REPO="${DESTINATION}/${USER}"
    local FORGET_OPTS="--keep-daily ${KEEP_DAILY} --keep-weekly ${KEEP_WEEKLY}"

    if ! "${RESTIC}" cat config --repo "${REPO}" --password-file "${PASS_FILE}" > /dev/null 2>&1; then
        echo "Skipping forget for ${USER}: repository not found at ${REPO}"
        return 0
    fi

    echo "Starting forget for user: ${USER}"

    # Remove stale locks only (safe under flock; see note in backup_user).
    "${RESTIC}" unlock --repo "${REPO}" --password-file "${PASS_FILE}" > /dev/null 2>&1

    if ! "${RESTIC}" forget --repo "${REPO}" --password-file "${PASS_FILE}" ${FORGET_OPTS} > "${LOG}/${SFX}_${USER}-forget.log" 2>&1; then
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
    local REPO="${DESTINATION}/${USER}"
    local PRUNE_OPTS="--max-unused ${MAX_UNUSED}"

    if [ -n "${MAX_REPACK_SIZE}" ]; then
        PRUNE_OPTS="${PRUNE_OPTS} --max-repack-size ${MAX_REPACK_SIZE}"
    fi

    if ! "${RESTIC}" cat config --repo "${REPO}" --password-file "${PASS_FILE}" > /dev/null 2>&1; then
        echo "Skipping prune for ${USER}: repository not found at ${REPO}"
        return 0
    fi

    echo "Starting prune for user: ${USER} (max-unused=${MAX_UNUSED}${MAX_REPACK_SIZE:+, max-repack-size=${MAX_REPACK_SIZE}})"

    # Remove stale locks only (safe under flock; see note in backup_user).
    "${RESTIC}" unlock --repo "${REPO}" --password-file "${PASS_FILE}" > /dev/null 2>&1

    if ! "${RESTIC}" prune --repo "${REPO}" --password-file "${PASS_FILE}" ${PRUNE_OPTS} > "${LOG}/${SFX}_${USER}-prune.log" 2>&1; then
        echo "Prune failed for ${SFX} : ${USER}. Check ${LOG}/${SFX}_${USER}-prune.log"
        record_failure "${USER} (prune)"
        return 1
    fi

    echo "Prune completed for ${SFX} : ${USER}."
}

users=$(find -L ${SOURCE} -maxdepth 1 -mindepth 1 -type d ! -name "restore*" -printf '%f\n' | sort)

# Run the given per-user function across all targets, throttled to MAX_JOBS in parallel.
run_parallel() {
    local fn="$1"
    local running=0

    for user in $users; do

        "${fn}" "$user" &

        running=$((running + 1))

        if (( running >= MAX_JOBS )); then
            wait -n
            running=$((running - 1))
        fi
    done

    wait
}

if $RUN; then
    echo "=== Backup run for ${SFX} (source ${SOURCE}) ==="
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
    rm -f "${FAIL_LOG}"
    exit 1
fi

rm -f "${FAIL_LOG}"
echo "All operations completed successfully."
exit 0
