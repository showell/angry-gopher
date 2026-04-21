"""
auto_player.py — drive an Elm-backed LynRummy session using the
Python-native `hints` module.

Loop:
  - Fetch current state.
  - Ask hints.build_suggestions for firing tricks.
  - Take the top suggestion, send each of its primitives verbatim.
  - When no suggestions fire, attempt complete_turn.
  - Stop on referee rejection, deck-low-water, or max_actions.

No /hint round-trip, no trick_result on the wire, no
decomposition. Every action sent is a primitive.

Usage:
    python3 tools/lynrummy_elm_player/auto_player.py [--session N] [--max-actions N]
"""

import argparse
import datetime
import sys

from client import Client
import hints
import gesture_synth


# Game termination: deck running out, not a turn_result variant.
# LynRummy doesn't end on "victory" — humans keep playing past
# hand-emptied events; the middle game is the fun part. Real end
# is when the deck is nearly exhausted.
DECK_LOW_WATER = 10

# `failure` is the one turn_result that stops the loop — means the
# server refused a dirty-board complete_turn.
TERMINAL_RESULTS = {"failure"}


def _apply_locally(board, prim):
    """Mirror of what the server does to a board when it receives
    this primitive, so gesture_synth sees the correct state for
    the NEXT primitive in the same trick."""
    kind = prim["action"]
    if kind == "merge_hand":
        return hints._apply_merge_hand(
            board, prim["target_stack"], prim["hand_card"],
            prim.get("side", "right"))
    if kind == "merge_stack":
        return hints._apply_merge_stack(
            board, prim["source_stack"], prim["target_stack"],
            prim.get("side", "right"))
    if kind == "move_stack":
        return hints._apply_move(board, prim["stack_index"], prim["new_loc"])
    if kind == "split":
        return hints._apply_split(board, prim["stack_index"], prim["card_index"])
    if kind == "place_hand":
        return hints._apply_place_hand(board, prim["hand_card"], prim["loc"])
    return board


def play_session(c, session_id, *, max_actions=300, verbose=True):
    actions = 0
    turns = 0
    last_result = None

    while actions < max_actions:
        state = c.get_state(session_id)["state"]
        hand = state["hands"][state["active_player_index"]]["hand_cards"]
        board = state["board"]

        suggestions = hints.build_suggestions(hand, board)
        if suggestions:
            top = suggestions[0]
            trick_id = top["trick_id"]
            prims = top["primitives"]
            if verbose:
                print(f"  trick: {trick_id} ({len(prims)} primitives)")
            # Maintain a local board that advances per-primitive
            # so gesture synthesis can compute drag endpoints
            # from the correct pre-primitive state without a
            # round-trip to /state.
            local = hints._copy_board(board)
            for prim in prims:
                endpoints = gesture_synth.drag_endpoints(prim, local)
                meta = (gesture_synth.synthesize(*endpoints)
                        if endpoints is not None else None)
                try:
                    c.send_action(session_id, prim, gesture_metadata=meta)
                except RuntimeError as e:
                    if verbose:
                        print(f"  send failed: {e}")
                    return {"actions": actions, "turns": turns,
                            "final_turn_result": "send_error"}
                actions += 1
                local = _apply_locally(local, prim)
            continue

        # No more suggestions — try complete_turn.
        try:
            resp = c.send_complete_turn(session_id)
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

        state_resp = c.get_state(session_id)
        deck_size = len(state_resp.get("state", state_resp).get("deck", []))
        if verbose:
            print(f"    deck remaining: {deck_size}")
        if deck_size <= DECK_LOW_WATER:
            if verbose:
                print(f"  deck at low water ({deck_size}); ending game.")
            break

    return {"actions": actions, "turns": turns,
            "final_turn_result": last_result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", type=int, default=None,
                        help="Session id. Omitted → new one.")
    parser.add_argument("--max-actions", type=int, default=300)
    parser.add_argument("--label", default=None)
    parser.add_argument("--base",
                        default="http://localhost:9000/gopher/lynrummy-elm")
    args = parser.parse_args()

    c = Client(base=args.base)
    if args.session is not None:
        sid = args.session
    else:
        stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
        label = args.label or f"claude py-hints {stamp}"
        sid = c.new_session(label=label)

    initial = c.get_score(sid)
    print(f"session {sid}: initial board_score {initial['board_score']}")

    summary = play_session(c, sid, max_actions=args.max_actions)

    final = c.get_score(sid)
    print()
    print(f"actions played:  {summary['actions']}")
    print(f"turns completed: {summary['turns']}")
    print(f"final turn_result: {summary['final_turn_result']}")
    print(f"final board_score: {final['board_score']}")
    print(f"browse: http://localhost:9000/gopher/lynrummy-elm/play/{sid}")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
