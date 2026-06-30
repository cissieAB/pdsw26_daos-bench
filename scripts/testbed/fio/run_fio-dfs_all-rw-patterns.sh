#!/usr/bin/bash

# This script runs a sweep of fio tests using the DAOS DFS engine, fixing
#  iodepth=16 and numjobs=16 while varying block size across all rw_pattern.fio sections.
#
# NOTE: rw_pattern.fio uses size=20g per job (320 GiB total across 16 jobs).
# This was increased from 128m after analysis showed the smaller working set
# caused fio's time_based=1 read sections to loop hundreds of times over the
# same recently-overwritten data within each 60-s window, making measured
# read bandwidth highly sensitive to run-to-run differences in how much of
# that churn had settled rather than to steady-state storage performance.
# At 20g/job, prefill now writes ~320 GiB sequentially before each block-size
# sweep (adds tens of seconds of wall-clock time per bs value, depending on
# write bandwidth), and the 60-s read sections complete roughly one pass
# instead of many.
#
# Usage: ./<this-script>.sh [N_REPEATS]
#   N_REPEATS  number of full sweeps (default: 1)

set -euox pipefail

N_REPEATS="${1:-1}"
SCRIPT_START=$(date +%s)

# ---------------------------------------------------------------------------
# 0. Locate fio and verify version / DFS engine support
# ---------------------------------------------------------------------------
FIO_BIN_PATH="/home/xmei/local/bin/fio"

if [[ ! -x "${FIO_BIN_PATH}" ]]; then
    echo "ERROR: fio not found or not executable at ${FIO_BIN_PATH}" >&2
    exit 1
fi

FIO_VERSION=$("${FIO_BIN_PATH}" --version | awk '{print $2}')

echo "Using fio: ${FIO_BIN_PATH}"
echo "Detected version: ${FIO_VERSION}"

FIO="${FIO_BIN_PATH}"
if ! "${FIO}" --enghelp dfs &>/dev/null; then
    echo "ERROR: fio-${FIO_VERSION} does not have the dfs ioengine compiled in." >&2
    exit 1
fi
echo "fio version OK (${FIO_VERSION}) and dfs engine is available."
echo

# Confirm DAOS pool is accessible
POOL="${DAOS_POOL_NAME:-iobench}"
if ! daos pool query "${POOL}" &>/dev/null; then
    echo "ERROR: DAOS pool '${POOL}' not found or not accessible." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Run fio tests.
#    iodepth and numjobs are fixed at 16; block size is swept.
#    All rw_pattern.fio sections run in a single fio invocation per block size.
# ---------------------------------------------------------------------------

CURRENT_CONT=""
cleanup() {
    if [[ -n "${CURRENT_CONT}" ]]; then
        daos container destroy "${POOL}" "${CURRENT_CONT}" &>/dev/null || true
    fi
}
trap cleanup EXIT

CONT_BASE="${DAOS_CONT_NAME:-fio_dfs-all-rw-patterns}"
OUTPUT_DIR=../../../results/testbed/fio-dfs-all-rw-patterns

NUMJOBS=16
IODEPTH=16
BLOCK_SIZE_LIST=("4k" "16k" "1m" "2m" "4m")

for repeat in $(seq 1 "${N_REPEATS}"); do
echo "######## Sweep ${repeat}/${N_REPEATS} started: $(date) ########"

    for bs in "${BLOCK_SIZE_LIST[@]}"; do
        label="bs${bs}_nj${NUMJOBS}_iod${IODEPTH}_$(date +%s)"
        CONT="${CONT_BASE}_${label}"

        mkdir -p "${OUTPUT_DIR}"

        echo "DAOS container: ${CONT}"
        echo "fio parameters: numjobs=${NUMJOBS}, iodepth=${IODEPTH}, bs=${bs}"
        echo "Output directory: ${OUTPUT_DIR}"
        echo

        daos container create --type=POSIX "${POOL}" "${CONT}" &>/dev/null || {
            echo "ERROR: failed to create container ${CONT} in pool ${POOL}" >&2
            exit 1
        }
        CURRENT_CONT="${CONT}"

        echo "###### Container properties:"
        daos cont getprop "${POOL}" "${CURRENT_CONT}"
        echo

        echo "###### Container query"
        daos cont query "${POOL}" "${CURRENT_CONT}"
        echo

        ${FIO} \
            --ioengine=dfs \
            --pool="${POOL}" \
            --cont="${CURRENT_CONT}" \
            --bs="${bs}" \
            --numjobs="${NUMJOBS}" \
            --iodepth="${IODEPTH}" \
            --output="${OUTPUT_DIR}/fio_${label}.json" \
            --output-format=json \
            rw_pattern.fio

        daos container destroy "${POOL}" "${CONT}" &>/dev/null || {
            echo "ERROR: failed to destroy container ${CONT} in pool ${POOL}" >&2
        }
        CURRENT_CONT=""

        sleep 5

    done

echo "######## Sweep ${repeat}/${N_REPEATS} finished: $(date) ########"
done

SCRIPT_END=$(date +%s)
ELAPSED=$(( SCRIPT_END - SCRIPT_START ))
printf "Total elapsed time: %02d:%02d:%02d (hh:mm:ss)\n" $((ELAPSED/3600)) $(( (ELAPSED%3600)/60 )) $((ELAPSED%60))
echo "Done. Results written to ${OUTPUT_DIR}/"
