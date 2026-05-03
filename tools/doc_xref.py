#!/usr/bin/env python3
"""tools/doc_xref.py — heuristic drift detector for Markdown docs.

Catches the most common kind of doc-rot: references to files or symbols
that no longer exist in the repo. Not a type-checker — a fast linter
for the failure modes documented in the random240 + random241 audits.

What it checks per doc:

  1. Relative markdown links `[text](path)` — target file must exist.
     Misses: anchors-into-existing-file, links to external URLs.

  2. Backtick paths `src/foo.ts`, `python/SOLVER.md`, etc. (heuristic:
     contains a `/` and ends in a known extension) — file must exist.
     Misses: paths styled outside backticks; multi-line paths.

  3. (--strict only) Backtick identifiers `function_name`, `Foo.bar`
     — at least one `git grep` hit somewhere in the repo. Identifiers
     too short, too common, or styled as keywords are filtered out.
     Misses: identifiers from external libraries/stdlib.

What it CANNOT check:
  - Status claims ("X is on life-support") — semantic, not syntactic.
  - Behavioral claims ("BFS does X first") — needs reading code.
  - Count claims ("214/214 leaf scenarios") — needs running tests.
  - Aspirational/stale TODOs — needs human judgement.

Usage:
    tools/doc_xref.py games/lynrummy/ARCHITECTURE.md
    tools/doc_xref.py --all
    tools/doc_xref.py --all --strict     # adds the identifier check
    tools/doc_xref.py --all --quiet      # only summarize

Exit code: 0 if no drift hits, 1 if any hits (suitable for CI).

Surfaced as IFs in random240.md (orphan analysis) and random241.md
(claim verification). Shared theme: catching a fictional path or
symbol in seconds instead of by hand-grep.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterable

REPO = Path(__file__).resolve().parents[1]

EXTENSIONS = (
    "py", "ts", "tsx", "elm", "go", "md", "json", "txt",
    "dsl", "html", "css", "sh", "toml", "yml", "yaml", "jsonl",
)

# Backtick-wrapped path: contains `/` and ends with a known extension.
# Allow one optional trailing `:line` suffix (e.g., `bfs.py:323`).
PATH_RE = re.compile(
    r"`([./A-Za-z0-9_\-]+/[A-Za-z0-9_./\-]+\.(?:" + "|".join(EXTENSIONS) + r"))(?::\d+)?`"
)

# Markdown link: [text](target). Targets that are URLs / mailto / pure
# anchors (#foo) are skipped at resolution time.
LINK_RE = re.compile(r"\[(?:[^\]]+)\]\(([^)\s]+)\)")

# Backtick identifier (only used in --strict). Heuristic:
# letters/underscores, optional dotted segments, len ≥ 4 to cut noise.
IDENT_RE = re.compile(r"`([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)`")

# Identifiers we never flag — too short or common to be drift-safe.
IDENT_DENYLIST = {
    "True", "False", "None", "null", "true", "false", "self", "this",
    "init", "main", "test", "Test", "List", "Maybe", "Result",
    "string", "int", "bool", "void", "any",
}

# Doc roots scanned in --all mode.
DOC_ROOTS = ["games/lynrummy"]
EXCLUDE_DIRS = {".git", "node_modules", "elm-stuff", "__pycache__", "data"}


def find_docs(roots: Iterable[str]) -> list[Path]:
    out: list[Path] = []
    for root in roots:
        base = REPO / root
        for p in base.rglob("*.md"):
            if any(part in EXCLUDE_DIRS for part in p.parts):
                continue
            out.append(p)
    return sorted(out)


def is_external(target: str) -> bool:
    return target.startswith(("http://", "https://", "mailto:", "ftp://"))


def is_anchor_only(target: str) -> bool:
    return target.startswith("#") or target == ""


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def check_link(doc: Path, target: str) -> bool:
    """Resolve a markdown link target relative to the doc; return True
    if it resolves to an existing file (or known-good anchor target).
    External URLs, anchors, and tilde paths are treated as out-of-scope."""
    target = target.split("#", 1)[0]
    if not target or is_external(target) or target.startswith("~"):
        return True
    if target.startswith("/"):
        candidate = REPO / target.lstrip("/")
    else:
        candidate = (doc.parent / target).resolve()
    return candidate.exists()


# Path prefixes that live outside this repo and should be considered
# out-of-scope for verification (we treat them as legitimate even if
# they don't exist on this machine).
EXTERNAL_PATH_PREFIXES = (
    "memory/",                   # ~/.claude/projects/.../memory/
    "claude-steve/",             # sibling essay repo
    "claude-collab/",            # sibling collab repo
    "/tmp/",                     # runtime artifacts
    "~/",                        # home-relative
)

# Substrings indicating a gitignored runtime path, anywhere in the
# string. Examples: ".claude/plan-state.json" (per-session state),
# "node_modules/...", "__pycache__/...".
EXTERNAL_PATH_SUBSTRINGS = (
    "/.claude/",
    "node_modules/",
    "__pycache__/",
    "elm-stuff/",
)


def is_external_path(path_str: str) -> bool:
    if path_str.startswith(EXTERNAL_PATH_PREFIXES):
        return True
    if any(s in path_str for s in EXTERNAL_PATH_SUBSTRINGS):
        return True
    if path_str.startswith("/"):
        try:
            return not Path(path_str).resolve().is_relative_to(REPO)
        except (ValueError, OSError):
            return True
    return False


def check_path(path_str: str) -> bool:
    """Return True if the backticked path resolves somewhere in the repo.
    External paths (memory/, claude-steve/, /tmp/, etc.) short-circuit
    to True. Otherwise tries (a) relative to repo root, (b) git-tracked
    file ending in the basename. Forgiving on purpose — we want to flag
    fictional paths, not paths-with-different-anchors."""
    if is_external_path(path_str):
        return True
    p = path_str.lstrip("./")
    if p.startswith("/"):
        # Absolute under REPO (already filtered by is_external_path).
        return Path(p).exists()
    if (REPO / p).exists():
        return True
    # Fall back to git-tracked file lookup
    try:
        res = subprocess.run(
            ["git", "-C", str(REPO), "ls-files", "*" + Path(p).name],
            capture_output=True, text=True, timeout=10, check=False,
        )
        for f in res.stdout.splitlines():
            if f == p or f.endswith("/" + p) or f.endswith(p):
                return True
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return False


def check_identifier(ident: str) -> bool:
    """Return True if the identifier appears at least once in any
    git-tracked file in the repo. Used by --strict only."""
    if len(ident.replace(".", "")) < 4:
        return True  # too short to be drift-meaningful
    if ident in IDENT_DENYLIST:
        return True
    # `git grep -q -F` — fixed-string, quiet, exit 0 if any match.
    try:
        res = subprocess.run(
            ["git", "-C", str(REPO), "grep", "-q", "-F", ident],
            capture_output=True, timeout=10, check=False,
        )
        return res.returncode == 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return True  # don't flag on tool failure


def audit_doc(doc: Path, strict: bool = False) -> list[tuple[int, str, str]]:
    text = doc.read_text(encoding="utf-8", errors="replace")
    hits: list[tuple[int, str, str]] = []

    seen_paths: set[str] = set()

    for m in LINK_RE.finditer(text):
        target = m.group(1)
        if is_external(target) or is_anchor_only(target):
            continue
        if not check_link(doc, target):
            hits.append((line_of(text, m.start()), "broken_link", target))

    for m in PATH_RE.finditer(text):
        path_str = m.group(1)
        if path_str in seen_paths:
            continue
        seen_paths.add(path_str)
        if not check_path(path_str):
            hits.append((line_of(text, m.start()), "missing_path", path_str))

    if strict:
        seen_idents: set[str] = set()
        for m in IDENT_RE.finditer(text):
            ident = m.group(1)
            if ident in seen_idents:
                continue
            # Skip if the ident is a substring of a path already flagged
            # (avoid double-reporting the same drift)
            if any(ident in p for _, kind, p in hits if kind == "missing_path"):
                continue
            seen_idents.add(ident)
            if not check_identifier(ident):
                hits.append((line_of(text, m.start()), "missing_ident", ident))

    hits.sort(key=lambda h: (h[0], h[1]))
    return hits


def report(doc: Path, hits: list[tuple[int, str, str]], quiet: bool) -> None:
    rel = doc.relative_to(REPO)
    if not hits:
        if not quiet:
            print(f"{rel}: clean")
        return
    for line, kind, payload in hits:
        print(f"{rel}:{line}: {kind} | {payload}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    ap.add_argument("doc", nargs="?", help="path to a single .md doc")
    ap.add_argument("--all", action="store_true",
                    help=f"scan every .md under {DOC_ROOTS}")
    ap.add_argument("--strict", action="store_true",
                    help="also flag backtick identifiers with zero git-grep hits")
    ap.add_argument("--quiet", action="store_true",
                    help="suppress per-doc 'clean' lines")
    args = ap.parse_args()

    if args.all:
        docs = find_docs(DOC_ROOTS)
    elif args.doc:
        docs = [Path(args.doc).resolve()]
    else:
        ap.error("provide a doc path or --all")
        return 2

    total_hits = 0
    docs_with_hits = 0
    for doc in docs:
        hits = audit_doc(doc, strict=args.strict)
        if hits:
            docs_with_hits += 1
            total_hits += len(hits)
        report(doc, hits, quiet=args.quiet)

    if args.all or args.quiet:
        kind_label = "ident+path+link" if args.strict else "path+link"
        print(f"---", file=sys.stderr)
        print(f"summary: {total_hits} drift hits across {docs_with_hits}/{len(docs)} docs ({kind_label})",
              file=sys.stderr)
    return 0 if total_hits == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
