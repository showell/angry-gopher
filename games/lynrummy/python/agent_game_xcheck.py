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


def find_play_xcheck(hand, board, *, records):
    """Call both engines on the same input, assert step-list
    equivalence, return Python's full PlayResult.

    Appends one record dict to `records` per call, including
    Python wall, full TS-via-bridge wall, and engine-only TS
    wall (reported by bridge.ts itself, excluding subprocess +
    serialization overhead).

    Raises DivergenceError on disagreement — the cross-check that
    matters."""
    t = time.time()
    py_play = agent_prelude.find_play(hand, board)
    py_wall_s = time.time() - t
    py_steps = agent_prelude.format_hint(py_play)

    t = time.time()
    ts_steps, ts_engine_ms = ts_solver.find_play_with_timing(hand, board)
    ts_full_wall_s = time.time() - t

    record = {
        "hand": [list(c) for c in hand],
        "board": [[list(c) for c in s] for s in board],
        "py_wall_ms": py_wall_s * 1000.0,
        "ts_full_wall_ms": ts_full_wall_s * 1000.0,
        "ts_engine_ms": ts_engine_ms,
        "py_steps": py_steps,
        "agreed": py_steps == ts_steps,
    }
    records.append(record)

    if py_steps != ts_steps:
        raise DivergenceError(
            "engines disagree on step list:\n"
            f"  hand:  {hand}\n"
            f"  board: {board}\n"
            f"  py:    {py_steps}\n"
            f"  ts:    {ts_steps}\n"
        )
    return py_play


def play_xcheck_session(seed, *, max_actions=500, records=None):
    """Replicates play_session_offline but cross-checks every
    find_play against TS. Returns a per-session summary dict.
    Appends per-call records to `records` if provided."""
    rng = random.Random(seed)
    initial_state = dealer.deal(rng=rng)
    board = initial_state["board"]
    hand = _hand_cards_to_tuples(
        initial_state["hands"][0]["hand_cards"])

    if records is None:
        records = []
    session_records = []
    actions = 0
    plays = 0

    while actions < max_actions and hand:
        board_tuples = _board_cards_to_tuples(board)
        play = find_play_xcheck(hand, board_tuples,
                                records=session_records)
        # Tag with seed + turn, then ship to caller's accumulator.
        session_records[-1]["seed"] = seed
        session_records[-1]["turn"] = plays + 1
        records.append(session_records[-1])

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

    py_walls = [r["py_wall_ms"] for r in session_records]
    ts_engine_walls = [r["ts_engine_ms"] for r in session_records]
    ts_full_walls = [r["ts_full_wall_ms"] for r in session_records]
    return {
        "seed": seed,
        "plays": plays,
        "actions": actions,
        "hand_remaining": len(hand),
        "py_total_ms": sum(py_walls),
        "ts_total_engine_ms": sum(ts_engine_walls),
        "ts_total_full_ms": sum(ts_full_walls),
        "py_max_ms": max(py_walls, default=0.0),
        "ts_max_engine_ms": max(ts_engine_walls, default=0.0),
        "ts_max_full_ms": max(ts_full_walls, default=0.0),
        "find_play_calls": len(session_records),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seeds", default="1,2,3,4,5",
                        help="Comma-separated RNG seeds.")
    parser.add_argument("--max-actions", type=int, default=500)
    parser.add_argument("--capture", default=None,
                        help=("Path to JSONL output. Every find_play "
                              "call's input + timings are appended, "
                              "so trouble cases can be analyzed later."))
    parser.add_argument("--top-slow", type=int, default=5,
                        help="Print the N slowest find_play calls per engine.")
    args = parser.parse_args()

    seeds = [int(s) for s in args.seeds.split(",") if s.strip()]
    print(f"running {len(seeds)} seed(s); max-actions={args.max_actions}")
    if args.capture:
        print(f"capturing per-call records → {args.capture}")
    print()

    all_clean = True
    summaries = []
    all_records = []
    for seed in seeds:
        try:
            summary = play_xcheck_session(
                seed, max_actions=args.max_actions, records=all_records)
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
              f"py-max {summary['py_max_ms']:7.1f}ms  "
              f"ts-engine-max {summary['ts_max_engine_ms']:7.1f}ms  "
              f"ts-full-max {summary['ts_max_full_ms']:7.1f}ms")

    if args.capture:
        with open(args.capture, "a") as fp:
            for r in all_records:
                fp.write(json.dumps(r) + "\n")
        print(f"\nwrote {len(all_records)} records to {args.capture}")

    print()
    if all_clean:
        calls = sum(s["find_play_calls"] for s in summaries)
        print(f"ALL CLEAN: {len(seeds)} seeds, {calls} find_play calls")
        print()
        # Top-N slowest by py_wall_ms (engine-clean signal)
        slow_py = sorted(all_records, key=lambda r: -r["py_wall_ms"])[:args.top_slow]
        print(f"top {len(slow_py)} slowest find_play calls (by Python wall):")
        for r in slow_py:
            print(f"  seed {r['seed']:3d} turn {r['turn']:2d}: "
                  f"py {r['py_wall_ms']:7.1f}ms  "
                  f"ts-engine {r['ts_engine_ms']:7.1f}ms  "
                  f"ts-full {r['ts_full_wall_ms']:7.1f}ms  "
                  f"hand-size={len(r['hand'])} board-stacks={len(r['board'])}")
        # Same view by ts_engine_ms
        slow_ts = sorted(all_records, key=lambda r: -r["ts_engine_ms"])[:args.top_slow]
        print()
        print(f"top {len(slow_ts)} slowest by TS engine wall (excl. bridge):")
        for r in slow_ts:
            print(f"  seed {r['seed']:3d} turn {r['turn']:2d}: "
                  f"ts-engine {r['ts_engine_ms']:7.1f}ms  "
                  f"py {r['py_wall_ms']:7.1f}ms  "
                  f"hand-size={len(r['hand'])} board-stacks={len(r['board'])}")
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
