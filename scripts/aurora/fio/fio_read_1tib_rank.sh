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
FILENAMES="large.${FIRST}"
for (( i = 1; i < FILES_PER_RANK; i++ )); do
    FILENAMES+=":large.$(( FIRST + i ))"
done

EXTRA_OPTS=()
if [[ "${PATTERN}" == "read" ]]; then
    # Finish one file before moving to the next, so each stream stays
    # truly sequential (default roundrobin interleaves across files).
    EXTRA_OPTS+=(--file_service_type=sequential)
fi

# No end_fsync / create_on_open: read-only pass over existing data.
# allow_file_create=0 makes a missing large.N fail loudly instead of
# silently creating an empty file.
exec "${FIO}" \
    --name="${PATTERN}-1tib" \
    --ioengine=dfs \
    --pool="${POOL}" \
    --cont="${CONT}" \
    --chunk_size="${CHUNK_SIZE}" \
    --rw="${PATTERN}" \
    --bs="${BS}" \
    --iodepth="${IODEPTH}" \
    --filename="${FILENAMES}" \
    --filesize="${FILESIZE}" \
    --allow_file_create=0 \
    --randrepeat=0 \
    --group_reporting=1 \
    --output-format=json \
    --output="${OUTPUT_DIR}/${LABEL}_rank$(printf '%03d' "${RANK}").json" \
    "${EXTRA_OPTS[@]}"
