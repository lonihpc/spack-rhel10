#!/bin/bash
# sbatch template for the environments/tier3-test Spack environment.
#
# Purpose: REAL (not --fake) `spack install` of the Tier 3 batch (bowtie2,
# hisat2, star, spades, vcftools, revbayes - bioinformatics tools) to
# validate the bulk-build pipeline at something closer to the real
# production software list.
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
export TCLTK_CFLAGS="-I/nonexistent"
export TCLTK_LIBS="-L/nonexistent"
export PKG_CONFIG_LIBDIR=/nonexistent
source /project/fchen14/spack-tool/share/spack/setup-env.sh
spack env activate environments/tier3-test
JOBS="${SLURM_CPUS_PER_TASK:-8}"
spack install -j "$JOBS"
spack module lmod refresh -y
