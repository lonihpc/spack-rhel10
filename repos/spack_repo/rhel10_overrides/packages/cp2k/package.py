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
import os

from spack_repo.builtin.packages.cp2k.package import Cp2k as BuiltinCp2k
from spack_repo.builtin.packages.cp2k.package import CMakeBuilder as BuiltinCMakeBuilder

from spack.package import *


class Cp2k(BuiltinCp2k):
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


class CMakeBuilder(BuiltinCMakeBuilder):
    def cmake_args(self):
        args = super().cmake_args()
        if self.spec.satisfies("+cuda"):
            cuda_arch = self.spec.variants["cuda_arch"].value[0]
            args.append(self.define("CMAKE_CUDA_ARCHITECTURES", cuda_arch))
        return args
