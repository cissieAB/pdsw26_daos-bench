#!/usr/bin/env bash
#
# Controlled rerun for Figure 3 / fixed aggregate-concurrency experiment.
#
# The experiment varies (numjobs, iodepth) while holding constant:
#   - numjobs * iodepth = 256
#   - request size = 1 MiB
#   - total DFS file/object count = 64
#   - size of each DFS file = 128 MiB
#   - aggregate working-set size = 8 GiB
#   - workload = 60 s random write after a 10 s ramp period
#
# Each fio job owns a disjoint subset of the same fixed 64-file set:
#   4 x 64  -> 16 files/job x 128 MiB = 2 GiB/job
#   8 x 32  ->  8 files/job x 128 MiB = 1 GiB/job
#   16 x 16 ->  4 files/job x 128 MiB = 512 MiB/job
#   32 x 8  ->  2 files/job x 128 MiB = 256 MiB/job
#   64 x 4  ->  1 file/job  x 128 MiB = 128 MiB/job
#
# Why this replaces the previous one-shared-file control:
#   The earlier controlled attempt used one shared DFS filename plus disjoint
#   offsets. That fixed the file/object count at one, but it also forced every
#   fio job through one logical DFS object. On this testbed, the smoke test
#   observed a DAOS RPC timeout. The container query already reported
#   File Object Class = SX, so the timeout was not evidence that --file-oclass=SX
#   was missing. This version avoids the single-object contention risk while
#   still fixing total file/object count and aggregate working-set size.
#
# Usage:
#   ./run_fio-dfs_256io_sweep_fixed64files.sh [N_REPEATS]
#
# Examples:
#   ./run_fio-dfs_256io_sweep_fixed64files.sh 1   # smoke test: 5 runs
#   ./run_fio-dfs_256io_sweep_fixed64files.sh 5   # minimal paper campaign: 25 runs
#
# Optional environment variables:
#   FIO_BIN_PATH=/home/xmei/local/bin/fio
#   DAOS_POOL_NAME=iobench
#   DAOS_CONT_BASE=fio_dfs_controlled_64files
#   OUTPUT_ROOT=/path/to/results
#   RUNTIME_SEC=60
#   RAMP_SEC=10
#   INTER_RUN_SLEEP_SEC=5
#   DEBUG=1

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
    # Expected location: <repo>/scripts/testbed/fio/<this-script>
    REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
fi

FIO_BIN_PATH="${FIO_BIN_PATH:-/home/xmei/local/bin/fio}"
POOL="${DAOS_POOL_NAME:-iobench}"
CONT_BASE="${DAOS_CONT_BASE:-fio_dfs_controlled_64files}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/results/testbed/fio-dfs-256io-sweep-controlled-64files}"

BLOCK_SIZE="1M"
TOTAL_OBJECTS=64
FILE_SIZE="128m"
TOTAL_DATASET_SIZE="8g"
# Keep $jobnum and $filenum literal. fio expands them, not Bash.
FILENAME_FORMAT='fio_data.$jobnum.$filenum'
RUNTIME_SEC="${RUNTIME_SEC:-60}"
RAMP_SEC="${RAMP_SEC:-10}"
INTER_RUN_SLEEP_SEC="${INTER_RUN_SLEEP_SEC:-5}"

