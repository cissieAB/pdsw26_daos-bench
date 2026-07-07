#!/usr/bin/bash

# Per-rank fio launcher — invoked by mpiexec from qsub_fio_read_1tib.qsub.
# fio is not MPI-aware, so each rank is an independent fio process that
# reads its own disjoint slice of the large.* files:
#   rank R reads large.(R*FILES_PER_RANK) .. large.(R*FILES_PER_RANK + FILES_PER_RANK - 1)
#
# Required env (exported by the qsub script, forwarded by mpiexec -genvall):
#   FIO, POOL, CONT, PATTERN (read|randread), FILES_PER_RANK, OUTPUT_DIR, LABEL
# Optional env:
#   BS (2m), CHUNK_SIZE (2m), IODEPTH (16), FILESIZE (16g)

set -euo pipefail

RANK="${PALS_RANKID:-${PMI_RANK:?neither PALS_RANKID nor PMI_RANK is set}}"

: "${FIO:?}" "${POOL:?}" "${CONT:?}" "${PATTERN:?}" \
  "${FILES_PER_RANK:?}" "${OUTPUT_DIR:?}" "${LABEL:?}"

BS="${BS:-2m}"
CHUNK_SIZE="${CHUNK_SIZE:-2m}"
IODEPTH="${IODEPTH:-16}"
FILESIZE="${FILESIZE:-16g}"

FIRST=$(( RANK * FILES_PER_RANK ))

# The fio dfs engine holds a single open DFS object per job (dd->obj in
# engines/dfs.c), so a job must never touch more than one file — with a
# colon-separated filename list, switching files releases the wrong handle
# and reads fail with DER_NO_HDL. Give each file its own job instead (same
# one-file-per-job layout the 1 TiB write used). On the fio command line,
# options before the first --name are global; each --name starts a new job,
# and all jobs run concurrently.
JOB_OPTS=()
for (( i = 0; i < FILES_PER_RANK; i++ )); do
    F="large.$(( FIRST + i ))"
    JOB_OPTS+=(--name="${F}" --filename="${F}")
done

# No end_fsync / create_on_open: read-only pass over existing data.
# allow_file_create=0 makes a missing large.N fail loudly instead of
# silently creating an empty file.
exec "${FIO}" \
    --ioengine=dfs \
    --pool="${POOL}" \
    --cont="${CONT}" \
    --chunk_size="${CHUNK_SIZE}" \
    --rw="${PATTERN}" \
    --bs="${BS}" \
    --iodepth="${IODEPTH}" \
    --filesize="${FILESIZE}" \
    --allow_file_create=0 \
    --randrepeat=0 \
    --group_reporting=1 \
    --output-format=json \
    --output="${OUTPUT_DIR}/${LABEL}_rank$(printf '%03d' "${RANK}").json" \
    "${JOB_OPTS[@]}"
