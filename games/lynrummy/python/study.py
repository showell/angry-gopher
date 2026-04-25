#!/usr/bin/env python3
"""
study.py — read BOARD_LAB sessions and present them for
comparison.

Uses the `puzzle_name` column in `lynrummy_puzzle_seeds` to
group every session (human or agent) that played the same
named puzzle, then prints each solution's primitive sequence
with the spatial facts that matter: what stack was touched,
where it landed (for moves), which side (for merges), drag
endpoint coords, sample counts.

The output is deliberately terse per-primitive so whole
solutions are readable at a glance. A divergence summary at
the bottom flags places where human and agent chose
differently.

Usage:
    python3 games/lynrummy/python/study.py
        # list every puzzle_name and counts of sessions
    python3 games/lynrummy/python/study.py tight_right_edge
        # show every solution to that puzzle
    python3 games/lynrummy/python/study.py --all
        # dump every puzzle's sessions
    python3 games/lynrummy/python/study.py --feedback N
        # N most-recent annotated plays: puzzle + reply + actions,
        # one markdown block each. Single-query entry point for
        # "read the latest replies."
"""

import argparse
import json
import os
import sqlite3
import sys


DEFAULT_DB = os.path.expanduser("~/AngryGopher/prod/gopher.db")


SUITS = {0: "C", 1: "D", 2: "S", 3: "H"}
VALUES = {1: "A", 2: "2", 3: "3", 4: "4", 5: "5", 6: "6", 7: "7",
          8: "8", 9: "9", 10: "T", 11: "J", 12: "Q", 13: "K"}


def _fmt_card(card):
    return f"{VALUES.get(card['value'], '?')}{SUITS.get(card['suit'], '?')}"


def _fmt_cards(cards):
    return "[" + ",".join(_fmt_card(c) for c in cards) + "]"


def _fmt_stack(stack):
    cards = [bc["card"] for bc in stack["board_cards"]]
    return _fmt_cards(cards)


def _classify_actor(label):
    if label.startswith("agent:"):
        return "AGENT"
    if label.startswith("board-lab:"):
        return "HUMAN"
    return "????"


def _primitive_summary(kind, action, gesture):
    """One-line spatial summary of a primitive. Focused on the
    facts that matter for human/agent comparison: what moved
    where, which side of a merge, how long the drag was."""
    parts = [f"{kind:<11}"]
    if kind == "move_stack":
        parts.append(_fmt_stack(action["stack"]))
        loc = action["new_loc"]
        parts.append(f"→ ({loc['left']},{loc['top']})")
    elif kind == "merge_hand":
        parts.append(f"hand={_fmt_card(action['hand_card'])}")
        parts.append(f"target={_fmt_stack(action['target'])}")
        parts.append(f"side={action.get('side', '?')}")
    elif kind == "merge_stack":
        parts.append(f"source={_fmt_stack(action['source'])}")
        parts.append(f"target={_fmt_stack(action['target'])}")
        parts.append(f"side={action.get('side', '?')}")
    elif kind == "split":
        parts.append(_fmt_stack(action["stack"]))
        parts.append(f"@card_index={action['card_index']}")
    elif kind == "place_hand":
        parts.append(f"hand={_fmt_card(action['hand_card'])}")
        loc = action["loc"]
        parts.append(f"→ ({loc['left']},{loc['top']})")

    if gesture:
        path = gesture.get("path", [])
        if len(path) > 1:
            parts.append(
                f"drag ({path[0]['x']},{path[0]['y']})→"
                f"({path[-1]['x']},{path[-1]['y']}) "
                f"n={len(path)}"
            )

    return "  " + " ".join(str(p) for p in parts)


def _fetch_sessions(conn, puzzle_name=None):
    """Return (puzzle_name, session_id, label) tuples."""
    c = conn.cursor()
    if puzzle_name:
        c.execute(
            """SELECT ps.puzzle_name, s.id, s.label
               FROM lynrummy_elm_sessions s
               JOIN lynrummy_puzzle_seeds ps ON ps.session_id = s.id
               WHERE ps.puzzle_name = ?
               ORDER BY s.id""",
            (puzzle_name,),
        )
    else:
        c.execute(
            """SELECT ps.puzzle_name, s.id, s.label
               FROM lynrummy_elm_sessions s
               JOIN lynrummy_puzzle_seeds ps ON ps.session_id = s.id
               WHERE ps.puzzle_name IS NOT NULL
               ORDER BY ps.puzzle_name, s.id"""
        )
    return c.fetchall()


def _fetch_actions(conn, session_id):
    c = conn.cursor()
    c.execute(
        """SELECT seq, action_kind, action_json, gesture_metadata
           FROM lynrummy_elm_actions
           WHERE session_id = ?
           ORDER BY seq""",
        (session_id,),
    )
    out = []
    for seq, kind, act_json, gest_json in c.fetchall():
        action = json.loads(act_json)
        gesture = json.loads(gest_json) if gest_json else None
        out.append({"seq": seq, "kind": kind,
                    "action": action, "gesture": gesture})
    return out


def _show_sessions_for_puzzle(conn, puzzle_name, sessions):
    if not sessions:
        print(f"(no sessions for puzzle {puzzle_name!r})")
        return

    print(f"\n=== PUZZLE: {puzzle_name} ===")

    by_actor = {"HUMAN": [], "AGENT": [], "????": []}
    for name, sid, label in sessions:
        by_actor[_classify_actor(label)].append((sid, label))

    for actor in ("HUMAN", "AGENT", "????"):
        entries = by_actor[actor]
        if not entries:
            continue
        for sid, label in entries:
            actions = _fetch_actions(conn, sid)
            print(f"\n  [{actor}] session={sid}  label={label!r}  "
                  f"primitives={len(actions)}")
            if not actions:
                print("    (no primitives captured)")
                continue
            for a in actions:
                print(_primitive_summary(a["kind"], a["action"], a["gesture"]))

    _show_divergences(by_actor, conn)


