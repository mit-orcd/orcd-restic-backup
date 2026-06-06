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

# --- Adaptive concurrency governor (opt-in via -A|--adaptive) ---------------------------------
# By default the script throttles to a FIXED MAX_JOBS. With -A|--adaptive, a lightweight
# background "governor" steers the number of in-flight jobs based PRIMARILY on the rclone upload
# backlog (the vfs cache fill, read from rclone's remote-control API) with available memory as a
# secondary safety clamp. In adaptive mode MAX_JOBS becomes the CEILING (not a constant) and
# MIN_JOBS the floor. Concurrency moves by AIMD: additive increase (+GOV_STEP) when the backlog
# is low, multiplicative decrease (halve) when it is high or memory is below the floor. When -A
# is absent there is ZERO governor overhead and behavior is exactly as before (fixed MAX_JOBS).
# All knobs below are env-overridable.
ADAPTIVE_JOBS=false                                       # set true by -A|--adaptive
MIN_JOBS="${MIN_JOBS:-8}"                                 # concurrency floor in adaptive mode
GOV_INTERVAL="${GOV_INTERVAL:-20}"                        # governor sample period (seconds)
GOV_STEP="${GOV_STEP:-8}"                                 # additive-increase step (jobs)
RCLONE_BIN="${RCLONE_BIN:-rclone}"                        # rclone binary used for rc calls
RCLONE_RC_ADDR="${RCLONE_RC_ADDR:-127.0.0.1:5572}"        # rclone --rc address of the mount
CACHE_DIR="${CACHE_DIR:-}"                                # optional df fallback path (empty = skip)
CACHE_MAX_BYTES="${CACHE_MAX_BYTES:-8796093022208}"       # vfs cache ceiling in bytes (default 8 TiB)
CACHE_HIGH="${CACHE_HIGH:-70}"                            # back-off watermark (% of CACHE_MAX_BYTES)
CACHE_LOW="${CACHE_LOW:-40}"                              # grow watermark (% of CACHE_MAX_BYTES)
MEM_FLOOR_KB="${MEM_FLOOR_KB:-8388608}"                   # keep MemAvailable above this (~8 GiB)
MEMINFO="${MEMINFO:-/proc/meminfo}"                       # meminfo path (overridable for testing)

# Prune tuning. On remote/object storage (e.g. Wasabi) repacking partially-used pack files
# requires download + re-upload and is slow/expensive. MAX_UNUSED=unlimited skips repacking
# and only deletes fully-unreferenced packs (fast, minimal bandwidth); space is reclaimed
# lazily as packs become fully unused. MAX_REPACK_SIZE optionally caps repack volume per run
# (set e.g. 50G to chip away incrementally; empty = no cap). See restic docs "Customize pruning".
MAX_UNUSED="${MAX_UNUSED:-unlimited}"
MAX_REPACK_SIZE="${MAX_REPACK_SIZE:-}"

# Retry handling. restic's local backend over an rclone/s3fs mount can intermittently fail on
# lock files (e.g. "unable to refresh lock: chmod ...: no such file or directory") when the
# mount's directory cache briefly surfaces a lock object that is already gone on the remote, or
# after a killed run. Rather than fail the whole target, retry the operation, clearing locks in
# between. RETRIES = additional attempts after the first; RETRY_DELAY = seconds between them.
RETRIES="${RETRIES:-2}"
RETRY_DELAY="${RETRY_DELAY:-15}"

# Distribution-aware dispatch ordering (opt-in via -D|--dist-order). When enabled, the order
# in which owner directories are dispatched is computed by dist_planner.py so that any prefix
# of the run mirrors the full first-letter distribution (maximizing owner coverage if the run
# is interrupted). The execution engine/throttle is unchanged; only the order changes. Falls
# back to the plain sorted find if python/the planner is missing or errors.
PYTHON="${PYTHON:-python3}"
DIST_PLANNER="${DIST_PLANNER:-$(dirname "$0")/dist_planner.py}"

