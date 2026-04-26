"""
runaway_puzzles.py — turn each cap-exhausting projection
in a JSONL capture into a puzzle session.

For each runaway projection, build a puzzle whose hand is
JUST the evil card and whose board is the snapshot's board.
Steve plays each to see what the agent gave up on.

Usage:
    python3 runaway_puzzles.py /tmp/runaway_hunt.jsonl
"""

import argparse
import datetime
import json
import sys
import urllib.request

import geometry
from client import Client


DEFAULT_BASE = "http://localhost:9000/gopher/lynrummy-elm"


def _to_card_dict(card):
    return {"value": card[0], "suit": card[1], "origin_deck": card[2]}


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


def _card_label(c):
    rank = {1: "A", 10: "T", 11: "J", 12: "Q", 13: "K"}.get(c[0], str(c[0]))
    suit = "CDSH"[c[1]]
    deck = "'" if c[2] else ""
    return f"{rank}{suit}{deck}"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("snapshots")
    ap.add_argument("--base", default=DEFAULT_BASE)
    args = ap.parse_args()

    with open(args.snapshots) as f:
        snaps = [json.loads(l) for l in f if l.strip()]

    # Find unique runaway projections (per (snap_idx, evil_card)).
    seen_keys = set()
    runaways = []
    for s_idx, snap in enumerate(snaps):
        for proj in snap["projections"]:
            for ex in proj.get("exhaustions", []):
                if not ex.get("hit_max_states"):
                    continue
                evil = tuple(proj["cards"][0])
                key = (s_idx, evil)
                if key in seen_keys:
                    continue
                seen_keys.add(key)
                runaways.append({
                    "snap_idx": s_idx,
                    "evil": evil,
                    "wall": proj["wall"],
                    "board": [
                        [tuple(c) for c in s] for s in snap["board"]
                    ],
                })
                break  # one record per (snap, projection); skip more exhaustions

    if not runaways:
        print("No runaway projections in snapshot. Nothing to post.")
        return

    print(f"Found {len(runaways)} unique runaway projections.\n")
    c = Client(base=args.base)
    stamp = datetime.datetime.now().strftime("%H%M%S")

    for i, r in enumerate(runaways, 1):
        # Lay out the board stacks at non-overlapping locations.
        board_stacks = []
        placed = []
        for stack in r["board"]:
            loc = geometry.find_open_loc(placed, card_count=len(stack))
            sd = {
                "board_cards": [
                    {"card": _to_card_dict(c2), "state": 0}
                    for c2 in stack
                ],
                "loc": loc,
            }
            board_stacks.append(sd)
            placed.append(sd)

        hand_card = {"card": _to_card_dict(r["evil"]), "state": 0}

        state = {
            "board": board_stacks,
            "hands": [
                {"hand_cards": [hand_card]},
                {"hand_cards": []},
            ],
            "deck": [],
            "discard": [],
            "active_player_index": 0,
            "scores": [0, 0],
            "victor_awarded": False,
            "turn_start_board_score": 0,
            "turn_index": 0,
            "cards_played_this_turn": 0,
        }

        evil_label = _card_label(r["evil"])
        label = (f"runaway #{i} — evil card {evil_label} "
                 f"({r['wall']:.1f}s) {stamp}")
        puzzle_name = (
            f"runaway_{i}_{evil_label}_{stamp}"
            .replace("'", "p1"))

        sid = _post_puzzle(c, label, puzzle_name, state)
        print(f"#{i} evil={evil_label} wall={r['wall']:.1f}s "
              f"board={len(r['board'])} stacks")
        print(f"   {args.base}/play/{sid}")


if __name__ == "__main__":
    main()
