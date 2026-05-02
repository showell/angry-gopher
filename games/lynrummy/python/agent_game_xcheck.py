"""
agent_game_xcheck.py — play an offline LynRummy session with both
the Python and TS engines, asserting per-turn equivalence.

Phase A.2 of the Python-BFS-retirement plan: plays real-world games
end-to-end via Python orchestration, calls both `agent_prelude.find_play`
and `ts_solver.find_play_steps` on every turn, and aborts loudly if
the two engines disagree on the formatted step list. The Python
result is used to drive the local board (it carries the typed Desc
objects needed by `verbs.move_to_primitives`); TS is exercised
purely as a parallel cross-check.

A clean run across several seeds + a non-trivial number of plays
is the empirical evidence that the TS port is faithful on real
workloads. A divergence is the failure we needed to surface — it
prints the (hand, board) repro so we can drop it into a fixture.

Usage:
    python3 agent_game_xcheck.py --seeds 1,2,3 --max-actions 300

Per-seed timing (Python wall vs TS bridge wall) is printed at end —
not a precision benchmark (the TS leg pays Node startup ~30-100ms
per call), but enough to flag if TS is dramatically slower or
faster on real games.
"""

import argparse
import json
import random
import sys
import time

import agent_prelude
import dealer
import geometry
import primitives
import ts_solver
import verbs


class DivergenceError(RuntimeError):
    """Python and TS produced different step lists for the same
    (hand, board) input. Carries the input + both outputs so the
    case can be turned into a fixture."""


def _board_cards_to_tuples(board):
    return [
        [(bc["card"]["value"], bc["card"]["suit"],
          bc["card"]["origin_deck"])
         for bc in s["board_cards"]]
        for s in board
    ]


def _hand_cards_to_tuples(hand_cards):
    return [
        (hc["card"]["value"], hc["card"]["suit"],
         hc["card"]["origin_deck"])
        for hc in hand_cards
    ]


def _tuple_to_card_dict(c):
    return {"value": c[0], "suit": c[1], "origin_deck": c[2]}


def find_play_xcheck(hand, board, *, py_wall_acc, ts_wall_acc):
    """Call both engines on the same input, assert step-list
    equivalence, return Python's full PlayResult.

    `py_wall_acc` and `ts_wall_acc` are mutable lists; each call
    appends one float (the wall-clock seconds for that engine).
    Per-call timings, not precise benchmarks.

    Raises DivergenceError on disagreement — the cross-check that
    matters."""
    t = time.time()
    py_play = agent_prelude.find_play(hand, board)
    py_wall_acc.append(time.time() - t)
    py_steps = agent_prelude.format_hint(py_play)

    t = time.time()
    ts_steps = ts_solver.find_play_steps(hand, board)
    ts_wall_acc.append(time.time() - t)

    if py_steps != ts_steps:
        raise DivergenceError(
            "engines disagree on step list:\n"
            f"  hand:  {hand}\n"
            f"  board: {board}\n"
            f"  py:    {py_steps}\n"
            f"  ts:    {ts_steps}\n"
        )
    return py_play


def play_xcheck_session(seed, *, max_actions=500):
    """Replicates play_session_offline but cross-checks every
    find_play against TS. Returns a per-session summary dict."""
    rng = random.Random(seed)
    initial_state = dealer.deal(rng=rng)
    board = initial_state["board"]
    hand = _hand_cards_to_tuples(
        initial_state["hands"][0]["hand_cards"])

    py_wall = []
    ts_wall = []
    actions = 0
    plays = 0
    py_max_wall = 0.0
    ts_max_wall = 0.0

    while actions < max_actions and hand:
        board_tuples = _board_cards_to_tuples(board)
        play = find_play_xcheck(hand, board_tuples,
                                py_wall_acc=py_wall,
                                ts_wall_acc=ts_wall)
        py_max_wall = max(py_max_wall, py_wall[-1])
        ts_max_wall = max(ts_max_wall, ts_wall[-1])

        if play is None:
            break

        plays += 1

        # Apply placements locally.
        for ci, placed in enumerate(play["placements"]):
            placed_loc = geometry.find_open_loc(board, card_count=1)
            if ci == 0:
                board = list(board) + [{
                    "board_cards": [
                        {"card": _tuple_to_card_dict(placed),
                         "state": 0}
                    ],
                    "loc": placed_loc,
                }]
            else:
                target = board[-1]
                new_target = {
                    "board_cards": (
                        list(target["board_cards"])
                        + [{"card": _tuple_to_card_dict(placed),
                            "state": 0}]
                    ),
                    "loc": dict(target["loc"]),
                }
                board = board[:-1] + [new_target]
            hand = [c for c in hand if c != placed]
            actions += 1

        # Apply BFS plan steps locally via Python descs.
        for line, desc in play["plan"]:
            prims = verbs.move_to_primitives(desc, board)
            for prim in prims:
                board = primitives.apply_locally(board, prim)
                actions += 1

    return {
        "seed": seed,
        "plays": plays,
        "actions": actions,
        "hand_remaining": len(hand),
        "py_total_wall": sum(py_wall),
        "ts_total_wall": sum(ts_wall),
        "py_max_wall": py_max_wall,
        "ts_max_wall": ts_max_wall,
        "find_play_calls": len(py_wall),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seeds", default="1,2,3,4,5",
                        help="Comma-separated RNG seeds.")
    parser.add_argument("--max-actions", type=int, default=500)
    args = parser.parse_args()

    seeds = [int(s) for s in args.seeds.split(",") if s.strip()]
    print(f"running {len(seeds)} seed(s); max-actions={args.max_actions}")
    print()

    all_clean = True
    summaries = []
    for seed in seeds:
        try:
            summary = play_xcheck_session(seed, max_actions=args.max_actions)
        except DivergenceError as e:
            print(f"seed {seed}: DIVERGED")
            print(str(e))
            all_clean = False
            break
        summaries.append(summary)
        print(f"seed {seed:3d}: {summary['plays']:3d} plays, "
              f"{summary['find_play_calls']:3d} find_play calls, "
              f"{summary['actions']:3d} actions, "
              f"hand={summary['hand_remaining']:2d}  |  "
              f"py {summary['py_total_wall']:5.2f}s "
              f"(max {summary['py_max_wall']*1000:6.1f}ms)  "
              f"ts {summary['ts_total_wall']:5.2f}s "
              f"(max {summary['ts_max_wall']*1000:6.1f}ms)")

    print()
    if all_clean:
        py_total = sum(s["py_total_wall"] for s in summaries)
        ts_total = sum(s["ts_total_wall"] for s in summaries)
        calls = sum(s["find_play_calls"] for s in summaries)
        py_max = max((s["py_max_wall"] for s in summaries), default=0.0)
        ts_max = max((s["ts_max_wall"] for s in summaries), default=0.0)
        print(f"ALL CLEAN: {len(seeds)} seeds, {calls} find_play calls")
        print(f"  py: {py_total:.2f}s total, {py_max*1000:.1f}ms worst-call")
        print(f"  ts: {ts_total:.2f}s total, {ts_max*1000:.1f}ms worst-call")
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
