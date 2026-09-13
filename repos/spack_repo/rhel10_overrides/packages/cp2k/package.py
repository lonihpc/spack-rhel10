# Site override of the builtin `cp2k` package for the RHEL10 cluster.
#
# Real bug in Spack's own cp2k recipe (not our config, not the compiler
# choice): its CMakeBuilder.cmake_args() only passes CP2K's own
# `-DCP2K_WITH_GPU=<name>` variable (e.g. "A100") when +cuda, and never
# sets the standard CMake `CMAKE_CUDA_ARCHITECTURES`. CMakePackage's
# `enable_language(CUDA)` runs its own compiler-ABI probe *before*
# CP2K_WITH_GPU is ever translated into an actual architecture by CP2K's
# own CMakeLists.txt - and that probe defaults to CMake's built-in
# fallback architecture, compute_60 (Pascal). CUDA 13.3 has dropped
# support for compute_60 entirely, so the probe itself fails outright:
#   nvcc fatal : Unsupported gpu architecture 'compute_60'
# completely independent of cuda_arch=80 being perfectly valid - the
# probe never gets that far. This is a real, version-drift bug in the
# recipe (CUDA keeps raising its minimum supported architecture; cp2k's
# recipe never accounted for CMake's own pre-CP2K-logic ABI check needing
# CMAKE_CUDA_ARCHITECTURES set up front).
#
# Fix: reuse builtin's CMakeBuilder.cmake_args() in full (not a fork) and
# just append CMAKE_CUDA_ARCHITECTURES from the same cuda_arch variant
# CP2K_WITH_GPU already derives from, so CMake's ABI probe uses the real
# target architecture instead of falling back to compute_60.
#
# Spack's builder dispatch (spack.builder.get_builder_class) walks the
# package class's MRO and uses the first ancestor whose OWN module
# defines a class named after the buildsystem's builder (here
# "CMakeBuilder") - so defining both Cp2k and CMakeBuilder here, in the
# same module, is what makes this override's CMakeBuilder take effect
# instead of builtin's.
from spack_repo.builtin.packages.cp2k.package import Cp2k as BuiltinCp2k
from spack_repo.builtin.packages.cp2k.package import CMakeBuilder as BuiltinCMakeBuilder

from spack.package import *


class Cp2k(BuiltinCp2k):
    pass


class CMakeBuilder(BuiltinCMakeBuilder):
    def cmake_args(self):
        args = super().cmake_args()
        if self.spec.satisfies("+cuda"):
            cuda_arch = self.spec.variants["cuda_arch"].value[0]
            args.append(self.define("CMAKE_CUDA_ARCHITECTURES", cuda_arch))
        return args