# Fields: numjobs:iodepth:files_per_job:size_per_job
# All configurations preserve:
#   numjobs * iodepth       = 256 outstanding I/Os (nominal)
#   numjobs * files_per_job = 64 DFS files/objects
#   numjobs * size_per_job  = 8 GiB aggregate working set
CONFIGS=(
    "4:64:16:2g"
    "8:32:8:1g"
    "16:16:4:512m"
    "32:8:2:256m"
    "64:4:1:128m"
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

echo "============================================================"
echo "Controlled fio DFS sweep: fixed 64-file layout"
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
echo "Total files       : ${TOTAL_OBJECTS}"
echo "File size         : ${FILE_SIZE}"
echo "Total dataset     : ${TOTAL_DATASET_SIZE}"
echo "Filename format   : ${FILENAME_FORMAT}"
echo "Measured runtime  : ${RUNTIME_SEC} s"
echo "Ramp time         : ${RAMP_SEC} s"
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
    $'campaign\trepeat\tposition\tnumjobs\tiodepth\taggregate_qd\tfiles_per_job\ttotal_files\tfile_size\tsize_per_job\ttotal_dataset_size\tcontainer\tresult_json\tstart_utc\tend_utc\tstatus' \
    > "${MANIFEST}"

SCRIPT_START_EPOCH="$(date +%s)"

for ((repeat = 1; repeat <= N_REPEATS; repeat++)); do
    # Cyclically rotate the starting configuration on each repetition.
    # Across five repetitions, every configuration occupies every order position once.
    start_index=$(((repeat - 1) % N_CONFIGS))

    echo
    echo "######## Repetition ${repeat}/${N_REPEATS}; rotation start=${start_index} ########"

    for ((position = 0; position < N_CONFIGS; position++)); do
        config_index=$(((start_index + position) % N_CONFIGS))
        IFS=':' read -r nj iod files_per_job size_per_job <<< "${CONFIGS[config_index]}"

        aggregate_qd=$((nj * iod))
        total_files=$((nj * files_per_job))

        if ((aggregate_qd != 256)); then
            echo "ERROR: invalid configuration nj=${nj}, iod=${iod}; aggregate QD=${aggregate_qd}." >&2
            exit 1
        fi
        if ((total_files != TOTAL_OBJECTS)); then
            echo "ERROR: invalid file layout nj=${nj}, files_per_job=${files_per_job}; total_files=${total_files}." >&2
            exit 1
        fi

        timestamp="$(date +%s)"
        label="r${repeat}_p$((position + 1))_bs${BLOCK_SIZE}_nj${nj}_iod${iod}_${timestamp}"
        CONT="${CONT_BASE}_${label}"
        RESULT_JSON="${OUTPUT_DIR}/fio_${label}.json"
        PROP_LOG="${OUTPUT_DIR}/container_${label}.properties.txt"
        QUERY_LOG="${OUTPUT_DIR}/container_${label}.query.txt"
        start_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

        echo
        echo "------------------------------------------------------------"
        echo "Repeat / position : ${repeat}/${N_REPEATS}, $((position + 1))/${N_CONFIGS}"
        echo "Configuration     : numjobs=${nj}, iodepth=${iod}, aggregate_qd=${aggregate_qd}"
        echo "Files per job     : ${files_per_job}"
        echo "Total files       : ${total_files}"
        echo "File size         : ${FILE_SIZE}"
        echo "Size per job      : ${size_per_job}"
        echo "Total dataset     : ${TOTAL_DATASET_SIZE}"
        echo "Container         : ${CONT}"
        echo "Result            : ${RESULT_JSON}"
        echo "Start UTC         : ${start_utc}"
        echo "------------------------------------------------------------"

        # Keep the container creation command consistent with the original script.
        # The saved query/getprop output must be checked for the actual file object
        # class. On the current testbed it reports File Object Class = SX already,
        # so adding --file-oclass=SX would be redundant rather than a timeout fix.
        daos container create --type=POSIX "${POOL}" "${CONT}" >/dev/null
        CURRENT_CONT="${CONT}"

        daos container getprop "${POOL}" "${CONT}" >"${PROP_LOG}"
        daos container query "${POOL}" "${CONT}" >"${QUERY_LOG}"

        # ---------------------------------------------------------------------
        # OLD ONE-SHARED-FILE CONTROL (DO NOT USE)
        # ---------------------------------------------------------------------
        # The following layout fixed object count at one, but all jobs accessed
        # the same logical DFS object. Even with File Object Class = SX, this can
        # create single-object contention. A smoke test observed DER_TIMEDOUT.
        # The timeout does not prove all requests went to one target; SX is
        # striped. The issue is that the experiment unnecessarily funnels all
        # jobs through one logical object.
        #
        #   --filename="fio_data.shared" \
        #   --filesize="8g" \
        #   --size="${size_per_job}" \
        #   --offset=0 \
        #   --offset_increment="${size_per_job}" \
        #
        # REPLACEMENT BELOW:
        #   - fixed 64 generated files for every configuration
        #   - each file is 128 MiB
        #   - each job receives 64/numjobs files
        #   - filenames remain unique through $jobnum and $filenum
        # ---------------------------------------------------------------------

        set +e
        "${FIO}" \
            --output="${RESULT_JSON}" \
            --output-format=json \
            --name=rand_write \
            --ioengine=dfs \
            --pool="${POOL}" \
            --cont="${CONT}" \
            --filename_format="${FILENAME_FORMAT}" \
            --nrfiles="${files_per_job}" \
            --openfiles="${files_per_job}" \
            --filesize="${FILE_SIZE}" \
            --size="${size_per_job}" \
            --file_service_type=roundrobin \
            --bs="${BLOCK_SIZE}" \
            --numjobs="${nj}" \
            --iodepth="${iod}" \
            --rw=randwrite \
            --runtime="${RUNTIME_SEC}" \
            --ramp_time="${RAMP_SEC}" \
            --time_based=1 \
            --direct=1 \
            --buffered=0 \
            --group_reporting=1 \
            --randrepeat=0 \
            --norandommap=1 \
            --refill_buffers=1 \
            --lat_percentiles=1 \
            --clat_percentiles=1 \
            --slat_percentiles=1 \
            --percentile_list=50:90:95:99:99.9:99.99
        fio_status=$?
        set -e

        end_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

        if ((fio_status == 0)); then
            status="ok"
        else
            status="fio_exit_${fio_status}"
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${CAMPAIGN_ID}" "${repeat}" "$((position + 1))" \
            "${nj}" "${iod}" "${aggregate_qd}" "${files_per_job}" \
            "${total_files}" "${FILE_SIZE}" "${size_per_job}" \
            "${TOTAL_DATASET_SIZE}" "${CONT}" "${RESULT_JSON}" \
            "${start_utc}" "${end_utc}" "${status}" \
            >> "${MANIFEST}"

        if ((fio_status != 0)); then
            echo "ERROR: fio failed with exit code ${fio_status}." >&2
            exit "${fio_status}"
        fi

        if [[ ! -s "${RESULT_JSON}" ]]; then
            echo "ERROR: fio returned success but '${RESULT_JSON}' is missing or empty." >&2
            exit 1
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

printf '\nCampaign completed successfully.\n'
printf 'Output directory: %s\n' "${OUTPUT_DIR}"
printf 'Manifest:         %s\n' "${MANIFEST}"
printf 'Campaign log:     %s\n' "${RUN_LOG}"
printf 'Elapsed time:     %02d:%02d:%02d (hh:mm:ss)\n' \
    $((ELAPSED / 3600)) $(((ELAPSED % 3600) / 60)) $((ELAPSED % 60))
