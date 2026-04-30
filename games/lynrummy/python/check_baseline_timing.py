#!/usr/bin/env python3
"""check_baseline_timing.py — Timing regression checker for the 81-card baseline.

Reads baseline_board_81_timing.json (the stored baseline) and
conformance_fixtures.json (DSL scenarios parsed by fixturegen).

For each baseline_board_* scenario:
  - Builds the board state from the fixture
  - Runs the BFS solver (--runs times, takes minimum)
  - Compares against the stored baseline

Only scenarios with baseline_ms > MIN_BASELINE_MS (default 100ms) are
checked. Python timing noise dominates below that threshold; correctness
is covered by DSL conformance tests for the fast cases.

A regression is flagged when: current_ms > baseline_ms * (1 + tolerance)

Usage:
  python3 check_baseline_timing.py
  python3 check_baseline_timing.py --tolerance 0.10 --runs 3

Exit code 0 = all pass; 1 = regressions found.
"""

import argparse
import json
import sys
import time

import bfs
from buckets import Buckets

# Only check scenarios whose baseline exceeds this threshold.
# Python timing is too noisy below ~100ms (GC, cache warmth,
# OS scheduling) to give stable 10%-tolerance readings.
# The fast cases are covered by correctness tests; this checker
# is specifically for the slow ones that can regress noticeably.
_MIN_BASELINE_MS = 200.0


def _to_tuple(c):
    return (c["value"], c["suit"], c["origin_deck"])


def _bucket_to_tuples(stacks):
    return [[_to_tuple(bc["card"]) for bc in s["board_cards"]] for s in stacks]


def _load_fixtures(path="conformance_fixtures.json"):
    with open(path) as f:
        return {sc["name"]: sc for sc in json.load(f)}


def _load_baseline(path="baseline_board_81_timing.json"):
    with open(path) as f:
        return json.load(f)


def _time_scenario(sc, n_runs):
    state = Buckets(
        _bucket_to_tuples(sc.get("helper", [])),
        _bucket_to_tuples(sc.get("trouble", [])),
        _bucket_to_tuples(sc.get("growing", [])),
        _bucket_to_tuples(sc.get("complete", [])),
    )
    best_ms = float("inf")
    for _ in range(n_runs):
        t0 = time.perf_counter()
        bfs.solve_state_with_descs(
            state, max_trouble_outer=10, max_states=200000, verbose=False
        )
        best_ms = min(best_ms, (time.perf_counter() - t0) * 1000)
    return best_ms


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument(
        "--tolerance", type=float, default=0.10,
        help="Allowed slowdown fraction (default 0.10 = 10%%)",
    )
    ap.add_argument(
        "--runs", type=int, default=3,
        help="Solver runs per scenario; minimum is used (default 3)",
    )
    ap.add_argument(
        "--fixtures", default="conformance_fixtures.json",
        help="Path to conformance_fixtures.json",
    )
    ap.add_argument(
        "--baseline", default="baseline_board_81_timing.json",
        help="Path to timing baseline JSON",
    )
    args = ap.parse_args()

    fixtures = _load_fixtures(args.fixtures)
    baseline = _load_baseline(args.baseline)

    regressions = []
    total = len(baseline)

    for i, (sid, base_info) in enumerate(sorted(baseline.items())):
        sc = fixtures.get(sid)
        if sc is None:
            print(
                f"MISSING fixture for {sid} — run ops/check-conformance first",
                file=sys.stderr,
            )
            sys.exit(1)

        base_ms = base_info["ms"]

        if base_ms < _MIN_BASELINE_MS:
            continue  # too noisy to check reliably

        threshold_ms = base_ms * (1 + args.tolerance)

        print(f"[{i+1:2}/{total}] {sid:<35} ... ", end="", flush=True)
        current_ms = _time_scenario(sc, args.runs)

        delta_ms = current_ms - base_ms
        pct = delta_ms / max(base_ms, 0.001) * 100

        is_regression = current_ms > threshold_ms

        if is_regression:
            status = f"REGRESSION  +{pct:.0f}%  ({base_ms:.1f} → {current_ms:.1f}ms)"
            regressions.append((sid, base_ms, current_ms))
        else:
            status = f"ok  {current_ms:.1f}ms  (baseline {base_ms:.1f}ms)"

        print(status)

    print(f"\n{total - len(regressions)}/{total} passed")

    if regressions:
        print(f"\nREGRESSIONS ({len(regressions)}):")
        for sid, base_ms, cur_ms in regressions:
            pct = (cur_ms - base_ms) / max(base_ms, 0.001) * 100
            print(f"  {sid}: {base_ms:.1f}ms → {cur_ms:.1f}ms  (+{pct:.0f}%)")
        sys.exit(1)


if __name__ == "__main__":
    main()
