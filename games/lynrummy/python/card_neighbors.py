"""
card_neighbors.py — Per-card neighbor tables for fast liveness queries.

For each card c (encoded as 0..103), `NEIGHBORS[c]` is the list of
unordered pairs `(c1_id, c2_id)` such that {c, c1, c2} forms a valid
3-card group: a set, a pure run, or an rb run. Built once at module
import; never changes.

The intended use is fast singleton-liveness queries — answering "is
there an accessible pair on the board that completes a triple with
c?" in O(|NEIGHBORS[c]|) ≈ O(72) instead of the O(|pool|²) scan in
the original `_singleton_is_live`. See `BFS_CARD_TRACKER.md` for the
broader design and `bfs.py` for the call site.

Card encoding (0..103):

    card_id(value, suit, deck) = (value - 1) * 8 + suit * 2 + deck

with value ∈ 1..13, suit ∈ {0,1,2,3} (C/D/S/H), deck ∈ {0,1}.
The encoding is stable: cards with the same (value, suit) but
different decks differ in their low bit; same value, different suit
differ in the bits above; different values differ in the high bits.

Bucket tags (for the per-state `card_loc` array):

    ABSENT   = 0   # not on the board
    HELPER   = 1   # in a helper stack         (accessible)
    TROUBLE  = 2   # in a trouble stack        (accessible)
    GROWING  = 3   # in a growing 2-partial    (accessible)
    COMPLETE = 4   # sealed in a complete group (inaccessible)

A card is "accessible" iff its tag is HELPER, TROUBLE, or GROWING —
encoded as `0 < tag < 4` for cheap range testing in the inner loop.
"""

from itertools import combinations

from rules import RED


# --- Card encoding ---

def card_id(card):
    """Encode a (value, suit, deck) tuple as 0..103."""
    v, s, d = card
    return (v - 1) * 8 + s * 2 + d


# --- Bucket tags ---

ABSENT = 0
HELPER = 1
TROUBLE = 2
GROWING = 3
COMPLETE = 4


# --- Neighbor-table construction ---

def _suits_in_color(red):
    """Return the two suits of the given color (red=True or False)."""
    return tuple(s for s in range(4) if (s in RED) == red)


def _build_neighbors():
    """Generate NEIGHBORS by enumerating each valid-group category
    once. Sets, pure runs, and rb runs partition the space (sets have
    one repeated value; runs have three distinct values), so no
    cross-category duplicates. Within each category every triple is
    generated exactly once in canonical order, so within-category
    duplicates are also impossible. The resulting per-card lists are
    dedup-free.

    Each card has 12 set partners + 12 pure-run partners + 48 rb-run
    partners = 72 partner pairs.
    """
    out = [[] for _ in range(104)]

    def add_triple(c1, c2, c3):
        i1 = card_id(c1)
        i2 = card_id(c2)
        i3 = card_id(c3)
        out[i1].append((i2, i3))
        out[i2].append((i1, i3))
        out[i3].append((i1, i2))

    # Sets: same value, three distinct suits, decks chosen
    # independently per card.
    for v in range(1, 14):
        for s1, s2, s3 in combinations(range(4), 3):
            for d1 in range(2):
                for d2 in range(2):
                    for d3 in range(2):
                        add_triple((v, s1, d1), (v, s2, d2), (v, s3, d3))

    # Pure runs: same suit, three consecutive values (Lyn Rummy
    # values wrap K → A, per `rules.successor`).
    for v0 in range(1, 14):
        v1 = v0 % 13 + 1
        v2 = v1 % 13 + 1
        for s in range(4):
            for d0 in range(2):
                for d1 in range(2):
                    for d2 in range(2):
                        add_triple((v0, s, d0), (v1, s, d1), (v2, s, d2))

    # RB runs: alternating colors, three consecutive values. The two
    # `start_red` cases cover both color-parity orderings (RBR and
    # BRB).
    for v0 in range(1, 14):
        v1 = v0 % 13 + 1
        v2 = v1 % 13 + 1
        for start_red in (True, False):
            suits0 = _suits_in_color(start_red)
            suits1 = _suits_in_color(not start_red)
            suits2 = suits0  # position 2 matches position 0's color
            for s0 in suits0:
                for s1 in suits1:
                    for s2 in suits2:
                        for d0 in range(2):
                            for d1 in range(2):
                                for d2 in range(2):
                                    add_triple(
                                        (v0, s0, d0),
                                        (v1, s1, d1),
                                        (v2, s2, d2),
                                    )

    return out


NEIGHBORS = _build_neighbors()


# --- Card-location array + liveness query ---

def build_card_loc(buckets):
    """From a `Buckets` state, return a 104-element list mapping
    card_id → bucket tag. Cards not on the board are ABSENT.

    Each bucket may hold either raw card-list stacks or CCS
    objects; both expose a card iteration via __iter__, but
    going through `.cards` on CCS is a hair faster than the
    iterator wrapper. `_iter_cards` papers over the difference."""
    loc = [ABSENT] * 104
    for stack in buckets.helper:
        for c in _iter_cards(stack):
            loc[card_id(c)] = HELPER
    for stack in buckets.trouble:
        for c in _iter_cards(stack):
            loc[card_id(c)] = TROUBLE
    for stack in buckets.growing:
        for c in _iter_cards(stack):
            loc[card_id(c)] = GROWING
    for stack in buckets.complete:
        for c in _iter_cards(stack):
            loc[card_id(c)] = COMPLETE
    return loc


def _iter_cards(stack):
    cards = getattr(stack, "cards", None)
    return cards if cards is not None else stack


def is_live(c, card_loc):
    """True if `c` can form a valid 3-card group with two accessible
    partner cards on the board (helper / trouble / growing). `c`'s
    own tag is irrelevant — the question is reachability, not
    presence. COMPLETE cards are sealed and don't count as partners.

    O(|NEIGHBORS[c]|) per call; no list construction, no classify
    invocation, no triple permutations.
    """
    for c1_id, c2_id in NEIGHBORS[card_id(c)]:
        loc1 = card_loc[c1_id]
        loc2 = card_loc[c2_id]
        if 0 < loc1 < 4 and 0 < loc2 < 4:
            return True
    return False
