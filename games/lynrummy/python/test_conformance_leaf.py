"""test_conformance_leaf.py — Conformance runner for leaf-level
BFS functions.

Each leaf has a DSL file under
`games/lynrummy/conformance/leaf/<function>.dsl` describing its
input/expected pairs. The DSLs use a compact one-line-per-scenario
syntax — every line reads as the algorithmic fact it asserts:

    classify AC 2C → pair_run        # successive same suit
    classify AC AC → none            # same card twice

The runner dispatches on the leading verb (`classify`, etc.) and
runs every scenario against the live Python implementation. Each
DSL line is self-contained and self-evident; the inline comment
serves as the scenario's name.

Goals:
  - Pin Python's leaf behavior so it can't drift silently.
  - Provide a language-agnostic spec for the upcoming TS port.
  - Keep the contract human-readable: every line in every DSL
    should be obviously true at a glance.

Run directly:
    python3 games/lynrummy/python/test_conformance_leaf.py
"""

import os
import sys
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from rules.card import card as parse_card_label
from classified_card_stack import (
    classify_stack,
    kind_after_absorb_left, kind_after_absorb_right,
)


_HERE = os.path.dirname(os.path.abspath(__file__))
_LEAF_DSL_DIR = os.path.normpath(
    os.path.join(_HERE, "..", "conformance", "leaf"))


# --- DSL parser -----------------------------------------------------------
#
# Compact one-line syntax. Each non-comment, non-blank line is a single
# scenario:
#
#   <verb> <token>... → <expected>          [# inline comment]
#
# `→` is the literal arrow separator (one Unicode code point). The
# tokens between `<verb>` and `→` are verb-specific arguments. The
# expected value is verb-specific too.

_ARROW = "→"


def _parse_dsl(path):
    """Parse a leaf DSL file. Returns a list of (line_number, raw_line,
    verb, args, expected, comment) tuples — one per scenario line.
    Comment-only and blank lines are skipped."""
    out = []
    with open(path) as f:
        for lineno, raw in enumerate(f, start=1):
            line = raw.rstrip("\n")
            stripped = line.lstrip()
            if not stripped or stripped.startswith("#"):
                continue
            # Split off any inline comment.
            comment = ""
            if "#" in line:
                pre, _, post = line.partition("#")
                line = pre.rstrip()
                comment = post.strip()
            if _ARROW not in line:
                raise ValueError(
                    f"{path}:{lineno}: scenario missing '{_ARROW}': {raw!r}")
            lhs, _, rhs = line.partition(_ARROW)
            tokens = lhs.split()
            if not tokens:
                raise ValueError(
                    f"{path}:{lineno}: scenario has no verb: {raw!r}")
            verb, args = tokens[0], tokens[1:]
            expected = rhs.strip()
            if not expected:
                raise ValueError(
                    f"{path}:{lineno}: scenario missing expected value: {raw!r}")
            out.append((lineno, raw.rstrip("\n"), verb, args, expected, comment))
    return out


# --- Per-verb runners -----------------------------------------------------

def _parse_cards(args):
    """Convert a list of card-label tokens into card tuples. The
    literal token `[]` represents an empty card list."""
    if args == ["[]"]:
        return []
    return [parse_card_label(t) for t in args]


def _run_classify(args, expected):
    cards = _parse_cards(args)
    result = classify_stack(cards)
    actual = "none" if result is None else result.kind
    if actual != expected:
        return f"expected {expected}, got {actual}"
    return None


def _split_at_plus(args):
    """Absorb DSLs use `+` to separate the target card list from
    the candidate card. Returns (target_tokens, card_token) or
    raises ValueError if the format is wrong."""
    if "+" not in args:
        raise ValueError(f"absorb scenario missing '+': {args!r}")
    sep = args.index("+")
    target_tokens = args[:sep]
    after = args[sep + 1:]
    if len(after) != 1:
        raise ValueError(
            f"absorb scenario must have exactly one card after '+', "
            f"got {after!r}")
    return target_tokens, after[0]


def _absorb_target(target_tokens):
    """Classify the target stack from its label tokens. Raises if
    the target itself is invalid — every absorb scenario presumes a
    valid target."""
    cards = [parse_card_label(t) for t in target_tokens]
    target = classify_stack(cards)
    if target is None:
        raise ValueError(
            f"absorb target does not classify: {target_tokens!r}")
    return target


def _run_right_absorb(args, expected):
    target_tokens, card_token = _split_at_plus(args)
    target = _absorb_target(target_tokens)
    card = parse_card_label(card_token)
    result_kind = kind_after_absorb_right(target, card)
    actual = "none" if result_kind is None else result_kind
    if actual != expected:
        return f"expected {expected}, got {actual}"
    return None


def _run_left_absorb(args, expected):
    target_tokens, card_token = _split_at_plus(args)
    target = _absorb_target(target_tokens)
    card = parse_card_label(card_token)
    result_kind = kind_after_absorb_left(target, card)
    actual = "none" if result_kind is None else result_kind
    if actual != expected:
        return f"expected {expected}, got {actual}"
    return None


_RUNNERS = {
    "classify": _run_classify,
    "right_absorb": _run_right_absorb,
    "left_absorb": _run_left_absorb,
}


# --- Driver ---------------------------------------------------------------

def _run_dsl(path):
    scenarios = _parse_dsl(path)
    failures = 0
    for lineno, raw_line, verb, args, expected, comment in scenarios:
        runner = _RUNNERS.get(verb)
        if runner is None:
            print(f"SKIP {path}:{lineno} unknown verb {verb!r}: {raw_line}")
            continue
        try:
            err = runner(args, expected)
        except Exception as e:
            err = f"{type(e).__name__}: {e}"
            traceback.print_exc()
        if err is not None:
            label = comment or raw_line
            print(f"FAIL {path}:{lineno} ({label}): {err}")
            failures += 1
    return len(scenarios), len(scenarios) - failures, failures


def main():
    if not os.path.isdir(_LEAF_DSL_DIR):
        print(f"no leaf-DSL dir at {_LEAF_DSL_DIR}", file=sys.stderr)
        sys.exit(1)
    paths = sorted(
        os.path.join(_LEAF_DSL_DIR, f)
        for f in os.listdir(_LEAF_DSL_DIR)
        if f.endswith(".dsl")
    )
    if not paths:
        print(f"no .dsl files in {_LEAF_DSL_DIR}", file=sys.stderr)
        sys.exit(1)

    grand_total = 0
    grand_passed = 0
    grand_failed = 0
    for path in paths:
        total, passed, failed = _run_dsl(path)
        grand_total += total
        grand_passed += passed
        grand_failed += failed
        name = os.path.basename(path)
        if failed:
            print(f"  {name}: {passed}/{total} passed ({failed} failed)")
        else:
            print(f"  {name}: {total}/{total} passed")

    print()
    print(f"{grand_passed}/{grand_total} leaf conformance scenarios passed")
    if grand_failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
