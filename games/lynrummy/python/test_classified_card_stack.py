"""test_classified_card_stack.py — Coverage for ClassifiedCardStack.

Tests group by capability: the from_raw classifier, slicing
operations (peel/split/drop), and extension operations
(append_right / append_left).
"""

import sys
import traceback

from rules.card import card

from classified_card_stack import (
    ClassifiedCardStack,
    KIND_RUN, KIND_RB, KIND_SET,
    KIND_PAIR_RUN, KIND_PAIR_RB, KIND_PAIR_SET,
    KIND_SINGLETON,
)


def _stack(*labels):
    return tuple(card(lbl) for lbl in labels)


# --- from_raw classification --------------------------------------------------

def test_from_raw_singleton():
    s = ClassifiedCardStack.from_raw(_stack("AC"))
    assert s.kind == KIND_SINGLETON
    assert len(s) == 1


def test_from_raw_pair_run():
    s = ClassifiedCardStack.from_raw(_stack("AC", "2C"))
    assert s.kind == KIND_PAIR_RUN


def test_from_raw_pair_rb():
    s = ClassifiedCardStack.from_raw(_stack("AC", "2D"))
    assert s.kind == KIND_PAIR_RB


def test_from_raw_pair_set():
    s = ClassifiedCardStack.from_raw(_stack("AC", "AD"))
    assert s.kind == KIND_PAIR_SET


def test_from_raw_run():
    s = ClassifiedCardStack.from_raw(_stack("AC", "2C", "3C"))
    assert s.kind == KIND_RUN


def test_from_raw_run_long():
    s = ClassifiedCardStack.from_raw(_stack("9C", "TC", "JC", "QC", "KC"))
    assert s.kind == KIND_RUN


def test_from_raw_run_wraps_k_to_a():
    s = ClassifiedCardStack.from_raw(_stack("QC", "KC", "AC"))
    assert s.kind == KIND_RUN


def test_from_raw_rb():
    s = ClassifiedCardStack.from_raw(_stack("AC", "2D", "3C"))
    assert s.kind == KIND_RB


def test_from_raw_rb_long():
    s = ClassifiedCardStack.from_raw(_stack("AC", "2D", "3C", "4H"))
    assert s.kind == KIND_RB


def test_from_raw_set():
    s = ClassifiedCardStack.from_raw(_stack("AC", "AD", "AH"))
    assert s.kind == KIND_SET


def test_from_raw_set_4cards():
    s = ClassifiedCardStack.from_raw(_stack("AC", "AD", "AS", "AH"))
    assert s.kind == KIND_SET


def test_from_raw_invalid_pair_disconnected():
    # AC and 4C — not consecutive, not same value.
    try:
        ClassifiedCardStack.from_raw(_stack("AC", "4C"))
    except ValueError:
        return
    raise AssertionError("expected ValueError")


def test_from_raw_invalid_run_wrong_suit():
    # AC, 2C, 3D — third card breaks pure-run; not rb either
    # (start same suit, can't switch to rb mid-run).
    try:
        ClassifiedCardStack.from_raw(_stack("AC", "2C", "3D"))
    except ValueError:
        return
    raise AssertionError("expected ValueError")


def test_from_raw_invalid_set_duplicate_suit():
    try:
        ClassifiedCardStack.from_raw(_stack("AC", "AC"))
    except ValueError:
        return
    raise AssertionError("expected ValueError")


def test_from_raw_invalid_set_with_runner():
    try:
        ClassifiedCardStack.from_raw(_stack("AC", "AD", "2C"))
    except ValueError:
        return
    raise AssertionError("expected ValueError")


def test_from_raw_empty_invalid():
    try:
        ClassifiedCardStack.from_raw(_stack())
    except ValueError:
        return
    raise AssertionError("expected ValueError")


# --- Slicing: peel ------------------------------------------------------------

def test_peel_first_run_to_pair_run():
    parent = ClassifiedCardStack.from_raw(_stack("AC", "2C", "3C"))
    s = parent.peel_first()
    assert s.cards == _stack("2C", "3C")
    assert s.kind == KIND_PAIR_RUN


def test_peel_last_run_to_pair_run():
    parent = ClassifiedCardStack.from_raw(_stack("AC", "2C", "3C"))
    s = parent.peel_last()
    assert s.cards == _stack("AC", "2C")
    assert s.kind == KIND_PAIR_RUN


def test_peel_first_run_long_stays_run():
    parent = ClassifiedCardStack.from_raw(_stack("AC", "2C", "3C", "4C"))
    s = parent.peel_first()
    assert s.kind == KIND_RUN
    assert len(s) == 3


def test_peel_first_rb_to_pair_rb():
    parent = ClassifiedCardStack.from_raw(_stack("AC", "2D", "3C"))
    s = parent.peel_first()
    assert s.cards == _stack("2D", "3C")
    assert s.kind == KIND_PAIR_RB


def test_peel_last_set_to_pair_set():
    parent = ClassifiedCardStack.from_raw(_stack("AC", "AD", "AH"))
    s = parent.peel_last()
    assert s.kind == KIND_PAIR_SET


def test_peel_pair_to_singleton():
    parent = ClassifiedCardStack.from_raw(_stack("AC", "2C"))
    s = parent.peel_first()
    assert s.kind == KIND_SINGLETON
    assert s.cards == _stack("2C")


# --- Slicing: split_at --------------------------------------------------------

