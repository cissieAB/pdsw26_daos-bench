#!/bin/bash
#PBS -N fio_3engines_rand_write
#PBS -l select=1
#PBS -l walltime=02:00:00
#PBS -l filesystems=home:flare:daos_user
#PBS -q prod
#PBS -A e2sar-daos
#PBS -j oe
#PBS -o $HOME/logs/

# ---------------------------------------------------------------------------
# fio 3-engine rand_write comparison on Aurora
#   1. libaio via dfuse (no interception lib)
#   2. libaio via dfuse + LD_PRELOAD=libioil.so
#   3. DAOS native DFS engine
# numjobs=16, iodepth=16, bs=4k, runtime=60 s
# ---------------------------------------------------------------------------

set -euox pipefail

cd "${PBS_O_WORKDIR}"

mkdir -p /logs

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
export DAOS_POOL_NAME="${DAOS_POOL_NAME:-e2sar}"
export FIO_BS="${FIO_BS:-1m}"

echo "Job ID:       ${PBS_JOBID}"
echo "Nodes:        $(cat ${PBS_NODEFILE} | sort -u | tr '\n' ' ')"
echo "DAOS pool:    ${DAOS_POOL_NAME}"
echo "fio bs:       ${FIO_BS}"
echo "Start:        $(date)"
echo

# ---------------------------------------------------------------------------
# Verify DAOS client is reachable
# ---------------------------------------------------------------------------
daos pool query "${DAOS_POOL_NAME}"

# ---------------------------------------------------------------------------
# Run the benchmark
# ---------------------------------------------------------------------------
bash run_fio_3engines_rand_write.sh

echo
echo "End: $(date)"
