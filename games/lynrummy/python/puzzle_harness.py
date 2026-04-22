"""
puzzle_harness.py — CLI for the decomposition harness.

Three commands:

  --list                         catalog of puzzle names + descriptions
  --play  <name>                 create a puzzle session, print the URL
  --compare <name> --session <id>  diff Steve's primitives vs the decomposer's

Typical flow:

  python3 games/lynrummy/python/puzzle_harness.py --list
  python3 games/lynrummy/python/puzzle_harness.py --play hand_stacks_basic
  # Steve opens the URL, solves it.
  python3 games/lynrummy/python/puzzle_harness.py --compare hand_stacks_basic --session 7
"""

import argparse
import json
import sys
import urllib.request
import urllib.error

import puzzles
import strategy
import dsl
from compare import compare


DEFAULT_BASE = "http://localhost:9000/gopher/lynrummy-elm"


def _http_get(url):
    with urllib.request.urlopen(url) as resp:
        return json.loads(resp.read())


def _http_post(url, body):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode("utf-8"),
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())


def _derive_expected(puzzle_spec):
    """Ask strategy.py for the top-ranked trick's primitive sequence
    at the puzzle's initial state. If target_trick doesn't match
    what fires first, we surface that as a mismatch."""
    state = puzzle_spec["initial_state"]
    hand = state["hands"][state["active_player_index"]]["hand_cards"]
    board = state["board"]
    suggestions = strategy.build_suggestions(hand, board)
    want = puzzle_spec["target_trick"]
    for s in suggestions:
        if s["trick_id"] == want:
            return s["primitives"]
    if suggestions:
        raise RuntimeError(
            f"puzzle target_trick={want!r} but strategy.py returned "
            f"{[s['trick_id'] for s in suggestions]!r}"
        )
    raise RuntimeError(f"strategy.py returned no suggestions for {want!r}")


def _fmt_primitive(p):
    kind = p["action"]
    body = {k: v for k, v in p.items() if k != "action"}
    return f"{kind:<14}  {json.dumps(body)}"


def cmd_list():
    names = puzzles.all_names()
    if not names:
        print("(no puzzles in catalog)")
        return
    for name in names:
        p = puzzles.get_puzzle(name)
        print(f"  {name}")
        print(f"      trick: {p['target_trick']}")
        print(f"      {p['description']}")


def cmd_play(name, base):
    p = puzzles.get_puzzle(name)
    envelope = {
        "label": f"puzzle: {name}",
        "initial_state": p["initial_state"],
    }
    try:
        data = _http_post(f"{base}/new-puzzle-session", envelope)
    except urllib.error.HTTPError as e:
        sys.exit(f"error: {e.code} — {e.read().decode('utf-8', 'replace')}")
    sid = data["session_id"]
    print(f"puzzle: {name}")
    print(f"trick:  {p['target_trick']}")
    print(f"task:   {p['description']}")
    print()
    print(f"session id: {sid}")
    print(f"open:       {base}/#{sid}")


def cmd_compare(name, session_id, base):
    puzzle = puzzles.get_puzzle(name)
    # Actual: Steve's primitives, pulled from the session.
    try:
        sess = _http_get(f"{base}/sessions/{session_id}/actions")
    except urllib.error.HTTPError as e:
        sys.exit(f"error: {e.code} — {e.read().decode('utf-8', 'replace')}")
    actual = [envelope["action"] for envelope in sess.get("actions", [])]

    # Expected: what the decomposer would emit.
    try:
        expected = _derive_expected(puzzle)
    except NotImplementedError as e:
        print(f"(decomposer stub) — {e}")
        print()
        print("Steve's primitive sequence:")
        for i, p in enumerate(actual, 1):
            print(f"  [{i}] {_fmt_primitive(p)}")
        return

    initial_state = puzzle["initial_state"]
    report = compare(expected, actual, initial_state)

    print(f"puzzle: {name}   session {session_id}")
    print(f"trick:  {puzzle['target_trick']}")
    print()
    print(f"Expected ({len(expected)}):")
    for line in dsl.render_sequence(expected, initial_state):
        print(f"  {line}")
    print()
    print(f"Actual ({len(actual)}):")
    for line in dsl.render_sequence(actual, initial_state):
        print(f"  {line}")
    print()
    print(f"overall: {report['overall']}")
    for note in report["notes"]:
        print(f"  {note}")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base", default=DEFAULT_BASE)
    ap.add_argument("--list", action="store_true",
                    help="Show available puzzles.")
    ap.add_argument("--play", metavar="NAME",
                    help="Create a puzzle session; print URL.")
    ap.add_argument("--compare", metavar="NAME",
                    help="Diff a solved session against the decomposer.")
    ap.add_argument("--session", type=int,
                    help="Session id (required with --compare).")
    args = ap.parse_args()

    if args.list:
        cmd_list()
        return
    if args.play:
        cmd_play(args.play, args.base)
        return
    if args.compare:
        if args.session is None:
            ap.error("--compare requires --session <id>")
        cmd_compare(args.compare, args.session, args.base)
        return
    ap.print_help()


if __name__ == "__main__":
    main()
