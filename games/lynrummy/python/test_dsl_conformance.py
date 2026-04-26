"""
test_dsl_conformance.py — run DSL scenarios against Python strategy.

Reads conformance_fixtures.json (emitted by cmd/fixturegen from
games/lynrummy/conformance/scenarios/*.dsl) and dispatches each
scenario by op. No framework. Run directly:

    python3 games/lynrummy/python/test_dsl_conformance.py

Supported ops:
  - build_suggestions: invoke strategy.enumerate_plays, compare
    trick_id + hand_cards row-by-row against `expect: suggestions`.
    (The DSL op name stays `build_suggestions` because the
    concept is shared with Elm, where the output feeds the
    human-facing hint surface; Python's internal function is
    `enumerate_plays` since the agent doesn't suggest, it
    enumerates.)
  - hint_invariant: invoke the named trick's emitter, apply its
    primitives to the input board, and assert every resulting
    stack classifies as a complete group (set / pure_run /
    rb_run) AND that the board is geometrically clean (every
    stack in bounds, no padded-overlap). Any other result fails
    — an invariant-violating emission is a bug.

Python is interpreted, so there is no codegen step for these
tests — the JSON file IS the source. Regenerate via:

    go run ./cmd/fixturegen ./games/lynrummy/conformance/scenarios/*.dsl
"""

import json
import sys
from pathlib import Path

import bfs_solver
import strategy
from geometry import find_violation

FIXTURES_PATH = Path(__file__).parent / "conformance_fixtures.json"


def _collect_hand_cards_from_primitives(prims):
    """A suggestion's hand_cards (in the Elm/Go sense) = the
    cards a trick's emission pulls from the hand, in the order
    the primitives consume them."""
    out = []
    for p in prims:
        if "hand_card" in p:
            out.append(p["hand_card"])
    return out


def _card_eq(a, b):
    return (a["value"] == b["value"]
            and a["suit"] == b["suit"]
            and a["origin_deck"] == b["origin_deck"])


def _run_build_suggestions(sc):
    hand = sc["hand"]
    board = sc["board"]
    got = strategy.enumerate_plays(hand, board)
    want = sc["expect"].get("suggestions", [])
    if len(got) != len(want):
        return False, (f"suggestion count: want {len(want)}, got "
                       f"{len(got)} ({[s['trick_id'] for s in got]})")
    for i, (g, w) in enumerate(zip(got, want)):
        if g["trick_id"] != w["trick_id"]:
            return False, (f"suggestion[{i}].trick_id: want "
                           f"{w['trick_id']!r}, got {g['trick_id']!r}")
        got_hc = _collect_hand_cards_from_primitives(g["primitives"])
        want_hc = w["hand_cards"]
        if len(got_hc) != len(want_hc):
            return False, (f"suggestion[{i}].hand_cards length: "
                           f"want {len(want_hc)}, got {len(got_hc)}")
        for j, (gc, wc) in enumerate(zip(got_hc, want_hc)):
            if not _card_eq(gc, wc):
                return False, (f"suggestion[{i}].hand_cards[{j}]: "
                               f"want {wc}, got {gc}")
    return True, f"OK — {len(got)} suggestions"


def _apply_primitives(board, prims):
    board = strategy._copy_board(board)
    for p in prims:
        kind = p["action"]
        if kind == "split":
            board = strategy._apply_split(board, p["stack_index"], p["card_index"])
        elif kind == "move_stack":
            board = strategy._apply_move(board, p["stack_index"], p["new_loc"])
        elif kind == "merge_stack":
            board = strategy._apply_merge_stack(
                board, p["source_stack"], p["target_stack"],
                p.get("side", "right"))
        elif kind == "merge_hand":
            board = strategy._apply_merge_hand(
                board, p["target_stack"], p["hand_card"],
                p.get("side", "right"))
        elif kind == "place_hand":
            board = strategy._apply_place_hand(
                board, p["hand_card"], p["loc"])
    return board


def _fmt_card(c):
    vals = {1: "A", 10: "T", 11: "J", 12: "Q", 13: "K"}
    return f"{vals.get(c['value'], str(c['value']))}{'CDSH'[c['suit']]}"


def _fmt_stack(s):
    return "[" + ",".join(_fmt_card(bc["card"]) for bc in s["board_cards"]) + "]"


