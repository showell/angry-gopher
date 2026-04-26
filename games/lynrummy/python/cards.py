"""
cards.py — card primitives the BFS planner sits on.

Mirrors Elm's `Game.Agent.Cards` + `Game.Card` + part of
`Game.StackType`. Holds the deck-agnostic predicates and
verb-eligibility checks that the move enumerator + the
extract physics consult.

Lifted from `beginner.py` on 2026-04-26 as the module split
landed (per ALIGNMENT_REPORT.md). The legacy beginner
planner is retiring; these primitives needed their own home
so the BFS doesn't reach into a legacy module.
"""

# --- Card + board model ---

RANKS = "A23456789TJQK"
SUITS = "CDSH"           # Clubs Diamonds Spades Hearts
RED = {1, 3}             # Diamonds, Hearts


def card(label, deck=0):
    """'5H' → (5, 3, 0). 'TC:1' → (10, 0, 1)."""
    if ":" in label:
        label, d = label.split(":")
        deck = int(d)
    return (RANKS.index(label[0]) + 1,
            SUITS.index(label[1]),
            deck)


def label(c):
    v, s, _ = c
    return RANKS[v - 1] + SUITS[s]


def card_label(c):
    """Label that includes deck suffix when non-zero. Used
    in DSL output where two cards of the same value+suit
    can co-exist (one per deck) and need to be told apart."""
    v, s, d = c
    base = RANKS[v - 1] + SUITS[s]
    return f"{base}:{d}" if d else base


# --- Classification ---

def successor(v):
    return 1 if v == 13 else v + 1


def color(s):
    return "red" if s in RED else "black"


def classify(stack):
    """Single-pass classifier for length-3+ stacks. Early
    exits on the first impossibility. Inlines successor and the
    red-set membership check to avoid call overhead — this
    is the hottest function in the search."""
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


# --- Verb eligibility ---
# Mirror Elm's `canPeel` / `canPluck` / etc. inside
# Enumerator.elm. Each predicate is a pure function on
# (kind, n, ci); the enumerator dispatches via verb_for.

def can_peel(kind, n, ci):
    if kind == "set" and n >= 4:
        return True
    if kind in ("pure_run", "rb_run") and n >= 4 and (
            ci == 0 or ci == n - 1):
        return True
    return False


def can_pluck(kind, n, ci):
    return kind in ("pure_run", "rb_run") and 3 <= ci <= n - 4


def can_yank(kind, n, ci):
    if kind not in ("pure_run", "rb_run"):
        return False
    if ci == 0 or ci == n - 1 or 3 <= ci <= n - 4:
        return False
    left_len = ci
    right_len = n - ci - 1
    return (max(left_len, right_len) >= 3
            and min(left_len, right_len) >= 1)


def can_steal(kind, n, ci):
    if n != 3:
        return False
    if kind in ("pure_run", "rb_run"):
        return ci == 0 or ci == n - 1
    return kind == "set"


def can_split_out(kind, n, ci):
    """Extract the interior card of a length-3 run, splitting
    it into two singleton TROUBLE fragments. Fills the only
    extraction gap in the verb vocabulary: every card on the
    board becomes reachable for absorption."""
    return (kind in ("pure_run", "rb_run")
            and n == 3 and ci == 1)
