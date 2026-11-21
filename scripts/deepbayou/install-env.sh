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

# QB4 lesson: a conda (base) shell leaks its own python into Spack.
unset SPACK_PYTHON
export SPACK_PYTHON=/usr/bin/python3
SPACK_ROOT_DIR="${SPACK_ROOT_DIR:-/project/fchen14/spack-tool}"
source "$SPACK_ROOT_DIR/share/spack/setup-env.sh"

echo "=== host $(hostname), env $ENV_DIR, spack $(spack --version), repo $(git rev-parse --short HEAD) ==="

spack env activate "$ENV_DIR"

# Always re-solve from the committed config: spack.lock is git-ignored and
# a stale lock (or reuse of an old install) silently ignores config
# changes - two QB4 debugging detours came from exactly that.
spack concretize -f --fresh

JOBS="${SLURM_CPUS_PER_TASK:-8}"
spack install -j "$JOBS"

spack module lmod refresh -y --delete-tree
echo "=== done: $ENV_DIR ==="
