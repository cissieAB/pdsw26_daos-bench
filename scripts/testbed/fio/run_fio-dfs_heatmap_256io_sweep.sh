#!/usr/bin/bash

# This script runs a sweep of fio tests using the DAOS DFS engine, varying
#  numjobs and iodepth together to keep total queue depth constant at 256.

set -euox pipefail

# ---------------------------------------------------------------------------
# 0. Locate fio and verify version / DFS engine support
# ---------------------------------------------------------------------------
FIO_BIN_PATH="${HOME}/local/bin/fio"

if [[ ! -x "${FIO_BIN_PATH}" ]]; then
    echo "ERROR: fio not found or not executable at ${FIO_BIN_PATH}" >&2
    exit 1
fi

# Confirm fio version and DFS engine support
FIO_VERSION=$("${FIO_BIN_PATH}" --version | awk '{print $2}')

echo "Using fio: ${FIO_BIN_PATH}"
echo "Detected version: ${FIO_VERSION}"

FIO="${FIO_BIN_PATH}"
# Confirm the DFS ioengine is available
if ! "${FIO}" --enghelp dfs &>/dev/null; then
    echo "ERROR: fio-${FIO_VERSION} does not have the dfs ioengine compiled in." >&2
    exit 1
fi 
echo "fio version OK (${FIO_VERSION}) and dfs engine is available."
echo

# Confirm DAOS pool is accessible
POOL="${DAOS_POOL_NAME:-iobench}"         # DAOS pool UUID or label
if ! daos pool query "${POOL}" &>/dev/null; then
    echo "ERROR: DAOS pool '${POOL}' not found or not accessible." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Run fio tests. 
#    numjobs and iodepth are swept together to keep total queue depth constant at 256.
# ---------------------------------------------------------------------------

CURRENT_CONT=""
cleanup() {
    if [[ -n "${CURRENT_CONT}" ]]; then
        daos container destroy "${POOL}" "${CURRENT_CONT}" &>/dev/null || true
    fi
}
trap cleanup EXIT

CONT_BASE="${DAOS_CONT_NAME:-fio_dfs-bs1m}"       # DAOS container name
OUTPUT_DIR=../../../results/testbed/fio-dfs-heatmap-256io-sweep   # base output directory for results
TIMESTAMP=$(date +%s)

# fio parameter list
NUMJOBS_LIST=("4" "8" "16" "32" "64")                     # number of fio jobs
IODEPTH_LIST=("64" "32" "16" "8" "4")                     # io depth per job
BLOCK_SIZE="1M"                                         # block size for all tests

for run_id in "${!NUMJOBS_LIST[@]}"; do
    nj=${NUMJOBS_LIST[$run_id]}
    iod=${IODEPTH_LIST[$run_id]}

    bs="${BLOCK_SIZE}"
    label="bs${bs}_nj${nj}_iod${iod}_${TIMESTAMP}"
    CONT="${CONT_BASE}_${label}"

    mkdir -p "${OUTPUT_DIR}"

    echo "DAOS container: ${CONT}"
    echo "fio parameters: numjobs=${nj}, iodepth=${iod}, bs=${bs}"
    echo "Output directory: ${OUTPUT_DIR}"
    echo

    # Create container for this run
    # Must be a posix container
    daos container create --type=POSIX "${POOL}" "${CONT}" &>/dev/null || {
        echo "ERROR: failed to create container ${CONT} in pool ${POOL}" >&2
        exit 1
    }
    CURRENT_CONT="${CONT}"

    echo "###### Container properties:"
    daos cont getprop ${POOL} ${CURRENT_CONT}
    echo

    echo "###### Container query"
    daos cont query ${POOL} ${CURRENT_CONT}
    echo

    # Run fio
    ${FIO} \
        --ioengine=dfs \
        --size=128m \
        --pool="${POOL}" \
        --cont="${CURRENT_CONT}" \
        --bs="${bs}" \
        --numjobs="${nj}" \
        --iodepth="${iod}" \
        --output="${OUTPUT_DIR}/fio_${label}.json" \
        --output-format=json \
        rw_pattern.fio --section=rand_write

    # Destroy container after each run
    daos container destroy "${POOL}" "${CONT}" &>/dev/null || {
        echo "ERROR: failed to destroy container ${CONT} in pool ${POOL}" >&2
    }
    CURRENT_CONT=""

    sleep 5

done

echo "Done. Results written to ${OUTPUT_DIR}/"
