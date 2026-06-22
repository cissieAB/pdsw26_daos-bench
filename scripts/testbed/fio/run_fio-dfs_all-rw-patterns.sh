#!/usr/bin/bash

# This script runs a sweep of fio tests using the DAOS DFS engine, fixing
#  iodepth=16 and numjobs=16 while varying block size across all rw_pattern.fio sections.

set -euox pipefail

# ---------------------------------------------------------------------------
# 0. Locate fio and verify version / DFS engine support
# ---------------------------------------------------------------------------
FIO_BIN_PATH="${HOME}/local/bin/fio"

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
OUTPUT_DIR=../../../results/testbed/fio-dfs-all-patterns
TIMESTAMP=$(date +%s)

NUMJOBS=16
IODEPTH=16
BLOCK_SIZE_LIST=("4k" "16k" "1m" "2m" "4m")

for bs in "${BLOCK_SIZE_LIST[@]}"; do
    label="bs${bs}_nj${NUMJOBS}_iod${IODEPTH}_${TIMESTAMP}"
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

echo "Done. Results written to ${OUTPUT_DIR}/"
