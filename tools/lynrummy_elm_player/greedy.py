"""
Greedy player: repeatedly ask the server for hints, pick the
highest-scoring one, play it. No rule logic lives here — all
legality and scoring lives server-side. This is the clean
shape of a "dumb" Python client sitting on top of the
"intelligent" Go server.

Usage:
    python3 tools/lynrummy_elm_player/greedy.py [--max-turns N]

Prints a per-turn summary and a final session URL.
"""

import argparse
import sys

from client import Client, card


def play_greedy(c, session_id, max_turns=50, verbose=True):
    """Play until no legal merges remain or max_turns is hit.

    Returns the list of (turn, action_dict, new_score) tuples.
    """
    trace = []
    for turn in range(1, max_turns + 1):
        hints = c.get_hints(session_id)
        # Go marshals nil slices as null, not [].
        combined = (hints.get("hand_merges") or []) + (hints.get("stack_merges") or [])
        if not combined:
            if verbose:
                print(f"  turn {turn}: no legal merges. stopping.")
            break

        best = max(combined, key=lambda h: h["result_score"])
        action = _hint_to_action(best)
        resp = c.send_action(session_id, action)

        score = c.get_score(session_id)
        trace.append((turn, action, score["board_score"]))

        if verbose:
            print(f"  turn {turn}: {_describe(best)} → score={score['board_score']}")

    return trace


def _hint_to_action(hint):
    """Translate a Hint dict into a WireAction payload."""
    if hint["kind"] == "merge_hand":
        return {
            "action": "merge_hand",
            "hand_card": hint["hand_card"],
            "target_stack": hint["target_stack"],
            "side": hint["side"],
        }
    if hint["kind"] == "merge_stack":
        return {
            "action": "merge_stack",
            "source_stack": hint["source_stack"],
            "target_stack": hint["target_stack"],
            "side": hint["side"],
        }
    raise ValueError(f"unknown hint kind: {hint['kind']}")


def _describe(hint):
    if hint["kind"] == "merge_hand":
        card = hint["hand_card"]
        return (f"merge hand card V{card['value']}S{card['suit']} → "
                f"stack {hint['target_stack']} ({hint['side']})")
    return (f"merge stack {hint['source_stack']} → stack {hint['target_stack']} "
            f"({hint['side']})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--max-turns", type=int, default=50)
    parser.add_argument("--base", default="http://localhost:9000/gopher/lynrummy-elm")
    args = parser.parse_args()

    c = Client(base=args.base)
    sid = c.new_session()
    initial = c.get_score(sid)
    print(f"session {sid}: initial score {initial['board_score']}")

    trace = play_greedy(c, sid, max_turns=args.max_turns)

    final = c.get_score(sid)
    state = c.get_state(sid)
    print()
    print(f"played {len(trace)} turns")
    print(f"final score: {final['board_score']}")
    print(f"hand size remaining: {state['state']['hand']['hand_cards'].__len__()}")
    print(f"browse: {args.base.rsplit('/', 1)[0]}/lynrummy-elm/sessions/{sid}")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
