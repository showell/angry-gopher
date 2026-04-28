#!/usr/bin/env python3
"""Measure the weight of a feature by grep pattern(s).

Usage:
    tools/feature_weight.py [OPTIONS] PATTERN [PATTERN ...]

A feature is identified by one or more regex patterns (OR'd together).
The underlying mechanism is grep: walk the repo, match lines, count.

OPTIONS
    --exclude REGEX     Skip files whose relative path matches REGEX.
                        Repeatable. Typical use: drop vendored or mirrored
                        code (--exclude 'elm-').
    --focus-threshold PCT
                        A file is OWNED_BY_CONTENT if its focus ratio
                        (matching-lines / file-LOC) meets this bar.
                        Default: 10.
    -h, --help          Show this help.

CLASSIFICATION
    OWNED_BY_PATH       The relative path itself matches the pattern.
                        These files are definitionally part of the
                        feature, regardless of content density.
    OWNED_BY_CONTENT    Focus ratio >= --focus-threshold%.
    REFERENCING         Has matches but neither of the above — a file
                        that mentions the feature but isn't primarily
                        about it.

    "Delete candidates" = OWNED_BY_PATH ∪ OWNED_BY_CONTENT.
    "Scrub candidates"  = REFERENCING.

EXAMPLES
    tools/feature_weight.py 'github|webhook|linkifier' --exclude 'elm-'
    tools/feature_weight.py 'channels?\\b|HandleChannels|topic' --focus-threshold 15
"""
import os
import re
import sys
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKIP_DIRS = {".git", "node_modules", "__pycache__", "elm-stuff"}
SKIP_FILE_RE = re.compile(r"(\.pyc|\.swp|elm\.js|\.db|\.sqlite)$")

OWN_PATH, OWN_CONTENT, REFED = "path", "content", "ref"


def kind_of(path):
    rel = os.path.relpath(path, REPO)
    if rel.endswith(".md"):
        return "docs"
    if rel.startswith("cmd/") and rel.endswith(".go"):
        return "cmd"
    if rel.endswith("_test.go"):
        return "test"
    if rel.endswith(".go"):
        return "prod"
    return "other"


def walk_files(exclude_res):
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if SKIP_FILE_RE.search(f):
                continue
            path = os.path.join(root, f)
            rel = os.path.relpath(path, REPO)
            if any(r.search(rel) for r in exclude_res):
                continue
            k = kind_of(path)
            if k == "other":
                continue
            yield path, rel, k


def parse_args(argv):
    patterns, excludes = [], []
    focus_threshold = 10.0
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--exclude" and i + 1 < len(argv):
            excludes.append(argv[i + 1])
            i += 2
        elif a == "--focus-threshold" and i + 1 < len(argv):
            focus_threshold = float(argv[i + 1])
            i += 2
        elif a in ("-h", "--help"):
            print(__doc__)
            sys.exit(0)
        else:
            patterns.append(a)
            i += 1
    if not patterns:
        print(__doc__)
        sys.exit(1)
    return patterns, excludes, focus_threshold


def classify(rel, focus, path_re, focus_threshold):
    if path_re.search(rel):
        return OWN_PATH
    if focus >= focus_threshold:
        return OWN_CONTENT
    return REFED


