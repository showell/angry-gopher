"""
board_lab_puzzles.py — canonical catalog of BOARD_LAB puzzles.

Python is the source of truth. This module writes a JSON blob
that Go serves at `/gopher/board-lab/puzzles` and Elm fetches
on page load. Sessions (human and agent) are keyed by
`puzzle_name` in `lynrummy_puzzle_seeds` so `study.py` can
join both sides of a puzzle.

Each puzzle:

  - `name` — stable machine id (snake_case).
  - `title` — panel heading.
  - `description` — one-paragraph prompt shown in the panel.
  - `initial_state` — full lynrummy.State blob, POST-ready.

Run as a script to write the catalog JSON:

    python3 games/lynrummy/python/board_lab_puzzles.py \\
        --write games/lynrummy/board-lab/puzzles.json

Run with no args to print it to stdout.
"""

import argparse
import json
import os
import sys


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


# --- Puzzle builders ------------------------------------------
#
# Let a puzzle read close to how you'd describe it:
#   stack("6H 7H 8H", at=(80, 500))
#   hand("9H")


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


# --- Crowded-target batch (2026-04-23) -----------------------
#
# 14 distinct puzzles, each forcing a pre-move. Principles
# for adding more:
#
#   - "Neighbor on one side" isn't crowding if the hand card
#     can attach to the OTHER side. Real crowding needs the
#     hand card's VALUE to force a specific attachment (for
#     runs) OR both sides blocked (for sets / merged-stack
#     footprints that exceed either direction).
#   - Gaps of 30 px read as roomy. Tight interference wants
#     gap ~15 px — barely legal at margin=7 but visually too
#     close for the merged stack.
#   - Splits need VERTICAL neighbors: the extracted card
#     stays in-row and has to be routed somewhere.
#
# Distinct spatial decisions, one per puzzle:
#   1  Wedged run, hand value-forces right attach
#   2  Right-edge pinch — merge overflows the board
#   3  Single-side block, hand value forces the blocked side
#   4  Follow-up merge with wedged receiver
#   5  Follow-up merge with pinned source (must escape its row)
#   6  Double-shove — two blockers in a row
#   7  Block-behind-block — blocker pinned by its own neighbor
#   8  Cascade: place hand card to enable a follow-up merge
#   9  Both legal targets crowded — pick which to clear
#  10  Big-stack footprint (5→6 card merge overflows)
#  11  Split-for-set with vertical neighbor above split
#  12  Neighbor-as-candidate — the "blocker" is a merge option
#  13  Middle target between two merge candidates — order choice
#  14  Wedge requires vertical relocation (row fully packed)


def _wedged_run_right_forced():
    # Hand=8H forces right attach; target 5H-6H-7H wedged
    # between neighbors on both sides at tight gaps. Must
    # pre-move target out of the row entirely.
    return puzzle(
        name="wedged_run_right_forced",
        title="Wedged run, 8H forces right attach",
        description=(
            "Hand has 8H. The 5H-6H-7H target sits in the middle "
            "row with neighbors pressed tight against both sides. "
            "8H only attaches to the RIGHT end of the run — and "
            "that side has a set of Jacks in the way."
        ),
        board=[
            stack("QC QD QS", at=(120, 192)),
            stack("5H 6H 7H", at=(120, 300)),
            stack("JC JD JS", at=(120, 408)),
        ],
        player_hand=hand("8H"),
    )


def _right_edge_pinch():
    # Target close enough to the right edge that adding one
    # card pushes the merged stack past maxWidth=800. Pre-move
    # isn't about a neighbor — it's about the board boundary.
    return puzzle(
        name="right_edge_pinch",
        title="Right-edge pinch",
        description=(
            "Hand has 9D. The 6D-7D-8D target is pressed against "
            "the right edge of the board — adding 9D in place "
            "would push the merged stack off the board entirely. "
            "The target has to move first."
        ),
        board=[
            stack("6D 7D 8D", at=(120, 700)),
            stack("KC KD KS", at=(320, 60)),
        ],
        player_hand=hand("9D"),
    )


