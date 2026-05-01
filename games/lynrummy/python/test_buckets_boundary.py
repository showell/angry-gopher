"""test_buckets_boundary.py — Coverage for classify_buckets.

The boundary helper that converts raw `Buckets` of card lists into
`Buckets` of `ClassifiedCardStack` lists. Raises on any invalid stack.
"""

import sys
import traceback

from rules.card import card

from buckets import Buckets, classify_buckets
from classified_card_stack import (
    KIND_RUN, KIND_RB, KIND_SET,
    KIND_PAIR_RUN, KIND_PAIR_SET,
    KIND_SINGLETON,
)


def _stack(*labels):
    return [card(lbl) for lbl in labels]


def test_empty_buckets_pass_through():
    raw = Buckets(helper=[], trouble=[], growing=[], complete=[])
    result = classify_buckets(raw)
    assert result.helper == []
    assert result.trouble == []
    assert result.growing == []
    assert result.complete == []


def test_classifies_each_bucket():
    raw = Buckets(
        helper=[_stack("AC", "2C", "3C")],
        trouble=[_stack("KC")],
        growing=[_stack("AC", "AD")],
        complete=[_stack("4D", "4H", "4S")],
    )
    result = classify_buckets(raw)
    assert result.helper[0].kind == KIND_RUN
    assert result.trouble[0].kind == KIND_SINGLETON
    assert result.growing[0].kind == KIND_PAIR_SET
    assert result.complete[0].kind == KIND_SET


def test_preserves_card_order_within_stack():
    raw = Buckets(
        helper=[_stack("AC", "2C", "3C")],
        trouble=[],
        growing=[],
        complete=[],
    )
    result = classify_buckets(raw)
    assert result.helper[0].cards == tuple(_stack("AC", "2C", "3C"))


def test_preserves_stack_order_within_bucket():
    raw = Buckets(
        helper=[_stack("AC", "2C", "3C"), _stack("5D", "6D", "7D")],
        trouble=[],
        growing=[],
        complete=[],
    )
    result = classify_buckets(raw)
    assert len(result.helper) == 2
    assert result.helper[0].cards[0] == card("AC")
    assert result.helper[1].cards[0] == card("5D")


def test_rb_classifies():
    raw = Buckets(
        helper=[_stack("AC", "2D", "3C")],
        trouble=[], growing=[], complete=[],
    )
    result = classify_buckets(raw)
    assert result.helper[0].kind == KIND_RB


def test_pair_run_in_growing():
    raw = Buckets(
        helper=[],
        trouble=[],
        growing=[_stack("5C", "6C")],
        complete=[],
    )
    result = classify_buckets(raw)
    assert result.growing[0].kind == KIND_PAIR_RUN


def test_invalid_stack_in_helper_raises():
    raw = Buckets(
        helper=[_stack("AC", "4C")],  # disconnected — not classifiable
        trouble=[], growing=[], complete=[],
    )
    try:
        classify_buckets(raw)
    except ValueError as e:
        assert "helper[0]" in str(e)
        return
    assert False, "expected ValueError"


def test_invalid_stack_in_trouble_raises():
    raw = Buckets(
        helper=[],
        trouble=[_stack("AC", "AC")],  # duplicate-suit set
        growing=[], complete=[],
    )
    try:
        classify_buckets(raw)
    except ValueError as e:
        assert "trouble[0]" in str(e)
        return
    assert False, "expected ValueError"


def test_invalid_stack_in_growing_raises():
    raw = Buckets(
        helper=[], trouble=[],
        growing=[_stack("AC", "AD", "2C")],  # set-with-runner — invalid
        complete=[],
    )
    try:
        classify_buckets(raw)
    except ValueError as e:
        assert "growing[0]" in str(e)
        return
    assert False, "expected ValueError"


def test_invalid_stack_in_complete_raises():
    raw = Buckets(
        helper=[], trouble=[], growing=[],
        complete=[_stack("AC", "2C", "3D")],  # mixed suit/color run
    )
    try:
        classify_buckets(raw)
    except ValueError as e:
        assert "complete[0]" in str(e)
        return
    assert False, "expected ValueError"


def test_error_includes_bucket_index():
    raw = Buckets(
        helper=[_stack("AC", "2C", "3C"), _stack("5D", "5D")],  # second bad
        trouble=[], growing=[], complete=[],
    )
    try:
        classify_buckets(raw)
    except ValueError as e:
        assert "helper[1]" in str(e)
        return
    assert False, "expected ValueError"


def test_returns_buckets_namedtuple():
    raw = Buckets(helper=[], trouble=[], growing=[], complete=[])
    result = classify_buckets(raw)
    assert isinstance(result, Buckets)


def test_buckets_are_independent_lists():
    raw = Buckets(
        helper=[_stack("AC", "2C", "3C")],
        trouble=[], growing=[], complete=[],
    )
    result = classify_buckets(raw)
    result.helper.append("sentinel")
    assert "sentinel" not in raw.helper


def main():
    tests = [
        (name, fn) for name, fn in sorted(globals().items())
        if name.startswith("test_") and callable(fn)
    ]
    failed = 0
    for name, fn in tests:
        try:
            fn()
        except Exception as e:
            print(f"FAIL {name}: {type(e).__name__}: {e}")
            traceback.print_exc()
            failed += 1
    print()
    print(f"{len(tests) - failed}/{len(tests)} test functions passed")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
