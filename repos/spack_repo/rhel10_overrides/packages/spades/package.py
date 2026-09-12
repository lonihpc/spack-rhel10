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

    # Two real spades 4.0.0 upstream source bugs - both plain typos, not
    # compiler-specific behavior. Neither ever got compiled before because
    # C++ template member functions are only instantiated when actually
    # used, and apparently nothing exercised these two particular methods
    # under whatever toolchain upstream tests with; building with icpx/a
    # newer libstdc++ here instantiates them, exposing the bugs:
    #
    # 1. src/common/kmer_index/ph_map/key_with_hash.hpp:
    #    SimpleKeyWithHash::operator== references `this->is_minimal_`, but
    #    `is_minimal_` is a member of a DIFFERENT class in the same file
    #    (InvertableKeyWithHash, further down) - SimpleKeyWithHash has no
    #    such member at all. Fix: drop the bogus comparison term.
    # 2. src/common/adt/flat_set.hpp:
    #    flat_set::swap() does `data_.swap(other.data)` - the underlying
    #    container member is named `data_` (with the trailing underscore,
    #    used correctly on the left-hand side), so `other.data` is a plain
    #    typo for `other.data_`.
    # 3. ext/src/lexy/include/lexy/input_location.hpp (bundled lexy
    #    library, not spades' own code): input_location::operator< does
    #    `lhs._column_nr < rhs._colum_nr` - every other use of this member
    #    in the file (including two lines above) spells it `_column_nr`;
    #    `_colum_nr` (missing the second "n") is a typo for the same
    #    member, not a different one.
    @run_before("cmake")
    def fix_upstream_source_typos(self):
        key_with_hash = os.path.join(
            self.stage.source_path,
            "src",
            "common",
            "kmer_index",
            "ph_map",
            "key_with_hash.hpp",
        )
        filter_file(
            r"this->idx_ == that.idx_ && this->is_minimal_ == that.is_minimal_",
            "this->idx_ == that.idx_",
            key_with_hash,
        )

        flat_set = os.path.join(self.stage.source_path, "src", "common", "adt", "flat_set.hpp")
        filter_file(
            r"data_\.swap\(other\.data\)",
            "data_.swap(other.data_)",
            flat_set,
        )

        input_location = os.path.join(
            self.stage.source_path,
            "ext",
            "src",
            "lexy",
            "include",
            "lexy",
            "input_location.hpp",
        )
        filter_file(
            r"rhs\._colum_nr",
            "rhs._column_nr",
            input_location,
        )
