#!/usr/bin/env python3
"""
test_bfs_extract.py — assertions for `enumerator.extract_pieces`,
the pure VERB → (helper_pieces, spawned_pieces) decomposition
that the extract layer of move-enumeration sits on.

Cards are 3-tuples (value, suit, deck). Suits: C=0, D=1, S=2,
H=3 (matching the rest of the codebase).

Each test feeds a hand-built source stack + verb + ci and pins
the resulting piece lists. No DB, no fixtures.

Run directly:
    python3 games/lynrummy/python/test_bfs_extract.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import enumerator


C, D, S, H = 0, 1, 2, 3


def _assert(label, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(f"{status}  {label}" + (f"     {detail}" if detail else ""))
    if not ok:
        sys.exit(1)


# --- peel -----------------------------------------------------

def test_peel_left_edge_run():
    """Peel 5H from [5H 6H 7H 8H] → remnant [6H 7H 8H]."""
    src = [(5, H, 0), (6, H, 0), (7, H, 0), (8, H, 0)]
    helpers, spawned = enumerator.extract_pieces(src, 0, "peel")
    _assert("peel-left-edge helpers",
            helpers == [[(6, H, 0), (7, H, 0), (8, H, 0)]],
            f"got {helpers}")
    _assert("peel-left-edge no spawn", spawned == [],
            f"got {spawned}")


def test_peel_right_edge_run():
    """Peel 8H from [5H 6H 7H 8H] → remnant [5H 6H 7H]."""
    src = [(5, H, 0), (6, H, 0), (7, H, 0), (8, H, 0)]
    helpers, spawned = enumerator.extract_pieces(src, 3, "peel")
    _assert("peel-right-edge helpers",
            helpers == [[(5, H, 0), (6, H, 0), (7, H, 0)]],
            f"got {helpers}")


def test_peel_from_set_keeps_remaining_three():
    """Peel any card from a 4-set: remnant is the other three."""
    src = [(7, C, 0), (7, D, 0), (7, S, 0), (7, H, 0)]
    helpers, spawned = enumerator.extract_pieces(src, 1, "peel")
    _assert("peel-set keeps three",
            helpers == [[(7, C, 0), (7, S, 0), (7, H, 0)]],
            f"got {helpers}")


# --- pluck ----------------------------------------------------

def test_pluck_interior_run_yields_two_helpers():
    """Pluck 7H from [5H 6H 7H 8H 9H] → left [5H 6H], right
    [8H 9H]. Both end up in helper_pieces (regardless of length;
    `do_extract` is the layer that filters)."""
    src = [(5, H, 0), (6, H, 0), (7, H, 0), (8, H, 0), (9, H, 0)]
    helpers, spawned = enumerator.extract_pieces(src, 2, "pluck")
    _assert("pluck-interior helpers split into two",
            helpers == [[(5, H, 0), (6, H, 0)],
                        [(8, H, 0), (9, H, 0)]],
            f"got {helpers}")
    _assert("pluck-interior no spawn", spawned == [],
            f"got {spawned}")


# --- yank -----------------------------------------------------

def test_yank_keeps_long_helpers_spawns_short():
    """Yank from [5H 6H 7H 8H 9H 10H] at ci=2 → left [5H 6H]
    (length 2, spawn), right [8H 9H 10H] (length 3, helper)."""
    src = [(5, H, 0), (6, H, 0), (7, H, 0),
           (8, H, 0), (9, H, 0), (10, H, 0)]
    helpers, spawned = enumerator.extract_pieces(src, 2, "yank")
    _assert("yank long-right stays helper",
            helpers == [[(8, H, 0), (9, H, 0), (10, H, 0)]],
            f"got {helpers}")
    _assert("yank short-left becomes spawned",
            spawned == [[(5, H, 0), (6, H, 0)]],
            f"got {spawned}")


def test_yank_two_long_helpers_no_spawn():
    """Yank from middle of a 7-card run: both halves length-3."""
    src = [(2, H, 0), (3, H, 0), (4, H, 0),
           (5, H, 0), (6, H, 0), (7, H, 0), (8, H, 0)]
    helpers, spawned = enumerator.extract_pieces(src, 3, "yank")
    _assert("yank both halves stay helper",
            len(helpers) == 2 and spawned == [],
            f"got helpers={helpers}, spawned={spawned}")


# --- steal ----------------------------------------------------

def test_steal_set_dismantles_to_singletons():
    """Steal from length-3 set: spawn each remaining card as a
    singleton."""
    src = [(7, S, 0), (7, H, 0), (7, D, 0)]
    helpers, spawned = enumerator.extract_pieces(src, 0, "steal")
    _assert("steal-set no helpers", helpers == [],
            f"got {helpers}")
    _assert("steal-set spawns two singletons",
            spawned == [[(7, H, 0)], [(7, D, 0)]],
            f"got {spawned}")


def test_steal_run_left_edge_spawns_pair():
    """Steal from left edge of length-3 run: spawn the 2-partial."""
    src = [(5, H, 0), (6, H, 0), (7, H, 0)]
    helpers, spawned = enumerator.extract_pieces(src, 0, "steal")
    _assert("steal-run-left no helpers", helpers == [],
            f"got {helpers}")
    _assert("steal-run-left spawns the pair",
            spawned == [[(6, H, 0), (7, H, 0)]],
            f"got {spawned}")


def test_steal_run_right_edge_spawns_pair():
    """Steal from right edge of length-3 run: spawn the
    leading 2-partial."""
    src = [(5, H, 0), (6, H, 0), (7, H, 0)]
    helpers, spawned = enumerator.extract_pieces(src, 2, "steal")
    _assert("steal-run-right spawns the leading pair",
            spawned == [[(5, H, 0), (6, H, 0)]],
            f"got {spawned}")


def test_split_out_run_interior_spawns_two_singletons():
    """split_out the middle of a length-3 run: both endpoints
    fall to TROUBLE as singletons; no helper remnant."""
    src = [(5, H, 0), (6, H, 0), (7, H, 0)]
    helpers, spawned = enumerator.extract_pieces(src, 1, "split_out")
    _assert("split_out yields no helper remnant",
            helpers == [], f"got {helpers}")
    _assert("split_out spawns left singleton then right",
            spawned == [[(5, H, 0)], [(7, H, 0)]],
            f"got {spawned}")


# --- bucket / graduation helpers ------------------------------

def test_remove_absorber_from_trouble():
    """Drop the named index from trouble; growing untouched."""
    trouble = [[(1, H, 0)], [(2, H, 0)], [(3, H, 0)]]
    growing = [[(7, C, 0), (7, D, 0)]]
    nt, ng = enumerator.remove_absorber("trouble", 1, trouble, growing)
    _assert("remove_absorber drops trouble[1]",
            nt == [[(1, H, 0)], [(3, H, 0)]],
            f"got {nt}")
    _assert("growing unchanged when removing from trouble",
            ng == growing,
            f"got {ng}")


def test_remove_absorber_from_growing():
    trouble = [[(5, S, 0)]]
    growing = [[(7, C, 0), (7, D, 0)],
               [(11, C, 0), (12, C, 0)]]
    nt, ng = enumerator.remove_absorber("growing", 0, trouble, growing)
    _assert("remove_absorber drops growing[0]",
            ng == [[(11, C, 0), (12, C, 0)]],
            f"got {ng}")
    _assert("trouble unchanged when removing from growing",
            nt == trouble,
            f"got {nt}")


def test_remove_absorber_purity():
    """Inputs aren't mutated."""
    trouble = [[(1, H, 0)], [(2, H, 0)]]
    growing = [[(7, C, 0), (7, D, 0)]]
    t_snap = [list(s) for s in trouble]
    g_snap = [list(s) for s in growing]
    enumerator.remove_absorber("trouble", 0, trouble, growing)
    _assert("trouble not mutated", trouble == t_snap)
    _assert("growing not mutated", growing == g_snap)


