#!/usr/bin/env bash
#
# Aurora port of scripts/testbed/fio/run_fio-dfs_256io_sweep_controlled.sh.
#
# Controlled rerun for Figure 3 / fixed aggregate-concurrency experiment.
#
# The experiment varies (numjobs, iodepth) while holding constant:
#   - numjobs * iodepth = 256 outstanding I/Os
#   - request size = 1 MiB
#   - aggregate working-set size = 8 GiB
#   - one DFS file/object per fio job
#   - workload = 60 s random write after a 10 s ramp period
#
#   4 x 64  ->  4 objects x 2 GiB   = 8 GiB
#   8 x 32  ->  8 objects x 1 GiB   = 8 GiB
#   16 x 16 -> 16 objects x 512 MiB = 8 GiB
#   32 x 8  -> 32 objects x 256 MiB = 8 GiB
#   64 x 4  -> 64 objects x 128 MiB = 8 GiB
#
# WHY ONE FILE PER JOB (do not raise nrfiles).
#   Upstream fio's engines/dfs.c stores the dfs object handle in a single
#   per-thread slot (struct daos_data.obj) rather than per open file.  With
#   nrfiles > 1 each dfs_open() overwrites the previous handle, so every I/O
#   in the job is issued against the last-opened object regardless of which
#   file fio believes it selected, and offsets stay relative to the individual
#   file size.  The nominal working set silently collapses (e.g. a declared
#   8 GiB / 64-file layout becomes 512 MiB spread over 4 objects), and
#   teardown emits "Failed to release <file>: 22" for every file but one.
#   nrfiles=1 is the only setting the stock engine handles correctly, so the
#   object count necessarily tracks numjobs here.  That coupling is a known
#   and stated limitation of this sweep; see the methodology section.
#
#   To vary object count independently of I/O concurrency, use IOR with
#   -a DFS instead, where each MPI rank opens its own object.
#
# Aurora-specific differences from the testbed script:
#   - default pool is 'e2sar' (testbed: 'iobench')
#   - default fio binary is ${HOME}/local/bin/fio
#   - containers are created with --properties=rd_fac:0 like the other
#     Aurora scripts in this repo
#   - the DAOS module is loaded if the 'daos' command is not already in PATH
#
# Usage (interactive job or via qsub_fio-dfs_256io_sweep_controlled.qsub):
#   ./run_fio-dfs_256io_sweep_controlled_1file.sh [N_REPEATS]
#
# Examples:
#   ./run_fio-dfs_256io_sweep_controlled_1file.sh 1   # smoke test: 5 runs
#   ./run_fio-dfs_256io_sweep_controlled_1file.sh 5   # paper campaign: 25 runs
#
# Optional environment variables:
#   FIO_BIN_PATH=${HOME}/local/bin/fio
#   DAOS_POOL_NAME=e2sar
#   DAOS_CONT_BASE=fio_dfs_controlled_1file
#   OUTPUT_ROOT=/path/to/results
#   RUNTIME_SEC=60
#   RAMP_SEC=10
#   INTER_RUN_SLEEP_SEC=5
#   FIO_THREAD_MODE=0     # 1 => pass --thread=1 (see note below)
#   DEBUG=1
#
# On FIO_THREAD_MODE:
#   In the default fork mode each job process independently runs daos_init /
#   pool connect / cont open / dfs_mount, because those handles live in
#   file-scope globals in dfs.c.  The number of DAOS client contexts therefore
#   tracks numjobs (4 -> 64) across the sweep.  With --thread=1 a single
#   context is shared by all jobs.  Neither is wrong, but they measure
#   different x-axes; run the 64x4 configuration both ways and compare medians
#   and across-run CV before committing to one for the paper.

set -Eeuo pipefail

if [[ "${DEBUG:-0}" == "1" ]]; then
    set -x
fi

