#!/usr/bin/bash

# Read back the 1 TiB dataset written by fio_write10TiB.fio (section
# write-large_fs-16g scaled to 64 x 16 GiB files, chunk_size=2m) with many
# fio processes launched via MPI. One fio process per rank; each rank reads
# a disjoint slice of the large.* files (see fio_read_1tib_rank.sh).
# Runs a sequential-read pass and a random-read pass, bs=2m.
#
# The container is NOT created or destroyed here — it must already hold
# the data (files large.0 .. large.<NFILES-1> at the container root).
#
# Grab an interactive node first, e.g.:
#   qsub -I -q debug -A e2sar-daos -l select=1:ncpus=208 \
#        -l walltime=00:59:00 -l filesystems=home:flare:daos_user_fs
#
# Usage: ./run_fio_read_1tib.sh [seq|rand|both]
#   seq   sequential read only
#   rand  random read only
#   both  sequential pass then random pass (default)
#
# Env overrides:
#   RANKS_PER_NODE   fio processes per node (default: 32)
#   DAOS_POOL_NAME   (default: e2sar)
#   DAOS_CONT_NAME   (default: fio-fs16g)
#   NFILES           number of large.* files (default: 64)
#   FILESIZE         size of each file (default: 16g)
#   BS / CHUNK_SIZE / IODEPTH  (default: 2m / 2m / 16)

set -euo pipefail

# Load DAOS module
module use /soft/modulefiles/ || { echo "ERROR: Failed to use modulefiles" >&2; exit 1; }
module load daos || { echo "ERROR: Failed to load DAOS module" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Config
# ---------------------------------------------------------------------------
# Compute node default path is $HOME
WKDIR=$HOME/iobench/pdsw26_daos-bench/scripts/aurora/fio   # <=== Change dir as needed
cd "${WKDIR}"

export FIO="${HOME}/local/bin/fio"    # <=== Change path to fio binary as needed
export POOL="${DAOS_POOL_NAME:-e2sar}"
export CONT="${DAOS_CONT_NAME:-fio-1tib-fs16g}"
export BS="${BS:-2m}"
export CHUNK_SIZE="${CHUNK_SIZE:-2m}"
export IODEPTH="${IODEPTH:-16}"
export FILESIZE="${FILESIZE:-16g}"

NFILES="${NFILES:-64}"
RANKS_PER_NODE="${RANKS_PER_NODE:-32}"

# seq|rand|both switch -> fio rw value(s)
MODE="${1:-both}"
case "${MODE}" in
    seq)  PATTERNS="read" ;;
    rand) PATTERNS="randread" ;;
    *)
        echo "ERROR: unknown mode '${MODE}' (expected seq, or rand)" >&2
        exit 1
        ;;
esac

# Inside an interactive PBS job $PBS_NODEFILE is set; fall back to 1 node.
if [[ -n "${PBS_NODEFILE:-}" ]]; then
    NNODES=$(wc -l < "$PBS_NODEFILE")
    echo "Nodes (${NNODES}): $(tr '\n' ',' < "$PBS_NODEFILE")"
else
    NNODES=1
    echo "PBS_NODEFILE not set — assuming single node: $(hostname)"
fi
NRANKS=$(( NNODES * RANKS_PER_NODE ))

if (( NFILES % NRANKS != 0 )); then
    echo "ERROR: NFILES=${NFILES} not divisible by NRANKS=${NRANKS}" \
         "(${NNODES} nodes x ${RANKS_PER_NODE} ppn)" >&2
    exit 1
fi
export FILES_PER_RANK=$(( NFILES / NRANKS ))

OUTPUT_DIR=../../../results/aurora/fio/read-pattern/read_1tib_n${NNODES}_ppn${RANKS_PER_NODE}_bs${BS}_iod${IODEPTH}
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR=$(cd "${OUTPUT_DIR}" && pwd)
export OUTPUT_DIR

# skip-1 breadth scan. Bind 48 cores
CPU_BINDING_SKIP1="list:4:6:56:58:9:11:61:63:12:14:64:66:17:19:69:71:20:22:72:74:25:27:77:79:28:30:80:82:33:35:85:87:36:38:88:90:41:43:93:95:44:46:96:98:49:51:100:102"
export ZE_FLAT_DEVICE_HIERARCHY=COMPOSITE
export AFFINITY_ORDERING=compact

CPU_BIND_OPTS=()
if (( RANKS_PER_NODE <= 48 )); then
    CPU_BIND_OPTS=(--cpu-bind "${CPU_BINDING_SKIP1}")
fi

START_TIME=$SECONDS

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

daos pool list | grep -q -- "${POOL}" || { echo "ERROR: no pool: ${POOL}" >&2; exit 1; }

# Container must already exist with the written data — never recreate it.
daos cont query "${POOL}" "${CONT}" || {
    echo "ERROR: container ${CONT} not found in pool ${POOL} —" \
         "run the 1 TiB write first." >&2
    exit 1
}

echo
echo "Pool:      ${POOL}"
echo "Container: ${CONT} (pre-existing, read-only)"
echo "Dataset:   ${NFILES} x ${FILESIZE} files (large.0 .. large.$(( NFILES - 1 )))"
echo "Ranks:     ${NRANKS} (${NNODES} nodes x ${RANKS_PER_NODE} ppn)," \
     "${FILES_PER_RANK} file(s)/rank"
echo "fio:       bs=${BS} chunk_size=${CHUNK_SIZE} iodepth=${IODEPTH}"
echo "Patterns:  ${PATTERNS}"
echo

# ---------------------------------------------------------------------------
# 2. Sequential-read pass, then random-read pass
# ---------------------------------------------------------------------------
for PATTERN in ${PATTERNS}; do
    export PATTERN
    TIMESTAMP=$(date +%s)
    export LABEL="fio_1tib_${PATTERN}_n${NNODES}_ppn${RANKS_PER_NODE}_${TIMESTAMP}"

    echo "========================================================"
    echo "  ${PATTERN}: ${NRANKS} fio processes via mpiexec"
    echo "========================================================"

    mpiexec -np "${NRANKS}" -ppn "${RANKS_PER_NODE}" "${CPU_BIND_OPTS[@]}" \
            --no-vni -genvall -- \
            bash "${WKDIR}/fio_read_1tib_rank.sh"

    echo "Done: ${OUTPUT_DIR}/${LABEL}_rank*.json"

    # Aggregate summary across the per-rank JSONs
    python3 - "${OUTPUT_DIR}" "${LABEL}" <<'EOF'
import glob, json, os, sys
outdir, label = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(outdir, f"{label}_rank*.json")))
total_bytes = 0
max_runtime_ms = 0
for path in files:
    with open(path) as f:
        data = json.load(f)
    for job in data["jobs"]:
        r = job["read"]
        total_bytes += r["io_bytes"]
        max_runtime_ms = max(max_runtime_ms, r["runtime"])
if max_runtime_ms:
    tib = total_bytes / 2**40
    gibps = total_bytes / 2**30 / (max_runtime_ms / 1000)
    print(f"  AGGREGATE ({len(files)} ranks): {tib:.2f} TiB read, "
          f"{gibps:.2f} GiB/s (sum bytes / max rank runtime)")
else:
    print("  WARNING: no rank output found for", label)
EOF

    sleep 10
done

ELAPSED_TIME=$((SECONDS - START_TIME))
echo "Completed script in $ELAPSED_TIME seconds"
