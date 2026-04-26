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
    [8C 9C TC]. Stolen JC absorbs onto trouble [QH] forming
    [QH JC] partial — completion candidate KC required for the
    doomed-third filter to admit the move."""
    helper = [
        [(9, C, 0), (10, C, 0), (11, C, 0)],   # source
        [(8, D, 0), (8, S, 0), (8, H, 0), (8, C, 0)],  # donor
        [(13, C, 0), (1, C, 0), (2, C, 0)],    # KC AC 2C — supplies KC
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


# --- doomed-third filter --------------------------------------

def test_doomed_partial_pruned():
    """Trouble [4H], helper [5H 6H 7H 8H]. Peel 5H or 8H would
    extract a 5/8 onto 4H. Peel 5H → partial [4H 5H] (pure-run);
    needs 3H or 6H. 6H is in helper (still extractable end of
    the same run). So this partial is NOT doomed; move fires.

    Now block: remove all the helper companions and ensure the
    only completion path is gone."""
    # Variant A: completion exists → move fires.
    helper_with = [[(5, H, 0), (6, H, 0), (7, H, 0), (8, H, 0)]]
    state = (helper_with, [[(4, H, 0)]], [], [])
    moves = list(bs.enumerate_moves(state))
    _assert("doomed-filter admits move when completion exists",
            any(d["type"] == "extract_absorb" for d, _ in moves))

    # Variant B: no completion exists. Trouble 4H + helper of
    # 5-6-7-8 of HEARTS (so peel 5H → [4H 5H] needs 3H or 6H;
    # 6H is interior of the run, NOT extractable; 3H is absent).
    # Wait — the helper inventory check goes by (value, suit)
    # ignoring extractability. 6H IS in inventory regardless of
    # position. So this case is actually NOT doomed.
    #
    # To force doomed: trouble 4S + helper [6H 7H 8H] (no 3 or 5
    # of any color, no 4-set partner).
    helper_no_completion = [[(6, H, 0), (7, H, 0), (8, H, 0)]]
    state = (helper_no_completion, [[(4, S, 0)]], [], [])
    moves = list(bs.enumerate_moves(state))
    # 4S has neighbor 5-of-anything. None of 6H/7H/8H is a
    # 4S-neighbor — extracts wouldn't fire anyway. So this
    # tests the upstream short-circuit, not specifically the
    # doomed-filter. Still, no extract_absorb should fire.
    _assert("no extract fires when no shape match",
            not any(d["type"] == "extract_absorb" for d, _ in moves))

    # Variant C: 4S + helper [5H 6H 7H 8H] (a pure-H run).
    # Peel 5H → spawn [6H 7H 8H], absorb 5H onto 4S → [4S 5H]
    # rb-pair partial. Completion needs 3-red or 6-black.
    # Inventory: 4S 5H 6H 7H 8H. 6H is RED (doesn't satisfy
    # 6-black). No 3-red anywhere. → DOOMED.
    helper_only_pure_h = [[(5, H, 0), (6, H, 0), (7, H, 0), (8, H, 0)]]
    state = (helper_only_pure_h, [[(4, S, 0)]], [], [])
    moves = list(bs.enumerate_moves(state))
    extracts = [d for d, _ in moves if d["type"] == "extract_absorb"]
    _assert("doomed-filter blocks doomed peel",
            len(extracts) == 0,
            f"got {len(extracts)} extracts: "
            f"{[(d['verb'], d['ext_card']) for d in extracts]}")

    # Variant D: same setup but add a 3D card so the partial is
    # NOT doomed. Move should fire.
    helper_with_3d = [
        [(5, H, 0), (6, H, 0), (7, H, 0), (8, H, 0)],
        [(3, D, 0), (4, D, 0), (5, D, 0)],   # supplies 3D
    ]
    state = (helper_with_3d, [[(4, S, 0)]], [], [])
    moves = list(bs.enumerate_moves(state))
    extracts = [d for d, _ in moves if d["type"] == "extract_absorb"]
    _assert("doomed-filter admits move when 3D supplies completion",
            len(extracts) >= 1,
            f"got {len(extracts)} extracts")


# --- doomed growing partials reachable mid-search -------------

def test_doomed_growing_partial_is_reachable():
    """The doomed-third filter checks at MERGE time. It does
    NOT re-check existing growing partials. This test
    constructs an initial state where the BFS reaches a
    state with a doomed growing partial — proving that the
    current filter has a gap.

    Setup: 4 distinct 7s in trouble + a length-4 pure-clubs
    helper [4C 5C 6C 7C']. Step 1: free pull 7D onto 7C →
    growing [7C 7D] (admitted; 7H, 7S still in trouble as
    completion candidates). Step 2: free pull 7S onto 7H →
    growing [7H 7S] (admitted; 7C/7C' in helper is a
    completion candidate). Resulting state has two growing
    7-partials; [7C 7D]'s completion candidates (7H, 7S)
    are now committed inside [7H 7S], NOT available in
    helper or trouble. So [7C 7D] is doomed in this state,
    even though it was admitted earlier."""
    helper = [[(4, C, 0), (5, C, 0), (6, C, 0), (7, C, 1)]]
    trouble = [[(7, C, 0)], [(7, D, 0)], [(7, H, 0)], [(7, S, 0)]]
    state = (helper, trouble, [], [])

    # Move 1: pull 7D onto 7C.
    after_m1 = None
    for d, ns in bs.enumerate_moves(state):
        if (d["type"] == "free_pull"
                and d["loose"] == (7, D, 0)
                and d["target_before"] == [(7, C, 0)]):
            after_m1 = ns
            break
    _assert("move 1 (pull 7D onto 7C) is enumerated",
            after_m1 is not None)

    # Move 2: pull 7S onto 7H.
    after_m2 = None
    for d, ns in bs.enumerate_moves(after_m1):
        if (d["type"] == "free_pull"
                and d["loose"] == (7, S, 0)
                and d["target_before"] == [(7, H, 0)]):
            after_m2 = ns
            break
    _assert("move 2 (pull 7S onto 7H) is enumerated",
            after_m2 is not None)

    helper2, trouble2, growing2, _ = after_m2
    inv = bs._completion_inventory(helper2, trouble2)
    doomed = []
    for g in growing2:
        if len(g) == 2:
            shapes = bs._completion_shapes(g)
            if not (shapes & inv):
                doomed.append(g)
    _assert("at least one growing partial is doomed in the "
            "reached state",
            len(doomed) >= 1,
            f"growing={growing2}, doomed={doomed}, inv={sorted(inv)}")

    # And the state-level filter MUST fire on this state —
    # enumerate_moves yields nothing when a doomed growing
    # partial is present.
    moves_from_doomed_state = list(bs.enumerate_moves(after_m2))
    _assert("state-level filter prunes a doomed-growing state",
            moves_from_doomed_state == [],
            f"got {len(moves_from_doomed_state)} moves")


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
    ("test_doomed_partial_pruned", test_doomed_partial_pruned),
    ("test_doomed_growing_partial_is_reachable",
     test_doomed_growing_partial_is_reachable),
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
