"""classified_card_stack.py — Card stack with cached classification.

A card stack carries its kind as a property of the data, not as something
the algorithm has to recompute. The rigorous classifier runs once at
construction (or, for slices and extensions, derives the new kind cheaply
from the parent + the operation) and the kind sticks for the lifetime of
the stack.

Kind alphabet (7):
  - run, rb, set         — length-3+ legal groups
  - pair_run, pair_rb,   — length-2 partials that could complete to
    pair_set               their corresponding length-3+ kind
  - singleton            — length-1

Stacks that fit none of these are invalid input. The constructor raises
rather than reify a "bad" kind.
"""

from dataclasses import dataclass

from rules.card import RED


# Kind tags (small string set; equality is fast Python-side).
KIND_RUN = "run"
KIND_RB = "rb"
KIND_SET = "set"
KIND_PAIR_RUN = "pair_run"
KIND_PAIR_RB = "pair_rb"
KIND_PAIR_SET = "pair_set"
KIND_SINGLETON = "singleton"

_LEN3_KINDS = (KIND_RUN, KIND_RB, KIND_SET)
_PAIR_KINDS = (KIND_PAIR_RUN, KIND_PAIR_RB, KIND_PAIR_SET)

# Maps length-3+ kind to its length-2 partial form, and vice versa.
_PAIR_OF = {KIND_RUN: KIND_PAIR_RUN, KIND_RB: KIND_PAIR_RB, KIND_SET: KIND_PAIR_SET}
_FULL_OF = {v: k for k, v in _PAIR_OF.items()}


# --- Classifier (used by from_raw and any caller wanting a fresh classify) ---

def _successor(v):
    return 1 if v == 13 else v + 1


def _classify_raw(cards):
    """Return one of the 7 kinds, or None if `cards` doesn't fit any.

    Caller is expected to have an immutable cards tuple; we don't tuple
    or copy here. None is the explicit "invalid" signal — the constructor
    converts that into a ValueError.
    """
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
    # Set partial: same value, distinct suits.
    if av == bv:
        return KIND_PAIR_SET if asu != bsu else None
    # Run partial: consecutive values (a's successor is b).
    if _successor(av) != bv:
        return None
    if asu == bsu:
        return KIND_PAIR_RUN
    # Different suits; legal only if alternating colors (rb partial).
    if (asu in RED) != (bsu in RED):
        return KIND_PAIR_RB
    return None


def _classify_long(cards):
    a0v, a0s, _ = cards[0]
    a1v, a1s, _ = cards[1]
    n = len(cards)

    # Set: same value, all distinct suits.
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

    # Run candidate.
    if _successor(a0v) != a1v:
        return None

    if a0s == a1s:
        # Pure run — same suit throughout.
        prev_v = a1v
        for i in range(2, n):
            cv, cs, _ = cards[i]
            if cv != _successor(prev_v) or cs != a0s:
                return None
            prev_v = cv
        return KIND_RUN

    # rb run candidate: alternating colors.
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


# --- The data structure ---

@dataclass(frozen=True, slots=True)
class ClassifiedCardStack:
    """An immutable card sequence + its classification.

    Equality is by (cards, kind); hashing is structural. Construct via
    `from_raw` for unknown input or via the slicing / extension methods
    on an existing stack — those derive the new kind cheaply rather than
    re-running the classifier.
    """
    cards: tuple
    kind: str

    # Convenience constructors

    @classmethod
    def from_raw(cls, cards):
        """Full classifier path. Raises ValueError on invalid input.

        Use this once at the input boundary (loading state from JSON,
        building the initial Buckets) — afterwards prefer the slicing
        methods which derive kind from the parent."""
        cards_t = tuple(cards)
        kind = _classify_raw(cards_t)
        if kind is None:
            raise ValueError(
                f"Invalid stack — does not classify as any kind: {cards_t}")
        return cls(cards_t, kind)

    @classmethod
    def singleton(cls, card):
        """Build a length-1 stack. No classification work needed."""
        return cls((card,), KIND_SINGLETON)

    # Container-ish behavior

    def __len__(self):
        return len(self.cards)

    def __iter__(self):
        return iter(self.cards)

    def __getitem__(self, i):
        return self.cards[i]

    # Slicing — kind derived from parent + new length

    def peel_first(self):
        """Drop cards[0]. Returns the new (n-1)-card stack.
        Parent must be length >= 2."""
        return self._take_contiguous(self.cards[1:])

    def peel_last(self):
        """Drop cards[-1]. Returns the new (n-1)-card stack.
        Parent must be length >= 2."""
        return self._take_contiguous(self.cards[:-1])

    def split_at(self, i):
        """Remove cards[i], return (left, right) stacks for the
        prefix / suffix pieces. Used by yank, pluck, split_out — the
        operations that fragment a run by removing an interior card.

        Both halves inherit the parent's kind family (pure-run halves
        of a pure run, rb-run halves of an rb run); their kind tags
        come from `_kind_after_truncation` based on remaining length.
        """
        left = self._take_contiguous(self.cards[:i])
        right = self._take_contiguous(self.cards[i + 1:])
        return left, right

    def drop_card_at(self, i):
        """Remove cards[i] from a SET. Sets are unordered so removing
        any card just shrinks the set by one. Result is set or
        pair_set depending on resulting length."""
        if self.kind != KIND_SET:
            raise ValueError(
                f"drop_card_at is only valid on a set, got {self.kind}")
        new_cards = self.cards[:i] + self.cards[i + 1:]
        n = len(new_cards)
        if n >= 3:
            return ClassifiedCardStack(new_cards, KIND_SET)
        if n == 2:
            return ClassifiedCardStack(new_cards, KIND_PAIR_SET)
        if n == 1:
            return ClassifiedCardStack(new_cards, KIND_SINGLETON)
        raise ValueError("drop_card_at left an empty stack — caller bug")

    def _take_contiguous(self, new_cards):
        """Helper for peel/split: take a contiguous prefix or suffix
        of the parent. The kind family is preserved, the kind tag
        comes from the new length."""
        n = len(new_cards)
        if n == 0:
            raise ValueError("Slice produced an empty stack — caller bug")
        if n == 1:
            return ClassifiedCardStack(new_cards, KIND_SINGLETON)
        # For length 2-3+, the kind family is preserved by the slice.
        # Map between full-form (run/rb/set) and pair-form (pair_run/...).
        if self.kind in _LEN3_KINDS:
            family = self.kind
        elif self.kind in _PAIR_KINDS:
            family = _FULL_OF[self.kind]
        else:
            # singleton — can't slice further
            raise ValueError(
                f"Cannot take_contiguous from {self.kind}")
        return ClassifiedCardStack(
            new_cards,
            family if n >= 3 else _PAIR_OF[family])

    # Extension — derives kind from parent + the new card

    def append_right(self, card):
        """Build (cards + (card,)) and classify the result. Returns
        ClassifiedCardStack on legal extension, None otherwise.

        Cheap path: if parent is length-3+ and the new card extends
        the pattern, the kind stays the same family (run/rb/set).
        Otherwise we fall back to the full classifier on the new
        cards tuple."""
        new_cards = self.cards + (card,)
        return _classify_or_none(new_cards)

    def append_left(self, card):
        """Build ((card,) + cards) and classify. Returns
        ClassifiedCardStack on legal extension, None otherwise."""
        new_cards = (card,) + self.cards
        return _classify_or_none(new_cards)


def _classify_or_none(cards):
    kind = _classify_raw(cards)
    if kind is None:
        return None
    return ClassifiedCardStack(cards, kind)
