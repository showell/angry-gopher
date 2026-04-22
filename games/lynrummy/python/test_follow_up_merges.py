#!/usr/bin/env python3
"""
test_follow_up_merges.py — unit tests for strategy.find_follow_up_merges.

Covers the two fundamental merge shapes:
  - Two pure runs whose card sequences chain (right-merge)
  - A 3-set + a 1-card stack that extends to a 4-set (either side)

Plus one negative: a board of disjoint groups that shouldn't merge.

Run directly:
    python3 games/lynrummy/python/test_follow_up_merges.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import strategy


# Suits: Clubs=0, Diamonds=1, Spades=2, Hearts=3.
H, S, D, C = 3, 2, 1, 0


def _bc(value, suit):
    return {"card": {"value": value, "suit": suit, "origin_deck": 0},
            "state": 0}


def _stack(cards, loc):
    return {"board_cards": [_bc(v, s) for v, s in cards], "loc": loc}


def _assert(label, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(f"{status}  {label}" + (f"     {detail}" if detail else ""))
    if not ok:
        sys.exit(1)


def test_two_pure_runs_chain():
    """[5H,6H,7H] + [8H,9H,10H] should merge into one pure run."""
    board = [
        _stack([(5, H), (6, H), (7, H)], {"top": 100, "left": 100}),
        _stack([(8, H), (9, H), (10, H)], {"top": 200, "left": 200}),
    ]
    prims = strategy.find_follow_up_merges(board)
    _assert("two pure runs chain into one",
            len(prims) == 1 and prims[0]["action"] == "merge_stack",
            f"got {prims}")


def test_three_set_plus_single_extends():
    """[7S,7H,7D] + [7C] should merge into a 4-set."""
    board = [
        _stack([(7, S), (7, H), (7, D)], {"top": 100, "left": 100}),
        # A 1-card "stack" is not a valid group on its own, but
        # the test exercises the pair predicate, not board
        # validity.
        _stack([(7, C)], {"top": 200, "left": 200}),
    ]
    prims = strategy.find_follow_up_merges(board)
    _assert("3-set + single extends to 4-set",
            len(prims) == 1,
            f"got {prims}")


def test_disjoint_groups_no_merge():
    """Two sets of different values shouldn't merge."""
    board = [
        _stack([(5, H), (5, S), (5, D)], {"top": 100, "left": 100}),
        _stack([(9, H), (9, S), (9, D)], {"top": 200, "left": 200}),
    ]
    prims = strategy.find_follow_up_merges(board)
    _assert("disjoint groups stay disjoint",
            len(prims) == 0,
            f"got {prims}")


def test_two_independent_merges():
    """Four stacks: (A+B) merge, (C+D) merge — both emitted."""
    board = [
        _stack([(3, H), (4, H), (5, H)], {"top": 100, "left": 100}),
        _stack([(6, H), (7, H), (8, H)], {"top": 100, "left": 300}),
        _stack([(3, S), (3, D), (3, C)], {"top": 200, "left": 100}),
        _stack([(3, H)], {"top": 200, "left": 300}),
    ]
    prims = strategy.find_follow_up_merges(board)
    _assert("two independent pairs both merge",
            len(prims) == 2,
            f"got {prims}")


def test_merge_applies_with_shifting_indices():
    """Two sequential merges: indices shift after the first is
    applied. Simulate to confirm the emitted primitives apply
    cleanly against the evolving board."""
    board = [
        _stack([(3, H), (4, H), (5, H)], {"top": 100, "left": 100}),
        _stack([(6, H), (7, H), (8, H)], {"top": 100, "left": 300}),
        _stack([(3, S), (3, D), (3, C)], {"top": 200, "left": 100}),
        _stack([(3, H)], {"top": 200, "left": 300}),
    ]
    prims = strategy.find_follow_up_merges(board)
    ok, reason = strategy._invariant_clean(board, prims)
    # The 3H ends up in a 4-set, cards all wind up in some valid
    # group. _invariant_clean requires every final stack to be a
    # complete group; the two merged stacks are both complete.
    _assert("emitted primitives apply with shifting indices",
            ok, reason or "")


def test_overflow_triggers_move_first():
    """A merged stack that would overflow the board edge should
    trigger a move_stack of the target before the merge — same
    "plan around the eventual stack" pattern as _plan_merge_hand.
    The match picks side="left" (5-10 in value order), which
    shifts the merged loc LEFT by src_width*CARD_PITCH from
    tgt.left. Putting tgt at left=20 makes the merged stack's
    left edge land at -79, which violates BOARD_MARGIN."""
    board = [
        _stack([(5, H), (6, H), (7, H)], {"top": 100, "left": 600}),
        _stack([(8, H), (9, H), (10, H)], {"top": 200, "left": 20}),
    ]
    prims = strategy.find_follow_up_merges(board)
    kinds = [p["action"] for p in prims]
    _assert("overflow near edge triggers pre-merge move_stack",
            kinds == ["move_stack", "merge_stack"],
            f"got {kinds}")
    # And the final board should have no geometry violation.
    from geometry import find_violation
    sim = strategy._copy_board(board)
    for p in prims:
        if p["action"] == "move_stack":
            sim = strategy._apply_move(sim, p["stack_index"], p["new_loc"])
        elif p["action"] == "merge_stack":
            sim = strategy._apply_merge_stack(
                sim, p["source_stack"], p["target_stack"],
                p.get("side", "right"))
    _assert("post-plan board has no geometry violation",
            find_violation(sim) is None,
            f"violation at idx {find_violation(sim)}")


if __name__ == "__main__":
    test_two_pure_runs_chain()
    test_three_set_plus_single_extends()
    test_disjoint_groups_no_merge()
    test_two_independent_merges()
    test_merge_applies_with_shifting_indices()
    test_overflow_triggers_move_first()
    print("\n7/7 passed")
