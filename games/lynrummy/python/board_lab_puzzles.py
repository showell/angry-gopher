"""
board_lab_puzzles.py — canonical catalog of BOARD_LAB puzzles.

Python is the source of truth for puzzle definitions; this
module produces a JSON blob that Go serves at
`/gopher/board-lab/puzzles` and Elm fetches on page load.
Letting Python own the catalog means:

  - Agent-studies-human and human-plays-agent-replay can refer
    to the same named puzzle without two catalogs drifting.
  - A `puzzle_name` column in `lynrummy_puzzle_seeds` (added
    in the companion schema change) makes SQLite sessions
    queryable by puzzle — "show me every solution anyone
    played on 'tight_right_edge'."
  - Writing new puzzles goes here first; Elm picks them up
    automatically on next build.

Each puzzle has:

  - `name` — stable machine id (snake_case).
  - `title` — human-readable panel heading.
  - `description` — one-paragraph prompt shown in the panel.
  - `initial_state` — a full lynrummy.State blob ready for
    POSTing to /new-puzzle-session.

Run as a script to write the catalog JSON:

    python3 games/lynrummy/python/board_lab_puzzles.py \\
        --write games/lynrummy/board-lab/puzzles.json

Run with no args to print it to stdout (useful for diffing).
"""

import argparse
import json
import os
import sys


# Card constants. Suits: Clubs=0, Diamonds=1, Spades=2, Hearts=3.
C, D, S, H = 0, 1, 2, 3


_VALUE_MAP = {"A": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6,
              "7": 7, "8": 8, "9": 9, "T": 10, "J": 11,
              "Q": 12, "K": 13}
_SUIT_MAP = {"C": 0, "D": 1, "S": 2, "H": 3}


def _card(value, suit, deck=0):
    return {"value": value, "suit": suit, "origin_deck": deck}


def _parse_card(token, deck=0):
    """Parse '6H' / '10H' / 'TH' / 'JH' into a card dict.
    Accepts two-char (6H, TH) and three-char (10H) shorthands."""
    token = token.strip()
    if len(token) == 3 and token[:2] == "10":
        val_char, suit_char = "T", token[2]
    elif len(token) == 2:
        val_char, suit_char = token[0], token[1]
    else:
        raise ValueError(f"bad card token {token!r}: expected e.g. '6H', 'TH', '10H'")
    val = _VALUE_MAP.get(val_char.upper())
    suit = _SUIT_MAP.get(suit_char.upper())
    if val is None:
        raise ValueError(f"bad value in {token!r}: expected A/2-9/T/J/Q/K")
    if suit is None:
        raise ValueError(f"bad suit in {token!r}: expected C/D/S/H")
    return _card(val, suit, deck=deck)


def _parse_cards(s, deck=0):
    return [_parse_card(t, deck=deck) for t in s.split()]


# --- DSL-ish builders -----------------------------------------
#
# These let a puzzle read close to how you'd describe it:
#   stack("6H 7H 8H", at=(80, 500))
#   hand("9H")
# instead of the lower-level _card / _stack / _hand dict
# constructions. Short of a real DSL; just readable Python.


def stack(cards, at):
    """Build a board stack from a space-separated card string.
    `at=(top, left)` names the position in board-frame pixels."""
    top, left = at
    return {
        "board_cards": [{"card": c, "state": 0}
                        for c in _parse_cards(cards)],
        "loc": {"top": top, "left": left},
    }


def hand(cards):
    """Build a hand from a space-separated card string.
    An empty string / no cards → empty hand."""
    return {
        "hand_cards": [{"card": c, "state": 0}
                       for c in _parse_cards(cards)],
    }


def puzzle(name, title, description, board, player_hand):
    """Build a catalog entry. `board` is a list of stack()
    results; `player_hand` is a hand() result."""
    return {
        "name": name,
        "title": title,
        "description": description,
        "initial_state": _state(board=board, player_hand=player_hand),
    }


def _state(board, player_hand):
    """Wrap a (board, hand) into a full lynrummy.State blob. The
    lab is always within-a-turn, so scores/deck/etc. take
    neutral defaults."""
    return {
        "board": board,
        "hands": [player_hand, {"hand_cards": []}],
        "deck": [],
        "discard": [],
        "active_player_index": 0,
        "scores": [0, 0],
        "victor_awarded": False,
        "turn_start_board_score": 0,
        "turn_index": 0,
        "cards_played_this_turn": 0,
    }


# --- Puzzle catalog --------------------------------------------


def _pair_peel():
    return puzzle(
        name="pair_peel",
        title="Pair peel",
        description=(
            "Hand has two 3s. The board has a 4-card pure club run "
            "with 3C at one end. Peel the 3C off the run and merge "
            "it with your pair to form a 3-set of 3s."
        ),
        board=[stack("3C 4C 5C 6C", at=(100, 200))],
        player_hand=hand("3S 3D"),
    )


