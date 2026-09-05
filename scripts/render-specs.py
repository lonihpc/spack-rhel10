#!/usr/bin/env python3
"""Render config/specs.yaml into the specs: block of every environment's
spack.yaml, so the target software list has one source of truth even
though Spack's own `include:` mechanism can't share a `specs:` list.

Usage:
    python3 scripts/render-specs.py [--check]

--check exits non-zero (without writing) if any target file would change -
useful for CI/pre-commit to catch a hand-edited spack.yaml that drifted
from config/specs.yaml.

How it works: everything from the "specs:" line to the end of
config/specs.yaml is treated as an opaque text block (not parsed as YAML -
re-serializing would risk reformatting comments/style), indented by 2
spaces, and spliced into each target spack.yaml between a pair of
"BEGIN/END GENERATED SPECS" marker comments. Content outside the markers
in each spack.yaml is left untouched.
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SPECS_SOURCE = REPO_ROOT / "config" / "specs.yaml"
TARGET_FILES = [
    REPO_ROOT / "environments" / "dev-local" / "spack.yaml",
    REPO_ROOT / "environments" / "production" / "spack.yaml",
]

BEGIN_MARKER = "  # >>> BEGIN GENERATED SPECS (from config/specs.yaml - do not edit by hand)"
END_MARKER = "  # <<< END GENERATED SPECS"
INDENT = "  "


def load_specs_block() -> str:
    """Return the `specs:` line and everything after it, indented by 2
    spaces to nest under spack.yaml's top-level `spack:` key."""
    text = SPECS_SOURCE.read_text()
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line == "specs:":
            block_lines = lines[i:]
            break
    else:
        raise SystemExit(f"{SPECS_SOURCE}: could not find a 'specs:' line")

    # Drop trailing blank lines so we control exactly one trailing newline.
    while block_lines and block_lines[-1].strip() == "":
        block_lines.pop()

    indented = [INDENT + line if line else line for line in block_lines]
    return "\n".join(indented) + "\n"


def render_target(path: Path, specs_block: str) -> bool:
    """Splice specs_block between the markers in `path`. Returns True if
    the file's content changed."""
    original = path.read_text()
    lines = original.splitlines(keepends=True)

    try:
        begin_idx = next(i for i, l in enumerate(lines) if l.rstrip("\n") == BEGIN_MARKER)
        end_idx = next(i for i, l in enumerate(lines) if l.rstrip("\n") == END_MARKER)
    except StopIteration:
        raise SystemExit(
            f"{path}: missing BEGIN/END GENERATED SPECS markers - "
            "add them once by hand, then re-run this script."
        )
    if end_idx <= begin_idx:
        raise SystemExit(f"{path}: END marker appears before BEGIN marker")

    new_lines = lines[: begin_idx + 1] + [specs_block] + lines[end_idx:]
    new_content = "".join(new_lines)

    if new_content != original:
        path.write_text(new_content)
        return True
    return False


def main() -> int:
    check_only = "--check" in sys.argv[1:]
    specs_block = load_specs_block()

    changed_any = False
    for target in TARGET_FILES:
        if check_only:
            original = target.read_text()
            # Dry-run: render into a copy in memory by reusing render logic
            # against a temp check without writing.
            lines = original.splitlines(keepends=True)
            begin_idx = next(
                (i for i, l in enumerate(lines) if l.rstrip("\n") == BEGIN_MARKER), None
            )
            end_idx = next(
                (i for i, l in enumerate(lines) if l.rstrip("\n") == END_MARKER), None
            )
            if begin_idx is None or end_idx is None or end_idx <= begin_idx:
                print(f"MISSING MARKERS: {target}")
                changed_any = True
                continue
            new_content = "".join(lines[: begin_idx + 1] + [specs_block] + lines[end_idx:])
            if new_content != original:
                print(f"OUT OF DATE: {target}")
                changed_any = True
            else:
                print(f"up to date:  {target}")
        else:
            if render_target(target, specs_block):
                print(f"updated:     {target}")
                changed_any = True
            else:
                print(f"unchanged:   {target}")

    if check_only and changed_any:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
