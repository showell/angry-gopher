"""
analyze_focus_block.py — diagnose why the focus-only rule
blocks an otherwise-solvable puzzle.

Default target is sid 146 (the regression). Pass a different
sid as argv[1].

What it does:
  1. Loads the puzzle's initial 4-tuple state.
  2. Runs BFS with focus DISABLED → unrestricted plan P.
  3. Runs BFS with focus ENABLED → focus plan or None.
  4. If P exists, replays P step-by-step against the focus rule:
       - prints the lineage's focus at each step
       - flags VIOLATIONS (move that doesn't touch focus)
       - tries to recover focus from the post-step state and
         continue tracing so all violations surface, not just
         the first.
  5. Summarizes the violations: count, types, what work was
     deferred from focus to handle.

Output is human-facing text. Run as `python3 analyze_focus_block.py
[sid]`.
"""

import json
import sqlite3
import sys

import bfs
import enumerator
import move
from cards import classify, card_label
from move import (
    ExtractAbsorbDesc, FreePullDesc, PushDesc,
    ShiftDesc, SpliceDesc,
)


DB_PATH = "/home/steve/AngryGopher/prod/gopher.db"


def stack_label(stack):
    return " ".join(card_label(c) for c in stack)


def _load_puzzle(sid):
    """Return the (helper, trouble) 4-tuple state for `sid`."""
    conn = sqlite3.connect(DB_PATH)
    row = conn.execute(
        "SELECT initial_state_json FROM lynrummy_puzzle_seeds "
        "WHERE session_id=?", (sid,)).fetchone()
    state = json.loads(row[0])

    def s2b(state):
        return [[(bc["card"]["value"], bc["card"]["suit"],
                  bc["card"]["origin_deck"])
                 for bc in stack["board_cards"]]
                for stack in state["board"]]

    hand = state["hands"][state["active_player_index"]]["hand_cards"]
    trouble_card = (hand[0]["card"]["value"], hand[0]["card"]["suit"],
                    hand[0]["card"]["origin_deck"])
    board = s2b(state) + [[trouble_card]]
    helper = [s for s in board if classify(s) != "other"]
    trouble = [s for s in board if classify(s) == "other"]
    return (helper, trouble, [], []), trouble_card


def _solve(initial4, focus_on):
    """Run solve_state_with_descs with focus_on toggled. Returns
    [(line, desc), ...] or None. Flips the flag on the
    `enumerator` module directly — that's where the BFS engine
    reads it; the `bfs_solver` re-export is read-only."""
    enumerator.FOCUS_ENABLED = focus_on
    try:
        return bfs.solve_state_with_descs(
            initial4, max_trouble_outer=10, max_states=10000)
    finally:
        enumerator.FOCUS_ENABLED = True


def _apply_desc(state4, desc):
    """Replay a desc against a 4-tuple state. We re-derive the
    new state by enumerate_moves and matching descs (by line
    string for uniqueness). Returns the new 4-tuple state."""
    target_line = move.describe(desc)
    for d, new_state in enumerator.enumerate_moves(state4):
        if move.describe(d) == target_line:
            return new_state
    raise RuntimeError(
        f"could not replay step: {target_line!r}")


def _trouble_growing_entries(state4):
    """Content tuples for every trouble + growing entry. Useful
    for re-syncing lineage after a focus-rule violation."""
    _, trouble, growing, _ = state4
    return ([tuple(s) for s in trouble]
            + [tuple(s) for s in growing])


def _resync_lineage(prev_lineage, state4):
    """After a non-focus step, recompute lineage:
       - drop entries no longer present in (trouble + growing)
       - keep surviving entries in their previous order
       - append any new entries (those that aren't already
         tracked) at the end."""
    surviving = []
    pool = _trouble_growing_entries(state4)
    pool_remaining = list(pool)
    for entry in prev_lineage:
        if entry in pool_remaining:
            surviving.append(entry)
            pool_remaining.remove(entry)
    new_entries = pool_remaining
    return tuple(surviving + new_entries)