RUN=false
FORGET=false
PRUNE=false
DIST_ORDER=false

# --- Steady-state "freshness" mode (opt-in via -L|--loop and/or --skip-unchanged) -----------
# The initial seed of all repos is expensive (~120h), but once seeded, incremental backups are
# cheap. To minimize the latency between a user adding a file and that file being backed up, two
# opt-in mechanisms are provided:
#   * -L|--loop          repeat the backup pass continuously (a freshness daemon).
#   * --skip-unchanged   before backing up a user, cheaply check whether that user's SOURCE tree
#                        changed since its last successful backup (a per-user "last" marker plus a
#                        short-circuiting `find -newer` scan). Unchanged users are skipped with
#                        ZERO restic/Wasabi work, so each cycle stays fast and changed users get
#                        re-backed up within ~one cycle.
# Looping implies skip-unchanged (otherwise every cycle would re-backup everything and hammer
# Wasabi); set SKIP_UNCHANGED explicitly in the environment to force it on or off. When neither
# flag is present, behavior is exactly as before: a single pass over all users with no skipping
# and no marker/state requirement. All knobs below are env-overridable.
LOOP=false                                               # set true by -L|--loop
# Did the environment explicitly provide SKIP_UNCHANGED? If so it wins (force on/off); otherwise
# it defaults false and is auto-enabled when -L|--loop is given.
if [ -n "${SKIP_UNCHANGED+x}" ]; then
    SKIP_UNCHANGED_ENV=true
else
    SKIP_UNCHANGED_ENV=false
fi
SKIP_UNCHANGED="${SKIP_UNCHANGED:-false}"                # set true by --skip-unchanged
LOOP_INTERVAL="${LOOP_INTERVAL:-60}"                     # seconds to sleep between loop cycles
LOOP_MAX_CYCLES="${LOOP_MAX_CYCLES:-0}"                  # 0 = infinite; else stop after N cycles
STATE_DIR="${STATE_DIR:-${TMP}/state}"                   # per-user "last backup" markers live here

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
    echo "  -D|--dist-order             Dispatch backups in a coverage-optimal order from dist_planner.py (default: alphabetical sort)"
    echo "  -A|--adaptive               Adaptively tune concurrency from rclone upload backlog + memory (default: fixed MAX_JOBS)"
    echo "  -L|--loop                   Steady-state freshness: repeat the backup pass continuously (implies --skip-unchanged)"
    echo "  --skip-unchanged            Skip users whose source tree is unchanged since their last backup (cheap find -newer check)"
    echo ""
    echo "  -r, -f and -p may be combined; at least one is required."
    echo "  Order when combined: backup -> forget -> prune."
    echo ""
    echo "Environment overrides:"
    echo "  MAX_UNUSED        Prune --max-unused value (default: unlimited = no repack, fastest)"
    echo "  MAX_REPACK_SIZE   Prune --max-repack-size value (default: unset = no cap)"
    echo "  RETRIES           Extra attempts per target after the first (default: 2)"
    echo "  RETRY_DELAY       Seconds between attempts, with an unlock in between (default: 15)"
    echo "  ALLOW_ROOT_FS=1   Bypass the destination mount-point safety check"
    echo "  PYTHON            Python interpreter used for -D|--dist-order (default: python3)"
    echo "  DIST_PLANNER      Path to dist_planner.py for -D|--dist-order (default: alongside this script)"
    echo ""
    echo "  Steady-state freshness (-L|--loop, --skip-unchanged):"
    echo "  SKIP_UNCHANGED    Force skip-unchanged on/off (true/false); overrides the -L auto-enable"
    echo "  LOOP_INTERVAL     Seconds to sleep between backup cycles in loop mode (default: 60)"
    echo "  LOOP_MAX_CYCLES   Stop after N loop cycles; 0 = infinite (default: 0)"
    echo "  STATE_DIR         Where per-user last-backup markers live (default: \${TMP}/state)"
    echo ""
    echo "  Adaptive concurrency (-A|--adaptive) tuning:"
    echo "  MIN_JOBS          Concurrency floor in adaptive mode (default: 8); MAX_JOBS is the ceiling"
    echo "  GOV_INTERVAL      Governor sample period in seconds (default: 20)"
    echo "  GOV_STEP          Additive-increase step in jobs when backlog is low (default: 8)"
    echo "  RCLONE_BIN        rclone binary used for rc calls (default: rclone)"
    echo "  RCLONE_RC_ADDR    rclone --rc address of the mount (default: 127.0.0.1:5572)"
    echo "  CACHE_DIR         Optional df-fallback path for backlog if rc is unavailable (default: unset = skip)"
    echo "  CACHE_MAX_BYTES   vfs cache ceiling in bytes (default: 8796093022208 = 8 TiB)"
    echo "  CACHE_HIGH        Back-off watermark, percent of CACHE_MAX_BYTES (default: 70)"
    echo "  CACHE_LOW         Grow watermark, percent of CACHE_MAX_BYTES (default: 40)"
    echo "  MEM_FLOOR_KB      Back off if MemAvailable falls below this many KiB (default: 8388608 = ~8 GiB)"
    echo "  MEMINFO           Path to meminfo for the memory signal (default: /proc/meminfo)"
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
        -D|--dist-order)
            DIST_ORDER=true
            shift
            ;;
        -A|--adaptive)
            ADAPTIVE_JOBS=true
            shift
            ;;
        -L|--loop)
            LOOP=true
            shift
            ;;
        --skip-unchanged)
            SKIP_UNCHANGED=true
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

