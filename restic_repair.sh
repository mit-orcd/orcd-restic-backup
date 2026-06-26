#!/bin/bash
#
# Standalone repair companion to restic_backup_s3.sh.
#
# Purpose: after a prune run, some per-user repos may fail with missing-pack /
# "index is not complete" / "Data seems to be missing" errors (typically fallout
# from the old rclone-mount PUT+COPY+DELETE era). This script collects those
# failed repos and repairs each one, then prunes it.
#
# It can be run two ways:
#   * chained right after the prune run (it reads the just-written prune logs), or
#   * at any later time (pass an explicit name list with -L/-u, or let it re-scan
#     the prune logs; a healthy repo is detected and skipped, so re-runs are safe).
#
# Per-repo routine (CHECK-GATED so it never damages a healthy repo):
#   1. unlock                         (clear stale locks)
#   2. check                          -> if healthy: skip to prune
#   3. repair index                   (drop references to packs missing from the repo)
#   4. check                          -> if healthy now: skip to prune
#   5. repair snapshots --forget      *** DESTRUCTIVE ***  rewrites damaged snapshots
#                                      WITHOUT the missing files and forgets the
#                                      originals. The lost file content is gone from
#                                      history; the next backup re-captures it from
#                                      the live filesystem. Only runs when steps 2/4
#                                      still report missing data. Use --dry-run to
#                                      preview, or --no-snapshot-repair to disable.
#   6. check + prune
#
# Credentials / endpoint / repo layout are resolved IDENTICALLY to restic_backup_s3.sh
# (same -c/-b/-R, same AWS/Wasabi handling), so the repo URLs line up exactly.
#
## RUN example (after prune, auto-discover failed repos from the prune logs):
##   AWS_PROFILE=orcd AWS_REGION=us-east-2 \
##     /root/bin/restic_repair.sh -c aws -b orcd-backup-home -R home3
## RUN example (preview only, no changes):
##   ... /root/bin/restic_repair.sh -c aws -b orcd-backup-home -R home3 --dry-run
## RUN example (explicit targets, later):
##   ... /root/bin/restic_repair.sh -c aws -b orcd-backup-home -R home3 -u zichende -u alice
## RUN example (capture the failed list now, repair later):
##   ... /root/bin/restic_repair.sh -c aws -b orcd-backup-home -R home3 --save-list /root/repair.queue
##   ... /root/bin/restic_repair.sh -c aws -b orcd-backup-home -R home3 -L /root/repair.queue
############################################################################################
TMP="${TMP:-/db/temp}"
LOG=${TMP}/log
mkdir -p "${LOG}"
cd "${TMP}" || exit 1

PASS_FILE="${PASS_FILE:-$HOME/.backup_pass}"

# Cloud provider: aws (default) or wasabi. Also settable via -c|--cloud.
CLOUD="${CLOUD:-aws}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

RCLONE_CONF="${RCLONE_CONF:-/root/.config/rclone/rclone.conf}"
RCLONE_REMOTE="${RCLONE_REMOTE:-wasabi}"
BUCKET="${BUCKET:-orcd-backup-home}"
ROOT_DIR=""                             # REQUIRED (-R): root dir inside the bucket, e.g. home3
S3_ENDPOINT="${S3_ENDPOINT:-}"
S3_CONNECTIONS="${S3_CONNECTIONS:-5}"

RESTIC="${RESTIC:-/usr/local/bin/restic}"
RETRY_LOCK="${RETRY_LOCK:-5m}"

# Prune tuning (used for the final prune of each repaired repo); mirrors restic_backup_s3.sh.
MAX_UNUSED="${MAX_UNUSED:-unlimited}"
REPACK_SMALLER_THAN="${REPACK_SMALLER_THAN:-}"

# Repair is heavy (index rebuild + tree walks); keep concurrency modest by default.
MAX_JOBS="${MAX_JOBS:-8}"

USERS_CLI=()
LIST_FILE=""
SAVE_LIST=""
DRY_RUN=false
DO_PRUNE=true
NO_SNAPSHOT_REPAIR=false

