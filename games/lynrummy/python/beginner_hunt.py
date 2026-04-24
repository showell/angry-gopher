"""
beginner_hunt.py — three-competitor discrepancy hunt.

Competitors:
  1. Steve (human ground-truth)
  2. tricks/hints — strategy.choose_play (auto_player's engine)
  3. beginner.py — peel/pluck/steal/extend with taboo cycle-detection

For each random-dealt game, drive play with the tricks engine. When
the tricks engine stalls AND the deck has ≤ 49 cards remaining
(per Steve 2026-04-24: too-many-cards-left isn't puzzle material
yet, keep playing), run beginner.py on the current state.

Three outcomes per stall:
  - tricks stalled, beginner solves   → beginner > tricks
  - both stall                        → candidate puzzle for Steve
  - tricks solves (no stall)          → not a stuck point; continue

Usage:
    python3 beginner_hunt.py [--games N]
"""

import argparse
import datetime
import json

from client import Client
import beginner
import dealer
import gesture_synth
import strategy


DECK_THRESHOLD_FOR_PUZZLE = 49


def _server_board_to_beginner(state):
    """Convert server board (legal stacks only) to beginner format."""
    board = []
    for stack in state["board"]:
        cards = [(bc["card"]["value"],
                  bc["card"]["suit"],
                  bc["card"]["origin_deck"])
                 for bc in stack["board_cards"]]
        board.append(cards)
    return board


def _hand_cards(state):
    active = state["active_player_index"]
    return [(hc["card"]["value"], hc["card"]["suit"], hc["card"]["origin_deck"])
            for hc in state["hands"][active]["hand_cards"]]


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
    if kind == "place_hand":
        return strategy._apply_place_hand(board, prim["hand_card"],
                                          prim["loc"])
    return board


def _send_play(c, sid, play, board):
    local = strategy._copy_board(board)
    for prim in play["primitives"]:
        endpoints = gesture_synth.drag_endpoints(prim, local)
        meta = (gesture_synth.synthesize(*endpoints)
                if endpoints is not None else None)
        wire = _to_wire(prim, local)
        try:
            c.send_action(sid, wire, gesture_metadata=meta)
        except RuntimeError:
            return None
        local = _apply_local(local, prim)
    for prim in strategy.find_follow_up_merges(local):
        endpoints = gesture_synth.drag_endpoints(prim, local)
        meta = (gesture_synth.synthesize(*endpoints)
                if endpoints is not None else None)
        wire = _to_wire(prim, local)
        try:
            c.send_action(sid, wire, gesture_metadata=meta)
        except RuntimeError:
            return None
        local = _apply_local(local, prim)
    return local


def hunt_one(c, game_idx):
    stamp = datetime.datetime.now().strftime("%H:%M:%S")
    sid = c.new_session(label=f"hunt {game_idx} {stamp}",
                        initial_state=dealer.deal())
    stalls_considered = 0
    beginner_wins = 0
    both_stall = 0
    puzzle_sids = []

    for _step in range(200):
        state = c.get_state(sid)["state"]
        active = state["active_player_index"]
        hand = state["hands"][active]["hand_cards"]
        board = state["board"]

        play = strategy.choose_play(hand, board)
        if play is not None:
            local = _send_play(c, sid, play, board)
            if local is None:
                break
            continue

        # tricks engine is stalled.
        if len(hand) == 0:
            # nothing to stall on; complete the turn and keep going.
            try:
                resp = c.send_complete_turn(sid)
            except RuntimeError:
                break
            if resp.get("turn_result") == "failure":
                break
            continue

        deck_size = len(state["deck"])
        if deck_size > DECK_THRESHOLD_FOR_PUZZLE:
            # too early — draw and keep playing.
            try:
                resp = c.send_complete_turn(sid)
            except RuntimeError:
                break
            if resp.get("turn_result") == "failure":
                break
            continue

        stalls_considered += 1
        beg_board = _server_state_to_beginner_board(state)
        beg_plan = beginner.beginner_plan(beg_board)
        if beg_plan is not None:
            beginner_wins += 1
            # not a puzzle; advance turn and keep playing.
            try:
                resp = c.send_complete_turn(sid)
            except RuntimeError:
                break
            if resp.get("turn_result") == "failure":
                break
            continue

        # both stalled — genuine puzzle candidate.
        both_stall += 1
        puzzle_sids.append(sid)
        # Leave the game mid-stall so the puzzle session
        # (auto_player's existing flow would spin one off,
        # but we'll do that here directly).
        break

    return {
        "source_session": sid,
        "stalls_considered": stalls_considered,
        "beginner_wins": beginner_wins,
        "both_stall": both_stall,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--games", type=int, default=5)
    parser.add_argument("--base",
                        default="http://localhost:9000/gopher/lynrummy-elm")
    args = parser.parse_args()

    c = Client(base=args.base)
    totals = {"stalls_considered": 0,
              "beginner_wins": 0,
              "both_stall": 0}
    per_game = []
    for i in range(args.games):
        r = hunt_one(c, i + 1)
        per_game.append(r)
        for k in totals:
            totals[k] += r[k]
        print(f"game {i+1}: session {r['source_session']}, "
              f"stalls={r['stalls_considered']}, "
              f"beginner_wins={r['beginner_wins']}, "
              f"both_stall={r['both_stall']}")

    print()
    print("=" * 50)
    print(f"total stalls considered:  {totals['stalls_considered']}")
    print(f"beginner beats tricks:    {totals['beginner_wins']}")
    print(f"both stalled (puzzles):   {totals['both_stall']}")


if __name__ == "__main__":
    main()
