#!/usr/bin/env bash
#
# Controlled rerun for Figure 3 / fixed aggregate-concurrency experiment.
#
# The experiment varies (numjobs, iodepth) while holding constant:
#   - numjobs * iodepth = 256
#   - request size = 1 MiB
#   - aggregate address space = 8 GiB
#   - active DFS filename = 1 shared file
#   - workload = 60 s random write after a 10 s ramp period
#
# Each fio sub-job writes a disjoint region of the same 8 GiB file:
#   4 x 64  -> 2 GiB per job
#   8 x 32  -> 1 GiB per job
#   16 x 16 -> 512 MiB per job
#   32 x 8  -> 256 MiB per job
#   64 x 4  -> 128 MiB per job
#
# Usage:
#   ./run_fio-dfs_256io_sweep_controlled.sh [N_REPEATS]
#
# Examples:
#   ./run_fio-dfs_256io_sweep_controlled.sh 1   # smoke test: 5 runs
#   ./run_fio-dfs_256io_sweep_controlled.sh 5   # minimal paper campaign: 25 runs
#
# Optional environment variables:
#   FIO_BIN_PATH=/home/xmei/local/bin/fio
#   DAOS_POOL_NAME=iobench
#   DAOS_CONT_BASE=fio_dfs_controlled
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
CONT_BASE="${DAOS_CONT_BASE:-fio_dfs_controlled}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${REPO_ROOT}/results/testbed/fio-dfs-256io-sweep-controlled}"

BLOCK_SIZE="1M"
TOTAL_FILE_SIZE="8g"
SHARED_FILENAME="fio_data.shared"
RUNTIME_SEC="${RUNTIME_SEC:-60}"
RAMP_SEC="${RAMP_SEC:-10}"
INTER_RUN_SLEEP_SEC="${INTER_RUN_SLEEP_SEC:-5}"

# The five configurations preserve numjobs * iodepth = 256.
CONFIGS=(
    "4:64:2g"
    "8:32:1g"
    "16:16:512m"
    "32:8:256m"
    "64:4:128m"
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
echo "Controlled fio DFS sweep"
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
echo "Shared file       : ${SHARED_FILENAME}"
echo "Total file size   : ${TOTAL_FILE_SIZE}"
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
    $'campaign\trepeat\tposition\tnumjobs\tiodepth\taggregate_qd\tregion_size\ttotal_file_size\tcontainer\tresult_json\tstart_utc\tend_utc\tstatus' \
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
        IFS=':' read -r nj iod region_size <<< "${CONFIGS[config_index]}"

        aggregate_qd=$((nj * iod))
        if ((aggregate_qd != 256)); then
            echo "ERROR: invalid configuration nj=${nj}, iod=${iod}; aggregate QD=${aggregate_qd}." >&2
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
        echo "Per-job region    : ${region_size}"
        echo "Shared file size  : ${TOTAL_FILE_SIZE}"
        echo "Container         : ${CONT}"
        echo "Result            : ${RESULT_JSON}"
        echo "Start UTC         : ${start_utc}"
        echo "------------------------------------------------------------"

        daos container create --type=POSIX "${POOL}" "${CONT}" >/dev/null
        CURRENT_CONT="${CONT}"

        daos container getprop "${POOL}" "${CONT}" >"${PROP_LOG}"
        daos container query "${POOL}" "${CONT}" >"${QUERY_LOG}"

        set +e
        "${FIO}" \
            --output="${RESULT_JSON}" \
            --output-format=json \
            --name=rand_write \
            --ioengine=dfs \
            --pool="${POOL}" \
            --cont="${CONT}" \
            --filename="${SHARED_FILENAME}" \
            --filesize="${TOTAL_FILE_SIZE}" \
            --size="${region_size}" \
            --offset=0 \
            --offset_increment="${region_size}" \
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

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${CAMPAIGN_ID}" "${repeat}" "$((position + 1))" \
            "${nj}" "${iod}" "${aggregate_qd}" "${region_size}" \
            "${TOTAL_FILE_SIZE}" "${CONT}" "${RESULT_JSON}" \
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
