"""
compare_engines.py — measure how often beginner.py rescues a
tricks-engine stall.

For each random-dealt game, drive play with `strategy.choose_play`.
Every time the tricks engine stalls with a single-card hand and
deck < 45, pass the state to `beginner.beginner_plan` and record:
  - tricks stalled, beginner solves → beginner rescue
  - both stall                      → genuine puzzle
  - tricks didn't stall (normal)    → baseline

Reports per-game and totals.
"""

import argparse
import datetime

import auto_player
import beginner
from client import Client
import dealer
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


def run_one_game(c, idx, max_steps=300):
    stamp = datetime.datetime.now().strftime("%H%M%S")
    sid = c.new_session(label=f"cmp {idx} {stamp}",
                        initial_state=dealer.deal())
    stalls = 0
    rescues = 0
    puzzles = 0

    for _ in range(max_steps):
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
                    broke = True
                    break
            if broke:
                break
            for prim in strategy.find_follow_up_merges(local):
                local = auto_player._send_one(c, sid, prim, local, verbose=False)
                if local is None:
                    break
            continue

        if len(hand) == 0:
            try:
                resp = c.send_complete_turn(sid)
            except RuntimeError:
                break
            if resp.get("turn_result") == "failure":
                break
            continue

        if len(hand) == 1 and deck < DECK_MAX:
            stalls += 1
            trouble = hand[0]["card"]
            t = (trouble["value"], trouble["suit"], trouble["origin_deck"])
            beg_board = _server_board_to_beginner(state) + [[t]]
            plan = beginner.beginner_plan(beg_board)
            if plan is not None:
                rescues += 1
            else:
                puzzles += 1

        try:
            resp = c.send_complete_turn(sid)
        except RuntimeError:
            break
        if resp.get("turn_result") == "failure":
            break

    return {"sid": sid, "stalls": stalls,
            "rescues": rescues, "puzzles": puzzles}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--games", type=int, default=10)
    parser.add_argument("--base",
                        default="http://localhost:9000/gopher/lynrummy-elm")
    args = parser.parse_args()

    c = Client(base=args.base)
    totals = {"stalls": 0, "rescues": 0, "puzzles": 0}
    for i in range(args.games):
        r = run_one_game(c, i + 1)
        for k in totals:
            totals[k] += r[k]
        print(f"game {i+1}: sid={r['sid']} "
              f"stalls={r['stalls']} rescues={r['rescues']} "
              f"puzzles={r['puzzles']}")

    print()
    print("=" * 60)
    print(f"total tricks-stalls considered: {totals['stalls']}")
    print(f"rescued by beginner:            {totals['rescues']}")
    print(f"genuine puzzles (both stuck):   {totals['puzzles']}")
    if totals["stalls"]:
        pct = 100 * totals["rescues"] / totals["stalls"]
        print(f"rescue rate:                    {pct:.1f}%")


if __name__ == "__main__":
    main()
