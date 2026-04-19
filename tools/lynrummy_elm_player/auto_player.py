"""
auto_player.py — drive an Elm-backed LynRummy session by
repeatedly taking the FIRST suggestion /hint returns, then
calling complete_turn when no hints remain.

Mirrors a human playing the most obvious trick, not an optimizer.
The /hint endpoint returns trick suggestions in priority order
(simplest first); we just take suggestions[0], POST its action,
repeat.

Usage:
    python3 tools/lynrummy_elm_player/auto_player.py [--session N] [--max-actions N]

If --session is omitted, creates a new session.
"""

import argparse
import sys

from client import Client


# Turn results that end the game.
TERMINAL_RESULTS = {"success_as_victor", "success_with_hand_emptied"}


def play_session(c, session_id, *, max_actions=200, verbose=True):
    """Play until the game ends or max_actions is hit.

    Returns a summary dict.
    """
    actions = 0
    turns = 0
    last_result = None

    while actions < max_actions:
        hint_resp = c.get_hint(session_id)
        suggestions = hint_resp.get("suggestions") or []

        if suggestions:
            first = suggestions[0]
            c.send_action(session_id, first["action"])
            actions += 1
            if verbose:
                print(f"  act {actions}: {first['trick_id']} — "
                      f"{first['description']}")
            continue

        # No hints: end the turn. Server validates board + classifies.
        resp = c.send_complete_turn(session_id)
        turns += 1
        result = resp.get("turn_result")
        last_result = result
        if verbose:
            print(f"  turn {turns}: complete_turn → {result} "
                  f"(banked {resp.get('turn_score', 0)}, "
                  f"drew {resp.get('cards_drawn', 0)})")

        if result in TERMINAL_RESULTS:
            break

    return {"actions": actions, "turns": turns,
            "final_turn_result": last_result}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--session", type=int, default=None,
                        help="Session id. Omitted → creates a new one.")
    parser.add_argument("--max-actions", type=int, default=200)
    parser.add_argument("--base",
                        default="http://localhost:9000/gopher/lynrummy-elm")
    args = parser.parse_args()

    c = Client(base=args.base)
    sid = args.session if args.session is not None else c.new_session()

    initial = c.get_score(sid)
    print(f"session {sid}: initial board_score {initial['board_score']}")

    summary = play_session(c, sid, max_actions=args.max_actions)

    final = c.get_score(sid)
    print()
    print(f"actions played: {summary['actions']}")
    print(f"turns completed: {summary['turns']}")
    print(f"final turn_result: {summary['final_turn_result']}")
    print(f"final board_score: {final['board_score']}")
    print(f"browse: http://localhost:9000/gopher/lynrummy-elm/sessions/{sid}")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
