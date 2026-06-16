#!/usr/bin/bash

# Compare three fio I/O engines on a DAOS POSIX container (rand_write, 60 s):
#   1. libaio via dfuse mount (no interception lib)
#   2. libaio via dfuse mount + LD_PRELOAD=libioil.so (I/O interception lib)
#   3. DAOS native DFS engine
#
# Each engine gets a fresh POSIX container (--properties df_fac:0) to ensure
# independent results.  Fixed: numjobs=16, iodepth=16, runtime=60 s.
#
# Env overrides:
#   DAOS_POOL_NAME   (default: e2sar)
#   DAOS_CONT_NAME   (default: fio_3engines)
#   DAOS_LIBIOIL     (default: /usr/lib64/libpil4dfs.so)
#   DFUSE_MNT        (default: /tmp/dfuse_fio_3engines_$$)
#   FIO_BS           (default: 1m)

set -euox pipefail

# ---------------------------------------------------------------------------
# 0. Config
# ---------------------------------------------------------------------------
FIO="${HOME}/local/bin/fio"

POOL="${DAOS_POOL_NAME:-e2sar}"
CONT_BASE="${DAOS_CONT_NAME:-fio_3engines}"
LIBIOIL="${DAOS_LIBIOIL:-/usr/lib64/libpil4dfs.so}"
DFUSE_MNT="${DFUSE_MNT:-/tmp/dfuse_fio_3engines_$$}"

NUMJOBS=16
IODEPTH=16
BS="${FIO_BS:-1m}"
RUNTIME=60
SIZE="2g"
FIO_FILE="fio_data"
TIMESTAMP=$(date +%s)

OUTPUT_DIR=../../../results/aurora/fio-3engines-rand_write
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

if [[ ! -f "${LIBIOIL}" ]]; then
    echo "WARNING: libioil not found at ${LIBIOIL}; engine 2 will be skipped." >&2
fi

if ! daos pool query "${POOL}" &>/dev/null; then
    echo "ERROR: DAOS pool '${POOL}' not accessible." >&2
    exit 1
fi

echo
echo "Pool:    ${POOL}"
echo "Pattern: rand_write"
echo "numjobs=${NUMJOBS}  iodepth=${IODEPTH}  bs=${BS}  runtime=${RUNTIME}s"
echo

mkdir -p "${DFUSE_MNT}"

# ---------------------------------------------------------------------------
# 2. Cleanup helpers
# ---------------------------------------------------------------------------
CURRENT_CONT=""

dfuse_unmount() {
    if mountpoint -q "${DFUSE_MNT}" 2>/dev/null; then
        fusermount3 -u "${DFUSE_MNT}" 2>/dev/null \
            || fusermount -u "${DFUSE_MNT}" 2>/dev/null \
            || umount "${DFUSE_MNT}" || true
        sleep 2
    fi
}

cleanup() {
    dfuse_unmount
    if [[ -n "${CURRENT_CONT}" ]]; then
        daos container destroy "${POOL}" "${CURRENT_CONT}" &>/dev/null || true
        CURRENT_CONT=""
    fi
    rmdir "${DFUSE_MNT}" 2>/dev/null || true
}
trap cleanup EXIT

create_cont() {
    local name="$1"
    daos container create --type=POSIX --properties rd_fac:0 "${POOL}" "${name}" || {
        echo "ERROR: failed to create container ${name}" >&2
        exit 1
    }
    CURRENT_CONT="${name}"
    echo "###### Container properties:"
    daos cont getprop "${POOL}" "${name}"
    echo "###### Container query:"
    daos cont query "${POOL}" "${name}"
    echo
}

destroy_cont() {
    local name="$1"
    daos container destroy "${POOL}" "${name}" &>/dev/null || {
        echo "WARNING: failed to destroy container ${name}" >&2
    }
    CURRENT_CONT=""
    sleep 5
}

# ---------------------------------------------------------------------------
# 3. Engine 1 — dfuse + libaio (no interception lib)
# ---------------------------------------------------------------------------
echo "========================================================"
echo "  Engine 1: dfuse + libaio (no interception lib)"
echo "========================================================"
LABEL="libaio_dfuse_noint_bs${BS}_nj${NUMJOBS}_iod${IODEPTH}_${TIMESTAMP}"
CONT="${CONT_BASE}_eng1_${TIMESTAMP}"
create_cont "${CONT}"

dfuse --pool="${POOL}" --container="${CONT}" --mountpoint="${DFUSE_MNT}"
sleep 3

"${FIO}" \
    --name="rand_write" \
    --ioengine=libaio \
    --rw=randwrite \
    --bs="${BS}" \
    --numjobs="${NUMJOBS}" \
    --iodepth="${IODEPTH}" \
    --size="${SIZE}" \
    --filename="${DFUSE_MNT}/${FIO_FILE}" \
    --time_based=1 \
    --runtime="${RUNTIME}" \
    --direct=1 \
    --buffered=0 \
    --group_reporting=1 \
    --output="${OUTPUT_DIR}/fio_${LABEL}.json" \
    --output-format=json

dfuse_unmount
destroy_cont "${CONT}"

# ---------------------------------------------------------------------------
# 4. Engine 2 — dfuse + libaio + libioil (I/O interception lib)
# ---------------------------------------------------------------------------
echo "========================================================"
echo "  Engine 2: dfuse + libaio + libioil (interception lib)"
echo "========================================================"
if [[ -f "${LIBIOIL}" ]]; then
    LABEL="libaio_dfuse_libioil_bs${BS}_nj${NUMJOBS}_iod${IODEPTH}_${TIMESTAMP}"
    CONT="${CONT_BASE}_eng2_${TIMESTAMP}"
    create_cont "${CONT}"

    dfuse --pool="${POOL}" --container="${CONT}" --mountpoint="${DFUSE_MNT}"
    sleep 3

    LD_PRELOAD="${LIBIOIL}" "${FIO}" \
        --name="rand_write" \
        --ioengine=libaio \
        --rw=randwrite \
        --bs="${BS}" \
        --numjobs="${NUMJOBS}" \
        --iodepth="${IODEPTH}" \
        --size="${SIZE}" \
        --filename="${DFUSE_MNT}/${FIO_FILE}" \
        --time_based=1 \
        --runtime="${RUNTIME}" \
        --direct=1 \
        --buffered=0 \
        --group_reporting=1 \
        --output="${OUTPUT_DIR}/fio_${LABEL}.json" \
        --output-format=json

    dfuse_unmount
    destroy_cont "${CONT}"
else
    echo "SKIP: libioil not found at ${LIBIOIL}"
    echo
fi

# ---------------------------------------------------------------------------
# 5. Engine 3 — DAOS native DFS engine
# ---------------------------------------------------------------------------
echo "========================================================"
echo "  Engine 3: DAOS native DFS engine"
echo "========================================================"
LABEL="dfs_bs${BS}_nj${NUMJOBS}_iod${IODEPTH}_${TIMESTAMP}"
CONT="${CONT_BASE}_eng3_${TIMESTAMP}"
create_cont "${CONT}"

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
    --direct=1 \
    --buffered=0 \
    --group_reporting=1 \
    --output="${OUTPUT_DIR}/fio_${LABEL}.json" \
    --output-format=json

destroy_cont "${CONT}"

echo "========================================================"
echo "Done. Results written to ${OUTPUT_DIR}/"
echo "========================================================"

rm -f ./*.0.0
