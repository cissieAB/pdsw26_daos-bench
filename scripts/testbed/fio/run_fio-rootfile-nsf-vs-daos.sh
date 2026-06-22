#!/usr/bin/bash
# Sequential-read benchmark of a single ROOT file on DAOS DFS then on Network File System (NSF) over 100 GbE.
# bs iterates over: 4k 4m 1m; numjobs=1, iodepth=32, reads full 29 GiB file once
#
# Usage: bash run_fio-rootfile-nsf-vs-daos.sh [--skip-daos]

set -euox pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SKIP_DAOS=false
for _arg in "$@"; do
    case "${_arg}" in
        --skip-daos) SKIP_DAOS=true ;;
        *) echo "Unknown argument: ${_arg}" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# 0. Config
# ---------------------------------------------------------------------------
FIO_NSF="/usr/bin/fio"         # system fio for NSF (no DFS engine needed)
FIO_DFS="/home/xmei/local/bin/fio"    # custom build with DAOS DFS engine

SRC_FILE="/nvme/haidis/gluex/eta3pi_trees/data2020/ds_tree/PiPiGG_Tree_073266.root"

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

BS_LIST=(4k 4m 1m)
FIO_ENGINES=(pvsync2 libaio psync)

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
if [[ ! -x "${FIO_NSF}" ]]; then
    echo "ERROR: fio not found at ${FIO_NSF}" >&2; exit 1
fi
if [[ ! -f "${SRC_FILE}" ]]; then
    echo "ERROR: source file not found: ${SRC_FILE}" >&2; exit 1
fi
if [[ "${SKIP_DAOS}" == false ]]; then
    if [[ ! -x "${FIO_DFS}" ]]; then
        echo "ERROR: fio not found at ${FIO_DFS}" >&2; exit 1
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
fi

# ---------------------------------------------------------------------------
# 1. DAOS DFS: read pre-copied file via dfs ioengine
#    Source: daos://iobench/root-cp/test.root
# ---------------------------------------------------------------------------
if [[ "${SKIP_DAOS}" == true ]]; then
    echo "=== [1/2] DAOS DFS seq_read — SKIPPED ==="
else
    echo "=== [1/2] DAOS DFS seq_read (pool=${POOL}, cont=${CONT}, file=${DAOS_FILE}) ==="
    for BS in "${BS_LIST[@]}"; do
        for RUN in $(seq 1 10); do
            OUT_DAOS="${OUTPUT_DIR}/dfs_seq_read_bs${BS}_nj1_iod32_dfs_$(date +%s).json"
            echo "--- DAOS DFS bs=${BS} run=${RUN}/10 ---"
            "${FIO_DFS}" \
                "${FIO_COMMON[@]}" \
                --bs="${BS}" \
                --ioengine=dfs \
                --pool="${POOL}" \
                --cont="${CONT}" \
                --size=28g \
                --filename="${DAOS_FILE}" \
                --output="${OUT_DAOS}"
            echo "DAOS result: ${OUT_DAOS}"
            sleep 5
        done
    done
fi
echo

# ---------------------------------------------------------------------------
# 2. NSF: read the file directly — iterate over engines, 10 runs each
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# User selection: block sizes and engines for NSF runs

pick_from_list() {
    local prompt="$1"; shift
    local -a options=("$@")
    echo "${prompt}"
    for i in "${!options[@]}"; do
        printf "  %d) %s\n" "$((i+1))" "${options[$i]}"
    done
    read -rp "  Enter numbers (space-separated) or 'a' for all: " _choices
    PICKED=()
    if [[ "${_choices}" == "a" ]]; then
        PICKED=("${options[@]}")
    else
        for _c in ${_choices}; do
            PICKED+=("${options[$((${_c}-1))]}")
        done
    fi
}

pick_from_list "Select block sizes to run:" "${BS_LIST[@]}"
RUN_BS=("${PICKED[@]}")

pick_from_list "Select NSF engines to run:" "${FIO_ENGINES[@]}"
RUN_ENGINES=("${PICKED[@]}")

echo "Will run: bs=[${RUN_BS[*]}]  engines=[${RUN_ENGINES[*]}]"
read -rp "Press Enter to start NSF runs..."


echo "=== [2/2] NSF seq_read ==="

for BS in "${RUN_BS[@]}"; do
    for ENGINE in "${RUN_ENGINES[@]}"; do
        for RUN in $(seq 1 10); do
            OUT_NSF="${OUTPUT_DIR}/${ENGINE}_nsf_seq_read_bs${BS}_nj1_iod32_$(date +%s).json"
            echo "--- NSF bs=${BS} engine=${ENGINE} run=${RUN}/10 ---"
            "${FIO_NSF}" \
                "${FIO_COMMON[@]}" \
                --bs="${BS}" \
                --ioengine="${ENGINE}" \
                --filename="${SRC_FILE}" \
                --output="${OUT_NSF}"
            echo "NSF result: ${OUT_NSF}"

            sleep 5
        done
        sleep 30
    done
done
echo



echo "=== Done. Results in ${OUTPUT_DIR}/ ==="
