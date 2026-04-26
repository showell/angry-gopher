"""
probe_focus_step.py — at a chosen step into the unrestricted
plan, list which moves the focus rule WOULD allow vs which
moves the unrestricted plan actually used. Helps identify
"focus is genuinely blocked" vs "focus had options but BFS
chose elsewhere."

Default: probe sid 146 right after step 1 (when focus is
[AC:1 2D:1] and spawns [2H], [2C:1] are pending).

Usage: python3 probe_focus_step.py [sid] [step_count]
  step_count = how many lines of the unrestricted plan to
  apply before probing.
"""

import sys

import enumerator
import move
from cards import classify, label_d
from analyze_focus_block import (
    _load_puzzle, _solve, _apply_desc, stack_label,
    _format_lineage, _what_did_step_touch,
)


def main():
    sid = int(sys.argv[1]) if len(sys.argv) > 1 else 146
    step_n = int(sys.argv[2]) if len(sys.argv) > 2 else 1

    initial4, trouble_card = _load_puzzle(sid)
    plan_off = _solve(initial4, focus_on=False)
    if plan_off is None:
        print("no unrestricted plan; abort.")
        return

    state4 = initial4
    lineage = enumerator.initial_lineage(initial4[1], initial4[2])
    for i, (line, desc) in enumerate(plan_off[:step_n], 1):
        focus = lineage[0] if lineage else None
        touches = focus and enumerator.move_touches_focus(desc, focus)
        if touches:
            lineage = enumerator.update_lineage(lineage, desc)
        else:
            from analyze_focus_block import _resync_lineage
            state4_after = _apply_desc(state4, desc)
            lineage = _resync_lineage(lineage, state4_after)
        state4 = _apply_desc(state4, desc)

    print(f"=== probe sid {sid} after {step_n} step(s) ===")
    print(f"lineage: {_format_lineage(lineage)}")
    if not lineage:
        print("(no focus — would be victory)")
        return
    focus = lineage[0]
    print(f"focus = [{stack_label(focus)}]")
    print()
    print("--- helper bucket (after step) ---")
    for i, h in enumerate(state4[0]):
        print(f"  H{i:2}: [{stack_label(h)}]  ({classify(h)})")
    print()
    print("--- trouble bucket ---")
    for i, t in enumerate(state4[1]):
        print(f"  T{i:2}: [{stack_label(t)}]")
    print("--- growing bucket ---")
    for i, g in enumerate(state4[2]):
        print(f"  G{i:2}: [{stack_label(g)}]")

    # Enumerate all legal moves; partition into focus-touching
    # vs not.
    focus_moves = []
    other_moves = []
    for desc, _ns in enumerator.enumerate_moves(state4):
        if enumerator.move_touches_focus(desc, focus):
            focus_moves.append(desc)
        else:
            other_moves.append(desc)

    print(f"\n--- focus-touching moves: {len(focus_moves)} ---")
    for d in focus_moves:
        print(f"  {move.describe_move(d)}")
    print(f"\n--- non-focus moves: {len(other_moves)} ---")
    for d in other_moves[:20]:
        print(f"  {move.describe_move(d)}")
    if len(other_moves) > 20:
        print(f"  ... {len(other_moves) - 20} more")


if __name__ == "__main__":
    main()
