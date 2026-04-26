#!/usr/bin/env python3
"""
test_agent_prelude.py — assertions for `find_play` (the
hand-aware outer loop).

Each test hand-builds a (hand, board) pair and asserts on the
returned placement + plan shape. Mirrors the search-order
priority: pairs first, singletons fallback, None when stuck.

Run directly:
    python3 games/lynrummy/python/test_agent_prelude.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agent_prelude


C, D, S, H = 0, 1, 2, 3


def _assert(label, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(f"{status}  {label}" + (f"     {detail}" if detail else ""))
    if not ok:
        sys.exit(1)


# --- (a) pair-with-third-in-hand ----------------------------

def test_three_card_run_in_hand_no_bfs():
    """Hand [5H 6H 7H], board has nothing useful. Pair (5H,6H)
    melds; third 7H completes. Return placements=3 cards,
    plan=[]."""
    hand = [(5, H, 0), (6, H, 0), (7, H, 0)]
    board = [
        [(11, S, 0), (12, S, 0), (13, S, 0)],  # disjoint
    ]
    play = agent_prelude.find_play(hand, board)
    _assert("3-run-in-hand returns a play",
            play is not None, f"got {play}")
    _assert("placements has 3 cards",
            len(play["placements"]) == 3,
            f"got {play['placements']}")
    _assert("plan is empty (no BFS needed)",
            play["plan"] == [], f"got {play['plan']}")


def test_three_card_set_in_hand_no_bfs():
    """Hand [7C 7D 7S]. Pair (7C, 7D) melds (set partial);
    third 7S completes."""
    hand = [(7, C, 0), (7, D, 0), (7, S, 0)]
    board = []
    play = agent_prelude.find_play(hand, board)
    _assert("3-set-in-hand returns a play",
            play is not None)
    _assert("placements has 3 cards",
            len(play["placements"]) == 3)
    _assert("plan is empty",
            play["plan"] == [])


# --- (b) pair without third → BFS ---------------------------

def test_pair_without_third_uses_board():
    """Hand [5H', 6H']. No third in hand. Board has helper
    [7H 8H 9H 10H 11H 12H] — projecting the pair onto the
    board creates 2-partial trouble [5H' 6H']; BFS pushes it
    left onto the run for a length-8 pure_run. Pair ends up
    placed (no third needed)."""
    hand = [(5, H, 1), (6, H, 1)]
    board = [
        [(7, H, 0), (8, H, 0), (9, H, 0),
         (10, H, 0), (11, H, 0), (12, H, 0)],
    ]
    play = agent_prelude.find_play(hand, board)
    _assert("pair-without-third returns a play",
            play is not None, f"got {play}")
    _assert("placements has 2 cards",
            len(play["placements"]) == 2,
            f"got {play['placements']}")


# --- (c) singleton fallback ---------------------------------

def test_singleton_fallback_extends_run():
    """Hand has 1 card, no pair possible. Singleton (4H)
    projects onto board; BFS finds a free_pull plan with
    helper [5H 6H 7H]."""
    hand = [(4, H, 0)]
    board = [[(5, H, 0), (6, H, 0), (7, H, 0)]]
    play = agent_prelude.find_play(hand, board)
    _assert("singleton-fallback returns a play",
            play is not None, f"got {play}")
    _assert("placements is just the one card",
            play["placements"] == [(4, H, 0)],
            f"got {play['placements']}")
    _assert("plan is non-empty",
            len(play["plan"]) >= 1, f"got {play['plan']}")


# --- (d) stuck → None ---------------------------------------

def test_lonely_hand_no_helpers_returns_none():
    """Hand [5H], board has nothing related. No projection
    yields a plan. find_play returns None — driver
    completes turn."""
    hand = [(5, H, 0)]
    board = [
        [(11, S, 0), (12, S, 0), (13, S, 0), (1, S, 0)],
    ]
    play = agent_prelude.find_play(hand, board)
    _assert("stuck-hand returns None",
            play is None, f"got {play}")


def test_two_hand_cards_pair_doesnt_meld_no_helpers():
    """Hand [5H, KC] — no meldable pair (different value,
    different color, non-consecutive). Singletons all fail.
    Return None."""
    hand = [(5, H, 0), (13, C, 0)]
    board = [
        [(8, D, 0), (9, D, 0), (10, D, 0)],
    ]
    play = agent_prelude.find_play(hand, board)
    _assert("non-meldable pair returns None",
            play is None, f"got {play}")


# --- search-order priority ----------------------------------

def test_pair_preferred_over_singleton():
    """Hand [5H 6H 9D]. Pair (5H, 6H) melds and BFS finds a
    plan via board [4H 5C 6S 7H] (rb-run helper). Singleton
    9D could ALSO project onto another helper, but pair runs
    first. The returned placements have 2 cards, not 1."""
    hand = [(5, H, 1), (6, H, 1), (9, D, 0)]
    board = [
        [(8, H, 0), (9, H, 0), (10, H, 0)],  # could absorb 9D
        [(4, H, 1), (5, H, 0), (6, H, 0), (7, H, 1)],  # extends pair
    ]
    play = agent_prelude.find_play(hand, board)
    _assert("pair-vs-singleton finds a play",
            play is not None, f"got {play}")
    _assert("pair preferred (placements has 2)",
            len(play["placements"]) == 2,
            f"got {play['placements']}")


TESTS = [
    ("test_three_card_run_in_hand_no_bfs",
     test_three_card_run_in_hand_no_bfs),
    ("test_three_card_set_in_hand_no_bfs",
     test_three_card_set_in_hand_no_bfs),
    ("test_pair_without_third_uses_board",
     test_pair_without_third_uses_board),
    ("test_singleton_fallback_extends_run",
     test_singleton_fallback_extends_run),
    ("test_lonely_hand_no_helpers_returns_none",
     test_lonely_hand_no_helpers_returns_none),
    ("test_two_hand_cards_pair_doesnt_meld_no_helpers",
     test_two_hand_cards_pair_doesnt_meld_no_helpers),
    ("test_pair_preferred_over_singleton",
     test_pair_preferred_over_singleton),
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
