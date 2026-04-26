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


def _time_one(rec, repeats, max_states):
    """Re-run find_play `repeats` times, return list of
    (wall, stats) pairs where `stats` is the per-projection
    record from the LAST run (used to flag exhaustions)."""
    walls = []
    last_stats = {}
    for _ in range(repeats):
        last_stats = {}
        t0 = time.time()
        agent_prelude.find_play_with_budget(
            rec["hand"], rec["board"],
            max_states=max_states,
            stats=last_stats)
        walls.append(time.time() - t0)
    return walls, last_stats


def _summarize(rec, walls, last_stats):
    runaways = []
    for proj in last_stats.get("projections", []):
        for ex in proj.get("exhaustions", []):
            if ex["hit_max_states"]:
                runaways.append({
                    "kind": proj["kind"],
                    "cards": proj["cards"],
                    "cap": ex["cap"],
                    "expansions": ex["expansions"],
                    "seen": ex["seen_count"],
                    "diagnostics": ex.get("diagnostics", {}),
                })
    return {
        "captured_wall": rec["total_wall"],
        "median_wall": statistics.median(walls),
        "min_wall": min(walls),
        "max_wall": max(walls),
        "hand_size": len(rec["hand"]),
        "board_size": len(rec["board"]),
        "found_play": rec["found_play"],
        "n_projections": len(rec["projections"]),
        "runaways": runaways,
    }


def _print_summary(rank, summary):
    flag = " ⚠ RUNAWAY" if summary["runaways"] else ""
    print(f"  #{rank:2d} captured={summary['captured_wall']:5.2f}s "
          f"median={summary['median_wall']:5.2f}s "
          f"min={summary['min_wall']:5.2f}s "
          f"max={summary['max_wall']:5.2f}s | "
          f"hand={summary['hand_size']:>2} "
          f"board={summary['board_size']:>2} "
          f"projs={summary['n_projections']:>2} "
          f"{'+plan' if summary['found_play'] else 'STUCK'}"
          f"{flag}")
    for r in summary["runaways"]:
        cards = ", ".join(f"{c[0]}/{c[1]}/{c[2]}" for c in r["cards"])
        print(f"      ⚠ runaway: {r['kind']} cards=[{cards}] "
              f"cap={r['cap']} expansions={r['expansions']} "
              f"seen={r['seen']}")


def _print_projection_breakdown(rec):
    print("    projections:")
    for proj in rec["projections"]:
        cards = ",".join(f"{c[0]}/{c[1]}/{c[2]}" for c in proj["cards"])
        marker = "✓" if proj["found_plan"] else "·"
        print(f"      {marker} {proj['kind']:9} wall={proj['wall']:.2f}s "
              f"cards=[{cards}]")


def _print_runaway_diagnostics(runaway):
    diags = runaway.get("diagnostics", {})
    if not diags:
        print("    (no diagnostics captured — runaway record"
              " came from non-final cap)")
        return

    print(f"    cap={runaway['cap']} expansions="
          f"{runaway['expansions']} seen={runaway['seen']}")

    hist = diags.get("trouble_histogram", {})
    if hist:
        print("    trouble-count histogram of states added "
              "to frontier:")
        for tc in sorted(hist.keys()):
            bar = "█" * min(40, hist[tc] // max(1, max(hist.values()) // 40))
            print(f"      tc={tc:>2}  {hist[tc]:>5}  {bar}")

    widths = diags.get("level_widths", [])
    if widths:
        print("    BFS level widths "
              "(level → frontier size at end of level):")
        for i, w in enumerate(widths[:15]):
            print(f"      L{i:>2}  {w}")
        if len(widths) > 15:
            print(f"      ... ({len(widths) - 15} more levels)")

    samples = diags.get("sample_states", [])
    if samples:
        print("    Sample states from the frontier at"
              " cap-exhaustion:")
        for i, (state, prog_lines) in enumerate(samples, 1):
            helper, trouble, growing, complete = state
            print(f"      sample {i}:")
            print(f"        program ({len(prog_lines)} lines):")
            for line in prog_lines[-3:]:
                print(f"          ... {line}")
            print(f"        trouble: {[_card_summary(s) for s in trouble]}")
            print(f"        growing: {[_card_summary(s) for s in growing]}")
            print(f"        helper count: {len(helper)},"
                  f" complete count: {len(complete)}")


def _card_summary(stack):
    return "[" + " ".join(
        f"{c[0]}/{'CDSH'[c[1]]}{c[2] if c[2] else ''}"
        for c in stack
    ) + "]"


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
    ap.add_argument("--max-states", type=int, default=10000,
                    help=("BFS state budget per projection. Lower "
                          "values cut profiling time AND surface "
                          "any runaway searches as ⚠ RUNAWAY in "
                          "the summary."))
    ap.add_argument("--max-captured-wall", type=float, default=30.0,
                    help=("Skip snapshots whose captured wall "
                          "exceeds this (filters out pre-existing "
                          "pathological captures)."))
    ap.add_argument("--profile-slowest", action="store_true",
                    help="cProfile the slowest case")
    args = ap.parse_args()

    snaps = _load_snapshots(args.snapshots)
    if not snaps:
        sys.exit(f"no snapshots in {args.snapshots}")

    snaps = [s for s in snaps
             if s["total_wall"] <= args.max_captured_wall]
    snaps.sort(key=lambda s: s["total_wall"], reverse=True)
    top = snaps[:args.top]

    print(f"Loaded {len(snaps)} snapshots (post-filter); profiling "
          f"top {len(top)} with {args.repeats} repeats each, "
          f"max_states={args.max_states}.\n")
    print("Per-case re-times:")

    summaries = []
    last_stats_for_slowest = None
    for i, rec in enumerate(top, 1):
        walls, last_stats = _time_one(rec, args.repeats,
                                      args.max_states)
        if i == 1:
            last_stats_for_slowest = last_stats
        s = _summarize(rec, walls, last_stats)
        summaries.append(s)
        _print_summary(i, s)

    print("\nProjection breakdown for the slowest case:")
    _print_projection_breakdown(top[0])

    if summaries[0]["runaways"]:
        print("\nWhat the slowest runaway is chasing:")
        _print_runaway_diagnostics(summaries[0]["runaways"][0])

    if args.profile_slowest:
        print("\ncProfile (top 30 by cumulative time) for the "
              "slowest case:")
        print(_profile_one(top[0]))


if __name__ == "__main__":
    main()
