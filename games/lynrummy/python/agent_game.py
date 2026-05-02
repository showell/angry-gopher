"""
agent_game.py — drive an Elm-backed LynRummy session using
the BFS planner + hand-aware outer loop.

Bootstraps a fresh session via `dealer.deal()`, then loops:
fetch state → `ts_solver.find_play(hand, board)` → send
the placements + the BFS plan → repeat until find_play returns
None (turn complete) or the deck runs low.

Replaces `auto_player.py`'s trick-engine driver.

Usage:
    python3 games/lynrummy/python/agent_game.py
        [--max-turns N] [--max-actions N] [--label NAME]
"""

import argparse
import datetime
import json
import sys
import time

import ts_solver
import dealer
import move
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


def _execute_plan(client, sid, plan, local, *, verbose, perf):
    """For each (line, desc) plan step, translate via verbs and
    send each primitive. Returns the updated local board or
    None on send error.

    `perf` is a dict; each translator + send is timed and the
    longest-by-layer is tracked there."""
    for step_num, (line, desc) in enumerate(plan, 1):
        if verbose:
            print(f"  plan step {step_num}: {move.narrate(desc)}")
        t = time.time()
        prims = verbs.move_to_primitives(desc, local)
        translate_wall = time.time() - t
        _record_max(perf, "translate", translate_wall,
                    {"desc_type": desc.type,
                     "n_prims": len(prims)})
        for prim in prims:
            t = time.time()
            local = primitives.send_one(client, sid, prim, local,
                                        verbose=verbose)
            send_wall = time.time() - t
            _record_max(perf, "send", send_wall,
                        {"action": prim["action"]})
            if local is None:
                return None
    return local


def _record_max(perf, layer, wall, meta):
    """Track the per-layer maximum-wall record on the
    aggregated `perf` dict."""
    cur = perf.get(layer)
    if cur is None or wall > cur["wall"]:
        record = {"wall": wall}
        record.update(meta)
        perf[layer] = record


def play_session(c, sid, *, max_turns=20, max_actions=300,
                 verbose=True, capture_path=None):
    actions = 0
    turns = 0
    last_result = None
    perf = {}  # global longest-per-layer across the whole game
    capture_fp = (open(capture_path, "w")
                  if capture_path else None)
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
            stats = {}
            play = ts_solver.find_play(hand, board_tuples,
                                           stats=stats)
            if capture_fp is not None:
                capture_fp.write(json.dumps({
                    "hand": hand,
                    "board": board_tuples,
                    "projections": stats.get("projections", []),
                    "total_wall": stats.get("total_wall", 0.0),
                    "found_play": play is not None,
                }) + "\n")
                capture_fp.flush()
            # Track the slowest projection seen this game.
            for proj in stats.get("projections", []):
                _record_max(perf, "projection", proj["wall"], {
                    "kind": proj["kind"],
                    "cards": proj["cards"],
                    "found_plan": proj["found_plan"],
                })
            _record_max(perf, "find_play",
                        stats.get("total_wall", 0.0),
                        {"hand_size": len(hand),
                         "board_size": len(board_tuples)})
            if play is None:
                break
            plays_this_turn += 1
            if verbose:
                print(f"  play {plays_this_turn}: place "
                      f"{len(play['placements'])} card(s), "
                      f"plan {len(play['plan'])} step(s) "
                      f"[find_play {stats.get('total_wall', 0):.2f}s]")

            local = _execute_placements(
                c, sid, play["placements"], local, verbose=verbose)
            if local is None:
                last_result = "send_error"
                break

            local = _execute_plan(
                c, sid, play["plan"], local, verbose=verbose,
                perf=perf)
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

    if capture_fp is not None:
        capture_fp.close()
    return {"actions": actions, "turns": turns,
            "final_turn_result": last_result,
            "perf": perf}


