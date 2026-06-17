#!/usr/bin/bash

# fio rand_write: DAOS POSIX container via dfuse, libaio engine + libpil4dfs interception lib
# numjobs=16, iodepth=16, runtime=60 s
#
# Env overrides:
#   DAOS_POOL_NAME   (default: e2sar)
#   DAOS_CONT_NAME   (default: fio_libil)
#   DAOS_LIBIL       (default: /usr/lib64/libpil4dfs.so, /usr/lib64/libioil.so)
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

POOL="${DAOS_POOL_NAME:-e2sar}"
CONT="${DAOS_CONT_NAME:-fio_libil}"
# libpil4dfs hangs with fio
LIBIL="${DAOS_LIBIL:-/usr/lib64/libioil.so}"
DFUSE_MNT="${DFUSE_MNT:-/tmp/${POOL}/${CONT}}"

NUMJOBS=16
IODEPTH=16
BS="${FIO_BS:-1m}"
RUNTIME=60
SIZE="2g"
TIMESTAMP=$(date +%s)

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

if [[ ! -f "${LIBIL}" ]]; then
    echo "ERROR: interception library not found at ${LIBIL}" >&2
    exit 1
fi
echo "Using interception lib: ${LIBIL}"

if ! daos pool query "${POOL}" | grep -i "ntarget"; then
    echo "ERROR: DAOS pool '${POOL}' not found or not Ready." >&2
    exit 1
fi

echo
echo "Pool:    ${POOL}"
echo "Engine:  libaio via dfuse + LD_PRELOAD=${LIBIL}"
echo "Pattern: rand_write"
echo "numjobs=${NUMJOBS}  iodepth=${IODEPTH}  bs=${BS}  runtime=${RUNTIME}s"
echo

# ---------------------------------------------------------------------------
# 2. Cleanup helpers
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
# 3. Run
# ---------------------------------------------------------------------------
LABEL="libil_bs${BS}_nj${NUMJOBS}_iod${IODEPTH}_${TIMESTAMP}"

echo "========================================================"
echo "  dfuse + libaio + nterception lib"
echo "  container: ${CONT}"
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

LD_PRELOAD="${LIBIL}" "${FIO}" \
    --name="rand_write" \
    --ioengine=libaio \
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

# Unmount container on compute nodes
clean-dfuse.sh /tmp/$POOL/$CONT
daos container destroy "${POOL}" "${CONT}" &>/dev/null \
    || echo "WARNING: failed to destroy container ${CONT}" >&2
CURRENT_CONT=""

echo "========================================================"
echo "Done. Result: ${OUTPUT_DIR}/fio_${LABEL}.json"
echo "========================================================"
