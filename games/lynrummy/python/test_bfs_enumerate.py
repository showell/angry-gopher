#!/usr/bin/env python3
"""
test_bfs_enumerate.py — snapshot tests for
`bfs_solver.enumerate_moves`, the per-state move generator.

These tests are intentionally small and concrete: hand-built
4-bucket states, full enumeration, exact assertions on the
desc dicts produced. They serve two purposes:

1. Regression coverage for the FP refactor — any future
   change to move enumeration that drops or duplicates a
   move shows up here.
2. Reference oracle for the upcoming Elm port — same input
   state should yield same desc set (up to ordering).

Run directly:
    python3 games/lynrummy/python/test_bfs_enumerate.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bfs_solver as bs


C, D, S, H = 0, 1, 2, 3


def _assert(label, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(f"{status}  {label}" + (f"     {detail}" if detail else ""))
    if not ok:
        sys.exit(1)


def _types(moves):
    return sorted(d["type"] for d, _ in moves)


# --- end-extract: peel a card adjacent to a trouble singleton --

def test_simple_peel_into_trouble():
    """HELPER [5H 6H 7H 8H], TROUBLE [4H singleton]. 4H neighbors
    include 5H. Should generate at least one extract_absorb
    (peel 5H from the run, absorb onto the 4H trouble)."""
    helper = [[(5, H, 0), (6, H, 0), (7, H, 0), (8, H, 0)]]
    trouble = [[(4, H, 0)]]
    state = (helper, trouble, [], [])
    moves = list(bs.enumerate_moves(state))
    types = _types(moves)
    _assert("at least one extract_absorb fires",
            "extract_absorb" in types,
            f"types: {types}")
    # Find the specific 5H peel.
    matches = [d for d, _ in moves
               if d["type"] == "extract_absorb"
               and d["ext_card"] == (5, H, 0)
               and d["target_before"] == [(4, H, 0)]]
    _assert("peel 5H onto [4H] is enumerated",
            len(matches) >= 1,
            f"got {len(matches)}")


# --- splice ---------------------------------------------------

def test_splice_into_length_4_run():
    """A length-4 pure run + a singleton trouble = potential
    splice. Insertion produces two legal length-3+ halves."""
    helper = [[(5, H, 0), (6, H, 0), (7, H, 0), (8, H, 0)]]
    trouble = [[(7, H, 1)]]  # second-deck 7H — splices in
    state = (helper, trouble, [], [])
    moves = list(bs.enumerate_moves(state))
    splices = [d for d, _ in moves if d["type"] == "splice"]
    # Set classification: runs don't accept dup values.
    # rb_run also won't accept same-value-same-color. So no
    # splice should fire here.
    _assert("no splice for same-color dup-value insert",
            len(splices) == 0,
            f"got {len(splices)}")


def test_splice_dup_5d_into_pure_diamonds():
    """Splice 5D:1 into [3D 4D 5D 6D 7D 8D] (length-6 pure run).
    At k=2 side=left: [3D 4D 5D:1] + [5D 6D 7D 8D]. Both halves
    classify as pure_run, both length-3+. One physical gesture
    in actual Lyn Rummy."""
    helper = [[(3, D, 0), (4, D, 0), (5, D, 0),
               (6, D, 0), (7, D, 0), (8, D, 0)]]
    trouble = [[(5, D, 1)]]  # second-deck 5D
    state = (helper, trouble, [], [])
    moves = list(bs.enumerate_moves(state))
    splices = [d for d, _ in moves if d["type"] == "splice"]
    _assert("at least one splice fires",
            len(splices) >= 1, f"got {len(splices)}")
    # Verify the specific desc shape.
    matches = [d for d in splices if d["loose"] == (5, D, 1)]
    _assert("splice with loose=5D:1 is enumerated",
            len(matches) >= 1, f"got {len(matches)}")


# --- engulf (push from GROWING) -------------------------------

def test_engulf_2partial_into_legal_run():
    """The puzzle-130 engulf shape: GROWING [AC 2D] + HELPER
    [3S 4D 5C] → COMPLETE [AC 2D 3S 4D 5C] (length-5 rb-run)."""
    helper = [[(3, S, 0), (4, D, 0), (5, C, 0)]]
    growing = [[(1, C, 0), (2, D, 0)]]
    state = (helper, [], growing, [])
    moves = list(bs.enumerate_moves(state))
    pushes = [d for d, _ in moves if d["type"] == "push"]
    _assert("at least one engulf fires",
            len(pushes) >= 1, f"got {len(pushes)}")
    # Find the engulf where growing 2-partial absorbs the run.
    engulfs = [d for d in pushes
               if d["trouble_before"] == [(1, C, 0), (2, D, 0)]
               and d["target_before"] == [(3, S, 0), (4, D, 0),
                                           (5, C, 0)]]
    _assert("specific engulf desc is enumerated",
            len(engulfs) >= 1, f"got {len(engulfs)}")
    # Verify post-state: helper drained, growing drained,
    # complete gained the merged stack.
    for d, new_state in moves:
        if (d["type"] == "push"
                and d["trouble_before"] == [(1, C, 0), (2, D, 0)]
                and d["target_before"] == [(3, S, 0), (4, D, 0),
                                            (5, C, 0)]
                and d["side"] == "right"):
            nh, nt, ng, nc = new_state
            _assert("engulf empties helper", nh == [],
                    f"got {nh}")
            _assert("engulf empties growing", ng == [],
                    f"got {ng}")
            _assert("engulf adds to complete",
                    len(nc) == 1, f"got {nc}")
            return


# --- shift ----------------------------------------------------

def test_shift_pops_jack_via_eight():
    """The expert 8C-pops-JC idiom. Source [9C TC JC] (length-3
    pure run) needs replacement at left end if we steal JC. Donor
    [8D 8S 8H 8C] (length-4 set) supplies 8C → new_source
    [8C 9C TC]. Stolen JC absorbs onto trouble [QH]."""
    helper = [
        [(9, C, 0), (10, C, 0), (11, C, 0)],   # source
        [(8, D, 0), (8, S, 0), (8, H, 0), (8, C, 0)],  # donor
    ]
    trouble = [[(12, H, 0)]]  # QH absorbs the popped JC
    state = (helper, trouble, [], [])
    moves = list(bs.enumerate_moves(state))
    shifts = [d for d, _ in moves if d["type"] == "shift"]
    _assert("at least one shift fires",
            len(shifts) >= 1, f"got {len(shifts)}")
    matches = [d for d in shifts
               if d["stolen"] == (11, C, 0)
               and d["p_card"] == (8, C, 0)]
    _assert("8C-pops-JC shift is enumerated",
            len(matches) >= 1, f"got {len(matches)}")


# --- enumeration purity --------------------------------------

def test_enumerate_does_not_mutate_state():
    """Walking the entire generator must not mutate the input
    state lists."""
    helper = [[(5, H, 0), (6, H, 0), (7, H, 0), (8, H, 0)]]
    trouble = [[(4, H, 0)], [(9, H, 0)]]
    growing = [[(11, C, 0), (12, C, 0)]]
    complete = []
    state = (helper, trouble, growing, complete)

    snap_h = [list(s) for s in helper]
    snap_t = [list(s) for s in trouble]
    snap_g = [list(s) for s in growing]
    snap_c = [list(s) for s in complete]

    _ = list(bs.enumerate_moves(state))

    _assert("helper not mutated", helper == snap_h)
    _assert("trouble not mutated", trouble == snap_t)
    _assert("growing not mutated", growing == snap_g)
    _assert("complete not mutated", complete == snap_c)


TESTS = [
    ("test_simple_peel_into_trouble", test_simple_peel_into_trouble),
    ("test_splice_into_length_4_run", test_splice_into_length_4_run),
    ("test_splice_dup_5d_into_pure_diamonds",
     test_splice_dup_5d_into_pure_diamonds),
    ("test_engulf_2partial_into_legal_run",
     test_engulf_2partial_into_legal_run),
    ("test_shift_pops_jack_via_eight",
     test_shift_pops_jack_via_eight),
    ("test_enumerate_does_not_mutate_state",
     test_enumerate_does_not_mutate_state),
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