usage() {
    echo "Usage: $0 -R <root-dir> [options]"
    echo "Repairs per-user restic repos that failed prune with missing-pack / index errors."
    echo ""
    echo "Target selection (default: auto-discover from prune logs in ${LOG}):"
    echo "  -u|--user <name>        Repair this user only (repeatable)"
    echo "  -L|--list <file>        Read names to repair from <file> (one per line; # comments ok)"
    echo "  --save-list <file>      Write the auto-discovered failed names to <file> and exit"
    echo "                          (capture now, repair later) -- makes no changes"
    echo ""
    echo "Repo selection (must match the prune run):"
    echo "  -c|--cloud <provider>   Cloud provider: aws|wasabi (default: ${CLOUD})"
    echo "  -b|--bucket <bucket>    Destination bucket (default: ${BUCKET})"
    echo "  -R|--root-dir <dir>     REQUIRED: root dir inside the bucket (e.g. home3)"
    echo ""
    echo "Behavior:"
    echo "  --dry-run               Show what would happen; preview snapshot repair"
    echo "                          (repair snapshots --dry-run); make NO changes"
    echo "  --no-snapshot-repair    Do unlock + repair index only; never run the destructive"
    echo "                          'repair snapshots --forget' (report repos still damaged)"
    echo "  --no-prune              Skip the final prune of each repaired repo"
    echo ""
    echo "Environment overrides: AWS_PROFILE/AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY,"
    echo "  AWS_REGION, RCLONE_CONF/RCLONE_REMOTE (wasabi), S3_ENDPOINT, S3_CONNECTIONS,"
    echo "  MAX_JOBS (default ${MAX_JOBS}), MAX_UNUSED, REPACK_SMALLER_THAN, RETRY_LOCK, PASS_FILE, TMP."
    echo ""
    echo "WARNING: without --dry-run/--no-snapshot-repair, repos still damaged after an index"
    echo "         rebuild are fixed with 'repair snapshots --forget', which PERMANENTLY drops"
    echo "         the missing files from historical snapshots. The next backup re-captures them."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--cloud)    CLOUD="$2"; shift 2 ;;
        -b|--bucket)   BUCKET="$2"; shift 2 ;;
        -R|--root-dir) ROOT_DIR="$2"; shift 2 ;;
        -u|--user)     USERS_CLI+=("$2"); shift 2 ;;
        -L|--list)     LIST_FILE="$2"; shift 2 ;;
        --save-list)   SAVE_LIST="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --no-snapshot-repair) NO_SNAPSHOT_REPAIR=true; shift ;;
        --no-prune)    DO_PRUNE=false; shift ;;
        -h|--help)     usage ;;
        *)             usage ;;
    esac
done

ROOT_DIR="${ROOT_DIR#/}"; ROOT_DIR="${ROOT_DIR%/}"
if [ -z "${ROOT_DIR}" ]; then
    echo "ERROR: root dir inside the bucket is required (-R <dir>, e.g. -R home3)."
    usage
fi

# Normalize/validate cloud provider.
CLOUD="${CLOUD,,}"
case "${CLOUD}" in
    wasabi|aws) : ;;
    *) echo "ERROR: unsupported cloud provider '${CLOUD}' (supported: wasabi, aws)."; usage ;;
esac

############################################################################################
# Preflight
############################################################################################
if [ ! -x "${RESTIC}" ]; then
    echo "ERROR: restic binary not found/executable at '${RESTIC}'."; exit 1
fi
if [ ! -r "${PASS_FILE}" ]; then
    echo "ERROR: password file '${PASS_FILE}' is missing or unreadable."; exit 1
fi

BUCKET_BASE="${BUCKET%%/*}"
COMPONENT="${BUCKET_BASE#orcd-backup-}"
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/stage/backup/${COMPONENT}/001/restic-cache}"
mkdir -p "${RESTIC_CACHE_DIR}" 2>/dev/null

