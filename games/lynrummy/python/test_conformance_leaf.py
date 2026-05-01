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
    can_peel, peel,
    can_pluck, pluck,
    can_yank, yank,
    can_steal, steal,
    can_split_out, split_out,
    kinds_after_splice_left, kinds_after_splice_right,
    extends_tables,
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
    """Parse a leaf DSL file. Returns a list of scenario dicts.

    Two scenario shapes:

      Single-line (most leaves):
          <verb> <token>... → <expected>            [# inline comment]
        Yields {"lineno", "raw", "verb", "args", "expected",
                "comment", "body": None}

      Multi-line block (extenders):
          <verb> <token>...                          [# header comment]
            <bucket>: <entries>                      [# inline comment]
            <bucket>: <entries>                      ...
        The block opens at a column-0 verb line WITHOUT `→`. Subsequent
        whitespace-prefixed lines are body. The block ends at the next
        column-0 line or EOF.
        Yields {"lineno", "raw", "verb", "args", "expected": None,
                "comment", "body": list of (lineno, body_line, comment)}

    Comment-only and blank lines are skipped between scenarios.
    """
    with open(path) as f:
        lines = list(enumerate(f, start=1))

    def _strip_comment(line):
        comment = ""
        if "#" in line:
            pre, _, post = line.partition("#")
            line = pre.rstrip()
            comment = post.strip()
        return line, comment

    def _is_indented(raw):
        return raw and raw[0] in " \t"

    out = []
    i = 0
    while i < len(lines):
        lineno, raw = lines[i]
        line = raw.rstrip("\n")
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue
        # Column-0 line — opens a scenario.
        if _is_indented(raw):
            # Stray indented line outside a block.
            raise ValueError(
                f"{path}:{lineno}: indented line outside a block: {raw!r}")
        body_line, comment = _strip_comment(line)
        if _ARROW in body_line:
            # Single-line scenario.
            lhs, _, rhs = body_line.partition(_ARROW)
            tokens = lhs.split()
            if not tokens:
                raise ValueError(
                    f"{path}:{lineno}: scenario has no verb: {raw!r}")
            verb, args = tokens[0], tokens[1:]
            expected = rhs.strip()
            if not expected:
                raise ValueError(
                    f"{path}:{lineno}: scenario missing expected value: {raw!r}")
            out.append({
                "lineno": lineno,
                "raw": line,
                "verb": verb,
                "args": args,
                "expected": expected,
                "comment": comment,
                "body": None,
            })
            i += 1
            continue
        # Multi-line block: header line opens it.
        tokens = body_line.split()
        if not tokens:
            raise ValueError(
                f"{path}:{lineno}: empty header line: {raw!r}")
        verb, args = tokens[0], tokens[1:]
        body = []
        i += 1
        while i < len(lines):
            blineno, braw = lines[i]
            bstripped = braw.lstrip()
            if not bstripped or bstripped.startswith("#"):
                i += 1
                continue
            if not _is_indented(braw):
                break  # next column-0 line ends the block
            bline, bcomment = _strip_comment(braw.rstrip("\n"))
            body.append((blineno, bline.strip(), bcomment))
            i += 1
        out.append({
            "lineno": lineno,
            "raw": line,
            "verb": verb,
            "args": args,
            "expected": None,
            "comment": comment,
            "body": body,
        })
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


# --- Source-side verbs (peel / pluck / yank / steal / split_out) -----
#
# Each takes (stack, position) and returns a tuple of CCS pieces. The
# DSL syntax is:
#
#     <verb> <cards>... @ <position> → <piece1_cards> | <piece2_cards> | ...
#     <verb> <cards>... @ <position> → none      (predicate returns False)
#
# `@ <int>` separates the stack from the position. The runner parses
# the LHS into (cards, position) and the RHS into a list of card-tuple
# lists, then verifies (a) the predicate matches the expected legal/
# illegal status and (b) the executor's pieces match cards exactly.


def _split_at_at(args):
    """Verbs that act on a stack at a given position use `@ <int>`
    to separate. Returns (target_tokens, position_int)."""
    if "@" not in args:
        raise ValueError(f"verb scenario missing '@': {args!r}")
    sep = args.index("@")
    target_tokens = args[:sep]
    after = args[sep + 1:]
    if len(after) != 1:
        raise ValueError(
            f"verb scenario must have exactly one position after '@', "
            f"got {after!r}")
    return target_tokens, int(after[0])