def test_split_at_run_middle_yank():
    # 6-card pure run, yank index 3. Left=length-3 run,
    # right=length-2 pair_run.
    parent = ClassifiedCardStack.from_raw(
        _stack("AC", "2C", "3C", "4C", "5C", "6C"))
    left, right = parent.split_at(3)
    assert left.kind == KIND_RUN
    assert left.cards == _stack("AC", "2C", "3C")
    assert right.kind == KIND_PAIR_RUN
    assert right.cards == _stack("5C", "6C")


def test_split_at_run_pluck_two_runs():
    # 7-card pure run, pluck index 3. Both halves are length-3 runs.
    parent = ClassifiedCardStack.from_raw(
        _stack("AC", "2C", "3C", "4C", "5C", "6C", "7C"))
    left, right = parent.split_at(3)
    assert left.kind == KIND_RUN
    assert left.cards == _stack("AC", "2C", "3C")
    assert right.kind == KIND_RUN
    assert right.cards == _stack("5C", "6C", "7C")


def test_split_at_run_split_out_singletons():
    # Length-3 pure run, split_out at index 1: both halves are
    # singletons.
    parent = ClassifiedCardStack.from_raw(_stack("AC", "2C", "3C"))
    left, right = parent.split_at(1)
    assert left.kind == KIND_SINGLETON
    assert right.kind == KIND_SINGLETON


def test_split_at_rb_yank():
    # Length-4 rb, yank index 1: left=length-1 (singleton),
    # right=length-2 (pair_rb).
    parent = ClassifiedCardStack.from_raw(_stack("AC", "2D", "3C", "4D"))
    left, right = parent.split_at(1)
    assert left.kind == KIND_SINGLETON
    assert right.kind == KIND_PAIR_RB


# --- Slicing: drop_card_at on sets -------------------------------------------

def test_drop_card_at_set_4_to_set_3():
    parent = ClassifiedCardStack.from_raw(_stack("AC", "AD", "AS", "AH"))
    s = parent.drop_card_at(2)
    assert s.kind == KIND_SET
    assert len(s) == 3


def test_drop_card_at_set_3_to_pair_set():
    parent = ClassifiedCardStack.from_raw(_stack("AC", "AD", "AH"))
    s = parent.drop_card_at(0)
    assert s.kind == KIND_PAIR_SET
    assert len(s) == 2


def test_drop_card_at_rejects_run():
    parent = ClassifiedCardStack.from_raw(_stack("AC", "2C", "3C"))
    try:
        parent.drop_card_at(1)
    except ValueError:
        return
    raise AssertionError("expected ValueError on run drop_card_at")


# --- Extension: append_right / append_left -----------------------------------

def test_append_right_singleton_to_pair_run():
    s = ClassifiedCardStack.singleton(card("AC"))
    out = s.append_right(card("2C"))
    assert out is not None
    assert out.kind == KIND_PAIR_RUN


def test_append_right_singleton_to_pair_rb():
    s = ClassifiedCardStack.singleton(card("AC"))
    out = s.append_right(card("2D"))
    assert out.kind == KIND_PAIR_RB


def test_append_right_singleton_to_pair_set():
    s = ClassifiedCardStack.singleton(card("AC"))
    out = s.append_right(card("AD"))
    assert out.kind == KIND_PAIR_SET


def test_append_right_singleton_invalid():
    s = ClassifiedCardStack.singleton(card("AC"))
    out = s.append_right(card("5H"))  # not adjacent, not same value
    assert out is None


def test_append_right_pair_run_to_run():
    s = ClassifiedCardStack.from_raw(_stack("AC", "2C"))
    out = s.append_right(card("3C"))
    assert out.kind == KIND_RUN


def test_append_right_pair_run_invalid_suit():
    s = ClassifiedCardStack.from_raw(_stack("AC", "2C"))
    # 3D would break pure-run AND can't make rb (already same-suit).
    out = s.append_right(card("3D"))
    assert out is None


def test_append_right_pair_rb_to_rb():
    s = ClassifiedCardStack.from_raw(_stack("AC", "2D"))
    out = s.append_right(card("3C"))
    assert out.kind == KIND_RB


def test_append_right_pair_set_to_set():
    s = ClassifiedCardStack.from_raw(_stack("AC", "AD"))
    out = s.append_right(card("AH"))
    assert out.kind == KIND_SET


def test_append_right_run_extends():
    s = ClassifiedCardStack.from_raw(_stack("AC", "2C", "3C"))
    out = s.append_right(card("4C"))
    assert out.kind == KIND_RUN
    assert len(out) == 4


def test_append_left_singleton_to_pair_run():
    s = ClassifiedCardStack.singleton(card("2C"))
    out = s.append_left(card("AC"))
    assert out.kind == KIND_PAIR_RUN
    assert out.cards == _stack("AC", "2C")


def test_append_left_run_extends():
    s = ClassifiedCardStack.from_raw(_stack("2C", "3C", "4C"))
    out = s.append_left(card("AC"))
    assert out.kind == KIND_RUN
    assert len(out) == 4


# --- Equality + hashing ------------------------------------------------------

def test_equality_by_value():
    a = ClassifiedCardStack.from_raw(_stack("AC", "2C", "3C"))
    b = ClassifiedCardStack.from_raw(_stack("AC", "2C", "3C"))
    assert a == b
    assert hash(a) == hash(b)


def test_inequality_by_kind_differs():
    a = ClassifiedCardStack.from_raw(_stack("AC", "2C"))
    b = ClassifiedCardStack.from_raw(_stack("AC", "2D"))
    assert a != b


# --- Runner ------------------------------------------------------------------

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
