"""classified_card_stack.py — Card stack with cached classification.

A `ClassifiedCardStack` is the data: an immutable cards tuple plus its
kind. Operations come in pairs: a probe that earns the kind knowledge,
and a custom executor that uses that knowledge to build the result.

Pattern:

    new_kind = kind_after_absorb_right(target, card)
    if new_kind is None:
        return None
    result = absorb_right(target, card, new_kind)

The probe asks "can I do this, and what would the result be?" and
short-circuits on failure with no allocations. The executor assumes
the precondition holds and builds the result trivially.

Source-side verbs (`peel` / `pluck` / `yank` / `steal` / `split_out`)
follow the same pattern with `verb_for_position` as the probe — it
returns the single verb that applies (or None), and each verb has its
own custom executor that uses the parent's kind family to derive the
remnant kinds without re-classifying.

Kind alphabet (7):
  - run, rb, set         — length-3+ legal groups
  - pair_run, pair_rb,   — length-2 partials
    pair_set
  - singleton            — length-1

Stacks that fit none of these are invalid input. `classify_stack`
returns None for them; the input boundary converts that None into an
error before anything else runs.
"""

from dataclasses import dataclass, field

from rules.card import RED


# --- Kind alphabet ----------------------------------------------------------

KIND_RUN = "run"
KIND_RB = "rb"
KIND_SET = "set"
KIND_PAIR_RUN = "pair_run"
KIND_PAIR_RB = "pair_rb"
KIND_PAIR_SET = "pair_set"
KIND_SINGLETON = "singleton"

_LEN3_KINDS = (KIND_RUN, KIND_RB, KIND_SET)
_PAIR_KINDS = (KIND_PAIR_RUN, KIND_PAIR_RB, KIND_PAIR_SET)

# Length-3+ kind ⇄ pair-form kind.
_PAIR_OF = {KIND_RUN: KIND_PAIR_RUN, KIND_RB: KIND_PAIR_RB, KIND_SET: KIND_PAIR_SET}
_FULL_OF = {v: k for k, v in _PAIR_OF.items()}

# A "family" is one of run / rb / set — we use the full-form kind tag
# as the family identifier so the same vocabulary serves both purposes.
_FAMILY_OF_KIND = {
    KIND_RUN: KIND_RUN,
    KIND_PAIR_RUN: KIND_RUN,
    KIND_RB: KIND_RB,
    KIND_PAIR_RB: KIND_RB,
    KIND_SET: KIND_SET,
    KIND_PAIR_SET: KIND_SET,
    # KIND_SINGLETON has no family yet — handled as a special case.
}


# --- Data structure ---------------------------------------------------------

@dataclass(frozen=True, slots=True)
class ClassifiedCardStack:
    """Immutable card sequence + cached kind + cached length.
    Construction goes through the module functions; the type itself
    is inert. Three slot reads — `stack.cards`, `stack.kind`,
    `stack.n` — cover every access. No dunder methods on purpose:
    `len(stack)`, `for c in stack`, and `stack[i]` all raise. This
    is two things at once:
      1. Speed: dunder dispatch is slow on the BFS hot path; slot
         reads of `.cards`, `.kind`, `.n` are direct attribute hits.
      2. Elm portability: the Elm port has no equivalent of
         `__iter__` / `__getitem__` / `__len__` — every access goes
         through the record fields. Mirroring that here makes the
         port a near-mechanical translation."""
    cards: tuple
    kind: str
    n: int = field(init=False)

    def __post_init__(self):
        object.__setattr__(self, "n", len(self.cards))


# --- Internal classifier ----------------------------------------------------

def _successor(v):
    return 1 if v == 13 else v + 1


def _classify_raw(cards):
    n = len(cards)
    if n == 0:
        return None
    if n == 1:
        return KIND_SINGLETON
    if n == 2:
        return _classify_pair(cards)
    return _classify_long(cards)


