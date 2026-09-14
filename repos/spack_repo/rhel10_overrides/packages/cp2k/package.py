# Site override of the builtin `cp2k` package for the RHEL10 cluster.
#
# Real bug in cp2k's own upstream CMakeLists.txt (not Spack's recipe, not
# our config, not the compiler choice) - confirmed by fetching the actual
# source and reading it after the first fix attempt below turned out not
# to help on a real build:
#
#   option(CP2K_USE_ACCEL "..." OFF)
#   if(CP2K_USE_ACCEL MATCHES "CUDA")
#     # P100 is the default target.
#     set(CMAKE_CUDA_ARCHITECTURES 60)
#     ...
#     enable_language(CUDA)
#     ...
#     set(CMAKE_CUDA_ARCHITECTURES ${CP2K_GPU_ARCH_NUMBER_${CP2K_WITH_GPU}})
#
# cp2k hardcodes CMAKE_CUDA_ARCHITECTURES to 60 (Pascal/P100) as a
# throwaway placeholder just so `enable_language(CUDA)` has *something*
# to work with, intending to immediately overwrite it with the real
# architecture derived from CP2K_WITH_GPU a few lines later. But
# `enable_language(CUDA)` runs its own compiler-ABI probe (compiling a
# trivial .cu file) *using that placeholder value* before cp2k's own code
# ever gets to the real assignment - and CUDA 13.3 has dropped support
# for compute_60 entirely, so the probe itself fails outright:
#   nvcc fatal : Unsupported gpu architecture 'compute_60'
# This has nothing to do with cuda_arch=80 (perfectly valid) - the probe
# never gets that far, and it overrides any CMAKE_CUDA_ARCHITECTURES we
# pass on the command line too (which is why the first fix attempt below
# didn't help - cp2k's own `set(... 60)` runs after cmake_args' -D flag
# is parsed, clobbering it before enable_language(CUDA) ever sees our
# value).
#
# FIRST FIX ATTEMPT (kept, harmless but not sufficient on its own):
# append CMAKE_CUDA_ARCHITECTURES to cmake_args() from the same cuda_arch
# variant CP2K_WITH_GPU already derives from. This influences nothing by
# itself since cp2k's CMakeLists.txt unconditionally overwrites it right
# before the probe - but it's a correct, standard CMake variable to pass,
# doesn't hurt, and would start being effective on its own again if
# upstream ever removes their hardcoded placeholder.
#
# REAL FIX: patch cp2k's own top-level CMakeLists.txt, replacing the
# hardcoded placeholder `60` with our actual cuda_arch, so the ABI probe
# uses a real, currently-supported architecture instead of a
# no-longer-supported one. Harmless to cp2k's own later logic - it just
# re-derives and re-assigns the same value from CP2K_WITH_GPU right after
# anyway, so patching the placeholder to already match doesn't change
# cp2k's own behavior, just fixes the probe that runs before that
# re-derivation.
#
# Spack's builder dispatch (spack.builder.get_builder_class) walks the
# package class's MRO and uses the first ancestor whose OWN module
# defines a class named after the buildsystem's builder (here
# "CMakeBuilder") - so defining both Cp2k and CMakeBuilder here, in the
# same module, is what makes this override's CMakeBuilder take effect
# instead of builtin's.
#
# IMPORTANT, learned the hard way (@run_before("cmake") on Cp2k silently
# never fired on a real build - confirmed by the probe still using
# compute_60 despite this hook supposedly patching it away first):
# Spack's phase_callbacks.py only auto-merges @run_before/@run_after
# hooks between a *Package and its *Builder for OLD-STYLE packages (the
# "Adapter" case, e.g. this repo's python/spades/charmpp overrides, which
# have no separate Builder class of their own). cp2k already has an
# explicit, separate CMakeBuilder - for packages like this, phase hooks
# MUST be defined directly on the Builder class, not the Package class,
# or they're simply never invoked. Hence this hook lives on CMakeBuilder
# below, not on Cp2k.
#
# SECOND, UNRELATED real bug found once the above got the build past the
# cmake-configure stage entirely: cp2k@2025.1's
# src/offload/offload_fft.h has a switch statement converting cufftResult
# error codes to human-readable strings, including three enum values -
# CUFFT_INCOMPLETE_PARAMETER_LIST, CUFFT_PARSE_ERROR,
# CUFFT_LICENSE_ERROR - that NVIDIA has since removed from cufft.h
# (deprecated, then dropped entirely by CUDA 13.3, confirmed by the real
# build error: "'CUFFT_INCOMPLETE_PARAMETER_LIST' undeclared" etc., and
# by fetching cp2k's real v2025.1 source from GitHub to confirm the
# other ~15 cufftResult cases in the same switch - including
# CUFFT_INVALID_DEVICE, CUFFT_NO_WORKSPACE, CUFFT_NOT_IMPLEMENTED, which
# are NOT in the error list - still exist in CUDA 13.3's cufft.h, so
# only these 3 specific enum values were actually removed upstream).
# This is purely cosmetic code (converts an error code to its own name
# as a string for logging): the function has no `default:` case, but
# ends with an unconditional `return "<unknown>";` right after the
# switch, so any value that doesn't match a case (including these 3 now
# that they're gone) safely falls through to that instead of undefined
# behavior. Commenting the 3 cases out (rather than deleting) mirrors
# upstream's OWN established precedent for this exact situation - the
# HIP side of the very same function already has
# `// case HIPFFT_LICENSE_ERROR:` / `//   return ...;` commented out for
# the equivalent already-removed HIP enum value, confirmed in the
# fetched source - so this fix is applying upstream's own fix pattern to
# the CUDA side, just not yet done there for newer CUDA toolkits.
import os

from spack_repo.builtin.packages.cp2k.package import Cp2k as BuiltinCp2k
from spack_repo.builtin.packages.cp2k.package import CMakeBuilder as BuiltinCMakeBuilder

from spack.package import *


class Cp2k(BuiltinCp2k):
    pass


class CMakeBuilder(BuiltinCMakeBuilder):
    @run_before("cmake")
    def fix_cuda_arch_probe_placeholder(self):
        if self.spec.satisfies("+cuda"):
            cuda_arch = self.spec.variants["cuda_arch"].value[0]
            cmakelists = os.path.join(self.stage.source_path, "CMakeLists.txt")
            filter_file(
                r"set\(CMAKE_CUDA_ARCHITECTURES 60\)",
                f"set(CMAKE_CUDA_ARCHITECTURES {cuda_arch})",
                cmakelists,
            )

    @run_before("cmake")
    def fix_removed_cufft_error_codes(self):
        if self.spec.satisfies("+cuda"):
            offload_fft_h = os.path.join(
                self.stage.source_path, "src", "offload", "offload_fft.h"
            )
            for enum_name in (
                "CUFFT_INCOMPLETE_PARAMETER_LIST",
                "CUFFT_PARSE_ERROR",
                "CUFFT_LICENSE_ERROR",
            ):
                filter_file(
                    rf"^(\s*)case {enum_name}:[ \t]*$",
                    rf"\1// case {enum_name}:",
                    offload_fft_h,
                )
                filter_file(
                    rf'^(\s*)return "{enum_name}";[ \t]*$',
                    rf'\1//   return "{enum_name}";',
                    offload_fft_h,
                )

    def cmake_args(self):
        args = super().cmake_args()
        if self.spec.satisfies("+cuda"):
            cuda_arch = self.spec.variants["cuda_arch"].value[0]
            args.append(self.define("CMAKE_CUDA_ARCHITECTURES", cuda_arch))
        return args