N_REPEATS="${1:-5}"
if ! [[ "${N_REPEATS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: N_REPEATS must be a positive integer; got '${N_REPEATS}'." >&2
    exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null)"; then
    :
else
    # Expected location: <repo>/scripts/aurora/fio/<this-script>
    REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
fi

# Load the DAOS module when running outside the qsub wrapper.
if ! command -v daos >/dev/null 2>&1; then
    echo "Loading DAOS module"
    module use /soft/modulefiles/ || { echo "ERROR: Failed to use modulefiles" >&2; exit 1; }
    module load daos || { echo "ERROR: Failed to load DAOS module" >&2; exit 1; }
fi

FIO_BIN_PATH="${FIO_BIN_PATH:-${HOME}/local/bin/fio}"
POOL="${DAOS_POOL_NAME:-e2sar}"
CONT_BASE="${DAOS_CONT_BASE:-fio_dfs_controlled_1file}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/results/aurora/fio-dfs-256io-sweep-controlled-1file}"

BLOCK_SIZE="1M"
FILES_PER_JOB=1
TOTAL_DATASET_SIZE="8g"
AGGREGATE_QD_TARGET=256
# Keep $jobnum and $filenum literal. fio expands them, not Bash.
# filenum is always 0 here; $jobnum keeps the names unique across jobs.
FILENAME_FORMAT='fio_data.$jobnum.$filenum'
RUNTIME_SEC="${RUNTIME_SEC:-60}"
RAMP_SEC="${RAMP_SEC:-10}"
INTER_RUN_SLEEP_SEC="${INTER_RUN_SLEEP_SEC:-5}"
FIO_THREAD_MODE="${FIO_THREAD_MODE:-0}"

# Fields: numjobs:iodepth:size_per_job
# All configurations preserve:
#   numjobs * iodepth      = 256 outstanding I/Os (nominal)
#   numjobs * size_per_job = 8 GiB aggregate working set
# Object count is numjobs, and is NOT held constant; see the header note.
# CONFIGS=(
#     "4:64:2g"
#     "8:32:1g"
#     "16:16:512m"
#     "32:8:256m"
#     "64:4:128m"
# )
CONFIGS=(
    "4:64:2g"
    "8:32:1g"
    "16:16:512m"
)
N_CONFIGS="${#CONFIGS[@]}"

CAMPAIGN_ID="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${OUTPUT_ROOT}/${CAMPAIGN_ID}"
MANIFEST="${OUTPUT_DIR}/manifest.tsv"
RUN_LOG="${OUTPUT_DIR}/campaign.log"
mkdir -p "${OUTPUT_DIR}"

# Mirror all terminal output into a persistent campaign log.
exec > >(tee -a "${RUN_LOG}") 2>&1

CURRENT_CONT=""
cleanup() {
    local exit_code=$?
    if [[ -n "${CURRENT_CONT}" ]]; then
        echo "Cleanup: destroying container '${CURRENT_CONT}'..."
        daos container destroy "${POOL}" "${CURRENT_CONT}" >/dev/null 2>&1 || true
        CURRENT_CONT=""
    fi
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

require_command() {
    local command_name="$1"
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "ERROR: required command '${command_name}' is not available." >&2
        exit 1
    fi
}

require_command daos
require_command git
require_command tee

if [[ ! -x "${FIO_BIN_PATH}" ]]; then
    echo "ERROR: fio is not executable at '${FIO_BIN_PATH}'." >&2
    echo "Set FIO_BIN_PATH to the DFS-enabled fio binary." >&2
    exit 1
fi

FIO="${FIO_BIN_PATH}"
FIO_VERSION="$(${FIO} --version)"

# Guard rail: the stock dfs engine cannot service more than one file per job.
if ((FILES_PER_JOB != 1)); then
    echo "ERROR: FILES_PER_JOB must be 1 with a stock fio." >&2
    echo "       Upstream engines/dfs.c keeps a single dfs object handle per job," >&2
    echo "       so nrfiles > 1 sends all I/O to the last-opened file and" >&2
    echo "       silently shrinks the working set." >&2
    exit 1
fi

# Optional --thread=1, applied identically to every configuration.
THREAD_OPTS=()
if [[ "${FIO_THREAD_MODE}" == "1" ]]; then
    THREAD_OPTS=(--thread=1)
fi

echo "============================================================"
echo "Controlled fio DFS sweep (Aurora): one object per job"
echo "============================================================"
echo "Campaign ID       : ${CAMPAIGN_ID}"
echo "Repository root   : ${REPO_ROOT}"
echo "Output directory  : ${OUTPUT_DIR}"
echo "fio binary        : ${FIO}"
echo "fio version       : ${FIO_VERSION}"
echo "DAOS pool         : ${POOL}"
echo "Repetitions       : ${N_REPEATS}"
echo "Configurations    : ${CONFIGS[*]}"
echo "Block size        : ${BLOCK_SIZE}"
echo "Files per job     : ${FILES_PER_JOB}"
echo "Total dataset     : ${TOTAL_DATASET_SIZE}"
echo "Filename format   : ${FILENAME_FORMAT}"
echo "Measured runtime  : ${RUNTIME_SEC} s"
echo "Ramp time         : ${RAMP_SEC} s"
echo "Thread mode       : ${FIO_THREAD_MODE} (1 => --thread=1)"
echo "============================================================"

if ! "${FIO}" --enghelp dfs >/dev/null 2>&1; then
    echo "ERROR: '${FIO}' does not have the DAOS DFS ioengine." >&2
    exit 1
fi

if ! daos pool query "${POOL}" >/dev/null 2>&1; then
    echo "ERROR: DAOS pool '${POOL}' is not accessible." >&2
    exit 1
fi

printf '%s\n' \
    $'campaign\trepeat\tposition\tnumjobs\tiodepth\taggregate_qd\tfiles_per_job\ttotal_objects\tsize_per_job\ttotal_dataset_size\tthread_mode\tcontainer\tresult_json\tcmd_file\tstart_utc\tend_utc\tstatus' \
    > "${MANIFEST}"

SCRIPT_START_EPOCH="$(date +%s)"
TOTAL_RUNS=0
FAILED_RUNS=0

for ((repeat = 1; repeat <= N_REPEATS; repeat++)); do
    # Cyclically rotate the starting configuration on each repetition.
    # Across five repetitions, every configuration occupies every order position once.
    start_index=$(((repeat - 1) % N_CONFIGS))

    echo
    echo "######## Repetition ${repeat}/${N_REPEATS}; rotation start=${start_index} ########"

    for ((position = 0; position < N_CONFIGS; position++)); do
        config_index=$(((start_index + position) % N_CONFIGS))
        IFS=':' read -r nj iod size_per_job <<< "${CONFIGS[config_index]}"

        aggregate_qd=$((nj * iod))
        total_objects=$((nj * FILES_PER_JOB))

        if ((aggregate_qd != AGGREGATE_QD_TARGET)); then
            echo "ERROR: invalid configuration nj=${nj}, iod=${iod}; aggregate QD=${aggregate_qd}." >&2
            exit 1
        fi

        timestamp="$(date +%s)"
        label="r${repeat}_p$((position + 1))_bs${BLOCK_SIZE}_nj${nj}_iod${iod}_${timestamp}"
        CONT="${CONT_BASE}_${label}"
        RESULT_JSON="${OUTPUT_DIR}/fio_${label}.json"
        CMD_LOG="${OUTPUT_DIR}/fio_${label}.cmd"
        PROP_LOG="${OUTPUT_DIR}/container_${label}.properties.txt"
        QUERY_LOG="${OUTPUT_DIR}/container_${label}.query.txt"
        start_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

        echo
        echo "------------------------------------------------------------"
        echo "Repeat / position : ${repeat}/${N_REPEATS}, $((position + 1))/${N_CONFIGS}"
        echo "Configuration     : numjobs=${nj}, iodepth=${iod}, aggregate_qd=${aggregate_qd}"
        echo "Files per job     : ${FILES_PER_JOB}"
        echo "Total objects     : ${total_objects}"
        echo "Size per job      : ${size_per_job}"
        echo "Total dataset     : ${TOTAL_DATASET_SIZE}"
        echo "Container         : ${CONT}"
        echo "Result            : ${RESULT_JSON}"
        echo "Start UTC         : ${start_utc}"
        echo "------------------------------------------------------------"

        # rd_fac:0 matches the other Aurora scripts in this repo (no redundancy).
        # The saved query/getprop output must still be checked for the actual
        # file object class reported on Aurora.
        daos container create --type=POSIX --properties=rd_fac:0 "${POOL}" "${CONT}" >/dev/null
        CURRENT_CONT="${CONT}"

        daos container getprop "${POOL}" "${CONT}" >"${PROP_LOG}"
        daos container query "${POOL}" "${CONT}" >"${QUERY_LOG}"

        # One object per job; filesize == size so the job's whole working set
        # lives in its single file.
        #
        # Built as an array so the logged command and the executed command are
        # the same object.  %q keeps $jobnum / $filenum literal in the log, so
        # the recorded command can be pasted back into a shell unchanged.
        fio_cmd=(
            "${FIO}"
            --output="${RESULT_JSON}"
            --output-format=json
            --name=rand_write
            --ioengine=dfs
            --pool="${POOL}"
            --cont="${CONT}"
            --filename_format="${FILENAME_FORMAT}"
            --nrfiles="${FILES_PER_JOB}"
            --openfiles="${FILES_PER_JOB}"
            --filesize="${size_per_job}"
            --size="${size_per_job}"
            --bs="${BLOCK_SIZE}"
            --numjobs="${nj}"
            --iodepth="${iod}"
            "${THREAD_OPTS[@]}"
            --rw=randwrite
            --runtime="${RUNTIME_SEC}"
            --ramp_time="${RAMP_SEC}"
            --time_based=1
            --direct=1
            --buffered=0
            --group_reporting=1
            --randrepeat=0
            --norandommap=1
            --refill_buffers=1
            --lat_percentiles=1
            --clat_percentiles=1
            --slat_percentiles=1
            --percentile_list=50:90:95:99:99.9:99.99
        )

        printf '%q ' "${fio_cmd[@]}" > "${CMD_LOG}"
        printf '\n' >> "${CMD_LOG}"
        echo "Command           : $(cat "${CMD_LOG}")"

        set +e
        "${fio_cmd[@]}"
        fio_status=$?
        set -e

        end_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        TOTAL_RUNS=$((TOTAL_RUNS + 1))

        # fio can exit 0 while a job records a nonzero "error" in the JSON,
        # so the JSON is checked as well as the exit code.
        if ((fio_status != 0)); then
            status="fio_exit_${fio_status}"
        elif [[ ! -s "${RESULT_JSON}" ]]; then
            status="missing_json"
        elif grep -q '"error" *: *[1-9]' "${RESULT_JSON}"; then
            status="job_error"
        else
            status="ok"
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${CAMPAIGN_ID}" "${repeat}" "$((position + 1))" \
            "${nj}" "${iod}" "${aggregate_qd}" "${FILES_PER_JOB}" \
            "${total_objects}" "${size_per_job}" "${TOTAL_DATASET_SIZE}" \
            "${FIO_THREAD_MODE}" "${CONT}" "${RESULT_JSON}" "${CMD_LOG}" \
            "${start_utc}" "${end_utc}" "${status}" \
            >> "${MANIFEST}"

        # A failed run is recorded and skipped; the campaign continues so that
        # one bad point does not cost the remaining repetitions.
        if [[ "${status}" != "ok" ]]; then
            FAILED_RUNS=$((FAILED_RUNS + 1))
            echo "WARNING: run ${label} finished with status '${status}'; continuing." >&2
        fi

        daos container destroy "${POOL}" "${CONT}" >/dev/null
        CURRENT_CONT=""

        echo "Completed UTC      : ${end_utc}"
        echo "Status             : ${status}"

        if ((INTER_RUN_SLEEP_SEC > 0)); then
            sleep "${INTER_RUN_SLEEP_SEC}"
        fi
    done

done

SCRIPT_END_EPOCH="$(date +%s)"
ELAPSED=$((SCRIPT_END_EPOCH - SCRIPT_START_EPOCH))

if ((FAILED_RUNS > 0)); then
    printf '\nCampaign finished with %d of %d runs failed.\n' "${FAILED_RUNS}" "${TOTAL_RUNS}"
else
    printf '\nCampaign completed successfully (%d runs).\n' "${TOTAL_RUNS}"
fi
printf 'Output directory: %s\n' "${OUTPUT_DIR}"
printf 'Manifest:         %s\n' "${MANIFEST}"
printf 'Campaign log:     %s\n' "${RUN_LOG}"
printf 'Elapsed time:     %02d:%02d:%02d (hh:mm:ss)\n' \
    $((ELAPSED / 3600)) $(((ELAPSED % 3600) / 60)) $((ELAPSED % 60))

# Nonzero exit so PBS marks the job as failed, without discarding good runs.
((FAILED_RUNS == 0)) || exit 1