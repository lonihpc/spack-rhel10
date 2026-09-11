#!/bin/bash
# sbatch template for the environments/tier3-test Spack environment.
#
# Purpose: REAL (not --fake) `spack install` of the Tier 3 batch (bowtie2,
# hisat2, star, spades, vcftools, revbayes - bioinformatics tools) to
# validate the bulk-build pipeline at something closer to the real
# production software list.
#
# Installs SERIALLY (one spec per `spack install` call) instead of a
# single `spack install -j 8` for the whole environment: three real runs
# (jobs 41-43) all hung at the exact same point (right after revbayes
# finished, ~7m27s in every time, regardless of whether spades had
# already failed earlier in that run) with the `spack install` process
# blocked on fcntl(F_SETLK) against
# spack-install/.spack-db/lock with EAGAIN, and no other process holding
# it visible in `lslocks` - a shared-filesystem (this install_tree lives
# under /project) fcntl lock consistency issue, not something caused by
# any one package. Serializing installs means only one spack process ever
# touches the database at a time, which should avoid the lock contention
# entirely. A failure in one spec does NOT stop the rest from being
# attempted - failures are collected and reported at the end, since the
# point of this run is to see how many of the batch build cleanly, not to
# stop at the first problem.
#
# Usage:
#   sbatch scripts/tier3-test-install.sh
#
#SBATCH --job-name=spack-tier3-test
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --time=06:00:00
#SBATCH --output=tier3-test-install-%j.log
# Real cluster values (LONI) - same as smoke-test-install.sh/tier1-test-install.sh/tier2-test-install.sh.
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
spack env activate environments/tier3-test

JOBS="${SLURM_CPUS_PER_TASK:-8}"

spack concretize -f

# Keep this list in sync with environments/tier3-test/spack.yaml's specs:.
# Deliberately unquoted in the loop below - "spades ~sra" needs to split
# into two argv words ("spades" "~sra") for spack's own spec-string
# parser to recombine into one spec, same as typing it on a real command
# line.
SPECS=(
  bowtie2
  hisat2
  star
  "spades ~sra"
  vcftools
  revbayes
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