def _value_forces_blocked_side():
    # Single-side block where the hand card's VALUE forces
    # attachment on the blocked side. The alternate side is
    # clean but irrelevant — 6H can't join a run's high end.
    return puzzle(
        name="value_forces_blocked_side",
        title="Hand value forces the blocked side",
        description=(
            "Hand has 6H. The 7H-8H-9H target needs 6H on its "
            "LEFT (the low end) — but a set of Queens sits "
            "tight against that side. The target's right side "
            "is wide open, but 6H doesn't fit there."
        ),
        board=[
            stack("QC QD QS", at=(120, 192)),
            stack("7H 8H 9H", at=(120, 300)),
        ],
        player_hand=hand("6H"),
    )


def _follow_up_wedged_receiver():
    # Receiver wedged between neighbors at tight gaps. Source
    # fragment sits elsewhere. Receiver must move before it
    # can absorb source.
    return puzzle(
        name="follow_up_wedged_receiver",
        title="Follow-up merge, receiver wedged",
        description=(
            "Two heart fragments want to chain: 5H-6H-7H (receiver, "
            "wedged between neighbors) and 2H-3H-4H (elsewhere). "
            "The receiver has to move out of its row before it "
            "can grow."
        ),
        board=[
            stack("QC QD QS", at=(120, 192)),
            stack("5H 6H 7H", at=(120, 300)),
            stack("JC JD JS", at=(120, 408)),
            stack("2H 3H 4H", at=(320, 100)),
        ],
        player_hand=hand(""),
    )


def _follow_up_pinned_source():
    # Source 2S-3S-4S pinned between neighbors at tight gaps.
    # Receiver 5S-6S-7S elsewhere. The source must escape its
    # row before it can go merge with the receiver.
    return puzzle(
        name="follow_up_pinned_source",
        title="Follow-up merge, source pinned",
        description=(
            "Two spade fragments want to chain: 2S-3S-4S (pinned "
            "between neighbors in its row) and 5S-6S-7S (free). "
            "The source has to escape its row to reach the "
            "receiver."
        ),
        board=[
            stack("AC AD AH", at=(240, 192)),
            stack("2S 3S 4S", at=(240, 300)),
            stack("TC TD TH", at=(240, 408)),
            stack("5S 6S 7S", at=(80, 500)),
        ],
        player_hand=hand(""),
    )


def _double_shove():
    # Two blockers in a row at tight gap. The merged target
    # becomes 5 cards wide; neither blocker alone can be
    # slid sideways enough to make room, so at least one
    # must leave the row.
    return puzzle(
        name="double_shove",
        title="Double shove",
        description=(
            "Hand has 6C. The 2C-3C-4C-5C target is already 4 "
            "cards; adding 6C makes it 5. Two 3-sets sit tight "
            "to its right, filling the rest of the row. Making "
            "room demands moving multiple stacks."
        ),
        board=[
            stack("2C 3C 4C 5C", at=(120, 100)),
            stack("8D 8H 8S", at=(120, 241)),
            stack("JC JD JH", at=(120, 349)),
        ],
        player_hand=hand("6C"),
    )


def _block_behind_block():
    # The immediate blocker is itself pinned on its right by
    # another stack, so you can't just slide it. It has to
    # leave the row. Tests whether the player sees past the
    # first-layer obstacle.
    return puzzle(
        name="block_behind_block",
        title="Block behind block",
        description=(
            "Hand has 8H. The 5H-6H-7H target wants growth on "
            "its right, but the blocker there has its OWN tight "
            "neighbor — you can't just shove the first blocker "
            "sideways. Something has to leave the row."
        ),
        board=[
            stack("5H 6H 7H", at=(120, 150)),
            stack("4C 4D 4S", at=(120, 258)),
            stack("9S 9H 9C", at=(120, 366)),
        ],
        player_hand=hand("8H"),
    )


