#!/bin/bash
# sbatch template for the environments/smoke-test Spack environment.
#
# Purpose: a small, fast, REAL (not --fake) `spack install` of 3
# representative packages (cmake, cosma, bwa %nvhpc) to prove the whole
# pipeline works on an actual RHEL10 compute node - real compilers found
# and invoked (including nvhpc, exercised for the first time for real
# here), real network/download access, real module generation - before
# committing to a full production install. This MUST run on a compute
# node via sbatch, never on the login node (see CLAUDE.md).
#
# Usage:
#   sbatch scripts/smoke-test-install.sh
#
# Resource requests below are deliberately conservative defaults - bump
# them if the real cluster's queue/partition needs something different.
# No GPU requested: none of these 3 packages need to RUN on a GPU, bwa
# only needs nvhpc as a COMPILER to be present on the node, which doesn't
# require a --gpus/--gres request.
#
# Walltime re-evaluated after making `cuda` spack-built (config/
# packages.yaml, require:@13.3.0 instead of external) - kept at 2h: none
# of these 3 packages (cmake, cosma, bwa %nvhpc) actually depend on the
# standalone `cuda` package (confirmed via `spack concretize` - it doesn't
# appear anywhere in this environment's dependency graph), and
# intel-oneapi-compilers/intel-oneapi-mpi/nvhpc all stay external (not
# spack-built - see config/packages.yaml and CLAUDE.md for why), so this
# smoke test's actual download/build workload is unchanged from before.
#
#SBATCH --job-name=spack-smoke-test
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --time=02:00:00
#SBATCH --output=smoke-test-install-%j.log
# Real cluster values (LONI) - filled in from a prior run.
#SBATCH --partition=gpu2
#SBATCH --account=loni_loniadmin1


set -euo pipefail


# Resolve the repo root relative to this script's own location, so this
# works regardless of the directory `sbatch` was invoked from.
REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
cd "$REPO_ROOT"

#source spack/share/spack/setup-env.sh
unset SPACK_PYTHON
export SPACK_PYTHON=/usr/bin/python3
source /project/fchen14/spack-tool/share/spack/setup-env.sh
spack env activate environments/smoke-test

JOBS="${SLURM_CPUS_PER_TASK:-4}"
spack install -j "$JOBS"

# Generate real module files against the smoke-test install tree too, so
# the module-generation half of the pipeline gets exercised for real, not
# just `spack install`.
spack module lmod refresh -y
