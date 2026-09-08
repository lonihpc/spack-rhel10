#!/bin/bash
# sbatch template for the environments/tier2-test Spack environment.
#
# Purpose: REAL (not --fake) `spack install` of the Tier 2 batch (fftw,
# hdf5, netcdf-c, netcdf-cxx4, netcdf-fortran, parallel-netcdf, metis,
# parmetis, superlu-dist, hypre, petsc) to validate the bulk-build
# pipeline with MPI-linked dependency chains at something closer to the
# real production software list.
#
# Resources bumped after a real run (job 29) hit the 8-cpu/6h limits and
# got killed by SLURM on walltime, not a compile error - `spack install`
# is resumable, so this is purely a resource-quota increase
# (cpus-per-task 8->64, walltime 6h->24h), not a sign anything is broken.
#
# Usage:
#   sbatch scripts/tier2-test-install.sh
#
#SBATCH --job-name=spack-tier2-test
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=64
#SBATCH --time=24:00:00
#SBATCH --output=tier2-test-install-%j.log
# Real cluster values (LONI) - same as smoke-test-install.sh/tier1-test-install.sh.
#SBATCH --partition=gpu2
#SBATCH --account=loni_loniadmin1
set -euo pipefail
REPO_ROOT="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
cd "$REPO_ROOT"
unset SPACK_PYTHON
export SPACK_PYTHON=/usr/bin/python3
source /project/fchen14/spack-tool/share/spack/setup-env.sh
spack env activate environments/tier2-test
JOBS="${SLURM_CPUS_PER_TASK:-8}"
spack install -j "$JOBS"
spack module lmod refresh -y