# Normalize SKIP_UNCHANGED (env values may be 1/yes/on/true etc.) to a true/false command so
# `$SKIP_UNCHANGED` can be used directly as a conditional.
case "${SKIP_UNCHANGED}" in
    1|true|TRUE|yes|YES|on|ON)        SKIP_UNCHANGED=true ;;
    *)                                SKIP_UNCHANGED=false ;;
esac

# Looping without skip-unchanged would re-backup every user every cycle, so auto-enable it under
# -L unless the environment explicitly set SKIP_UNCHANGED (which then wins, on or off).
if $LOOP && ! $SKIP_UNCHANGED_ENV; then
    SKIP_UNCHANGED=true
fi

SFX=$(echo ${DESTINATION}|awk -F"/" '{print $NF}')

# Freshness markers live under ${STATE_DIR}/${SFX}; create it once up front, only when skip
# detection is active (default single-pass runs touch no state at all).
if $SKIP_UNCHANGED; then
    mkdir -p "${STATE_DIR}/${SFX}"
fi

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

# Companion to FAIL_LOG for the skip-unchanged path: background jobs record skipped users here so
# the per-cycle summary can report how many were skipped. Short appends (< PIPE_BUF) are atomic on
# POSIX, so concurrent writes from parallel jobs are safe.
SKIP_LOG="${TMP}/.skipped.${SFX}.$$"
: > "${SKIP_LOG}"

