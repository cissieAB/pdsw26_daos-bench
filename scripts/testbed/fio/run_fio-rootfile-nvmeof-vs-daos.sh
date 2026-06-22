#!/usr/bin/bash
# Sequential-read benchmark of a single ROOT file on NVMe-oF then on DAOS DFS.
# Fixed: bs=1m, numjobs=1, iodepth=32, reads full 29 GiB file once
#
# Usage: bash run_fio-rootfile-nvmeof-vs-daos.sh

set -euox pipefail

# ---------------------------------------------------------------------------
# 0. Config
# ---------------------------------------------------------------------------
FIO_NVME="/usr/bin/fio"         # system fio for NVMe-oF (no DFS engine needed)
FIO_DFS="${HOME}/local/bin/fio"    # custom build with DAOS DFS engine

SRC_FILE="/nvme/haidis/gluex/eta3pi_trees/data2020/ds_tree/PiPiGG_Tree_073266.root"
FILE_SIZE="28g"

# Pre-copied DAOS location: daos://iobench/root-cp/test.root
# [xmei@ebpf2203 ~]$ daos fs scan iobench root-cp
# DFS scanner: Start (2026-06-12-23:12:25)
# DFS scanner: Done! (runtime: 0 sec)
# DFS scanner: 1 scanned objects
# DFS scanner: 1 files
# DFS scanner: 0 symlinks
# DFS scanner: 0 directories
# DFS scanner: 1 max tree depth
# DFS scanner: 30667149142 bytes of total data  28.56 GiB
# DFS scanner: 30667149142 bytes per file on average
# DFS scanner: 30667149142 bytes is largest file size
# DFS scanner: 1 entries in the largest directory

POOL="iobench"
CONT="root-cp"
DAOS_FILE="test.root"

OUTPUT_DIR="../../../results/testbed/fio-cmp"
mkdir -p "${OUTPUT_DIR}"

FIO_COMMON=(
    --name=seq_read
    --rw=read
    --numjobs=1
    --iodepth=32
    --group_reporting=1
    --randrepeat=0
    --output-format=json
)

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [[ ! -x "${FIO_NVME}" ]]; then
    echo "ERROR: fio not found at ${FIO_NVME}" >&2; exit 1
fi
if [[ ! -x "${FIO_DFS}" ]]; then
    echo "ERROR: fio not found at ${FIO_DFS}" >&2; exit 1
fi
if [[ ! -f "${SRC_FILE}" ]]; then
    echo "ERROR: source file not found: ${SRC_FILE}" >&2; exit 1
fi
if ! "${FIO_DFS}" --enghelp dfs &>/dev/null; then
    echo "ERROR: fio dfs engine not available" >&2; exit 1
fi
if ! daos pool query "${POOL}" &>/dev/null; then
    echo "ERROR: DAOS pool '${POOL}' not accessible" >&2; exit 1
fi
if ! daos container query "${POOL}" "${CONT}" &>/dev/null; then
    echo "ERROR: DAOS container '${CONT}' not accessible in pool '${POOL}'" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# 1. NVMe-oF: read the file directly — iterate over engines, 10 runs each
# ---------------------------------------------------------------------------
echo "=== [1/2] NVMe-oF seq_read ==="
NVME_ENGINES=(pvsync2 libaio psync)

for ENGINE in "${NVME_ENGINES[@]}"; do
    for RUN in $(seq 1 10); do
        OUT_NVME="${OUTPUT_DIR}/${ENGINE}_nvmeof_seq_read_bs4m_nj1_iod32_$(date +%s).json"
        echo "--- NVMe-oF engine=${ENGINE} run=${RUN}/10 ---"
        "${FIO_NVME}" \
            "${FIO_COMMON[@]}" \
            --ioengine="${ENGINE}" \
            --filename="${SRC_FILE}" \
            --output="${OUT_NVME}"
        echo "NVMe-oF result: ${OUT_NVME}"

        sleep 5
    done
done
echo

# ---------------------------------------------------------------------------
# 2. DAOS DFS: read pre-copied file via dfs ioengine
#    Source: daos://iobench/root-cp/test.root
# ---------------------------------------------------------------------------
echo "=== [2/2] DAOS DFS seq_read (pool=${POOL}, cont=${CONT}, file=${DAOS_FILE}) ==="

for RUN in $(seq 1 10); do
    OUT_DAOS="${OUTPUT_DIR}/daos_seq_read_bs4m_nj1_iod32_dfs_$(date +%s).json"
    echo "--- DAOS DFS run=${RUN}/10 ---"
    "${FIO_DFS}" \
        "${FIO_COMMON[@]}" \
        --ioengine=dfs \
        --pool="${POOL}" \
        --cont="${CONT}" \
        --size=28g \
        --filename="${DAOS_FILE}" \
        --output="${OUT_DAOS}"
    echo "DAOS result: ${OUT_DAOS}"
    sleep 5
done
echo

echo "=== Done. Results in ${OUTPUT_DIR}/ ==="
