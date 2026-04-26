"""
agent_game.py — drive an Elm-backed LynRummy session using
the BFS planner + hand-aware outer loop.

Bootstraps a fresh session via `dealer.deal()`, then loops:
fetch state → `agent_prelude.find_play(hand, board)` → send
the placements + the BFS plan → repeat until find_play returns
None (turn complete) or the deck runs low.

Replaces `auto_player.py`'s trick-engine driver. See
`agent_game.claude` for the design.

Usage:
    python3 games/lynrummy/python/agent_game.py
        [--max-turns N] [--max-actions N] [--label NAME]
"""

import argparse
import datetime
import sys

import agent_prelude
import bfs_solver
import dealer
import geometry
import primitives
import verbs
from client import Client


DEFAULT_BASE = "http://localhost:9000/gopher/lynrummy-elm"

# Stop the loop when the deck runs low — past this point the
# game is essentially over and self-play stops being
# informative.
DECK_LOW_WATER = 10

# Turn-result variants that terminate the game.
TERMINAL_RESULTS = {"failure"}


def _board_cards_to_tuples(board):
    """Convert a server-state board (list of CardStack-shaped
    dicts) to the tuple-of-tuples shape the planner uses."""
    return [
        [(bc["card"]["value"], bc["card"]["suit"],
          bc["card"]["origin_deck"])
         for bc in s["board_cards"]]
        for s in board
    ]


def _hand_cards_to_tuples(hand_cards):
    return [
        (hc["card"]["value"], hc["card"]["suit"],
         hc["card"]["origin_deck"])
        for hc in hand_cards
    ]


def _tuple_to_card_dict(card):
    return {"value": card[0], "suit": card[1], "origin_deck": card[2]}


def _send_place_hand(client, sid, card_tuple, local, *, verbose):
    """Pick a fresh open location and send a place_hand action.
    Returns the updated local board."""
    new_loc = geometry.find_open_loc(local, card_count=1)
    wire = {
        "action": "place_hand",
        "hand_card": _tuple_to_card_dict(card_tuple),
        "loc": new_loc,
    }
    try:
        client.send_action(sid, wire, gesture_metadata=None)
    except RuntimeError as e:
        if verbose:
            print(f"  place_hand failed: {e}")
        return None
    if verbose:
        print(f"  placed {card_tuple} at {new_loc}")
    # Mirror the server's place_hand effect on the local board.
    placed_stack = {
        "board_cards": [
            {"card": _tuple_to_card_dict(card_tuple), "state": 0}
        ],
        "loc": new_loc,
    }
    return list(local) + [placed_stack]


def _send_merge_hand_onto(client, sid, card_tuple, target_stack,
                          local, *, verbose):
    """Send a merge_hand action: card from hand → target stack
    on the right side. Returns the updated local board."""
    wire = {
        "action": "merge_hand",
        "hand_card": _tuple_to_card_dict(card_tuple),
        "target": target_stack,
        "side": "right",
    }
    try:
        client.send_action(sid, wire, gesture_metadata=None)
    except RuntimeError as e:
        if verbose:
            print(f"  merge_hand failed: {e}")
        return None
    if verbose:
        print(f"  merged {card_tuple} onto stack")
    # Mirror server: remove target, append target+[card].
    from primitives import cards_of, find_stack_index
    tgt_idx = find_stack_index(local, cards_of(target_stack))
    target = local[tgt_idx]
    new_target = {
        "board_cards": (
            list(target["board_cards"])
            + [{"card": _tuple_to_card_dict(card_tuple), "state": 0}]
        ),
        "loc": dict(target["loc"]),
    }
    return [s for i, s in enumerate(local) if i != tgt_idx] + [new_target]


def _execute_placements(client, sid, placements, local, *, verbose):
    """Place the listed hand cards onto the board. For 1 card,
    a single place_hand. For 2-3 cards, place the first as a
    singleton and merge the rest onto it in order. Returns the
    updated local board, or None on send error."""
    if not placements:
        return local
    local = _send_place_hand(client, sid, placements[0], local,
                              verbose=verbose)
    if local is None:
        return None
    # The just-placed singleton is at the end of `local`.
    for card in placements[1:]:
        target = local[-1]
        local = _send_merge_hand_onto(
            client, sid, card, target, local, verbose=verbose)
        if local is None:
            return None
    return local