record_skip() {
    echo "$1" >> "${SKIP_LOG}"
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

# Run a restic command with retries, clearing locks between attempts. This absorbs transient
# lock-file errors seen on rclone/s3fs mounts (stale dir-cache entries, killed-run leftovers).
# --repo and --password-file are appended automatically.
# Usage: retry_restic <repo> <logfile> -- <restic args...>
retry_restic() {
    local repo="$1"
    local logfile="$2"
    shift 2
    [ "$1" = "--" ] && shift

    local attempt=1
    local max=$((RETRIES + 1))

    while :; do
        if "${RESTIC}" "$@" --repo "${repo}" --password-file "${PASS_FILE}" > "${logfile}" 2>&1; then
            return 0
        fi

        if [ "${attempt}" -ge "${max}" ]; then
            return 1
        fi

        echo "  retry ${attempt}/${RETRIES} for repo ${repo} after failure (see ${logfile}); unlocking and waiting ${RETRY_DELAY}s"
        # Clear stale/phantom locks before the next attempt.
        "${RESTIC}" unlock --repo "${repo}" --password-file "${PASS_FILE}" > /dev/null 2>&1
        sleep "${RETRY_DELAY}"
        attempt=$((attempt + 1))
    done
}

# Cheap change detection for steady-state freshness mode. Returns 0 if the user's SOURCE tree has
# changed since its last successful backup (or has never been backed up), 1 if unchanged. The
# "last backup" marker is ${STATE_DIR}/${SFX}/<user>.last and holds a unix timestamp. The SOURCE
# path mirrors backup_user, which cd's to SOURCE and backs up "./<user>" (i.e. ${SOURCE}/<user>).
#
# We never want to skip a real backup by mistake, so on ANY uncertainty (missing/garbled marker,
# find error) we report "changed" (return 0). The scan uses `find ... -newermt @<ts> -print -quit`
# so it stops at the FIRST entry newer than the marker — O(1) in the common "one new file" case
# rather than walking the whole tree.
user_changed() {
    local USER="$1"
    local marker="${STATE_DIR}/${SFX}/${USER}.last"
    local ts hit

    # No marker -> never backed up (or marker lost) -> treat as changed.
    [ -f "${marker}" ] || return 0

    ts=$(cat "${marker}" 2>/dev/null)
    case "${ts}" in
        ''|*[!0-9]*) return 0 ;;   # unreadable/garbled marker -> be safe, back it up
    esac

    # Short-circuiting scan: -quit makes find exit at the first entry newer than the marker.
    hit=$(find "${SOURCE}/${USER}" -newermt "@${ts}" -print -quit 2>/dev/null) || return 0
    [ -n "${hit}" ] && return 0    # something newer than the last backup -> changed
    return 1                       # nothing newer -> unchanged
}

backup_user() {
    local USER="$1"
    # Capture the pre-scan/pre-backup time BEFORE the change check. Recording this (rather than
    # "now" after the backup) as the marker means a file added WHILE this backup runs is still
    # seen as newer next cycle and gets re-backed up — we never miss a concurrent write.
    local _scan_start=$(date +%s)
    local TS=$(date +%Y%m%d-%H%M%S)
    local TAG="backup-${TS}"
    local REPO="${DESTINATION}/${USER}"
    local RESTIC_OPTS="--compression ${COMPRESSION} --verbose --skip-if-unchanged"
    local marker="${STATE_DIR}/${SFX}/${USER}.last"

    # Steady-state freshness: when skip-unchanged is active, skip users whose SOURCE tree is
    # unchanged since the last successful backup WITHOUT touching the repo (no init/unlock/backup,
    # so no Wasabi lock churn). This is the key win that keeps each cycle fast.
    if $SKIP_UNCHANGED && ! user_changed "${USER}"; then
        echo "Skipping unchanged user: ${USER}"
        record_skip "${USER}"
        return 0
    fi

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

    if ! retry_restic "${REPO}" "${LOG}/${SFX}_${USER}-backup.log" -- backup --tag "${TAG}" "./${USER}" ${RESTIC_OPTS}; then
        echo "Backup failed for ${SFX} : ${USER}. Check ${LOG}/${SFX}_${USER}-backup.log"
        record_failure "${USER} (backup)"
        return 1
    fi

    # On success, publish the pre-scan timestamp as the freshness marker (atomic write + mv).
    # Only when skip-unchanged is active, so default single-pass runs create no state.
    if $SKIP_UNCHANGED; then
        if printf '%s\n' "${_scan_start}" > "${marker}.tmp" 2>/dev/null; then
            mv -f "${marker}.tmp" "${marker}" 2>/dev/null
        fi
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

    if ! retry_restic "${REPO}" "${LOG}/${SFX}_${USER}-prune.log" -- prune ${PRUNE_OPTS}; then
        echo "Prune failed for ${SFX} : ${USER}. Check ${LOG}/${SFX}_${USER}-prune.log"
        record_failure "${USER} (prune)"
        return 1
    fi

    echo "Prune completed for ${SFX} : ${USER}."
}

