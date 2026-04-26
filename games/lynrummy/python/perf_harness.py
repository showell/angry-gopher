"""
perf_harness.py — load find_play snapshots, benchmark, profile.

Pipe `agent_game.py --capture FILE` to capture (hand, board)
inputs. Then run this harness against the JSONL file:

  - lists the slowest cases by recorded total_wall;
  - re-runs each top-N case `--repeats` times and reports
    median wall (independent of network jitter, since this
    only exercises the planner — no HTTP);
  - optionally cProfiles the slowest single case and dumps
    the top-30 cumulative-time entries.

Usage:
    python3 perf_harness.py /tmp/perf_snapshots.jsonl
    python3 perf_harness.py snaps.jsonl --top 5 --repeats 3
    python3 perf_harness.py snaps.jsonl --profile-slowest
"""

import argparse
import cProfile
import json
import pstats
import statistics
import sys
import time
from io import StringIO

import agent_prelude


def _to_tuple_card(c):
    """JSON stores cards as lists; the planner uses tuples."""
    return (c[0], c[1], c[2])


def _to_tuple_stack(s):
    return [_to_tuple_card(c) for c in s]


def _load_snapshots(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            rec["hand"] = [_to_tuple_card(c) for c in rec["hand"]]
            rec["board"] = [_to_tuple_stack(s) for s in rec["board"]]
            out.append(rec)
    return out


def _time_one(rec, repeats):
    """Re-run find_play `repeats` times, return list of walls."""
    walls = []
    for _ in range(repeats):
        t0 = time.time()
        agent_prelude.find_play(rec["hand"], rec["board"])
        walls.append(time.time() - t0)
    return walls


def _summarize(rec, walls):
    return {
        "captured_wall": rec["total_wall"],
        "median_wall": statistics.median(walls),
        "min_wall": min(walls),
        "max_wall": max(walls),
        "hand_size": len(rec["hand"]),
        "board_size": len(rec["board"]),
        "found_play": rec["found_play"],
        "n_projections": len(rec["projections"]),
    }


def _print_summary(rank, summary):
    print(f"  #{rank:2d} captured={summary['captured_wall']:5.2f}s "
          f"median={summary['median_wall']:5.2f}s "
          f"min={summary['min_wall']:5.2f}s "
          f"max={summary['max_wall']:5.2f}s | "
          f"hand={summary['hand_size']:>2} "
          f"board={summary['board_size']:>2} "
          f"projs={summary['n_projections']:>2} "
          f"{'+plan' if summary['found_play'] else 'STUCK'}")


def _print_projection_breakdown(rec):
    print("    projections:")
    for proj in rec["projections"]:
        cards = ",".join(f"{c[0]}/{c[1]}/{c[2]}" for c in proj["cards"])
        marker = "✓" if proj["found_plan"] else "·"
        print(f"      {marker} {proj['kind']:9} wall={proj['wall']:.2f}s "
              f"cards=[{cards}]")


def _profile_one(rec):
    profiler = cProfile.Profile()
    profiler.enable()
    agent_prelude.find_play(rec["hand"], rec["board"])
    profiler.disable()
    out = StringIO()
    stats = pstats.Stats(profiler, stream=out)
    stats.sort_stats("cumulative")
    stats.print_stats(30)
    return out.getvalue()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("snapshots",
                    help="JSONL file from agent_game --capture")
    ap.add_argument("--top", type=int, default=10,
                    help="Show the N slowest cases (default 10)")
    ap.add_argument("--repeats", type=int, default=5,
                    help="Re-time each case N times (default 5)")
    ap.add_argument("--profile-slowest", action="store_true",
                    help="cProfile the slowest case")
    args = ap.parse_args()

    snaps = _load_snapshots(args.snapshots)
    if not snaps:
        sys.exit(f"no snapshots in {args.snapshots}")

    snaps.sort(key=lambda s: s["total_wall"], reverse=True)
    top = snaps[:args.top]

    print(f"Loaded {len(snaps)} snapshots; profiling top {len(top)} "
          f"with {args.repeats} repeats each.\n")
    print("Per-case re-times:")

    summaries = []
    for i, rec in enumerate(top, 1):
        walls = _time_one(rec, args.repeats)
        s = _summarize(rec, walls)
        summaries.append(s)
        _print_summary(i, s)

    print("\nProjection breakdown for the slowest case:")
    _print_projection_breakdown(top[0])

    if args.profile_slowest:
        print("\ncProfile (top 30 by cumulative time) for the "
              "slowest case:")
        print(_profile_one(top[0]))


if __name__ == "__main__":
    main()
