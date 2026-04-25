#!/usr/bin/env python3
"""
test_verbs.py — assertions for the VERB → PRIMITIVE translator.

Covers each desc type the BFS solver emits (extract_absorb,
free_pull, push, splice, shift) and verifies:
  - Translator emits a primitive list that applies cleanly
    against the simulated board (no missing stacks).
  - Pre-flight `move_stack` is emitted when the eventual
    geometry would violate, NOT after — intermediate frames
    must stay clean by construction.
  - The post-trick board has no geometry violations.

Style mirrors `test_follow_up_merges.py` and
`test_plan_merge_hand.py`: function-level tests, module-level
TESTS list, PASS/FAIL printing main(). Run directly:

    python3 games/lynrummy/python/test_verbs.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import primitives
import verbs
from geometry import find_violation


C, D, S, H = 0, 1, 2, 3


def _bc(value, suit, deck=0):
    return {"card": {"value": value, "suit": suit,
                     "origin_deck": deck},
            "state": 0}


def _stack(cards, loc):
    """`cards` may be 2-tuples (v, s) — deck defaults to 0 — or
    3-tuples (v, s, d)."""
    bcs = []
    for c in cards:
        if len(c) == 2:
            bcs.append(_bc(c[0], c[1]))
        else:
            bcs.append(_bc(c[0], c[1], c[2]))
    return {"board_cards": bcs, "loc": loc}


def _apply_all(board, prims):
    sim = list(board)
    for p in prims:
        sim = primitives.apply_locally(sim, p)
    return sim


def _assert(label, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(f"{status}  {label}" + (f"     {detail}" if detail else ""))
    if not ok:
        sys.exit(1)


# --- extract_absorb ------------------------------------------

def test_peel_left_edge_then_merge():
    """Peel 5H from [5H 6H 7H 8H], absorb onto trouble [4H]
    right-side. Spawned remnant [6H 7H 8H] stays a clean run."""
    board = [
        _stack([(5, H), (6, H), (7, H), (8, H)],
               {"top": 100, "left": 100}),
        _stack([(4, H)], {"top": 100, "left": 400}),
    ]
    desc = {
        "type": "extract_absorb",
        "verb": "peel",
        "source": [(5, H, 0), (6, H, 0), (7, H, 0), (8, H, 0)],
        "ext_card": (5, H, 0),
        "target_before": [(4, H, 0)],
        "target_bucket_before": "trouble",
        "result": [(4, H, 0), (5, H, 0)],
        "side": "right",
        "graduated": False,
        "spawned": [],
    }
    prims = verbs.step_to_primitives(desc, board)
    sim = _apply_all(board, prims)
    actions = [p["action"] for p in prims]
    _assert("peel-left actions are split + merge",
            actions == ["split", "merge_stack"],
            f"got {actions}")
    _assert("peel-left post board is geometry-clean",
            find_violation(sim) is None,
            f"violation at idx {find_violation(sim)}")
    contents = sorted(tuple(primitives.cards_of(s)) for s in sim)
    _assert("peel-left produces [4H,5H] + [6H,7H,8H]",
            ((4, H, 0), (5, H, 0)) in contents
            and ((6, H, 0), (7, H, 0), (8, H, 0)) in contents,
            f"got {contents}")


def test_pluck_interior_premoves_donor():
    """Plucking an interior card from a 5-card run forces a
    pre-move (interior splits get pre-cleared per the
    2026-04-23 rule)."""
    board = [
        _stack([(5, H), (6, H), (7, H), (8, H), (9, H)],
               {"top": 100, "left": 100}),
        _stack([(7, S)], {"top": 100, "left": 500}),
    ]
    desc = {
        "type": "extract_absorb",
        "verb": "pluck",
        "source": [(5, H, 0), (6, H, 0), (7, H, 0),
                   (8, H, 0), (9, H, 0)],
        "ext_card": (7, H, 0),
        "target_before": [(7, S, 0)],
        "target_bucket_before": "trouble",
        "result": [(7, S, 0), (7, H, 0)],
        "side": "right",
        "graduated": False,
        "spawned": [],
    }
    prims = verbs.step_to_primitives(desc, board)
    sim = _apply_all(board, prims)
    actions = [p["action"] for p in prims]
    _assert("pluck-interior emits a pre-move before splitting",
            actions[0] == "move_stack" and "split" in actions,
            f"got {actions}")
    _assert("pluck-interior post board is geometry-clean",
            find_violation(sim) is None,
            f"violation at idx {find_violation(sim)}")


# --- free_pull ----------------------------------------------

def test_free_pull_in_place():
    """Loose [4H] singleton merges right onto [5H 6H 7H].
    Plenty of room — single in-place merge."""
    board = [
        _stack([(5, H), (6, H), (7, H)],
               {"top": 100, "left": 100}),
        _stack([(4, H)], {"top": 100, "left": 50}),
    ]
    desc = {
        "type": "free_pull",
        "loose": (4, H, 0),
        "target_before": [(5, H, 0), (6, H, 0), (7, H, 0)],
        "target_bucket_before": "growing",
        "result": [(4, H, 0), (5, H, 0), (6, H, 0), (7, H, 0)],
        "side": "left",
        "graduated": True,
    }
    prims = verbs.step_to_primitives(desc, board)
    sim = _apply_all(board, prims)
    _assert("free_pull emits one merge (no pre-move needed)",
            len(prims) == 1 and prims[0]["action"] == "merge_stack",
            f"got {[p['action'] for p in prims]}")
    _assert("free_pull post board is geometry-clean",
            find_violation(sim) is None,
            f"violation at idx {find_violation(sim)}")


def test_free_pull_left_edge_premoves():
    """Loose [4H] merges LEFT onto a stack near the left edge —
    the eventual 4-card stack would push off-board, so the
    planner pre-moves the target."""
    from geometry import CARD_PITCH
    board = [
        _stack([(5, H), (6, H), (7, H)],
               {"top": 200, "left": 5}),
        _stack([(4, H)], {"top": 100, "left": 400}),
    ]
    desc = {
        "type": "free_pull",
        "loose": (4, H, 0),
        "target_before": [(5, H, 0), (6, H, 0), (7, H, 0)],
        "target_bucket_before": "growing",
        "result": [(4, H, 0), (5, H, 0), (6, H, 0), (7, H, 0)],
        "side": "left",
        "graduated": True,
    }
    prims = verbs.step_to_primitives(desc, board)
    sim = _apply_all(board, prims)
    actions = [p["action"] for p in prims]
    _assert("left-edge free_pull pre-moves target before merging",
            actions == ["move_stack", "merge_stack"],
            f"got {actions}")
    _assert("left-edge free_pull post board is geometry-clean",
            find_violation(sim) is None,
            f"violation at idx {find_violation(sim)}")


# --- push -----------------------------------------------------

def test_push_partial_in_place():
    """Push 2-partial trouble [QC KC] right onto helper [JS]
    (in-place legal)."""
    board = [
        _stack([(11, S)], {"top": 100, "left": 100}),
        _stack([(12, C), (13, C)], {"top": 200, "left": 100}),
    ]
    desc = {
        "type": "push",
        "trouble_before": [(12, C, 0), (13, C, 0)],
        "target_before": [(11, S, 0)],
        "result": [(11, S, 0), (12, C, 0), (13, C, 0)],
        "side": "right",
    }
    prims = verbs.step_to_primitives(desc, board)
    sim = _apply_all(board, prims)
    _assert("push emits one merge_stack",
            len(prims) == 1 and prims[0]["action"] == "merge_stack",
            f"got {[p['action'] for p in prims]}")
    _assert("push post board is geometry-clean",
            find_violation(sim) is None,
            f"violation at idx {find_violation(sim)}")


# --- splice ---------------------------------------------------

def test_splice_run():
    """Splice [4H] into pure run [5H 6H 7H 8H] at k=0 so the
    loose joins the right half ([4H 5H 6H 7H 8H] split logically;
    in our representation, k=1 with side='right' realizes
    [5H] + [4H 6H 7H 8H]). Just verify any valid splice produces
    a clean post-board."""
    board = [
        _stack([(2, H), (3, H), (4, H), (5, H), (6, H), (7, H)],
               {"top": 100, "left": 100}),
        _stack([(4, S)], {"top": 200, "left": 400}),
    ]
    # k=3 means split after 3 cards: left=[2H 3H 4H], right=[5H 6H 7H].
    # side=right means loose joins right → [4S 5H 6H 7H].
    desc = {
        "type": "splice",
        "loose": (4, S, 0),
        "source": [(2, H, 0), (3, H, 0), (4, H, 0),
                   (5, H, 0), (6, H, 0), (7, H, 0)],
        "k": 3, "side": "right",
        "left_result": [(2, H, 0), (3, H, 0), (4, H, 0)],
        "right_result": [(4, S, 0), (5, H, 0), (6, H, 0), (7, H, 0)],
    }
    prims = verbs.step_to_primitives(desc, board)
    sim = _apply_all(board, prims)
    actions = [p["action"] for p in prims]
    _assert("splice emits split + merge_stack (with optional pre-moves)",
            "split" in actions and "merge_stack" in actions,
            f"got {actions}")
    _assert("splice post board is geometry-clean",
            find_violation(sim) is None,
            f"violation at idx {find_violation(sim)}")


# --- shift ----------------------------------------------------

def test_shift_right_end():
    """8C pops JC: source [9C TC JC] (length-3 pure run, stolen
    at right end), donor [8D 8S 8H 8C] (length-4 set), p=8C
    replaces J at left to give new_source [8C 9C TC]. Stolen JC
    absorbs onto trouble [QH] right."""
    board = [
        _stack([(9, C), (10, C), (11, C)],
               {"top": 100, "left": 100}),  # source
        _stack([(8, D), (8, S), (8, H), (8, C)],
               {"top": 200, "left": 100}),  # donor (set, length 4)
        _stack([(12, H)], {"top": 300, "left": 400}),  # target
    ]
    desc = {
        "type": "shift",
        "source": [(9, C, 0), (10, C, 0), (11, C, 0)],
        "donor": [(8, D, 0), (8, S, 0), (8, H, 0), (8, C, 0)],
        "stolen": (11, C, 0),
        "p_card": (8, C, 0),
        "which_end": 2,
        "new_source": [(8, C, 0), (9, C, 0), (10, C, 0)],
        "new_donor": [(8, D, 0), (8, S, 0), (8, H, 0)],
        "target_before": [(12, H, 0)],
        "target_bucket_before": "trouble",
        "merged": [(12, H, 0), (11, C, 0)],
        "side": "right",
        "graduated": False,
    }
    prims = verbs.step_to_primitives(desc, board)
    sim = _apply_all(board, prims)
    _assert("shift produces a non-empty primitive list",
            len(prims) >= 3,
            f"got {len(prims)} prims")
    _assert("shift post board is geometry-clean",
            find_violation(sim) is None,
            f"violation at idx {find_violation(sim)}")
    contents = sorted(tuple(primitives.cards_of(s)) for s in sim)
    _assert("shift produces new_source [8C 9C 10C]",
            ((8, C, 0), (9, C, 0), (10, C, 0)) in contents,
            f"got {contents}")
    _assert("shift produces merged [12H 11C]",
            ((12, H, 0), (11, C, 0)) in contents,
            f"got {contents}")
    _assert("shift produces new_donor [8D 8S 8H]",
            ((8, D, 0), (8, S, 0), (8, H, 0)) in contents,
            f"got {contents}")


TESTS = [
    ("test_peel_left_edge_then_merge",
     test_peel_left_edge_then_merge),
    ("test_pluck_interior_premoves_donor",
     test_pluck_interior_premoves_donor),
    ("test_free_pull_in_place",
     test_free_pull_in_place),
    ("test_free_pull_left_edge_premoves",
     test_free_pull_left_edge_premoves),
    ("test_push_partial_in_place",
     test_push_partial_in_place),
    ("test_splice_run",
     test_splice_run),
    ("test_shift_right_end",
     test_shift_right_end),
]


def main():
    failed = 0
    for name, fn in TESTS:
        try:
            fn()
        except SystemExit:
            failed += 1
        except Exception as e:
            print(f"ERROR {name}: {type(e).__name__}: {e}")
            failed += 1
    print()
    print(f"{len(TESTS) - failed}/{len(TESTS)} test functions passed")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