# Owner-directory discovery. Default order is the plain alphabetical sort. When -D|--dist-order
# is requested, the order comes from dist_planner.py (coverage-optimal proportional interleave);
# the SAME find filter is the fallback if the planner is missing or produces no output, so a
# flag/env problem can never abort a backup. Factored into a function so loop mode can RE-DISCOVER
# each cycle (picking up newly-added user directories). Sets the global `users` list.
discover_users() {
    if $DIST_ORDER && { [ -x "${DIST_PLANNER}" ] || [ -f "${DIST_PLANNER}" ]; }; then
        users=$("${PYTHON}" "${DIST_PLANNER}" "${SOURCE}" --emit-order 2> "${LOG}/${SFX}_dist-planner.log")
        if [ -z "${users}" ]; then
            echo "WARNING: dist-order planner produced no output (see ${LOG}/${SFX}_dist-planner.log); falling back to sorted find"
            users=$(find -L ${SOURCE} -maxdepth 1 -mindepth 1 -type d ! -name "restore*" -printf '%f\n' | sort)
        else
            echo "Using distribution-aware dispatch order from ${DIST_PLANNER}"
        fi
    elif $DIST_ORDER; then
        echo "WARNING: --dist-order requested but planner not found at ${DIST_PLANNER}; falling back to sorted find"
        users=$(find -L ${SOURCE} -maxdepth 1 -mindepth 1 -type d ! -name "restore*" -printf '%f\n' | sort)
    else
        users=$(find -L ${SOURCE} -maxdepth 1 -mindepth 1 -type d ! -name "restore*" -printf '%f\n' | sort)
    fi
}

############################################################################################
# Adaptive concurrency governor (active only with -A|--adaptive).
#
# A background loop samples the rclone upload backlog (vfs cache fill) and available memory
# every GOV_INTERVAL seconds and writes a target concurrency to GOV_TARGET_FILE using AIMD.
# run_parallel reads that target via current_cap() to throttle dispatch. The governor NEVER
# kills running jobs and NEVER aborts a backup: if its signals are unavailable it holds the
# target steady and the run continues. When -A is absent none of this runs.
############################################################################################
GOV_TARGET_FILE="${TMP}/.gov_target.${SFX}"
GOV_STOP_FILE="${TMP}/.gov_stop.${SFX}.$$"
GOV_PID=""

# Parse diskCache.bytesUsed (bytes) from an rclone `vfs/stats` JSON blob. bytesUsed reflects the
# total data resident in the vfs cache, which includes data still queued for upload to the
# remote — i.e. the upload backlog. Prefer python3 for robust JSON parsing; fall back to
# grep/sed if python3 is unavailable. Echoes the integer; nonzero return if not found.
_gov_parse_bytes() {
    local json="$1"

    if command -v python3 > /dev/null 2>&1; then
        printf '%s' "${json}" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    dc = d.get("diskCache", {}) or {}
    print(int(dc.get("bytesUsed", 0) or 0))
except Exception:
    sys.exit(1)
' 2>/dev/null && return 0
        return 1
    fi

    # grep/sed fallback: first integer following "bytesUsed".
    local b
    b=$(printf '%s' "${json}" | grep -o '"bytesUsed"[[:space:]]*:[[:space:]]*[0-9][0-9]*' | head -1 | grep -o '[0-9][0-9]*$')
    [ -n "${b}" ] && { echo "${b}"; return 0; }
    return 1
}

