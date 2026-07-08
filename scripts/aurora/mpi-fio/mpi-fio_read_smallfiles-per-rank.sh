#!/usr/bin/bash

# Per-rank fio launcher — invoked by mpiexec from qsub_fio_read_smallFilesPerRank.qsub.
# fio is not MPI-aware, so each rank is an independent fio process running a
# single job that reads the small-file set of one original write job:
# rank R reads small.R.0 .. small.R.(NRFILES-1) (written with
# filename_format=small.$jobnum.$filenum, numjobs=NJOBS, nrfiles=NRFILES).
# The job reads SIZE bytes spread evenly over NRFILES files
# (SIZE/NRFILES per file, e.g. 16g/4096 = 4 MiB), then stops.
#
# MPI launch: one rank per write job, so -np = numjobs of the write pass
# (e.g. 64 for the 1 TiB dataset of 4 MiB files):
#
#   export FIO=... POOL=... CONT=... PATTERN=read OUTPUT_DIR=... LABEL=...
#   mpiexec -np 64 -ppn 32 -genvall /path/to/mpi-fio_read_smallfiles-per-rank.sh
#
# (-np = total ranks = write-side numjobs; -ppn = ranks per node, so
#  -np 64 -ppn 32 uses 2 nodes; -genvall forwards the env below to
#  every rank. The rank id comes from PALS_RANKID/PMI_RANK, which
#  mpiexec sets automatically.)
#
# Required env (exported by the qsub script, forwarded by mpiexec -genvall):
#   POOL, CONT, PATTERN (read|randread), OUTPUT_DIR, LABEL
# Optional env:
#   FIO ($HOME/local/bin/fio), BS (2m), CHUNK_SIZE (2m),
#   IODEPTH (1, must be <= filesize/bs = 2),
#   SIZE (16g), NRFILES (4096), FILE_SERVICE_TYPE (sequential)

set -euo pipefail

RANK="${PALS_RANKID:-${PMI_RANK:?neither PALS_RANKID nor PMI_RANK is set}}"

: "${POOL:?}" "${CONT:?}" "${PATTERN:?}" \
  "${OUTPUT_DIR:?}" "${LABEL:?}"

FIO="${FIO:-${HOME}/local/bin/fio}"
BS="${BS:-2m}"
CHUNK_SIZE="${CHUNK_SIZE:-2m}"
IODEPTH="${IODEPTH:-1}"                    # <= filesize (4 MiB) / bs (2 MiB) = 2
SIZE="${SIZE:-16g}"
NRFILES="${NRFILES:-4096}"
FILE_SERVICE_TYPE="${FILE_SERVICE_TYPE:-sequential}"

# fio expands $filenum in filename_format; the rank number is a literal.
# Rank R covers exactly the files the write pass's job R created.
FORMAT="small.${RANK}.\$filenum"

# No end_fsync / create_on_open: read-only pass over existing data.
# allow_file_create=0 makes a missing small.R.N fail loudly instead of
# silently creating an empty file. --size + --nrfiles bounds the job the
# same way the write side did: SIZE/NRFILES bytes per file, then exit.
exec "${FIO}" \
    --ioengine=dfs \
    --pool="${POOL}" \
    --cont="${CONT}" \
    --chunk_size="${CHUNK_SIZE}" \
    --rw="${PATTERN}" \
    --bs="${BS}" \
    --iodepth="${IODEPTH}" \
    --size="${SIZE}" \
    --nrfiles="${NRFILES}" \
    --file_service_type="${FILE_SERVICE_TYPE}" \
    --time_based=0 \
    --allow_file_create=0 \
    --randrepeat=0 \
    --group_reporting=1 \
    --output-format=json \
    --output="${OUTPUT_DIR}/${LABEL}_rank$(printf '%03d' "${RANK}").json" \
    --name="smallfiles.${RANK}" \
    --filename_format="${FORMAT}"
