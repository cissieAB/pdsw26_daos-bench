#!/usr/bin/bash

# Heatmap sweep: single fio job with DFS engine, varying numjobs x block size.
# numjobs : 4 8 16 32 64
# bs      : 4k 16k 1m 2m 4m
# Each (bs, nj) pair gets a fresh POSIX container created before and destroyed after.
# Prefill step writes data with --filename=fio_data before the timed seq_read run.
# Time-based, 60 s per run.
#
# Usage: ./<this-script>.sh [N_REPEATS]
#   N_REPEATS  number of full sweeps (default: 1)

set -euox pipefail

N_REPEATS="${1:-1}"

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

# ---------------------------------------------------------------------------
# 1. Check DAOS pool
# ---------------------------------------------------------------------------
POOL="${DAOS_POOL_NAME:-iobench}"
if ! daos pool query "${POOL}" &>/dev/null; then
    echo "ERROR: DAOS pool '${POOL}' not found or not accessible." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Sweep parameters
# ---------------------------------------------------------------------------
IODEPTH=16
PATTERN="${FIO_PATTERN:-seq_read}"             # override via env if needed
RUNTIME=60                                     # seconds per test run

NUMJOB_LIST=("4" "8" "16" "32" "64")
BLOCK_SIZE_LIST=("4k" "16k" "1m" "2m" "4m")

CONT_BASE="${DAOS_CONT_NAME:-fio_dfs-heatmap}"
OUTPUT_DIR=../../../results/testbed/fio-dfs-heatmap-nj-bs-sweep

mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# 3. Cleanup trap — destroy container if script exits mid-run
# ---------------------------------------------------------------------------
CURRENT_CONT=""
cleanup() {
    if [[ -n "${CURRENT_CONT}" ]]; then
        daos container destroy "${POOL}" "${CURRENT_CONT}" &>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 4. Run sweep (repeated N_REPEATS times)
# ---------------------------------------------------------------------------
for repeat in $(seq 1 "${N_REPEATS}"); do
echo "######## Sweep ${repeat}/${N_REPEATS} started: $(date) ########"

for bs in "${BLOCK_SIZE_LIST[@]}"; do
    for nj in "${NUMJOB_LIST[@]}"; do

        label="${PATTERN}_bs${bs}_nj${nj}_iod${IODEPTH}_$(date +%s)"
        CONT="${CONT_BASE}_${label}"

        echo "========================================================"
        echo "  bs=${bs}  iodepth=${IODEPTH}  numjobs=${nj}  pattern=${PATTERN}"
        echo "  container: ${CONT}"
        echo "========================================================"

        # Create a fresh POSIX container
        daos container create --type=POSIX "${POOL}" "${CONT}" &>/dev/null || {
            echo "ERROR: failed to create container ${CONT}" >&2
            exit 1
        }
        CURRENT_CONT="${CONT}"

        echo "###### Container properties:"
        daos cont getprop "${POOL}" "${CURRENT_CONT}"
        echo

        echo "###### Container query:"
        daos cont query "${POOL}" "${CURRENT_CONT}"
        echo

        # Prefill: sequential write to populate fio_data before reading
        echo "###### Prefill: writing data with filename=fio_data ..."
        "${FIO}" \
            --name="prefill" \
            --ioengine=dfs \
            --pool="${POOL}" \
            --cont="${CURRENT_CONT}" \
            --rw=write \
            --bs=1m \
            --numjobs="${nj}" \
            --iodepth="${IODEPTH}" \
            --size=20g \
            --filename=fio_data \
            --direct=1 \
            --buffered=0 \
            --group_reporting=1 \
            --output-format=normal
        echo "###### Prefill complete."
        echo

        # Timed seq_read run
        "${FIO}" \
            --name="${PATTERN}" \
            --ioengine=dfs \
            --pool="${POOL}" \
            --cont="${CURRENT_CONT}" \
            --rw=read \
            --bs="${bs}" \
            --numjobs="${nj}" \
            --iodepth="${IODEPTH}" \
            --size=4g \
            --filename=fio_data \
            --time_based=1 \
            --runtime="${RUNTIME}" \
            --direct=1 \
            --buffered=0 \
            --group_reporting=1 \
            --output="${OUTPUT_DIR}/fio_${label}.json" \
            --output-format=json

        # Destroy container
        daos container destroy "${POOL}" "${CONT}" &>/dev/null || {
            echo "ERROR: failed to destroy container ${CONT}" >&2
        }
        CURRENT_CONT=""

        sleep 5

    done
done

echo "######## Sweep ${repeat}/${N_REPEATS} finished: $(date) ########"
done

echo "Done. Results written to ${OUTPUT_DIR}/"