# Echo an integer 0-100 = percent of CACHE_MAX_BYTES currently used/queued in the rclone vfs
# cache (the upload-backlog signal). Returns nonzero if it cannot determine a value.
#   PRIMARY: rclone rc vfs/stats -> diskCache.bytesUsed.
#   FALLBACK: df -kP "$CACHE_DIR" used bytes (df preferred over du; du over an 8T cache is slow).
gov_backlog_pct() {
    local json bytes pct used_kb

    json=$("${RCLONE_BIN}" rc --rc-addr="${RCLONE_RC_ADDR}" --rc-no-auth vfs/stats 2>/dev/null)
    if [ -n "${json}" ]; then
        bytes=$(_gov_parse_bytes "${json}")
        if [ -n "${bytes}" ] && [ "${bytes}" -ge 0 ] 2>/dev/null; then
            pct=$(( 100 * bytes / CACHE_MAX_BYTES ))
            (( pct > 100 )) && pct=100
            (( pct < 0 )) && pct=0
            echo "${pct}"
            return 0
        fi
    fi

    # Fallback: approximate backlog from filesystem usage of the cache dir.
    if [ -n "${CACHE_DIR}" ]; then
        used_kb=$(df -kP "${CACHE_DIR}" 2>/dev/null | awk 'NR==2 {print $3}')
        if [ -n "${used_kb}" ] && [ "${used_kb}" -ge 0 ] 2>/dev/null; then
            pct=$(( 100 * used_kb * 1024 / CACHE_MAX_BYTES ))
            (( pct > 100 )) && pct=100
            (( pct < 0 )) && pct=0
            echo "${pct}"
            return 0
        fi
    fi

    return 1
}

# Echo MemAvailable in KiB from MEMINFO (default /proc/meminfo). Nonzero return if unavailable.
gov_mem_available_kb() {
    local kb
    kb=$(awk '/^MemAvailable:/ {print $2; exit}' "${MEMINFO}" 2>/dev/null)
    if [ -n "${kb}" ] && [ "${kb}" -ge 0 ] 2>/dev/null; then
        echo "${kb}"
        return 0
    fi
    return 1
}

# Echo the current concurrency cap. Non-adaptive: constant MAX_JOBS (identical to legacy
# behavior). Adaptive: the governor's target from GOV_TARGET_FILE, clamped to [MIN_JOBS,
# MAX_JOBS]; defaults to MIN_JOBS if the file is missing/unreadable/non-numeric.
current_cap() {
    if ! $ADAPTIVE_JOBS; then
        echo "${MAX_JOBS}"
        return 0
    fi

    local t
    t=$(cat "${GOV_TARGET_FILE}" 2>/dev/null)
    case "${t}" in
        ''|*[!0-9]*) t="${MIN_JOBS}" ;;
    esac
    (( t < MIN_JOBS )) && t="${MIN_JOBS}"
    (( t > MAX_JOBS )) && t="${MAX_JOBS}"
    echo "${t}"
}

# Pure AIMD decision: given the current target, backlog pct, and MemAvailable (KiB), echo the
# next target clamped to [MIN_JOBS, MAX_JOBS]. Factored out of governor_loop so it can be unit
# tested in isolation.
#   - pct >= CACHE_HIGH  OR  mem < MEM_FLOOR_KB  -> multiplicative decrease (halve)
#   - pct <  CACHE_LOW                           -> additive increase (+GOV_STEP)
#   - otherwise                                  -> hold
# A non-numeric/empty mem is treated as "unknown" and does not trigger the memory clamp.
gov_next_target() {
    local target="$1" pct="$2" mem="$3"
    local mem_low=0

    case "${mem}" in
        ''|*[!0-9]*) mem_low=0 ;;
        *) [ "${mem}" -lt "${MEM_FLOOR_KB}" ] && mem_low=1 ;;
    esac

    if [ "${pct}" -ge "${CACHE_HIGH}" ] || [ "${mem_low}" -eq 1 ]; then
        target=$(( target / 2 ))
    elif [ "${pct}" -lt "${CACHE_LOW}" ]; then
        target=$(( target + GOV_STEP ))
    fi

    (( target < MIN_JOBS )) && target="${MIN_JOBS}"
    (( target > MAX_JOBS )) && target="${MAX_JOBS}"
    echo "${target}"
}