def _classify_pair(cards):
    a, b = cards
    av, asu, _ = a
    bv, bsu, _ = b
    if av == bv:
        return KIND_PAIR_SET if asu != bsu else None
    if _successor(av) != bv:
        return None
    if asu == bsu:
        return KIND_PAIR_RUN
    if (asu in RED) != (bsu in RED):
        return KIND_PAIR_RB
    return None


def _classify_long(cards):
    a0v, a0s, _ = cards[0]
    a1v, a1s, _ = cards[1]
    n = len(cards)

    if a0v == a1v:
        if a0s == a1s:
            return None
        seen = {a0s, a1s}
        for i in range(2, n):
            cv, cs, _ = cards[i]
            if cv != a0v or cs in seen:
                return None
            seen.add(cs)
        return KIND_SET

    if _successor(a0v) != a1v:
        return None

    if a0s == a1s:
        prev_v = a1v
        for i in range(2, n):
            cv, cs, _ = cards[i]
            if cv != _successor(prev_v) or cs != a0s:
                return None
            prev_v = cv
        return KIND_RUN

    a0_red = a0s in RED
    a1_red = a1s in RED
    if a0_red == a1_red:
        return None
    prev_v = a1v
    prev_red = a1_red
    for i in range(2, n):
        cv, cs, _ = cards[i]
        if cv != _successor(prev_v):
            return None
        c_red = cs in RED
        if c_red == prev_red:
            return None
        prev_v = cv
        prev_red = c_red
    return KIND_RB


# --- Public constructors ----------------------------------------------------

def classify_stack(cards):
    """Run the rigorous classifier. Returns CCS on success, None on
    invalid input. Use this at the input boundary; afterwards every
    stack is already classified."""
    cards_t = tuple(cards)
    kind = _classify_raw(cards_t)
    if kind is None:
        return None
    return ClassifiedCardStack(cards_t, kind)


def singleton(card):
    """Build a length-1 ClassifiedCardStack."""
    return ClassifiedCardStack((card,), KIND_SINGLETON)


def to_singletons(stack):
    """Atomize a stack into one ClassifiedCardStack per card. Used by
    `steal` on sets, where the BFS algorithm wants the remaining cards
    as separate trouble singletons rather than one combined pair_set."""
    return tuple(singleton(c) for c in stack.cards)


# --- Source-side verbs ------------------------------------------------------
#
# The five extraction verbs: peel, pluck, yank, steal, split_out.
# Each pair: a `can_X(stack, i)` predicate + a custom `X(stack, i)`
# executor. `verb_for_position` is the dispatching probe — it asks
# which (if any) verb applies at position i.

def can_peel(stack, i):
    """Peel: drop an end card from a length-4+ run/rb, or any card from
    a length-4+ set (sets are unordered)."""
    n = stack.n
    if stack.kind == KIND_SET and n >= 4:
        return True
    if stack.kind in (KIND_RUN, KIND_RB) and n >= 4 and (i == 0 or i == n - 1):
        return True
    return False


def can_pluck(stack, i):
    """Pluck: drop an interior card of a run/rb such that BOTH halves
    remain length-3+ runs of the same family. Requires n >= 7 with
    i in [3, n-4]."""
    if stack.kind not in (KIND_RUN, KIND_RB):
        return False
    return 3 <= i <= stack.n - 4


def can_yank(stack, i):
    """Yank: drop a card from a run/rb at a position where one half is
    length-3+ and the other is length 1 or 2 (non-empty). Covers the
    positions outside peel (ends) and pluck (deep interior)."""
    if stack.kind not in (KIND_RUN, KIND_RB):
        return False
    n = stack.n
    if i == 0 or i == n - 1 or 3 <= i <= n - 4:
        return False
    left_len = i
    right_len = n - i - 1
    return max(left_len, right_len) >= 3 and min(left_len, right_len) >= 1


def can_steal(stack, i):
    """Steal: only on length-3 stacks. End positions for run/rb;
    any position for set."""
    if stack.n != 3:
        return False
    if stack.kind in (KIND_RUN, KIND_RB):
        return i == 0 or i == 2
    return stack.kind == KIND_SET


