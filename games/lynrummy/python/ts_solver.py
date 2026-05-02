"""
ts_solver.py — Python wrapper around the TS engine via bridge.ts.

Subprocess-per-call. Same JSON wire format the Elm side will eventually
use. Drop-in alternative to `agent_prelude.find_play` and `bfs.solve_state`
for tooling that wants to exercise the TS engine without leaving Python.

Mirrors the public surface:
    ts_solver.find_play(hand, board) → dict | None
    ts_solver.solve(helper, trouble, growing, complete, ...) → list[str] | None

Both wrap one `node bridge.ts` invocation per call. Per-call overhead is
roughly Node's startup cost (~30–100 ms), which dominates fast BFS calls.
For correctness validation and real-world game playthroughs that's fine;
for perf benchmarks we'll likely batch or daemon-ize later. Per Steve:
start simple.
"""

import json
import subprocess
from pathlib import Path

_TS_DIR = Path(__file__).resolve().parent.parent / "ts"
_BRIDGE_PATH = _TS_DIR / "bridge.ts"


class TsSolverError(RuntimeError):
    """The TS bridge subprocess failed (parse error, dispatch error,
    or non-zero exit). Carries the bridge's stderr for triage."""


def _invoke(request):
    """Run bridge.ts with `request` as JSON on stdin; return parsed
    response. Raises TsSolverError on bridge failure."""
    proc = subprocess.run(
        ["node", str(_BRIDGE_PATH)],
        input=json.dumps(request),
        capture_output=True,
        text=True,
        cwd=_TS_DIR,
    )
    if proc.returncode != 0:
        raise TsSolverError(
            f"bridge.ts exited {proc.returncode}: {proc.stderr.strip()}"
        )
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise TsSolverError(
            f"bridge.ts emitted invalid JSON: {e} | stdout={proc.stdout!r}"
        )


def find_play(hand, board, *, stats=None):
    """Hand-aware play search. Mirrors `agent_prelude.find_play`.

    `hand` is a list of (value, suit, deck) tuples.
    `board` is a list of stacks, each a list of card tuples.

    `stats` (out-param dict): if provided, populated with
    `projections` (list of per-projection records: kind, cards,
    wall, found_plan, exhaustions) and `total_wall` (seconds).
    Mirrors Python `agent_prelude.find_play`'s stats shape.

    Returns a dict {"placements": [card, ...], "plan": [str, ...]}
    or None.
    """
    res = _invoke({
        "op": "find_play",
        "hand": [list(c) for c in hand],
        "board": [[list(c) for c in stack] for stack in board],
    })
    if stats is not None:
        stats["total_wall"] = float(res.get("total_wall", 0.0))
        stats["projections"] = [
            {
                "kind": p["kind"],
                "cards": [tuple(c) for c in p["cards"]],
                "wall": float(p["wall"]),
                "found_plan": bool(p["found_plan"]),
                "exhaustions": list(p.get("exhaustions", [])),
            }
            for p in res.get("projections", [])
        ]
    if res.get("placements") is None:
        return None
    return {
        "placements": [tuple(c) for c in res["placements"]],
        "plan": list(res["plan"]),
    }


def find_play_steps(hand, board):
    """Convenience: return the formatted hint step list (the
    "place [...] from hand" prefix + plan lines), matching
    `agent_prelude.format_hint(find_play(...))`. Returns [] when
    no play exists."""
    res = _invoke({
        "op": "find_play",
        "hand": [list(c) for c in hand],
        "board": [[list(c) for c in stack] for stack in board],
    })
    return list(res.get("steps", []))


def find_play_with_timing(hand, board):
    """Same as find_play_steps, but also returns engine-only wall
    time (excluding subprocess startup + JSON serialization).
    Returns (steps_list, engine_wall_ms)."""
    res = _invoke({
        "op": "find_play",
        "hand": [list(c) for c in hand],
        "board": [[list(c) for c in stack] for stack in board],
    })
    return list(res.get("steps", [])), float(res.get("engine_wall_ms", 0.0))


def solve(helper, trouble, growing, complete, *,
          max_trouble_outer=8, max_states=10000):
    """4-bucket BFS solve. Mirrors `bfs.solve_state`.

    Each bucket arg is a list of stacks (each stack a list of card
    tuples). Returns the plan as [str, ...] or None.
    """
    res = _invoke({
        "op": "solve",
        "buckets": {
            "helper": [[list(c) for c in s] for s in helper],
            "trouble": [[list(c) for c in s] for s in trouble],
            "growing": [[list(c) for c in s] for s in growing],
            "complete": [[list(c) for c in s] for s in complete],
        },
        "max_trouble_outer": max_trouble_outer,
        "max_states": max_states,
    })
    plan = res.get("plan")
    if plan is None:
        return None
    return list(plan)


def solve_board(board, *, max_trouble_outer=8, max_states=10000):
    """Flat-board BFS solve. Mirrors `bfs.solve(board, ...)` —
    partitions stacks into helper/trouble inside the bridge and
    runs the inner solver. Returns the plan as [str, ...] or None.
    """
    res = _invoke({
        "op": "solve_board",
        "board": [[list(c) for c in s] for s in board],
        "max_trouble_outer": max_trouble_outer,
        "max_states": max_states,
    })
    plan = res.get("plan")
    if plan is None:
        return None
    return list(plan)