def _tight_right_edge():
    return puzzle(
        name="tight_right_edge",
        title="Tight right edge",
        description=(
            "Hand has 9H. The 6H-7H-8H run sits hard against the "
            "right edge — dropping 9H onto it in place would push "
            "the merged stack off the board. You need to MoveStack "
            "the run to a clearer spot first, then merge. Two other "
            "stacks sit on the board too, so the choice of where to "
            "move is a spatial call."
        ),
        board=[
            stack("6H 7H 8H", at=(80, 695)),
            stack("5C 5D 5S", at=(80, 400)),
            stack("2S 3S 4S", at=(280, 100)),
        ],
        player_hand=hand("9H"),
    )


def _split_for_set():
    return puzzle(
        name="split_for_set",
        title="Split for set",
        description=(
            "Hand has 5H and 5D. The board has a 7-card pure club "
            "run with 5C in the middle. Extract 5C via a mid-run "
            "split and merge the three 5s into a set."
        ),
        board=[stack("2C 3C 4C 5C 6C 7C 8C", at=(100, 100))],
        player_hand=hand("5H 5D"),
    )


def _peel_for_run():
    return puzzle(
        name="peel_for_run",
        title="Peel for run",
        description=(
            "Hand has 8S and 9S. The board has a 4-set of 7s. Peel "
            "7S off the set (leaving a valid 3-set behind) and "
            "merge with 8S-9S to form a pure run."
        ),
        board=[stack("7S 7H 7D 7C", at=(100, 180))],
        player_hand=hand("8S 9S"),
    )


def _follow_up_merge():
    return puzzle(
        name="follow_up_merge_chained_runs",
        title="Follow-up merge (chained runs)",
        description=(
            "Hand has 6H. Two heart runs sit on the board: "
            "3H-4H-5H and 7H-8H-9H. Merging 6H onto the low run "
            "makes it 3-4-5-6 — which now chains with 7-8-9. "
            "Two merges, one turn."
        ),
        board=[
            stack("3H 4H 5H", at=(80, 120)),
            stack("7H 8H 9H", at=(260, 480)),
        ],
        player_hand=hand("6H"),
    )


def _corner_blocked():
    # Designed 2026-04-23 after observing that the agent's
    # find_open_loc always returns (7, 7) when a pre-move is
    # needed. Pre-placing a 3-set of 2s right at the corner
    # (loc 10, 10) forces the scan to land somewhere else.
    # Study signal: does the degraded choice still read as
    # "human-like"?
    return puzzle(
        name="corner_blocked",
        title="Corner blocked",
        description=(
            "Hand has 9H. The 6H-7H-8H run at the right edge "
            "needs a pre-move before it can absorb the 9H — just "
            "like 'Tight right edge' — but the top-left corner is "
            "already occupied by a 3-set of 2s. Where does the "
            "moved run land this time?"
        ),
        board=[
            stack("2C 2H 2D", at=(10, 10)),
            stack("6H 7H 8H", at=(80, 695)),
            stack("5C 5H 5D", at=(260, 400)),
        ],
        player_hand=hand("9H"),
    )


def _multi_corner_blocked():
    # Stress test: every "obvious" open spot is occupied.
    # Top-left, top-right, left-mid, middle-mid. The pre-move
    # must land in one of the narrow gaps. Agent's row-major
    # scan gets to pick between several awkward spots. Human
    # almost certainly picks the gap that feels balanced — a
    # clear study signal.
    return puzzle(
        name="multi_corner_blocked",
        title="Multi-corner blocked",
        description=(
            "Hand has 9H. Same merge shape as 'Tight right edge' "
            "— 6H-7H-8H at the right needs a pre-move before 9H "
            "lands — but every corner and left-side edge already "
            "has a stack parked there. Find the least-awkward "
            "gap for the run's new home."
        ),
        board=[
            stack("2C 2H 2D", at=(10, 10)),
            stack("TC TH TD", at=(10, 640)),
            stack("4C 4H 4D", at=(220, 10)),
            stack("JC JH JD", at=(220, 380)),
            stack("6H 7H 8H", at=(80, 695)),
        ],
        player_hand=hand("9H"),
    )


def _wide_eventual():
    # A 5-card run on the board wants one more card. The
    # merged stack will be 6 cards (192 px wide). Pre-placing
    # so that the EVENTUAL stack fits — not just the
    # current 5-card form — is the kind of lookahead
    # `_plan_merge_hand` exists for. Human's landing pad has
    # to be genuinely spacious; the corner can't absorb 192 px
    # wide without margin work.
    return puzzle(
        name="wide_eventual",
        title="Wide eventual",
        description=(
            "Hand has 8H. The 3H-4H-5H-6H-7H run is already 5 "
            "cards wide and sits pinned against the right edge. "
            "Adding 8H makes it a 6-card stack (192 px). The "
            "pre-move has to land somewhere big enough for the "
            "EVENTUAL stack, not just the current one."
        ),
        board=[
            stack("3H 4H 5H 6H 7H", at=(80, 625)),
            stack("QC QH QD", at=(280, 260)),
        ],
        player_hand=hand("8H"),
    )


