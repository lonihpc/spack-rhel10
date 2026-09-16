#!/bin/bash
# sbatch template for the environments/gpu-test Spack environment.
#
# Purpose: REAL (not --fake) `spack install` of the GPU family - cp2k,
# lammps, namd, all built +cuda cuda_arch=80 %gcc - to validate these
# compile for real before deciding whether to move any of this toward
# production (not urgent - production's install_tree naming isn't
# finalized yet anyway).
#
# Host compiler is %gcc, after TWO failed attempts - see
# environments/gpu-test/spack.yaml's comment for the full story:
#   - %nvhpc: none of these 3 need nvhpc as host compiler (CUDA is
#     handled independently of host-compiler choice in all three), and it
#     hit real nvhpc compiler bugs building namd's charmpp/zstd
#     dependencies (internal compiler crash, assembler-incompatible
#     instruction, stdatomic.h/converse.h conflict) - none of that is
#     GPU-related, it's nvhpc misbehaving on code that never needed it.
#   - %oneapi: failed for a completely different reason - nvcc itself
#     rejects icx outright ("option: icx is not supported in this
#     version!"). Confirmed via NVIDIA's own CUDA 13.4 install guide: gcc
#     6.x-16.x, clang 7.x-22.x, and nvhpc are official supported host
#     compilers on x86_64 - icx isn't listed at all. This is a known,
#     general nvcc limitation (see spack/spack#40374 for the same class
#     of problem elsewhere), not specific to this project's config.
#   - %gcc: the one choice that's both nvcc-accepted (within the
#     supported 6.x-16.x range) and free of nvhpc's compiler bugs.
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

# Auto-push this job's log to the `cluster-results` branch on exit - see
# scripts/lib/push-results.sh for the full design and
# scripts/push-latest-results.sh for the manual SIGKILL fallback.
LOG_FILE="$REPO_ROOT/gpu-test-install-${SLURM_JOB_ID:-manual}.log"
source "$REPO_ROOT/scripts/lib/push-results.sh"
trap push_results EXIT

unset SPACK_PYTHON
export SPACK_PYTHON=/usr/bin/python3
# Deliberately NOT setting PKG_CONFIG_LIBDIR/PKG_CONFIG_PATH here (unlike
# tier3-test-install.sh): those were a since-abandoned attempt at working
# around python's _tkinter/Tcl9 issue (the real fix ended up being the
# repos/spack_repo/rhel10_overrides python override, not these env vars).
# gpu-test doesn't build python at all, and a real run here proved these
# job-wide env vars actively break OTHER packages instead - lammps
# couldn't find fftw3 via pkg-config with PKG_CONFIG_LIBDIR blanked out,
# even though Spack's own build environment would have provided the
# right PKG_CONFIG_PATH for it.
source /project/fchen14/spack-tool/share/spack/setup-env.sh
spack env activate environments/gpu-test

JOBS="${SLURM_CPUS_PER_TASK:-16}"

spack concretize -f

# Keep this list in sync with environments/gpu-test/spack.yaml's specs:.
# lammps' `^fftw`: see that file's comment - without it, the concretizer
# picks the external intel-oneapi-mkl for lammps' fftw-api dependency,
# which doesn't register a pkg-config "fftw3" module, so lammps' CMake
# configure fails to find it even though MKL is genuinely present.
# namd's `^charmpp build-target=charm++`: see that file's comment -
# without it, charmpp's default build-target=LIBS also builds the AMPI/
# ROMIO sub-library that namd never uses, and ROMIO's own MPI-configure
# self-test fails outright under the netlrts backend.
# cp2k's `^fftw`: same class of problem as lammps' - see that file's
# comment. cp2k's own FindFftw.cmake can't locate MKL's FFTW-compatible
# layer even with -DCP2K_USE_FFTW3_WITH_MKL=ON, so force a real,
# Spack-built fftw for cp2k's fftw-api dependency (BLAS/LAPACK/ScaLAPACK
# stay on MKL, unaffected).
#
# namd's `^cuda@12.9.0`: see environments/gpu-test/spack.yaml's comment
# for the full 5-round CUDA-13.3 fix chain and why it was paused, then
# resolved via a second, parallel `cuda@12.9.0` external (registered in
# ../../config/packages.yaml) - NAMD's own release notes cap official
# CUDA support at "9.1-12.x", so this pins namd to a CUDA version it
# actually supports instead of the default cuda@13.3.0 that cp2k/lammps
# use.
SPECS=(
  "cp2k +cuda cuda_arch=80 %gcc ^fftw"
  "lammps +cuda cuda_arch=80 %gcc ^fftw"
  "namd@3.0.3 +cuda cuda_arch=80 %gcc ^charmpp build-target=charm++ ^cuda@12.9.0"
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
