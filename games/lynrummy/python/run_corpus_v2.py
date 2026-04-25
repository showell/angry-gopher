"""
run_corpus_v2.py — benchmark beginner.py against the
random-deal corpus.

Reads `corpus/sessions.txt` (one puzzle session id per
line). For each, loads the puzzle's initial_state from the
DB, asks beginner.py to solve, prints a one-line summary
per puzzle. Final block prints depth distribution + total
wall.

Usage:
    python3 run_corpus_v2.py [--max-nodes N] [--max-compound K]
"""

import argparse
import json
import sqlite3
import time

import beginner as b


DEFAULT_DB = "/home/steve/AngryGopher/prod/gopher.db"
SESSIONS_PATH = "corpus/sessions.txt"


def s2b(state):
    return [[(bc["card"]["value"], bc["card"]["suit"], bc["card"]["origin_deck"])
             for bc in stack["board_cards"]]
            for stack in state["board"]]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--max-nodes", type=int, default=10000)
    p.add_argument("--max-compound", type=int, default=10)
    p.add_argument("--max-seconds", type=float, default=120.0)
    p.add_argument("--db", default=DEFAULT_DB)
    p.add_argument("--sessions", default=SESSIONS_PATH)
    args = p.parse_args()

    conn = sqlite3.connect(args.db)
    sids = [int(s.strip()) for s in open(args.sessions) if s.strip()]
    print(f"corpus_v2: {len(sids)} puzzles, "
          f"max_nodes={args.max_nodes}, "
          f"max_compound={args.max_compound}", flush=True)
    print(f"{'sid':>4} {'trouble':>8} {'depth':>5} {'wall':>6}",
          flush=True)

    total_wall = 0.0
    depth_dist = {}

    for sid in sids:
        row = conn.execute(
            "SELECT initial_state_json FROM lynrummy_puzzle_seeds "
            "WHERE session_id=?", (sid,)).fetchone()
        state = json.loads(row[0])
        hand = state["hands"][state["active_player_index"]]["hand_cards"]
        trouble = (hand[0]["card"]["value"], hand[0]["card"]["suit"],
                   hand[0]["card"]["origin_deck"])
        board = s2b(state) + [[trouble]]
        t0 = time.time()
        plan = b.beginner_plan(
            board,
            max_compound=args.max_compound,
            max_nodes=args.max_nodes,
            max_seconds=args.max_seconds)
        wall = time.time() - t0
        total_wall += wall
        if plan is None:
            depth = "STUCK"
            depth_dist["stuck"] = depth_dist.get("stuck", 0) + 1
        else:
            depth = len(plan)
            depth_dist[depth] = depth_dist.get(depth, 0) + 1
        print(f"{sid:>4} {b.label_d(trouble):>8} "
              f"{str(depth):>5} {wall:>5.2f}s", flush=True)

    print()
    print(f"total wall: {total_wall:.1f}s")
    print("depth distribution:")
    for k in sorted(depth_dist.keys(), key=lambda x: (isinstance(x, str), x)):
        print(f"  {k}: {depth_dist[k]}")


if __name__ == "__main__":
    main()
