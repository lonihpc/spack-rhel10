# Site override of the builtin `namd` package for the RHEL10 cluster.
#
# Real bug (not Spack's recipe, not our config): namd@2.14's
# src/DeviceCUDA.C reads `deviceProp.computeMode` (from
# cudaGetDeviceProperties) in three places to detect GPUs in
# "prohibited"/"exclusive-process" CUDA compute mode. NVIDIA has since
# removed the `computeMode` field from `cudaDeviceProp` entirely in
# newer CUDA Runtime API headers (deprecated, then dropped by CUDA
# 13.3) - confirmed by the real build error:
#   error: 'struct cudaDeviceProp' has no member named 'computeMode'
# at DeviceCUDA.C:166, :174, :349. namd's source is manual-download/
# license-gated (can't be fetched or patched via a checked-in .patch
# file against a public mirror), so the exact surrounding lines were
# pulled directly off the cluster (from the already-downloaded,
# manually-placed source tarball) to write this fix precisely rather
# than guessing at the multi-line `if` boundaries.
#
# Fix: since compute-mode can no longer be queried at all, there is no
# way to actually detect prohibited/exclusive-mode devices anymore -
# the least invasive fix (matching the surrounding code's own
# structure) is to make each of the 3 `if` conditions that reference
# `.computeMode` unconditionally take the branch it would take on a
# normal, unrestricted device: never "prohibited", never
# "exclusive-process". This preserves every surrounding line (the rest
# of each multi-line boolean expression, or the following independent
# `if` checks) untouched - only the single line containing the
# `.computeMode` comparison is rewritten to a literal 1/0. Practical
# effect: on hardware that isn't in a restricted compute mode (true for
# this cluster's normal, non-MPS GPU allocation), behavior is identical
# to before; a genuinely prohibited/exclusive-mode GPU would just fail
# later with a real CUDA runtime error instead of namd's own friendlier
# early message - an acceptable loss of a diagnostic-only check, not a
# functional regression for normal use.
#
# No separate Builder class needed here (unlike cp2k/charmpp) - namd's
# builtin package.py defines `edit()`/`install()` directly on the
# `Namd` class itself with no explicit MakefileBuilder subclass, so
# this is the "old-style"/Adapter case where a @run_before hook on the
# Package class DOES get merged into the effective builder automatically
# (see cp2k's package.py comment for the contrasting case that doesn't).
#
# version("3.0.3", ...) below: builtin's namd package.py doesn't know
# about 3.0.3 yet (NAMD's own site has released newer versions than
# Spack's recipe has caught up to - only 3.0.2/3.0.1/2.x are declared
# upstream). Since Spack's DirectiveMeta re-merges a parent class's
# already-registered version()/variant()/depends_on() directives into
# a subclass (confirmed elsewhere in this repo, e.g. the python
# override), adding one more version() here is a normal, additive
# extension - not a fork of the whole recipe. sha256 confirmed by the
# user directly from the file they downloaded from NAMD's own site.
#
# SECOND, unrelated real bug found once namd@3.0.3's build got past
# fetch/charmpp/edit and into actual CUDA kernel compilation: CUDA
# 13.3 merged CUB/Thrust/libcu++ into one "CCCL" (CUDA Core Compute
# Libraries) project, and along with that merge, renamed the macro
# used to suppress its "C++17 required" version check from the old,
# separate `CUB_IGNORE_DEPRECATED_CPP_DIALECT`/
# `THRUST_IGNORE_DEPRECATED_CPP_DIALECT` to a single, unified
# `CCCL_IGNORE_DEPRECATED_CPP_DIALECT`. namd@3.0.3's own
# arch/Linux-x86_64.cuda already defines the two old macros (upstream
# clearly hit this exact class of problem before and worked around it
# for older CUDA) but hasn't caught up with CUDA 13.3's rename, so the
# new macro is never defined and the #error still fires:
#   error: #error CUB requires at least C++17. Define
#   CCCL_IGNORE_DEPRECATED_CPP_DIALECT to suppress this message.
# (repeated for Thrust's and libcu++'s own copies of the same check).
# THIRD, discovered right after fixing the above (job 67): defining
# CCCL_IGNORE_DEPRECATED_CPP_DIALECT only suppresses the *warning-level*
# #error gate - it doesn't make an actual C++11 compile magically
# support C++17 language features. Once the #error stopped blocking
# compilation, real errors surfaced from deep inside CUDA 13.3's own
# CCCL headers (__floating_point/storage.h, __limits/
# numeric_limits_ext.h, etc.), e.g. "a constexpr function must contain
# exactly one return statement" - a genuine C++11 restriction (relaxed
# in C++14) that CCCL's own header code now relies on being relaxed.
# So CUDA 13.3's CCCL genuinely requires C++17, not just a suppressed
# warning about wanting it. The real fix is bumping
# arch/Linux-x86_64.cuda's own `CUDA_COMPILER_FLAGS = -m64 -std=c++11`
# to `-std=c++17` for nvcc's CUDA compilation units - this only affects
# the separately-compiled .cu translation units (linked at the object
# level with namd's other, still -std=c++11 g++-compiled host code;
# the C++ standard flag doesn't affect libstdc++'s ABI, which is
# controlled by a separate macro), so it's safe and narrowly scoped.
# Once this is done, the CCCL_IGNORE_DEPRECATED_CPP_DIALECT macro from
# the fix above technically becomes unnecessary (the version check it
# suppresses would no longer fire) but is harmless to leave defined.
#
# Confirmed by pulling arch/Linux-x86_64.cuda directly off the cluster
# (from the same manually-downloaded, license-gated source tarball as
# the DeviceCUDA.C fix above) - it's a simple Makefile variable
# assignment, not kernel code, so the fix just adds the one missing
# `-D` flag right after the two existing ones, in the exact same style.
import os