def _what_did_step_touch(desc):
    """Return a short string naming what content the step
    touched (target / loose / consumed). For diagnostic output."""
    t = desc.type
    if isinstance(desc, ExtractAbsorbDesc):
        return f"absorb-onto [{stack_label(desc.target_before)}]"
    if isinstance(desc, FreePullDesc):
        return (f"pull [{card_label(desc.loose)}] onto "
                f"[{stack_label(desc.target_before)}]")
    if isinstance(desc, ShiftDesc):
        return f"shift-onto [{stack_label(desc.target_before)}]"
    if isinstance(desc, SpliceDesc):
        return f"splice [{card_label(desc.loose)}] into helper"
    if isinstance(desc, PushDesc):
        return f"push [{stack_label(desc.trouble_before)}] onto helper"
    return desc.type


def _format_lineage(lineage):
    if not lineage:
        return "<empty>"
    parts = []
    for i, entry in enumerate(lineage):
        marker = "★" if i == 0 else " "
        parts.append(f"{marker}[{stack_label(entry)}]")
    return " ".join(parts)


def _replay_and_trace(initial4, plan, initial_lineage):
    """Walk the plan against the focus rule. Print line-by-line
    trace and accumulate violations. Returns the violations list."""
    state4 = initial4
    lineage = initial_lineage
    violations = []
    print("\n--- replay against focus rule ---")
    print(f"   initial lineage: {_format_lineage(lineage)}")
    for i, (line, desc) in enumerate(plan, 1):
        focus = lineage[0] if lineage else None
        touches = (focus is not None
                   and enumerator.move_touches_focus(desc, focus))
        flag = "  ok " if touches else "VIOL"
        focus_label = (f"[{stack_label(focus)}]"
                       if focus else "<none>")
        action = _what_did_step_touch(desc)
        print(f"  {i:2}. {flag}  focus={focus_label:18}  "
              f"step={action}")
        if not touches and focus is not None:
            violations.append({
                "step": i,
                "line": line,
                "desc": desc,
                "focus": focus,
            })
        # Apply the move to the 4-tuple state.
        state4 = _apply_desc(state4, desc)
        # Update lineage. If touched, do the proper update;
        # otherwise resync from the new state.
        if touches:
            lineage = enumerator.update_lineage(lineage, desc)
        else:
            lineage = _resync_lineage(lineage, state4)
    return violations


def _summarize(violations):
    if not violations:
        print("\n  no violations — plan IS focus-compatible "
              "(why does focus_on fail?). investigate cap iteration.")
        return
    print(f"\n--- {len(violations)} violation(s) ---")
    by_type = {}
    for v in violations:
        t = v["desc"].type
        by_type[t] = by_type.get(t, 0) + 1
    print("  by move type: "
          + ", ".join(f"{k}:{v}" for k, v in sorted(by_type.items())))
    for v in violations:
        focus = stack_label(v["focus"])
        action = _what_did_step_touch(v["desc"])
        print(f"  step {v['step']:2}: focus was [{focus}], "
              f"step did {action}")


def main():
    sid = int(sys.argv[1]) if len(sys.argv) > 1 else 146
    print(f"=== analyze_focus_block sid {sid} ===")

    initial4, trouble_card = _load_puzzle(sid)
    print(f"trouble card: {card_label(trouble_card)}")
    print(f"initial helper count: {len(initial4[0])}")
    print(f"initial trouble count: {len(initial4[1])}")
    initial_lineage = enumerator.initial_lineage(initial4[1], initial4[2])
    print(f"initial lineage: {_format_lineage(initial_lineage)}")

    print("\n--- focus DISABLED ---")
    plan_off = _solve(initial4, focus_on=False)
    if plan_off is None:
        print("  unrestricted BFS also found no plan — "
              "this puzzle is genuinely hard. abort.")
        return
    print(f"  unrestricted plan: {len(plan_off)} lines")
    for i, (line, _d) in enumerate(plan_off, 1):
        print(f"    {i:2}. {line}")

    print("\n--- focus ENABLED ---")
    plan_on = _solve(initial4, focus_on=True)
    if plan_on is None:
        print("  focus BFS: STUCK (the regression we're studying).")
    else:
        print(f"  focus BFS: {len(plan_on)} lines")
        for i, (line, _d) in enumerate(plan_on, 1):
            print(f"    {i:2}. {line}")

    violations = _replay_and_trace(initial4, plan_off, initial_lineage)
    _summarize(violations)


if __name__ == "__main__":
    main()
