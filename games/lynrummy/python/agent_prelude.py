"""
agent_prelude.py — hand-aware "what should I play?" outer loop.

Given a hand + a board, find a plausible play: which hand
cards to place onto the board, plus the BFS plan that
cleans up the board afterward. The BFS itself is hand-blind;
this layer is what makes the agent hand-aware.

Search order (encodes game preference; no scoring layer):

  (a) For each meldable hand pair, try to find a completing
      third in the hand → 3 cards leave the hand in one move,
      no BFS needed. First success returns.
  (b) For each meldable hand pair without a third, project as
      a 2-partial trouble + run BFS. First plan returns.
  (c) For each remaining hand card, project as a singleton
      trouble + run BFS. First plan returns.
  (d) None of the above succeeded → return None. The agent
      is stuck; the driver completes the turn and the dealer
      decides. There's no "save a card" choice for the agent
      to make — emptying the hand is always preferred.
"""

import bfs_solver as bs
from beginner import classify, partial_ok


def find_play(hand, board):
    """Find a plausible play. Returns
    {"placements": [card, ...], "plan": [str, ...]}
    or None.

    `hand` is a list of card-tuples (value, suit, deck).
    `board` is a list of stacks, each a list of card-tuples
    (the same shape `bfs_solver.solve` accepts)."""
    # (a) + (b): pair search.
    for i, c1 in enumerate(hand):
        for c2 in hand[i + 1:]:
            if not partial_ok([c1, c2]):
                continue

            # (a) Third in hand?
            ordered = _find_completing_third([c1, c2], hand)
            if ordered is not None:
                return {
                    "placements": ordered,
                    "plan": [],
                }

            # (b) Project the pair onto the board, run BFS.
            plan = _try_projection(board, [[c1, c2]])
            if plan is not None:
                return {
                    "placements": [c1, c2],
                    "plan": plan,
                }

    # (c) Singletons.
    for c in hand:
        plan = _try_projection(board, [[c]])
        if plan is not None:
            return {
                "placements": [c],
                "plan": plan,
            }

    # (d) Nothing fired.
    return None


def _find_completing_third(pair, hand):
    """Return the ordered length-3 stack [a, b, c] that
    classifies as a legal group when `pair` gains a third
    hand card, or None. The order matters — runs are
    consecutive-by-value, so the harness needs to lay the
    cards down in the legal order."""
    for c in hand:
        if c is pair[0] or c is pair[1]:
            continue
        if c == pair[0] or c == pair[1]:
            continue
        for ordered in (
                [pair[0], pair[1], c],
                [pair[0], c, pair[1]],
                [c, pair[0], pair[1]],
        ):
            if classify(ordered) != "other":
                return ordered
    return None


def _try_projection(board, extra_stacks):
    """Add `extra_stacks` to `board` (as new stacks), run BFS
    with desc tracking, and return the plan as
    [(line, desc), ...] on success or None on no plan."""
    augmented = list(board) + list(extra_stacks)
    helper = [s for s in augmented if classify(s) != "other"]
    trouble = [s for s in augmented if classify(s) == "other"]
    initial = (helper, trouble, [], [])
    return bs.solve_state_with_descs(
        initial, max_trouble_outer=10, max_states=200000)
