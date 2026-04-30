#!/usr/bin/env python3
"""bench_outer_shell.py — Compare outer-shell modes on random hands.

Fixed corpus: 60 random 6-card hands drawn from the 81 cards not on
the Game 17 opening board (6 helpers, 23 cards), seed 42.

NOTE: 6-card hands are used here solely to exercise all four outcome
types (triple, pair, single, stuck) within a manageable corpus. Real
Lyn Rummy hands start at 15 cards; hand size shrinks as cards are
played to the board.

Two modes compared:

  singleton-only  skip pair/triple steps; project each hand card as a
                  singleton trouble, pick the shortest BFS plan.

  full            triple-in-hand first (no BFS), then every valid pair
                  as a 2-partial trouble, then every singleton; pick
                  shortest plan overall. This is agent_prelude.find_play.

Usage:
  python3 bench_outer_shell.py
"""

import random
import time
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bfs
import agent_prelude
from rules import classify, is_partial_ok
from rules.card import card as make_card, card_label

_N = 60
_HAND_SIZE = 6   # benchmark only — not actual gameplay hand size
_SEED = 42
_MAX_STATES = 5000

# ── Fixed board ──────────────────────────────────────────────────────────────

_BOARD_STACKS_LABELS = [
    ["KS", "AS", "2S", "3S"],
    ["TD", "JD", "QD", "KD"],
    ["2H", "3H", "4H"],
    ["7S", "7D", "7C"],
    ["AC", "AD", "AH"],
    ["2C", "3D", "4C", "5H", "6S", "7H"],
]


def _make_board():
    return [[make_card(lbl, deck=0) for lbl in stack]
            for stack in _BOARD_STACKS_LABELS]


def _remaining_cards():
    """The 81 cards not on the board."""
    on_board = {make_card(lbl, deck=0)
                for stack in _BOARD_STACKS_LABELS for lbl in stack}
    out = []
    for si in range(4):
        for vi in range(13):
            for deck in (0, 1):
                c = (vi + 1, si, deck)
                if c not in on_board:
                    out.append(c)
    assert len(out) == 81
    return out


# ── Singleton-only mode ───────────────────────────────────────────────────────

def _project_singleton(board, c):
    """BFS with `c` as a singleton trouble. Returns (plan_or_None, ms)."""
    augmented = board + [[c]]
    helper = [s for s in augmented if classify(s) != "other"]
    trouble = [s for s in augmented if classify(s) == "other"]
    t0 = time.perf_counter()
    plan = bfs.solve_state_with_descs(
        (helper, trouble, [], []),
        max_trouble_outer=10,
        max_states=_MAX_STATES,
        verbose=False,
    )
    return plan, (time.perf_counter() - t0) * 1000


def find_play_singletons_only(hand, board):
    """Singleton-only: try every hand card as a trouble singleton,
    return the one with the shortest BFS plan (or None if stuck)."""
    candidates = []
    total_ms = 0.0
    projections = 0
    for c in hand:
        plan, ms = _project_singleton(board, c)
        total_ms += ms
        projections += 1
        if plan is not None:
            candidates.append({"placements": [c], "plan": plan})
    result = (None if not candidates
              else min(candidates, key=lambda r: len(r["plan"])))
    return result, total_ms, projections


# ── Full mode ─────────────────────────────────────────────────────────────────

def find_play_full(hand, board):
    """Full mode via agent_prelude.find_play_with_budget."""
    t0 = time.perf_counter()
    result = agent_prelude.find_play_with_budget(
        hand, board, max_states=_MAX_STATES
    )
    total_ms = (time.perf_counter() - t0) * 1000
    # Rough projection count: valid pairs + singletons; for display only.
    n_pairs = sum(
        1 for i, c1 in enumerate(hand)
        for c2 in hand[i + 1:]
        if is_partial_ok([c1, c2])
    )
    projections = n_pairs + len(hand)
    return result, total_ms, projections


# ── Formatting helpers ────────────────────────────────────────────────────────

