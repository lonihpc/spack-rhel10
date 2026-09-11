# Site override of the builtin `spades` package for the RHEL10 cluster.
#
# spades 4.0.0 bundles a pre-fix snapshot of microsoft/mimalloc. Its
# vendored ext/src/mimalloc/CMakeLists.txt has:
#   if(CMAKE_CXX_COMPILER_ID MATCHES "Intel")
#     list(APPEND mi_cflags -Kc++)
#   endif()
# "Intel" also matches CMake's "IntelLLVM" compiler ID (icx/icpx), so this
# unconditionally appends -Kc++ (a classic icc-only flag) to the oneAPI
# build too - icpx doesn't understand it and aborts with "unknown
# argument: '-Kc++'" while compiling ext/mimalloc's static.c. Upstream
# mimalloc later fixed this exact bug by excluding IntelLLVM:
#   if(CMAKE_CXX_COMPILER_ID MATCHES "Intel" AND NOT CMAKE_CXX_COMPILER_ID
#      MATCHES "IntelLLVM")
# but spades 4.0.0's bundled copy predates that fix, and Spack's own
# `spades` recipe doesn't patch around it. This subclasses the builtin
# Spades package (see repos/spack_repo/rhel10_overrides/packages/python/
# package.py for why subclassing - not a full recipe fork - is the
# supported way to add a small site-specific hook) and applies the same
# fix upstream mimalloc made, via filter_file before cmake configures.
import os

from spack_repo.builtin.packages.spades.package import Spades as BuiltinSpades

from spack.package import *


class Spades(BuiltinSpades):
    @run_before("cmake")
    def fix_mimalloc_intelllvm_kcxx_flag(self):
        cmakelists = os.path.join(
            self.stage.source_path, "ext", "src", "mimalloc", "CMakeLists.txt"
        )
        filter_file(
            r'if\(CMAKE_CXX_COMPILER_ID MATCHES "Intel"\)',
            'if(CMAKE_CXX_COMPILER_ID MATCHES "Intel" '
            'AND NOT CMAKE_CXX_COMPILER_ID MATCHES "IntelLLVM")',
            cmakelists,
        )
