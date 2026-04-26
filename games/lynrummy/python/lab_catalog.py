"""
lab_catalog.py — write the BOARD_LAB catalog JSON the Elm
gallery loads.

Pulls mined puzzle seeds (rows where puzzle_name LIKE
'mined_%') from the DB. Each row → catalog entry with name /
title / description / initial_state / agent_solution. Output
goes to games/lynrummy/board-lab/puzzles.json.

The corpus block was removed 2026-04-26 — corpus seeds carry
hand cards, and the lab now only surfaces board-only puzzles
where the hand is empty.

Usage:
    python3 games/lynrummy/python/lab_catalog.py
"""

import argparse
import json
import sqlite3

import bfs

DEFAULT_DB = "/home/steve/AngryGopher/prod/gopher.db"
CATALOG_PATH = "../board-lab/puzzles.json"


def _board_for_solver(state):
    return [[(bc["card"]["value"], bc["card"]["suit"],
              bc["card"]["origin_deck"])
             for bc in stack["board_cards"]]
            for stack in state["board"]]


def _summarize(state, max_trouble, max_states):
    board = _board_for_solver(state)
    plan = bfs.solve(board, max_trouble_outer=max_trouble,
                     max_states=max_states, verbose=False)
    if plan is None:
        return "STUCK", "(no plan within budget)"
    depth = f"{len(plan)}-line"
    text = "\n".join(f"{i}. {line}"
                     for i, line in enumerate(plan, 1))
    return depth, text


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--db", default=DEFAULT_DB)
    p.add_argument("--out", default=CATALOG_PATH)
    p.add_argument("--max-trouble", type=int, default=10)
    p.add_argument("--max-states", type=int, default=200000)
    args = p.parse_args()

    conn = sqlite3.connect(args.db)
    catalog = []

    mined_rows = conn.execute(
        "SELECT session_id, initial_state_json, puzzle_name "
        "FROM lynrummy_puzzle_seeds "
        "WHERE puzzle_name LIKE 'mined_%' "
        "ORDER BY session_id").fetchall()
    for sid, state_json, puzzle_name in mined_rows:
        state = json.loads(state_json)
        depth, plan_text = _summarize(
            state, args.max_trouble, args.max_states)
        title = f"{puzzle_name} ({depth})"
        description = f"Mined puzzle (session {sid}). BFS plan: {depth}."
        catalog.append({
            "name": puzzle_name,
            "title": title,
            "description": description,
            "initial_state": state,
            "agent_solution": plan_text,
        })

    out_payload = {"puzzles": catalog}
    with open(args.out, "w") as f:
        json.dump(out_payload, f, indent=2)
    print(f"wrote {args.out} ({len(catalog)} puzzles)")


if __name__ == "__main__":
    main()
