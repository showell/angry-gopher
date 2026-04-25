"""
Python-side dealer. Produces a complete initial state suitable
for POSTing to `/new-session` with an `initial_state` field.

Why Python deals instead of Go: Go's server-side dealer has a
fixed opening board AND fixed opening hands — the `deck_seed`
only affects the post-deal draw pile order. Every auto_player
run from a fresh session therefore converges to the same stuck
state because agent play is deterministic from a fixed hand.
This dealer keeps the opening BOARD fixed (it's a teaching
fixture that appears in docs and BOARD_LAB) but randomizes the
HANDS + DECK so each game explores a different trajectory.

Usage:
    import dealer
    initial_state = dealer.deal()
    # Then pass to Client.new_session(initial_state=initial_state)
"""

import random


# --- Card constants, mirroring games/lynrummy/card.go ---

SUIT_CLUB = 0
SUIT_DIAMOND = 1
SUIT_SPADE = 2
SUIT_HEART = 3

# --- State enums, mirroring card_stack.go ---

BOARD_FIRMLY_ON_BOARD = 0
HAND_NORMAL = 0

# --- Score, mirroring score.go ---

STACK_TYPE_VALUES = {
    "pure_run": 100,
    "set": 60,
    "rb_run": 50,
}


# --- Opening board. Mirrors dealer.go's initialBoardDefs exactly
# so the server's action validation and client's rendering agree
# on the starting shape.

_OPENING_BOARD_LABELS = [
    (0, ["KS", "AS", "2S", "3S"]),
    (1, ["TD", "JD", "QD", "KD"]),
    (2, ["2H", "3H", "4H"]),
    (3, ["7S", "7D", "7C"]),
    (4, ["AC", "AD", "AH"]),
    (5, ["2C", "3D", "4C", "5H", "6S", "7H"]),
]


def _board_location(row):
    col = (row * 3 + 1) % 5
    return {"top": 20 + row * 60, "left": 40 + col * 30}


_VALUE_FROM_RANK = {
    "A": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7,
    "8": 8, "9": 9, "T": 10, "J": 11, "Q": 12, "K": 13,
}
_SUIT_FROM_CHAR = {
    "C": SUIT_CLUB, "D": SUIT_DIAMOND, "S": SUIT_SPADE, "H": SUIT_HEART,
}


def _parse_label(label):
    """'KS' -> {'value':13, 'suit':2, 'origin_deck':0}. OriginDeck
    defaults to 0; callers may override."""
    return {
        "value": _VALUE_FROM_RANK[label[0]],
        "suit": _SUIT_FROM_CHAR[label[1]],
        "origin_deck": 0,
    }


def _full_double_deck():
    """All 104 cards, suit-ordered. Same canonical order as
    BuildDeterministicDoubleDeck in dealer.go."""
    cards = []
    for deck in (0, 1):
        for suit in (SUIT_CLUB, SUIT_DIAMOND, SUIT_SPADE, SUIT_HEART):
            for value in range(1, 14):
                cards.append({"value": value, "suit": suit, "origin_deck": deck})
    return cards


def _build_initial_board():
    """Produces the 6 opening stacks (deck 0), matching
    dealer.go's InitialBoard / buildInitialBoard."""
    stacks = []
    for row, labels in _OPENING_BOARD_LABELS:
        board_cards = [
            {"card": _parse_label(label), "state": BOARD_FIRMLY_ON_BOARD}
            for label in labels
        ]
        stacks.append({"board_cards": board_cards, "loc": _board_location(row)})
    return stacks


def _classify(cards):
    """Port of strategy._classify — needed for score computation.
    Returns 'set' / 'pure_run' / 'rb_run' / 'other'."""
    n = len(cards)
    if n < 3:
        return "other"
    values = [c["value"] for c in cards]
    suits = [c["suit"] for c in cards]
    if len(set(values)) == 1 and len(set(suits)) == len(suits):
        return "set"
    for i in range(1, n):
        prev = values[i - 1]
        exp = 1 if prev == 13 else prev + 1
        if values[i] != exp:
            return "other"
    if len(set(suits)) == 1:
        return "pure_run"
    colors = ["black" if s in (0, 2) else "red" for s in suits]
    if all(colors[i] != colors[i - 1] for i in range(1, n)):
        return "rb_run"
    return "other"


def _score_for_stacks(stacks):
    total = 0
    for s in stacks:
        cards = [bc["card"] for bc in s["board_cards"]]
        kind = _classify(cards)
        total += len(cards) * STACK_TYPE_VALUES.get(kind, 0)
    return total


def _card_key(c):
    return (c["origin_deck"], c["suit"], c["value"])


def deal(num_players=2, hand_size=15, rng=None):
    """Return a complete initial state dict suitable for POSTing
    to `/new-session` as `initial_state`. Opening board stays
    fixed (deck-0 cards pre-allocated); the remaining 74 cards
    are shuffled and dealt into hands and deck."""
    rng = rng or random.Random()
    all_cards = _full_double_deck()

    board = _build_initial_board()
    used = set()
    for s in board:
        for bc in s["board_cards"]:
            used.add(_card_key(bc["card"]))

    remaining = [c for c in all_cards if _card_key(c) not in used]
    rng.shuffle(remaining)

    hands = []
    cursor = 0
    for _ in range(num_players):
        hand_cards = [
            {"card": remaining[cursor + i], "state": HAND_NORMAL}
            for i in range(hand_size)
        ]
        cursor += hand_size
        hands.append({"hand_cards": hand_cards})

    deck = remaining[cursor:]

    return {
        "board": board,
        "hands": hands,
        "deck": deck,
        "discard": [],
        "active_player_index": 0,
        "scores": [0] * num_players,
        "victor_awarded": False,
        "turn_start_board_score": _score_for_stacks(board),
        "turn_index": 0,
        "cards_played_this_turn": 0,
    }