############################################################################################
# Credentials/endpoint, per provider (identical contract to restic_backup_s3.sh).
############################################################################################
rclone_conf_get() {
    awk -F'=' -v section="${RCLONE_REMOTE}" -v key="$1" '
        /^\[/      { in_sec = ($0 == "[" section "]") }
        in_sec && $1 ~ "^[ \t]*" key "[ \t]*$" {
            sub(/^[ \t]+/, "", $2); sub(/[ \t\r]+$/, "", $2); print $2; exit
        }' "${RCLONE_CONF}"
}

case "${CLOUD}" in
    wasabi)
        if [ ! -r "${RCLONE_CONF}" ]; then
            echo "ERROR: rclone config '${RCLONE_CONF}' is missing or unreadable (needed for wasabi keys)."; exit 1
        fi
        export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-$(rclone_conf_get access_key_id)}"
        export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-$(rclone_conf_get secret_access_key)}"
        [ -z "${S3_ENDPOINT}" ] && S3_ENDPOINT="$(rclone_conf_get endpoint)"
        if [ -z "${AWS_ACCESS_KEY_ID}" ] || [ -z "${AWS_SECRET_ACCESS_KEY}" ] || [ -z "${S3_ENDPOINT}" ]; then
            echo "ERROR: could not determine S3 credentials/endpoint from '${RCLONE_CONF}' section [${RCLONE_REMOTE}]."; exit 1
        fi
        ;;
    aws)
        export AWS_REGION AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION}}"
        [ -z "${S3_ENDPOINT}" ] && S3_ENDPOINT="https://s3.${AWS_REGION}.amazonaws.com"
        if [ -z "${AWS_ACCESS_KEY_ID}" ] || [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
            if [ -z "${AWS_PROFILE}" ]; then
                echo "ERROR: no AWS credentials: set AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY, or AWS_PROFILE."; exit 1
            fi
            export AWS_PROFILE
        fi
        ;;
esac

case "${S3_ENDPOINT}" in
    http://*|https://*) : ;;
    *) S3_ENDPOINT="https://${S3_ENDPOINT}" ;;
esac

REPO_PREFIX="s3:${S3_ENDPOINT}/${BUCKET%/}/${ROOT_DIR}"
SFX="${COMPONENT}-${ROOT_DIR//\//_}"

############################################################################################
# Single-instance lock (one repair run per bucket+root at a time).
############################################################################################
LOCK_FILE="${TMP}/.restic_repair.${SFX}.lock"
exec 200>"${LOCK_FILE}" || { echo "ERROR: cannot open lock file ${LOCK_FILE}"; exit 1; }
if ! flock -n 200; then
    echo "ERROR: another repair run for bucket '${BUCKET}' (root '${ROOT_DIR}') is already in progress."; exit 1
fi

############################################################################################
# Failure tracking
############################################################################################
FAIL_LOG="${TMP}/.repair_failures.${SFX}.$$"
: > "${FAIL_LOG}"
trap 'rm -f "${FAIL_LOG}"' EXIT
record_failure() { echo "$1" >> "${FAIL_LOG}"; }

log_both() { local f="$1"; shift; echo "$*"; echo "$*" >> "${f}"; }

# Discover repos that failed prune by scanning their prune logs for integrity signatures.
discover_from_logs() {
    local f name
    shopt -s nullglob
    for f in "${LOG}/${SFX}_"*"-prune.log"; do
        if grep -qiE 'packs from index missing in repo|index is not complete|Data seems to be missing|Integrity check failed|not found in the index|pack file .* (is missing|not found)' "${f}"; then
            name="${f##*/}"
            name="${name#"${SFX}_"}"
            name="${name%-prune.log}"
            printf '%s\n' "${name}"
        fi
    done
    shopt -u nullglob
}

############################################################################################
# Build the target list.
############################################################################################
names=()
if [ "${#USERS_CLI[@]}" -gt 0 ]; then
    names=("${USERS_CLI[@]}")
elif [ -n "${LIST_FILE}" ]; then
    if [ ! -r "${LIST_FILE}" ]; then echo "ERROR: list file '${LIST_FILE}' is missing or unreadable."; exit 1; fi
    mapfile -t names < <(grep -vE '^[[:space:]]*(#|$)' "${LIST_FILE}")
else
    mapfile -t names < <(discover_from_logs | sort -u)
fi

if [ "${#names[@]}" -eq 0 ]; then
    echo "No repositories need repair (no matching prune-log failures found under ${LOG})."
    exit 0
fi

if [ -n "${SAVE_LIST}" ]; then
    printf '%s\n' "${names[@]}" > "${SAVE_LIST}"
    echo "Saved ${#names[@]} repo name(s) needing repair to ${SAVE_LIST}. No changes made."
    exit 0
fi

echo "=== restic repair for ${SFX} (${CLOUD}, repo prefix ${REPO_PREFIX}) ==="
echo "Targets (${#names[@]}): ${names[*]}"
$DRY_RUN && echo "*** DRY-RUN: no changes will be made ***"

