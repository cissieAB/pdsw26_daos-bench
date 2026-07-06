#!/usr/bin/bash

# Per-rank fio launcher for qsub_fio_dfs_seq-rand-read.qsub.
# Invoked on every rank by mpiexec; all parameters arrive via the
# environment (-genvall). fio is not MPI-aware, so each rank runs an
# independent fio process with FIO_NUMJOBS jobs, each job on its own
# set of files, named rank<RANK>-j<jobnum>-f<filenum>. The read phases
# therefore re-read exactly the files the same rank/job generated in
# the write phase.

set -euo pipefail

RANK="${PALS_RANKID:-${PMI_RANK:-0}}"

EXTRA_ARGS=()
if [[ "${FIO_RW}" == rand* ]]; then
    EXTRA_ARGS+=(--norandommap --randrepeat=0 --file_service_type=random)
fi
if [[ "${FIO_RW}" == *write* ]]; then
    EXTRA_ARGS+=(--refill_buffers)
fi
# all phases are size-bound: write generates every file in full, and the
# read phases read the rank's whole file set exactly once
if (( FIO_NRFILES > 1024 && ${FIO_OPENFILES:-512} > 0 )); then
    # cap concurrently open DFS objects for the small-file pattern
    EXTRA_ARGS+=(--openfiles="${FIO_OPENFILES:-512}")
fi

exec "${FIO_BIN}" \
    --name="${FIO_JOBNAME}" \
    --ioengine=dfs \
    --pool="${DAOS_POOL}" \
    --cont="${DAOS_CONT}" \
    --chunk_size="${FIO_CHUNK_SIZE}" \
    --rw="${FIO_RW}" \
    --bs="${FIO_BS}" \
    --iodepth="${FIO_IODEPTH}" \
    --numjobs="${FIO_NUMJOBS:-1}" \
    --nrfiles="${FIO_NRFILES}" \
    --filesize="${FIO_FILESIZE}" \
    --filename_format="rank${RANK}-j\$jobnum-f\$filenum" \
    --fallocate=none \
    --group_reporting=1 \
    --output-format=json \
    --output="${FIO_OUT_DIR}/fio_${FIO_LABEL}_rank${RANK}.json" \
    ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
