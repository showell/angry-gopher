"""
test_plan_merge_hand.py — assertions for the pre-flight
geometry-planning helper in `strategy._plan_merge_hand`.

Regression target: the "6H partly off the board" bug, where a
left-merge onto a stack near the left edge of the board used
to produce an intermediate frame with a card out of bounds.
The helper now moves the target FIRST, sized for the EVENTUAL
stack, then merges.

Run directly:

    python3 games/lynrummy/python/test_plan_merge_hand.py
"""

import sys

import strategy
from geometry import CARD_PITCH, find_violation


def _card(value, suit, origin_deck=0):
    return {"value": value, "suit": suit, "origin_deck": origin_deck}


def _stack(left, top, cards):
    return {
        "loc": {"left": left, "top": top},
        "board_cards": [{"card": c, "state": 0} for c in cards],
    }


def test_left_merge_near_left_edge_moves_first():
    # A 3-card 789rb at loc.left = 5 (the tightest legal left
    # margin). Hand card 6H merges LEFT. Without pre-planning,
    # the merged 4-card stack would sit at loc.left = 5 -
    # CARD_PITCH = -28, off the board. The helper must emit
    # move_stack FIRST so the merged stack lands legally.
    seven_h = _card(7, 3)
    eight_s = _card(8, 2)
    nine_h = _card(9, 3)
    six_h = _card(6, 3)
    sim = [_stack(5, 200, [seven_h, eight_s, nine_h])]

    prims, sim_after = strategy._plan_merge_hand(sim, 0, six_h, "left")

    assert len(prims) == 2, \
        f"expected move_stack + merge_hand; got {len(prims)} prims"
    assert prims[0]["action"] == "move_stack", \
        f"first prim should be move_stack; got {prims[0]['action']}"
    assert prims[1]["action"] == "merge_hand", \
        f"second prim should be merge_hand; got {prims[1]['action']}"
    assert find_violation(sim_after) is None, \
        "simulated post-merge board has a geometry violation"
    assert sim_after[-1]["loc"]["left"] >= 0, \
        f"final stack went off left edge: {sim_after[-1]['loc']}"


def test_right_merge_with_room_merges_in_place():
    # Plenty of room on the right. Merge-in-place is legal; the
    # helper should emit a single merge_hand (no move).
    cards = [_card(2, 0), _card(3, 0), _card(4, 0)]
    six = _card(5, 0)
    sim = [_stack(100, 200, cards)]

    prims, sim_after = strategy._plan_merge_hand(sim, 0, six, "right")

    assert len(prims) == 1, \
        f"expected in-place merge; got {len(prims)} prims"
    assert prims[0]["action"] == "merge_hand"
    assert prims[0]["side"] == "right"
    assert find_violation(sim_after) is None


def test_right_merge_near_right_edge_moves_first():
    # 3-card run at loc.left just under max_width - 3*pitch so
    # that adding a 4th card rightward pushes it off the right
    # edge. Helper must move first.
    cards = [_card(2, 0), _card(3, 0), _card(4, 0)]
    five = _card(5, 0)
    # Stack sits flush against the right-most legal 3-card spot;
    # adding a 4th rightward overflows.
    from geometry import BOARD_MAX_WIDTH, BOARD_MARGIN
    far_right = BOARD_MAX_WIDTH - 3 * CARD_PITCH - BOARD_MARGIN
    sim = [_stack(far_right, 200, cards)]

    prims, sim_after = strategy._plan_merge_hand(sim, 0, five, "right")

    assert len(prims) == 2, \
        f"expected move_stack + merge_hand; got {len(prims)} prims"
    assert prims[0]["action"] == "move_stack"
    assert prims[1]["action"] == "merge_hand"
    assert find_violation(sim_after) is None


TESTS = [
    ("test_left_merge_near_left_edge_moves_first", test_left_merge_near_left_edge_moves_first),
    ("test_right_merge_with_room_merges_in_place", test_right_merge_with_room_merges_in_place),
    ("test_right_merge_near_right_edge_moves_first", test_right_merge_near_right_edge_moves_first),
]


def main():
    failed = 0
    for name, fn in TESTS:
        try:
            fn()
            print(f"PASS  {name}")
        except AssertionError as e:
            print(f"FAIL  {name}: {e}")
            failed += 1
        except Exception as e:
            print(f"ERROR {name}: {type(e).__name__}: {e}")
            failed += 1
    print()
    print(f"{len(TESTS) - failed}/{len(TESTS)} passed")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
