"""
test_dsl_conformance.py — run DSL scenarios against Python hints.

Reads conformance_fixtures.json (emitted by cmd/fixturegen from
games/lynrummy/conformance/scenarios/*.dsl) and dispatches each
scenario by op. No framework. Run directly:

    python3 tools/lynrummy_elm_player/test_dsl_conformance.py

Supported ops:
  - build_suggestions: invoke hints.build_suggestions, compare
    trick_id + hand_cards row-by-row against `expect: suggestions`.

Python is interpreted, so there is no codegen step for these
tests — the JSON file IS the source. Regenerate via:

    go run ./cmd/fixturegen ./games/lynrummy/conformance/scenarios/*.dsl
"""

import json
import sys
from pathlib import Path

import hints

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
    got = hints.build_suggestions(hand, board)
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


DISPATCH = {
    "build_suggestions": _run_build_suggestions,
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
