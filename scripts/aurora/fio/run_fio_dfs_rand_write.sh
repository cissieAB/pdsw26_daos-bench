#!/usr/bin/bash

# fio rand_write: DAOS POSIX container via native DFS engine
# Container is destroyed and recreated before each run.
# numjobs=16, iodepth=16, runtime=60 s
#
# Usage: ./<this-script>.sh [N_REPEATS]
#   N_REPEATS  number of runs (default: 1)
#
# Env overrides:
#   DAOS_POOL_NAME   (default: e2sar)
#   DAOS_CONT_NAME   (default: fio_dfs)
#   FIO_BS           (default: 1m)

set -euox pipefail

# Compute node default path is $HOME
WKDIR=$HOME/iobench/pdsw26_daos-bench/scripts/aurora/fio   # <=== Change dir as needed
cd "${WKDIR}"

# Load DAOS module
echo "Loading DAOS module"
module use /soft/modulefiles/ || { echo "ERROR: Failed to use modulefiles" >&2; exit 1; }
module load daos || { echo "ERROR: Failed to load DAOS module" >&2; exit 1; }


# ---------------------------------------------------------------------------
# 0. Config
# ---------------------------------------------------------------------------
FIO="${HOME}/local/bin/fio"

POOL="${DAOS_POOL_NAME:-e2sar}"
CONT="${DAOS_CONT_NAME:-fio_dfs}"

NUMJOBS=16
IODEPTH=16
BS="${FIO_BS:-1m}"
RUNTIME=60
SIZE="2g"
FIO_FILE="fio_data"
NRUNS="${1:-10}"

OUTPUT_DIR=../../../results/aurora/fio/engine
mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# 1. Sanity checks
# ---------------------------------------------------------------------------
if [[ ! -x "${FIO}" ]]; then
    echo "ERROR: fio not found or not executable at ${FIO}" >&2
    exit 1
fi

FIO_VERSION=$("${FIO}" --version | awk '{print $2}')
echo "Using fio: ${FIO} (${FIO_VERSION})"

if ! "${FIO}" --enghelp dfs &>/dev/null; then
    echo "ERROR: fio-${FIO_VERSION} does not have the dfs ioengine compiled in." >&2
    exit 1
fi
echo "fio version OK and dfs engine is available."

if ! daos pool query "${POOL}" | grep -i "ntarget"; then
    echo "ERROR: DAOS pool '${POOL}' not found or not Ready." >&2
    exit 1
fi

echo
echo "Pool:    ${POOL}"
echo "Engine:  DAOS native DFS"
echo "Pattern: rand_write"
echo "numjobs=${NUMJOBS}  iodepth=${IODEPTH}  bs=${BS}  runtime=${RUNTIME}s"
echo

# ---------------------------------------------------------------------------
# 2. Cleanup helper
# ---------------------------------------------------------------------------
CURRENT_CONT=""

cleanup() {
    if [[ -n "${CURRENT_CONT}" ]]; then
        daos container destroy "${POOL}" "${CURRENT_CONT}" &>/dev/null || true
        CURRENT_CONT=""
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 3. Loop 10 runs — destroy/recreate container before each run
# ---------------------------------------------------------------------------
for (( RUN=1; RUN<=NRUNS; RUN++ )); do
    TIMESTAMP=$(date +%s)
    LABEL="dfs_bs${BS}_nj${NUMJOBS}_iod${IODEPTH}_${TIMESTAMP}"

    echo "========================================================"
    echo "  DAOS native DFS engine  run ${RUN}/${NRUNS}"
    echo "  Recreating container: ${CONT}"
    echo "========================================================"

    # Destroy previous container if it exists
    daos container destroy "${POOL}" "${CONT}" &>/dev/null || true
    CURRENT_CONT=""

    daos container create --type=POSIX --properties rd_fac:0 "${POOL}" "${CONT}" || {
        echo "ERROR: failed to create container ${CONT}" >&2
        exit 1
    }
    CURRENT_CONT="${CONT}"
    echo "###### Container properties:"
    daos cont getprop "${POOL}" "${CONT}"
    echo "###### Container query:"
    daos cont query "${POOL}" "${CONT}"
    echo

    "${FIO}" \
        --name="rand_write" \
        --ioengine=dfs \
        --pool="${POOL}" \
        --cont="${CONT}" \
        --rw=randwrite \
        --bs="${BS}" \
        --numjobs="${NUMJOBS}" \
        --iodepth="${IODEPTH}" \
        --size="${SIZE}" \
        --filename="${FIO_FILE}" \
        --time_based=1 \
        --runtime="${RUNTIME}" \
        --randrepeat=0 \
        --norandommap \
        --refill_buffers \
        --group_reporting=1 \
        --output="${OUTPUT_DIR}/fio_${LABEL}.json" \
        --output-format=json

    echo "Done: ${OUTPUT_DIR}/fio_${LABEL}.json"

    daos container destroy "${POOL}" "${CONT}" &>/dev/null \
        || echo "WARNING: failed to destroy container ${CONT}" >&2
    CURRENT_CONT=""

    sleep 10
done

echo "========================================================"
echo "All runs complete."
echo "========================================================"