def _cascade_place_then_follow_up():
    # Hand card placement links two board fragments. One
    # move (merge_hand) creates the 4-card stack; a second
    # (merge_stack) chains it with the far fragment.
    return puzzle(
        name="cascade_place_then_follow_up",
        title="Place, then follow-up merge",
        description=(
            "Hand has 5D. Adding it to 2D-3D-4D (left) gives "
            "2-3-4-5, which then chains with the 6D-7D-8D "
            "fragment (right) for a 6-card diamond run. Two "
            "merges, one turn."
        ),
        board=[
            stack("2D 3D 4D", at=(120, 80)),
            stack("6D 7D 8D", at=(340, 400)),
            stack("KS KH KC", at=(340, 600)),
        ],
        player_hand=hand("5D"),
    )


def _both_targets_crowded():
    # Two legal homes for 7H exist: extend a crowded heart run
    # or join a crowded 7-set. Both require clearing a
    # neighbor. Which is easier?
    return puzzle(
        name="both_targets_crowded",
        title="Both targets crowded",
        description=(
            "Hand has 7H. You could extend the crowded 4H-5H-6H "
            "run (blocked right) or join the crowded 7C-7D-7S "
            "set (blocked left). Both homes are legal, both "
            "need clearing."
        ),
        board=[
            stack("4H 5H 6H", at=(120, 150)),
            stack("KC KD KH", at=(120, 258)),
            stack("2C 2D 2H", at=(320, 150)),
            stack("7C 7D 7S", at=(320, 258)),
        ],
        player_hand=hand("7H"),
    )


def _big_stack_footprint_overflow():
    # 5-card target fits in place comfortably. But adding one
    # more card makes it a 6-card (192 px) stack that
    # overflows the right-neighbor. Decision is specifically
    # about FUTURE footprint, not current one.
    return puzzle(
        name="big_stack_footprint_overflow",
        title="Big stack footprint overflow",
        description=(
            "Hand has 8D. The 3D-4D-5D-6D-7D run (5 cards) sits "
            "comfortably in place RIGHT NOW — but adding 8D "
            "stretches it to 6 cards wide, enough to overlap "
            "the Queen-set to its right."
        ),
        board=[
            stack("3D 4D 5D 6D 7D", at=(120, 200)),
            stack("QC QH QS", at=(120, 374)),
        ],
        player_hand=hand("8D"),
    )


def _split_with_vertical_neighbor():
    # Steve's guidance: splits need VERTICAL neighbors to be
    # crowded, since the extracted card stays in its row and
    # the player has to route it somewhere. A K-set parked
    # right above the split position blocks the natural
    # upward route.
    return puzzle(
        name="split_with_vertical_neighbor",
        title="Split-for-set, vertical neighbor blocks route",
        description=(
            "Hand has 6C and 6D. Split 6H out of the middle of "
            "a 7-card heart run to form a set of 6s with the "
            "pair. A K-set sits DIRECTLY ABOVE the split — "
            "routing the extracted card upward is blocked."
        ),
        board=[
            stack("KC KD KS", at=(145, 200)),
            stack("3H 4H 5H 6H 7H 8H 9H", at=(200, 100)),
        ],
        player_hand=hand("6C 6D"),
    )


def _neighbor_as_candidate():
    # The "blocker" right next to the target is actually a
    # merge partner, not an obstacle — a 4H-5H-6H target has
    # a 7H-8H-9H stack tight on its right. Merging them is
    # free and trivial. Tests recognition that
    # spatially-adjacent doesn't mean obstructive.
    return puzzle(
        name="neighbor_as_candidate",
        title="The neighbor isn't a blocker, it's a merge",
        description=(
            "Two heart fragments sit tight against each other: "
            "4H-5H-6H and 7H-8H-9H. Visually this LOOKS like "
            "a crowded target with a right-side neighbor — but "
            "the neighbor is actually a merge partner."
        ),
        board=[
            stack("4H 5H 6H", at=(120, 200)),
            stack("7H 8H 9H", at=(120, 308)),
        ],
        player_hand=hand(""),
    )


