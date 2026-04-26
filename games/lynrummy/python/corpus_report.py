"""
corpus_report.py — runs bfs_solver against the corpus and
emits a Markdown report to claude-steve.

Output goes to ~/showell_repos/claude-steve/random020.md by
default (overwritten each run). Each puzzle gets a section
with the initial board (one stack per row) and the solver's
plan (as a fenced code block).

Usage:
    python3 corpus_report.py [--out PATH]
"""

import argparse
import json
import os
import sqlite3
import sys
import time

import beginner as b
import bfs


DEFAULT_DB = "/home/steve/AngryGopher/prod/gopher.db"
SESSIONS_PATH = "corpus/sessions.txt"
DEFAULT_OUT = os.path.expanduser(
    "~/showell_repos/claude-steve/random020.md")


def s2b(state):
    return [[(bc["card"]["value"], bc["card"]["suit"],
              bc["card"]["origin_deck"])
             for bc in stack["board_cards"]]
            for stack in state["board"]]


def render_board(stacks):
    sorted_stacks = sorted(stacks, key=lambda s: s[0][0])
    return "\n".join(
        " ".join(b.label_d(c) for c in s) for s in sorted_stacks)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", default=DEFAULT_OUT)
    p.add_argument("--db", default=DEFAULT_DB)
    p.add_argument("--sessions", default=SESSIONS_PATH)
    p.add_argument("--max-trouble", type=int, default=10)
    p.add_argument("--max-states", type=int, default=200000)
    args = p.parse_args()

    conn = sqlite3.connect(args.db)
    sids = [int(s.strip()) for s in open(args.sessions) if s.strip()]

    rows = []
    total_wall = 0.0
    distribution = {}

    for sid in sids:
        row = conn.execute(
            "SELECT initial_state_json FROM lynrummy_puzzle_seeds "
            "WHERE session_id=?", (sid,)).fetchone()
        state = json.loads(row[0])
        hand = state["hands"][state["active_player_index"]]["hand_cards"]
        trouble = (hand[0]["card"]["value"], hand[0]["card"]["suit"],
                   hand[0]["card"]["origin_deck"])
        # Board with trouble singleton appended (matches what
        # the solver receives).
        board = s2b(state) + [[trouble]]

        t0 = time.time()
        plan = bfs.solve(
            board,
            max_trouble_outer=args.max_trouble,
            max_states=args.max_states,
            verbose=False)
        wall = time.time() - t0
        total_wall += wall
        depth = len(plan) if plan is not None else "STUCK"
        distribution[depth] = distribution.get(depth, 0) + 1
        rows.append({
            "sid": sid,
            "trouble": trouble,
            "board": board,
            "plan": plan,
            "depth": depth,
            "wall": wall,
        })

    out_path = args.out
    with open(out_path, "w") as f:
        f.write("# Corpus solutions report\n\n")
        f.write(f"Generated: bfs.solve, "
                f"max_trouble_outer={args.max_trouble}, "
                f"max_states={args.max_states}.\n\n")
        f.write(f"**Total wall**: {total_wall:.2f}s across "
                f"{len(rows)} puzzles.\n\n")
        f.write("**Depth distribution**:\n\n")
        f.write("| depth | count |\n|---|---|\n")
        for k in sorted(distribution.keys(),
                        key=lambda x: (isinstance(x, str), x)):
            f.write(f"| {k} | {distribution[k]} |\n")
        f.write("\n---\n\n")

        for r in rows:
            sid = r["sid"]
            tb = b.label_d(r["trouble"])
            f.write(f"## sid {sid} — trouble {tb} "
                    f"(depth {r['depth']}, "
                    f"{r['wall'] * 1000:.0f}ms)\n\n")
            f.write("Initial board:\n\n")
            f.write("```\n")
            f.write(render_board(r["board"]))
            f.write("\n```\n\n")
            f.write("Plan:\n\n")
            f.write("```\n")
            if r["plan"]:
                for i, line in enumerate(r["plan"], 1):
                    f.write(f"{i}. {line}\n")
            else:
                f.write("STUCK — no plan within budget.\n")
            f.write("```\n\n")

    print(f"wrote {out_path} ({len(rows)} puzzles, "
          f"{total_wall:.2f}s total wall)")


if __name__ == "__main__":
    main()
