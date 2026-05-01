"""classified_card_stack.py — Card stack with cached classification.

A `ClassifiedCardStack` is the data: an immutable cards tuple plus its
kind. All operations on it are module-level pure functions, not methods.

Why pure functions: the data structure should be inert, and the BFS
algorithm composes operations on it; methods that produce new instances
hide the algorithmic shape inside the type. Free functions read like
the steps of an extraction.

Kind alphabet (7):
  - run, rb, set         — length-3+ legal groups
  - pair_run, pair_rb,   — length-2 partials that complete to their
    pair_set               corresponding length-3+ kind
  - singleton            — length-1

Stacks that fit none of these are invalid input. `classify_stack`
returns None for them; callers that want to enforce validity convert
that None into an error at the boundary.

Pure functions provided:
  - classify_stack(cards)              construct from raw cards
  - singleton(card)                    construct a length-1 stack
  - remove_card(stack, card)           1-3 pieces after removing card
  - insert_right(stack, card)          extend on the right; None if illegal
  - insert_left(stack, card)           extend on the left; None if illegal
  - concat(left, right)                concatenate two stacks; None if illegal
  - splice(stack, card, position, side) insert into middle; (left,right) or None
  - to_singletons(stack)               atomize into individual cards
"""

from dataclasses import dataclass

from rules.card import RED


# Kind tags. Module-level constants for fast equality + IDE friendliness.
KIND_RUN = "run"
KIND_RB = "rb"
KIND_SET = "set"
KIND_PAIR_RUN = "pair_run"
KIND_PAIR_RB = "pair_rb"
KIND_PAIR_SET = "pair_set"
KIND_SINGLETON = "singleton"

_LEN3_KINDS = (KIND_RUN, KIND_RB, KIND_SET)
_PAIR_KINDS = (KIND_PAIR_RUN, KIND_PAIR_RB, KIND_PAIR_SET)

# Maps length-3+ kind to its length-2 partial form.
_PAIR_OF = {KIND_RUN: KIND_PAIR_RUN, KIND_RB: KIND_PAIR_RB, KIND_SET: KIND_PAIR_SET}
# Inverse: length-2 partial to its full-form kind.
_FULL_OF = {v: k for k, v in _PAIR_OF.items()}


# --- Data structure ---

@dataclass(frozen=True, slots=True)
class ClassifiedCardStack:
    """Immutable card sequence + cached kind.

    Equality and hash are structural over (cards, kind). Container
    delegation (__len__, __iter__, __getitem__) makes a CCS read like
    a sequence at sites that don't need the kind.

    Construction is via the module functions, not methods, so the
    type stays inert."""
    cards: tuple
    kind: str

    def __len__(self):
        return len(self.cards)

    def __iter__(self):
        return iter(self.cards)

    def __getitem__(self, i):
        return self.cards[i]


# --- Internal classifier ---
# These are the rigorous classifier; everything else is layered on top.
# Kept module-private so the public surface is the named functions below.


def _successor(v):
    return 1 if v == 13 else v + 1


def _classify_raw(cards):
    """Return one of the 7 kinds, or None if `cards` doesn't fit any."""
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


# --- Public constructors ---

def classify_stack(cards):
    """Run the rigorous classifier on `cards`. Returns
    ClassifiedCardStack on success, None on invalid input.

    Use this at the input boundary (loading state, validating raw
    fixture data) and inside `splice` / `concat` / `insert_*` where
    the result of an operation needs verification."""
    cards_t = tuple(cards)
    kind = _classify_raw(cards_t)
    if kind is None:
        return None
    return ClassifiedCardStack(cards_t, kind)


def singleton(card):
    """Build a length-1 ClassifiedCardStack. No classification work."""
    return ClassifiedCardStack((card,), KIND_SINGLETON)


# --- Stack operations ---

