# Site override of the builtin `revbayes` package.
#
# revbayes@1.2.2's src/CMakeLists.txt does
#     find_package(Boost 1.71.0 COMPONENTS regex program_options thread
#                  system filesystem date_time serialization REQUIRED)
# Boost.System has been header-only since Boost 1.69, but up to 1.88 Boost
# still shipped a stub `boost_system` library plus its CMake package config,
# so asking for the `system` component kept working. Boost 1.89 removed the
# stub (and boost_system-config.cmake) entirely. With the boost@1.90.0 this
# Spack/builtin repo now picks, BoostConfig.cmake can't find a matching
# boost_system config in the Spack prefix, falls through to the host's
# /usr/lib64/cmake/boost_system-1.83.0, rejects it on version, and cmake
# fails ~5 s into the build:
#     Could not find a configuration file for package "boost_system" that
#     exactly matches requested version "1.90.0".
# (db job 13, 2026-11-22; QB4's tier3 built revbayes fine back in September
# because the builtin repo still resolved an older boost then.)
#
# revbayes only uses Boost.System through headers
# (src/libs/tensorphylo/Loader.cpp: #include <boost/system/error_code.hpp>),
# and no CMakeLists links Boost::system / Boost_SYSTEM_LIBRARY explicitly, so
# simply dropping `system` from the COMPONENTS list is the whole fix - the
# same change upstream projects made for Boost 1.89. Only applied when the
# concretized boost is 1.89+, so older boosts see the untouched file.
#
# Subclasses the builtin package (inherits every directive); revbayes has no
# separate Builder class, so a package-level @run_before hook is merged into
# the build (see the cp2k override for the case where that is NOT true).
from spack_repo.builtin.packages.revbayes.package import Revbayes as BuiltinRevbayes

from spack.package import *


class Revbayes(BuiltinRevbayes):
    @run_before("cmake")
    def drop_header_only_boost_system_component(self):
        if self.spec.version <= Version("1.0.13"):
            return  # old layout (projects/cmake), not this CMakeLists.txt
        if not self.spec["boost"].satisfies("@1.89:"):
            return
        # The component list has one name per line; `system` stands alone.
        filter_file(r"^\s*system\s*$", "", join_path("src", "CMakeLists.txt"))
