#!/bin/bash
# GPU functional validation for environments/deepbayou/gpu-test
# (deployment step 9): run one small case per GPU code on the 2x V100S of a
# Deep Bayou RHEL10 node and check that it actually ran on the GPU.
#
# Usage (repo root, db login node):
#   sbatch -J db-gpu-validate scripts/deepbayou/gpu-validate.sh
#   sbatch -J db-gpu-validate scripts/deepbayou/gpu-validate.sh lammps cp2k   # subset
#
# Tests (each independent; one failing does not stop the others):
#   lammps  inline LJ melt (256k atoms, 1000 steps), `-sf gpu -pk gpu 2`,
#           2 MPI ranks; checks the "GPU package" device banner.
#   cp2k    a tiny H2O PBE single point (DZVP-MOLOPT-SR-GTH),
#           2 MPI ranks; checks the energy converged and the
#           OFFLOAD/DBM GPU report lines.
#   namd    apoa1 (92k atoms) on 2 GPUs, 2 SMP processes x 22 PEs - only if
#           $NAMD_APOA1_DIR (default /project/fchen14/spack-rhel10-packages/apoa1)
#           exists; otherwise SKIP. Get it once on the login node:
#             cd /project/fchen14/spack-rhel10-packages
#             wget https://www.ks.uiuc.edu/Research/namd/utilities/apoa1.tar.gz
#             tar xzf apoa1.tar.gz
#
# GPU use is proven independently of each program's own banner by a
# background `nvidia-smi --query-compute-apps` sampler; the summary lists
# which executables were seen on the GPUs.
#
# Outputs go to a scratch dir under /project (not /tmp - Slurm wipes /tmp at
# job end); key lines are copied into the job log, which push-results.sh
# pushes to cluster-results like the install jobs.
#
#SBATCH --job-name=db-gpu-validate
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=48
#SBATCH --gres=gpu:2
#SBATCH --time=01:00:00
#SBATCH --partition=gpu2
#SBATCH --account=hpc_db4admin
#SBATCH --output=%x-%j.log

set -uo pipefail   # no -e: a failing test must not abort the others

TESTS=("$@")
[ ${#TESTS[@]} -eq 0 ] && TESTS=(lammps cp2k namd)

REPO_ROOT="${SLURM_SUBMIT_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/../.." && pwd)}"
cd "$REPO_ROOT"
ENV_DIR="environments/deepbayou/gpu-test"

LOG_FILE="$REPO_ROOT/${SLURM_JOB_NAME:-db-gpu-validate}-${SLURM_JOB_ID:-manual}.log"
source "$REPO_ROOT/scripts/lib/push-results.sh"
trap push_results EXIT
trap 'exit 143' TERM

unset SPACK_PYTHON
export SPACK_PYTHON=/usr/bin/python3
SPACK_ROOT_DIR="${SPACK_ROOT_DIR:-/project/fchen14/spack-tool}"
source "$SPACK_ROOT_DIR/share/spack/setup-env.sh"

NAMD_APOA1_DIR="${NAMD_APOA1_DIR:-/project/fchen14/spack-rhel10-packages/apoa1}"
WORK="/project/fchen14/spack-rhel10-db-gpu-validate/${SLURM_JOB_ID:-manual}"
mkdir -p "$WORK"
NP=2                      # one MPI rank per GPU
NT=$(( ${SLURM_CPUS_PER_TASK:-48} / NP ))

echo "=== host $(hostname), repo $(git rev-parse --short HEAD), work $WORK ==="
nvidia-smi
nvidia-smi --query-gpu=index,name,driver_version,memory.total,compute_cap --format=csv

# Single-node job: let Intel MPI fork its ranks locally instead of going
# through an srun step (the allocation is 1 task x 48 cpus).
export I_MPI_HYDRA_BOOTSTRAP=fork
export I_MPI_PIN_DOMAIN=omp
export OMP_NUM_THREADS=$NT

# Background GPU sampler: every second, which processes hold a GPU context.
GPU_SAMPLES="$WORK/gpu-apps.csv"
nvidia-smi --query-compute-apps=timestamp,gpu_uuid,pid,process_name,used_memory \
  --format=csv,noheader -l 1 > "$GPU_SAMPLES" 2>&1 &