# Background governor loop (AIMD). Recomputes target concurrency every GOV_INTERVAL seconds and
# writes it atomically to GOV_TARGET_FILE. Exits when GOV_STOP_FILE appears.
governor_loop() {
    local govlog="${LOG}/${SFX}_governor.log"
    local target pct mem warned_backlog=0

    # Seed target from an existing valid state file, else a modest starting point.
    target=$(cat "${GOV_TARGET_FILE}" 2>/dev/null)
    case "${target}" in
        ''|*[!0-9]*) target=$(( MAX_JOBS / 4 )) ;;
    esac
    (( target < MIN_JOBS )) && target="${MIN_JOBS}"
    (( target > MAX_JOBS )) && target="${MAX_JOBS}"

    while [ ! -e "${GOV_STOP_FILE}" ]; do
        if pct=$(gov_backlog_pct); then
            mem=$(gov_mem_available_kb 2>/dev/null)
            target=$(gov_next_target "${target}" "${pct}" "${mem}")
        else
            # Backlog signal unavailable (rc + df both failed): hold target steady, warn once.
            if [ "${warned_backlog}" -eq 0 ]; then
                echo "$(date '+%Y-%m-%dT%H:%M:%S') WARNING: backlog signal unavailable (rclone rc/df failed); holding target=${target} (cap falls back to last value, never below MIN_JOBS)" >> "${govlog}"
                warned_backlog=1
            fi
            mem=$(gov_mem_available_kb 2>/dev/null)
            pct="NA"
        fi

        # Atomic publish of the new target.
        printf '%s\n' "${target}" > "${GOV_TARGET_FILE}.tmp" 2>/dev/null && mv -f "${GOV_TARGET_FILE}.tmp" "${GOV_TARGET_FILE}" 2>/dev/null
        echo "$(date '+%Y-%m-%dT%H:%M:%S') pct=${pct} memAvailKB=${mem:-NA} target=${target}" >> "${govlog}"

        sleep "${GOV_INTERVAL}"
    done
}

# Initialize governor state and launch the background monitor (adaptive mode only).
start_governor() {
    $ADAPTIVE_JOBS || return 0

    rm -f "${GOV_STOP_FILE}" 2>/dev/null

    # Seed an initial target so current_cap has a sane value before the first sample.
    local init=$(( MAX_JOBS / 4 ))
    (( init < MIN_JOBS )) && init="${MIN_JOBS}"
    (( init > MAX_JOBS )) && init="${MAX_JOBS}"
    printf '%s\n' "${init}" > "${GOV_TARGET_FILE}"

    governor_loop &
    GOV_PID=$!
    echo "Adaptive concurrency enabled: governor PID ${GOV_PID} (MIN_JOBS=${MIN_JOBS}, ceiling MAX_JOBS=${MAX_JOBS}, start target=${init}); log ${LOG}/${SFX}_governor.log"
}

# Stop the governor and clean up its state files. Safe to call repeatedly / when not started.
stop_governor() {
    [ -n "${GOV_PID}" ] || return 0
    : > "${GOV_STOP_FILE}" 2>/dev/null
    kill "${GOV_PID}" 2>/dev/null
    wait "${GOV_PID}" 2>/dev/null
    GOV_PID=""
    rm -f "${GOV_STOP_FILE}" "${GOV_TARGET_FILE}" "${GOV_TARGET_FILE}.tmp" 2>/dev/null
}

# Ensure the governor never outlives the run, even on interruption.
trap 'stop_governor' EXIT INT TERM

