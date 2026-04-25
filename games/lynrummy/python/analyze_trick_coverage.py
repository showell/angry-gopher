"""
Trick redundancy probe. Play N games, and at every decision
point record the set of tricks that fire (pass invariant). A
trick A is a candidate for redundancy if at every state where A
fires, some other trick B ≠ A also fires — B could stand in for
A in the priority order without losing coverage.

This is a weaker claim than "B finds the same move" — B may
find a DIFFERENT play, potentially worse. That requires human
eye after we see the candidates.

Usage: python3 analyze_trick_coverage.py [--games N]
"""

import argparse
import datetime
from collections import defaultdict

from client import Client
import strategy
import gesture_synth


def collect_states(client, num_games, max_actions=300):
    """Play `num_games` games. At every decision point (before
    choose_play), record the full hand+board and the set of
    tricks that fire on it. Returns list of sets of trick_ids.
    """
    states = []
    for g in range(num_games):
        stamp = datetime.datetime.now().strftime("%H:%M:%S")
        sid = client.new_session(label=f"coverage-probe {g+1}/{num_games} {stamp}")
        actions = 0
        while actions < max_actions:
            st = client.get_state(sid)["state"]
            active = st["active_player_index"]
            hand = st["hands"][active]["hand_cards"]
            board = st["board"]

            firing = _tricks_firing(hand, board)
            states.append(firing)

            play = strategy.choose_play(hand, board)
            if play is None:
                # Take the beginner fallback: complete_turn.
                try:
                    resp = client.send_complete_turn(sid)
                except RuntimeError:
                    break
                result = resp.get("turn_result")
                if result == "failure":
                    break
                state_resp = client.get_state(sid)
                deck = len(state_resp.get("state", state_resp).get("deck", []))
                if deck <= 10:
                    break
                continue

            # Send primitives, advance local board.
            local = strategy._copy_board(board)
            for prim in play["primitives"]:
                wire = _to_wire(prim, local)
                endpoints = gesture_synth.drag_endpoints(prim, local)
                meta = (gesture_synth.synthesize(*endpoints)
                        if endpoints is not None else None)
                client.send_action(sid, wire, gesture_metadata=meta)
                local = _apply_local(local, prim)
                actions += 1
            for prim in strategy.find_follow_up_merges(local):
                wire = _to_wire(prim, local)
                endpoints = gesture_synth.drag_endpoints(prim, local)
                meta = (gesture_synth.synthesize(*endpoints)
                        if endpoints is not None else None)
                client.send_action(sid, wire, gesture_metadata=meta)
                local = _apply_local(local, prim)
                actions += 1
        print(f"  game {g+1}: {actions} actions, {len(states)} states so far")
    return states


def _tricks_firing(hand, board):
    """Return set of trick_ids whose emission passes invariant."""
    out = set()
    for name, fn in strategy.TRICK_ORDER:
        prims = fn(hand, board)
        if prims is None:
            continue
        ok, _ = strategy._invariant_clean(board, prims)
        if ok:
            out.add(name)
    return out


def _to_wire(prim, board):
    """Inline copy of auto_player's _to_wire_shape."""
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
        return strategy._apply_place_hand(board, prim["hand_card"], prim["loc"])
    return board


def analyze(states):
    """For each trick A, compute: how often A fires; how often A
    is the SOLE firing trick (irreplaceable at that moment); for
    every other B, how often A fires AND B also fires.
    """
    trick_names = [name for name, _ in strategy.TRICK_ORDER]
    fire_count = {n: 0 for n in trick_names}
    sole_count = {n: 0 for n in trick_names}
    # co_fire[A][B] = count of states where A fires AND B fires
    co_fire = {a: {b: 0 for b in trick_names} for a in trick_names}

    for firing in states:
        if not firing:
            continue
        for a in firing:
            fire_count[a] += 1
            if len(firing) == 1:
                sole_count[a] += 1
            for b in firing:
                co_fire[a][b] += 1

    print(f"\nAnalyzed {len(states)} states ({sum(1 for s in states if s)} with at least one firing trick).\n")
    print(f"{'trick':<28} fires   sole   coverage-by-others")
    print("-" * 78)
    for a in trick_names:
        fa = fire_count[a]
        sa = sole_count[a]
        if fa == 0:
            print(f"{a:<28} {fa:>5}   {sa:>4}   (never fires)")
            continue
        # For each other trick B, fraction of A's firings that B also covers.
        covers = []
        for b in trick_names:
            if b == a:
                continue
            if co_fire[a][b] == fa:
                covers.append(f"{b}=100%")
            elif co_fire[a][b] >= fa * 0.9:
                covers.append(f"{b}={100*co_fire[a][b]//fa}%")
        cover_str = ", ".join(covers) if covers else "—"
        redundant = "  *SUPERSEDED*" if sa == 0 and any(co_fire[a][b] == fa for b in trick_names if b != a) else ""
        print(f"{a:<28} {fa:>5}   {sa:>4}   {cover_str}{redundant}")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--games", type=int, default=3)
    p.add_argument("--base", default="http://localhost:9000/gopher/lynrummy-elm")
    args = p.parse_args()

    client = Client(base=args.base)
    states = collect_states(client, args.games)
    analyze(states)


if __name__ == "__main__":
    main()
