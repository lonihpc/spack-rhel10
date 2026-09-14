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
# enumerator 'memory_order_relaxed'" etc.
#
# FIRST FIX ATTEMPT (reverted): just adding `#define _STDATOMIC_H` after
# converse.h's own typedef. This backfired on a real build: it makes any
# LATER real `#include <stdatomic.h>` (e.g. transitively via
# /usr/include/lustre/lustreapi.h, pulled in while building charmpp's IO
# library - this cluster's /project is Lustre-backed) see the guard
# already set and skip its entire body - not just memory_order, but every
# other C11 atomic type it defines (atomic_int, atomic_bool, etc.), which
# lustreapi.h then needs and doesn't get: "unknown type name 'atomic_int'".
# Our patch only ever intended to provide memory_order, but claiming the
# _STDATOMIC_H guard implicitly claimed to provide the *entire* header.
#
# REAL FIX: since this compiler/libc combination provides a real, correct
# <stdatomic.h> (confirmed identical enum values to converse.h's own
# hand-typed copy), stop hand-typing memory_order at all - #include the
# real header instead, and disable (not delete, to keep the file
# otherwise intact - filter_file operates line-by-line, so precisely
# deleting a multi-line block reliably isn't straightforward) converse.h's
# own typedef via `#if 0`. filter_file only needs to target the opening
# `#ifndef _STDATOMIC_H` line, which is unique in the file - inserting
# `#include <stdatomic.h>` immediately before it (still inside the outer
# `#if __GNUC__ && ... C11 ...` guard, so it only fires when C11 atomics
# are actually available, matching upstream's original intent) and
# turning the `#ifndef` into `#if 0` so the old hand-typed enum becomes
# dead code the preprocessor skips entirely, including whatever's inside
# it (like the reverted attempt's `#define _STDATOMIC_H`, which the
# earlier fix put there and is now itself dead code once the enclosing
# block is disabled).
import os

from spack_repo.builtin.packages.charmpp.package import Charmpp as BuiltinCharmpp

from spack.package import *


class Charmpp(BuiltinCharmpp):
    @run_before("install")
    def fix_stdatomic_conflict(self):
        converse_h = os.path.join(
            self.stage.source_path, "src", "conv-core", "converse.h"
        )
        filter_file(
            r"#ifndef _STDATOMIC_H",
            "#include <stdatomic.h>\n"
            "#if 0 /* memory_order now provided by <stdatomic.h> included "
            "above instead - see rhel10_overrides/packages/charmpp/package.py */",
            converse_h,
        )