def _interfering_neighbor():
    # Direct-play (the simplest trick) made spatial: merging
    # 9H onto the 6H-7H-8H run in place would make it 4 cards
    # wide and overlap the 4-set just to its right. Forces a
    # pre-move even though there's no trick complexity. Tests
    # whether the agent recognizes the eventual overflow
    # against a NEIGHBOR, not against the board edge.
    return puzzle(
        name="interfering_neighbor",
        title="Interfering neighbor",
        description=(
            "Hand has 9H. The 6H-7H-8H run sits in the middle of "
            "the board with a 3-set of 4s packed right next to it "
            "— close enough that merging 9H onto the run in place "
            "would overlap the 4s. Even this simple direct-play "
            "needs a pre-move when the neighbor's in the way."
        ),
        board=[
            stack("6H 7H 8H", at=(120, 300)),
            # 6H-7H-8H right edge = 300+93 = 393. 4-set at 400 =
            # gap of 7 (legal). Merged 4-card right edge = 426,
            # overlaps the 4-set at 400-493.
            stack("4C 4H 4D", at=(120, 400)),
        ],
        player_hand=hand("9H"),
    )


def _packed_row():
    # Four 3-card stacks tiled across the top row with minimal
    # gaps. The middle target (6H-7H-8H) can't extend in place
    # — the adjacent K-set would overlap. There's no room in
    # the row itself to move the target; the pre-move has to
    # go to another row. Tests vertical relocation decision.
    return puzzle(
        name="packed_row",
        title="Packed row",
        description=(
            "Hand has 9H. Four 3-card stacks sit tiled across the "
            "top row of the board, leaving no gap big enough to "
            "host a 4-card merged stack. The 6H-7H-8H run is "
            "between the 2-set and the K-set; extending it in "
            "place would overlap the Ks. The pre-move has to "
            "leave the top row — where does it go?"
        ),
        board=[
            stack("2S 2H 2D", at=(80, 50)),
            stack("6H 7H 8H", at=(80, 220)),
            # merged 4-card right = 220+126 = 346. K-set at 350
            # = gap of 4 (< BOARD_MARGIN=5, forcing relocation).
            stack("KC KH KD", at=(80, 350)),
            stack("9C 9D 9S", at=(80, 500)),
        ],
        player_hand=hand("9H"),
    )


def _no_room_at_the_top():
    # Agent v2's HUMAN_PREFERRED_ORIGIN = (50, 90). A 3-set
    # parked right there forces the scan to fall through to
    # a non-default spot. Human will land somewhere the scan
    # logic won't predict — the comparison is the study
    # signal.
    return puzzle(
        name="no_room_at_the_top",
        title="No room at the top",
        description=(
            "Hand has 9H. Same 'right-edge overflow' pattern as "
            "Tight right edge — but the top-left preferred "
            "landing zone is occupied by a 3-set of Aces. The "
            "pre-move can't default to its usual spot; the scan "
            "has to land somewhere less obvious. Where feels "
            "right to you?"
        ),
        board=[
            # Park the preferred zone (50, 90).
            stack("AC AH AD", at=(90, 60)),
            stack("6H 7H 8H", at=(80, 695)),
        ],
        player_hand=hand("9H"),
    )


def catalog():
    """Ordered list of board-lab puzzles. Order matters — it's the
    order panels appear on the page. New puzzles are appended
    rather than interleaved so the corpus grows by accretion;
    sessions captured against old ordering still match by
    `puzzle_name`."""
    return [
        _pair_peel(),
        _tight_right_edge(),
        _split_for_set(),
        _peel_for_run(),
        _follow_up_merge(),
        _corner_blocked(),
        _multi_corner_blocked(),
        _wide_eventual(),
        _interfering_neighbor(),
        _packed_row(),
        _no_room_at_the_top(),
    ]


def to_json():
    return json.dumps({"puzzles": catalog()}, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--write",
        metavar="PATH",
        help="Write the catalog JSON to PATH. "
             "Prints to stdout if omitted.",
    )
    args = parser.parse_args()

    out = to_json()
    if args.write:
        os.makedirs(os.path.dirname(os.path.abspath(args.write)), exist_ok=True)
        with open(args.write, "w") as f:
            f.write(out)
            f.write("\n")
        print(f"Wrote {args.write} ({len(out)} bytes)", file=sys.stderr)
    else:
        print(out)


if __name__ == "__main__":
    main()
