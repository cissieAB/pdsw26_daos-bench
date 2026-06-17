#!/bin/bash
# Usage: cd scripts/aurora/fio && qsub qsub_fio_3engines_rand_write.sh
#        DAOS_POOL_NAME=<pool> FIO_BS=4k qsub qsub_fio_3engines_rand_write.sh
# 
# Auora queue guide: https://docs.alcf.anl.gov/aurora/running-jobs-aurora/#queues
#        Note that the "prod" queue requires at least 256 nodes. 
#        Queue "debug" and "debug-scaling" have a max walltime of 1 hr. 
#        Prefer use the interactive job instead for single-node jobs.
# 
#PBS -N fio_3engines_rand_write
#PBS -l select=1
#PBS -l walltime=01:00:00
#PBS -l filesystems=home:flare:daos_user_fs
#PBS -q debug
#PBS -A e2sar-daos
#PBS -j oe
#PBS -o $HOME/logs/

# ---------------------------------------------------------------------------
# fio 3-engine rand_write comparison on Aurora
#   1. libaio via dfuse (no interception lib)
#   2. libaio via dfuse + LD_PRELOAD=/usr/lib64/libpil4dfs.so
#   3. DAOS native DFS engine
# numjobs=16, iodepth=16, bs=4k, runtime=60 s
# ---------------------------------------------------------------------------

set -euox pipefail

# Compute node default path is $HOME
WKDIR=$HOME/iobench/pdsw26_daos-bench/scripts/aurora/fio   # <=== Change dir as needed
cd "${WKDIR}"

mkdir -p "${HOME}/logs"

# Load DAOS module
echo "Loading DAOS module"
module use /soft/modulefiles/ || { echo "ERROR: Failed to use modulefiles" >&2; exit 1; }
module load daos || { echo "ERROR: Failed to load DAOS module" >&2; exit 1; }


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
bash run_fio_libil_rand_write.sh    # <== update the script

echo
echo "End: $(date)"