def can_split_out(stack, i):
    """Split-out: extract the middle card of a length-3 run/rb. Both
    halves are singletons."""
    return (stack.kind in (KIND_RUN, KIND_RB)
            and stack.n == 3 and i == 1)


def verb_for_position(stack, i):
    """Probe: returns the single verb that applies at position i, or None.

    Verbs are mutually exclusive at any (stack, i) — the predicates
    partition the legal extraction positions into one verb each."""
    if can_peel(stack, i):
        return "peel"
    if can_pluck(stack, i):
        return "pluck"
    if can_yank(stack, i):
        return "yank"
    if can_steal(stack, i):
        return "steal"
    if can_split_out(stack, i):
        return "split_out"
    return None


# Custom executors. Each ASSUMES its precondition; we assert in case of
# caller bug.

def peel(stack, i):
    """Assumes can_peel(stack, i). Returns (extracted_singleton, remnant).

    For set: remnant has the same value, one less suit. Length n-1
    where n was >= 4; remnant kind is set or pair_set by length.
    For run/rb at end position: remnant is the contiguous (n-1) cards
    on the opposite side. Family preserved; length-driven kind."""
    assert can_peel(stack, i), \
        f"can_peel({stack.kind} len={stack.n}, {i}) is False"
    extracted = singleton(stack.cards[i])
    if stack.kind == KIND_SET:
        rest = stack.cards[:i] + stack.cards[i + 1:]
        return (extracted,
                ClassifiedCardStack(rest, _set_kind_for_length(len(rest))))
    family = stack.kind
    rest = stack.cards[1:] if i == 0 else stack.cards[:-1]
    return (extracted,
            ClassifiedCardStack(rest, _run_kind_for_length(family, len(rest))))


def pluck(stack, i):
    """Assumes can_pluck(stack, i). Returns (extracted, left, right).

    Both halves are length-3+ runs of the parent family."""
    assert can_pluck(stack, i), \
        f"can_pluck({stack.kind} len={stack.n}, {i}) is False"
    family = stack.kind
    extracted = singleton(stack.cards[i])
    left_cards = stack.cards[:i]
    right_cards = stack.cards[i + 1:]
    return (extracted,
            ClassifiedCardStack(left_cards, family),
            ClassifiedCardStack(right_cards, family))


def yank(stack, i):
    """Assumes can_yank(stack, i). Returns (extracted, left, right).

    One half is length-3+ run-family, the other is length-1 (singleton)
    or length-2 (pair_X). Both non-empty by yank precondition."""
    assert can_yank(stack, i), \
        f"can_yank({stack.kind} len={stack.n}, {i}) is False"
    family = stack.kind
    extracted = singleton(stack.cards[i])
    left_cards = stack.cards[:i]
    right_cards = stack.cards[i + 1:]
    return (extracted,
            ClassifiedCardStack(left_cards, _run_kind_for_length(family, len(left_cards))),
            ClassifiedCardStack(right_cards, _run_kind_for_length(family, len(right_cards))))


def steal(stack, i):
    """Assumes can_steal(stack, i). Returns 2-3 pieces.

    For set (n=3): atomizes — returns (extracted, *other_two_singletons)
    so 3 pieces total. (BFS rule: stealing from a set destroys the set
    and the remaining cards become independent trouble singletons,
    rather than persisting as one pair_set.)
    For run/rb (n=3, i=0 or i=2): returns (extracted, length-2 partial)."""
    assert can_steal(stack, i), \
        f"can_steal({stack.kind} len={stack.n}, {i}) is False"
    extracted = singleton(stack.cards[i])
    if stack.kind == KIND_SET:
        others = tuple(singleton(c) for j, c in enumerate(stack.cards) if j != i)
        return (extracted,) + others
    family = stack.kind
    rest = stack.cards[1:] if i == 0 else stack.cards[:-1]
    return (extracted, ClassifiedCardStack(rest, _PAIR_OF[family]))


