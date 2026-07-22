#!/usr/bin/bash

# Interactive IOR read-after-write launcher, O_DIRECT mode (--posix.odirect) -- bypasses
# the Linux page cache.
# Run this directly inside an interactive PBS session you already hold, e.g.:
#   qsub -I -l select=<N>:ncpus=208 -l walltime=00:59:00 -A e2sar-daos -q debug \
#        -l filesystems=home:flare:daos_user_fs
#   $ ./run_ior_rw_3modes.sh
# Unlike qsub_ior_rw.qsub / qsub_ior_rw_single-config.qsub (submitted with #PBS headers via
# `qsub <script>.qsub`), this script has no #PBS directives -- it assumes you already have
# the allocation and a shell on the MPI launch node.
#
# Sweeps 3 DAOS access modes against the same chunk_size=2MiB container, PPN=48, -w -r
# (write, then read back, same invocation) -- everything else matches qsub_ior_rw.qsub:
#   POSIX     -- dfuse mount, no interception library (plain POSIX syscalls)
#   POSIX_IL  -- dfuse mount + libpil4dfs.so interception library (LD_PRELOAD)
#   DFS       -- native DFS API (ior -a DFS), no dfuse mount and no interception library needed
#
# DISABLE_PAGE_CACHE=1 (default) passes O_DIRECT (--posix.odirect; the old global -B was
# removed from IOR) on the POSIX and POSIX_IL runs so they bypass the Linux page cache --
# the same flag as in qsub_ior_rw_single-config.qsub. Set DISABLE_PAGE_CACHE=0 to run
# buffered (page-cached) I/O instead; output filenames are labeled nocache/cache
# accordingly. DFS has no such flag and needs none: the native DFS API never goes through
# the kernel page cache, so its results are always labeled nocache.
# CAVEAT: O_DIRECT semantics on dfuse (POSIX / POSIX_IL) depend on how the mount was
# launched -- confirm launch-dfuse.sh actually passes O_DIRECT through rather than
# silently falling back to buffered I/O before trusting the "nocache" label on those runs.
#
# Usage: ./run_ior_rw_3modes.sh
# Env overrides:
#   DAOS_POOL_NAME      (default: e2sar)
#   NITER               (default: 10)
#   DFUSE_MNT_ROOT      (default: /tmp; dfuse mounts land at $DFUSE_MNT_ROOT/$POOL_NAME/$CONTAINER)
#   DISABLE_PAGE_CACHE  (default: 1; 1 = O_DIRECT on POSIX/POSIX_IL, 0 = buffered page-cached I/O)
#   CHUNK_SIZE          (default: 2MiB; DFS chunk size set on every container at create time.
#                        NOTE: the IOR --dfs.chunk_size flag for the DFS run is still hardcoded
#                        to 2m -- keep them in sync if you override this.)
#
# NOTE: --chunk-size on `daos container create` is assumed to be the correct flag for
# setting the DFS chunk size on a POSIX-type container ahead of dfuse mount (there is no
# per-run IOR chunk_size knob for -a POSIX the way there is --dfs.chunk_size for -a DFS).
# Double check this against your daos CLI version before relying on the POSIX/POSIX_IL results.

set -euo pipefail

# Compute node default path is $HOME
WKDIR=$HOME/iobench/pdsw26_daos-bench/scripts/aurora/ior   # <=== Change dir as needed
cd "${WKDIR}"

# Load DAOS module
module use /soft/modulefiles/ || { echo "Failed to use modulefiles"; exit 1; }
module load daos || { echo "Failed to load DAOS module"; exit 1; }

# ---------------------------------------------------------------------------
# 0. Config
# ---------------------------------------------------------------------------
POOL_NAME="${DAOS_POOL_NAME:-e2sar}"
NITER="${NITER:-2}"
DISABLE_PAGE_CACHE="${DISABLE_PAGE_CACHE:-1}"   # 1 = O_DIRECT on POSIX/POSIX_IL, 0 = buffered
CHUNK_SIZE="${CHUNK_SIZE:-2MiB}"
PPN=48
NSEGMENTS=32
IOR_TX_SIZES=("2M")

