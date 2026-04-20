#!/usr/bin/env python3
"""sidecar_audit — detect drift between source files and their
.claude sidecar companions.

Two checks:

  1. **Coverage**: every source file (*.go / *.py / *.elm, excluding
     tests and obvious generated caches) has a sibling .claude file.
     Missing sidecars are the single biggest silent-drift risk
     — they let new code accumulate without domain notes.

  2. **just_use target**: every .claude file's `just_use <filename>`
     header points at a file that actually exists next to it.
     Catches sidecars orphaned by renames / removals of the code
     they were documenting.

Run directly:

    python3 tools/sidecar_audit.py

Exits 0 if clean; 1 if any drift is found. Safe to wire into a
pre-commit hook.
"""

import sys
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent

# Source-file globs that must have a sidecar companion. Tests are
# intentionally excluded (many test files document themselves with
# a top-of-file docstring and a sidecar is overkill).
SOURCE_PATTERNS = [
    ("*.go",  lambda p: not p.name.endswith("_test.go")),
    ("*.py",  lambda p: not p.name.startswith("test_")),
    ("*.elm", lambda p: not p.name.endswith("Test.elm")),
]

EXCLUDE_DIRS = {
    ".git", "node_modules", "elm-stuff", "vendor",
    "__pycache__", ".cache", "dist", "build",
}

# Known exceptions: files that legitimately have no sidecar.
# Small, documented list so exclusions are visible.
EXEMPT_FILES = {
    # Python test runners are self-describing via module docstring.
    "tools/lynrummy_elm_player/test_hints_invariant.py",
    "tools/lynrummy_elm_player/test_dsl_conformance.py",
    # apply_labels.py is a sibling tool script with module docstring.
    # It HAS a sidecar, but listed here so its absence wouldn't flag.
}


def iter_source_files():
    for pattern, filt in SOURCE_PATTERNS:
        for path in REPO.rglob(pattern):
            if any(part in EXCLUDE_DIRS for part in path.parts):
                continue
            if not filt(path):
                continue
            yield path


def sidecar_for(path: Path) -> Path:
    return path.with_suffix(".claude")


def check_coverage():
    """Return list of source files that lack a sidecar."""
    missing = []
    for src in iter_source_files():
        rel = src.relative_to(REPO).as_posix()
        if rel in EXEMPT_FILES:
            continue
        if not sidecar_for(src).exists():
            missing.append(rel)
    return sorted(missing)


def check_just_use():
    """Return list of .claude files whose `just_use <x>` header
    points at a missing sibling. Sidecars without the header
    (doc-style .claude files) are skipped."""
    broken = []
    for claude_path in REPO.rglob("*.claude"):
        if any(part in EXCLUDE_DIRS for part in claude_path.parts):
            continue
        first = ""
        try:
            with claude_path.open() as f:
                for line in f:
                    line = line.strip()
                    if line:
                        first = line
                        break
        except OSError:
            continue
        if not first.startswith("just_use "):
            continue
        target = first[len("just_use "):].strip()
        if not target:
            continue
        sibling = claude_path.parent / target
        if not sibling.exists():
            broken.append(
                f"{claude_path.relative_to(REPO).as_posix()} → {target}"
            )
    return sorted(broken)


def main():
    missing = check_coverage()
    broken = check_just_use()

    if missing:
        print(f"Source files without a sidecar ({len(missing)}):")
        for f in missing:
            print(f"  - {f}")
        print()

    if broken:
        print(f"Sidecars with broken just_use targets ({len(broken)}):")
        for f in broken:
            print(f"  - {f}")
        print()

    if not missing and not broken:
        print("sidecar_audit: clean")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