def _show_divergences(by_actor, conn):
    """Flag basic human/agent differences: primitive count
    mismatch, first-primitive divergence, pre-move landing locs.
    Designed to surface study signal without claiming judgment."""
    humans = by_actor["HUMAN"]
    agents = by_actor["AGENT"]
    if not humans or not agents:
        return

    # Pick the "canonical" attempt per side — the one with the
    # most primitives (skips abandoned / zero-action rows).
    def _pick(entries):
        best = None
        best_n = -1
        for sid, label in entries:
            actions = _fetch_actions(conn, sid)
            if len(actions) > best_n:
                best_n = len(actions)
                best = (sid, label, actions)
        return best

    h_sid, h_label, h_acts = _pick(humans)
    a_sid, a_label, a_acts = _pick(agents)

    if not h_acts and not a_acts:
        return

    print("\n  --- divergences ---")
    if len(h_acts) != len(a_acts):
        print(f"    primitive count: HUMAN={len(h_acts)}  "
              f"AGENT={len(a_acts)}")

    h_kinds = [a["kind"] for a in h_acts]
    a_kinds = [a["kind"] for a in a_acts]
    if h_kinds != a_kinds:
        print(f"    kind sequence:   HUMAN={h_kinds}")
        print(f"                     AGENT={a_kinds}")

    # Compare first move_stack landing loc (if both have one) —
    # the spatial decision that most distinguishes human-style
    # from agent-default.
    def _first_move_loc(acts):
        for a in acts:
            if a["kind"] == "move_stack":
                loc = a["action"]["new_loc"]
                return (loc["left"], loc["top"])
        return None

    h_loc = _first_move_loc(h_acts)
    a_loc = _first_move_loc(a_acts)
    if h_loc and a_loc and h_loc != a_loc:
        print(f"    first move loc:  HUMAN={h_loc}  AGENT={a_loc}")


def _show_feedback(conn, n):
    """Dump the N most-recent annotated plays — one annotation per
    block, with the puzzle it's anchored to and the primitives
    that were played. One SQL for the headers, one per session
    to fetch actions; no N² cross-product. Designed so the
    entire collect-it-all-for-analysis step is a single
    command invocation instead of a SQL dig."""
    c = conn.cursor()
    c.execute(
        """SELECT a.session_id, a.puzzle_name, a.user_name,
                  a.body, a.created_at
           FROM board_lab_annotations a
           ORDER BY a.created_at DESC
           LIMIT ?""",
        (n,),
    )
    rows = c.fetchall()
    if not rows:
        print("No annotations.")
        return

    for sid, puzzle_name, user_name, body, _ts in rows:
        actions = _fetch_actions(conn, sid)
        print(f"\n## {puzzle_name} — session {sid} — {user_name}")
        print(f"\n  reply: {body}")
        if not actions:
            print("  actions: (none)")
            continue
        for a in actions:
            print(_primitive_summary(a["kind"], a["action"], a["gesture"]))


def _show_index(conn):
    """Tabulate puzzles with session counts per actor."""
    c = conn.cursor()
    c.execute(
        """SELECT ps.puzzle_name,
                  SUM(CASE WHEN s.label LIKE 'board-lab:%' THEN 1 ELSE 0 END) AS humans,
                  SUM(CASE WHEN s.label LIKE 'agent:%'    THEN 1 ELSE 0 END) AS agents,
                  COUNT(*) AS total
           FROM lynrummy_elm_sessions s
           JOIN lynrummy_puzzle_seeds ps ON ps.session_id = s.id
           WHERE ps.puzzle_name IS NOT NULL
           GROUP BY ps.puzzle_name
           ORDER BY ps.puzzle_name"""
    )
    rows = c.fetchall()
    if not rows:
        print("No puzzle sessions in the DB.")
        return

    print(f"{'puzzle_name':<36} {'human':>7} {'agent':>7} {'total':>7}")
    print("-" * 60)
    for name, humans, agents, total in rows:
        print(f"{name:<36} {humans:>7} {agents:>7} {total:>7}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("puzzle", nargs="?",
                        help="Puzzle name to study. If omitted, "
                             "prints the puzzle index.")
    parser.add_argument("--all", action="store_true",
                        help="Dump every puzzle's sessions.")
    parser.add_argument("--feedback", type=int, metavar="N", default=None,
                        help="Last N annotated plays: reply + actions.")
    parser.add_argument("--db", default=DEFAULT_DB,
                        help=f"Path to gopher.db (default: {DEFAULT_DB})")
    args = parser.parse_args()

    conn = sqlite3.connect(args.db)

    if args.feedback is not None:
        _show_feedback(conn, args.feedback)
        return 0

    if args.all:
        sessions = _fetch_sessions(conn)
        by_puzzle = {}
        for name, sid, label in sessions:
            by_puzzle.setdefault(name, []).append((name, sid, label))
        for name in sorted(by_puzzle):
            _show_sessions_for_puzzle(conn, name, by_puzzle[name])
        return 0

    if not args.puzzle:
        _show_index(conn)
        return 0

    sessions = _fetch_sessions(conn, args.puzzle)
    _show_sessions_for_puzzle(conn, args.puzzle, sessions)
    return 0


if __name__ == "__main__":
    sys.exit(main())
