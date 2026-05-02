"""
test_dsl_conformance.py — run DSL scenarios against Python BFS + geometry.

Reads conformance_fixtures.json (emitted by cmd/fixturegen from
games/lynrummy/conformance/scenarios/*.dsl) and dispatches each
scenario by op. No framework. Run directly:

    python3 games/lynrummy/python/test_dsl_conformance.py

Supported ops: enumerate_moves, solve, find_open_loc,
hint_for_hand. The legacy strategy/trick layer (build_suggestions,
hint_invariant) was removed when the tricks code was retired —
hints flow through the BFS solver now.

Python is interpreted, so there is no codegen step for these
tests — the JSON file IS the source. Regenerate via:

    go run ./cmd/fixturegen ./games/lynrummy/conformance/scenarios/*.dsl
"""

import json
import sys
from pathlib import Path

import bfs
import enumerator
import move
import agent_prelude
from rules.card import card as parse_card_label

FIXTURES_PATH = Path(__file__).parent / "conformance_fixtures.json"
OPS_MANIFEST_PATH = Path(__file__).parent / "conformance_ops.json"


def _bucket_to_tuples(stacks):
    """Convert a JSON 4-bucket section (list of stacks with
    board_cards) into the BFS solver's tuple-of-tuples shape."""
    return [
        [(bc["card"]["value"], bc["card"]["suit"],
          bc["card"]["origin_deck"])
         for bc in s["board_cards"]]
        for s in stacks
    ]


def _run_enumerate_moves(sc):
    """Build a 4-bucket state from the scenario's helper/trouble/
    growing/complete sections, walk `enumerator.enumerate_moves`,
    and assert against any of:
      - expect.yields: at least one move has this type
      - expect.narrate_contains: at least one move's narrate()
        contains this substring
      - expect.hint_contains: at least one move's hint()
        contains this substring
    """
    state = (
        _bucket_to_tuples(sc.get("helper", [])),
        _bucket_to_tuples(sc.get("trouble", [])),
        _bucket_to_tuples(sc.get("growing", [])),
        _bucket_to_tuples(sc.get("complete", [])),
    )
    expect = sc["expect"]
    expected_type = expect.get("yields", "")
    narrate_sub = expect.get("narrate_contains", "")
    hint_sub = expect.get("hint_contains", "")

    if not (expected_type or narrate_sub or hint_sub):
        return False, ("expect missing yields / narrate_contains "
                       "/ hint_contains")

    moves = list(enumerator.enumerate_moves(state))

    if expected_type:
        matches = [d for d, _ in moves if d.type == expected_type]
        if not matches:
            types = sorted({d.type for d, _ in moves})
            return False, (f"no {expected_type!r} move yielded; "
                           f"types seen: {types or 'none'}")

    if narrate_sub:
        narrates = [move.narrate(d) for d, _ in moves]
        if not any(narrate_sub in n for n in narrates):
            sample = narrates[:3]
            return False, (f"no narrate contains {narrate_sub!r}; "
                           f"sample: {sample}")

    if hint_sub:
        hints = [move.hint(d) for d, _ in moves]
        hints = [h for h in hints if h is not None]
        if not any(hint_sub in h for h in hints):
            sample = hints[:3]
            return False, (f"no hint contains {hint_sub!r}; "
                           f"sample: {sample}")

    return True, (f"OK — {len(moves)} moves yielded, "
                  f"assertions matched")


def _run_solve(sc):
    """Build a 4-bucket state, walk `bfs.solve_state`,
    and assert on `no_plan` / `plan_length` / `plan_lines`
    per the scenario."""
    state = (
        _bucket_to_tuples(sc.get("helper", [])),
        _bucket_to_tuples(sc.get("trouble", [])),
        _bucket_to_tuples(sc.get("growing", [])),
        _bucket_to_tuples(sc.get("complete", [])),
    )
    plan = bfs.solve_state(
        state, max_trouble_outer=10, max_states=200000,
        verbose=False)

    expect = sc["expect"]
    if expect.get("no_plan"):
        if plan is None:
            return True, "OK — no plan, as expected"
        return False, f"expected no plan; got plan of length {len(plan)}"

    plan_lines = expect.get("plan_lines")
    if plan_lines:
        if plan is None:
            return False, (f"expected plan of {len(plan_lines)} lines; "
                           f"got None")
        if plan == plan_lines:
            return True, f"OK — plan_lines match ({len(plan)} lines)"
        # Find first divergence for a useful message.
        for i, (got, want) in enumerate(zip(plan, plan_lines)):
            if got != want:
                return False, (
                    f"plan_lines diverge at line {i+1}: "
                    f"want {want!r}, got {got!r}")
        return False, (f"plan_lines length: want {len(plan_lines)}, "
                       f"got {len(plan)}")

    plan_length = expect.get("plan_length", 0)
    if plan_length > 0:
        if plan is None:
            return False, f"expected plan of length {plan_length}; got None"
        if len(plan) == plan_length:
            return True, f"OK — plan of length {plan_length}"
        return False, (f"expected plan of length {plan_length}; "
                       f"got {len(plan)}")
    return False, ("solve scenario missing expectation "
                   "(no_plan / plan_length / plan_lines)")