def _run_hint_invariant(sc):
    trick_name = sc["trick"]
    emitter = getattr(strategy, trick_name, None)
    if emitter is None:
        return False, f"unknown trick {trick_name!r}"
    prims = emitter(sc["hand"], sc["board"])
    if prims is None:
        return False, "emitter returned None (trick did not fire)"
    try:
        final = _apply_primitives(sc["board"], prims)
    except (IndexError, KeyError) as e:
        return False, f"simulation crashed: {type(e).__name__}: {e}"
    for i, s in enumerate(final):
        cards = [bc["card"] for bc in s["board_cards"]]
        if strategy._classify(cards) == "other":
            return False, (f"stack {i} ({_fmt_stack(s)}) is incomplete "
                           f"after {len(prims)} primitives")
    bad_idx = find_violation(final)
    if bad_idx is not None:
        bad = final[bad_idx]
        return False, (f"stack {bad_idx} ({_fmt_stack(bad)}) at "
                       f"({bad['loc']['left']},{bad['loc']['top']}) "
                       f"violates geometry after {len(prims)} primitives")
    return True, f"OK — {len(prims)} primitives, {len(final)} clean stacks"


def _bucket_to_tuples(stacks):
    """Convert a JSON 4-bucket section (list of stacks with
    board_cards) into bfs_solver's tuple-of-tuples shape."""
    return [
        [(bc["card"]["value"], bc["card"]["suit"],
          bc["card"]["origin_deck"])
         for bc in s["board_cards"]]
        for s in stacks
    ]


def _run_enumerate_moves(sc):
    """Build a 4-bucket state from the scenario's helper/trouble/
    growing/complete sections, walk `bfs_solver.enumerate_moves`,
    and assert at least one yielded desc matches the expected
    `yields` type."""
    state = (
        _bucket_to_tuples(sc.get("helper", [])),
        _bucket_to_tuples(sc.get("trouble", [])),
        _bucket_to_tuples(sc.get("growing", [])),
        _bucket_to_tuples(sc.get("complete", [])),
    )
    expected_type = sc["expect"].get("yields", "")
    if not expected_type:
        return False, "expect.yields missing"
    moves = list(bfs_solver.enumerate_moves(state))
    matches = [d for d, _ in moves if d["type"] == expected_type]
    if not matches:
        types = sorted({d["type"] for d, _ in moves})
        return False, (f"no {expected_type!r} move yielded; "
                       f"types seen: {types or 'none'}")
    return True, (f"OK — {len(moves)} moves yielded, "
                  f"{len(matches)} matched {expected_type!r}")


def _run_solve(sc):
    """Build a 4-bucket state, walk `bfs_solver.solve_state`,
    and assert on `no_plan` or `plan_length` per the scenario."""
    state = (
        _bucket_to_tuples(sc.get("helper", [])),
        _bucket_to_tuples(sc.get("trouble", [])),
        _bucket_to_tuples(sc.get("growing", [])),
        _bucket_to_tuples(sc.get("complete", [])),
    )
    plan = bfs_solver.solve_state(
        state, max_trouble_outer=10, max_states=200000,
        verbose=False)

    expect = sc["expect"]
    if expect.get("no_plan"):
        if plan is None:
            return True, "OK — no plan, as expected"
        return False, f"expected no plan; got plan of length {len(plan)}"

    plan_length = expect.get("plan_length", 0)
    if plan_length > 0:
        if plan is None:
            return False, f"expected plan of length {plan_length}; got None"
        if len(plan) == plan_length:
            return True, f"OK — plan of length {plan_length}"
        return False, (f"expected plan of length {plan_length}; "
                       f"got {len(plan)}")
    return False, "solve scenario missing expectation (no_plan or plan_length)"


DISPATCH = {
    "build_suggestions": _run_build_suggestions,
    "hint_invariant":    _run_hint_invariant,
    "enumerate_moves":   _run_enumerate_moves,
    "solve":             _run_solve,
}


def main():
    scenarios = json.loads(FIXTURES_PATH.read_text())
    passed = failed = skipped = 0
    for sc in scenarios:
        op = sc["op"]
        runner = DISPATCH.get(op)
        if runner is None:
            skipped += 1
            print(f"SKIP  {sc['name']:<50}  (op {op!r} not handled by Python)")
            continue
        try:
            ok, msg = runner(sc)
        except Exception as e:
            ok, msg = False, f"{type(e).__name__}: {e}"
        status = "PASS" if ok else "FAIL"
        if ok:
            passed += 1
        else:
            failed += 1
        print(f"{status}  {sc['name']:<50}  {msg}")
    print()
    total = passed + failed
    print(f"{passed}/{total} passed  ({skipped} skipped)")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
