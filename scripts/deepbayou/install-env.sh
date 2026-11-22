#!/bin/bash
# Generic sbatch script for any Deep Bayou Spack environment under
# environments/deepbayou/<name>. One script for every tier instead of one
# copy per environment like scripts/qb4/*-install.sh (those were nearly
# identical except for the environment path and walltime).
#
# Usage - always from the repo root on a db login node, never on the
# login node itself without sbatch (real builds must run on a compute node):
#   sbatch -J db-smoke-test scripts/deepbayou/install-env.sh smoke-test
#   sbatch -J db-tier1-test -t 12:00:00 scripts/deepbayou/install-env.sh tier1-test
#
# -J sets the job name, which is also the results directory name on the
# cluster-results branch (results/<job name>/...). sbatch command-line
# options override the #SBATCH defaults below (e.g. -t, -c, -p).
#
# Defaults: Deep Bayou RHEL10 nodes are db009/db010 (2x 24-core Cascade
# Lake = 48 cores). These nodes are currently reserved for this deployment
# work (user, 2026-11-21), so take the whole node: partition gpu2 (QOS
# `normal`, 3-day limit, no per-job CPU cap) with all 48 cores. NOT
# `single`: its QOS caps each job at cpu=12 (sacctmgr) - asking for more
# leaves the job pending forever with QOSMaxCpuPerJobLimit. Builds don't
# need a GPU device (nvcc only needs the toolkit), so no --gres here.
#
#SBATCH --job-name=db-spack
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=48
#SBATCH --time=04:00:00
#SBATCH --partition=gpu2
#SBATCH --account=hpc_db4admin
#SBATCH --output=%x-%j.log

set -euo pipefail

ENV_NAME="${1:?usage: sbatch -J <job-name> scripts/deepbayou/install-env.sh <env-name>}"

# SLURM_SUBMIT_DIR, not the script's own location (QB4 lesson: a relative
# sbatch path + a different startup cwd on the compute node broke that).
REPO_ROOT="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
cd "$REPO_ROOT"

ENV_DIR="environments/deepbayou/$ENV_NAME"
if [ ! -f "$ENV_DIR/spack.yaml" ]; then
  echo "No such environment: $ENV_DIR" >&2
  exit 2
fi

# Auto-push this job's log to the cluster-results branch on any normal exit
# (see scripts/lib/push-results.sh; scripts/push-latest-results.sh is the
# manual fallback when Slurm hard-kills the job on walltime/OOM).
LOG_FILE="$REPO_ROOT/${SLURM_JOB_NAME:-db-spack}-${SLURM_JOB_ID:-manual}.log"
source "$REPO_ROOT/scripts/lib/push-results.sh"
trap push_results EXIT
# Slurm's walltime kill sends SIGTERM first (SIGKILL only ~30 s later).
# Without this, bash ran the EXIT trap with $? == 0, so job 12 - killed at
# its time limit - was recorded on cluster-results as "exit=0". 143 =
# 128 + SIGTERM.
trap 'exit 143' TERM

# QB4 lesson: a conda (base) shell leaks its own python into Spack.
unset SPACK_PYTHON
export SPACK_PYTHON=/usr/bin/python3
# Carried over from scripts/qb4/tier3-test-install.sh (the only QB4 script
# that had it, and Tier 3 is part of tiers-test here): empty the default
# pkg-config search path so builds only see the .pc files Spack itself puts
# on PKG_CONFIG_PATH for their declared dependencies, never the host's
# /usr/lib64/pkgconfig.
export PKG_CONFIG_LIBDIR=/nonexistent
export PKG_CONFIG_PATH=
SPACK_ROOT_DIR="${SPACK_ROOT_DIR:-/project/fchen14/spack-tool}"
source "$SPACK_ROOT_DIR/share/spack/setup-env.sh"

echo "=== host $(hostname), env $ENV_DIR, spack $(spack --version), repo $(git rev-parse --short HEAD) ==="

spack env activate "$ENV_DIR"

# Always re-solve from the committed config: spack.lock is git-ignored and
# a stale lock (or reuse of an old install) silently ignores config
# changes - two QB4 debugging detours came from exactly that.
spack concretize -f --fresh

JOBS="${SLURM_CPUS_PER_TASK:-8}"