def _fmt_result(result):
    if result is None:
        return "stuck"
    placements = " ".join(card_label(c) for c in result["placements"])
    n = len(result["plan"])
    kind = "pair" if len(result["placements"]) == 2 else (
        "triple" if len(result["placements"]) == 3 else "single")
    return f"{kind} [{placements}] → {n}-step plan"


def _plan_len(result):
    return 999 if result is None else len(result["plan"])


def _placement_count(result):
    return 0 if result is None else len(result["placements"])


def _outcome(result):
    if result is None:
        return "stuck"
    n = len(result["placements"])
    if n >= 3:
        return "triple"
    if n == 2:
        return "pair"
    return "single"


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    remaining = _remaining_cards()
    rng = random.Random(_SEED)
    hands = [rng.sample(remaining, _HAND_SIZE) for _ in range(_N)]
    board = _make_board()

    print(f"Game 17 board  ·  {_N} hands of {_HAND_SIZE} (benchmark size)  ·  "
          f"seed={_SEED}  ·  max_states={_MAX_STATES}")
    print()

    col = 44  # width for result column

    # ── singleton-only pass ──────────────────────────────────────────────
    print("=== singleton-only (no pair/triple) ===")
    solo_times = []
    solo_results = []
    for i, hand in enumerate(hands):
        result, ms, n_proj = find_play_singletons_only(hand, board)
        solo_times.append(ms)
        solo_results.append(result)
        desc = _fmt_result(result)
        print(f"  hand {i+1:2}  {desc:<{col}}  {ms:7.1f}ms  ({n_proj} projections)")
    solo_total = sum(solo_times)
    solo_stuck = sum(1 for r in solo_results if r is None)
    print(f"  ── total {solo_total:.0f}ms  ·  stuck {solo_stuck}/{_N}\n")

    # ── full pass ────────────────────────────────────────────────────────
    print("=== full (triple-in-hand + pair-BFS + singleton) ===")
    full_times = []
    full_results = []
    for i, hand in enumerate(hands):
        result, ms, n_proj = find_play_full(hand, board)
        full_times.append(ms)
        full_results.append(result)
        desc = _fmt_result(result)
        print(f"  hand {i+1:2}  {desc:<{col}}  {ms:7.1f}ms  (~{n_proj} projections)")
    full_total = sum(full_times)
    full_stuck = sum(1 for r in full_results if r is None)
    print(f"  ── total {full_total:.0f}ms  ·  stuck {full_stuck}/{_N}\n")

    # ── per-hand comparison ───────────────────────────────────────────────
    better_plan = 0
    same_plan = 0
    worse_plan = 0
    more_placements = 0
    for rs, rf in zip(solo_results, full_results):
        sp, fp = _plan_len(rs), _plan_len(rf)
        sc, fc = _placement_count(rs), _placement_count(rf)
        if fp < sp:
            better_plan += 1
        elif fp == sp:
            same_plan += 1
        else:
            worse_plan += 1
        if fc > sc:
            more_placements += 1

    # ── outcome coverage (full mode) ────────────────────────────────────
    outcomes = [_outcome(r) for r in full_results]
    counts = {k: outcomes.count(k) for k in ("triple", "pair", "single", "stuck")}

    # ── summary ──────────────────────────────────────────────────────────
    ratio = full_total / max(solo_total, 0.001)
    print("=== summary ===")
    print(f"  singleton-only  {solo_total:7.0f}ms total  stuck {solo_stuck}/{_N}")
    print(f"  full            {full_total:7.0f}ms total  stuck {full_stuck}/{_N}")
    print(f"  wall ratio (full/solo): {ratio:.2f}x", end="")
    if ratio > 1:
        print(f"  (full is {(ratio-1)*100:.0f}% slower in wall time)")
    else:
        print(f"  (full is {(1-ratio)*100:.0f}% faster in wall time)")
    print(f"  plan improvement: better={better_plan}  same={same_plan}"
          f"  worse={worse_plan}  more-placements={more_placements}"
          f"  (out of {_N} hands)")
    print(f"  outcome coverage (full): "
          f"triple={counts['triple']}  pair={counts['pair']}  "
          f"single={counts['single']}  stuck={counts['stuck']}")


if __name__ == "__main__":
    main()
