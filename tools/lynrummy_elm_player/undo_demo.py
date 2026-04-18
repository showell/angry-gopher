"""
Undo demo: make a move, check state, undo it, verify the state
reverts. Undo is log-preprocessed server-side — the action
stays in the persisted log (audit trail intact), but replay
skips it + its target, so downstream queries see the pre-move
state.

Usage:
    python3 tools/lynrummy_elm_player/undo_demo.py
"""

import sys

from client import Client, card, find_stack_containing


def main():
    c = Client()
    sid = c.new_session()
    print(f"session {sid}")

    def snap(label):
        st = c.get_state(sid)
        sc = c.get_score(sid)
        print(f"  [{label}]  hand={len(st['state']['hands'][st['state']['active_player_index']]['hand_cards'])}  "
              f"board_stacks={len(st['state']['board'])}  "
              f"score={sc['board_score']}  seq={st['seq']}")

    snap("initial")

    # Action 1: merge 7H from the hand onto the 7-set.
    state = c.get_state(sid)
    seven_set = find_stack_containing(state, "7S")
    c.send_merge_hand(sid, hand_card=card("7H", deck=1),
                      target_stack=seven_set, side="right")
    snap("after merge_hand 7H")

    # Action 2: split stack 0 (the K-A-2-3 spade run) at index 2.
    state = c.get_state(sid)
    spade_run = find_stack_containing(state, "KS")
    c.send_split(sid, stack_index=spade_run, card_index=2)
    snap("after split KS")

    # Undo the split.
    c.send_undo(sid)
    snap("after undo (expect: split reverted, merge still stands)")

    # Undo the merge too.
    c.send_undo(sid)
    snap("after 2nd undo (expect: back to initial)")

    # Confirm the action LOG still contains all 4 actions,
    # even though the effective state only reflects 0 of them.
    state = c.get_state(sid)
    print()
    print(f"action log still has {state['seq']} entries "
          f"(audit trail intact; effective state reverted)")
    print(f"browse: http://localhost:9000/gopher/lynrummy-elm/sessions/{sid}")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