repair_one() {
    local NAME="$1"
    local REPO="${REPO_PREFIX}/${NAME}"
    local L="${LOG}/${SFX}_${NAME}-repair.log"
    : > "${L}"
    local -a base=(--repo "${REPO}" --password-file "${PASS_FILE}" -o "s3.connections=${S3_CONNECTIONS}" --retry-lock "${RETRY_LOCK}")

    log_both "${L}" "=== repair ${NAME} (${REPO}) ==="

    if ! "${RESTIC}" cat config "${base[@]}" > /dev/null 2>>"${L}"; then
        log_both "${L}" "  skip ${NAME}: repository not found / inaccessible"
        record_failure "${NAME} (repo inaccessible)"
        return 1
    fi

    "${RESTIC}" unlock "${base[@]}" >> "${L}" 2>&1

    # Is the repo actually damaged? (check-gated so healthy repos are never modified)
    if "${RESTIC}" check "${base[@]}" >> "${L}" 2>&1; then
        log_both "${L}" "  ${NAME}: already healthy (no repair needed)"
    else
        log_both "${L}" "  ${NAME}: damage detected -> repair index"
        if ! "${RESTIC}" repair index "${base[@]}" >> "${L}" 2>&1; then
            log_both "${L}" "  ${NAME}: repair index FAILED"
            record_failure "${NAME} (repair index failed)"
            return 1
        fi

        if "${RESTIC}" check "${base[@]}" >> "${L}" 2>&1; then
            log_both "${L}" "  ${NAME}: healthy after index rebuild"
        else
            # Snapshots still reference missing data.
            if $DRY_RUN; then
                log_both "${L}" "  ${NAME}: [dry-run] still damaged; would run 'repair snapshots --forget'. Preview:"
                "${RESTIC}" repair snapshots --dry-run "${base[@]}" >> "${L}" 2>&1
                record_failure "${NAME} (needs snapshot repair) [dry-run]"
                return 0
            fi
            if $NO_SNAPSHOT_REPAIR; then
                log_both "${L}" "  ${NAME}: still damaged; snapshot repair disabled (--no-snapshot-repair)"
                record_failure "${NAME} (needs snapshot repair)"
                return 1
            fi
            log_both "${L}" "  ${NAME}: rewriting damaged snapshots (repair snapshots --forget) [DESTRUCTIVE]"
            if ! "${RESTIC}" repair snapshots --forget "${base[@]}" >> "${L}" 2>&1; then
                log_both "${L}" "  ${NAME}: repair snapshots FAILED"
                record_failure "${NAME} (repair snapshots failed)"
                return 1
            fi
            if ! "${RESTIC}" check "${base[@]}" >> "${L}" 2>&1; then
                log_both "${L}" "  ${NAME}: STILL damaged after snapshot repair"
                record_failure "${NAME} (still damaged after repair)"
                return 1
            fi
            log_both "${L}" "  ${NAME}: repaired"
        fi
    fi

    if $DO_PRUNE && ! $DRY_RUN; then
        local -a popts=(prune --max-unused "${MAX_UNUSED}" --verbose)
        [ -n "${REPACK_SMALLER_THAN}" ] && popts+=(--repack-smaller-than "${REPACK_SMALLER_THAN}")
        log_both "${L}" "  ${NAME}: prune"
        if ! "${RESTIC}" "${popts[@]}" "${base[@]}" >> "${L}" 2>&1; then
            log_both "${L}" "  ${NAME}: prune after repair FAILED"
            record_failure "${NAME} (prune after repair failed)"
            return 1
        fi
    fi

    log_both "${L}" "  ${NAME}: OK"
    return 0
}

# Throttle on live job count, like restic_backup_s3.sh.
for name in "${names[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "${MAX_JOBS}" ]; do
        wait -n
    done
    repair_one "${name}" &
done
wait

############################################################################################
# Summary
############################################################################################
if [ -s "${FAIL_LOG}" ]; then
    fail_count=$(wc -l < "${FAIL_LOG}" | tr -d ' ')
    echo "Repair completed with ${fail_count} item(s) needing attention:"
    sort "${FAIL_LOG}" | sed 's/^/  - /'
    exit 1
fi

echo "All targeted repositories repaired successfully."
exit 0