def _execute_plan(client, sid, plan, local, *, verbose):
    """For each (line, desc) plan step, translate via verbs and
    send each primitive. Returns the updated local board or
    None on send error."""
    for step_num, (line, desc) in enumerate(plan, 1):
        if verbose:
            print(f"  plan step {step_num}: {bfs_solver.narrate(desc)}")
        prims = verbs.step_to_primitives(desc, local)
        for prim in prims:
            local = primitives.send_one(client, sid, prim, local,
                                        verbose=verbose)
            if local is None:
                return None
    return local


def play_session(c, sid, *, max_turns=20, max_actions=300,
                 verbose=True):
    actions = 0
    turns = 0
    last_result = None
    while turns < max_turns and actions < max_actions:
        state = c.get_state(sid)["state"]
        active = state["active_player_index"]
        hand_cards = state["hands"][active]["hand_cards"]
        hand = _hand_cards_to_tuples(hand_cards)
        board_tuples = _board_cards_to_tuples(state["board"])

        if verbose:
            print(f"\n--- turn {turns + 1}: hand={len(hand)} cards, "
                  f"board={len(board_tuples)} stacks ---")

        # Inner loop: keep finding plays until we're stuck.
        local = state["board"]
        plays_this_turn = 0
        while True:
            play = agent_prelude.find_play(hand, board_tuples)
            if play is None:
                break
            plays_this_turn += 1
            if verbose:
                print(f"  play {plays_this_turn}: place "
                      f"{len(play['placements'])} card(s), "
                      f"plan {len(play['plan'])} step(s)")

            local = _execute_placements(
                c, sid, play["placements"], local, verbose=verbose)
            if local is None:
                last_result = "send_error"
                break

            local = _execute_plan(
                c, sid, play["plan"], local, verbose=verbose)
            if local is None:
                last_result = "send_error"
                break

            actions += len(play["placements"]) + len(play["plan"])
            if actions >= max_actions:
                break

            # Refresh hand + board for next find_play.
            state = c.get_state(sid)["state"]
            hand_cards = state["hands"][active]["hand_cards"]
            hand = _hand_cards_to_tuples(hand_cards)
            board_tuples = _board_cards_to_tuples(state["board"])
            local = state["board"]

        if last_result == "send_error":
            break

        # Stuck or hand exhausted — complete the turn.
        try:
            resp = c.send_complete_turn(sid)
        except RuntimeError as e:
            if verbose:
                print(f"  complete_turn refused: {e}")
            last_result = "failure"
            break
        turns += 1
        result = resp.get("turn_result")
        last_result = result
        if verbose:
            print(f"  turn {turns}: complete_turn → {result} "
                  f"(banked {resp.get('turn_score', 0)}, "
                  f"drew {resp.get('cards_drawn', 0)})")

        if result in TERMINAL_RESULTS:
            break

        deck_size = len(c.get_state(sid).get(
            "state", {}).get("deck", []))
        if verbose:
            print(f"    deck remaining: {deck_size}")
        if deck_size <= DECK_LOW_WATER:
            if verbose:
                print(f"  deck at low water ({deck_size}); "
                      f"ending game.")
            break

    return {"actions": actions, "turns": turns,
            "final_turn_result": last_result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--max-turns", type=int, default=20)
    parser.add_argument("--max-actions", type=int, default=300)
    parser.add_argument("--label", default=None)
    parser.add_argument("--base", default=DEFAULT_BASE)
    args = parser.parse_args()

    c = Client(base=args.base)
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    label = args.label or f"agent_game (BFS) {stamp}"
    sid = c.new_session(label=label, initial_state=dealer.deal())

    initial = c.get_score(sid)
    print(f"session {sid}: initial board_score "
          f"{initial['board_score']}")

    summary = play_session(c, sid, max_turns=args.max_turns,
                           max_actions=args.max_actions)

    final = c.get_score(sid)
    print()
    print(f"actions played:  {summary['actions']}")
    print(f"turns completed: {summary['turns']}")
    print(f"final turn_result: {summary['final_turn_result']}")
    print(f"final board_score: {final['board_score']}")
    print(f"browse: {args.base}/play/{sid}")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
