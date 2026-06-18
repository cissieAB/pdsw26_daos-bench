#!/usr/bin/bash

# fio rand_write: DAOS POSIX container via dfuse (no interception lib)
# Loops over ioengines: libaio, psync, pvsync2
# numjobs=16, iodepth=16, runtime=60 s
#
# Env overrides:
#   DAOS_POOL_NAME   (default: e2sar)
#   DAOS_CONT_NAME   (default: fio_dfuse)
#   DFUSE_MNT        (default: /tmp/<pool>/<cont>)
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
ENGINES=(libaio psync pvsync2)

POOL="${DAOS_POOL_NAME:-e2sar}"
CONT="${DAOS_CONT_NAME:-fio_dfuse}"
DFUSE_MNT="${DFUSE_MNT:-/tmp/$USER/${POOL}/${CONT}}"

NUMJOBS=16
IODEPTH=16
BS="${FIO_BS:-1m}"
RUNTIME=60
SIZE="2g"

OUTPUT_DIR=../../../results/aurora/fio/3engines-rand_write
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

if ! daos pool query "${POOL}" | grep -i "ntarget"; then
    echo "ERROR: DAOS pool '${POOL}' not found or not Ready." >&2
    exit 1
fi

echo
echo "Pool:    ${POOL}"
echo "Engines: ${ENGINES[*]} via dfuse (no interception lib)"
echo "Pattern: rand_write"
echo "numjobs=${NUMJOBS}  iodepth=${IODEPTH}  bs=${BS}  runtime=${RUNTIME}s"
echo

# ---------------------------------------------------------------------------
# 2. Cleanup helpers
# ---------------------------------------------------------------------------
CURRENT_CONT=""

cleanup() {
    if [[ -n "${CURRENT_CONT}" ]]; then
        fusermount3 -u "${DFUSE_MNT}" &>/dev/null || true
        daos container destroy "${POOL}" "${CURRENT_CONT}" &>/dev/null || true
        CURRENT_CONT=""
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 3. Create container and mount dfuse once
# ---------------------------------------------------------------------------
echo "========================================================"
echo "  Creating container: ${CONT}"
echo "========================================================"

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

mkdir -p "${DFUSE_MNT}"
# Mounting script on compute nodes
launch-dfuse.sh ${POOL}:${CONT}
sleep 3
mount | grep dfuse

# ---------------------------------------------------------------------------
# 4. Loop over engines x 10 runs each
# ---------------------------------------------------------------------------
NRUNS=10

for FIOENGINE in "${ENGINES[@]}"; do
    for (( RUN=1; RUN<=NRUNS; RUN++ )); do
        TIMESTAMP=$(date +%s)
        LABEL="dfuse_${FIOENGINE}_bs${BS}_nj${NUMJOBS}_iod${IODEPTH}_${TIMESTAMP}"

        echo "========================================================"
        echo "  Engine: ${FIOENGINE}  run ${RUN}/${NRUNS}  (dfuse, no IL)"
        echo "  Wiping container contents ..."
        echo "========================================================"
        rm -rf "${DFUSE_MNT:?}"/*

        "${FIO}" \
            --name="rand_write" \
            --ioengine=${FIOENGINE} \
            --rw=randwrite \
            --bs="${BS}" \
            --numjobs="${NUMJOBS}" \
            --iodepth="${IODEPTH}" \
            --size="${SIZE}" \
            --directory="${DFUSE_MNT}" \
            --nrfiles=4 \
            --time_based=1 \
            --runtime="${RUNTIME}" \
            --direct=1 \
            --buffered=0 \
            --randrepeat=0 \
            --norandommap \
            --refill_buffers \
            --group_reporting=1 \
            --output="${OUTPUT_DIR}/fio_${LABEL}.json" \
            --output-format=json

        echo "Done: ${OUTPUT_DIR}/fio_${LABEL}.json"
        sleep 10

        rm -rf ${DFUSE_MNT}/*
    done
done

# ---------------------------------------------------------------------------
# 5. Teardown
# ---------------------------------------------------------------------------
fusermount3 -u "${DFUSE_MNT}"
daos container destroy "${POOL}" "${CONT}" &>/dev/null \
    || echo "WARNING: failed to destroy container ${CONT}" >&2
CURRENT_CONT=""

echo "========================================================"
echo "All runs complete."
echo "========================================================"
