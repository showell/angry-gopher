#!/usr/bin/env python3
"""
agent_board_lab.py — run the Python strategy against every
BOARD_LAB catalog puzzle and persist its solution alongside
human attempts.

For each puzzle in the catalog:
  1. POST a new puzzle session labeled "agent: <title>" with
     the same initial_state and puzzle_name a human session
     would use, so agent + human attempts land keyed to the
     same puzzle_name in lynrummy_puzzle_seeds.
  2. Run strategy.choose_play on (hand, board). If a play
     fires, send its primitives with gesture telemetry
     synthesized via gesture_synth.
  3. Run strategy.find_follow_up_merges on the resulting
     board and send any follow-up merge_stack primitives too.
  4. Stop when choose_play returns None (no more plays) or
     after one primary trick + follow-ups — whichever comes
     first. Unlike auto_player's full-game loop, this plays
     the puzzle the same way a human in BOARD_LAB would:
     one visible turn's worth of moves.

Produces a row per catalog puzzle in lynrummy_puzzle_seeds
with puzzle_name set, plus one or more rows in
lynrummy_elm_actions per session. Ready for the analysis
script (next) to compare against human attempts.

Usage:
    python3 games/lynrummy/python/agent_board_lab.py
    python3 games/lynrummy/python/agent_board_lab.py --only tight_right_edge
"""

import argparse
import copy
import json
import sys
import urllib.request
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import board_lab_puzzles
import client as lynrummy_client
import gesture_synth
import strategy


def _new_puzzle_session(client, label, puzzle_name, initial_state):
    """POST to /new-puzzle-session with puzzle_name set so the
    session is queryable by the catalog key."""
    body = json.dumps({
        "label": label,
        "puzzle_name": puzzle_name,
        "initial_state": initial_state,
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{client.base}/new-puzzle-session",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())["session_id"]


def _to_wire_shape(prim, board):
    """Translate an internal index-based primitive to the
    CardStack-ref wire shape the server expects. Same mapping
    as auto_player.py's local helper — kept inline here so the
    harness stays self-contained."""
    kind = prim["action"]
    if kind == "split":
        return {"action": "split",
                "stack": board[prim["stack_index"]],
                "card_index": prim["card_index"]}
    if kind == "merge_stack":
        return {"action": "merge_stack",
                "source": board[prim["source_stack"]],
                "target": board[prim["target_stack"]],
                "side": prim.get("side", "right")}
    if kind == "merge_hand":
        return {"action": "merge_hand",
                "hand_card": prim["hand_card"],
                "target": board[prim["target_stack"]],
                "side": prim.get("side", "right")}
    if kind == "move_stack":
        return {"action": "move_stack",
                "stack": board[prim["stack_index"]],
                "new_loc": prim["new_loc"]}
    return prim


def _apply_locally(board, prim):
    """Mirror of server-side board mutation so gesture_synth
    sees the correct pre-primitive state for the NEXT primitive."""
    kind = prim["action"]
    if kind == "merge_hand":
        return strategy._apply_merge_hand(
            board, prim["target_stack"], prim["hand_card"],
            prim.get("side", "right"))
    if kind == "merge_stack":
        return strategy._apply_merge_stack(
            board, prim["source_stack"], prim["target_stack"],
            prim.get("side", "right"))
    if kind == "move_stack":
        return strategy._apply_move(
            board, prim["stack_index"], prim["new_loc"])
    if kind == "split":
        return strategy._apply_split(
            board, prim["stack_index"], prim["card_index"])
    if kind == "place_hand":
        return strategy._apply_place_hand(
            board, prim["hand_card"], prim["loc"])
    return board


def _send_one(client, session_id, prim, board, verbose):
    """Synthesize gesture metadata + POST one primitive. Returns
    the updated local board, or None on send error."""
    endpoints = gesture_synth.drag_endpoints(prim, board)
    meta = (gesture_synth.synthesize(*endpoints)
            if endpoints is not None else None)
    wire = _to_wire_shape(prim, board)
    try:
        client.send_action(session_id, wire, gesture_metadata=meta)
    except RuntimeError as e:
        if verbose:
            print(f"    send failed: {e}")
        return None
    if verbose:
        kind = prim["action"]
        path_ct = len(meta["path"]) if meta and "path" in meta else 0
        print(f"    sent {kind} (gesture={path_ct} samples)")
    return _apply_locally(board, prim)


def play_puzzle(client, puzzle, verbose=True):
    """Run the agent on one catalog puzzle. Returns a result
    dict summarizing what happened."""
    state = puzzle["initial_state"]
    board = copy.deepcopy(state["board"])
    hand = copy.deepcopy(state["hands"][0]["hand_cards"])

    if verbose:
        print(f"\n== {puzzle['title']} ({puzzle['name']}) ==")
        print(f"   hand: {len(hand)} cards   board: {len(board)} stacks")

    session_id = _new_puzzle_session(
        client,
        label=f"agent: {puzzle['title']}",
        puzzle_name=puzzle["name"],
        initial_state=state,
    )
    if verbose:
        print(f"   session: {session_id}")

    play = strategy.choose_play(hand, board)
    if play is None:
        if verbose:
            print("   no play fires; skipping")
        return {"puzzle": puzzle["name"], "session": session_id,
                "primary": None, "follow_ups": 0, "sent": 0}

    if verbose:
        print(f"   primary: {play['trick_id']} "
              f"({len(play['primitives'])} primitives)")

    sent = 0
    for prim in play["primitives"]:
        new_board = _send_one(client, session_id, prim, board, verbose)
        if new_board is None:
            return {"puzzle": puzzle["name"], "session": session_id,
                    "primary": play["trick_id"], "follow_ups": 0,
                    "sent": sent, "error": "send failed"}
        board = new_board
        sent += 1

    follow_ups = strategy.find_follow_up_merges(board)
    if follow_ups and verbose:
        print(f"   follow-up merges: {len(follow_ups)}")
    for prim in follow_ups:
        new_board = _send_one(client, session_id, prim, board, verbose)
        if new_board is None:
            break
        board = new_board
        sent += 1

    return {"puzzle": puzzle["name"], "session": session_id,
            "primary": play["trick_id"],
            "follow_ups": len(follow_ups), "sent": sent}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", metavar="NAME",
                        help="Play just this puzzle (by name).")
    parser.add_argument("--base",
                        default=lynrummy_client.DEFAULT_BASE,
                        help="Base URL of the lynrummy-elm endpoints.")
    parser.add_argument("--quiet", action="store_true",
                        help="Only print final summary.")
    args = parser.parse_args()

    client = lynrummy_client.Client(base=args.base)
    catalog = board_lab_puzzles.catalog()
    if args.only:
        catalog = [p for p in catalog if p["name"] == args.only]
        if not catalog:
            print(f"No puzzle named {args.only!r} in catalog.",
                  file=sys.stderr)
            return 1

    results = [
        play_puzzle(client, p, verbose=not args.quiet)
        for p in catalog
    ]

    print()
    print("Agent attempts:")
    for r in results:
        status = r.get("primary") or "-"
        fu = r["follow_ups"]
        print(f"  session={r['session']:<4} puzzle={r['puzzle']:<28} "
              f"trick={status:<20} follow_ups={fu} sent={r['sent']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
