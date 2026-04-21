"""
Behaviorist telemetry reader for the LynRummy Elm action log.

The Elm client attaches a drag path (list of pointer samples
with timestamps) to each drag-derived WireAction via the
envelope shape:

    POST /gopher/lynrummy-elm/actions
    {"action": {...}, "gesture_metadata": {"path": [{"t","x","y"}, ...]}}

The server persists `gesture_metadata` in a sibling column on
`lynrummy_elm_actions`. This module is the Python read side —
direct SQLite, no HTTP. (Relaxation of the "CRUD HTML is agent
interface" rule: telemetry is analysis data, not gameplay data,
and there's no enumerate-and-bridge benefit to tunneling it
through HTTP.)

## Usage

    from telemetry import gesture_trail
    for seq, kind, meta in gesture_trail(session_id=42):
        if meta:
            path = meta["path"]
            dt = path[-1]["t"] - path[0]["t"]
            print(f"seq={seq} kind={kind} duration={dt:.0f}ms pts={len(path)}")

## CLI

    python3 telemetry.py 42       # dump trail for session 42
    python3 telemetry.py 42 3     # dump just seq=3
"""

import json
import os
import sqlite3
import sys

DEFAULT_DB = os.path.expanduser("~/AngryGopher/prod/gopher.db")


def _connect(db_path=None):
    path = db_path or os.environ.get("GOPHER_DB") or DEFAULT_DB
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def gesture_trail(session_id, *, db_path=None):
    """Yield (seq, action_kind, gesture_metadata_dict_or_None)
    for every action in a session, ordered by seq.

    gesture_metadata is None for non-drag actions and for any
    action recorded before telemetry capture was wired up.
    """
    conn = _connect(db_path)
    try:
        rows = conn.execute(
            "SELECT seq, action_kind, gesture_metadata "
            "FROM lynrummy_elm_actions WHERE session_id = ? "
            "ORDER BY seq",
            (session_id,),
        ).fetchall()
    finally:
        conn.close()
    for row in rows:
        meta = json.loads(row["gesture_metadata"]) if row["gesture_metadata"] else None
        yield row["seq"], row["action_kind"], meta


def drag_summary(meta):
    """Collapse a gesture_metadata dict to a compact dict:
    {'n_points', 'duration_ms', 'start', 'end'}.

    Returns None if meta is None or has no path.
    """
    if not meta or "path" not in meta or not meta["path"]:
        return None
    path = meta["path"]
    first, last = path[0], path[-1]
    return {
        "n_points": len(path),
        "duration_ms": last["t"] - first["t"],
        "start": (first["x"], first["y"]),
        "end": (last["x"], last["y"]),
    }


def _cli(argv):
    if len(argv) < 2:
        print("usage: telemetry.py <session_id> [seq]", file=sys.stderr)
        return 2
    session_id = int(argv[1])
    seq_filter = int(argv[2]) if len(argv) >= 3 else None
    for seq, kind, meta in gesture_trail(session_id):
        if seq_filter is not None and seq != seq_filter:
            continue
        summary = drag_summary(meta)
        if summary is None:
            print(f"seq={seq:3d} kind={kind:18s} (no gesture)")
        else:
            print(
                f"seq={seq:3d} kind={kind:18s} "
                f"pts={summary['n_points']:3d} "
                f"dur={summary['duration_ms']:7.1f}ms "
                f"{summary['start']} -> {summary['end']}"
            )
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv))
