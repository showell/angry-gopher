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


def _card(value, suit, deck=0):
    return {"value": value, "suit": suit, "origin_deck": deck}


def _board_card(c):
    return {"card": c, "state": 0}


def _hand_card(c):
    return {"card": c, "state": 0}


def _stack(top, left, *cards):
    return {
        "board_cards": [_board_card(c) for c in cards],
        "loc": {"top": top, "left": left},
    }


def _hand(*cards):
    return {"hand_cards": [_hand_card(c) for c in cards]}


def _state(board, hand):
    """Wrap a (board, hand) into a full lynrummy.State blob. The
    lab is always within-a-turn, so scores/deck/etc. take
    neutral defaults."""
    return {
        "board": board,
        "hands": [hand, {"hand_cards": []}],
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
    return {
        "name": "pair_peel",
        "title": "Pair peel",
        "description": (
            "Hand has two 3s. The board has a 4-card pure club run "
            "with 3C at one end. Peel the 3C off the run and merge "
            "it with your pair to form a 3-set of 3s."
        ),
        "initial_state": _state(
            board=[
                _stack(100, 200,
                       _card(3, C), _card(4, C), _card(5, C), _card(6, C)),
            ],
            hand=_hand(_card(3, S), _card(3, D)),
        ),
    }


def _tight_right_edge():
    return {
        "name": "tight_right_edge",
        "title": "Tight right edge",
        "description": (
            "Hand has 9H. The 6H-7H-8H run sits hard against the "
            "right edge — dropping 9H onto it in place would push "
            "the merged stack off the board. You need to MoveStack "
            "the run to a clearer spot first, then merge. Two other "
            "stacks sit on the board too, so the choice of where to "
            "move is a spatial call."
        ),
        "initial_state": _state(
            board=[
                _stack(80, 695,
                       _card(6, H), _card(7, H), _card(8, H)),
                _stack(80, 400,
                       _card(5, C), _card(5, D), _card(5, S)),
                _stack(280, 100,
                       _card(2, S), _card(3, S), _card(4, S)),
            ],
            hand=_hand(_card(9, H)),
        ),
    }


def _split_for_set():
    return {
        "name": "split_for_set",
        "title": "Split for set",
        "description": (
            "Hand has 5H and 5D. The board has a 7-card pure club "
            "run with 5C in the middle. Extract 5C via a mid-run "
            "split and merge the three 5s into a set."
        ),
        "initial_state": _state(
            board=[
                _stack(100, 100,
                       _card(2, C), _card(3, C), _card(4, C),
                       _card(5, C),
                       _card(6, C), _card(7, C), _card(8, C)),
            ],
            hand=_hand(_card(5, H), _card(5, D)),
        ),
    }


def _peel_for_run():
    return {
        "name": "peel_for_run",
        "title": "Peel for run",
        "description": (
            "Hand has 8S and 9S. The board has a 4-set of 7s. Peel "
            "7S off the set (leaving a valid 3-set behind) and "
            "merge with 8S-9S to form a pure run."
        ),
        "initial_state": _state(
            board=[
                _stack(100, 180,
                       _card(7, S), _card(7, H),
                       _card(7, D), _card(7, C)),
            ],
            hand=_hand(_card(8, S), _card(9, S)),
        ),
    }


def _follow_up_merge():
    return {
        "name": "follow_up_merge_chained_runs",
        "title": "Follow-up merge (chained runs)",
        "description": (
            "Hand has 6H. Two heart runs sit on the board: "
            "3H-4H-5H and 7H-8H-9H. Merging 6H onto the low run "
            "makes it 3-4-5-6 — which now chains with 7-8-9. "
            "Two merges, one turn."
        ),
        "initial_state": _state(
            board=[
                _stack(80, 120,
                       _card(3, H), _card(4, H), _card(5, H)),
                _stack(260, 480,
                       _card(7, H), _card(8, H), _card(9, H)),
            ],
            hand=_hand(_card(6, H)),
        ),
    }


def catalog():
    """Ordered list of board-lab puzzles. Order matters — it's the
    order panels appear on the page."""
    return [
        _pair_peel(),
        _tight_right_edge(),
        _split_for_set(),
        _peel_for_run(),
        _follow_up_merge(),
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