def split_out(stack, i):
    """Assumes can_split_out(stack, i). Length-3 run or rb, i=1.
    Returns (extracted, left_singleton, right_singleton)."""
    assert can_split_out(stack, i), \
        f"can_split_out({stack.kind} len={stack.n}, {i}) is False"
    return (singleton(stack.cards[1]),
            singleton(stack.cards[0]),
            singleton(stack.cards[2]))


# --- Target-side: absorb a card --------------------------------------------

def kind_after_absorb_right(target, card):
    """Probe: what kind would (target.cards + (card,)) classify as, or
    None if illegal. O(1) for run/rb (single boundary check); bounded
    for set (cross-stack suit uniqueness, max 4 cards)."""
    return _absorb_kind(target, card, side="right")


def kind_after_absorb_left(target, card):
    """Probe: what kind would ((card,) + target.cards) classify as, or
    None if illegal."""
    return _absorb_kind(target, card, side="left")


def absorb_right(target, card, new_kind):
    """Executor. Assumes new_kind == kind_after_absorb_right(target, card).
    Trivial — appends card and tags with the earned kind."""
    return ClassifiedCardStack(target.cards + (card,), new_kind)


def absorb_left(target, card, new_kind):
    """Executor. Assumes new_kind == kind_after_absorb_left(target, card)."""
    return ClassifiedCardStack((card,) + target.cards, new_kind)


# --- Splice ----------------------------------------------------------------

def kinds_after_splice(stack, card, position, side):
    """Probe: returns (left_kind, right_kind) if both halves classify,
    None otherwise.

    side='left':  left  = stack.cards[:position] + (card,)
                  right = stack.cards[position:]
    side='right': left  = stack.cards[:position]
                  right = (card,) + stack.cards[position:]

    Fast path for run/rb parents (the splice hot path): the pure-slice
    half's kind is derived from parent family + slice length; the
    with-card half needs at most a single boundary check (length-3+) or
    a 2-card pair classification (length-2). No full reclassification.
    Other parent kinds fall through to the rigorous classifier."""
    if side not in ("left", "right"):
        raise ValueError(f"side must be 'left' or 'right', got {side!r}")
    family = _FAMILY_OF_KIND.get(stack.kind)
    if family == KIND_RUN or family == KIND_RB:
        return _kinds_after_splice_run(
            stack.cards, card, position, side, family)
    # Fallback: non-run/rb parent (set, partial, singleton). Rigorous.
    left_cards, right_cards = _splice_halves(stack, card, position, side)
    left_kind = _classify_raw(left_cards)
    if left_kind is None:
        return None
    right_kind = _classify_raw(right_cards)
    if right_kind is None:
        return None
    return (left_kind, right_kind)


def _kinds_after_splice_run(parent_cards, card, position, side, family):
    """Splice-probe specialization for run/rb parent. Caller has
    confirmed family in (KIND_RUN, KIND_RB)."""
    n = len(parent_cards)
    if side == "left":
        # left  = parent[:position] + (card,)
        # right = parent[position:]
        slice_len = n - position
        with_card_len = position + 1
        right_kind = _slice_kind(family, slice_len)
        if right_kind is None:
            return None
        if with_card_len == 1:
            left_kind = KIND_SINGLETON
        elif with_card_len == 2:
            left_kind = _classify_pair((parent_cards[0], card))
            if left_kind is None:
                return None
        else:
            if not _boundary_ok(parent_cards[position - 1], card, family):
                return None
            left_kind = family
        return (left_kind, right_kind)
    # side == "right"
    # left  = parent[:position]
    # right = (card,) + parent[position:]
    slice_len = position
    with_card_len = n - position + 1
    left_kind = _slice_kind(family, slice_len)
    if left_kind is None:
        return None
    if with_card_len == 1:
        right_kind = KIND_SINGLETON
    elif with_card_len == 2:
        right_kind = _classify_pair((card, parent_cards[position]))
        if right_kind is None:
            return None
    else:
        if not _boundary_ok(card, parent_cards[position], family):
            return None
        right_kind = family
    return (left_kind, right_kind)