def remove_card(stack, card):
    """Remove `card` from `stack`. Returns a tuple of 1, 2, or 3
    ClassifiedCardStacks.

    The FIRST piece is always the extracted card as a singleton.
    Subsequent pieces are the remnants:

      - run / rb (length 3+): up to two pieces — left prefix and
        right suffix, in original order. Empty halves are dropped,
        so the tuple has 2 or 3 entries depending on whether the
        card was at an end (2) or interior (3).
      - set (length 3+): one combined remainder piece (sets are
        unordered, so prefix+suffix concatenate naturally). 2 entries.
      - pair_run / pair_rb / pair_set: two singletons (extracted +
        the other card). 2 entries.
      - singleton: just the card itself; the original stack is fully
        consumed. 1 entry.

    Remnant kinds are derived from the parent's kind family + the
    new length, NOT by re-running the rigorous classifier — slicing
    a run leaves the family intact.

    Raises ValueError if `card` is not in `stack`.
    """
    idx = _find_card_index(stack, card)
    if idx is None:
        raise ValueError(f"card {card} not in stack {stack.cards}")

    extracted = singleton(card)

    if stack.kind == KIND_SINGLETON:
        return (extracted,)

    if stack.kind in _PAIR_KINDS:
        # Length 2: the other card becomes a singleton.
        other = stack.cards[1 - idx]
        return (extracted, ClassifiedCardStack((other,), KIND_SINGLETON))

    # Length 3+ from here on.
    if stack.kind == KIND_SET:
        # Sets are unordered: prefix + suffix join naturally into one
        # remainder. Family preserved; new length determines kind tag.
        rest = stack.cards[:idx] + stack.cards[idx + 1:]
        return (extracted,
                ClassifiedCardStack(rest, _set_kind_for_length(len(rest))))

    # run / rb: split into left prefix and right suffix; drop empties.
    family = stack.kind  # KIND_RUN or KIND_RB
    pieces = [extracted]
    if idx > 0:
        left = stack.cards[:idx]
        pieces.append(ClassifiedCardStack(left, _run_kind_for_length(family, len(left))))
    if idx < len(stack) - 1:
        right = stack.cards[idx + 1:]
        pieces.append(ClassifiedCardStack(right, _run_kind_for_length(family, len(right))))
    return tuple(pieces)


def insert_right(stack, card):
    """Build a new stack with `card` appended on the right. Returns
    ClassifiedCardStack on legal extension, None otherwise.

    Goes through the rigorous classifier — extension can change the
    kind family (singleton + card → pair_X for any of three flavors,
    pair_X + card → run/rb/set, etc.) so a shortcut path would
    duplicate the classifier's logic."""
    return classify_stack(stack.cards + (card,))


def insert_left(stack, card):
    """Build a new stack with `card` prepended. Returns
    ClassifiedCardStack on legal extension, None otherwise."""
    return classify_stack((card,) + stack.cards)


def concat(left, right):
    """Concatenate two stacks end-to-end. Returns ClassifiedCardStack
    on legal result, None otherwise.

    Used by 'push' moves where a trouble pair is appended onto a
    helper stack, and by 'engulf' where a growing 2-partial absorbs
    a helper run. Order matters: `left.cards + right.cards`."""
    return classify_stack(left.cards + right.cards)


def splice(stack, card, position, side):
    """Insert `card` at `position` in `stack`, fragmenting the result
    into two halves.

    `side` controls which half the inserted card joins:
      - 'left': card goes at the END of the left half
                (left = cards[:position] + (card,), right = cards[position:])
      - 'right': card goes at the START of the right half
                 (left = cards[:position], right = (card,) + cards[position:])

    Returns (left_half, right_half) as ClassifiedCardStacks if both
    halves classify as legal stacks; None otherwise.

    The BFS splice move only fires on length-4+ pure_run / rb_run
    sources; this function doesn't enforce that — callers may try a
    splice and inspect the None result. Both halves go through the
    rigorous classifier."""
    if side == "left":
        left_cards = stack.cards[:position] + (card,)
        right_cards = stack.cards[position:]
    elif side == "right":
        left_cards = stack.cards[:position]
        right_cards = (card,) + stack.cards[position:]
    else:
        raise ValueError(f"side must be 'left' or 'right', got {side!r}")

    left = classify_stack(left_cards)
    right = classify_stack(right_cards)
    if left is None or right is None:
        return None
    return (left, right)


def to_singletons(stack):
    """Break `stack` into one ClassifiedCardStack per card, each a
    singleton. Used by the BFS 'steal' verb on sets, where the
    remaining cards become individual trouble singletons rather
    than one combined pair_set."""
    return tuple(singleton(c) for c in stack.cards)


# --- Internal helpers ---

def _find_card_index(stack, card):
    """Linear scan; cards within a single legal stack are unique by
    (value, suit, deck) — runs are sequential, sets have distinct
    suits, partials and singletons are short. Returns None if not found."""
    for i, c in enumerate(stack.cards):
        if c == card:
            return i
    return None


def _run_kind_for_length(family, n):
    """Map a (run-family, length) to the resulting kind tag.
    `family` is KIND_RUN or KIND_RB. Length 0 is invalid here."""
    if n >= 3:
        return family
    if n == 2:
        return _PAIR_OF[family]
    if n == 1:
        return KIND_SINGLETON
    raise ValueError("zero-length run slice is not a valid stack")


def _set_kind_for_length(n):
    """Map remaining-length to the kind for a set fragment."""
    if n >= 3:
        return KIND_SET
    if n == 2:
        return KIND_PAIR_SET
    if n == 1:
        return KIND_SINGLETON
    raise ValueError("zero-length set slice is not a valid stack")
