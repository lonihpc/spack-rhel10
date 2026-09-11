# Site override of the builtin `python` package for the RHEL10 cluster.
#
# CPython 3.11+'s configure unconditionally tries to build every optional
# stdlib extension module (including _tkinter) and only drops the ones
# that fail at build/link time - or, for _tkinter specifically, ones that
# link successfully but then crash at runtime with "undefined symbol:
# Tcl_ListObjGetElements" during the `make install` self-test, because
# this cluster's system Tcl is 9.0 and CPython's _tkinter glue has known
# incomplete support for the Tcl 9 ABI
# (https://github.com/python/cpython/issues/104363). There is no
# configure-time flag or packages.yaml variant/env-var combination that
# reliably prevents this - the only clean fix is telling `Modules/
# makesetup` (which generates the build's Makefile from the Modules/
# Setup* files) to skip _tkinter entirely, via Modules/Setup.local, before
# `make` runs.
#
# This subclasses the builtin Python package (not a full copy) so it
# inherits all its versions/variants/dependencies/directives unchanged -
# Spack's directive metaclass (spack.directives_meta.DirectiveMeta)
# explicitly re-applies a base class's registered directives to any
# subclass, so this is the supported way to add a small site-specific
# hook without forking the whole ~1400-line recipe. Only takes effect
# because this repo is listed ahead of `builtin` in repos.yaml (see
# config/repos.yaml) - Spack resolves the unqualified `python` package
# name to whichever repo has priority.
import os

from spack_repo.builtin.packages.python.package import Python as BuiltinPython

from spack.package import *


class Python(BuiltinPython):
    @run_before("build")
    def disable_tkinter_module(self):
        setup_local = os.path.join(self.stage.source_path, "Modules", "Setup.local")
        with open(setup_local, "w") as f:
            f.write("*disabled*\n_tkinter\n")