LIBPIL4DFS="/usr/lib64/libpil4dfs.so"

NNODES=$(wc -l < "$PBS_NODEFILE")
HOSTNAMES=$(tr '\n' ',' < "$PBS_NODEFILE")
NRANKS=$(( NNODES * PPN ))
echo "Nodes (${NNODES}): ${HOSTNAMES}"
echo "PPN: ${PPN}, NRANKS: ${NRANKS}, NITER: ${NITER}, chunk_size: ${CHUNK_SIZE}, disable_page_cache: ${DISABLE_PAGE_CACHE}"

# skip-1 breadth scan. Bind 48 cores
CPU_BINDING_SKIP1="list:4:6:56:58:9:11:61:63:12:14:64:66:17:19:69:71:20:22:72:74:25:27:77:79:28:30:80:82:33:35:85:87:36:38:88:90:41:43:93:95:44:46:96:98:49:51:100:102"
export ZE_FLAT_DEVICE_HIERARCHY=COMPOSITE
export AFFINITY_ORDERING=compact

# Add ior into path
export PATH=$PATH:$HOME/ior/install/bin

DFUSE_MNT_ROOT="${DFUSE_MNT_ROOT:-/tmp}"
RESULTS_DIR="../../../results/aurora/ior/ior-rw-3modes"
mkdir -p "${RESULTS_DIR}"

# Verify pool exists
daos pool list | grep -q -- "$POOL_NAME" || { echo "No pool: $POOL_NAME"; exit 1; }

START_TIME=$SECONDS

# ---------------------------------------------------------------------------
# 1. Cleanup -- track the in-flight container/mount so Ctrl-C mid-run
#    doesn't leak either.
# ---------------------------------------------------------------------------
CURRENT_CONT=""
CURRENT_MNT=""

cleanup() {
    if [[ -n "${CURRENT_MNT}" ]]; then
        fusermount3 -u "${CURRENT_MNT}" &>/dev/null || true
        CURRENT_MNT=""
    fi
    if [[ -n "${CURRENT_CONT}" ]]; then
        daos container destroy "${POOL_NAME}" "${CURRENT_CONT}" &>/dev/null || true
        CURRENT_CONT=""
    fi
}
trap cleanup EXIT

create_container() {
    local cont="$1" extra_props="$2"
    if daos cont query "$POOL_NAME" "$cont" >/dev/null 2>&1; then
        echo "Container $cont already exists, destroying it..."
        daos container destroy "$POOL_NAME" "$cont" || { echo "Failed to destroy container $cont"; exit 1; }
    fi
    daos container create --type=POSIX "$POOL_NAME" "$cont" --properties=rd_fac:0 ${extra_props} \
        || { echo "Failed to create container $cont"; exit 1; }
    CURRENT_CONT="$cont"
    echo "Container $cont created."
    daos container get-prop "$POOL_NAME" "$cont"
    daos container query "$POOL_NAME" "$cont"
}

# Create the container fresh (all modes: chunk-size property; POSIX/POSIX_IL additionally
# get a dfuse mount) right before a single IOR invocation. For DFS the property is
# redundant -- IOR's --dfs.chunk_size overrides it per-file -- but setting it keeps the
# container query output consistent across modes.
setup_access() {
    local mode="$1" cont="$2" mnt="$3"
    create_container "${cont}" "--chunk-size=${CHUNK_SIZE}"
    if [[ "${mode}" != "DFS" ]]; then
        mkdir -p "${mnt}"
        launch-dfuse.sh "${POOL_NAME}:${cont}"
        sleep 3
        mount | grep dfuse
        CURRENT_MNT="${mnt}"
    fi
}

# Unmount (if applicable) and destroy the container right after that IOR invocation.
teardown_access() {
    local mode="$1" cont="$2" mnt="$3"
    if [[ "${mode}" != "DFS" ]]; then
        fusermount3 -u "${mnt}" &>/dev/null || echo "WARNING: failed to unmount ${mnt}"
        CURRENT_MNT=""
    fi
    daos container destroy "${POOL_NAME}" "${cont}" || echo "Failed to destroy container ${cont}"
    CURRENT_CONT=""
}