# Run the given per-user function across all targets. Non-adaptive: throttled to a constant
# MAX_JOBS (identical to legacy behavior). Adaptive: throttled to the governor's dynamic cap,
# which can shrink (stops launching new jobs until running drops below the new lower cap; it
# never kills running jobs) or grow up to MAX_JOBS.
run_parallel() {
    local fn="$1"
    local running=0
    local cap

    for user in $users; do
        cap=$(current_cap)
        while (( running >= cap )); do
            wait -n
            running=$((running - 1))
            cap=$(current_cap)
        done

        "${fn}" "$user" &
        running=$((running + 1))
    done

    wait
}

# Run a single backup cycle: (re-)discover users, dispatch backup_user across them, and log a
# one-line summary (cycle number, total/skipped/failed). The per-cycle failure and skip logs are
# reset at the top so a transient failure in one cycle does not permanently mark the whole run as
# failed; in loop mode the script's final exit status reflects the LAST cycle's failures.
run_backup_cycle() {
    local cycle="$1"
    local total skipped failed

    : > "${FAIL_LOG}"
    : > "${SKIP_LOG}"

    # Re-discover each cycle so user directories added between cycles are picked up.
    discover_users

    echo "=== Backup cycle ${cycle} for ${SFX} (source ${SOURCE}) ==="
    run_parallel backup_user

    total=$(echo "${users}" | wc -w | tr -d ' ')
    skipped=0; [ -s "${SKIP_LOG}" ] && skipped=$(wc -l < "${SKIP_LOG}" | tr -d ' ')
    failed=0;  [ -s "${FAIL_LOG}" ] && failed=$(wc -l < "${FAIL_LOG}" | tr -d ' ')
    echo "=== Backup cycle ${cycle} for ${SFX} done: total=${total} skipped=${skipped} failed=${failed} ==="
}

# Backup driver. Without -L|--loop this is exactly one cycle (legacy behavior). With -L it repeats
# continuously, sleeping LOOP_INTERVAL seconds between cycles, until LOOP_MAX_CYCLES is reached
# (0 = infinite). Only the backup pass loops; forget/prune remain single-shot. The governor (if
# -A) is started ONCE before this and stopped after, so it spans the whole loop.
run_backup() {
    if ! $LOOP; then
        run_backup_cycle 1
        return
    fi

    local cycle=1
    while :; do
        run_backup_cycle "${cycle}"
        if [ "${LOOP_MAX_CYCLES}" -gt 0 ] && [ "${cycle}" -ge "${LOOP_MAX_CYCLES}" ]; then
            echo "Loop reached LOOP_MAX_CYCLES=${LOOP_MAX_CYCLES}; stopping."
            break
        fi
        cycle=$((cycle + 1))
        sleep "${LOOP_INTERVAL}"
    done
}

# Launch the adaptive governor before any dispatch (no-op unless -A|--adaptive). It spans all
# selected modes — including the entire backup loop — and is torn down after the last one (and by
# the EXIT/INT/TERM trap).
start_governor

# Discover once up front so forget/prune (and a non-loop backup) have the user list. The backup
# loop re-discovers each cycle on top of this.
discover_users

if $RUN; then
    run_backup
fi

if $FORGET; then
    echo "=== Forget run for ${SFX} (source ${SOURCE}) ==="
    run_parallel forget_user
fi

if $PRUNE; then
    echo "=== Prune run for ${SFX} (source ${SOURCE}) ==="
    run_parallel prune_user
fi

stop_governor

############################################################################################
# Final status: report and exit non-zero if any target failed.
############################################################################################
if [ -s "${FAIL_LOG}" ]; then
    fail_count=$(wc -l < "${FAIL_LOG}" | tr -d ' ')
    echo "Completed with ${fail_count} failure(s):"
    sort "${FAIL_LOG}" | sed 's/^/  - /'
    rm -f "${FAIL_LOG}" "${SKIP_LOG}"
    exit 1
fi

rm -f "${FAIL_LOG}" "${SKIP_LOG}"
echo "All operations completed successfully."
exit 0
