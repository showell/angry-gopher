"""
rules/stack_type.py — Stack classification + rule predicates.

The Python equivalent of `Game.Rules.StackType.elm`. Holds
the value-cycle helpers (`successor`), the classification
oracle (`classify`), and the pure rule predicates
(`is_partial_ok`, `neighbors`) that determine what counts
as a legal group on the LynRummy board.

Class-1: game rules. These encode the laws of LynRummy and
are not expected to change.

The Elm precedent kept these in a single `StackType` module
because the rule predicates consult the classifier; the same
coupling holds here. (Elm-side predicates were lifted out of
the now-removed `Game.Agent.Cards` module into
`Game.Rules.StackType` on 2026-04-28; the Python parallel
landed shortly after.)
"""

import functools

from rules.card import RED, color


# --- Card value cycle ---

def successor(v):
    return 1 if v == 13 else v + 1


# --- Classification ---

def classify(stack):
    """Single-pass classifier for length-3+ stacks. Early
    exits on the first impossibility. Inlines successor and the
    red-set membership check to avoid call overhead — this
    is the hottest function in the search.

    Thin wrapper that hashes the (mutable list-of-tuples) stack
    into an immutable tuple key and delegates to the cached
    implementation. Pure function: cached results are equivalent
    to live results."""
    return _classify_cached(tuple(stack))


# maxsize=2**14 (16384) is a principled bound: large enough to
# hold all unique stacks seen during a single corpus run
# (~thousands of distinct stacks across 21 puzzles) without
# evicting, while still bounding memory for long-running
# processes (agent_game.py self-play). Profile evidence:
# ~192k classify calls per dominator puzzle, but the unique
# stack-content cardinality is tiny by comparison.
@functools.lru_cache(maxsize=2**14)
def _classify_cached(stack):
    n = len(stack)
    if n < 3:
        return "other"
    a0v, a0s, _ = stack[0]
    a1v, a1s, _ = stack[1]

    # Set: same value, distinct suits.
    if a0v == a1v:
        if a0s == a1s:
            return "other"
        seen_suits = {a0s, a1s}
        for i in range(2, n):
            cv, cs, _ = stack[i]
            if cv != a0v or cs in seen_suits:
                return "other"
            seen_suits.add(cs)
        return "set"

    # Run: consecutive values starting a0v → a1v.
    expected = 1 if a0v == 13 else a0v + 1
    if a1v != expected:
        return "other"

    if a0s == a1s:
        # Pure-run candidate: same suit throughout.
        prev_v = a1v
        for i in range(2, n):
            cv, cs, _ = stack[i]
            expected = 1 if prev_v == 13 else prev_v + 1
            if cv != expected or cs != a0s:
                return "other"
            prev_v = cv
        return "pure_run"

    # RB-run candidate: alternating colors.
    a0_red = a0s in RED
    a1_red = a1s in RED
    if a0_red == a1_red:
        return "other"
    prev_v = a1v
    prev_red = a1_red
    for i in range(2, n):
        cv, cs, _ = stack[i]
        expected = 1 if prev_v == 13 else prev_v + 1
        if cv != expected:
            return "other"
        c_red = cs in RED
        if c_red == prev_red:
            return "other"
        prev_v = cv
        prev_red = c_red
    return "rb_run"


# --- Rule predicates ---

def is_partial_ok(stack):
    """True if `stack` is a legal group OR a length-2 partial
    that could grow into one. Used to validate intermediate
    extends — a beginner is allowed to pair up two cards into a
    transient they'll finish on the next move."""
    n = len(stack)
    if n == 0:
        return True
    if n == 1:
        return True
    if n >= 3:
        return classify(stack) != "other"
    a, b = stack
    # Pair that could be a run partial:
    if successor(a[0]) == b[0]:
        if a[1] == b[1]:
            return True  # pure-run partial
        if color(a[1]) != color(b[1]):
            return True  # rb-run partial
    # Pair that could be a set partial:
    if a[0] == b[0] and a[1] != b[1]:
        return True
    return False


# --- Neighborhood ---

# maxsize=None: input space is bounded at 104 distinct
# (value, suit, deck) triples, so the cache can never grow
# beyond that. Trivial memory; full retention beats LRU
# eviction overhead. Pure function: cached results are
# equivalent to live results.
@functools.lru_cache(maxsize=None)
def neighbors(c):
    """(value, suit) shapes that could sit adjacent to `c` in
    some valid group. Deck-agnostic."""
    v, s, _ = c
    c_color = color(s)
    pred_v = 13 if v == 1 else v - 1
    succ_v = successor(v)
    out = set()
    # pure run: same suit, ±1 value
    out.add((pred_v, s))
    out.add((succ_v, s))
    # rb run: opposite color, ±1 value
    for ss in range(4):
        if color(ss) != c_color:
            out.add((pred_v, ss))
            out.add((succ_v, ss))
    # set: same value, different suit
    for ss in range(4):
        if ss != s:
            out.add((v, ss))
    return out