# ---------------------------------------------------------------------------
# 2. Run one full (smoke test + TX_SIZES sweep) IOR pass for one access mode
#    mode:    label used in output filenames
#    ior_api: IOR -a value (POSIX or DFS)
#    preload: LD_PRELOAD value, empty string for none
#    cont:    DAOS container name to create/destroy around each run
#    dfuse mount point (POSIX / POSIX_IL only) is derived as
#    $DFUSE_MNT_ROOT/$POOL_NAME/$cont, matching the fio dfuse scripts' convention.
# ---------------------------------------------------------------------------
run_mode() {
    local mode="$1" ior_api="$2" preload="$3" cont="$4"

    echo "########################################################"
    echo "# Mode: ${mode}"
    echo "########################################################"

    local mnt="${DFUSE_MNT_ROOT}/${POOL_NAME}/${cont}"
    local target dfs_opts="" direct_flag="" cache_label="nocache"

    if [[ "${mode}" == "DFS" ]]; then
        # DFS API never touches the kernel page cache; no O_DIRECT knob exists.
        target="/ior"
        dfs_opts="--dfs.pool $POOL_NAME --dfs.cont $cont --dfs.chunk_size=2m"
        if [[ "${DISABLE_PAGE_CACHE}" == "0" ]]; then
            cache_label="cache"
        fi
    else
        target="${mnt}/ior"
        if [[ "${DISABLE_PAGE_CACHE}" == "1" ]]; then
            # Newer IOR dropped the global -B flag; O_DIRECT is per-module now.
            direct_flag="--posix.odirect"
        else
            cache_label="cache"
        fi
    fi

    echo "Running IOR smoke test (${mode})"
    setup_access "${mode}" "${cont}" "${mnt}"
    env ${preload:+LD_PRELOAD=${preload}} mpiexec -np ${NRANKS} -ppn ${PPN} --cpu-bind ${CPU_BINDING_SKIP1} \
                                                --no-vni -genvall -- \
                                                ior -a "${ior_api}" -w -r ${direct_flag} \
                                                ${dfs_opts} \
                                                -o "${target}-smoke" \
                                                -b 64M -t 16M
    teardown_access "${mode}" "${cont}" "${mnt}"

    for tx_size in "${IOR_TX_SIZES[@]}"; do
        echo -e "\nRunning IOR read-write (${mode}) tx_size=${tx_size} ppn=${PPN} total_ranks=${NRANKS}"
        setup_access "${mode}" "${cont}" "${mnt}"
        env ${preload:+LD_PRELOAD=${preload}} mpiexec -np ${NRANKS} -ppn ${PPN} --cpu-bind ${CPU_BINDING_SKIP1} \
                                                    --no-vni -genvall -- \
                                                    ior -a "${ior_api}" -w -r ${direct_flag} \
                                                    ${dfs_opts} \
                                                    -o "${target}-rw-tx_${tx_size}" \
                                                    -s ${NSEGMENTS} -b 128M -t ${tx_size} -i ${NITER} \
                                                    -O summaryFile=${RESULTS_DIR}/ior_rw_${mode}_${cache_label}_n-${NNODES}_ppn-${PPN}_tx-${tx_size}_$(date +%s).csv -O summaryFormat=CSV
        teardown_access "${mode}" "${cont}" "${mnt}"
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# 3. Sweep: POSIX, POSIX+IL, DFS
# ---------------------------------------------------------------------------
run_mode "POSIX"    "POSIX" ""              "${USER}-ior_n${NNODES}_POSIX"
# run_mode "POSIX_IL" "POSIX" "${LIBPIL4DFS}" "${USER}-ior_n${NNODES}_POSIX_IL"
# run_mode "DFS"      "DFS"   ""              "${USER}-ior_n${NNODES}_DFS"

ELAPSED_TIME=$((SECONDS - START_TIME))
echo "Completed script in $ELAPSED_TIME seconds"
