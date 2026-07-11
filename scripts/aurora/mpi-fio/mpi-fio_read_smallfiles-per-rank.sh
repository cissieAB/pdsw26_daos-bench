#!/usr/bin/bash

# Per-rank fio launcher — invoked by mpiexec from qsub_fio_read_smallFilesPerRank.qsub.
# fio is not MPI-aware, so each rank is an independent fio process running a
# single job that reads a fixed-size slice of the whole small-file dataset.
# The dataset (written with filename_format=small.$jobnum.$filenum,
# numjobs=NJOBS_W, nrfiles=NRFILES_W) is treated as one flat namespace:
#   global index g = 0 .. NJOBS_W*NRFILES_W - 1  <->  small.(g/NRFILES_W).(g%NRFILES_W)
# Rank R reads the contiguous block g in [R*NRFILES, (R+1)*NRFILES), passed
# to fio as an explicit colon-separated --filename list (fio's
# filename_format cannot do this arithmetic itself). The rank count is
# therefore decoupled from the write-side numjobs; with NRFILES = NRFILES_W
# and -np = NJOBS_W this degenerates to the old strict mapping (rank R reads
# exactly write job R's files). The job reads SIZE bytes spread evenly over
# its NRFILES files (SIZE/NRFILES per file, e.g. 16g/4096 = 4 MiB), then stops.
#
# MPI launch: any -np with -np * NRFILES <= NJOBS_W * NRFILES_W, e.g. for the
# 1 TiB dataset of 4 MiB files (64 x 4096 files):
#
#   export FIO=... POOL=... CONT=... PATTERN=read OUTPUT_DIR=... LABEL=...
#   export NRFILES=2048 SIZE=8g   # 128 ranks x 2048 files covers the dataset
#   mpiexec -np 128 -ppn 32 -genvall /path/to/mpi-fio_read_smallfiles-per-rank.sh
#
# (-ppn = ranks per node; -genvall forwards the env below to every rank.
#  The rank id comes from PALS_RANKID/PMI_RANK, which mpiexec sets
#  automatically.)
#
# Required env (exported by the qsub script, forwarded by mpiexec -genvall):
#   POOL, CONT, PATTERN (read|randread), OUTPUT_DIR, LABEL
# Optional env:
#   FIO ($HOME/local/bin/fio), BS (2m), CHUNK_SIZE (2m),
#   IODEPTH (1, must be <= per-file size / bs),
#   SIZE (16g), NRFILES (4096, files this rank reads),
#   NRFILES_W (4096, write-side nrfiles defining the small.j.f layout),
#   FILE_SERVICE_TYPE (sequential),
#   PARSE_ONLY (0; 1 = fio only validates its options, no I/O — lets you
#   check the --filename list on a login node without a job:
#     PALS_RANKID=0 PARSE_ONLY=1 POOL=e2sar CONT=x PATTERN=read \
#       OUTPUT_DIR=/tmp LABEL=parsecheck ./mpi-fio_read_smallfiles-per-rank.sh )

set -euo pipefail

RANK="${PALS_RANKID:-${PMI_RANK:?neither PALS_RANKID nor PMI_RANK is set}}"
HOST="$(hostname -s)"   # recorded in the output filename: rank->node mapping

: "${POOL:?}" "${CONT:?}" "${PATTERN:?}" \
  "${OUTPUT_DIR:?}" "${LABEL:?}"

FIO="${FIO:-${HOME}/local/bin/fio}"
BS="${BS:-2m}"
CHUNK_SIZE="${CHUNK_SIZE:-2m}"
IODEPTH="${IODEPTH:-1}"                    # <= filesize (4 MiB) / bs (2 MiB) = 2
SIZE="${SIZE:-16g}"
NRFILES="${NRFILES:-4096}"
NRFILES_W="${NRFILES_W:-4096}"
FILE_SERVICE_TYPE="${FILE_SERVICE_TYPE:-sequential}"
PARSE_ONLY="${PARSE_ONLY:-0}"   # 1 = fio validates its options and exits, no I/O
                                # (login-node check; pool/cont are never opened)

# Rank R's contiguous slice of the flat namespace: global indices
# [R*NRFILES, (R+1)*NRFILES), each mapped back to small.(g/NRFILES_W).(g%NRFILES_W).
# Passed as one colon-separated --filename argument; a single exec arg is
# capped at 128 KiB on Linux, which this stays under up to NRFILES ~ 8000.
(( NRFILES <= 8000 )) \
    || { echo "ERROR: NRFILES=${NRFILES} too large for a --filename list (max ~8000)" >&2; exit 1; }
START=$(( RANK * NRFILES ))
NAMES=()
for (( g=START; g<START+NRFILES; g++ )); do
    NAMES+=( "small.$(( g / NRFILES_W )).$(( g % NRFILES_W ))" )
done
FILELIST=$(IFS=:; echo "${NAMES[*]}")

OUT="${OUTPUT_DIR}/${LABEL}_rank$(printf '%03d' "${RANK}")_${HOST}.json"

EXTRA=()
if [[ "${PARSE_ONLY}" == 1 ]]; then EXTRA+=( --parse-only ); fi

# No end_fsync / create_on_open: read-only pass over existing data.
# allow_file_create=0 makes a missing small.R.N fail loudly instead of
# silently creating an empty file. --size + --nrfiles bounds the job the
# same way the write side did: SIZE/NRFILES bytes per file, then exit.
"${FIO}" \
    "${EXTRA[@]}" \
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
    --output="${OUT}" \
    --name="smallfiles.${RANK}" \
    --filename="${FILELIST}"

# Stamp the rank's hostname into the JSON itself (not just the filename),
# so per-rank results are still traceable to a node after files get merged
# or renamed downstream. (Skipped in parse-only mode: fio wrote no output.)
if [[ "${PARSE_ONLY}" != 1 ]]; then
    jq --arg h "${HOST}" '. + {hostname: $h}' "${OUT}" > "${OUT}.tmp" && mv "${OUT}.tmp" "${OUT}"
fi
