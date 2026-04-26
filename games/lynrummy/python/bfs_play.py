"""
bfs_play.py — replay a BFS plan on the actual board.

Pipeline (all three layers live in libraries to prevent drift):
  1. VERBs       : `bfs.solve` produces DSL lines + descs.
  2. VERB → PRIM : `verbs.step_to_primitives` decomposes each
                   move into UI primitives.
  3. PRIM → GEST : `primitives.send_one` handles wire-shape +
                   gesture synthesis + POST.

This driver is intentionally thin: it loads the puzzle, runs
the solver, walks the plan, and dispatches each primitive to
the canonical send path.

Usage:
    python3 bfs_play.py <source_sid>
        # creates a fresh agent puzzle session against the same
        # initial_state and replays the BFS plan on it.
"""

import argparse
import datetime
import json
import sqlite3
import sys
import urllib.request

import bfs
import buckets
import cards
import enumerator
import move
import primitives
import verbs
from client import Client


DEFAULT_DB = "/home/steve/AngryGopher/prod/gopher.db"
DEFAULT_BASE = "http://localhost:9000/gopher/lynrummy-elm"


def _post_puzzle(client, label, puzzle_name, state):
    body = json.dumps({
        "label": label,
        "puzzle_name": puzzle_name,
        "initial_state": state,
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{client.base}/new-puzzle-session",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST")
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())["session_id"]


def _solve_with_descs(initial_state, max_trouble):
    """Variant of bfs.solve that returns
    [(line, desc), ...] so the translator can act on each
    desc dict."""
    for cap in range(1, max_trouble + 1):
        result = _bfs_with_descs(initial_state, cap)
        if result is not None:
            return result
    return None


def _bfs_with_descs(initial, max_trouble):
    if buckets.trouble_count(initial[1], initial[2]) > max_trouble:
        return None
    if buckets.is_victory(initial[1], initial[2]):
        return []
    seen = {buckets.state_sig(*initial)}
    current_level = [(initial, [])]
    while current_level:
        current_level.sort(
            key=lambda e: buckets.trouble_count(e[0][1], e[0][2]))
        next_level = []
        for state, program in current_level:
            for desc, new_state in enumerator.enumerate_moves(state):
                _, t, g, _ = new_state
                tc = buckets.trouble_count(t, g)
                if tc > max_trouble:
                    continue
                sig = buckets.state_sig(*new_state)
                if sig in seen:
                    continue
                seen.add(sig)
                line = move.describe(desc)
                new_program = program + [(line, desc)]
                if buckets.is_victory(t, g):
                    return new_program
                next_level.append((new_state, new_program))
        current_level = next_level
    return None


def _initial_buckets(state):
    """Build (helper, trouble, growing, complete) from a server
    state. Treats the trouble-card-in-hand as already on the
    board for the BFS (matches the place_hand prelude)."""
    raw_board = [
        [(bc["card"]["value"], bc["card"]["suit"],
          bc["card"]["origin_deck"])
         for bc in s["board_cards"]]
        for s in state["board"]
    ]
    hand = state["hands"][state["active_player_index"]]["hand_cards"]
    trouble_card = (hand[0]["card"]["value"],
                    hand[0]["card"]["suit"],
                    hand[0]["card"]["origin_deck"])
    raw_board = raw_board + [[trouble_card]]
    helper, trouble = [], []
    for s in raw_board:
        if cards.classify(s) == "other":
            trouble.append(s)
        else:
            helper.append(s)
    return (helper, trouble, [], []), trouble_card


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_sid", type=int,
                        help="DB session id whose puzzle to replay.")
    parser.add_argument("--db", default=DEFAULT_DB)
    parser.add_argument("--base", default=DEFAULT_BASE)
    parser.add_argument("--max-trouble", type=int, default=10)
    args = parser.parse_args()

    conn = sqlite3.connect(args.db)
    row = conn.execute(
        "SELECT initial_state_json, puzzle_name "
        "FROM lynrummy_puzzle_seeds WHERE session_id=?",
        (args.source_sid,)).fetchone()
    if not row:
        sys.exit(f"no puzzle for sid {args.source_sid}")
    state = json.loads(row[0])
    puzzle_name = row[1] or f"corpus_{args.source_sid}"

    initial_buckets, trouble_card = _initial_buckets(state)
    plan = _solve_with_descs(initial_buckets, args.max_trouble)
    if plan is None:
        sys.exit("no plan found")
    print(f"plan: {len(plan)} lines")

    c = Client(base=args.base)
    stamp = datetime.datetime.now().strftime("%H%M%S")
    label = f"agent BFS replay: {puzzle_name} {stamp}"
    sid = _post_puzzle(c, label,
                       f"{puzzle_name}_bfs_replay", state)
    print(f"session: {args.base}/play/{sid}")

    # Prelude: place the trouble card from hand onto the board
    # so the rest of the plan (which assumes it's a singleton
    # stack) lines up.
    place_loc = {"top": 50, "left": 600}
    place_wire = {
        "action": "place_hand",
        "hand_card": {"value": trouble_card[0],
                      "suit": trouble_card[1],
                      "origin_deck": trouble_card[2]},
        "loc": place_loc,
    }
    c.send_action(sid, place_wire, gesture_metadata=None)

    # Walk the plan. Pull live state once, then advance the
    # local board per primitive.
    server_state = c.get_state(sid)["state"]
    local = server_state["board"]

    for step_num, (line, desc) in enumerate(plan, 1):
        print(f"\nstep {step_num}: {line}")
        prims = verbs.step_to_primitives(desc, local)
        for prim in prims:
            local = primitives.send_one(c, sid, prim, local,
                                        verbose=True)
            if local is None:
                sys.exit(f"  send error at step {step_num}")
    print(f"\nDONE. Reload {args.base}/play/{sid} to watch.")


if __name__ == "__main__":
    main()