def test_graduate_legal_merged_goes_to_complete():
    """A legal 3+ run merges into COMPLETE, not GROWING."""
    growing = [[(7, C, 0), (7, D, 0)]]
    complete = []
    merged = [(5, H, 0), (6, H, 0), (7, H, 0)]
    ng, nc, graduated = enumerator.graduate(merged, growing, complete)
    _assert("graduated flag is True", graduated)
    _assert("growing unchanged", ng == growing)
    _assert("merged appended to complete",
            nc == [merged], f"got {nc}")


def test_graduate_partial_merged_stays_in_growing():
    """A 2-partial merge stays in GROWING."""
    growing = [[(11, C, 0), (12, C, 0)]]
    complete = [[(2, H, 0), (3, H, 0), (4, H, 0)]]
    merged = [(13, C, 0), (1, C, 0)]  # 2-partial
    ng, nc, graduated = enumerator.graduate(merged, growing, complete)
    _assert("graduated flag is False", not graduated)
    _assert("merged appended to growing",
            ng == growing + [merged], f"got {ng}")
    _assert("complete unchanged", nc == complete)


# --- do_extract integration ---------------------------------

def test_do_extract_does_not_mutate_input_helper():
    """Pure: the input helper list is unchanged after the call."""
    h0 = [(5, H, 0), (6, H, 0), (7, H, 0), (8, H, 0)]
    h1 = [(2, C, 0), (3, C, 0), (4, C, 0)]
    helper = [h0, h1]
    helper_snapshot = [list(s) for s in helper]
    new_helper, spawned, ext, src = enumerator.do_extract(
        helper, 0, 0, "peel")
    _assert("input helper list is unchanged",
            helper == helper_snapshot,
            f"helper mutated: {helper} vs {helper_snapshot}")
    _assert("ext_card is the requested card",
            ext == (5, H, 0), f"got {ext}")
    _assert("source_before is the original stack",
            src == h0, f"got {src}")


