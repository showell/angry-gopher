"""
complex_hunt.py — find COMPLEX beginner.py successes.

Same flow as one_card_hunt: random deal → tricks-engine
plays until stall → at each stall, run beginner.py. But
this version:
  - Uses the higher max_compound=6 budget (Steve 2026-04-24).
  - Reports plan length distribution.
  - Highlights deep solves (≥ 4 compound moves) as "complex
    successes."
  - Streaming output: prints per-stall stats live.
  - Capped node + time budget per attempt to prevent
    combinatorial explosion.

Usage:
    python3 complex_hunt.py [--games N] [--max-compound K]
"""

import argparse
import datetime
from collections import Counter

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


def hunt(c, idx, max_compound):
    stamp = datetime.datetime.now().strftime("%H%M%S")
    sid = c.new_session(label=f"complex {idx} {stamp}",
                        initial_state=dealer.deal())
    stalls_total = 0
    by_depth = Counter()
    deep_solves = []  # (sid, trouble_label, plan)

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
            stalls_total += 1
            trouble = hand[0]["card"]
            t = (trouble["value"], trouble["suit"], trouble["origin_deck"])
            beg_board = _server_board_to_beginner(state) + [[t]]
            plan = beginner.beginner_plan(
                beg_board, max_compound=max_compound)
            tlabel = beginner.label(t)
            if plan is None:
                by_depth["stuck"] += 1
                print(f"  game {idx}: stall on {tlabel} (deck={deck}) "
                      f"→ STUCK")
            else:
                d = len(plan)
                by_depth[d] += 1
                marker = "  ★" if d >= 4 else ""
                print(f"  game {idx}: stall on {tlabel} (deck={deck}) "
                      f"→ solved in {d} compound{marker}")
                if d >= 4:
                    deep_solves.append((sid, tlabel, plan))

        try:
            resp = c.send_complete_turn(sid)
        except RuntimeError:
            break
        if resp.get("turn_result") == "failure":
            break

    return {"sid": sid, "stalls": stalls_total,
            "by_depth": by_depth, "deep_solves": deep_solves}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--games", type=int, default=5)
    parser.add_argument("--max-compound", type=int, default=6)
    parser.add_argument("--base",
                        default="http://localhost:9000/gopher/lynrummy-elm")
    args = parser.parse_args()

    c = Client(base=args.base)
    overall_depth = Counter()
    all_deep = []
    for i in range(args.games):
        print(f"=== game {i+1}/{args.games} ===")
        r = hunt(c, i + 1, args.max_compound)
        for d, n in r["by_depth"].items():
            overall_depth[d] += n
        all_deep.extend(r["deep_solves"])

    print()
    print("=" * 60)
    print("depth distribution across all stalls:")
    keys = sorted(overall_depth.keys(),
                  key=lambda k: (isinstance(k, str), k))
    for k in keys:
        print(f"  {k:>5}: {overall_depth[k]}")
    print()
    print(f"deep solves (≥ 4 compound moves): {len(all_deep)}")
    for sid, lbl, plan in all_deep[:5]:
        print(f"  session {sid}, trouble {lbl}, {len(plan)} moves:")
        for line, _ in plan:
            print(f"    {line}")


if __name__ == "__main__":
    main()
