"""
py_regex_rename — batch regex substitution across .py files.

Sibling to `py_rename.py`. Where py_rename does
word-boundary identifier substitution (good for renames
like `_foo -> foo`), this tool takes full Python regex
patterns with capture groups, suitable for transforms like
`desc["foo"] -> desc.foo` or
`desc["type"] == "foo" -> isinstance(desc, FooDesc)`.

Usage:
  python3 tools/py_regex_rename.py SCRIPT --root path/to/dir
  python3 tools/py_regex_rename.py SCRIPT --root path/to/dir --execute
  python3 tools/py_regex_rename.py SCRIPT --root path/to/dir --execute --verify

Script syntax:

  # Lines starting with # are comments. Blank lines ignored.
  # Each directive is two lines:
  #   PATTERN: <python regex>
  #   REPLACE: <replacement template (\\1, \\2 etc. for groups)>
  # OR a one-line form:
  #   re: PATTERN >>> REPLACE

  re: desc\\["loose"\\] >>> desc.loose
  re: desc\\["target_before"\\] >>> desc.target_before

The two-line form is preferred when patterns contain `>>>`
or other tricky chars. Use `\\` to escape regex metacharacters.

After --execute, --verify runs the regression suite (matching
py_rename's set).
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path


def parse_script(script_path):
    """Returns list of (compiled_pattern, replace_str, raw_pattern_str)."""
    directives = []
    pending_pattern = None
    for raw in Path(script_path).read_text().splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if line.startswith("re: "):
            body = line[len("re: "):]
            if ">>>" not in body:
                sys.exit(f"bad re: directive (no >>>): {raw!r}")
            patt, repl = body.split(">>>", 1)
            patt = patt.strip()
            repl = repl.strip()
            try:
                compiled = re.compile(patt)
            except re.error as e:
                sys.exit(f"bad regex {patt!r}: {e}")
            directives.append((compiled, repl, patt))
        elif line.startswith("PATTERN:"):
            pending_pattern = line[len("PATTERN:"):].strip()
        elif line.startswith("REPLACE:"):
            if pending_pattern is None:
                sys.exit(f"REPLACE without preceding PATTERN: {raw!r}")
            patt = pending_pattern
            repl = line[len("REPLACE:"):].strip()
            try:
                compiled = re.compile(patt)
            except re.error as e:
                sys.exit(f"bad regex {patt!r}: {e}")
            directives.append((compiled, repl, patt))
            pending_pattern = None
        else:
            sys.exit(f"unrecognized directive line: {raw!r}")
    if pending_pattern is not None:
        sys.exit("dangling PATTERN with no REPLACE")
    return directives


def find_py_files(root):
    return sorted(p for p in Path(root).rglob("*.py")
                  if "__pycache__" not in p.parts)


def process_file(path, directives, execute):
    original = path.read_text()
    text = original
    counts = {}
    for compiled, repl, patt_str in directives:
        text, n = compiled.subn(repl, text)
        if n:
            counts[patt_str] = n
    if not counts:
        return 0, counts
    if execute:
        path.write_text(text)
    return sum(counts.values()), counts


DEFAULT_VERIFY_CMDS = [
    "python3 test_bfs_extract.py",
    "python3 test_bfs_enumerate.py",
    "python3 test_bfs_failure.py",
    "python3 test_verbs.py",
    "python3 test_dsl_conformance.py",
    "python3 test_agent_prelude.py",
    "python3 test_plan_merge_hand.py",
    "python3 test_follow_up_merges.py",
    "python3 test_gesture_synth.py",
]


def run_verify(verify_cmds, root):
    print("\n--- verifying ---")
    for cmd in verify_cmds:
        print(f"$ {cmd}")
        result = subprocess.run(
            cmd, shell=True, cwd=root, capture_output=True,
            text=True)
        out = (result.stdout + result.stderr).strip().splitlines()
        if out:
            print(f"  {out[-1]}")
        if result.returncode != 0:
            print(f"  EXIT {result.returncode} — STOPPING")
            return False
    return True


def main():
    ap = argparse.ArgumentParser(
        description="Regex-driven batch substitution across .py files.")
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
    per_directive_total = {patt_str: 0
                           for _, _, patt_str in directives}

    for path in files:
        n, counts = process_file(path, directives, args.execute)
        if n:
            total += n
            affected_files += 1
            rel = path.relative_to(args.root)
            print(f"  {rel}: {n} site(s)")
            for patt_str, c in counts.items():
                print(f"    {patt_str}  ×{c}")
                per_directive_total[patt_str] += c

    print(f"\n{'EXECUTED' if args.execute else 'DRY-RUN'}: "
          f"{total} change(s) across {affected_files} file(s)")
    print("\nper-directive totals:")
    for patt_str, c in per_directive_total.items():
        marker = "" if c else "  (no matches)"
        print(f"  {patt_str}: {c}{marker}")

    if args.execute and args.verify:
        ok = run_verify(DEFAULT_VERIFY_CMDS, args.root)
        if not ok:
            sys.exit(1)


if __name__ == "__main__":
    main()