def _slice_kind(family, n):
    """Kind of a contiguous n-card slice of a run/rb-family stack.
    Returns None when the slice is empty."""
    if n <= 0:
        return None
    if n == 1:
        return KIND_SINGLETON
    if n == 2:
        return _PAIR_OF[family]
    return family


def splice(stack, card, position, side, left_kind, right_kind):
    """Executor. Builds the two halves with the given kinds. Assumes
    kinds_after_splice returned (left_kind, right_kind)."""
    if side not in ("left", "right"):
        raise ValueError(f"side must be 'left' or 'right', got {side!r}")
    left_cards, right_cards = _splice_halves(stack, card, position, side)
    return (ClassifiedCardStack(left_cards, left_kind),
            ClassifiedCardStack(right_cards, right_kind))


# --- Internal helpers ------------------------------------------------------

def _splice_halves(stack, card, position, side):
    """Cards-tuple builder shared by the splice probe and executor."""
    if side == "left":
        return stack.cards[:position] + (card,), stack.cards[position:]
    # side == "right"
    return stack.cards[:position], (card,) + stack.cards[position:]


def _absorb_kind(target, card, side):
    """Shared kind-probe for absorb_right and absorb_left.

    side='right': boundary is (target.cards[-1], card) — target precedes
    side='left':  boundary is (card, target.cards[0]) — card precedes

    For sets, a cross-stack suit-uniqueness check fires (boundary
    alone misses non-adjacent duplicates)."""
    n_new = target.n + 1

    if target.kind == KIND_SINGLETON:
        # 2-card result: family inferred from the two cards in
        # boundary order.
        only = target.cards[0]
        if side == "right":
            family = _family_for_two_cards(only, card)
        else:
            family = _family_for_two_cards(card, only)
        if family is None:
            return None
        return _PAIR_OF[family]

    family = _FAMILY_OF_KIND[target.kind]

    # Boundary check between adjacent cards in resulting stack.
    if side == "right":
        boundary_a, boundary_b = target.cards[-1], card
    else:
        boundary_a, boundary_b = card, target.cards[0]
    if not _boundary_ok(boundary_a, boundary_b, family):
        return None

    # Set family additionally needs cross-stack suit uniqueness +
    # max-length cap (4 distinct suits).
    if family == KIND_SET:
        if n_new > 4:
            return None
        new_suit = card[1]
        for c in target.cards:
            if c[1] == new_suit:
                return None

    if n_new >= 3:
        return family
    return _PAIR_OF[family]


def _family_for_two_cards(c1, c2):
    """Return the family two cards form when adjacent in (c1, c2) order,
    or None if they don't form any legal pair."""
    v1, s1, _ = c1
    v2, s2, _ = c2
    if v1 == v2:
        if s1 == s2:
            return None
        return KIND_SET
    if _successor(v1) != v2:
        return None
    if s1 == s2:
        return KIND_RUN
    if (s1 in RED) != (s2 in RED):
        return KIND_RB
    return None


def _boundary_ok(a, b, family):
    """Single-boundary legality check for `family`. Caller has already
    determined the family from the parent kinds."""
    av, asu, _ = a
    bv, bsu, _ = b
    if family == KIND_SET:
        return av == bv and asu != bsu
    if family == KIND_RUN:
        return asu == bsu and _successor(av) == bv
    if family == KIND_RB:
        if _successor(av) != bv:
            return False
        return (asu in RED) != (bsu in RED)
    return False


def _run_kind_for_length(family, n):
    """Kind tag for a slice of a run/rb with n cards remaining."""
    if n >= 3:
        return family
    if n == 2:
        return _PAIR_OF[family]
    if n == 1:
        return KIND_SINGLETON
    raise ValueError("zero-length run slice is not a valid stack")


def _set_kind_for_length(n):
    """Kind tag for a remainder of a set with n cards."""
    if n >= 3:
        return KIND_SET
    if n == 2:
        return KIND_PAIR_SET
    if n == 1:
        return KIND_SINGLETON
    raise ValueError("zero-length set slice is not a valid stack")
