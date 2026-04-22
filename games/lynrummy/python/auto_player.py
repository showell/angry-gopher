"""
auto_player.py — drive an Elm-backed LynRummy session using the
Python-native `strategy` module (trick recognizers + hint
priority).

Loop:
  - Fetch current state.
  - Ask strategy.choose_play for the next play.
  - Send each of its primitives verbatim.
  - When no suggestions fire, attempt complete_turn.
  - Stop on referee rejection, deck-low-water, or max_actions.

Every session opens with a **cosmetic first move** — the
initial 6-card 2-7 run slides up next to the KA23 spade
run. Not strategic; it exists so replays start with a
clean, visible intra-board drag that also cues the viewer
"replay is live, game starts now."

No /hint round-trip, no trick_result on the wire, no
decomposition. Every action sent is a primitive.

Usage:
    python3 games/lynrummy/python/auto_player.py [--session N] [--max-actions N]
"""

import argparse
import datetime
import sys

from client import Client, card, find_stack_containing
import strategy
import gesture_synth


# Game termination: deck running out, not a turn_result variant.
# Lyn Rummy doesn't end on "victory" — humans keep playing past
# hand-emptied events; the middle game is the fun part. Real end
# is when the deck is nearly exhausted.
DECK_LOW_WATER = 10

# `failure` is the one turn_result that stops the loop — means the
# server refused a dirty-board complete_turn.
TERMINAL_RESULTS = {"failure"}


# Cosmetic-opener config. See module docstring. Three moves
# sliding tableau stacks into fresh spots; each is cued by a
# card it contains (stable under the reducer's reordering), so
# the sequence plays cleanly one after another.
COSMETIC_OPENERS = [
    {"label": "2C", "loc": {"left": 310, "top": 20}},   # 6-run →top-right
    {"label": "2H", "loc": {"left": 560, "top": 200}},  # heart trio → right
    {"label": "AC", "loc": {"left": 560, "top": 340}},  # ace trio → right
]
OPENER_MS_PER_PIXEL = 10


def do_cosmetic_opener(c, session_id, *, verbose=True):
    """Send the three cosmetic first moves. See module docstring."""
    for spec in COSMETIC_OPENERS:
        state = c.get_state(session_id)
        src_idx = find_stack_containing(state, spec["label"])
        if src_idx is None:
            if verbose:
                print(f"  opener skipped: no stack containing {spec['label']}")
            continue
        board = state["state"]["board"]
        src = board[src_idx]
        prim = {
            "action": "move_stack",
            "stack_index": src_idx,
            "new_loc": spec["loc"],
        }
        start, end = gesture_synth.drag_endpoints(prim, board)
        meta = gesture_synth.synthesize(
            start, end, ms_per_pixel=OPENER_MS_PER_PIXEL)
        if verbose:
            print(f"  opener: move_stack [{spec['label']}'s stack] "
                  f"{src['loc']} → {spec['loc']}")
        c.send_action(session_id, _to_wire_shape(prim, board), gesture_metadata=meta)


def _to_wire_shape(prim, board):
    """Translate an internal index-based primitive to the
    CardStack-ref wire shape the server expects. strategy.py + the
    local _apply_locally mirror still use the internal shape;
    translation is localized to the send boundary."""
    kind = prim["action"]
    if kind == "split":
        return {
            "action": "split",
            "stack": board[prim["stack_index"]],
            "card_index": prim["card_index"],
        }
    if kind == "merge_stack":
        return {
            "action": "merge_stack",
            "source": board[prim["source_stack"]],
            "target": board[prim["target_stack"]],
            "side": prim.get("side", "right"),
        }
    if kind == "merge_hand":
        return {
            "action": "merge_hand",
            "hand_card": prim["hand_card"],
            "target": board[prim["target_stack"]],
            "side": prim.get("side", "right"),
        }
    if kind == "move_stack":
        return {
            "action": "move_stack",
            "stack": board[prim["stack_index"]],
            "new_loc": prim["new_loc"],
        }
    # place_hand, complete_turn, undo pass through unchanged.
    return prim


def _apply_locally(board, prim):
    """Mirror of what the server does to a board when it receives
    this primitive, so gesture_synth sees the correct state for
    the NEXT primitive in the same trick."""
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
        return strategy._apply_split(board, prim["stack_index"], prim["card_index"])
    if kind == "place_hand":
        return strategy._apply_place_hand(board, prim["hand_card"], prim["loc"])
    return board


def play_session(c, session_id, *, max_actions=300, verbose=True):
    actions = 0
    turns = 0
    last_result = None

    while actions < max_actions:
        state = c.get_state(session_id)["state"]
        hand = state["hands"][state["active_player_index"]]["hand_cards"]
        board = state["board"]

        play = strategy.choose_play(hand, board)
        if play:
            trick_id = play["trick_id"]
            prims = play["primitives"]
            if verbose:
                print(f"  trick: {trick_id} ({len(prims)} primitives)")
            # Maintain a local board that advances per-primitive
            # so gesture synthesis can compute drag endpoints
            # from the correct pre-primitive state without a
            # round-trip to /state.
            local = strategy._copy_board(board)
            for prim in prims:
                endpoints = gesture_synth.drag_endpoints(prim, local)
                meta = (gesture_synth.synthesize(*endpoints)
                        if endpoints is not None else None)
                wire = _to_wire_shape(prim, local)
                try:
                    c.send_action(session_id, wire, gesture_metadata=meta)
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

    do_cosmetic_opener(c, sid)

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
