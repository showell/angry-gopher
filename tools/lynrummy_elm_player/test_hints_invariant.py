"""
test_hints_invariant.py — plain-Python test harness for the
"tricks leave a clean board" contract.

Each test case is a (hand, board) input for a specific trick
emitter in hints.py. If the emitter returns a primitive
sequence, this harness applies it to the input state and
asserts every resulting stack classifies as a valid complete
group (set / pure_run / rb_run). Anything else (singletons,
2-card pairs, gap pairs, bogus stacks) fails the test.

No framework. Run directly:

    python3 tools/lynrummy_elm_player/test_hints_invariant.py
"""

import sys

from puzzles import stack, hand, base_state
import hints


# --- Applying a sequence to a board -----------------------------

def _apply_sequence(state, prims):
    board = hints._copy_board(state["board"])
    for p in prims:
        kind = p.get("action")
        if kind == "split":
            board = hints._apply_split(board, p["stack_index"], p["card_index"])
        elif kind == "move_stack":
            board = hints._apply_move(board, p["stack_index"], p["new_loc"])
        elif kind == "merge_stack":
            board = hints._apply_merge_stack(
                board, p["source_stack"], p["target_stack"],
                p.get("side", "right"))
        elif kind == "merge_hand":
            board = hints._apply_merge_hand(
                board, p["target_stack"], p["hand_card"],
                p.get("side", "right"))
        elif kind == "place_hand":
            board = hints._apply_place_hand(
                board, p["hand_card"], p["loc"])
    return board


def _fmt(c):
    vals = {1: "A", 10: "T", 11: "J", 12: "Q", 13: "K"}
    suits = "CDSH"
    return f"{vals.get(c['value'], str(c['value']))}{suits[c['suit']]}"


def _fmt_stack(stack):
    return "[" + ",".join(_fmt(bc["card"]) for bc in stack["board_cards"]) + "]"


def _check(trick_name, case_name, emitter, state):
    hand_cards = state["hands"][state["active_player_index"]]["hand_cards"]
    board = state["board"]
    prims = emitter(hand_cards, board)
    if prims is None:
        return False, "emitter returned None (trick did not fire)"
    try:
        final = _apply_sequence(state, prims)
    except (IndexError, KeyError) as e:
        return False, f"simulation crashed: {type(e).__name__}: {e}"
    for i, s in enumerate(final):
        cards = [bc["card"] for bc in s["board_cards"]]
        if hints._classify(cards) == "other":
            return False, (
                f"stack {i} ({_fmt_stack(s)}) is incomplete after "
                f"sequence of {len(prims)} primitives"
            )
    return True, f"OK — {len(prims)} primitives, {len(final)} clean stacks"


# --- Test cases -------------------------------------------------

CASES = []

def add(trick_name, case_name, emitter, state):
    CASES.append((trick_name, case_name, emitter, state))


# direct_play -----------------------------------------------------

add("direct_play", "extend_pure_run",
    hints.direct_play,
    base_state(
        board=[stack(40, 40, "6D", "7D", "8D"),
               stack(180, 40, "AC", "2C", "3C")],
        active_hand=hand("9D"),
    ))

add("direct_play", "complete_set",
    hints.direct_play,
    base_state(
        board=[stack(40, 40, "5H", "5C", "5S")],
        active_hand=hand("5D"),
    ))


# hand_stacks -----------------------------------------------------

add("hand_stacks", "set_three_of_a_kind",
    hints.hand_stacks,
    base_state(
        board=[stack(40, 40, "JC", "QC", "KC")],
        active_hand=hand("4H", "4S", "4D"),
    ))

add("hand_stacks", "pure_run_three_card",
    hints.hand_stacks,
    base_state(
        board=[stack(40, 40, "JC", "QC", "KC")],
        active_hand=hand("5H", "6H", "7H"),
    ))

add("hand_stacks", "rb_run_three_card",
    hints.hand_stacks,
    base_state(
        board=[stack(40, 40, "JC", "QC", "KC")],
        active_hand=hand("5H", "6C", "7H"),
    ))


# pair_peel -------------------------------------------------------

add("pair_peel", "set_pair_edge",
    hints.pair_peel,
    base_state(
        board=[stack(40, 40, "5D", "6D", "7D", "8D")],
        active_hand=hand("5H", "5S"),
    ))

add("pair_peel", "run_pair_pure_edge",
    hints.pair_peel,
    base_state(
        board=[stack(40, 40, "7H", "8H", "9H", "TH")],
        active_hand=hand("5H", "6H"),
    ))

add("pair_peel", "set_pair_middle",
    hints.pair_peel,
    base_state(
        # 7-run diamonds, 5D at ci=2 — not extractable (ci<3).
        # Try 8-run with 5D at ci=3 instead.
        board=[stack(40, 40, "2D", "3D", "4D", "5D", "6D", "7D", "8D", "9D")],
        active_hand=hand("5H", "5S"),
    ))


# split_for_set ---------------------------------------------------

add("split_for_set", "both_edges",
    hints.split_for_set,
    base_state(
        board=[stack(40,  40, "5D", "6D", "7D", "8D"),
               stack(40, 300, "5S", "6S", "7S", "8S")],
        active_hand=hand("5H"),
    ))

add("split_for_set", "one_middle_one_edge",
    hints.split_for_set,
    base_state(
        board=[stack(40,  40, "2D", "3D", "4D", "5D", "6D", "7D", "8D", "9D"),
               stack(40, 400, "5S", "6S", "7S", "8S")],
        active_hand=hand("5H"),
    ))


# peel_for_run ----------------------------------------------------

add("peel_for_run", "rb_edges",
    hints.peel_for_run,
    base_state(
        # Clubs runs force RB-style trio; direct_play can't fire
        # because hand is diamond, neither run suit-compatible.
        board=[stack(40,  40, "6C", "7C", "8C", "9C"),
               stack(40, 300, "JC", "QC", "KC", "AC")],
        active_hand=hand("TD"),
    ))


# rb_swap ---------------------------------------------------------

add("rb_swap", "middle_swap_clubs_home",
    hints.rb_swap,
    base_state(
        # rb-run [3D, 4C, 5D, 6C]; hand 4S (same color as 4C,
        # different suit); 4C's home is [AC, 2C, 3C] pure clubs.
        board=[stack(40,  40, "3D", "4C", "5D", "6C"),
               stack(40, 300, "AC", "2C", "3C"),
               stack(180, 40, "9H", "TH", "JH")],
        active_hand=hand("4S"),
    ))


# loose_card_play -------------------------------------------------
# Deliberately omitted — triggering loose_card_play as top-priority
# requires a state where no higher-priority trick fires, and those
# scenarios are delicate to construct. Add cases as specific
# scenarios surface in real gameplay.


# --- Runner -----------------------------------------------------

def main():
    passed = 0
    failed = 0
    for trick, name, emitter, state in CASES:
        ok, msg = _check(trick, name, emitter, state)
        status = "PASS" if ok else "FAIL"
        if ok:
            passed += 1
        else:
            failed += 1
        print(f"{status}  {trick}:{name:<26}  {msg}")
    print()
    print(f"{passed}/{passed + failed} passed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
