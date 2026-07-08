#!/usr/bin/bash

# Per-rank fio launcher — invoked by mpiexec from qsub_fio_read_1filePerRank.qsub.
# fio is not MPI-aware, so each rank is an independent fio process running
# a single job that reads exactly one file: rank R reads large.R.
# The job reads its whole file exactly once (SIZE, default 100% of the
# file's actual size), then stops (no time_based cutoff).
#
# MPI launch: one rank per file, so -np = number of files in the dataset
# (e.g. 64 for the 1 TiB dataset of 16 GiB files, 640 for the 10 TiB one):
#
#   export FIO=... POOL=... CONT=... PATTERN=read OUTPUT_DIR=... LABEL=...
#   mpiexec -np 64 -ppn 32 -genvall /path/to/mpi-fio_read_1file-per-rank.sh
#
# (-np = total ranks = number of files; -ppn = ranks per node, so
#  -np 64 -ppn 32 uses 2 nodes; -genvall forwards the env below to
#  every rank. The rank id comes from PALS_RANKID/PMI_RANK, which
#  mpiexec sets automatically.)
#
# Required env (exported by the qsub script, forwarded by mpiexec -genvall):
#   FIO, POOL, CONT, PATTERN (read|randread), OUTPUT_DIR, LABEL
# Optional env:
#   BS (2m), CHUNK_SIZE (2m), IODEPTH (16), SIZE (100%)

set -euo pipefail

RANK="${PALS_RANKID:-${PMI_RANK:?neither PALS_RANKID nor PMI_RANK is set}}"

: "${FIO:?}" "${POOL:?}" "${CONT:?}" "${PATTERN:?}" \
  "${OUTPUT_DIR:?}" "${LABEL:?}"

BS="${BS:-2m}"
CHUNK_SIZE="${CHUNK_SIZE:-2m}"
IODEPTH="${IODEPTH:-16}"
SIZE="${SIZE:-100%}"

FILE="large.${RANK}"  # NOTE: a string

# No end_fsync / create_on_open: read-only pass over existing data.
# allow_file_create=0 makes a missing large.N fail loudly instead of
# silently creating an empty file. --size (not --filesize) bounds the
# amount the job reads: SIZE=100% reads the whole file once, then the
# job exits (randread covers every block once too, in random order).
# WARNING: an absolute SIZE larger than the actual file makes fio try to
# re-lay-out the file — it UNLINKS it first, then allow_file_create=0
# blocks the recreate, so the job reads 0 bytes AND the data file is
# gone. Keep SIZE at 100% (or <= the real file size).
exec "${FIO}" \
    --ioengine=dfs \
    --pool="${POOL}" \
    --cont="${CONT}" \
    --chunk_size="${CHUNK_SIZE}" \
    --rw="${PATTERN}" \
    --bs="${BS}" \
    --iodepth="${IODEPTH}" \
    --size="${SIZE}" \
    --time_based=0 \
    --allow_file_create=0 \
    --randrepeat=0 \
    --group_reporting=1 \
    --output-format=json \
    --output="${OUTPUT_DIR}/${LABEL}_rank$(printf '%03d' "${RANK}").json" \
    --name="${FILE}" \
    --filename="${FILE}"
