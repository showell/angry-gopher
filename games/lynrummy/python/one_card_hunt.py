"""
one_card_hunt.py — hunt for a single-card-stuck state.

Criteria: tricks engine stalls, active hand has exactly 1 card,
deck has < 45 cards remaining. First hit wins; reports puzzle
session URL for Steve.

Up to 20 games per invocation.
"""

import argparse
import datetime
import json
import urllib.error
import urllib.request

import auto_player
from client import Client
import dealer
import geometry
import gesture_synth
import strategy


DECK_MAX = 45


def _to_wire(prim, board):
    kind = prim["action"]
    if kind == "split":
        return {"action": "split", "stack": board[prim["stack_index"]],
                "card_index": prim["card_index"]}
    if kind == "merge_stack":
        return {"action": "merge_stack",
                "source": board[prim["source_stack"]],
                "target": board[prim["target_stack"]],
                "side": prim.get("side", "right")}
    if kind == "merge_hand":
        return {"action": "merge_hand", "hand_card": prim["hand_card"],
                "target": board[prim["target_stack"]],
                "side": prim.get("side", "right")}
    if kind == "move_stack":
        return {"action": "move_stack", "stack": board[prim["stack_index"]],
                "new_loc": prim["new_loc"]}
    return prim


def _apply_local(board, prim):
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
        return strategy._apply_move(board, prim["stack_index"], prim["new_loc"])
    if kind == "split":
        return strategy._apply_split(board, prim["stack_index"],
                                     prim["card_index"])
    return board


def _send_play(c, sid, play, board):
    """Reuse auto_player._send_one which handles gesture synth
    + index-shift tracking correctly."""
    local = strategy._copy_board(board)
    for prim in play["primitives"]:
        local = auto_player._send_one(c, sid, prim, local, verbose=False)
        if local is None:
            return None
    for prim in strategy.find_follow_up_merges(local):
        local = auto_player._send_one(c, sid, prim, local, verbose=False)
        if local is None:
            return None
    return local


def _post_puzzle(client, label, puzzle_name, state):
    body = json.dumps({
        "label": label,
        "puzzle_name": puzzle_name,
        "initial_state": state,
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{client.base}/new-puzzle-session",
        data=body, headers={"Content-Type": "application/json"},
        method="POST")
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())["session_id"]


def run_game(c, game_idx, max_steps=200):
    stamp = datetime.datetime.now().strftime("%H%M%S")
    sid = c.new_session(label=f"hunt-1card {game_idx} {stamp}",
                        initial_state=dealer.deal())
    for _ in range(max_steps):
        state = c.get_state(sid)["state"]
        active = state["active_player_index"]
        hand = state["hands"][active]["hand_cards"]
        board = state["board"]
        deck = len(state["deck"])

        play = strategy.choose_play(hand, board)
        if play is not None:
            local = _send_play(c, sid, play, board)
            if local is None:
                break
            continue

        # tricks stalled.
        if len(hand) == 0:
            try:
                resp = c.send_complete_turn(sid)
            except RuntimeError:
                break
            if resp.get("turn_result") == "failure":
                break
            continue

        if len(hand) == 1 and deck < DECK_MAX:
            # Perfect puzzle candidate.
            return sid, state

        # Otherwise: draw more and keep playing.
        try:
            resp = c.send_complete_turn(sid)
        except RuntimeError:
            break
        if resp.get("turn_result") == "failure":
            break
    return None, None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--games", type=int, default=20)
    parser.add_argument("--base",
                        default="http://localhost:9000/gopher/lynrummy-elm")
    args = parser.parse_args()

    c = Client(base=args.base)
    for i in range(args.games):
        sid, state = run_game(c, i + 1)
        if state is None:
            print(f"game {i+1}: no qualifying stall")
            continue
        active = state["active_player_index"]
        hand = state["hands"][active]["hand_cards"]
        deck = len(state["deck"])
        stuck_card = hand[0]["card"]
        from dsl_player import _label
        lbl = _label(stuck_card)
        print(f"game {i+1}: HIT — stuck on {lbl} with deck={deck}")
        # Spin off a clean puzzle session with FRESH layout. Use
        # a reduced board-height so no stack lands so low that
        # browser chrome clips it. Temporarily shrink
        # BOARD_MAX_HEIGHT for the re-layout pass, then restore.
        original_max_h = geometry.BOARD_MAX_HEIGHT
        geometry.BOARD_MAX_HEIGHT = 500  # conservative ceiling
        try:
            puzzle_state = dict(state)
            puzzle_state["deck"] = []
            relaid = []
            for s in puzzle_state["board"]:
                loc = geometry.find_open_loc(
                    relaid, card_count=len(s["board_cards"]))
                relaid.append(dict(s, loc=loc))
            puzzle_state["board"] = relaid
        finally:
            geometry.BOARD_MAX_HEIGHT = original_max_h
        try:
            pid = _post_puzzle(
                c,
                label=f"1-card stall: {lbl} (deck={deck})",
                puzzle_name=f"stall_{lbl}_deck{deck}_{datetime.datetime.now().strftime('%H%M%S')}",
                state=puzzle_state)
            print(f"  puzzle: {c.base}/play/{pid}")
        except urllib.error.HTTPError as e:
            print(f"  puzzle post failed: {e.code} {e.read().decode()}")
        return
    print("no qualifying stall found across all games")


if __name__ == "__main__":
    main()
