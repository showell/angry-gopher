"""
puzzle_from_snapshot.py — turn a captured find_play snapshot
into a puzzle session for Steve to play.

Picks the slowest captured (hand, board) state from a
JSONL snapshot file (excluding outliers > 30s), constructs
a full initial_state with that hand + board, POSTs to
/new-puzzle-session, prints the URL.

Usage:
    python3 puzzle_from_snapshot.py /tmp/perf_snapshots.jsonl
        [--label "agent stuck on TH/8C ..."]
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


def _board_stack_dict(stack, loc):
    return {
        "board_cards": [
            {"card": _to_card_dict(c), "state": 0} for c in stack
        ],
        "loc": loc,
    }


def _hand_card_dict(card):
    return {"card": _to_card_dict(card), "state": 0}


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


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("snapshots")
    ap.add_argument("--base", default=DEFAULT_BASE)
    ap.add_argument("--label", default=None)
    ap.add_argument("--rank", type=int, default=1,
                    help=("1 = slowest, 2 = second-slowest, "
                          "etc. Skips outliers > 30s captured."))
    args = ap.parse_args()

    with open(args.snapshots) as f:
        snaps = [json.loads(l) for l in f if l.strip()]
    snaps = [s for s in snaps if s["total_wall"] < 30]
    snaps.sort(key=lambda s: s["total_wall"], reverse=True)
    rec = snaps[args.rank - 1]

    hand_cards = [_hand_card_dict(tuple(c)) for c in rec["hand"]]
    # Lay out the board stacks at fresh non-overlapping locations.
    board_stacks = []
    placed = []
    for stack in rec["board"]:
        s_tuples = [tuple(c) for c in stack]
        loc = geometry.find_open_loc(placed, card_count=len(s_tuples))
        sd = _board_stack_dict(s_tuples, loc)
        board_stacks.append(sd)
        placed.append(sd)

    # Two-player puzzle scaffolding (matches dealer.py shape).
    state = {
        "board": board_stacks,
        "hands": [
            {"hand_cards": hand_cards},
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

    stamp = datetime.datetime.now().strftime("%H%M%S")
    label = args.label or (
        f"agent runaway #{args.rank} "
        f"(captured {rec['total_wall']:.2f}s) {stamp}")
    puzzle_name = f"runaway_{args.rank}_{stamp}"

    c = Client(base=args.base)
    sid = _post_puzzle(c, label, puzzle_name, state)
    print(f"session id: {sid}")
    print(f"label:      {label}")
    print(f"hand cards: {[tuple(c) for c in rec['hand']]}")
    print(f"projections:")
    for p in rec["projections"]:
        print(f"  {p['kind']:9} cards={p['cards']} "
              f"wall={p['wall']:.2f}s found={p['found_plan']}")
    print(f"\nbrowse: {args.base}/play/{sid}")


if __name__ == "__main__":
    main()
