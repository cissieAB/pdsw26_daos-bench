#!/usr/bin/bash

# Interactive smoke test for the 16 MiB-per-file sequential pattern:
# create a POSIX container, fio seq write (fio_dfs_seq_write_16m.fio),
# fio seq read-back (fio_dfs_seq_read_16m.fio), destroy the container.
#
# Grab an interactive node first, e.g.:
#   qsub -I -q debug -A e2sar-daos -l select=1:ncpus=208 \
#        -l walltime=00:30:00 -l filesystems=home:flare:daos_user_fs
#
# Usage: ./run_fio_dfs_seq_16m_test.sh [extra fio overrides...]
#   Overrides are appended to BOTH fio invocations so the read phase
#   always matches the write layout, e.g.:
#     ./run_fio_dfs_seq_16m_test.sh --nrfiles=256 --numjobs=32
#
# Env overrides:
#   DAOS_POOL_NAME   (default: e2sar)
#   DAOS_CONT_NAME   (default: fio_dfs_seq16m)
#   SKIP_READ=1      write phase only

set -euo pipefail

# Compute node default path is $HOME
WKDIR=$HOME/iobench/pdsw26_daos-bench/scripts/aurora/fio   # <=== Change dir as needed
cd "${WKDIR}"

# Load DAOS module
module use /soft/modulefiles/ || { echo "ERROR: Failed to use modulefiles" >&2; exit 1; }
module load daos || { echo "ERROR: Failed to load DAOS module" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Config
# ---------------------------------------------------------------------------
FIO="${HOME}/local/bin/fio"

POOL="${DAOS_POOL_NAME:-e2sar}"
CONT="${DAOS_CONT_NAME:-fio_dfs_seq16m}"
SKIP_READ="${SKIP_READ:-0}"
FIO_OVERRIDES=("$@")

OUTPUT_DIR=../../../results/aurora/fio/seq_16m_test
mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR=$(cd "${OUTPUT_DIR}" && pwd)

TIMESTAMP=$(date +%s)

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

daos pool list | grep -q -- "${POOL}" || { echo "ERROR: no pool: ${POOL}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 2. Container lifecycle
# ---------------------------------------------------------------------------
CURRENT_CONT=""

cleanup() {
    if [[ -n "${CURRENT_CONT}" ]]; then
        daos container destroy "${POOL}" "${CURRENT_CONT}" &>/dev/null || true
        CURRENT_CONT=""
    fi
}
trap cleanup EXIT

daos container destroy "${POOL}" "${CONT}" &>/dev/null || true

daos container create --type=POSIX "${POOL}" "${CONT}" || {
    echo "ERROR: failed to create container ${CONT}" >&2
    exit 1
}
CURRENT_CONT="${CONT}"
echo "Container ${CONT} created."
daos container get-prop "${POOL}" "${CONT}"

# Consumed by ${DAOS_POOL}/${DAOS_CONT} in the .fio job files
export DAOS_POOL="${POOL}"
export DAOS_CONT="${CONT}"

# ---------------------------------------------------------------------------
# 3. Write phase, then read-back
# ---------------------------------------------------------------------------
PHASES=(write)
(( SKIP_READ )) || PHASES+=(read)

for PHASE in "${PHASES[@]}"; do
    JOBFILE="fio_dfs_seq_${PHASE}_16m.fio"
    OUT="${OUTPUT_DIR}/fio_seq_${PHASE}_16m_${TIMESTAMP}.json"

    echo "========================================================"
    echo "  seq ${PHASE} 16m  (${JOBFILE})"
    [[ ${#FIO_OVERRIDES[@]} -gt 0 ]] && echo "  overrides: ${FIO_OVERRIDES[*]}"
    echo "========================================================"

    "${FIO}" "${JOBFILE}" \
        ${FIO_OVERRIDES[@]+"${FIO_OVERRIDES[@]}"} \
        --output-format=json \
        --output="${OUT}"

    echo "Done: ${OUT}"

    # Quick bandwidth summary from the JSON
    python3 - "${OUT}" <<'EOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for job in data["jobs"]:
    for op in ("write", "read"):
        s = job[op]
        if s["io_bytes"]:
            gib = s["io_bytes"] / 2**30
            print(f'  {job["jobname"]}: {op} {gib:.2f} GiB, '
                  f'{s["bw_bytes"]/2**30:.2f} GiB/s, iops {s["iops"]:.0f}')
EOF
done

# ---------------------------------------------------------------------------
# 4. Cleanup
# ---------------------------------------------------------------------------
daos container destroy "${POOL}" "${CONT}" \
    || echo "WARNING: failed to destroy container ${CONT}" >&2
CURRENT_CONT=""

echo "========================================================"
echo "Test complete. Results in ${OUTPUT_DIR}"
echo "========================================================"
