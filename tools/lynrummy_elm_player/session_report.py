"""
session_report.py — human-readable summary of a LynRummy Elm
session.

Combines the action log with the behaviorist gesture telemetry
into one pass so the agent (and Steve) can see what the human
did AND how they did it. Pure analysis; reads direct from
SQLite.

Example:

    $ python3 session_report.py 12
    session 12 · created 2026-04-19T15:58 · seed 1234567890
    ─────────────────────────────────────────────────────────
      1  split           stack=5 card=2                412ms  18pts  1.04x
      2  merge_hand      7H → stack[3] right           723ms  29pts  1.12x
      3  move_stack      stack=4 → (120, 80)           305ms  11pts  1.00x
      4  complete_turn                                 (no gesture)
    ─────────────────────────────────────────────────────────
    4 actions, 3 drags, total drag time 1.44s

    $ python3 session_report.py 12 --format=json
    {...}

Path-length ratio: actual path length / straight-line
distance. 1.0 = ruler-straight; >> 1.0 = curvy or hesitant.
A behaviorist metric — measure the movement, don't infer the
mind.
"""

import argparse
import datetime
import json
import math
import os
import sqlite3
import sys

DEFAULT_DB = os.path.expanduser("~/AngryGopher/prod/gopher.db")


def _connect(db_path=None):
    path = db_path or os.environ.get("GOPHER_DB") or DEFAULT_DB
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def session_header(session_id, *, db_path=None):
    conn = _connect(db_path)
    try:
        row = conn.execute(
            "SELECT id, created_at, label, deck_seed "
            "FROM lynrummy_elm_sessions WHERE id = ?",
            (session_id,),
        ).fetchone()
    finally:
        conn.close()
    if row is None:
        return None
    return {
        "id": row["id"],
        "created_at": row["created_at"],
        "label": row["label"],
        "deck_seed": row["deck_seed"],
    }


def session_actions(session_id, *, db_path=None):
    """Yield every action row for a session as a dict with
    parsed action + parsed gesture metadata. Ordered by seq.
    """
    conn = _connect(db_path)
    try:
        rows = conn.execute(
            "SELECT seq, action_kind, action_json, gesture_metadata, created_at "
            "FROM lynrummy_elm_actions WHERE session_id = ? "
            "ORDER BY seq",
            (session_id,),
        ).fetchall()
    finally:
        conn.close()
    for row in rows:
        yield {
            "seq": row["seq"],
            "kind": row["action_kind"],
            "action": json.loads(row["action_json"]),
            "gesture": (
                json.loads(row["gesture_metadata"])
                if row["gesture_metadata"]
                else None
            ),
            "created_at": row["created_at"],
        }


# --- Drag metrics --------------------------------------------

def drag_metrics(gesture):
    """Per-drag behaviorist metrics. Returns None for no-gesture.

    Fields:
      duration_ms    — last.t - first.t
      n_points       — sample count
      path_length    — sum of segment distances (viewport px)
      straight_line  — distance from first to last point
      ratio          — path_length / straight_line (∞ if zero)
    """
    if not gesture or "path" not in gesture or not gesture["path"]:
        return None
    path = gesture["path"]
    if len(path) < 2:
        # Single sample — no motion to measure.
        return {
            "duration_ms": 0.0,
            "n_points": len(path),
            "path_length": 0.0,
            "straight_line": 0.0,
            "ratio": 1.0,
        }
    first, last = path[0], path[-1]
    duration = last["t"] - first["t"]
    path_length = 0.0
    for a, b in zip(path, path[1:]):
        path_length += math.hypot(b["x"] - a["x"], b["y"] - a["y"])
    straight = math.hypot(last["x"] - first["x"], last["y"] - first["y"])
    ratio = path_length / straight if straight > 0 else float("inf")
    return {
        "duration_ms": duration,
        "n_points": len(path),
        "path_length": path_length,
        "straight_line": straight,
        "ratio": ratio,
    }


# --- Action description --------------------------------------

