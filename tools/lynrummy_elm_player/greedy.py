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
    """Play a solo game with explicit turn lifecycle.

    Each turn:
      1. Draw one card from the deck.
      2. While legal merges exist, play the highest-result_score one.
      3. Complete the turn.

    Stops when the deck is empty AND no merges are available.
    Returns a list of per-turn summaries.
    """
    summary = []
    for turn_num in range(1, max_turns + 1):
        state = c.get_state(session_id)
        deck_size = len(state["state"].get("deck") or [])
        if deck_size == 0 and _no_merges(c, session_id):
            if verbose:
                print(f"  turn {turn_num}: deck empty + no merges. stopping.")
            break

        if deck_size > 0:
            c.send_draw(session_id)

        plays = 0
        while True:
            hints = c.get_hints(session_id)
            combined = (hints.get("hand_merges") or []) + (hints.get("stack_merges") or [])
            if not combined:
                break
            best = max(combined, key=lambda h: h["result_score"])
            c.send_action(session_id, _hint_to_action(best))
            plays += 1
            if verbose:
                print(f"  turn {turn_num}.{plays}: {_describe(best)}")

        c.send_complete_turn(session_id)
        score = c.get_score(session_id)
        state = c.get_state(session_id)
        summary.append({
            "turn": turn_num,
            "plays_made": plays,
            "final_score": score["board_score"],
            "hand_size_remaining": len(state["state"]["hand"]["hand_cards"]),
            "deck_remaining": len(state["state"].get("deck") or []),
        })
        if verbose:
            print(f"  turn {turn_num}: {plays} plays → score={score['board_score']}, "
                  f"hand={summary[-1]['hand_size_remaining']}, "
                  f"deck={summary[-1]['deck_remaining']}")

    return summary


def _no_merges(c, session_id):
    hints = c.get_hints(session_id)
    return not ((hints.get("hand_merges") or []) + (hints.get("stack_merges") or []))


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

    summary = play_greedy(c, sid, max_turns=args.max_turns)

    final = c.get_score(sid)
    state = c.get_state(sid)
    print()
    print(f"played {len(summary)} turns")
    print(f"final score: {final['board_score']}")
    print(f"hand size remaining: {len(state['state']['hand']['hand_cards'])}")
    print(f"deck remaining: {len(state['state'].get('deck') or [])}")
    print(f"browse: {args.base.rsplit('/', 1)[0]}/lynrummy-elm/sessions/{sid}")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