TESTS = [
    ("test_peel_left_edge_run", test_peel_left_edge_run),
    ("test_peel_right_edge_run", test_peel_right_edge_run),
    ("test_peel_from_set_keeps_remaining_three",
     test_peel_from_set_keeps_remaining_three),
    ("test_pluck_interior_run_yields_two_helpers",
     test_pluck_interior_run_yields_two_helpers),
    ("test_yank_keeps_long_helpers_spawns_short",
     test_yank_keeps_long_helpers_spawns_short),
    ("test_yank_two_long_helpers_no_spawn",
     test_yank_two_long_helpers_no_spawn),
    ("test_steal_set_dismantles_to_singletons",
     test_steal_set_dismantles_to_singletons),
    ("test_steal_run_left_edge_spawns_pair",
     test_steal_run_left_edge_spawns_pair),
    ("test_steal_run_right_edge_spawns_pair",
     test_steal_run_right_edge_spawns_pair),
    ("test_split_out_run_interior_spawns_two_singletons",
     test_split_out_run_interior_spawns_two_singletons),
    ("test_remove_absorber_from_trouble",
     test_remove_absorber_from_trouble),
    ("test_remove_absorber_from_growing",
     test_remove_absorber_from_growing),
    ("test_remove_absorber_purity", test_remove_absorber_purity),
    ("test_graduate_legal_merged_goes_to_complete",
     test_graduate_legal_merged_goes_to_complete),
    ("test_graduate_partial_merged_stays_in_growing",
     test_graduate_partial_merged_stays_in_growing),
    ("test_do_extract_does_not_mutate_input_helper",
     test_do_extract_does_not_mutate_input_helper),
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
