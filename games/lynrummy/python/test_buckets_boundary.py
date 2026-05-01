"""test_buckets_boundary.py — Coverage for classify_buckets and the
state-level operations under CCS-shaped inputs.

`classify_buckets` is the boundary helper that converts raw `Buckets`
of card lists into `Buckets` of `ClassifiedCardStack` lists. Raises on
any invalid stack.

`state_sig`, `trouble_count`, `is_victory` continue to work when
buckets hold CCS rather than raw card lists — verified here via
container delegation (`__len__`, `__iter__`, `__getitem__`).
"""

import sys
import traceback

from rules.card import card

from buckets import (
    Buckets, classify_buckets,
    state_sig, trouble_count, is_victory,
)
from classified_card_stack import (
    KIND_RUN, KIND_RB, KIND_SET,
    KIND_PAIR_RUN, KIND_PAIR_SET,
    KIND_SINGLETON,
    classify_stack,
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


# --- CCS-shaped state operations (container delegation) -------------------

def _ccs(*labels):
    return classify_stack([card(lbl) for lbl in labels])


def test_trouble_count_handles_ccs_via_len_delegation():
    trouble = [_ccs("AC")]                                # len 1
    growing = [_ccs("QH", "KH"), _ccs("5S", "5D")]        # len 2 + 2
    assert trouble_count(trouble, growing) == 5


def test_trouble_count_zero_on_empty():
    assert trouble_count([], []) == 0


def test_is_victory_true_when_no_trouble_and_growing_all_len3():
    growing = [_ccs("AC", "2C", "3C"), _ccs("AD", "AS", "AH")]
    assert is_victory([], growing) is True


def test_is_victory_false_when_trouble_present():
    growing = [_ccs("AC", "2C", "3C")]
    trouble = [_ccs("KH")]
    assert is_victory(trouble, growing) is False


def test_is_victory_false_when_growing_under_3():
    growing = [_ccs("AC", "2C")]
    assert is_victory([], growing) is False


def test_is_victory_true_when_all_buckets_empty():
    assert is_victory([], []) is True


def test_state_sig_stable_for_ccs():
    helper = [_ccs("AC", "2C", "3C")]
    trouble = [_ccs("KH")]
    growing = []
    complete = []
    sig1 = state_sig(helper, trouble, growing, complete)
    sig2 = state_sig(helper, trouble, growing, complete)
    assert sig1 == sig2


def test_state_sig_invariant_under_stack_order():
    a = _ccs("AC", "2C", "3C")
    b = _ccs("5D", "6D", "7D")
    sig_ab = state_sig([a, b], [], [], [])
    sig_ba = state_sig([b, a], [], [], [])
    assert sig_ab == sig_ba


def test_state_sig_invariant_under_card_order_within_stack():
    # state_sig sorts the cards inside each stack via iter delegation.
    fwd = _ccs("AC", "2C", "3C")
    sig_fwd = state_sig([fwd], [], [], [])
    # CCS is immutable; build a different stack with same cards via
    # classify_stack on a permuted set order. (Sets allow reorder.)
    set_fwd = _ccs("AC", "AD", "AH")
    set_rev = _ccs("AH", "AD", "AC")
    assert state_sig([set_fwd], [], [], []) == state_sig([set_rev], [], [], [])


def test_state_sig_distinguishes_buckets_by_role():
    a = _ccs("AC", "2C", "3C")
    sig_helper = state_sig([a], [], [], [])
    sig_complete = state_sig([], [], [], [a])
    assert sig_helper != sig_complete


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
