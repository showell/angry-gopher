#!/usr/bin/env python3
"""
test_bfs_failure.py — assertions that the BFS planner DETECTS
INFEASIBILITY. The risk we're mitigating: a pathological
input where `solve` spins forever or balloons memory before
hitting the outer cap.

Test discipline:
  - Every test wraps `solve` with a wall-time guard. If wall
    exceeds `MAX_WALL`, the test fails loudly — we'd rather
    fail fast than hang.
  - Tests start from CLEARLY impossible cases and build up
    to subtler ones. Add a tier at a time.

Run directly:
    python3 games/lynrummy/python/test_bfs_failure.py
"""

import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bfs


# Wall-time per `solve` call. Tier-1 cases should return in
# milliseconds; we set a generous cap so a busy laptop doesn't
# false-flag, but tight enough that a pathological spin shows.
MAX_WALL = 2.0


C, D, S, H = 0, 1, 2, 3


def _assert(label, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(f"{status}  {label}" + (f"     {detail}" if detail else ""))
    if not ok:
        sys.exit(1)


def _solve_with_guard(board, max_trouble_outer=10, max_states=200000):
    """Run `solve` and return (plan_or_None, wall_seconds). If
    wall exceeds MAX_WALL, the caller treats it as a failure."""
    t0 = time.time()
    plan = bfs.solve(board, max_trouble_outer=max_trouble_outer,
                    max_states=max_states, verbose=False)
    wall = time.time() - t0
    return plan, wall


# --- Tier 1: trivially impossible -----------------------------

def test_singleton_with_no_board():
    """One trouble card, nothing else. Cannot form any group.
    Should return None fast."""
    board = [[(5, H, 0)]]
    plan, wall = _solve_with_guard(board)
    _assert("singleton-only returns None",
            plan is None, f"got {plan}")
    _assert("singleton-only finishes under MAX_WALL",
            wall < MAX_WALL, f"wall={wall:.2f}s")


def test_two_unrelated_singletons():
    """Two trouble singletons that share no group: 5H and JC.
    Cannot form any pair-partial, can't extend either."""
    board = [[(5, H, 0)], [(11, C, 0)]]
    plan, wall = _solve_with_guard(board)
    _assert("two-unrelated returns None",
            plan is None, f"got {plan}")
    _assert("two-unrelated finishes under MAX_WALL",
            wall < MAX_WALL, f"wall={wall:.2f}s")


def test_singleton_with_only_unhelpful_helper():
    """Trouble card 5H + a helper 6S-7H-8C-9D (rb-run length-4
    that's nowhere near 5H's value-neighbors and uses suits
    the rb-run doesn't extend cleanly with). Helper exists
    but can't be peeled-and-absorbed onto 5H."""
    # 5H neighbors include 4-shapes, 6-shapes, and 5-set partners.
    # Helper [JS QS KS AS] is wraparound spades — completely
    # disjoint value space, no extract can produce a 5H neighbor.
    board = [
        [(11, S, 0), (12, S, 0), (13, S, 0), (1, S, 0)],  # JS-QS-KS-AS
        [(5, H, 0)],
    ]
    plan, wall = _solve_with_guard(board)
    _assert("disjoint-helper returns None",
            plan is None, f"got {plan}")
    _assert("disjoint-helper finishes under MAX_WALL",
            wall < MAX_WALL, f"wall={wall:.2f}s")


# --- Tier 2: 2-partial troubles that can't complete ----------

def test_set_partial_no_third():
    """Trouble pair (AH, AS). To complete a set we need a
    third A. Board has no third A and no run containing an A.
    Pair cannot graduate to a legal stack."""
    board = [
        [(11, S, 0), (12, S, 0), (13, S, 0)],  # JS QS KS — no A involvement
        [(1, H, 0), (1, S, 0)],                # AH AS — set partial trouble
    ]
    plan, wall = _solve_with_guard(board)
    _assert("set-partial no-third returns None",
            plan is None, f"got {plan}")
    _assert("set-partial no-third finishes under MAX_WALL",
            wall < MAX_WALL, f"wall={wall:.2f}s")


def test_pure_run_partial_no_completion():
    """Trouble pair (5H, 6H) — pure-run partial. We need
    either 4H or 7H to complete a length-3 pure run, or
    something to extend further. Board has neither."""
    board = [
        [(11, S, 0), (12, S, 0), (13, S, 0)],
        [(5, H, 0), (6, H, 0)],
    ]
    plan, wall = _solve_with_guard(board)
    _assert("pure-run-partial no-completion returns None",
            plan is None, f"got {plan}")
    _assert("pure-run-partial no-completion finishes under MAX_WALL",
            wall < MAX_WALL, f"wall={wall:.2f}s")


# --- Tier 3: high-fanout impossibility ------------------------

def test_lonely_trouble_amid_rich_helpers():
    """Trouble singleton 5H surrounded by helpers that look
    promising but never yield a 5H-neighbor. Each helper has
    legal extract verbs (so the BFS produces lots of
    candidate moves), but no card it can extract is a 5H
    neighbor. The BFS will fan out, dedup, and exhaust.

    This is the canonical 'spin guard' test — many candidate
    moves, no path to victory."""
    board = [
        # Three legal length-4 helpers, each a pure run far from 5.
        [(1, S, 0), (2, S, 0), (3, S, 0), (4, S, 0)],
        [(11, C, 0), (12, C, 0), (13, C, 0), (1, C, 0)],
        [(8, D, 0), (9, D, 0), (10, D, 0), (11, D, 0)],
        # Lone trouble with no neighbors among helpers.
        [(5, H, 0)],
    ]
    plan, wall = _solve_with_guard(board)
    _assert("rich-helpers-lonely-trouble returns None",
            plan is None, f"got plan length {plan and len(plan)}")
    _assert("rich-helpers-lonely-trouble finishes under MAX_WALL",
            wall < MAX_WALL, f"wall={wall:.2f}s")


def test_partial_completable_but_stranded():
    """The harder fan-out case: an extract move IS available
    that creates a 2-partial growing, but no follow-up can
    complete it. Tests that BFS doesn't spin chasing
    completable-looking partials that strand.

    Setup: trouble [5H], helper [3C 4C 5C 6C] (pure-C length-4
    run). Extract 6C onto 5H → growing [5H 6C] (rb-pair). Now
    growing needs a 7-suit or 4-suit completion. The remaining
    helper after extract is [3C 4C 5C] — its only extractable
    end is 5C (set partner of 5H, but pair forms a same-suit
    dup; rejected) or 3C (not 5H/6C neighbor). Stuck.

    Plus a second isolated helper that's value-unrelated.
    """
    board = [
        [(3, C, 0), (4, C, 0), (5, C, 0), (6, C, 0)],
        [(11, S, 0), (12, S, 0), (13, S, 0), (1, S, 0)],
        [(5, H, 0)],
    ]
    plan, wall = _solve_with_guard(board, max_states=50000)
    _assert("partial-completable-stranded returns None",
            plan is None, f"got plan length {plan and len(plan)}")
    _assert("partial-completable-stranded finishes under MAX_WALL",
            wall < MAX_WALL, f"wall={wall:.2f}s")


def test_two_partial_troubles_no_completion_paths():
    """Two trouble pairs, both partials, neither completable
    via available helpers. Extract verbs would produce moves
    but none lead to victory. Stress on dedup + cap loop."""
    board = [
        # Helpers that don't carry the missing values.
        [(8, D, 0), (9, D, 0), (10, D, 0)],
        [(8, S, 0), (9, S, 0), (10, S, 0)],
        # Two unsolvable partials.
        [(1, H, 0), (1, S, 0)],   # AH AS — needs another A.
        [(5, H, 0), (6, H, 0)],   # 5H 6H — needs 4H or 7H.
    ]
    plan, wall = _solve_with_guard(board)
    _assert("two-partials no-paths returns None",
            plan is None, f"got plan length {plan and len(plan)}")
    _assert("two-partials no-paths finishes under MAX_WALL",
            wall < MAX_WALL, f"wall={wall:.2f}s")


TESTS = [
    ("test_singleton_with_no_board", test_singleton_with_no_board),
    ("test_two_unrelated_singletons", test_two_unrelated_singletons),
    ("test_singleton_with_only_unhelpful_helper",
     test_singleton_with_only_unhelpful_helper),
    ("test_set_partial_no_third", test_set_partial_no_third),
    ("test_pure_run_partial_no_completion",
     test_pure_run_partial_no_completion),
    ("test_lonely_trouble_amid_rich_helpers",
     test_lonely_trouble_amid_rich_helpers),
    ("test_partial_completable_but_stranded",
     test_partial_completable_but_stranded),
    ("test_two_partial_troubles_no_completion_paths",
     test_two_partial_troubles_no_completion_paths),
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
