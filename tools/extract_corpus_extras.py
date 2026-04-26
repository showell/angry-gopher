"""
extract_corpus_extras.py — mine a /tmp/*.jsonl agent capture
for projection puzzles to add to the conformance DSL corpus.

Reads the file emitted by `agent_game.py --offline --capture
FILE`, picks a sample of distinct-board projections, runs
each through Python's BFS to get the canonical plan_lines (or
prove unsolvability), and emits a DSL fixture file.

Per Steve's guidance (2026-04-26), unsolvable cases are
extra-weighted: target ~15 unsolvable + ~10 solvable per
extraction run.

Usage:
    python3 tools/extract_corpus_extras.py /tmp/wider_corpus.jsonl

Output: games/lynrummy/conformance/scenarios/planner_corpus_extras.dsl
"""

import argparse
import json
import sys
from pathlib import Path

REPO = Path("/home/steve/showell_repos/angry-gopher")
sys.path.insert(0, str(REPO / "games/lynrummy/python"))

import bfs  # noqa: E402

OUT_PATH = (
    REPO / "games/lynrummy/conformance/scenarios/planner_corpus_extras.dsl")

UNSOLVABLE_TARGET = 15
SOLVABLE_TARGET = 10

RANKS = "A23456789TJQK"
SUITS = "CDSH"


def card_label_dsl(value, suit, deck):
    return RANKS[value - 1] + SUITS[suit] + ("'" if deck else "")


def board_signature(board):
    """Stable hash of a board (list of stacks of card-tuples).
    Sort each stack, sort the stacks, dump to JSON."""
    canon = sorted([sorted(stack) for stack in board])
    return json.dumps(canon)


def render_scenario(name, helper_stacks, trouble_stacks, plan):
    """`helper_stacks` and `trouble_stacks` are lists of
    label-string lists. `plan` is None or list[str]."""
    lines = [f"scenario {name}"]
    if plan is None:
        lines.append(
            f"  desc: {name}. Auto-generated from offline play; "
            "asserts BFS proves no plan.")
    else:
        lines.append(
            f"  desc: {name}. Auto-generated from offline play.")
    lines.append("  op: solve")
    lines.append("  helper:")
    for stack in helper_stacks:
        lines.append(f"    at (0,0): {' '.join(stack)}")
    lines.append("  trouble:")
    for stack in trouble_stacks:
        lines.append(f"    at (0,0): {' '.join(stack)}")
    if plan is None:
        lines.append("  expect: no_plan")
    else:
        lines.append("  expect:")
        lines.append("    plan_lines:")
        for line in plan:
            lines.append(f"      - {json.dumps(line)}")
    return "\n".join(lines)


def partition(augmented):
    """Split a flat board into helper / trouble buckets the
    way bfs.solve does."""
    from cards import classify
    helper = [s for s in augmented if classify(s) != "other"]
    trouble = [s for s in augmented if classify(s) == "other"]
    return helper, trouble


def scenario_from_projection(record, projection, idx):
    """Build (name, helper_labels, trouble_labels, plan) or
    None if the projection should be skipped."""
    board = [
        [tuple(c) for c in stack] for stack in record["board"]
    ]
    extra = [tuple(c) for c in projection["cards"]]
    augmented = board + [extra]
    helper, trouble = partition(augmented)
    plan = bfs.solve(
        augmented, max_trouble_outer=10, max_states=200000,
        verbose=False)
    cards_label = "_".join(
        card_label_dsl(*c).replace("'", "p") for c in extra)
    name = f"extra_{idx:03d}_{cards_label}"

    def stacks_to_labels(stacks):
        return [[card_label_dsl(*c) for c in s] for s in stacks]

    return (name, stacks_to_labels(helper),
            stacks_to_labels(trouble), plan)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("snapshots",
                    help="Path to agent_game.py --offline --capture file")
    args = ap.parse_args()

    seen_boards = set()
    unsolvable = []
    solvable = []
    with open(args.snapshots) as f:
        for line in f:
            rec = json.loads(line)
            board_sig = board_signature(rec["board"])
            if board_sig in seen_boards:
                # Skip subsequent projections from same board to
                # keep variety high — every record contributes at
                # most one projection.
                continue
            for proj in rec.get("projections", []):
                # Take the first projection from this record
                # that fills our remaining quota.
                if (proj["found_plan"]
                        and len(solvable) < SOLVABLE_TARGET):
                    solvable.append((rec, proj))
                    seen_boards.add(board_sig)
                    break
                if (not proj["found_plan"]
                        and len(unsolvable) < UNSOLVABLE_TARGET):
                    unsolvable.append((rec, proj))
                    seen_boards.add(board_sig)
                    break
            if (len(unsolvable) >= UNSOLVABLE_TARGET
                    and len(solvable) >= SOLVABLE_TARGET):
                break

    scenarios = []
    idx = 0
    for rec, proj in unsolvable + solvable:
        idx += 1
        result = scenario_from_projection(rec, proj, idx)
        if result is None:
            continue
        name, helper, trouble, plan = result
        scenarios.append(render_scenario(name, helper, trouble, plan))

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    out = []
    out.append("# AUTO-GENERATED by tools/extract_corpus_extras.py.")
    out.append(
        "# Mined from agent_game.py --offline captures. Provides")
    out.append(
        "# additional port-parity coverage beyond planner_corpus.dsl,")
    out.append("# with unsolvable cases extra-weighted "
               "(unsolvability is extremely load-bearing).")
    out.append("")
    out.extend(scenarios)
    out.append("")
    OUT_PATH.write_text("\n\n".join(out))
    n_unsolv = sum(1 for s in scenarios if "no_plan" in s)
    n_solv = len(scenarios) - n_unsolv
    print(
        f"wrote {OUT_PATH}: {n_solv} solvable + {n_unsolv} unsolvable")


if __name__ == "__main__":
    main()
