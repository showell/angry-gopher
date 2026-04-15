#!/usr/bin/env python3
"""Measure the weight of a feature by grep pattern(s).

Usage:
    tools/feature_weight.py <pattern> [<pattern> ...]

A feature is identified by one or more regex patterns (OR'd together).
The tool walks the repo and reports:

  * Matching lines            — direct weight (pattern hits)
  * File-LOC                  — blast radius (lines in files that hit)
  * Breakdown by kind         — prod / test / cmd / docs / sidecar
  * Files                     — list with per-file match + LOC counts
  * Routes registered         — mux.HandleFunc lines referencing pattern
  * DB tables defined         — CREATE TABLE statements matching

Example:
    tools/feature_weight.py 'buddies|buddy|HandleBuddies'
    tools/feature_weight.py 'muted_users' 'muted_topics'
"""
import os
import re
import sys
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Dirs to skip entirely.
SKIP_DIRS = {".git", "node_modules", "__pycache__", "elm-stuff"}

# Files to skip (large generated artifacts, binaries).
SKIP_FILE_RE = re.compile(r"(\.pyc|\.swp|elm\.js|\.db|\.sqlite)$")


def kind_of(path):
    """Classify a file path into one of: prod | test | cmd | docs | sidecar | other."""
    rel = os.path.relpath(path, REPO)
    if rel.endswith(".claude"):
        return "sidecar"
    if rel.endswith(".md"):
        return "docs"
    if rel.startswith("cmd/") and rel.endswith(".go"):
        return "cmd"
    if rel.endswith("_test.go"):
        return "test"
    if rel.endswith(".go"):
        return "prod"
    return "other"


def walk_files():
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if SKIP_FILE_RE.search(f):
                continue
            path = os.path.join(root, f)
            k = kind_of(path)
            if k == "other":
                continue
            yield path, k


def main(patterns):
    big_re = re.compile("|".join(f"(?:{p})" for p in patterns))
    route_re = re.compile(r"mux\.HandleFunc\s*\(")
    table_re = re.compile(r"CREATE TABLE[^(]*\b(\w+)\b")

    files_by_kind = defaultdict(list)
    total_matches = 0
    total_file_loc = 0
    routes = []
    tables = []

    for path, kind in walk_files():
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
        except Exception:
            continue

        hit_lines = [ln for ln in lines if big_re.search(ln)]
        if not hit_lines:
            continue

        file_loc = len(lines)
        n_match = len(hit_lines)
        total_matches += n_match
        total_file_loc += file_loc
        files_by_kind[kind].append((path, n_match, file_loc))

        # Routes registered in this file that reference the pattern.
        for ln in lines:
            if route_re.search(ln) and big_re.search(ln):
                routes.append((path, ln.strip()))

        # CREATE TABLE statements matching the pattern.
        for m in table_re.finditer("".join(lines)):
            name = m.group(1)
            if big_re.search(name):
                tables.append(name)

    # --- Report ---
    print(f"Patterns: {patterns}")
    print(f"Total matching lines (direct weight):   {total_matches}")
    print(f"Total file-LOC (blast radius):          {total_file_loc}")
    print()
    print("Breakdown by kind:")
    for kind in ("prod", "test", "cmd", "docs", "sidecar"):
        entries = files_by_kind.get(kind, [])
        if not entries:
            continue
        nfiles = len(entries)
        loc = sum(e[2] for e in entries)
        hits = sum(e[1] for e in entries)
        print(f"  {kind:8s} files={nfiles:3d}  matches={hits:4d}  file-LOC={loc:5d}")
    print()
    print(f"DB tables matching: {sorted(set(tables)) or '—'}")
    print(f"Routes matching:    {len(routes)}")
    for path, ln in routes[:10]:
        rel = os.path.relpath(path, REPO)
        print(f"  {rel}: {ln}")
    if len(routes) > 10:
        print(f"  ... and {len(routes) - 10} more")
    print()
    print("Files (sorted by file-LOC, top 20):")
    all_files = [(p, m, l, k) for k, es in files_by_kind.items() for (p, m, l) in es]
    all_files.sort(key=lambda x: -x[2])
    for path, nmatch, floc, kind in all_files[:20]:
        rel = os.path.relpath(path, REPO)
        print(f"  [{kind:7s}] matches={nmatch:3d} loc={floc:4d}  {rel}")
    if len(all_files) > 20:
        print(f"  ... and {len(all_files) - 20} more files")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    main(sys.argv[1:])
