#!/bin/bash
# Manual fallback for scripts/lib/push-results.sh's one known limitation:
# if Slurm hard-kills a job (walltime SIGKILL, OOM killer), the job
# script's EXIT trap never runs - bash cannot catch SIGKILL - so results
# never get pushed automatically. Slurm itself still writes the
# --output log to the submit directory regardless (that's Slurm's own
# doing, independent of our scripts), it just sits there unpushed. Run
# this by hand afterward to push it anyway, reusing the exact same
# push_results() logic (branch isolation, retry-with-rebase, etc.) as the
# automatic path.
#
# Usage:
#   scripts/push-latest-results.sh <job_name> <job_id> <log_file_path> [exit_code]
# Example (job 12345 got walltime-killed, exit code unknown - check
# `sacct -j 12345 --format=JobID,State,ExitCode` for the real one):
#   scripts/push-latest-results.sh spack-tier2-test 12345 tier2-test-install-12345.log 137
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <job_name> <job_id> <log_file_path> [exit_code]" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
export SLURM_JOB_NAME="$1"
export SLURM_JOB_ID="$2"
LOG_FILE="$3"
EXIT_CODE="${4:-unknown-killed-by-slurm}"

source "$REPO_ROOT/scripts/lib/push-results.sh"
push_results "$EXIT_CODE"