def describe_action(action):
    """One-line concise description of a WireAction payload."""
    kind = action.get("action", "?")
    if kind == "split":
        return f"stack={action['stack_index']} card={action['card_index']}"
    if kind == "merge_stack":
        return (
            f"stack[{action['source_stack']}] → stack[{action['target_stack']}] "
            f"{action['side']}"
        )
    if kind == "merge_hand":
        card = _card_label(action.get("hand_card"))
        return f"{card} → stack[{action['target_stack']}] {action['side']}"
    if kind == "place_hand":
        card = _card_label(action.get("hand_card"))
        loc = action.get("loc", {})
        return f"{card} → ({loc.get('left', '?')}, {loc.get('top', '?')})"
    if kind == "move_stack":
        loc = action.get("new_loc", {})
        return (
            f"stack={action['stack_index']} → "
            f"({loc.get('left', '?')}, {loc.get('top', '?')})"
        )
    if kind == "complete_turn":
        return ""
    if kind == "undo":
        return ""
    if kind == "trick_result":
        return f"trick={action.get('trick_id', '?')}"
    if kind == "play_trick":
        return f"trick={action.get('trick_id', '?')}"
    return ""


_VALUE_LABELS = {
    1: "A", 2: "2", 3: "3", 4: "4", 5: "5", 6: "6", 7: "7",
    8: "8", 9: "9", 10: "T", 11: "J", 12: "Q", 13: "K",
}
_SUIT_LABELS = {0: "C", 1: "D", 2: "S", 3: "H"}


def _card_label(card):
    if not card:
        return "?"
    v = _VALUE_LABELS.get(card.get("value"), "?")
    s = _SUIT_LABELS.get(card.get("suit"), "?")
    return f"{v}{s}"


# --- Rendering -----------------------------------------------

def format_text(session_id, *, db_path=None):
    header = session_header(session_id, db_path=db_path)
    if header is None:
        return f"session {session_id}: not found\n"

    created = datetime.datetime.fromtimestamp(header["created_at"]).isoformat(
        timespec="minutes"
    )
    label_part = f" · label {header['label']!r}" if header["label"] else ""
    lines = [
        f"session {header['id']} · created {created} · "
        f"seed {header['deck_seed']}{label_part}",
        "─" * 65,
    ]

    n_actions = 0
    n_drags = 0
    total_drag_ms = 0.0
    for row in session_actions(session_id, db_path=db_path):
        n_actions += 1
        desc = describe_action(row["action"])
        metrics = drag_metrics(row["gesture"])
        if metrics is None or metrics["n_points"] < 2:
            gesture_str = "(no gesture)"
        else:
            n_drags += 1
            total_drag_ms += metrics["duration_ms"]
            gesture_str = (
                f"{metrics['duration_ms']:6.0f}ms  "
                f"{metrics['n_points']:3d}pts  "
                f"{metrics['ratio']:.2f}x"
            )
        lines.append(
            f"  {row['seq']:>2}  {row['kind']:<14s}  {desc:<30s}  {gesture_str}"
        )

    lines.append("─" * 65)
    lines.append(
        f"{n_actions} actions, {n_drags} drag"
        f"{'s' if n_drags != 1 else ''}, "
        f"total drag time {total_drag_ms / 1000:.2f}s"
    )
    return "\n".join(lines) + "\n"


def format_json(session_id, *, db_path=None):
    header = session_header(session_id, db_path=db_path)
    if header is None:
        return json.dumps({"error": "session not found", "id": session_id})
    actions = []
    for row in session_actions(session_id, db_path=db_path):
        metrics = drag_metrics(row["gesture"])
        actions.append(
            {
                "seq": row["seq"],
                "kind": row["kind"],
                "action": row["action"],
                "gesture_metrics": metrics,
            }
        )
    return json.dumps({"session": header, "actions": actions}, indent=2)


# --- CLI -----------------------------------------------------

def _cli(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session_id", type=int)
    parser.add_argument(
        "--format", choices=("text", "json"), default="text",
    )
    parser.add_argument("--db", default=None,
                        help="SQLite path (default: $GOPHER_DB or prod)")
    args = parser.parse_args(argv[1:])

    if args.format == "json":
        sys.stdout.write(format_json(args.session_id, db_path=args.db))
        sys.stdout.write("\n")
    else:
        sys.stdout.write(format_text(args.session_id, db_path=args.db))
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv))
