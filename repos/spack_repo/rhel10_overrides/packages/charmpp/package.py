# Site override of the builtin `charmpp` package for the RHEL10 cluster.
#
# Real, compiler-independent upstream bug (reproduced identically with
# both %nvhpc and %gcc as the host compiler - it's not compiler-specific
# at all): src/conv-core/converse.h defines its own `memory_order` enum
# to support C11 atomics on compilers/libcs that predate <stdatomic.h>,
# guarded by:
#   #if __GNUC__ && __STDC_VERSION__ >= 201112L && !__STDC_NO_ATOMICS__
#   #ifndef _STDATOMIC_H
#   typedef enum { memory_order_relaxed = ..., ... } memory_order;
#   #endif
# GCC's own freestanding <stdatomic.h> (gcc/ginclude/stdatomic.h) uses
# exactly the same guard macro name (_STDATOMIC_H) - so the names do
# match - but converse.h never DEFINES _STDATOMIC_H itself after
# providing its own equivalent definition. If converse.h is processed
# first (before anything else in the same translation unit actually
# `#include <stdatomic.h>`), its own memory_order gets defined but
# _STDATOMIC_H is still unset - so a later real `#include <stdatomic.h>`
# (pulled in transitively, e.g. via a system header) sees no guard, badly
# redefines every enumerator, and the build fails with "redeclaration of
# enumerator 'memory_order_relaxed'" etc. This is charmpp's own missing
# `#define _STDATOMIC_H` after its typedef, not a toolchain issue.
import os

from spack_repo.builtin.packages.charmpp.package import Charmpp as BuiltinCharmpp

from spack.package import *


class Charmpp(BuiltinCharmpp):
    @run_before("install")
    def fix_missing_stdatomic_guard(self):
        converse_h = os.path.join(
            self.stage.source_path, "src", "conv-core", "converse.h"
        )
        filter_file(
            r"(\}\s*memory_order;)",
            r"\1\n#define _STDATOMIC_H",
            converse_h,
        )
