"""
puzzle_catalog.py — write the Puzzles catalog JSON the Elm
gallery loads.

Reads mined puzzle seeds from
`games/lynrummy/conformance/mined_seeds.json` (committed,
overwritten by `tools/mine_puzzles.py`). Each seed → catalog
entry with name / title / initial_state. The title carries
the BFS plan length ("mined_003_KSp1 (5-line)"); the gallery
doesn't render a description block any more — repeating that
line in prose was just noise.

The corpus block was removed 2026-04-26 — corpus seeds carry
hand cards, and the Puzzles surface now only carries board-only
puzzles where the hand is empty.

Usage:
    python3 games/lynrummy/python/puzzle_catalog.py
"""

import argparse
import json
from pathlib import Path

import bfs

REPO = Path("/home/steve/showell_repos/angry-gopher")
DEFAULT_SEEDS = REPO / "games/lynrummy/conformance/mined_seeds.json"
CATALOG_PATH = "../puzzles/puzzles.json"


def _board_for_solver(state):
    return [[(bc["card"]["value"], bc["card"]["suit"],
              bc["card"]["origin_deck"])
             for bc in stack["board_cards"]]
            for stack in state["board"]]


def _depth_label(state, max_trouble, max_states):
    board = _board_for_solver(state)
    plan = bfs.solve(board, max_trouble_outer=max_trouble,
                     max_states=max_states, verbose=False)
    if plan is None:
        return "STUCK"
    return f"{len(plan)}-line"


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--seeds", default=str(DEFAULT_SEEDS))
    p.add_argument("--out", default=CATALOG_PATH)
    p.add_argument("--max-trouble", type=int, default=10)
    p.add_argument("--max-states", type=int, default=200000)
    args = p.parse_args()

    with open(args.seeds) as f:
        seeds = json.load(f)["seeds"]

    catalog = []
    for seed in seeds:
        state = seed["initial_state"]
        puzzle_name = seed["puzzle_name"]
        depth = _depth_label(state, args.max_trouble, args.max_states)
        catalog.append({
            "name": puzzle_name,
            "title": f"{puzzle_name} ({depth})",
            "initial_state": state,
        })

    out_payload = {"puzzles": catalog}
    with open(args.out, "w") as f:
        json.dump(out_payload, f, indent=2)
    print(f"wrote {args.out} ({len(catalog)} puzzles)")


if __name__ == "__main__":
    main()