# Watchdog for the "spack install hangs after a failed build" problem:
# db job 12 (tiers-test) finished all real build work within the first
# hour or so, then hung right after revbayes failed until the 12 h walltime
# killed it - valgrind, whose dependencies were all already installed, was
# never even started. QB4's tier3 hung at the same spot (after revbayes)
# three times; that was blamed on the /project fcntl DB lock, but
# tiers-test already runs with `locks: false`, so that explanation was at
# best incomplete. Until the real cause is known: stop `spack install` 20
# minutes before the walltime, dump the process tree (the evidence we need
# for the next diagnosis), and still run the module refresh and the log
# push instead of losing everything to the Slurm kill.
remaining_seconds() {
  # squeue %L: [days-]hours:minutes:seconds, or minutes:seconds
  local left d=0 h=0 m=0 sec=0
  left=$(squeue -h -j "$SLURM_JOB_ID" -o %L 2>/dev/null) || return 1
  [[ "$left" == *-* ]] && { d=${left%%-*}; left=${left#*-}; }
  IFS=: read -r -a parts <<< "$left"
  case ${#parts[@]} in
    3) h=${parts[0]}; m=${parts[1]}; sec=${parts[2]} ;;
    2) m=${parts[0]}; sec=${parts[1]} ;;
    *) return 1 ;;
  esac
  echo $(( 10#$d*86400 + 10#$h*3600 + 10#$m*60 + 10#$sec ))
}
INSTALL_TIMEOUT=0   # 0 = no limit (manual runs outside Slurm)
if [ -n "${SLURM_JOB_ID:-}" ] && left=$(remaining_seconds) && [ "$left" -gt 1800 ]; then
  INSTALL_TIMEOUT=$(( left - 1200 ))
fi
echo "=== spack install -j $JOBS (watchdog: ${INSTALL_TIMEOUT}s, 0 = none) ==="

# Run spack install in the background so the watchdog can inspect it while
# it is still alive (GNU timeout would kill it before we could look).
spack install -j "$JOBS" &
install_pid=$!
install_rc=0
if [ "$INSTALL_TIMEOUT" -gt 0 ]; then
  ( sleep "$INSTALL_TIMEOUT"
    if kill -0 "$install_pid" 2>/dev/null; then
      echo "!!! WATCHDOG: spack install still running after ${INSTALL_TIMEOUT}s - dumping state, then killing it"
      ps -u "$USER" -o pid,ppid,etime,pcpu,stat,wchan:20,cmd --forest
      for pid in $(pgrep -u "$USER" -f 'spack.*install'); do
        echo "--- /proc/$pid/stack and open files ($pid)"
        cat "/proc/$pid/wchan" 2>/dev/null; echo
        ls -l "/proc/$pid/fd" 2>/dev/null | tail -20
        timeout 10 strace -f -p "$pid" 2>&1 | tail -20 || true
      done
      pkill -TERM -P "$install_pid" 2>/dev/null || true
      kill -TERM "$install_pid" 2>/dev/null || true
      sleep 60
      kill -KILL "$install_pid" 2>/dev/null || true
    fi ) &
  watchdog_pid=$!
fi
wait "$install_pid" || install_rc=$?
[ -n "${watchdog_pid:-}" ] && kill "$watchdog_pid" 2>/dev/null || true
echo "=== spack install exited with $install_rc ==="

# Save every failed package's build log before the job ends: Spack keeps
# failed stages, but build_stage is the compute node's /tmp, which Slurm
# wipes when the job finishes (revbayes' log from job 12 was already gone
# when we went to read it). Spack prints one "[x] <hash> <pkg> failed:
# <log path>" line per failure; copy each log (plus the CMake/configure
# logs next to it, when present) into RESULT_EXTRA_DIR, which
# push_results commits under failed-builds/.
RESULT_EXTRA_DIR="${TMPDIR:-/tmp}/${USER}-failed-builds-${SLURM_JOB_ID:-manual}"
export RESULT_EXTRA_DIR
grep -oE '^\[x\] [a-z0-9]{7} [^ ]+ failed: [^ ]+\.log' "$LOG_FILE" 2>/dev/null | sort -u |
while read -r _ hash pkg _ log; do
  mkdir -p "$RESULT_EXTRA_DIR"
  name="${pkg%%@*}-${hash}"
  echo "--- saving failed build log for $pkg: $log"
  cp -f "$log" "$RESULT_EXTRA_DIR/${name}.log" 2>/dev/null || echo "    (log no longer exists)"
  stage="${log%.log}"
  for extra in "$stage"/spack-build-out.txt "$stage"/spack-build-env.txt \
               "$stage"/spack-build-*/CMakeFiles/CMakeConfigureLog.yaml \
               "$stage"/spack-build-*/CMakeFiles/CMakeError.log \
               "$stage"/spack-src/config.log; do
    [ -f "$extra" ] && cp -f "$extra" "$RESULT_EXTRA_DIR/${name}.$(basename "$extra")"
  done
  echo "    last 40 lines:"; tail -40 "$log" 2>/dev/null | sed 's/^/    | /'
done || true

# Regenerate modules even if some packages failed - everything that DID
# install should still get its module file.
spack module lmod refresh -y --delete-tree || true
echo "=== done: $ENV_DIR (install rc=$install_rc) ==="
exit "$install_rc"
