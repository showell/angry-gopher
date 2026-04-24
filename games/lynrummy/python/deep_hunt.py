"""
deep_hunt.py — find a complex (≥N compound) puzzle and post
it. Variant of one_card_hunt that captures specifically the
DEEP cases beginner.py solves with 4+ compound moves.

Usage:
    python3 deep_hunt.py --target 4   # find a 4-compound solve
    python3 deep_hunt.py --target 5   # find a 5-compound solve
"""

import argparse
import datetime
import json
import urllib.error
import urllib.request

import auto_player
import beginner
from client import Client
import dealer
import geometry
import strategy


DECK_MAX = 45


def _server_board_to_beginner(state):
    board = []
    for stack in state["board"]:
        cards = [(bc["card"]["value"],
                  bc["card"]["suit"],
                  bc["card"]["origin_deck"])
                 for bc in stack["board_cards"]]
        board.append(cards)
    return board


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


def hunt_for_target(c, target_depth, max_games):
    for game_idx in range(max_games):
        stamp = datetime.datetime.now().strftime("%H%M%S")
        sid = c.new_session(label=f"deep-hunt {game_idx+1} target={target_depth} {stamp}",
                            initial_state=dealer.deal())
        for _ in range(300):
            state = c.get_state(sid)["state"]
            active = state["active_player_index"]
            hand = state["hands"][active]["hand_cards"]
            board = state["board"]
            deck = len(state["deck"])

            play = strategy.choose_play(hand, board)
            if play is not None:
                local = strategy._copy_board(board)
                broke = False
                for prim in play["primitives"]:
                    local = auto_player._send_one(c, sid, prim, local, verbose=False)
                    if local is None:
                        broke = True; break
                if broke: break
                for prim in strategy.find_follow_up_merges(local):
                    local = auto_player._send_one(c, sid, prim, local, verbose=False)
                    if local is None: break
                continue

            if len(hand) == 0:
                try: resp = c.send_complete_turn(sid)
                except RuntimeError: break
                if resp.get("turn_result") == "failure": break
                continue

            if len(hand) == 1 and deck < DECK_MAX:
                trouble = hand[0]["card"]
                t = (trouble["value"], trouble["suit"], trouble["origin_deck"])
                beg_board = _server_board_to_beginner(state) + [[t]]
                plan = beginner.beginner_plan(beg_board, max_compound=6)
                tlabel = beginner.label(t)
                depth = len(plan) if plan else None
                if plan and depth >= target_depth:
                    print(f"game {game_idx+1}: HIT — trouble {tlabel}, "
                          f"deck={deck}, depth={depth}")
                    print("solve:")
                    for line, _ in plan:
                        print(f"  {line}")
                    # Post puzzle.
                    puzzle_state = dict(state)
                    puzzle_state["deck"] = []
                    original_max_h = geometry.BOARD_MAX_HEIGHT
                    geometry.BOARD_MAX_HEIGHT = 500
                    try:
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
                            label=f"deep-{depth}: {tlabel} (deck={deck})",
                            puzzle_name=f"deep_{depth}_{tlabel}_{stamp}",
                            state=puzzle_state)
                        print(f"  puzzle: {c.base}/play/{pid}")
                    except urllib.error.HTTPError as e:
                        print(f"  post failed: {e}")
                    return depth, plan
                else:
                    print(f"  game {game_idx+1}: stall on {tlabel} "
                          f"deck={deck} → "
                          f"{'depth ' + str(depth) if depth else 'STUCK'}")

            try: resp = c.send_complete_turn(sid)
            except RuntimeError: break
            if resp.get("turn_result") == "failure": break
        print(f"game {game_idx+1} ended; no target hit")
    print(f"no depth-{target_depth} solve in {max_games} games")
    return None, None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--target", type=int, default=4)
    p.add_argument("--max-games", type=int, default=20)
    p.add_argument("--base",
                   default="http://localhost:9000/gopher/lynrummy-elm")
    args = p.parse_args()
    c = Client(base=args.base)
    hunt_for_target(c, args.target, args.max_games)


if __name__ == "__main__":
    main()
