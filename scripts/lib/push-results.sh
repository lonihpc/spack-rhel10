# Sourced (not executed directly) by scripts/*-install.sh to push a
# job's log back to the `cluster-results` branch automatically when the
# script exits - success, failure (our scripts already collect failures
# and `exit 1` themselves, never aborting mid-way via `set -e` on a
# single spec failure), or any other normal exit path.
#
# Design: a dedicated `cluster-results` branch + a separate git worktree
# at $RESULTS_WORKTREE (default /project/fchen14/spack-rhel10-results)
# checked out to it, sharing the same .git as the main checkout but with
# fully independent branch/working-tree state - `git reset --hard` here
# never touches whatever branch/uncommitted work is active in the main
# checkout. No new credentials: `git push` runs as whatever identity the
# submitting user already has push access with, same as any commit made
# by hand.
#
# KNOWN LIMITATION: if Slurm hard-kills the job (walltime SIGKILL, OOM
# killer), this EXIT trap never runs - bash cannot catch SIGKILL. Slurm
# itself still writes the --output log to $SLURM_SUBMIT_DIR regardless
# (that's Slurm's own doing, independent of this script), it just never
# gets pushed automatically. Run scripts/push-latest-results.sh by hand
# afterward to push it.
#
# Callers must set LOG_FILE (path to this job's own log, matching its own
# #SBATCH --output= pattern) before sourcing this file, then:
#   trap push_results EXIT
# RESULTS_WORKTREE is optional, defaults below.

RESULTS_WORKTREE="${RESULTS_WORKTREE:-/project/fchen14/spack-rhel10-results}"

push_results() {
  # ${1:-$?}: called with no args (the normal `trap push_results EXIT`
  # case), $1 is unset so this reads $? - which, as the very first
  # expression evaluated in the function, is still the exit status that
  # triggered the trap (reading $? here, before any other command runs
  # and overwrites it, is what makes this work). scripts/
  # push-latest-results.sh (the manual SIGKILL-recovery path, where there
  # is no real trigering exit status to read) instead calls this with an
  # explicit code as $1.
  local job_rc="${1:-$?}"
  local job_name="${SLURM_JOB_NAME:-job}"
  local result_dir="results/${job_name}/$(date +%Y%m%d-%H%M%S)_job${SLURM_JOB_ID:-unknown}"

  if ! cd "$RESULTS_WORKTREE"; then
    echo "push_results: cannot cd to $RESULTS_WORKTREE, skipping results push" >&2
    return 1
  fi

  # Every git command below is explicitly guarded (|| ...) rather than
  # left as a bare statement: the calling scripts all run under
  # `set -euo pipefail`, and errexit still applies inside a function
  # invoked from an EXIT trap - an unguarded failing command here would
  # silently abort the rest of this function (including the retry loop)
  # instead of following the fallback path below.
  git fetch origin cluster-results || { echo "push_results: git fetch failed" >&2; return 1; }
  git reset --hard origin/cluster-results || { echo "push_results: git reset failed" >&2; return 1; }

  mkdir -p "$result_dir"
  # Log only - never copy actual build output (module files, binaries)
  # here, that belongs in the real install_tree, not this repo.
  cp -f "$LOG_FILE" "$result_dir/" 2>/dev/null
  echo "job ${SLURM_JOB_ID:-unknown} (${job_name}) exited with $job_rc" > "$result_dir/EXIT_CODE"

  git add "$result_dir"
  if ! git commit -m "job ${SLURM_JOB_ID:-unknown} (${job_name}) results, exit=$job_rc"; then
    echo "push_results: nothing to commit (unexpected - EXIT_CODE marker should always be new), skipping push" >&2
    return 1
  fi

  local attempt=0
  until git push origin cluster-results; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 3 ]; then
      echo "push_results: push failed after 3 attempts, giving up - check $RESULTS_WORKTREE by hand" >&2
      return 1
    fi
    git fetch origin cluster-results || true
    git rebase origin/cluster-results || true
  done
}
