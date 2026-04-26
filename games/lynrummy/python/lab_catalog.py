"""
lab_catalog.py — write the BOARD_LAB catalog JSON the Elm
gallery loads.

Pulls puzzle seeds from the DB:
  - Hand-curated rows from `board_lab_puzzles.py` (legacy
    catalog written separately to puzzles.json — this script
    leaves them alone).
  - Corpus seeds (the 21 sessions in corpus/sessions.txt;
    matches what corpus_lab_catalog.py used to do alone).
  - Mined puzzle seeds (rows where puzzle_name LIKE 'mined_%').

Each row → catalog entry with name / title / description /
initial_state / agent_solution. Output goes to
games/lynrummy/board-lab/puzzles.json. Replaces
corpus_lab_catalog.py as the canonical generator.

Usage:
    python3 games/lynrummy/python/lab_catalog.py
"""

import argparse
import json
import os
import sqlite3
import sys

import bfs
from cards import card_label

DEFAULT_DB = "/home/steve/AngryGopher/prod/gopher.db"
SESSIONS_PATH = "corpus/sessions.txt"
CATALOG_PATH = "../board-lab/puzzles.json"


def _trouble_label(state):
    hand = state["hands"][state["active_player_index"]]["hand_cards"]
    if not hand:
        return "?"
    c = hand[0]["card"]
    return card_label((c["value"], c["suit"], c["origin_deck"]))


def _hand_label(state):
    hand = state["hands"][state["active_player_index"]]["hand_cards"]
    parts = [card_label((hc["card"]["value"], hc["card"]["suit"],
                         hc["card"]["origin_deck"]))
             for hc in hand]
    return " + ".join(parts) if parts else "(empty)"


def _board_for_solver(state):
    return [[(bc["card"]["value"], bc["card"]["suit"],
              bc["card"]["origin_deck"])
             for bc in stack["board_cards"]]
            for stack in state["board"]]


def _augmented_for_bfs(state):
    """The puzzle's board + hand-cards-as-singletons (the
    shape the BFS receives once placements are projected)."""
    board = _board_for_solver(state)
    hand_cards = []
    for hc in state["hands"][state["active_player_index"]]["hand_cards"]:
        c = hc["card"]
        hand_cards.append((c["value"], c["suit"], c["origin_deck"]))
    return board + [list(hand_cards)] if hand_cards else board


def _summarize(state, max_trouble, max_states):
    augmented = _augmented_for_bfs(state)
    plan = bfs.solve(augmented, max_trouble_outer=max_trouble,
                     max_states=max_states, verbose=False)
    if plan is None:
        return "STUCK", "(no plan within budget)"
    depth = f"{len(plan)}-line"
    text = "\n".join(f"{i}. {line}"
                     for i, line in enumerate(plan, 1))
    return depth, text


def _load_corpus_sids(sessions_path):
    if not os.path.exists(sessions_path):
        return []
    return [int(s.strip()) for s in open(sessions_path)
            if s.strip()]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--db", default=DEFAULT_DB)
    p.add_argument("--sessions", default=SESSIONS_PATH)
    p.add_argument("--out", default=CATALOG_PATH)
    p.add_argument("--max-trouble", type=int, default=10)
    p.add_argument("--max-states", type=int, default=200000)
    args = p.parse_args()

    conn = sqlite3.connect(args.db)
    catalog = []

    corpus_sids = _load_corpus_sids(args.sessions)
    for n, sid in enumerate(corpus_sids, start=1):
        row = conn.execute(
            "SELECT initial_state_json, puzzle_name "
            "FROM lynrummy_puzzle_seeds WHERE session_id=?",
            (sid,)).fetchone()
        if row is None:
            continue
        state = json.loads(row[0])
        puzzle_name = row[1] or f"corpus_{sid}"
        trouble = _trouble_label(state)
        depth, plan_text = _summarize(
            state, args.max_trouble, args.max_states)
        title = f"#{n}. corpus {sid} — trouble {trouble}"
        description = (
            f"Random-deal corpus puzzle (session {sid}). "
            f"Trouble: {trouble}. BFS plan: {depth}.")
        catalog.append({
            "name": puzzle_name,
            "title": title,
            "description": description,
            "initial_state": state,
            "agent_solution": plan_text,
        })

    # Mined puzzles. Order by session_id so the catalog is
    # stable across regenerations.
    mined_rows = conn.execute(
        "SELECT session_id, initial_state_json, puzzle_name "
        "FROM lynrummy_puzzle_seeds "
        "WHERE puzzle_name LIKE 'mined_%' "
        "ORDER BY session_id").fetchall()
    for sid, state_json, puzzle_name in mined_rows:
        state = json.loads(state_json)
        hand = _hand_label(state)
        depth, plan_text = _summarize(
            state, args.max_trouble, args.max_states)
        title = f"{puzzle_name} — hand {hand} ({depth})"
        description = (
            f"Mined puzzle (session {sid}). Hand: {hand}. "
            f"BFS plan: {depth}.")
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
