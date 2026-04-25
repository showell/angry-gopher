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
import json
import os
import sys
import urllib.error
import urllib.request

from client import Client, card, find_stack_containing
import dealer
import strategy
import gesture_synth


# Stuck-turn capture. When the agent finds no play past
# `STUCK_CAPTURE_AFTER_TURNS` complete turns, snapshot the
# state and pause. `stuck_turns.jsonl` is durable across a
# game or two; Steve curates candidate puzzles from it.
STUCK_LOG_PATH = os.path.expanduser(
    "~/AngryGopher/prod/stuck_turns.jsonl"
)
STUCK_CAPTURE_AFTER_TURNS = 4


def _capture_stuck_turn(session_id, state, turns_completed):
    """Append a stuck-turn record to the side log. Returns the
    record for the caller to print."""
    active = state["active_player_index"]
    record = {
        "session_id": session_id,
        "turns_completed": turns_completed,
        "active_player_index": active,
        "board": state["board"],
        "hand": state["hands"][active]["hand_cards"],
        "captured_at": datetime.datetime.now().isoformat(),
    }
    os.makedirs(os.path.dirname(STUCK_LOG_PATH), exist_ok=True)
    with open(STUCK_LOG_PATH, "a") as f:
        f.write(json.dumps(record) + "\n")
    return record


def _create_puzzle_from_stuck(client, state, turns_completed,
                              source_session_id):
    """Create a fresh puzzle session whose initial_state is the
    captured stuck state. Gives Steve a clean URL with Instant
    Replay scoped to his moves only — the source auto_player
    session's 60+ setup actions would otherwise be replayed
    every time.

    Puzzles have no deck (see lynrummyElmNewPuzzleSession
    server-side rule), so we zero it out here.
    """
    puzzle_state = dict(state)
    puzzle_state["deck"] = []
    active = state["active_player_index"]
    hand_cards = state["hands"][active]["hand_cards"]
    stamp = datetime.datetime.now().strftime("%H%M%S")
    # Derive a name that's readable in the URL and unique per
    # capture. Prefix with source session so replays are traceable
    # back to the trajectory that produced the stuck state.
    label_bits = [_hand_label(hc["card"]) for hc in hand_cards[:3]]
    hand_tag = "_".join(label_bits) if label_bits else "empty"
    puzzle_name = f"stuck_s{source_session_id}_t{turns_completed}_{hand_tag}_{stamp}"
    body = json.dumps({
        "label": f"auto-stuck from session {source_session_id}",
        "puzzle_name": puzzle_name,
        "initial_state": puzzle_state,
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{client.base}/new-puzzle-session",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return None, f"{e.code}: {e.read().decode('utf-8', 'replace')}"
    return data["session_id"], puzzle_name


def _hand_label(c):
    rank = {1: "A", 11: "J", 12: "Q", 13: "K"}.get(c["value"], str(c["value"]))
    suit = {0: "C", 1: "D", 2: "S", 3: "H"}.get(c["suit"], "?")
    return f"{rank}{suit}"


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


def _send_one(c, session_id, prim, local, verbose):
    """Send one primitive + synthesize its drag path, advance
    the local board, return the new board. Returns None on
    send error (caller reports and aborts)."""
    endpoints = gesture_synth.drag_endpoints(prim, local)
    meta = (gesture_synth.synthesize(*endpoints)
            if endpoints is not None else None)
    wire = _to_wire_shape(prim, local)
    try:
        c.send_action(session_id, wire, gesture_metadata=meta)
    except RuntimeError as e:
        if verbose:
            print(f"  send failed: {e}")
        return None
    return _apply_locally(local, prim)


def play_session(c, session_id, *, max_actions=300, verbose=True):
    actions = 0
    turns = 0
    last_result = None
    last_result_puzzle_sid = None

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
                local = _send_one(c, session_id, prim, local, verbose)
                if local is None:
                    return {"actions": actions, "turns": turns,
                            "final_turn_result": "send_error"}
                actions += 1

            # Follow-up merges: orthogonal to the trick. Whatever
            # stacks the play just left on the board, scan for
            # merge partners that didn't exist pre-play. Not all
            # plays open up merges; when they do, a human would
            # spot and take them immediately.
            follow_ups = strategy.find_follow_up_merges(local)
            if follow_ups and verbose:
                print(f"  follow-up merges: {len(follow_ups)}")
            for prim in follow_ups:
                local = _send_one(c, session_id, prim, local, verbose)
                if local is None:
                    return {"actions": actions, "turns": turns,
                            "final_turn_result": "send_error"}
                actions += 1
            continue

        # No play fires. If the hand has unplayed cards past
        # the capture threshold, this is a puzzle candidate:
        # snapshot and pause. A hand with zero cards isn't
        # stuck — the player played everything; complete_turn
        # is the right move.
        if turns >= STUCK_CAPTURE_AFTER_TURNS and len(hand) > 0:
            record = _capture_stuck_turn(session_id, state, turns)
            if verbose:
                print(
                    f"  STUCK at turn {turns} "
                    f"(active={record['active_player_index']}, "
                    f"board={len(record['board'])} stacks, "
                    f"hand={len(record['hand'])} cards). "
                    f"Captured to {STUCK_LOG_PATH}."
                )
            # Spin off a fresh puzzle session so Instant Replay
            # in the browser shows only the solver's moves.
            puzzle_sid, puzzle_name_or_err = _create_puzzle_from_stuck(
                c, state, turns, session_id)
            if puzzle_sid is None:
                if verbose:
                    print(f"  puzzle-session create failed: "
                          f"{puzzle_name_or_err}")
            else:
                if verbose:
                    print(f"  puzzle session {puzzle_sid} "
                          f"(name: {puzzle_name_or_err})")
            last_result = "stuck_captured"
            last_result_puzzle_sid = puzzle_sid
            break

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
            "final_turn_result": last_result,
            "puzzle_session_id": last_result_puzzle_sid}


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
        # Python deals its own initial state so each new game
        # explores different hand/deck draws. Server's dealer has
        # a fixed opening board + fixed opening hands; relying on
        # it converges every self-play game to the same stuck
        # states. See dealer.py + RANDOM_VS_DETERMINISTIC.
        sid = c.new_session(label=label, initial_state=dealer.deal())

    initial = c.get_score(sid)
    print(f"session {sid}: initial board_score {initial['board_score']}")

    # Skip the cosmetic opener when resuming a session — the
    # opener assumes an untouched dealer board, and the pre-baked
    # move_stack locations will collide with whatever layout the
    # session has already drifted into.
    if args.session is None:
        do_cosmetic_opener(c, sid)

    summary = play_session(c, sid, max_actions=args.max_actions)

    final = c.get_score(sid)
    print()
    print(f"actions played:  {summary['actions']}")
    print(f"turns completed: {summary['turns']}")
    print(f"final turn_result: {summary['final_turn_result']}")
    print(f"final board_score: {final['board_score']}")
    print(f"browse: http://localhost:9000/gopher/lynrummy-elm/play/{sid}")
    if summary.get("puzzle_session_id"):
        psid = summary["puzzle_session_id"]
        print(f"puzzle: http://localhost:9000/gopher/lynrummy-elm/play/{psid}"
              " (fresh session — Instant Replay scoped to solver's moves)")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
