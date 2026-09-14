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