def _middle_target_two_candidates():
    # Target sits between two fragments that both chain with
    # it. Player chooses merge order: left-first or right-
    # first. Spatial efficiency (which direction of movement
    # is shorter) should drive the choice.
    return puzzle(
        name="middle_target_two_candidates",
        title="Target between two merge candidates",
        description=(
            "Three heart fragments on the board: 2H-3H-4H, "
            "5H-6H-7H, and 8H-9H-TH. All chain into a single "
            "run. Which pair merges first?"
        ),
        board=[
            stack("2H 3H 4H", at=(120, 100)),
            stack("5H 6H 7H", at=(280, 350)),
            stack("8H 9H TH", at=(440, 600)),
        ],
        player_hand=hand(""),
    )


def _wedge_needs_vertical_move():
    # Target wedged between tight neighbors in a row that is
    # ALSO horizontally packed — there's no lateral space to
    # relocate to. The pre-move has to go to a different row
    # entirely. Tests the vertical-relocation decision in
    # isolation.
    return puzzle(
        name="wedge_needs_vertical_move",
        title="Wedged target, row is full — go vertical",
        description=(
            "Hand has 5C. The 2C-3C-4C target is flanked on "
            "both sides by neighbors, and the rest of its row "
            "is packed with more stacks. Adding 5C needs a "
            "4-card footprint the row can't provide; the move "
            "has to leave the row entirely."
        ),
        board=[
            stack("8D 8H 8S", at=(120, 80)),
            stack("2C 3C 4C", at=(120, 188)),
            stack("JC JD JH", at=(120, 296)),
            stack("QC QD QH", at=(120, 404)),
            stack("KC KD KH", at=(120, 512)),
        ],
        player_hand=hand("5C"),
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
        # Crowded-target batch v2 (2026-04-23). 15 distinct
        # spatial-decision puzzles, carefully crafted —
        # no repeat shapes.
        _wedged_run_right_forced(),
        _right_edge_pinch(),
        _value_forces_blocked_side(),
        _follow_up_wedged_receiver(),
        _follow_up_pinned_source(),
        _double_shove(),
        _block_behind_block(),
        _cascade_place_then_follow_up(),
        _both_targets_crowded(),
        _big_stack_footprint_overflow(),
        _split_with_vertical_neighbor(),
        _neighbor_as_candidate(),
        _middle_target_two_candidates(),
        _wedge_needs_vertical_move(),
    ]
    _validate_catalog(puzzles)
    # Prefix each title with its 1-indexed catalog position so
    # Steve can refer to puzzles by number in annotations
    # ("#7 was unexpected") and I can resolve that back to the
    # panel without eyeballing the gallery.
    for i, p in enumerate(puzzles, start=1):
        p["title"] = f"#{i}. {p['title']}"
    return puzzles


def _validate_catalog(puzzles):
    """Each puzzle must (a) pass the referee's geometry check
    and (b) have a trick or follow-up merge the agent actually
    recognizes. (b) exists because BOARD_LAB studies spatial
    EXECUTION of tricks the agent would play — a puzzle the
    agent can't even fire is out of scope and would waste
    Steve's play time. Added after one such puzzle shipped,
    got played, and generated ~30 minutes of useless
    annotation. Raises on first violation."""
    # Deferred imports so `agent_board_lab.py`-style callers
    # don't pay geometry/strategy import costs on startup if
    # they never touch the catalog.
    from geometry import find_violation
    import strategy

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
        hand = [hc["card"] if "card" in hc else hc
                for hc in p["initial_state"]["hands"][0]["hand_cards"]]
        hand_wrapped = p["initial_state"]["hands"][0]["hand_cards"]
        play = strategy.choose_play(hand_wrapped, board)
        follow_ups = strategy.find_follow_up_merges(board)
        if play is None and not follow_ups:
            raise ValueError(
                f"Puzzle {p['name']!r} has no trick the agent "
                f"recognizes — neither choose_play nor "
                f"find_follow_up_merges fires on the initial "
                f"state. Either rework the hand/board so a "
                f"known trick applies, or drop the puzzle; "
                f"BOARD_LAB studies spatial EXECUTION of "
                f"agent-playable tricks, not missing tricks."
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
