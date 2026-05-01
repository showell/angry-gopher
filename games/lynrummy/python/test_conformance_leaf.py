"""test_conformance_leaf.py — Conformance runner for leaf-level
BFS functions.

Each leaf has a JSON fixture under `conformance/leaf/<function>.json`
describing input/expected pairs. The runner dispatches on the
`function` field and runs every scenario against the live Python
implementation.

Goals:
  - Pin Python's leaf behavior so it can't drift silently.
  - Provide a language-agnostic spec for the upcoming TS port.
  - Give a human-readable contract: every scenario should be
    self-evidently true to anyone who reads the JSON.

Run directly:
    python3 games/lynrummy/python/test_conformance_leaf.py
"""

import json
import os
import sys
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from rules.card import card as parse_card_label
from classified_card_stack import classify_stack


_HERE = os.path.dirname(os.path.abspath(__file__))
_FIXTURE_DIR = os.path.join(_HERE, "conformance", "leaf")


# --- Per-function runners ---

def _run_classify_stack(scenario):
    cards = [parse_card_label(label) for label in scenario["cards"]]
    result = classify_stack(cards)
    actual = None if result is None else result.kind
    expected = scenario["expected_kind"]
    if actual != expected:
        return f"expected {expected!r}, got {actual!r}"
    return None


_RUNNERS = {
    "classify_stack": _run_classify_stack,
}


# --- Driver ---

def _load_fixture(path):
    with open(path) as f:
        return json.load(f)


def _is_scenario(entry):
    """Section-marker entries (entries with `_section`) are doc-
    only and don't run. Real scenarios have a `name`."""
    return "name" in entry


def _run_fixture(path):
    fixture = _load_fixture(path)
    fn_name = fixture["function"]
    runner = _RUNNERS.get(fn_name)
    if runner is None:
        print(f"SKIP {fn_name} (no runner registered)")
        return 0, 0, 0
    scenarios = [s for s in fixture["scenarios"] if _is_scenario(s)]
    failures = 0
    for sc in scenarios:
        try:
            err = runner(sc)
        except Exception as e:
            err = f"{type(e).__name__}: {e}"
            traceback.print_exc()
        if err is not None:
            print(f"FAIL {fn_name} :: {sc['name']}: {err}")
            failures += 1
    return len(scenarios), len(scenarios) - failures, failures


def main():
    if not os.path.isdir(_FIXTURE_DIR):
        print(f"no fixture dir at {_FIXTURE_DIR}", file=sys.stderr)
        sys.exit(1)
    paths = sorted(
        os.path.join(_FIXTURE_DIR, f)
        for f in os.listdir(_FIXTURE_DIR)
        if f.endswith(".json")
    )
    if not paths:
        print(f"no fixtures in {_FIXTURE_DIR}", file=sys.stderr)
        sys.exit(1)

    grand_total = 0
    grand_passed = 0
    grand_failed = 0
    for path in paths:
        total, passed, failed = _run_fixture(path)
        grand_total += total
        grand_passed += passed
        grand_failed += failed
        name = os.path.basename(path)
        if failed:
            print(f"  {name}: {passed}/{total} passed ({failed} failed)")
        else:
            print(f"  {name}: {total}/{total} passed")

    print()
    print(f"{grand_passed}/{grand_total} leaf conformance scenarios passed")
    if grand_failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