def main(argv):
    patterns, excludes, focus_threshold = parse_args(argv)
    big_re = re.compile("|".join(f"(?:{p})" for p in patterns))
    exclude_res = [re.compile(p) for p in excludes]
    route_re = re.compile(r"mux\.HandleFunc\s*\(")
    table_re = re.compile(r"CREATE TABLE[^(]*\b(\w+)\b")

    rows = []  # (rel, kind, matches, loc, focus, own_class)
    routes = []
    tables = set()

    for path, rel, kind in walk_files(exclude_res):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                lines = fh.readlines()
        except Exception:
            continue

        hit_lines = [ln for ln in lines if big_re.search(ln)]
        path_matched = bool(big_re.search(rel))
        if not hit_lines and not path_matched:
            continue

        floc = len(lines)
        nmatch = len(hit_lines)
        focus = (nmatch / floc) * 100 if floc else 0.0
        own = classify(rel, focus, big_re, focus_threshold)
        rows.append((rel, kind, nmatch, floc, focus, own))

        for ln in lines:
            if route_re.search(ln) and big_re.search(ln):
                routes.append((rel, ln.strip()))
        for m in table_re.finditer("".join(lines)):
            name = m.group(1)
            if big_re.search(name):
                tables.add(name)

    # --- Partitions ---
    owned_path = [r for r in rows if r[5] == OWN_PATH]
    owned_content = [r for r in rows if r[5] == OWN_CONTENT]
    refed = [r for r in rows if r[5] == REFED]
    owned_all = owned_path + owned_content

    total_matches = sum(r[2] for r in rows)
    owned_loc = sum(r[3] for r in owned_all)
    refed_loc = sum(r[3] for r in refed)
    owned_matches = sum(r[2] for r in owned_all)
    refed_matches = sum(r[2] for r in refed)

    # --- Report ---
    def hr(ch="─", n=72):
        print(ch * n)

    print(f"Patterns:         {patterns}")
    if excludes:
        print(f"Excludes:         {excludes}")
    print(f"Focus threshold:  {focus_threshold:.1f}%   (content-owned cutoff)")
    hr("═")
    print(f"{'Direct weight':20s}: {total_matches:5d} matching lines across {len(rows)} files")
    print(
        f"{'Delete candidates':20s}: {len(owned_all):3d} files  "
        f"{owned_loc:5d} LOC  ({owned_matches} matches)"
    )
    print(
        f"  by path match        {len(owned_path):3d} files  "
        f"{sum(r[3] for r in owned_path):5d} LOC"
    )
    print(
        f"  by content density   {len(owned_content):3d} files  "
        f"{sum(r[3] for r in owned_content):5d} LOC  (focus >= {focus_threshold:.0f}%)"
    )
    print(
        f"{'Scrub candidates':20s}: {len(refed):3d} files  "
        f"{refed_loc:5d} LOC  ({refed_matches} matches)"
    )
    hr()

    # Breakdown by kind
    by_kind = defaultdict(lambda: [0, 0, 0])
    for rel, kind, nmatch, floc, focus, own in rows:
        by_kind[kind][0] += 1
        by_kind[kind][1] += nmatch
        by_kind[kind][2] += floc
    print("By kind:")
    for k in ("prod", "test", "cmd", "docs"):
        if k not in by_kind:
            continue
        f, m, l = by_kind[k]
        print(f"  {k:8s} files={f:3d}  matches={m:4d}  LOC={l:5d}")
    hr()

    # DB + routes
    if tables:
        print(f"DB tables matching: {sorted(tables)}")
    else:
        print("DB tables matching: —")
    print(f"Routes matching:    {len(routes)}")
    for rel, ln in routes[:10]:
        print(f"  {rel}: {ln}")
    if len(routes) > 10:
        print(f"  ... and {len(routes) - 10} more")
    hr()

    # Delete candidates (sorted: path first, then content by focus desc)
    print("Delete candidates (owned files; `rm` these):")
    if not owned_all:
        print("  — none —")
    else:
        owned_path_sorted = sorted(owned_path, key=lambda r: (-r[3], r[0]))
        owned_content_sorted = sorted(owned_content, key=lambda r: -r[4])
        for rel, kind, nmatch, floc, focus, _ in owned_path_sorted:
            print(f"  [path   {kind:7s}] loc={floc:4d} matches={nmatch:3d} focus={focus:5.1f}%  {rel}")
        for rel, kind, nmatch, floc, focus, _ in owned_content_sorted:
            print(f"  [content {kind:7s}] loc={floc:4d} matches={nmatch:3d} focus={focus:5.1f}%  {rel}")
    hr()

    # Top scrub candidates
    print("Top scrub candidates (files to edit, not delete; ranked by matches):")
    ref_sorted = sorted(refed, key=lambda r: -r[2])
    for rel, kind, nmatch, floc, focus, _ in ref_sorted[:15]:
        print(f"  [{kind:7s}] loc={floc:4d} matches={nmatch:3d} focus={focus:5.1f}%  {rel}")
    if len(ref_sorted) > 15:
        print(f"  ... and {len(ref_sorted) - 15} more")


if __name__ == "__main__":
    main(sys.argv[1:])
