#!/usr/bin/env python3
"""parity_check — compare exported names between twin Go / Elm modules.

Catches structural drift (renames, new exports on one side only,
removed exports) at near-zero cost. Does NOT catch semantic drift;
that's what conformance fixtures are for.

Module pairing is explicit below — update MODULE_PAIRS when a new
module is added to either side.

Usage:
  parity_check.py            Check all pairs.
  parity_check.py card       Check one pair by name.
"""

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

GO_ROOT = Path("/home/steve/showell_repos/angry-gopher/lynrummy")
ELM_ROOT = Path("/home/steve/showell_repos/angry-gopher/elm-lynrummy/src/LynRummy")

MODULE_PAIRS = [
    ("card",           "card.go",           "Card.elm"),
    ("stack_type",     "stack_type.go",     "StackType.elm"),
    ("card_stack",     "card_stack.go",     "CardStack.elm"),
    ("board_geometry", "board_geometry.go", "BoardGeometry.elm"),
    ("referee",        "referee.go",        "Referee.elm"),
]
# Modules with no twin yet (flagged but not failing):
GO_ONLY = ["events.go", "dealer.go"]
ELM_ONLY = ["Random.elm"]


def go_exports(path: Path) -> set[str]:
    """Exported identifiers: type, func, const, var starting with uppercase.

    Handles method receivers: `func (s CardStack) LeftMerge(...)` →
    contributes `LeftMerge`.
    """
    names: set[str] = set()
    if not path.exists():
        return names
    text = path.read_text()

    # Top-level type/const/var/func Name.
    for m in re.finditer(
        r"^(?:type|const|var|func)\s+([A-Z]\w*)", text, re.MULTILINE
    ):
        names.add(m.group(1))

    # Method: `func (recv Recv) Name(`.
    for m in re.finditer(
        r"^func\s+\([^)]+\)\s+([A-Z]\w*)\s*\(", text, re.MULTILINE
    ):
        names.add(m.group(1))

    # Grouped const blocks:  const ( Name Type = ... )
    for block in re.finditer(
        r"^(?:const|var)\s*\((.*?)^\)", text, re.MULTILINE | re.DOTALL
    ):
        for m in re.finditer(r"^\s*([A-Z]\w*)\b", block.group(1), re.MULTILINE):
            names.add(m.group(1))

    return names


def elm_exports(path: Path) -> set[str]:
    """Names inside the `module X exposing (...)` header.

    Strips `(..)` suffixes on type-with-variants exposures and
    normalizes whitespace.
    """
    names: set[str] = set()
    if not path.exists():
        return names
    text = path.read_text()

    m = re.search(r"module\s+\S+\s+exposing\s*\(", text, re.DOTALL)
    if not m:
        return names

    # Balanced-paren read from the opening '(' through the matching ')'.
    start = m.end() - 1
    depth = 0
    end = start
    for i in range(start, len(text)):
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                end = i
                break
    raw = text[start + 1:end]

    # Strip `(..)` or `(Tag1, Tag2)` attached to type names.
    raw = re.sub(r"\([^)]*\)", "", raw)

    for part in raw.split(","):
        name = part.strip()
        if name:
            names.add(name)

    return names


def norm(n: str) -> str:
    """Case-fold + snake→camel collapse for comparison."""
    return n.lower().replace("_", "")


def load_ignore() -> dict:
    try:
        import parity_ignore
        return parity_ignore.IGNORE
    except ImportError:
        return {}


def compare(label: str, go_path: Path, elm_path: Path, ignore: dict) -> bool:
    go_names = go_exports(go_path)
    elm_names = elm_exports(elm_path)

    mod_ignore = ignore.get(label, {})
    ignored_go = {norm(n) for n in mod_ignore.get("go_only", [])}
    ignored_elm = {norm(n) for n in mod_ignore.get("elm_only", [])}

    go_norm = {norm(n): n for n in go_names if norm(n) not in ignored_go}
    elm_norm = {norm(n): n for n in elm_names if norm(n) not in ignored_elm}

    only_go = sorted(go_norm[k] for k in go_norm.keys() - elm_norm.keys())
    only_elm = sorted(elm_norm[k] for k in elm_norm.keys() - go_norm.keys())
    shared = sorted(go_norm[k] for k in go_norm.keys() & elm_norm.keys())

    ok = not only_go and not only_elm
    mark = "OK" if ok else "DRIFT"
    print(f"=== {label}  [{mark}]")
    print(f"    {go_path.relative_to(GO_ROOT.parent)}  ↔  "
          f"{elm_path.relative_to(ELM_ROOT.parent)}")
    print(f"    shared: {len(shared)}")
    if only_go:
        print(f"    Go only ({len(only_go)}): {', '.join(only_go)}")
    if only_elm:
        print(f"    Elm only ({len(only_elm)}): {', '.join(only_elm)}")
    return ok


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.strip())
    p.add_argument("module", nargs="?", help="Module name to check (omit for all)")
    args = p.parse_args()

    pairs = MODULE_PAIRS
    if args.module:
        pairs = [x for x in MODULE_PAIRS if x[0] == args.module]
        if not pairs:
            sys.exit(f"unknown module: {args.module} "
                     f"(known: {', '.join(p[0] for p in MODULE_PAIRS)})")

    ignore = load_ignore()
    all_ok = True
    for label, go_name, elm_name in pairs:
        ok = compare(label, GO_ROOT / go_name, ELM_ROOT / elm_name, ignore)
        all_ok = all_ok and ok
        print()

    if not args.module:
        unpaired_notes = []
        if GO_ONLY:
            unpaired_notes.append(f"Go-only modules: {', '.join(GO_ONLY)}")
        if ELM_ONLY:
            unpaired_notes.append(f"Elm-only modules: {', '.join(ELM_ONLY)}")
        if unpaired_notes:
            print("Unpaired modules (no twin yet):")
            for n in unpaired_notes:
                print(f"  {n}")

    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