SAMPLER_PID=$!

declare -A RESULT

pkg_prefix() { spack -e "$ENV_DIR" location -i "$1" 2>/dev/null; }

# `spack -e <env> load` bypasses the shell function (it only intercepts when
# `load` is the first argument - job 16 failed on exactly that), so use the
# --sh form and eval it. Then make sure Intel MPI's mpirun is on PATH: the
# external's prefix is the oneAPI root, so source its own vars.sh if the
# load did not already put mpirun there.
load_pkg() {
  eval "$(spack -e "$REPO_ROOT/$ENV_DIR" load --sh "$1")" || return 1
  if ! command -v mpirun >/dev/null; then
    local mp vars
    mp=$(pkg_prefix intel-oneapi-mpi)
    vars=$(ls -d "$mp"/mpi/*/env/vars.sh 2>/dev/null | sort -V | tail -1)
    [ -n "$vars" ] && source "$vars"
  fi
  echo "load $1: mpirun=$(command -v mpirun || echo MISSING)"
}

run_lammps() {
  local p; p=$(pkg_prefix lammps) || { RESULT[lammps]="FAIL (not installed)"; return; }
  local d="$WORK/lammps"; mkdir -p "$d"; cd "$d"
  cat > in.lj <<'EOF'
units           lj
atom_style      atomic
lattice         fcc 0.8442
region          box block 0 40 0 40 0 40
create_box      1 box
create_atoms    1 box
mass            1 1.0
velocity        all create 1.44 87287 loop geom
pair_style      lj/cut 2.5
pair_coeff      1 1 1.0 1.0 2.5
neighbor        0.3 bin
neigh_modify    delay 0 every 20 check no
fix             1 all nve
thermo          100
run             1000
EOF
  ( load_pkg lammps || exit 99
    export OMP_NUM_THREADS=1
    mpirun -n $NP lmp -sf gpu -pk gpu $NP -in in.lj -log log.lammps ) > out.txt 2>&1
  local rc=$?
  grep -E "GPU package|Device [0-9]|Loop time|Performance:" out.txt | head -20
  if [ $rc -eq 0 ] && grep -q "Loop time" out.txt && grep -qiE "Device 0: .*V100" out.txt; then
    RESULT[lammps]="PASS ($(grep -m1 '^Performance:' out.txt))"
  else
    RESULT[lammps]="FAIL (rc=$rc)"; tail -40 out.txt
  fi
  cd "$REPO_ROOT"
}

run_cp2k() {
  local p; p=$(pkg_prefix cp2k) || { RESULT[cp2k]="FAIL (not installed)"; return; }
  local exe; exe=$(ls "$p"/bin/cp2k.psmp "$p"/bin/cp2k.popt 2>/dev/null | head -1)
  local data; data=$(dirname "$(find "$p" -name BASIS_MOLOPT -print -quit)")
  [ -n "$exe" ] && [ -n "$data" ] || { RESULT[cp2k]="FAIL (exe/data not found under $p)"; return; }
  local d="$WORK/cp2k"; mkdir -p "$d"; cd "$d"
  cat > h2o.inp <<'EOF'
&GLOBAL
  PROJECT h2o
  RUN_TYPE ENERGY
  PRINT_LEVEL MEDIUM
&END GLOBAL
&FORCE_EVAL
  METHOD Quickstep
  &DFT
    BASIS_SET_FILE_NAME BASIS_MOLOPT
    POTENTIAL_FILE_NAME GTH_POTENTIALS
    &MGRID
      CUTOFF 400
      REL_CUTOFF 50
    &END MGRID
    &SCF
      EPS_SCF 1.0E-6
      MAX_SCF 50
    &END SCF
    &XC
      &XC_FUNCTIONAL PBE
      &END XC_FUNCTIONAL
    &END XC
  &END DFT
  &SUBSYS
    &CELL
      ABC 10.0 10.0 10.0
    &END CELL
    &COORD
      O   0.000000  0.000000  0.117790
      H   0.000000  0.755453 -0.471161
      H   0.000000 -0.755453 -0.471161
    &END COORD
    &KIND H
      BASIS_SET DZVP-MOLOPT-SR-GTH
      POTENTIAL GTH-PBE-q1
    &END KIND
    &KIND O
      BASIS_SET DZVP-MOLOPT-SR-GTH
      POTENTIAL GTH-PBE-q6
    &END KIND
  &END SUBSYS
&END FORCE_EVAL
EOF
  ( load_pkg cp2k || exit 99
    export CP2K_DATA_DIR="$data" OMP_NUM_THREADS=4
    mpirun -n $NP "$exe" -i h2o.inp ) > out.txt 2>&1
  local rc=$?
  grep -iE "OFFLOAD|GPU|DBM|ENERGY\| Total FORCE_EVAL|SCF run converged" out.txt | head -20
  if [ $rc -eq 0 ] && grep -q "SCF run converged" out.txt; then
    RESULT[cp2k]="PASS ($(grep -m1 'ENERGY| Total FORCE_EVAL' out.txt | awk '{print $NF}') Ha)"
  else
    RESULT[cp2k]="FAIL (rc=$rc)"; tail -40 out.txt
  fi
  cd "$REPO_ROOT"
}

run_namd() {
  if [ ! -f "$NAMD_APOA1_DIR/apoa1.namd" ]; then
    RESULT[namd]="SKIP (no $NAMD_APOA1_DIR/apoa1.namd)"; return
  fi
  pkg_prefix namd >/dev/null || { RESULT[namd]="FAIL (not installed)"; return; }
  local d="$WORK/namd"; mkdir -p "$d"; cp "$NAMD_APOA1_DIR"/* "$d"/; cd "$d"
  # apoa1.namd writes to /usr/tmp by default; keep output here.
  sed -i 's#^outputname.*#outputname ./apoa1-out#' apoa1.namd
  ( load_pkg namd || exit 99
    # charmpp here is an SMP build: every charmrun process = ++ppn worker
    # PEs + 1 comm thread. Job 17 used `+p8` (no ++ppn) -> 8 processes with
    # 1 PE each, and NAMD 3 refuses to share 2 GPUs among 8 processes
    # ("Number of devices (2) is not a multiple of number of processes (8)").
    # One process per GPU instead: 2 processes x 22 PEs (+2 comm threads =
    # 46 of the 48 cores).
    charmrun ++local +p44 ++ppn 22 "$(command -v namd3)" +setcpuaffinity +devices 0,1 apoa1.namd ) > out.txt 2>&1
  local rc=$?
  grep -E "Pe [0-9]+ .*CUDA device|CUDA device|Benchmark time|WallClock" out.txt | head -20
  if [ $rc -eq 0 ] && grep -q "WallClock" out.txt && grep -q "CUDA device" out.txt; then
    RESULT[namd]="PASS ($(grep -m1 'Benchmark time' out.txt | sed 's/^Info: //'))"
  else
    RESULT[namd]="FAIL (rc=$rc)"
    # The NAMD_die message sits above the per-PE backtraces, so a plain
    # tail (job 17) only showed stack frames. Print the reason first.
    echo "--- first error lines:"; grep -m10 -nE "FATAL ERROR|ERROR:|CUDA error|Charm\+\+ fatal" out.txt
    echo "--- head:"; head -60 out.txt
  fi
  cd "$REPO_ROOT"
}

for t in "${TESTS[@]}"; do
  echo; echo "===================== $t ====================="
  SECONDS=0
  "run_$t"
  echo "--- $t: ${RESULT[$t]} (${SECONDS}s)"
done

kill $SAMPLER_PID 2>/dev/null; wait $SAMPLER_PID 2>/dev/null

echo; echo "===================== GPU processes seen by nvidia-smi ====================="
awk -F', ' 'NF>=5 {split($4,a,"/"); n=a[length(a)]; mem[n]= ($5+0>mem[n]+0)? $5 : mem[n]; gpu[n][$2]=1}
  END {for (n in mem) {c=0; for (g in gpu[n]) c++; printf "  %-20s max %s, on %d GPU(s)\n", n, mem[n], c}}' "$GPU_SAMPLES"

echo; echo "===================== SUMMARY ====================="
rc=0
for t in "${TESTS[@]}"; do
  echo "  $t: ${RESULT[$t]}"
  case "${RESULT[$t]}" in FAIL*) rc=1 ;; esac
done
echo "  outputs: $WORK"
exit $rc
