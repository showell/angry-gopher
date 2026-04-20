"""
Puzzle catalog for the human-play harness. Each puzzle is a
minimal board + hand designed to fire exactly one trick under
the correct LynRummy rules (CanExtract-respecting,
invariant-preserving). A human solves the puzzle in the Elm UI;
`hints.py` independently produces its own primitive sequence
for the same initial state; the comparator (compare.py)
validates that the two sequences are equivalent under the
arbitrariness axes (card order, merge side, loc, etc.).

Design constraints:
  - Source stacks for extractions are ≥ 4 cards (so CanExtract
    allows end-peels) or ≥ 7 for middle-peels.
  - Kick-home stacks for rb_swap are ≥ 3 cards and a valid type
    (pure run or small set).
  - Hand composition forces the target trick to be the
    highest-priority firing one.
"""

import copy


_SUITS  = {"C": 0, "D": 1, "S": 2, "H": 3}
_VALUES = {"A": 1,  "2": 2,  "3": 3,  "4": 4,  "5": 5,  "6": 6, "7": 7,
           "8": 8,  "9": 9,  "T": 10, "J": 11, "Q": 12, "K": 13}


def card(label, deck=0):
    v, s = label[0].upper(), label[1].upper()
    return {"value": _VALUES[v], "suit": _SUITS[s], "origin_deck": deck}


def board_card(label, deck=0):
    return {"card": card(label, deck), "state": 0}


def hand_card(label, deck=1):
    return {"card": card(label, deck), "state": 0}


def stack(top, left, *cards):
    bcs = []
    for c in cards:
        if isinstance(c, tuple):
            bcs.append(board_card(c[0], c[1]))
        else:
            bcs.append(board_card(c))
    return {"board_cards": bcs, "loc": {"top": top, "left": left}}


def hand(*cards):
    hcs = []
    for c in cards:
        if isinstance(c, tuple):
            hcs.append(hand_card(c[0], c[1]))
        else:
            hcs.append(hand_card(c))
    return {"hand_cards": hcs}


def base_state(board, active_hand, other_hand=None, deck=None):
    if other_hand is None:
        other_hand = hand()
    if deck is None:
        deck = [card("2C"), card("3C"), card("4C"), card("5C"), card("6C")]
    return {
        "board": board,
        "hands": [active_hand, other_hand],
        "deck": deck,
        "discard": [],
        "active_player_index": 0,
        "scores": [0, 0],
        "victor_awarded": False,
        "turn_start_board_score": 0,
        "turn_index": 0,
        "cards_played_this_turn": 0,
    }


# --- Puzzles ---------------------------------------------------
# Each is the minimal scenario for its target trick, designed so
# hints.build_suggestions returns that trick as the top (or only)
# firing one.

PUZZLES = {

    "direct_play_basic": {
        "description": (
            "Hand has 9D. Board has pure diamond run [6D, 7D, 8D]. "
            "Drag 9D onto the run → [6D, 7D, 8D, 9D]."
        ),
        "target_trick": "direct_play",
        "initial_state": base_state(
            board=[
                stack( 40,  40, "6D", "7D", "8D"),
                stack(180,  40, "QC", "KC", "AC"),
                stack( 40, 260, "2S", "3S", "4S"),
            ],
            active_hand=hand("9D"),
        ),
    },

    "hand_stacks_basic": {
        "description": (
            "Hand has 4H, 4S, 4D — three of a kind. Place all "
            "three as a new 4-set on open board."
        ),
        "target_trick": "hand_stacks",
        "initial_state": base_state(
            board=[
                stack( 40,  40, "JC", "QC", "KC"),
                stack( 40, 260, "TD", "JD", "QD"),
            ],
            active_hand=hand("4H", "4S", "4D"),
        ),
    },

    "pair_peel_basic": {
        "description": (
            "Hand has 5H + 5S (a pair). Board has pure diamond "
            "run [5D, 6D, 7D, 8D] — 5D is at the left edge and "
            "extractable. Peel 5D and form [5D, 5H, 5S]."
        ),
        "target_trick": "pair_peel",
        "initial_state": base_state(
            board=[
                stack( 40,  40, "5D", "6D", "7D", "8D"),
                stack(180,  40, "QC", "KC", "AC"),
            ],
            active_hand=hand("5H", "5S"),
        ),
    },

    "split_for_set_basic": {
        "description": (
            "Hand has 5H. Board has TWO separate 4-runs whose "
            "left-edge cards are 5D and 5S. Peel both, combine "
            "with 5H → [5H, 5D, 5S] 3-set."
        ),
        "target_trick": "split_for_set",
        "initial_state": base_state(
            board=[
                stack( 40,  40, "5D", "6D", "7D", "8D"),
                stack( 40, 300, "5S", "6S", "7S", "8S"),
                stack(180,  40, "QC", "KC", "AC"),
            ],
            active_hand=hand("5H"),
        ),
    },

    "split_for_set_middle": {
        "description": (
            "Middle-extraction variant. Board has a 7-run "
            "[3D..9D] (5D at ci=2 would be extractable) AND "
            "another 4-run [5S, 6S, 7S, 8S]. "
            "NOTE: ci=2 in a 7-run is NOT extractable "
            "(needs ci≥3 + 3 after). This puzzle only fires "
            "if 5D is at ci=3 of an 8-run."
        ),
        "target_trick": "split_for_set",
        "initial_state": base_state(
            board=[
                # 8-run, 5D at ci=3. CanExtract: ci>=3 ✓, 8-3-1=4 ≥3 ✓.
                stack( 40,  40, "2D", "3D", "4D", "5D", "6D", "7D", "8D", "9D"),
                stack( 40, 400, "5S", "6S", "7S", "8S"),
                stack(180,  40, "QC", "KC", "AC"),
            ],
            active_hand=hand("5H"),
        ),
    },

    "peel_for_run_basic": {
        "description": (
            "Hand has TD. Board has pure CLUBS runs containing "
            "9C and JC at extractable positions — since neither "
            "run is the same suit as the hand card, direct_play "
            "can't fire. Peel 9C + JC, form RB run "
            "[9C, TD, JC] (black-red-black)."
        ),
        "target_trick": "peel_for_run",
        "initial_state": base_state(
            board=[
                stack( 40,  40, "6C", "7C", "8C", "9C"),  # 9C at ci=3 extractable
                stack( 40, 300, "JC", "QC", "KC", "AC"),  # JC at ci=0 extractable
                stack(180,  40, "2S", "3S", "4S"),
            ],
            active_hand=hand("TD"),
        ),
    },

    "rb_swap_basic": {
        "description": (
            "Hand has 4S. Board has rb run [3D, 4C, 5D, 6C] "
            "and pure clubs [AC, 2C, 3C] that accepts 4C. "
            "Swap 4S in for 4C; 4C lands on the clubs run."
        ),
        "target_trick": "rb_swap",
        "initial_state": base_state(
            board=[
                stack( 40,  40, "3D", "4C", "5D", "6C"),
                stack( 40, 300, "AC", "2C", "3C"),
                stack(180,  40, "9H", "TH", "JH"),
            ],
            active_hand=hand("4S"),
        ),
    },

    # loose_card_play is hard to trigger as top priority — direct_play
    # almost always wins. Deferred. Flag with TODO.
}


def get_puzzle(name):
    if name not in PUZZLES:
        raise KeyError(f"unknown puzzle {name!r}. known: {sorted(PUZZLES)}")
    return copy.deepcopy(PUZZLES[name])


def all_names():
    return sorted(PUZZLES)
