"""
corpus_lab_catalog.py — write the 21-puzzle corpus to the
BOARD_LAB catalog JSON so they show up in the lab gallery.

Each catalog entry uses the puzzle's `puzzle_name` from the
DB (fall back to "corpus_<sid>"), a 1-line description with
the trouble card + BFS-plan length + peak trouble, and the
puzzle's initial_state pulled directly from
`lynrummy_puzzle_seeds`.

Usage:
    python3 corpus_lab_catalog.py
        # writes games/lynrummy/board-lab/puzzles.json

This OVERWRITES the existing hand-crafted catalog. The
hand-crafted catalog can be restored by running:
    python3 board_lab_puzzles.py \\
        --write games/lynrummy/board-lab/puzzles.json
"""

import argparse
import json
import os
import sqlite3
import sys

import beginner as b
import bfs


DEFAULT_DB = "/home/steve/AngryGopher/prod/gopher.db"
SESSIONS_PATH = "corpus/sessions.txt"
CATALOG_PATH = "../board-lab/puzzles.json"


def _trouble_label(state):
    hand = state["hands"][state["active_player_index"]]["hand_cards"]
    if not hand:
        return "?"
    c = hand[0]["card"]
    return b.label_d((c["value"], c["suit"], c["origin_deck"]))


def _board_for_solver(state):
    return [[(bc["card"]["value"], bc["card"]["suit"],
              bc["card"]["origin_deck"])
             for bc in stack["board_cards"]]
            for stack in state["board"]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default=DEFAULT_DB)
    parser.add_argument("--sessions", default=SESSIONS_PATH)
    parser.add_argument("--out", default=CATALOG_PATH)
    parser.add_argument("--max-trouble", type=int, default=10)
    parser.add_argument("--max-states", type=int, default=200000)
    args = parser.parse_args()

    conn = sqlite3.connect(args.db)
    sids = [int(s.strip()) for s in open(args.sessions) if s.strip()]
    catalog = []

    for n, sid in enumerate(sids, start=1):
        row = conn.execute(
            "SELECT initial_state_json, puzzle_name "
            "FROM lynrummy_puzzle_seeds WHERE session_id=?",
            (sid,)).fetchone()
        if row is None:
            print(f"warning: no seed row for sid {sid}")
            continue
        state = json.loads(row[0])
        puzzle_name = row[1] or f"corpus_{sid}"
        trouble = _trouble_label(state)

        # Run BFS to summarize.
        board = _board_for_solver(state) + [
            [(state["hands"][state["active_player_index"]]["hand_cards"][0]["card"]["value"],
              state["hands"][state["active_player_index"]]["hand_cards"][0]["card"]["suit"],
              state["hands"][state["active_player_index"]]["hand_cards"][0]["card"]["origin_deck"])]
        ]
        plan = bfs.solve(
            board,
            max_trouble_outer=args.max_trouble,
            max_states=args.max_states,
            verbose=False)
        if plan is None:
            depth = "STUCK"
            solution_text = "(no plan within budget)"
        else:
            depth = f"{len(plan)}-line"
            solution_text = "\n".join(
                f"{i}. {line}" for i, line in enumerate(plan, 1))

        title = f"#{n}. corpus {sid} — trouble {trouble}"
        description = (
            f"Random-deal corpus puzzle (session {sid}). "
            f"Trouble: {trouble}. BFS plan: {depth}."
        )
        catalog.append({
            "name": puzzle_name,
            "title": title,
            "description": description,
            "initial_state": state,
            "agent_solution": solution_text,
        })

    out_payload = {"puzzles": catalog}
    out_path = args.out
    with open(out_path, "w") as f:
        json.dump(out_payload, f, indent=2)
    print(f"wrote {out_path} ({len(catalog)} puzzles)")


if __name__ == "__main__":
    main()
