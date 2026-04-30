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

import time

import bfs
from rules import card_label, classify, is_partial_ok


def find_play(hand, board, stats=None):
    """Find a plausible play. Returns
    {"placements": [card, ...], "plan": [(line, desc), ...]}
    or None.

    `hand` is a list of card-tuples (value, suit, deck).
    `board` is a list of stacks, each a list of card-tuples.

    If `stats` is provided (a mutable dict), it gets populated
    with timing info:
      stats["total_wall"]   = float, seconds across all
                              projections this call ran.
      stats["projections"]  = list of per-projection records
                              {"kind", "cards", "wall",
                               "found_plan"}, in execution order.
    """
    if stats is not None:
        stats.setdefault("projections", [])
    t_total = time.time()

    # (a) + (b): pair search.
    for i, c1 in enumerate(hand):
        for c2 in hand[i + 1:]:
            if not is_partial_ok([c1, c2]):
                continue

            # (a) Third in hand?
            ordered = _find_completing_third([c1, c2], hand)
            if ordered is not None:
                _finish(stats, t_total)
                return {
                    "placements": ordered,
                    "plan": [],
                }

            # (b) Project the pair onto the board, run BFS.
            plan = _try_projection(board, [[c1, c2]],
                                   stats=stats,
                                   kind="pair",
                                   cards=[c1, c2])
            if plan is not None:
                _finish(stats, t_total)
                return {
                    "placements": [c1, c2],
                    "plan": plan,
                }

    # (c) Singletons.
    for c in hand:
        plan = _try_projection(board, [[c]],
                               stats=stats,
                               kind="singleton",
                               cards=[c])
        if plan is not None:
            _finish(stats, t_total)
            return {
                "placements": [c],
                "plan": plan,
            }

    # (d) Nothing fired.
    _finish(stats, t_total)
    return None


def _finish(stats, t_start):
    if stats is not None:
        stats["total_wall"] = time.time() - t_start


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


def _try_projection(board, extra_stacks, *, stats=None, kind="?",
                    cards=()):
    max_states = _PROJECTION_MAX_STATES["value"]
    """Add `extra_stacks` to `board` (as new stacks), run BFS
    with desc tracking, and return the plan as
    [(line, desc), ...] on success or None on no plan.

    Records a per-projection entry in `stats["projections"]`
    when stats is provided. Each cap-exhaustion is recorded
    too: stats["projections"][-1]["exhaustions"] is a list
    of {cap, expansions, seen_count, hit_max_states} dicts —
    one per cap that ran without finding a plan. A
    `hit_max_states=True` entry means the search aborted on
    the state budget (a runaway candidate, NOT a clean
    no-plan-exists termination)."""
    augmented = list(board) + list(extra_stacks)
    helper = [s for s in augmented if classify(s) != "other"]
    trouble = [s for s in augmented if classify(s) == "other"]
    initial = (helper, trouble, [], [])
    exhaustions = []
    t0 = time.time()
    plan = bfs.solve_state_with_descs(
        initial, max_trouble_outer=10, max_states=max_states,
        on_cap_exhausted=lambda **kw: exhaustions.append(kw))
    wall = time.time() - t0
    # Drop the bulky `diagnostics` field from non-runaway
    # exhaustions so the stats stay JSON-friendly. Runaways
    # keep their diagnostics for analysis.
    for ex in exhaustions:
        if not ex.get("hit_max_states"):
            ex.pop("diagnostics", None)
    if stats is not None:
        stats.setdefault("projections", []).append({
            "kind": kind,
            "cards": list(cards),
            "wall": wall,
            "found_plan": plan is not None,
            "exhaustions": exhaustions,
        })
    return plan


def find_play_with_budget(hand, board, *, max_states, stats=None):
    """Variant of find_play that lets perf_harness control the
    BFS state budget per projection. Default `find_play`
    keeps the production budget."""
    # Same logic as find_play but injects max_states. Implemented
    # by temporarily monkey-patching the projection helper —
    # cheap and avoids restructuring the public API.
    original_max = _PROJECTION_MAX_STATES["value"]
    _PROJECTION_MAX_STATES["value"] = max_states
    try:
        return find_play(hand, board, stats=stats)
    finally:
        _PROJECTION_MAX_STATES["value"] = original_max


def format_hint(result):
    """Return hint steps as a [str] for display and conformance testing.

    Step 0 is always "place [<cards>] from hand"; remaining steps are
    the BFS plan line descriptions. Returns [] when result is None
    (stuck — no playable card found).
    """
    if result is None:
        return []
    labels = " ".join(card_label(c) for c in result["placements"])
    steps = [f"place [{labels}] from hand"]
    steps.extend(line for line, _desc in result["plan"])
    return steps


def hint_scenario_dsl(name, hand, board, result):
    """Produce DSL text for one hint_for_hand conformance scenario.

    `name` is the scenario identifier (e.g. "turn_1_hint").
    `hand` is a list of card-tuples.
    `board` is a list of stacks (each a list of card-tuples).
    `result` is the find_play result (dict or None).
    """
    hand_str = " ".join(card_label(c) for c in hand)
    board_block = "\n".join(
        "    - " + " ".join(card_label(c) for c in stack)
        for stack in board
    )
    steps = format_hint(result)
    if steps:
        steps_block = "  expect_steps:\n" + "\n".join(f"    - {s}" for s in steps)
    else:
        steps_block = "  expect_steps: []"
    return (
        f"scenario {name}\n"
        f"  op: hint_for_hand\n"
        f"  hand: {hand_str}\n"
        f"  board:\n{board_block}\n"
        f"{steps_block}\n"
    )


# Default BFS state budget per projection. Lowered to 5000
# (from 200000) on 2026-04-25 after the doomed-third filter
# + state-level doomed-growing filter landed. With those
# filters, the corpus solves 21/21 at budget 2000; 5000
# gives a 1.5× safety margin. Anything higher is wasted
# work — none of the captured snapshot cases needed more
# than ~1500 states once the filters kick in.
_PROJECTION_MAX_STATES = {"value": 5000}
