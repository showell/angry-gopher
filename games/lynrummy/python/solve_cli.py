"""
solve_cli.py — quick CLI for solving a single board by session id.

Loads `lynrummy_puzzle_seeds.initial_state_json` for the
given session id, partitions into HELPER + TROUBLE, and
runs `bfs.solve`. Prints the resulting plan (or "no plan").

Usage:  python3 solve_cli.py [SID]   (SID defaults to 128)

Originally lived as `if __name__ == "__main__":` in
`bfs_solver.py`; lifted to its own file 2026-04-26 when
`bfs_solver.py` was retired in favor of the
`buckets/cards/move/enumerator/bfs` module split.
"""

import json
import sqlite3
import sys

import bfs
from cards import card_label


def main():
    sid = int(sys.argv[1]) if len(sys.argv) > 1 else 128
    conn = sqlite3.connect("/home/steve/AngryGopher/prod/gopher.db")
    row = conn.execute(
        "SELECT initial_state_json FROM lynrummy_puzzle_seeds "
        "WHERE session_id=?", (sid,)).fetchone()
    state = json.loads(row[0])

    def s2b(state):
        return [[(bc["card"]["value"], bc["card"]["suit"],
                  bc["card"]["origin_deck"])
                 for bc in stack["board_cards"]]
                for stack in state["board"]]

    hand = state["hands"][state["active_player_index"]]["hand_cards"]
    trouble_card = (hand[0]["card"]["value"], hand[0]["card"]["suit"],
                    hand[0]["card"]["origin_deck"])
    board = s2b(state) + [[trouble_card]]
    print(f"=== solve_cli session {sid} "
          f"(trouble={card_label(trouble_card)}) ===")
    plan = bfs.solve(board, max_states=200)
    if plan:
        print("\nFinal plan:")
        for i, l in enumerate(plan, 1):
            print(f"  {i}. {l}")
    else:
        print("\nNo plan found.")


if __name__ == "__main__":
    main()