from spack_repo.builtin.packages.namd.package import Namd as BuiltinNamd

from spack.package import *


class Namd(BuiltinNamd):
    version(
        "3.0.3",
        sha256="374537dd2c724116cbf45e3f72438f236012fd2664cb43e84de08c7fb9267424",
    )

    @run_before("build")
    def fix_removed_cuda_device_compute_mode(self):
        # Written and verified against namd@2.14's src/DeviceCUDA.C (see
        # module docstring above). We now build namd@3.0.3 instead (its
        # GPU backend was rewritten to use texture objects instead of
        # the legacy texture-reference API that made 2.14 uncompilable
        # under CUDA 13.3 - see environments/gpu-test/spack.yaml's
        # comment), so it's unknown/unverified whether 3.0.3's
        # DeviceCUDA.C (if it still exists under this path at all) still
        # has these exact `.computeMode` lines. ignore_absent=True makes
        # a missing file a harmless no-op rather than a hard error, and
        # filter_file itself already no-ops on any pattern that doesn't
        # match - so this hook is safe to leave in place for whichever
        # namd version is actually being built, active only where it's
        # still needed.
        if self.spec.satisfies("+cuda"):
            device_cuda_c = os.path.join(self.stage.source_path, "src", "DeviceCUDA.C")
            filter_file(
                r"^(\s*)if \( deviceProp\.computeMode != cudaComputeModeProhibited$",
                r"\1if ( 1",
                device_cuda_c,
                ignore_absent=True,
            )
            filter_file(
                r"^(\s*)if \( deviceProp\.computeMode == cudaComputeModeExclusive \) \{$",
                r"\1if ( 0 ) {",
                device_cuda_c,
                ignore_absent=True,
            )
            filter_file(
                r"^(\s*)if \( deviceProp\.computeMode == cudaComputeModeProhibited \)$",
                r"\1if ( 0 )",
                device_cuda_c,
                ignore_absent=True,
            )

    @run_before("build")
    def fix_cccl_cpp_dialect_macro_rename(self):
        if self.spec.satisfies("+cuda"):
            arch_cuda_file = os.path.join(
                self.stage.source_path, "arch", self.arch + ".cuda"
            )
            filter_file(
                r"^(\s*)CUDA_COMPILER_FLAGS \+= -DTHRUST_IGNORE_DEPRECATED_CPP_DIALECT$",
                r"\1CUDA_COMPILER_FLAGS += -DTHRUST_IGNORE_DEPRECATED_CPP_DIALECT"
                + "\n"
                + r"\1CUDA_COMPILER_FLAGS += -DCCCL_IGNORE_DEPRECATED_CPP_DIALECT",
                arch_cuda_file,
                ignore_absent=True,
            )
            filter_file(
                r"^(\s*)CUDA_COMPILER_FLAGS = -m64 -std=c\+\+11$",
                r"\1CUDA_COMPILER_FLAGS = -m64 -std=c++17",
                arch_cuda_file,
                ignore_absent=True,
            )
