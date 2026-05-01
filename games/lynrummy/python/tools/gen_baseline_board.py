#!/usr/bin/env python3
"""tools/gen_baseline_board.py — Generate the 81-card baseline suite.

The Game 17 board (6 helpers, 23 cards) is the fixed fixture.
For each of the 81 remaining cards in the double deck, run the
BFS solver and record: solvable/no_plan, plan lines, timing.

Outputs (paths relative to the repo root):
  games/lynrummy/conformance/scenarios/baseline_board_81.dsl
  games/lynrummy/python/baseline_board_81_gold.txt

The gold file is plain text — one scenario per line, sorted by
scenario id, scannable and diffable. Header comment documents the
columns and format.

Run from the python/ directory:
  python3 tools/gen_baseline_board.py

Commit both output files. Re-run after solver changes to update
the baseline; regenerate conformance fixtures with ops/check-conformance.
"""

import os
import sys

# Resolve python/ dir so imports work regardless of cwd.
_PYTHON_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, _PYTHON_DIR)

from buckets import Buckets
from rules.card import RANKS, SUITS
from rules.card import card as make_card
from bench_timing import time_solver


# ── Fixed board ──────────────────────────────────────────────────────────────

# The Game 17 standard opening board (23 deck-0 cards).
_BOARD_STACKS = [
    ["KS", "AS", "2S", "3S"],
    ["TD", "JD", "QD", "KD"],
    ["2H", "3H", "4H"],
    ["7S", "7D", "7C"],
    ["AC", "AD", "AH"],
    ["2C", "3D", "4C", "5H", "6S", "7H"],
]

# Verbatim DSL helper block (same every scenario).
_DSL_HELPERS = """\
  helper:
    at (0,0): KS AS 2S 3S
    at (0,0): TD JD QD KD
    at (0,0): 2H 3H 4H
    at (0,0): 7S 7D 7C
    at (0,0): AC AD AH
    at (0,0): 2C 3D 4C 5H 6S 7H"""


# ── Card helpers ──────────────────────────────────────────────────────────────

def _board_set():
    return {make_card(lbl, deck=0) for stack in _BOARD_STACKS for lbl in stack}


def _all_remaining():
    """All 81 (value, suit, deck) tuples not on the board, sorted."""
    on_board = _board_set()
    out = []
    for si in range(4):            # suits: C D S H
        for vi in range(13):       # values: A 2 … K
            for deck in (0, 1):
                c = (vi + 1, si, deck)
                if c not in on_board:
                    out.append(c)
    return out


def _dsl_label(c):
    """'2S' (deck 0) or '2S'' (deck 1)."""
    v, s, d = c
    base = RANKS[v - 1] + SUITS[s]
    return f"{base}'" if d else base


def _scenario_id(c):
    """Stable identifier: baseline_board_2S or baseline_board_2Sp."""
    v, s, d = c
    base = RANKS[v - 1] + SUITS[s]
    return f"baseline_board_{base}p" if d else f"baseline_board_{base}"


def _helpers_as_tuples():
    return [[make_card(lbl, deck=0) for lbl in stack] for stack in _BOARD_STACKS]


# ── Solver ────────────────────────────────────────────────────────────────────

def _time_solve(trouble_card):
    """Run solver via `bench_timing.time_solver` (warmup + GC-controlled
    min-of-10). Returns (plan_or_None, min_ms)."""
    helpers = _helpers_as_tuples()
    state = Buckets(helpers, [[trouble_card]], [], [])
    return time_solver(state)


# ── DSL formatting ────────────────────────────────────────────────────────────

def _format_scenario(c, plan):
    label = _dsl_label(c)
    sid = _scenario_id(c)

    if plan is None:
        result_desc = "no plan"
        expect = "  expect: no_plan"
    else:
        n = len(plan)
        result_desc = f"{n}-step plan"
        lines = "\n".join(f'      - "{line}"' for line, _ in plan)
        expect = f"  expect:\n    plan_lines:\n{lines}"

    desc = f"Baseline board, trouble {label}. {result_desc}. Auto-generated."
    return (
        f"scenario {sid}\n"
        f"  desc: {desc}\n"
        f"  op: solve\n"
        f"{_DSL_HELPERS}\n"
        f"  trouble:\n"
        f"    at (0,0): {label}\n"
        f"{expect}\n"
    )


