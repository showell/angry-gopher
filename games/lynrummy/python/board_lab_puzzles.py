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


def _corner_blocked():
    # Designed 2026-04-23 after observing that the agent's
    # find_open_loc always returns (7, 7) when a pre-move is
    # needed. Pre-placing a 3-set of 2s right at the corner
    # (loc 10, 10) forces the scan to land somewhere else.
    # Study signal: does the degraded choice still read as
    # "human-like"?
    return {
        "name": "corner_blocked",
        "title": "Corner blocked",
        "description": (
            "Hand has 9H. The 6H-7H-8H run at the right edge "
            "needs a pre-move before it can absorb the 9H — just "
            "like 'Tight right edge' — but the top-left corner is "
            "already occupied by a 3-set of 2s. Where does the "
            "moved run land this time?"
        ),
        "initial_state": _state(
            board=[
                _stack(10, 10,
                       _card(2, C), _card(2, H), _card(2, D)),
                _stack(80, 695,
                       _card(6, H), _card(7, H), _card(8, H)),
                _stack(260, 400,
                       _card(5, C), _card(5, H), _card(5, D)),
            ],
            hand=_hand(_card(9, H)),
        ),
    }


def _multi_corner_blocked():
    # Stress test: every "obvious" open spot is occupied.
    # Top-left, top-right, left-mid, middle-mid. The pre-move
    # must land in one of the narrow gaps. Agent's row-major
    # scan gets to pick between several awkward spots. Human
    # almost certainly picks the gap that feels balanced — a
    # clear study signal.
    return {
        "name": "multi_corner_blocked",
        "title": "Multi-corner blocked",
        "description": (
            "Hand has 9H. Same merge shape as 'Tight right edge' "
            "— 6H-7H-8H at the right needs a pre-move before 9H "
            "lands — but every corner and left-side edge already "
            "has a stack parked there. Find the least-awkward "
            "gap for the run's new home."
        ),
        "initial_state": _state(
            board=[
                _stack(10, 10,
                       _card(2, C), _card(2, H), _card(2, D)),
                _stack(10, 640,
                       _card(10, C), _card(10, H), _card(10, D)),
                _stack(220, 10,
                       _card(4, C), _card(4, H), _card(4, D)),
                _stack(220, 380,
                       _card(11, C), _card(11, H), _card(11, D)),
                _stack(80, 695,
                       _card(6, H), _card(7, H), _card(8, H)),
            ],
            hand=_hand(_card(9, H)),
        ),
    }


def _wide_eventual():
    # A 5-card run on the board wants one more card. The
    # merged stack will be 6 cards (192 px wide). Pre-placing
    # so that the EVENTUAL stack fits — not just the
    # current 5-card form — is the kind of lookahead
    # `_plan_merge_hand` exists for. Human's landing pad has
    # to be genuinely spacious; the corner can't absorb 192 px
    # wide without margin work.
    return {
        "name": "wide_eventual",
        "title": "Wide eventual",
        "description": (
            "Hand has 8H. The 3H-4H-5H-6H-7H run is already 5 "
            "cards wide and sits pinned against the right edge. "
            "Adding 8H makes it a 6-card stack (192 px). The "
            "pre-move has to land somewhere big enough for the "
            "EVENTUAL stack, not just the current one."
        ),
        "initial_state": _state(
            board=[
                _stack(80, 625,
                       _card(3, H), _card(4, H), _card(5, H),
                       _card(6, H), _card(7, H)),
                _stack(280, 260,
                       _card(12, C), _card(12, H), _card(12, D)),
            ],
            hand=_hand(_card(8, H)),
        ),
    }


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