def _run_find_open_loc(sc):
    """Geometry parity: invoke `geometry.find_open_loc` on the
    scenario's `existing` stacks + `card_count`, assert the
    returned loc matches `expect.loc` exactly. The same fixture
    runs in Elm via `Game.PlaceStack.findOpenLoc`, so any drift
    between the two algorithms shows up identically on both
    sides."""
    import geometry
    expect = sc["expect"]
    want = expect.get("loc")
    if want is None:
        return False, "find_open_loc scenario missing expect.loc"
    existing = sc.get("existing", [])
    card_count = sc.get("card_count", 0)
    got = geometry.find_open_loc(existing, card_count)
    if got["top"] == want["top"] and got["left"] == want["left"]:
        return True, (f"OK — loc=({got['top']},{got['left']})")
    return False, (f"want ({want['top']},{want['left']}); "
                   f"got ({got['top']},{got['left']})")


def _run_hint_for_hand(sc):
    """End-to-end hint test: parse hand + board from label strings,
    run agent_prelude.find_play + format_hint, assert steps match."""
    hand = [parse_card_label(tok) for tok in sc["hint_hand"]]
    board = [
        [parse_card_label(tok) for tok in stack]
        for stack in sc["hint_board"]
    ]
    result = agent_prelude.find_play(hand, board)
    got = agent_prelude.format_hint(result)
    want = sc["hint_steps"]
    if got == want:
        return True, f"OK — {len(got)} steps"
    if len(got) != len(want):
        return False, (
            f"step count: want {len(want)}, got {len(got)}\n"
            f"  want: {want}\n"
            f"  got:  {got}"
        )
    for i, (g, w) in enumerate(zip(got, want)):
        if g != w:
            return False, (
                f"step[{i}] mismatch:\n"
                f"  want: {w!r}\n"
                f"  got:  {g!r}"
            )
    return False, f"steps differ (lengths match but no single divergence found)"


DISPATCH = {
    "enumerate_moves":   _run_enumerate_moves,
    "solve":             _run_solve,
    "find_open_loc":     _run_find_open_loc,
    "hint_for_hand":     _run_hint_for_hand,
}


def _verify_dispatch_matches_manifest():
    """Cross-check DISPATCH against the Go registry's manifest.

    The fixturegen tool emits `conformance_ops.json` listing the
    op names the registry says should run on each target. If the
    Python DISPATCH dict disagrees with the manifest's `python`
    list, an op was added (or removed) on one side and not the
    other — which would otherwise show up as a silent SKIP. We'd
    rather fail loud than silently pass with reduced coverage.

    See cmd/fixturegen/ADDING_AN_OP.md.
    """
    manifest = json.loads(OPS_MANIFEST_PATH.read_text())
    expected = set(manifest.get("python", []))
    actual = set(DISPATCH.keys())
    missing_in_dispatch = sorted(expected - actual)
    extra_in_dispatch = sorted(actual - expected)
    if missing_in_dispatch or extra_in_dispatch:
        print("DISPATCH / registry drift:", file=sys.stderr)
        if missing_in_dispatch:
            print(f"  registry says python should handle: "
                  f"{missing_in_dispatch} — but DISPATCH has no entry. "
                  "Add a runner to test_dsl_conformance.py or set "
                  "Python=false on the OpKind.",
                  file=sys.stderr)
        if extra_in_dispatch:
            print(f"  DISPATCH has runners for: {extra_in_dispatch} "
                  "— but the Go registry doesn't mark them Python=true. "
                  "Update opRegistry in cmd/fixturegen/main.go or "
                  "remove the dead Python runner.",
                  file=sys.stderr)
        return False
    return True


def main():
    if not _verify_dispatch_matches_manifest():
        return 2
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
