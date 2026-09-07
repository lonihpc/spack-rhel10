#!/bin/bash
# sbatch template for the environments/tier1-test Spack environment.
#
# Purpose: a REAL (not --fake) `spack install` of the Tier 1 batch (boost,
# eigen, gsl, hwloc, valgrind, git, cmake) to validate the bulk-build
# pipeline at a size closer to the real target list, still under this
# personal account (NOT /usr/local/packages - that's production, and its
# install_tree naming isn't finalized yet). Same idea as
# scripts/smoke-test-install.sh (already validated with 3 packages), now
# scaled up to 7. This MUST run on a compute node via sbatch, never on the
# login node (see CLAUDE.md).
#
# Usage:
#   sbatch scripts/tier1-test-install.sh
#
# Resource requests below are deliberately conservative defaults - bump
# them if the real cluster's queue/partition needs something different, or
# if 7 packages need more time/cores than the smoke test's 3 did.
#
#SBATCH --job-name=spack-tier1-test
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --time=02:00:00
#SBATCH --output=tier1-test-install-%j.log
# Real cluster values (LONI) - filled in from the smoke-test run.
#SBATCH --partition=gpu2
#SBATCH --account=loni_loniadmin1


set -euo pipefail


# Prefer SLURM_SUBMIT_DIR (always the directory `sbatch` was actually run
# from, unaffected by the compute node's startup cwd) over resolving the
# script's own location - the latter can resolve wrong when sbatch is
# submitted with a relative path and the job's startup cwd differs from the
# submit dir (this is what caused the "No such environment" failure in the
# smoke test). Falls back to the old script-location-based resolution only
# when run manually outside Slurm.
REPO_ROOT="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
cd "$REPO_ROOT"

#source spack/share/spack/setup-env.sh
unset SPACK_PYTHON
export SPACK_PYTHON=/usr/bin/python3
source /project/fchen14/spack-tool/share/spack/setup-env.sh
spack env activate environments/tier1-test

JOBS="${SLURM_CPUS_PER_TASK:-4}"
spack install -j "$JOBS"

# Generate real module files against the tier1-test install tree too, so
# the module-generation half of the pipeline gets exercised for real, not
# just `spack install`.
spack module lmod refresh -y
