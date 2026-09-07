#!/bin/bash
# sbatch template for the environments/tier1-test Spack environment.
#
# Purpose: REAL (not --fake) `spack install` of the Tier 1 batch (boost,
# eigen, git, gsl, hwloc, valgrind, cmake) added on top of the smoke-test
# scale, to validate the bulk-build pipeline at something closer to the
# real production software list. All 7 only need a plain compiler (no
# MPI/CUDA), so no GPU is requested here - same rationale as the smoke
# test script. Walltime bumped to 4h vs. the smoke test's 2h because this
# batch pulls in git's autotools bootstrap chain (~40 extra small
# packages under %gcc: autoconf/automake/curl/openssl/perl/openssh/krb5
# etc.) plus duplicate builds of boost/curl/perl/openssl (once under
# %oneapi for cmake's needs, once under %gcc for git's needs) - see
# concretize output notes in the project doc for why.
#
# Usage:
#   sbatch scripts/tier1-test-install.sh
#
#SBATCH --job-name=spack-tier1-test
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --time=04:00:00
#SBATCH --output=tier1-test-install-%j.log
# Real cluster values (LONI) - same as smoke-test-install.sh.
#SBATCH --partition=gpu2
#SBATCH --account=loni_loniadmin1
set -euo pipefail
REPO_ROOT="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
cd "$REPO_ROOT"
unset SPACK_PYTHON
export SPACK_PYTHON=/usr/bin/python3
source /project/fchen14/spack-tool/share/spack/setup-env.sh
spack env activate environments/tier1-test
JOBS="${SLURM_CPUS_PER_TASK:-4}"
spack install -j "$JOBS"
spack module lmod refresh -y