def _parse_pieces(expected):
    """Parse a `|`-separated piece list into a list of card-tuple
    lists. Each piece is whitespace-separated card labels."""
    pieces = []
    for piece in expected.split("|"):
        tokens = piece.split()
        if not tokens:
            raise ValueError(
                f"empty piece in expected: {expected!r}")
        pieces.append([parse_card_label(t) for t in tokens])
    return pieces


def _verb_target(target_tokens):
    """Classify the target stack from its label tokens. Raises if
    the target itself doesn't classify."""
    cards = [parse_card_label(t) for t in target_tokens]
    target = classify_stack(cards)
    if target is None:
        raise ValueError(
            f"verb target does not classify: {target_tokens!r}")
    return target


def _check_verb(target_tokens, position, expected,
                predicate, executor, expected_piece_count=None):
    """Common runner: predicate gates execution; executor produces
    pieces that must match cards exactly (kinds are validated
    implicitly through the existing classifier coverage).

    `expected_piece_count` (optional) sanity-checks the executor's
    return shape — e.g., peel returns 2 pieces, pluck returns 3."""
    target = _verb_target(target_tokens)
    if expected == "none":
        if predicate(target, position):
            return f"expected {predicate.__name__} false, got true"
        return None
    if not predicate(target, position):
        return f"expected {predicate.__name__} true, got false"
    pieces = executor(target, position)
    if expected_piece_count is not None and len(pieces) != expected_piece_count:
        return (f"expected {expected_piece_count} pieces, "
                f"got {len(pieces)}: {pieces}")
    actual = [list(p.cards) for p in pieces]
    expected_cards = _parse_pieces(expected)
    if actual != expected_cards:
        return f"expected pieces {expected_cards}, got {actual}"
    return None


def _run_peel(args, expected):
    target_tokens, position = _split_at_at(args)
    return _check_verb(target_tokens, position, expected,
                       can_peel, peel, expected_piece_count=2)


def _run_pluck(args, expected):
    target_tokens, position = _split_at_at(args)
    return _check_verb(target_tokens, position, expected,
                       can_pluck, pluck, expected_piece_count=3)


def _run_yank(args, expected):
    target_tokens, position = _split_at_at(args)
    return _check_verb(target_tokens, position, expected,
                       can_yank, yank, expected_piece_count=3)


def _run_steal(args, expected):
    target_tokens, position = _split_at_at(args)
    # `steal` returns 2 pieces for run/rb (extracted + pair) and 3
    # pieces for set (extracted + 2 singletons). Don't enforce a
    # fixed piece count — the executor's actual return shape gets
    # compared by `_parse_pieces`.
    return _check_verb(target_tokens, position, expected,
                       can_steal, steal)


def _run_split_out(args, expected):
    target_tokens, position = _split_at_at(args)
    return _check_verb(target_tokens, position, expected,
                       can_split_out, split_out, expected_piece_count=3)


# --- Splice probes -----------------------------------------------------
#
# Format: <verb> <target>... + <card> @ <pos> → <left_kind> | <right_kind>
# Output is a kind tuple, not a card-piece list. Use `none` when either
# half fails to classify.


def _split_splice_args(args):
    """Splice DSL: target tokens, then `+`, then card, then `@`,
    then position. Returns (target_tokens, card_token, position)."""
    if "+" not in args or "@" not in args:
        raise ValueError(f"splice scenario needs '+' and '@': {args!r}")
    plus_at = args.index("+")
    at_at = args.index("@")
    if at_at < plus_at:
        raise ValueError(f"'+' must come before '@' in splice: {args!r}")
    target_tokens = args[:plus_at]
    card_tokens = args[plus_at + 1:at_at]
    pos_tokens = args[at_at + 1:]
    if len(card_tokens) != 1 or len(pos_tokens) != 1:
        raise ValueError(f"splice scenario malformed: {args!r}")
    return target_tokens, card_tokens[0], int(pos_tokens[0])


def _parse_kind_pair(expected):
    """Splice expected output is `<left_kind> | <right_kind>`. Returns
    a (left, right) tuple of kind strings."""
    parts = [p.strip() for p in expected.split("|")]
    if len(parts) != 2:
        raise ValueError(
            f"splice expected must be `<left> | <right>`: {expected!r}")
    return tuple(parts)


def _check_splice(args, expected, probe):
    target_tokens, card_token, position = _split_splice_args(args)
    target = _verb_target(target_tokens)
    card = parse_card_label(card_token)
    result = probe(target, card, position)
    if expected == "none":
        if result is not None:
            return f"expected none, got {result}"
        return None
    if result is None:
        return f"expected {expected}, got none"
    expected_pair = _parse_kind_pair(expected)
    actual_pair = result  # already (left, right)
    if actual_pair != expected_pair:
        return f"expected {expected_pair}, got {actual_pair}"
    return None


