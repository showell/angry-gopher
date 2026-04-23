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
    # pre-move even though there's no trick complexity.
    #
    # Design math for the gap between the two stacks (target's
    # right edge to neighbor's left edge):
    #   - >= 10 for visual distinguishability (the referee's
    #     min-gap is actually 5, but that reads as overlap to
    #     humans; gap >= 20 looks genuinely separate).
    #   - < (card_width + 2*margin) = 37 so no new card stack
    #     could be legally inserted between — the neighbor
    #     isn't just visually tight, it's spatially committed.
    #   - < (card_pitch + 2*margin) = 43 so the EVENTUAL
    #     4-card merged stack overflows the neighbor, making
    #     the pre-move mandatory.
    # gap = 30 satisfies all three.
    return puzzle(
        name="interfering_neighbor",
        title="Interfering neighbor",
        description=(
            "Hand has 9H. The 6H-7H-8H run sits in the middle of "
            "the board with a 3-set of 4s a card-width away on "
            "its right — clearly distinguishable as two stacks, "
            "but too close for a merged 4-card run to fit in "
            "place. Even this simple direct-play needs a pre-move "
            "when the neighbor's in the way."
        ),
        board=[
            stack("6H 7H 8H", at=(120, 300)),
            # Target right edge = 300+93 = 393. Neighbor at 423.
            # gap = 30 (legal, visually clear, can't host a card,
            # merge overflows).
            stack("4C 4H 4D", at=(120, 423)),
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


# --- Crowded-target batch (2026-04-23) -------------------------
#
# 25 puzzles built around the fundamental crowding problem: the
# target stack has a neighbor on the growth side, and the move
# can't happen in place. The escape is always to pre-move either
# the target, the blocking neighbor, or (when applicable) to
# pick a different legal target.
#
# Coordinate conventions used below:
#   - 3-card stack width = 93 px; 4-card = 126 px.
#   - A neighbor at gap=30 px from a 3-card target's right edge
#     makes a 4-card merge overflow (target ends at +126,
#     neighbor starts at +123) — forcing a pre-move.
#   - Rows at top=120 / 240 / 400 give three clear bands.
#
# Puzzles are designed so the RELEVANT crowding is on the
# growth side of the target. Far-corner stacks are
# distractors, not obstacles.


def _crowded_merge_hand_right():
    return puzzle(
        name="crowded_merge_hand_right",
        title="Merge-hand with right-blocked target",
        description=(
            "Hand has 7C. The target 4C-5C-6C has a 3-set of 8s "
            "sitting just to its right — close enough that the "
            "4-card merged run would overlap."
        ),
        board=[
            stack("4C 5C 6C", at=(120, 200)),
            stack("8D 8H 8S", at=(120, 323)),
        ],
        player_hand=hand("7C"),
    )


def _crowded_merge_hand_left():
    return puzzle(
        name="crowded_merge_hand_left",
        title="Merge-hand with left-blocked target",
        description=(
            "Hand has 9D. The target TD-JD-QD wants an 8D on its "
            "left, but a set of 2s is already there."
        ),
        board=[
            stack("2C 2H 2S", at=(120, 170)),
            stack("TD JD QD", at=(120, 293)),
        ],
        player_hand=hand("9D"),
    )


def _crowded_merge_hand_wedged():
    return puzzle(
        name="crowded_merge_hand_wedged",
        title="Merge-hand with target wedged both sides",
        description=(
            "Hand has 5S. The 6S-7S-8S target is sandwiched "
            "between neighbors on both sides. Either direction of "
            "growth would overlap something."
        ),
        board=[
            stack("KC KD KH", at=(120, 200)),
            stack("6S 7S 8S", at=(120, 323)),
            stack("AC AD AH", at=(120, 446)),
        ],
        player_hand=hand("5S"),
    )


def _crowded_follow_up_right():
    return puzzle(
        name="crowded_follow_up_right",
        title="Follow-up merge, right-blocked",
        description=(
            "Two heart fragments on the board — 2H-3H-4H and "
            "5H-6H-7H — should chain into one. The target on the "
            "left is blocked on its right by a set of Queens."
        ),
        board=[
            stack("2H 3H 4H", at=(120, 100)),
            stack("QC QD QS", at=(120, 223)),
            stack("5H 6H 7H", at=(280, 450)),
        ],
        player_hand=hand(""),
    )


def _crowded_follow_up_left():
    return puzzle(
        name="crowded_follow_up_left",
        title="Follow-up merge, left-blocked",
        description=(
            "Two spade fragments should chain: 2S-3S-4S and "
            "5S-6S-7S. The low-end target has a set of Queens "
            "to its left, so the growing stack can't shift "
            "that way."
        ),
        board=[
            stack("QC QD QH", at=(120, 200)),
            stack("2S 3S 4S", at=(120, 323)),
            stack("5S 6S 7S", at=(280, 500)),
        ],
        player_hand=hand(""),
    )


def _crowded_follow_up_wedge():
    return puzzle(
        name="crowded_follow_up_wedge",
        title="Follow-up merge with wedged receiver",
        description=(
            "Two diamond fragments (2D-3D-4D and 5D-6D-7D) want "
            "to chain into one 6-card run. The receiver on the "
            "main row is fenced in on both sides — it has to "
            "move before it can absorb anything."
        ),
        board=[
            stack("8C 8H 8S", at=(120, 200)),
            stack("5D 6D 7D", at=(120, 323)),
            stack("9C 9H 9S", at=(120, 446)),
            stack("2D 3D 4D", at=(280, 100)),
        ],
        player_hand=hand(""),
    )


def _crowded_direct_play_right():
    return puzzle(
        name="crowded_direct_play_right",
        title="Direct play, right-blocked",
        description=(
            "Hand has TS. The 7S-8S-9S run sits at mid-board; a "
            "set of 3s sits a hand-width to the right, so "
            "dropping TS onto the end in place would overlap."
        ),
        board=[
            stack("7S 8S 9S", at=(160, 250)),
            stack("3C 3D 3H", at=(160, 373)),
        ],
        player_hand=hand("TS"),
    )


def _crowded_direct_play_left():
    return puzzle(
        name="crowded_direct_play_left",
        title="Direct play, left-blocked",
        description=(
            "Hand has AD. The AS-AH-AC set is ready to accept a "
            "fourth Ace — but it sits just to the right of a "
            "short run. Extending to the left isn't on."
        ),
        board=[
            stack("5C 6C 7C", at=(180, 200)),
            stack("AS AH AC", at=(180, 323)),
        ],
        player_hand=hand("AD"),
    )


def _crowded_direct_play_alt_target():
    return puzzle(
        name="crowded_direct_play_alt_target",
        title="Direct play with a clean alternative",
        description=(
            "Hand has 6H. Two legal targets exist: a heart run "
            "5H-4H-3H at the top (crowded by a K-set) and a "
            "different heart pairing 6C-6D-6S at the bottom "
            "(wide open). Pick where to play."
        ),
        board=[
            stack("3H 4H 5H", at=(120, 150)),
            stack("KC KD KH", at=(120, 273)),
            stack("6C 6D 6S", at=(380, 300)),
        ],
        player_hand=hand("6H"),
    )


def _crowded_pair_peel_receiver():
    return puzzle(
        name="crowded_pair_peel_receiver",
        title="Pair peel, receiver crowded",
        description=(
            "Hand has two 7s. Peel 7C from a 4-card club run and "
            "merge with the pair for a 3-set of 7s. The 7s-pair "
            "receiver has a neighbor on its right."
        ),
        board=[
            stack("5C 6C 7C 8C", at=(120, 200)),
            stack("TD TH TS", at=(300, 373)),
        ],
        player_hand=hand("7H 7S"),
    )


def _crowded_pair_peel_donor_wedged():
    return puzzle(
        name="crowded_pair_peel_donor_wedged",
        title="Pair peel, donor wedged",
        description=(
            "Hand has 4H and 4S. The 4C we want to peel sits at "
            "the end of a spade run, which is wedged between "
            "neighbors — moving the run first may be easier "
            "than trying to land the new 4-set beside it."
        ),
        board=[
            stack("2S 3S 4S 5S 6S", at=(120, 200)),
            stack("8C 8D 8H", at=(280, 100)),
            stack("QC QD QH", at=(280, 360)),
        ],
        player_hand=hand("4C 4D"),
    )


def _crowded_peel_for_run_target_blocked():
    return puzzle(
        name="crowded_peel_for_run_target_blocked",
        title="Peel-for-run, run target blocked",
        description=(
            "Hand has 9D and TD. Peel JD off the 4-set of Jacks "
            "and merge into a diamond run. The 9-T-J receiver "
            "will want room on the right, but a K-set is already "
            "there."
        ),
        board=[
            stack("JC JD JH JS", at=(120, 200)),
            stack("KC KD KH", at=(320, 250)),
            stack("5H 5D 5S", at=(420, 500)),
        ],
        player_hand=hand("9D TD"),
    )


def _crowded_peel_for_run_left_blocked():
    return puzzle(
        name="crowded_peel_for_run_left_blocked",
        title="Peel-for-run, left-blocked landing",
        description=(
            "Hand has QH and KH. Peel JH off a 4-set of Jacks "
            "and build J-Q-K of hearts. The natural landing "
            "zone for the run has a set of 2s pinning its "
            "left side."
        ),
        board=[
            stack("JC JD JH JS", at=(120, 200)),
            stack("2C 2D 2H", at=(320, 200)),
        ],
        player_hand=hand("QH KH"),
    )


def _crowded_split_for_set_target_blocked():
    return puzzle(
        name="crowded_split_for_set_target_blocked",
        title="Split-for-set, set-target crowded",
        description=(
            "Hand has 5H and 5D. Split 5C out of a long club run "
            "to form a set of 5s with the pair. The set target "
            "(hand pair) sits near a distractor stack on the "
            "right."
        ),
        board=[
            stack("2C 3C 4C 5C 6C 7C 8C", at=(120, 100)),
            stack("KC KD KH", at=(300, 400)),
        ],
        player_hand=hand("5H 5D"),
    )


def _crowded_split_for_set_left_blocked():
    return puzzle(
        name="crowded_split_for_set_left_blocked",
        title="Split-for-set, hand pair left-blocked",
        description=(
            "Hand has 6C and 6D. A 7-card heart run sits on "
            "the board; split 6H out of the middle to form a "
            "set of 6s with the pair. The hand-pair target has "
            "a distractor on its LEFT this time."
        ),
        board=[
            stack("KC KD KS", at=(320, 150)),
            stack("3H 4H 5H 6H 7H 8H 9H", at=(120, 100)),
        ],
        player_hand=hand("6C 6D"),
    )


def _crowded_rb_swap_receiver():
    return puzzle(
        name="crowded_rb_swap_receiver",
        title="Red-black swap, receiver crowded",
        description=(
            "Hand has 5D. A red-black run 3D-4C-5H wants an "
            "extension but needs a swap to accept 5D cleanly. "
            "The receiving run has a neighbor pinning its "
            "right side."
        ),
        board=[
            stack("3D 4C 5H", at=(160, 200)),
            stack("9C 9D 9S", at=(160, 323)),
        ],
        player_hand=hand("5D 6C"),
    )


def _crowded_twin_runs_one_crowded():
    return puzzle(
        name="crowded_twin_runs_one_crowded",
        title="Twin runs, one crowded",
        description=(
            "Hand has 8C. Two club-run targets exist: 5C-6C-7C "
            "(top, crowded by a set on its right) and a "
            "separate 9C-TC-JC (bottom, open). Both will "
            "accept the 8C."
        ),
        board=[
            stack("5C 6C 7C", at=(120, 100)),
            stack("4D 4H 4S", at=(120, 223)),
            stack("9C TC JC", at=(320, 400)),
        ],
        player_hand=hand("8C"),
    )


def _crowded_twin_sets_one_crowded():
    return puzzle(
        name="crowded_twin_sets_one_crowded",
        title="Twin sets, one crowded",
        description=(
            "Hand has 3D. Two 3-sets sit on the board: one at "
            "top-left with a neighbor blocking its right; one "
            "at bottom-right in open space."
        ),
        board=[
            stack("3C 3H 3S", at=(120, 100)),
            stack("8C 8D 8H", at=(120, 223)),
            stack("3C 3H 3S", at=(380, 500)),
        ],
        player_hand=hand("3D"),
    )


def _crowded_set_vs_run_pick_clean():
    return puzzle(
        name="crowded_set_vs_run_pick_clean",
        title="Set or run, pick the clean one",
        description=(
            "Hand has 7H. You could extend the crowded "
            "4H-5H-6H heart run (its right side is blocked) or "
            "join the spacious 7C-7S-7D set in open space. "
            "Either is legal — which reads as cleaner?"
        ),
        board=[
            stack("4H 5H 6H", at=(120, 200)),
            stack("KC KD KH", at=(120, 323)),
            stack("7C 7S 7D", at=(380, 400)),
        ],
        player_hand=hand("7H"),
    )


def _crowded_double_shove():
    return puzzle(
        name="crowded_double_shove",
        title="Two stacks in the way",
        description=(
            "Hand has 5H. The 2H-3H-4H target's right is "
            "blocked by two distractors in a row. Clearing "
            "room for the 4-card merge means moving both "
            "blocking stacks."
        ),
        board=[
            stack("2H 3H 4H", at=(120, 100)),
            stack("8C 8D 8S", at=(120, 223)),
            stack("JC JD JS", at=(120, 346)),
        ],
        player_hand=hand("5H"),
    )


def _crowded_cascade_merge():
    return puzzle(
        name="crowded_cascade_merge",
        title="Cascade merge",
        description=(
            "Hand has 5D. Merging it onto the 6D-7D-8D run "
            "makes a 5-6-7-8 chunk that then chains with the "
            "2D-3D-4D fragment. Both merges happen this turn; "
            "the second depends on the first."
        ),
        board=[
            stack("2D 3D 4D", at=(120, 100)),
            stack("6D 7D 8D", at=(320, 300)),
            stack("KS KD KH", at=(320, 500)),
        ],
        player_hand=hand("5D"),
    )


def _crowded_block_behind_block():
    return puzzle(
        name="crowded_block_behind_block",
        title="Block behind block",
        description=(
            "Hand has 9S. The 6S-7S-8S target needs room on "
            "its right, but the neighbor that's in the way "
            "has ITS OWN neighbor — you can't just shove the "
            "first one over."
        ),
        board=[
            stack("6S 7S 8S", at=(120, 150)),
            stack("4C 4D 4H", at=(120, 273)),
            stack("TD TH TS", at=(120, 396)),
        ],
        player_hand=hand("9S"),
    )


def _crowded_merge_into_big_stack():
    return puzzle(
        name="crowded_merge_into_big_stack",
        title="Big stack meets neighbor",
        description=(
            "Hand has 8D. The 3D-4D-5D-6D-7D 5-card run is "
            "already wide — adding 8D makes it 6 cards (192 "
            "px). A queen-set sits close on the right."
        ),
        board=[
            stack("3D 4D 5D 6D 7D", at=(120, 100)),
            stack("QC QH QS", at=(120, 289)),
        ],
        player_hand=hand("8D"),
    )


def _crowded_tight_gap_right():
    return puzzle(
        name="crowded_tight_gap_right",
        title="Tight gap, right-blocked",
        description=(
            "Hand has 8H. The 5H-6H-7H target has a neighbor "
            "very close on its right — barely legal, visually "
            "tight. Is there room for the 4-card merge, or not?"
        ),
        board=[
            stack("5H 6H 7H", at=(120, 200)),
            stack("9C 9D 9S", at=(120, 308)),
        ],
        player_hand=hand("8H"),
    )


def _crowded_loose_card_receiver_blocked():
    return puzzle(
        name="crowded_loose_card_receiver_blocked",
        title="Loose card, crowded receiver",
        description=(
            "Hand has KD. The K-set target is already 3 cards "
            "(KC-KH-KS) — ready for a fourth King. But its "
            "right neighbor leaves no room to grow."
        ),
        board=[
            stack("KC KH KS", at=(160, 250)),
            stack("5C 5D 5H", at=(160, 373)),
        ],
        player_hand=hand("KD"),
    )


def _crowded_hand_stacks():
    return puzzle(
        name="crowded_hand_stacks",
        title="Hand set into crowded row",
        description=(
            "Hand has 6C, 6D, and 6S. Landing the set next to "
            "an existing row on the board is the natural move, "
            "but the obvious slot is walled in by neighbors."
        ),
        board=[
            stack("JC JD JH", at=(120, 150)),
            stack("9C 9D 9S", at=(120, 273)),
            stack("3C 3D 3H", at=(120, 396)),
        ],
        player_hand=hand("6C 6D 6S"),
    )


def catalog():
    """Ordered list of board-lab puzzles. Order matters — it's the
    order panels appear on the page. New puzzles are appended
    rather than interleaved so the corpus grows by accretion;
    sessions captured against old ordering still match by
    `puzzle_name`.

    Validates that every puzzle's initial state passes the
    referee's geometry rule. Illegal states used to ship
    quietly (the new-puzzle-session endpoint only
    structurally-decodes); this catches them at build time so
    drift is impossible."""
    puzzles = [
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
        # Crowded-target batch (2026-04-23).
        _crowded_merge_hand_right(),
        _crowded_merge_hand_left(),
        _crowded_merge_hand_wedged(),
        _crowded_follow_up_right(),
        _crowded_follow_up_left(),
        _crowded_follow_up_wedge(),
        _crowded_direct_play_right(),
        _crowded_direct_play_left(),
        _crowded_direct_play_alt_target(),
        _crowded_pair_peel_receiver(),
        _crowded_pair_peel_donor_wedged(),
        _crowded_peel_for_run_target_blocked(),
        _crowded_peel_for_run_left_blocked(),
        _crowded_split_for_set_target_blocked(),
        _crowded_split_for_set_left_blocked(),
        _crowded_rb_swap_receiver(),
        _crowded_twin_runs_one_crowded(),
        _crowded_twin_sets_one_crowded(),
        _crowded_set_vs_run_pick_clean(),
        _crowded_double_shove(),
        _crowded_cascade_merge(),
        _crowded_block_behind_block(),
        _crowded_merge_into_big_stack(),
        _crowded_tight_gap_right(),
        _crowded_loose_card_receiver_blocked(),
        _crowded_hand_stacks(),
    ]
    _validate_catalog(puzzles)
    return puzzles


def _validate_catalog(puzzles):
    """Each puzzle's initial state must pass the referee's
    geometry check (no out-of-bounds stacks, no too-close
    neighbors). Raises on first violation with a pointer at
    the offending puzzle."""
    # Deferred import so `agent_board_lab.py`-style callers
    # don't pay the geometry module's import cost on
    # startup if they never touch the catalog.
    from geometry import find_violation
    for p in puzzles:
        board = p["initial_state"]["board"]
        bad = find_violation(board)
        if bad is not None:
            raise ValueError(
                f"Puzzle {p['name']!r} has an illegal initial "
                f"state — stack {bad} violates geometry. "
                f"Check loc values against BOARD_MARGIN and "
                f"neighbor gaps."
            )


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