def play_session_offline(*, max_actions=500, capture_path=None):
    """Pure self-play with no server in the loop. Bootstraps via
    dealer.deal(), runs find_play until the agent is stuck or
    the hand empties, applies each play's placements +
    primitives to a local board copy. No HTTP. No session
    persistence. No gesture synthesis.

    Used for runaway-hunting / OPTIMIZE_PYTHON profiling where
    the server's validation, replay log, and rendering aren't
    needed."""
    initial_state = dealer.deal()
    board = initial_state["board"]
    hand = _hand_cards_to_tuples(
        initial_state["hands"][0]["hand_cards"])

    capture_fp = (open(capture_path, "a")
                  if capture_path else None)
    perf = {}
    actions = 0
    plays = 0

    while actions < max_actions and hand:
        board_tuples = _board_cards_to_tuples(board)
        stats = {}
        play = ts_solver.find_play(hand, board_tuples,
                                       stats=stats)
        if capture_fp is not None:
            capture_fp.write(json.dumps({
                "hand": hand,
                "board": board_tuples,
                "projections": stats.get("projections", []),
                "total_wall": stats.get("total_wall", 0.0),
                "found_play": play is not None,
            }) + "\n")
            capture_fp.flush()
        for proj in stats.get("projections", []):
            _record_max(perf, "projection", proj["wall"], {
                "kind": proj["kind"],
                "cards": proj["cards"],
                "found_plan": proj["found_plan"],
            })
        _record_max(perf, "find_play",
                    stats.get("total_wall", 0.0),
                    {"hand_size": len(hand),
                     "board_size": len(board_tuples)})

        if play is None:
            break

        plays += 1
        # Apply placements: each placement ends up on the board
        # as a singleton (or merged into the prior placement
        # for 2- and 3-card placements). Mirror what
        # _execute_placements does, but locally.
        for ci, placed in enumerate(play["placements"]):
            placed_loc = geometry.find_open_loc(board, card_count=1)
            if ci == 0:
                board = list(board) + [{
                    "board_cards": [
                        {"card": _tuple_to_card_dict(placed),
                         "state": 0}
                    ],
                    "loc": placed_loc,
                }]
            else:
                # Merge the new card onto the placed-so-far stack
                # (always the last entry on the board).
                target = board[-1]
                new_target = {
                    "board_cards": (
                        list(target["board_cards"])
                        + [{"card": _tuple_to_card_dict(placed),
                            "state": 0}]
                    ),
                    "loc": dict(target["loc"]),
                }
                board = board[:-1] + [new_target]
            hand = [c for c in hand if c != placed]
            actions += 1

        # Apply BFS plan steps locally.
        for line, desc in play["plan"]:
            t = time.time()
            prims = verbs.move_to_primitives(desc, board)
            translate_wall = time.time() - t
            _record_max(perf, "translate", translate_wall,
                        {"desc_type": desc.type,
                         "n_prims": len(prims)})
            for prim in prims:
                board = primitives.apply_locally(board, prim)
                actions += 1

    if capture_fp is not None:
        capture_fp.close()
    return {"actions": actions, "plays": plays,
            "hand_remaining": len(hand), "perf": perf}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--max-turns", type=int, default=20)
    parser.add_argument("--max-actions", type=int, default=300)
    parser.add_argument("--label", default=None)
    parser.add_argument("--base", default=DEFAULT_BASE)
    parser.add_argument("--capture",
                        help=("Path to JSONL file. When set, every "
                              "find_play call's (hand, board) inputs "
                              "and timing stats are appended."))
    parser.add_argument("--offline", action="store_true",
                        help=("Skip session creation + HTTP. Pure "
                              "self-play with local board only. "
                              "Used for runaway hunting and BFS "
                              "profiling."))
    args = parser.parse_args()

    if args.offline:
        summary = play_session_offline(
            max_actions=args.max_actions,
            capture_path=args.capture)
        print(f"offline self-play: {summary['plays']} plays, "
              f"{summary['actions']} actions, "
              f"{summary['hand_remaining']} cards in hand at end")
        print()
        print("worst-case wall (per layer):")
        for layer, record in summary.get("perf", {}).items():
            print(f"  {layer:12} {record['wall']:6.2f}s  {record}")
        return

    c = Client(base=args.base)
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    label = args.label or f"agent_game (BFS) {stamp}"
    sid = c.new_session(label=label, initial_state=dealer.deal())

    initial = c.get_score(sid)
    print(f"session {sid}: initial board_score "
          f"{initial['board_score']}")

    summary = play_session(c, sid, max_turns=args.max_turns,
                           max_actions=args.max_actions,
                           capture_path=args.capture)

    final = c.get_score(sid)
    print()
    print(f"actions played:  {summary['actions']}")
    print(f"turns completed: {summary['turns']}")
    print(f"final turn_result: {summary['final_turn_result']}")
    print(f"final board_score: {final['board_score']}")
    print(f"browse: {args.base}/play/{sid}")
    print()
    print("worst-case wall (per layer):")
    for layer, record in summary.get("perf", {}).items():
        print(f"  {layer:12} {record['wall']:6.2f}s  {record}")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
