"""
budget_sweep.py — replay every captured projection at varying
max_states budgets. Reports, per budget, how many projections
still find a plan vs how many are sacrificed.

The OPTIMIZE_PYTHON question: can we cut the BFS state budget
without losing many plans? If the answer is "lower it 10x and
98% still find their plan," we have a free perf win at the
cost of perfect agent play on the rare hard case.

Usage:
    python3 budget_sweep.py /tmp/perf_snapshots.jsonl
"""

import argparse
import json
import sys
import time

sys.path.insert(0, ".")
import bfs
from cards import classify


BUDGETS = [200000, 50000, 20000, 10000, 5000, 2000, 1000]


def _build_initial(board, extra_stacks):
    augmented = list(board) + list(extra_stacks)
    helper = [s for s in augmented if classify(s) != "other"]
    trouble = [s for s in augmented if classify(s) == "other"]
    return (helper, trouble, [], [])


def _run_projection(initial, max_states):
    t0 = time.time()
    plan = bfs.solve_state_with_descs(
        initial, max_trouble_outer=10,
        max_states=max_states)
    wall = time.time() - t0
    return plan is not None, wall


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("snapshots")
    args = ap.parse_args()

    with open(args.snapshots) as f:
        snaps = [json.loads(l) for l in f if l.strip()]
    snaps = [s for s in snaps if s["total_wall"] < 30]

    # Reconstruct each (initial, was_plan_found, captured_wall)
    # tuple from the captured projections.
    cases = []
    for snap in snaps:
        board = [[tuple(c) for c in s] for s in snap["board"]]
        for proj in snap["projections"]:
            extra = [list(map(tuple, proj["cards"]))]
            initial = _build_initial(board, extra)
            cases.append({
                "initial": initial,
                "kind": proj["kind"],
                "captured_found": proj["found_plan"],
                "captured_wall": proj["wall"],
            })

    captured_found = sum(1 for c in cases if c["captured_found"])
    print(f"Replaying {len(cases)} projections at varying budgets.")
    print(f"Capture baseline: {captured_found}/{len(cases)} "
          f"found a plan.\n")
    print(f"{'budget':>8} {'found':>8} {'lost_vs_baseline':>18} "
          f"{'total_wall':>12}")
    print("-" * 55)

    for budget in BUDGETS:
        found_now = 0
        total_wall = 0.0
        lost = 0
        for case in cases:
            ok, wall = _run_projection(case["initial"], budget)
            total_wall += wall
            if ok:
                found_now += 1
            elif case["captured_found"]:
                lost += 1
        print(f"{budget:>8} {found_now:>8} {lost:>18} "
              f"{total_wall:>10.2f}s")


if __name__ == "__main__":
    main()