def _run_right_splice(args, expected):
    return _check_splice(args, expected, kinds_after_splice_right)


def _run_left_splice(args, expected):
    return _check_splice(args, expected, kinds_after_splice_left)


# --- Multi-line block runner: extenders -------------------------------
#
# Header line:   extenders <target_cards>...
# Body lines:    <bucket>: <entries>
#
# Where:
#   <bucket>  is one of `left`, `right`, `set`.
#   <entries> is `-` (empty bucket) OR a comma-separated list of
#             `<card_label>=<kind>` items.
#
# Semantics: the DSL is a complete spec of the target's three
# extender dicts. Every entry the DSL lists must appear in the
# function's output, and every entry the function returns must
# appear in the DSL. Missing OR extra entries fail.


def _parse_extender_body(body):
    """Parse extenders body lines into a {bucket: dict} structure
    where each inner dict maps `(value, suit) → kind_string`."""
    expected = {"left": {}, "right": {}, "set": {}}
    seen_buckets = set()
    for lineno, line, _comment in body:
        if ":" not in line:
            raise ValueError(
                f"line {lineno}: bucket line missing ':': {line!r}")
        bucket, _, rest = line.partition(":")
        bucket = bucket.strip()
        rest = rest.strip()
        if bucket not in expected:
            raise ValueError(
                f"line {lineno}: unknown bucket {bucket!r}: must be "
                "one of left / right / set")
        if bucket in seen_buckets:
            raise ValueError(
                f"line {lineno}: bucket {bucket!r} listed twice")
        seen_buckets.add(bucket)
        if rest == "-":
            continue  # explicitly empty
        # Comma-separated entries: <card>=<kind>, <card>=<kind>, ...
        for entry in rest.split(","):
            entry = entry.strip()
            if "=" not in entry:
                raise ValueError(
                    f"line {lineno}: entry missing '=': {entry!r}")
            card_label, _, kind = entry.partition("=")
            card_label = card_label.strip()
            kind = kind.strip()
            card = parse_card_label(card_label)
            shape = (card[0], card[1])
            if shape in expected[bucket]:
                raise ValueError(
                    f"line {lineno}: duplicate shape {shape!r} in "
                    f"bucket {bucket!r}")
            expected[bucket][shape] = kind
    # Buckets not listed default to empty.
    return expected


def _run_extenders(args, body):
    target = _verb_target(args)
    expected = _parse_extender_body(body)
    actual_left, actual_right, actual_set = extends_tables(target)
    actual = {"left": actual_left, "right": actual_right, "set": actual_set}
    errors = []
    for bucket in ("left", "right", "set"):
        exp = expected[bucket]
        act = actual[bucket]
        for shape, kind in exp.items():
            if shape not in act:
                errors.append(
                    f"{bucket}: missing entry {shape}={kind}")
            elif act[shape] != kind:
                errors.append(
                    f"{bucket}: {shape} expected={kind} got={act[shape]}")
        for shape, kind in act.items():
            if shape not in exp:
                errors.append(
                    f"{bucket}: unexpected entry {shape}={kind}")
    if errors:
        return "; ".join(errors)
    return None


_RUNNERS = {
    "classify": _run_classify,
    "right_absorb": _run_right_absorb,
    "left_absorb": _run_left_absorb,
    "peel": _run_peel,
    "pluck": _run_pluck,
    "yank": _run_yank,
    "steal": _run_steal,
    "split_out": _run_split_out,
    "right_splice": _run_right_splice,
    "left_splice": _run_left_splice,
}

_RUNNERS_MULTI = {
    "extenders": _run_extenders,
}


# --- Driver ---------------------------------------------------------------

def _run_dsl(path):
    scenarios = _parse_dsl(path)
    failures = 0
    for sc in scenarios:
        verb = sc["verb"]
        lineno = sc["lineno"]
        raw_line = sc["raw"]
        comment = sc["comment"]
        if sc["body"] is None:
            runner = _RUNNERS.get(verb)
            if runner is None:
                print(f"SKIP {path}:{lineno} unknown verb {verb!r}: {raw_line}")
                continue
            try:
                err = runner(sc["args"], sc["expected"])
            except Exception as e:
                err = f"{type(e).__name__}: {e}"
                traceback.print_exc()
        else:
            runner = _RUNNERS_MULTI.get(verb)
            if runner is None:
                print(f"SKIP {path}:{lineno} unknown multi-line verb "
                      f"{verb!r}: {raw_line}")
                continue
            try:
                err = runner(sc["args"], sc["body"])
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