# ── Main ──────────────────────────────────────────────────────────────────────

def _warmup_full_pass(cards):
    """Run a full pass of every scenario UNTIMED before measuring.

    The function-level warmup inside `time_solver` primes one
    scenario at a time, but the very first scenarios in any capture
    eat suite-level cold-start costs (interpreter caches, lazy
    `NEIGHPORS` table build, branch-predictor priming, OS file-cache
    state). Running the whole suite once first means every scenario's
    real measurement starts against a fully-warmed system, not just
    a function-warmed one.

    Cost: one extra pass (~30s for the 81-card suite). Worth it for
    gold capture; not done in `check_baseline_timing` where the speed
    of the feedback loop matters more than between-capture stability."""
    print("[warmup] priming the suite (untimed pass)...", flush=True)
    for i, c in enumerate(cards):
        helpers = _helpers_as_tuples()
        state = Buckets(helpers, [[c]], [], [])
        # Use the same boundary path that real measurement uses.
        # Throw away timing; we only care about warming caches.
        time_solver(state, n_runs=1)
    print(f"[warmup] done ({len(cards)} scenarios primed).", flush=True)


_GOLD_HEADER = """\
# baseline_board_81_gold.txt — auto-generated by tools/gen_baseline_board.py
# Game 17 board (6 helpers, 23 cards) + one trouble singleton per
# remaining card in the double deck. 81 scenarios, sorted by id.
# Columns: <scenario_id>  <ms>  <result>
# Re-run the generator after solver changes; commit this and the paired DSL.
"""


def _format_gold_line(sid, ms, result):
    """Fixed-width line for the gold file. ms is right-aligned for
    visual scanning of large vs small times."""
    return f"{sid:<26}{ms:>8.1f}  {result}"


def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(_PYTHON_DIR)))
    dsl_out = os.path.join(
        repo_root,
        "games/lynrummy/conformance/scenarios/baseline_board_81.dsl",
    )
    gold_out = os.path.join(_PYTHON_DIR, "baseline_board_81_gold.txt")

    cards = _all_remaining()
    assert len(cards) == 81, f"Expected 81, got {len(cards)}"

    _warmup_full_pass(cards)

    rows = []  # (sid, ms, result_str)
    dsl_header = (
        "# AUTO-GENERATED by tools/gen_baseline_board.py. Do not hand-edit.\n"
        "# Baseline suite: Game 17 board (6 helpers, 23 cards),\n"
        "# one trouble singleton per remaining card in the double deck (81 total).\n"
        "# Re-run the generator after solver changes, then commit both outputs.\n"
    )
    blocks = [dsl_header]

    for i, c in enumerate(cards):
        label = _dsl_label(c)
        sid = _scenario_id(c)
        print(f"[{i+1:2}/81] {label:<5} ... ", end="", flush=True)

        plan, ms = _time_solve(c)
        result_str = "no_plan" if plan is None else f"{len(plan)}-step"
        print(f"{result_str:<13}  {ms:7.1f}ms")

        blocks.append(_format_scenario(c, plan))
        rows.append((sid, round(ms, 1), result_str))

    with open(dsl_out, "w") as f:
        f.write("\n".join(blocks))
    print(f"\nWrote {dsl_out}  ({len(cards)} scenarios)")

    rows.sort(key=lambda r: r[0])
    with open(gold_out, "w") as f:
        f.write(_GOLD_HEADER)
        f.write("\n")
        for sid, ms, result in rows:
            f.write(_format_gold_line(sid, ms, result) + "\n")
    print(f"Wrote {gold_out}")

    no_plan = sum(1 for r in rows if r[2] == "no_plan")
    solvable = len(rows) - no_plan
    slow = sum(1 for r in rows if r[1] > 100)
    print(f"\nSummary: {solvable} solvable, {no_plan} no-plan, {slow} slow (>100ms)")


if __name__ == "__main__":
    main()
