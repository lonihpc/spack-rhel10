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
unset SPACK_PYTHON
export SPACK_PYTHON=/usr/bin/python3
export PKG_CONFIG_LIBDIR=/nonexistent
export PKG_CONFIG_PATH=
source /project/fchen14/spack-tool/share/spack/setup-env.sh
spack env activate environments/gpu-test

JOBS="${SLURM_CPUS_PER_TASK:-16}"

spack concretize -f

# Keep this list in sync with environments/gpu-test/spack.yaml's specs:.
SPECS=(
  "cp2k +cuda cuda_arch=80 %gcc"
  "lammps +cuda cuda_arch=80 %gcc"
  "namd +cuda cuda_arch=80 %gcc"
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
