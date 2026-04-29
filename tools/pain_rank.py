#!/usr/bin/env python3
"""pain_rank — rank source files by a composite pain score.

Combines several cheap quantitative proxies for "file is probably
annoying to work in":

  - size           :  total lines (signal: tangled concerns)
  - todo_count     :  TODO/FIXME/HACK/XXX markers (self-labeled pain)
  - churn          :  commits touching the file (bug magnet or edge)
  - err_density    :  `if err != nil` lines / total lines (Go only)
  - escape_density :  `html.EscapeString` / similar calls (boilerplate)

Each metric is rank-normalized across files (0..1), then combined
as a weighted sum. Higher composite = more painful.

Usage:
  tools/pain_rank.py                      # rank all source files in .
  tools/pain_rank.py --repo /path/to/repo # specify repo root explicitly
  tools/pain_rank.py --top 20             # show top 20
  tools/pain_rank.py --weights size=2,todo=3  # override weights

Filters: generated files (per header), vendored, .min.js, tests.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

# File extensions we consider "source" for pain purposes.
SOURCE_EXTS = {".go", ".py", ".ts", ".elm", ".js"}

# Skip these directories entirely.
SKIP_DIRS = {
    ".git",
    "node_modules",
    "elm-stuff",
    "__pycache__",
    "vendor",
    "third_party",
}

# Skip files matching any of these patterns.
SKIP_BASENAME_RE = re.compile(r"(\.min\.(js|css)|\.pb\.go|^elm\.js$)")

GENERATED_MARKER_RE = re.compile(
    r"GENERATED.*DO NOT EDIT"           # standard generated-file header
    r"|^\(function\(scope\)\{"          # Elm-compiled JS bundle
    r"|^/\*\* @license\b",              # minified/compiled JS preamble
    re.IGNORECASE,
)

TODO_RE = re.compile(r"\b(?:TODO|FIXME|HACK|XXX)\b")
ERR_RE = re.compile(r"^\s*if err != nil\s*\{")
ESCAPE_RE = re.compile(r"html\.EscapeString|EscapeString\s*\(")


# --- Metric collectors ---


def is_generated(path: Path) -> bool:
    """Skip files whose first few lines announce themselves as generated."""
    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            head = "".join(f.readline() for _ in range(5))
    except OSError:
        return False
    return bool(GENERATED_MARKER_RE.search(head))


def is_test_file(path: Path) -> bool:
    """Tests are a distinct category; pain there is different."""
    name = path.name
    return (
        name.endswith("_test.go")
        or name.endswith("Test.elm")
        or name.endswith("_test.ts")
        or "/tests/" in str(path)
        or "/test/" in str(path)
    )


def file_metrics(path: Path) -> dict:
    """Return the raw metric values for one file."""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    lines = text.splitlines()
    size = len(lines)
    todo = len(TODO_RE.findall(text))
    err = sum(1 for l in lines if ERR_RE.match(l))
    escape = len(ESCAPE_RE.findall(text))
    return {
        "size": size,
        "todo_count": todo,
        "err_density": err / size if size else 0.0,
        "escape_density": escape / size if size else 0.0,
    }


def churn_counts(files: list[Path], repo_root: Path) -> dict[Path, int]:
    """Git-log churn per file. Single invocation for speed."""
    try:
        out = subprocess.check_output(
            ["git", "log", "--format=", "--name-only"],
            cwd=repo_root,
            text=True,
        )
    except subprocess.CalledProcessError:
        return {f: 0 for f in files}
    counts: dict[str, int] = {}
    for raw in out.splitlines():
        raw = raw.strip()
        if raw:
            counts[raw] = counts.get(raw, 0) + 1
    return {
        f: counts.get(str(f.relative_to(repo_root)), 0)
        for f in files
    }


# --- Ranking ---


def rank_normalize(values: list[float]) -> list[float]:
    """Convert a list of floats to 0..1 by rank. Ties share midrank."""
    n = len(values)
    if n == 0:
        return []
    indexed = sorted(enumerate(values), key=lambda pair: pair[1])
    ranks = [0.0] * n
    i = 0
    while i < n:
        j = i
        while j + 1 < n and indexed[j + 1][1] == indexed[i][1]:
            j += 1
        midrank = (i + j) / 2.0
        for k in range(i, j + 1):
            ranks[indexed[k][0]] = midrank
        i = j + 1
    return [r / max(1, n - 1) for r in ranks]


DEFAULT_WEIGHTS = {
    "size": 1.0,
    "todo_count": 2.0,
    "churn": 0.5,
    "err_density": 1.0,
    "escape_density": 0.5,
}


def parse_weights(spec: str) -> dict[str, float]:
    """--weights size=2,todo=3 syntax."""
    w = dict(DEFAULT_WEIGHTS)
    if not spec:
        return w
    for piece in spec.split(","):
        key, _, val = piece.partition("=")
        key = key.strip()
        if key == "todo":
            key = "todo_count"
        if key not in DEFAULT_WEIGHTS:
            sys.exit(f"unknown metric: {key!r} (known: {list(DEFAULT_WEIGHTS)})")
        w[key] = float(val)
    return w


# --- Discovery ---


def iter_source_files(repo_root: Path) -> list[Path]:
    out: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(repo_root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if SKIP_BASENAME_RE.search(name):
                continue
            path = Path(dirpath) / name
            if path.suffix not in SOURCE_EXTS:
                continue
            if is_generated(path):
                continue
            out.append(path)
    return out


# --- Main ---


def adjacency_churn(repo_root: Path, max_commit_size: int = 15) -> list[tuple[tuple[str, str], int]]:
    """File pairs that change together in small commits.

    Skips commits that touched > max_commit_size files — those are
    usually refactors / imports / license bumps, not features.
    Small-commit adjacency is the specific "I changed 11 files for
    a trivial feature" signal.

    Returns sorted list of ((fileA, fileB), count), highest first.
    """
    out = subprocess.check_output(
        ["git", "log", "--format=---%n%H", "--name-only"],
        cwd=repo_root,
        text=True,
    )
    pairs: dict[tuple[str, str], int] = {}
    commits = out.split("---\n")
    for commit in commits:
        lines = [l for l in commit.strip().splitlines() if l]
        if len(lines) < 2:
            continue
        # First line is the hash; remainder are filenames.
        files = sorted(lines[1:])
        if len(files) < 2 or len(files) > max_commit_size:
            continue
        for i in range(len(files)):
            for j in range(i + 1, len(files)):
                key = (files[i], files[j])
                pairs[key] = pairs.get(key, 0) + 1
    return sorted(pairs.items(), key=lambda kv: kv[1], reverse=True)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--repo", default=".", help="path to repo root (default: .)")
    p.add_argument("--top", type=int, default=15, help="how many files to show")
    p.add_argument("--weights", default="", help="override default metric weights")
    p.add_argument("--include-tests", action="store_true")
    p.add_argument("--verbose", action="store_true", help="show per-metric breakdown")
    p.add_argument(
        "--adjacency",
        action="store_true",
        help="instead of per-file ranking, show file pairs that change together",
    )
    p.add_argument(
        "--max-commit-size",
        type=int,
        default=15,
        help="ignore commits touching more than this many files (default 15)",
    )
    args = p.parse_args()

    repo_root = Path(args.repo).resolve()

    if args.adjacency:
        pairs = adjacency_churn(repo_root, args.max_commit_size)
        print(
            f"Top {args.top} file pairs by small-commit adjacency"
            f" (max {args.max_commit_size} files/commit)\n"
        )
        print(f"{'count':>5}  pair")
        print("-" * 80)
        for (a, b), count in pairs[: args.top]:
            print(f"{count:5d}  {a}\n       {b}\n")
        return

    weights = parse_weights(args.weights)

    files = iter_source_files(repo_root)
    if not args.include_tests:
        files = [f for f in files if not is_test_file(f)]

    has_go = any(f.suffix == ".go" for f in files)

    per_file = [(f, file_metrics(f)) for f in files]
    per_file = [(f, m) for f, m in per_file if m]  # drop unreadable
    churn = churn_counts([f for f, _ in per_file], repo_root)

    # Collect raw metric vectors, rank-normalize, composite.
    metric_names = ["size", "todo_count", "churn", "err_density", "escape_density"]
    if not has_go:
        metric_names = [k for k in metric_names if k not in ("err_density", "escape_density")]
    raw: dict[str, list[float]] = {k: [] for k in metric_names}
    for f, m in per_file:
        raw["size"].append(m["size"])
        raw["todo_count"].append(m["todo_count"])
        raw["churn"].append(churn.get(f, 0))
        if has_go:
            raw["err_density"].append(m["err_density"])
        raw["escape_density"].append(m["escape_density"])

    normalized = {k: rank_normalize(v) for k, v in raw.items()}

    scored = []
    for i, (f, m) in enumerate(per_file):
        composite = sum(
            weights[k] * normalized[k][i] for k in metric_names
        )
        scored.append((composite, f, m, {k: normalized[k][i] for k in metric_names}, churn.get(f, 0)))

    scored.sort(key=lambda row: row[0], reverse=True)

    print(f"Top {args.top} painful files (composite rank-normalized score, higher = more painful)\n")
    if has_go:
        print(f"{'score':>6}  {'lines':>5}  {'churn':>5}  {'TODO':>4}  {'err':>4}  path")
    else:
        print(f"{'score':>6}  {'lines':>5}  {'churn':>5}  {'TODO':>4}  path")
    print("-" * 80)
    for composite, f, m, _, ch in scored[: args.top]:
        rel = f.relative_to(repo_root)
        if has_go:
            print(
                f"{composite:6.2f}  {m['size']:5d}  {ch:5d}  {m['todo_count']:4d}  "
                f"{int(m['err_density'] * m['size']):4d}  {rel}"
            )
        else:
            print(
                f"{composite:6.2f}  {m['size']:5d}  {ch:5d}  {m['todo_count']:4d}  {rel}"
            )

    if args.verbose:
        print("\n--- per-metric normalized breakdown (top N) ---")
        for composite, f, _, norms, _ in scored[: args.top]:
            rel = f.relative_to(repo_root)
            print(f"\n{rel} (composite={composite:.2f})")
            for k in metric_names:
                print(f"  {k:18}  {norms[k]:.2f}  (w={weights[k]})")


if __name__ == "__main__":
    main()
