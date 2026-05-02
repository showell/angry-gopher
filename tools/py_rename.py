"""
py_rename — batch Python-identifier renamer.

Reads a script of `OLD -> NEW` directives and applies
word-boundary regex substitutions across .py files in a
target directory tree. Dry-run by default; --execute to
commit. After execute, runs the project's regression tests.

Modeled on `cmd/reorg` (the Go/Elm batch mover) but scoped
to identifier renames within Python source. Not a code-aware
refactor — just word-boundary substitution. Good enough for
underscore strips, type-alias adoption, and similar
mechanical passes; not appropriate for moves that change
semantics.

Usage:
  python3 tools/py_rename.py SCRIPT --root games/lynrummy/python
  python3 tools/py_rename.py SCRIPT --root games/lynrummy/python --execute
  python3 tools/py_rename.py SCRIPT --root games/lynrummy/python --execute --verify

Script syntax (one directive per line, # comments allowed):

  # Drop the underscore prefix from a load-bearing helper.
  _admissible_partial -> admissible_partial
  _completion_inventory -> completion_inventory

  # Rename across the codebase.
  RANKS -> RANK_NAMES

Dry-run prints every file + every site that would change.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path


def parse_script(script_path):
    """Returns list of (old, new) tuples. Comments and blank
    lines ignored."""
    directives = []
    for raw in Path(script_path).read_text().splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if "->" not in line:
            sys.exit(f"bad directive (no `->`): {raw!r}")
        old, new = [s.strip() for s in line.split("->", 1)]
        if not old or not new:
            sys.exit(f"empty old/new in directive: {raw!r}")
        directives.append((old, new))
    return directives


def find_py_files(root):
    return sorted(p for p in Path(root).rglob("*.py")
                  if "__pycache__" not in p.parts)


def apply_directive(text, old, new):
    """Word-boundary substitution. Returns (new_text, n_subs)."""
    pattern = r"\b" + re.escape(old) + r"\b"
    new_text, n = re.subn(pattern, new, text)
    return new_text, n


def process_file(path, directives, execute):
    """Returns (n_changes, per_directive_counts)."""
    original = path.read_text()
    text = original
    counts = {}
    for old, new in directives:
        text, n = apply_directive(text, old, new)
        if n:
            counts[(old, new)] = n
    if not counts:
        return 0, counts
    if execute:
        path.write_text(text)
    return sum(counts.values()), counts


def run_verify(verify_cmds, root):
    print("\n--- verifying ---")
    for cmd in verify_cmds:
        print(f"$ {cmd}")
        result = subprocess.run(
            cmd, shell=True, cwd=root, capture_output=True,
            text=True)
        # Print last line of each (which usually has the
        # PASS/FAIL summary).
        out = (result.stdout + result.stderr).strip().splitlines()
        if out:
            print(f"  {out[-1]}")
        if result.returncode != 0:
            print(f"  EXIT {result.returncode} — STOPPING")
            return False
    return True


DEFAULT_VERIFY_CMDS = [
    "python3 test_bfs_extract.py",
    "python3 test_bfs_enumerate.py",
    "python3 test_bfs_failure.py",
    "python3 test_verbs.py",
    "python3 test_agent_prelude.py",
    "python3 test_plan_merge_hand.py",
    "python3 test_follow_up_merges.py",
    "python3 test_gesture_synth.py",
]


def main():
    ap = argparse.ArgumentParser(
        description="Word-boundary identifier renamer.")
    ap.add_argument("script", help="rename script file")
    ap.add_argument("--root", required=True,
                    help="directory to walk for .py files")
    ap.add_argument("--execute", action="store_true",
                    help="apply changes (default: dry-run)")
    ap.add_argument("--verify", action="store_true",
                    help="after --execute, run regression tests")
    args = ap.parse_args()

    directives = parse_script(args.script)
    print(f"loaded {len(directives)} directive(s) from "
          f"{args.script}")
    files = find_py_files(args.root)
    print(f"scanning {len(files)} .py file(s) under {args.root}")

    total = 0
    affected_files = 0
    per_directive_total = {d: 0 for d in directives}

    for path in files:
        n, counts = process_file(path, directives, args.execute)
        if n:
            total += n
            affected_files += 1
            rel = path.relative_to(args.root)
            print(f"  {rel}: {n} site(s)")
            for (old, new), c in counts.items():
                print(f"    {old} -> {new}  ×{c}")
                per_directive_total[(old, new)] += c

    print(f"\n{'EXECUTED' if args.execute else 'DRY-RUN'}: "
          f"{total} change(s) across {affected_files} file(s)")
    print("\nper-directive totals:")
    for (old, new), c in per_directive_total.items():
        marker = "" if c else "  (no matches)"
        print(f"  {old} -> {new}: {c}{marker}")

    if args.execute and args.verify:
        ok = run_verify(DEFAULT_VERIFY_CMDS, args.root)
        if not ok:
            sys.exit(1)


if __name__ == "__main__":
    main()
