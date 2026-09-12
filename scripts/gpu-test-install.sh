#!/bin/bash
# sbatch template for the environments/gpu-test Spack environment.
#
# Purpose: REAL (not --fake) `spack install` of the GPU/nvhpc family -
# cp2k, lammps, namd, all built +cuda cuda_arch=80 %nvhpc - to validate
# these compile for real before deciding whether to move any of this
# toward production (not urgent - production's install_tree naming isn't
# finalized yet anyway).
#
# Installs SERIALLY (one spec per `spack install` call), same as
# scripts/tier3-test-install.sh: this install_tree lives on /project (a
# shared filesystem) whose fcntl advisory locks don't reliably release
# between processes - three straight tier3-test runs hung on this
# regardless of concurrency until switched to serial installs +
# config:locks: false (see environments/tier3-test/spack.yaml's comment
# for the full story). Applying the same fix here from the start. A
# failure in one spec does NOT stop the rest from being attempted -
# failures are collected and reported at the end.
#
# cpus-per-task/walltime sized generously: cp2k in particular is one of
# the heaviest builds in the whole target list even without CUDA (DBCSR,
# libxsmm, libint, scalapack, etc. all built from source first), and CUDA
# object files typically compile much slower than plain C++ under nvcc.
# Bump further if this isn't enough - see tier2-test-install.sh's history
# for precedent (8->64 cpus, 6h->24h after a real run undershot).
#
# Usage:
#   sbatch scripts/gpu-test-install.sh
#
#SBATCH --job-name=spack-gpu-test
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --time=08:00:00
#SBATCH --output=gpu-test-install-%j.log
# Real cluster values (LONI) - same as smoke-test-install.sh/tier1-test-install.sh/tier2-test-install.sh/tier3-test-install.sh.
#SBATCH --partition=gpu2
#SBATCH --account=loni_loniadmin1
set -euo pipefail
REPO_ROOT="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
cd "$REPO_ROOT"
unset SPACK_PYTHON
export SPACK_PYTHON=/usr/bin/python3
export PKG_CONFIG_LIBDIR=/nonexistent
export PKG_CONFIG_PATH=
source /project/fchen14/spack-tool/share/spack/setup-env.sh
spack env activate environments/gpu-test

JOBS="${SLURM_CPUS_PER_TASK:-16}"

spack concretize -f

# Keep this list in sync with environments/gpu-test/spack.yaml's specs:.
# Compiler pin is fully-qualified (%c=nvhpc %cxx=nvhpc [%fortran=nvhpc]),
# not bare %nvhpc - see that file's comment for why (bare %nvhpc on cp2k
# gets silently reuse-optimized away to gcc/oneapi with no error). namd
# has no %fortran pin - it has no fortran dependency at all (pure C++).
SPECS=(
  "cp2k +cuda cuda_arch=80 %c=nvhpc %cxx=nvhpc %fortran=nvhpc"
  "lammps +cuda cuda_arch=80 %c=nvhpc %cxx=nvhpc %fortran=nvhpc"
  "namd +cuda cuda_arch=80 %c=nvhpc %cxx=nvhpc"
)

FAILED=()
for spec in "${SPECS[@]}"; do
  echo "=== spack install -j $JOBS $spec ==="
  if ! spack install -j "$JOBS" $spec; then
    echo "!!! FAILED: $spec"
    FAILED+=("$spec")
  fi
done

spack module lmod refresh -y

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "=== ${#FAILED[@]} spec(s) failed: ${FAILED[*]} ==="
  exit 1
fi
