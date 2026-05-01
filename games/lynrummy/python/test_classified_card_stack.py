"""test_classified_card_stack.py — Coverage for the probe + custom-
executor API on ClassifiedCardStack.

Sections:
  - classify_stack: rigorous classifier across all 7 kinds + rejection
  - singleton, to_singletons: trivial constructors / atomization
  - Source verbs: verb_for_position dispatch + can_X predicates +
    the five custom executors (peel / pluck / yank / steal / split_out)
  - Target absorb: kind_after_absorb_right/left probes + executors
  - Splice: kinds_after_splice probe + splice executor
  - Equality + hashing
"""

import sys
import traceback

from rules.card import card

from classified_card_stack import (
    ClassifiedCardStack,
    KIND_RUN, KIND_RB, KIND_SET,
    KIND_PAIR_RUN, KIND_PAIR_RB, KIND_PAIR_SET,
    KIND_SINGLETON,
    classify_stack, singleton, to_singletons,
    can_peel, can_pluck, can_yank, can_steal, can_split_out,
    verb_for_position,
    peel, pluck, yank, steal, split_out,
    kind_after_absorb_right, kind_after_absorb_left,
    absorb_right, absorb_left,
    kinds_after_splice, splice,
)


def _stack(*labels):
    return tuple(card(lbl) for lbl in labels)


def _ccs(*labels):
    s = classify_stack(_stack(*labels))
    assert s is not None, f"unexpected None classifying {labels}"
    return s


# --- classify_stack ---------------------------------------------------------

def test_classify_singleton():
    assert classify_stack(_stack("AC")).kind == KIND_SINGLETON


def test_classify_pair_run():
    assert classify_stack(_stack("AC", "2C")).kind == KIND_PAIR_RUN


def test_classify_pair_rb():
    assert classify_stack(_stack("AC", "2D")).kind == KIND_PAIR_RB


def test_classify_pair_set():
    assert classify_stack(_stack("AC", "AD")).kind == KIND_PAIR_SET


def test_classify_run():
    assert classify_stack(_stack("AC", "2C", "3C")).kind == KIND_RUN


def test_classify_run_long():
    assert classify_stack(_stack("9C", "TC", "JC", "QC", "KC")).kind == KIND_RUN


def test_classify_run_wraps_k_to_a():
    assert classify_stack(_stack("QC", "KC", "AC")).kind == KIND_RUN


def test_classify_rb():
    assert classify_stack(_stack("AC", "2D", "3C")).kind == KIND_RB


def test_classify_rb_long():
    assert classify_stack(_stack("AC", "2D", "3C", "4H")).kind == KIND_RB


def test_classify_set_3():
    assert classify_stack(_stack("AC", "AD", "AH")).kind == KIND_SET


def test_classify_set_4():
    assert classify_stack(_stack("AC", "AD", "AS", "AH")).kind == KIND_SET


def test_classify_invalid_disconnected_pair():
    assert classify_stack(_stack("AC", "4C")) is None


def test_classify_invalid_run_wrong_suit():
    assert classify_stack(_stack("AC", "2C", "3D")) is None


def test_classify_invalid_set_duplicate_suit():
    assert classify_stack(_stack("AC", "AC")) is None


def test_classify_invalid_set_with_runner():
    assert classify_stack(_stack("AC", "AD", "2C")) is None


def test_classify_empty_returns_none():
    assert classify_stack(_stack()) is None


def test_classify_rb_two_reds_in_row_invalid():
    assert classify_stack(_stack("AD", "2H", "3C")) is None


# --- singleton / to_singletons ----------------------------------------------

def test_singleton_builds_kind():
    s = singleton(card("5H"))
    assert s.kind == KIND_SINGLETON
    assert s.cards == (card("5H"),)


def test_to_singletons_set():
    s = _ccs("AC", "AD", "AH")
    pieces = to_singletons(s)
    assert len(pieces) == 3
    for p in pieces:
        assert p.kind == KIND_SINGLETON


def test_to_singletons_run():
    s = _ccs("AC", "2C", "3C", "4C")
    pieces = to_singletons(s)
    assert tuple(p.cards[0] for p in pieces) == s.cards


def test_to_singletons_singleton_is_self_in_tuple():
    s = singleton(card("5H"))
    pieces = to_singletons(s)
    assert len(pieces) == 1
    assert pieces[0] == s


# --- verb_for_position + per-verb predicates --------------------------------

def test_verb_for_position_run_endpoints_peel():
    s = _ccs("AC", "2C", "3C", "4C")
    assert verb_for_position(s, 0) == "peel"
    assert verb_for_position(s, 3) == "peel"


def test_verb_for_position_run_interior_yank():
    s = _ccs("AC", "2C", "3C", "4C")
    # Length 4: position 1 → left=1, right=2. max=2 < 3, so yank fails.
    # Need length 5 for yank to fire at position 1.
    s5 = _ccs("AC", "2C", "3C", "4C", "5C")
    assert verb_for_position(s5, 1) == "yank"
    assert verb_for_position(s5, 3) == "yank"


def test_verb_for_position_run_pluck():
    # n=7, ci=3 → both halves length 3. Pluck fires.
    s = _ccs("AC", "2C", "3C", "4C", "5C", "6C", "7C")
    assert verb_for_position(s, 3) == "pluck"


def test_verb_for_position_run_steal():
    s = _ccs("AC", "2C", "3C")
    assert verb_for_position(s, 0) == "steal"
    assert verb_for_position(s, 2) == "steal"


def test_verb_for_position_run_split_out():
    s = _ccs("AC", "2C", "3C")
    assert verb_for_position(s, 1) == "split_out"


def test_verb_for_position_set_peel_or_steal():
    s_set3 = _ccs("AC", "AD", "AH")
    # Length 3 set: steal at any position.
    assert verb_for_position(s_set3, 0) == "steal"
    assert verb_for_position(s_set3, 1) == "steal"
    assert verb_for_position(s_set3, 2) == "steal"

    s_set4 = _ccs("AC", "AD", "AS", "AH")
    # Length 4 set: peel at any position.
    assert verb_for_position(s_set4, 0) == "peel"
    assert verb_for_position(s_set4, 2) == "peel"


def test_verb_for_position_pair_run_no_verb():
    s = _ccs("AC", "2C")
    assert verb_for_position(s, 0) is None
    assert verb_for_position(s, 1) is None


def test_verb_for_position_singleton_no_verb():
    s = singleton(card("AC"))
    assert verb_for_position(s, 0) is None


# --- peel ------------------------------------------------------------------

def test_peel_run_left_n4_to_run():
    s = _ccs("AC", "2C", "3C", "4C")
    extracted, remnant = peel(s, 0)
    assert extracted.cards == (card("AC"),)
    assert remnant.kind == KIND_RUN
    assert remnant.cards == _stack("2C", "3C", "4C")


def test_peel_run_right_n4_to_run():
    s = _ccs("AC", "2C", "3C", "4C")
    extracted, remnant = peel(s, 3)
    assert extracted.cards == (card("4C"),)
    assert remnant.kind == KIND_RUN
    assert remnant.cards == _stack("AC", "2C", "3C")


def test_peel_rb_to_rb():
    s = _ccs("AC", "2D", "3C", "4D")
    extracted, remnant = peel(s, 0)
    assert remnant.kind == KIND_RB


def test_peel_set_4_to_set_3():
    s = _ccs("AC", "AD", "AS", "AH")
    extracted, remnant = peel(s, 1)  # drop AD
    assert extracted.cards == (card("AD"),)
    assert remnant.kind == KIND_SET
    assert remnant.cards == _stack("AC", "AS", "AH")


def test_peel_assert_fires_on_invalid():
    s = _ccs("AC", "2C", "3C")  # length 3 — peel needs length 4+
    try:
        peel(s, 0)
    except AssertionError:
        return
    raise AssertionError("expected AssertionError")


# --- pluck -----------------------------------------------------------------

def test_pluck_run_n7_to_two_runs():
    s = _ccs("AC", "2C", "3C", "4C", "5C", "6C", "7C")
    extracted, left, right = pluck(s, 3)
    assert extracted.cards == (card("4C"),)
    assert left.kind == KIND_RUN
    assert left.cards == _stack("AC", "2C", "3C")
    assert right.kind == KIND_RUN
    assert right.cards == _stack("5C", "6C", "7C")


def test_pluck_rb_n7_to_two_rbs():
    s = _ccs("AC", "2D", "3C", "4D", "5C", "6D", "7C")
    extracted, left, right = pluck(s, 3)
    assert left.kind == KIND_RB
    assert right.kind == KIND_RB


def test_pluck_assert_fires_on_short_run():
    s = _ccs("AC", "2C", "3C", "4C")  # length 4, pluck needs length 7+
    try:
        pluck(s, 1)
    except AssertionError:
        return
    raise AssertionError("expected AssertionError")


# --- yank ------------------------------------------------------------------

def test_yank_run_n5_left_singleton_pair_right():
    # Length 5 run, ci=1 → left=1 singleton, right=3 run.
    s = _ccs("AC", "2C", "3C", "4C", "5C")
    extracted, left, right = yank(s, 1)
    assert extracted.cards == (card("2C"),)
    assert left.kind == KIND_SINGLETON
    assert left.cards == (card("AC"),)
    assert right.kind == KIND_RUN
    assert right.cards == _stack("3C", "4C", "5C")


def test_yank_run_n5_right_singleton():
    # Length 5, ci=3 → left=3 run, right=1 singleton.
    s = _ccs("AC", "2C", "3C", "4C", "5C")
    extracted, left, right = yank(s, 3)
    assert left.kind == KIND_RUN
    assert right.kind == KIND_SINGLETON


def test_yank_rb_n5_at_position_2():
    # Length 5 rb, ci=2 → left=2 pair_rb, right=2 pair_rb.
    s = _ccs("AC", "2D", "3C", "4D", "5C")
    # can_yank: max(2,2)=2 < 3 → yank fails. Should be None verb.
    assert verb_for_position(s, 2) is None


def test_yank_rb_n6_to_singleton_and_run():
    # Length 6 rb, ci=4 → left=4 rb, right=1 singleton.
    s = _ccs("AC", "2D", "3C", "4D", "5C", "6D")
    extracted, left, right = yank(s, 4)
    assert left.kind == KIND_RB
    assert right.kind == KIND_SINGLETON


# --- steal -----------------------------------------------------------------

def test_steal_run_left_end_to_pair_run():
    s = _ccs("AC", "2C", "3C")
    extracted, remnant = steal(s, 0)
    assert extracted.cards == (card("AC"),)
    assert remnant.kind == KIND_PAIR_RUN
    assert remnant.cards == _stack("2C", "3C")


def test_steal_run_right_end_to_pair_run():
    s = _ccs("AC", "2C", "3C")
    extracted, remnant = steal(s, 2)
    assert remnant.kind == KIND_PAIR_RUN
    assert remnant.cards == _stack("AC", "2C")


def test_steal_rb_to_pair_rb():
    s = _ccs("AC", "2D", "3C")
    extracted, remnant = steal(s, 0)
    assert remnant.kind == KIND_PAIR_RB


def test_steal_set_atomizes_to_3_singletons():
    s = _ccs("AC", "AD", "AH")
    pieces = steal(s, 1)  # drop AD
    assert len(pieces) == 3
    assert pieces[0].cards == (card("AD"),)
    # Other two are singletons of AC and AH.
    rest = {p.cards[0] for p in pieces[1:]}
    assert rest == {card("AC"), card("AH")}
    for p in pieces:
        assert p.kind == KIND_SINGLETON


def test_steal_set_4_card_assert_fires():
    # Steal only fires on n=3.
    s = _ccs("AC", "AD", "AS", "AH")
    try:
        steal(s, 0)
    except AssertionError:
        return
    raise AssertionError("expected AssertionError")


# --- split_out -------------------------------------------------------------

def test_split_out_run_three_singletons():
    s = _ccs("AC", "2C", "3C")
    pieces = split_out(s, 1)
    assert len(pieces) == 3
    assert pieces[0].cards == (card("2C"),)
    assert pieces[1].cards == (card("AC"),)
    assert pieces[2].cards == (card("3C"),)
    for p in pieces:
        assert p.kind == KIND_SINGLETON


def test_split_out_rb_three_singletons():
    s = _ccs("AC", "2D", "3C")
    pieces = split_out(s, 1)
    assert len(pieces) == 3


def test_split_out_assert_fires_on_wrong_position():
    s = _ccs("AC", "2C", "3C")
    try:
        split_out(s, 0)  # only ci=1 is split_out
    except AssertionError:
        return
    raise AssertionError("expected AssertionError")


# --- kind_after_absorb_right ------------------------------------------------

def test_absorb_right_singleton_to_pair_run():
    s = singleton(card("AC"))
    assert kind_after_absorb_right(s, card("2C")) == KIND_PAIR_RUN


def test_absorb_right_singleton_to_pair_rb():
    s = singleton(card("AC"))
    assert kind_after_absorb_right(s, card("2D")) == KIND_PAIR_RB


def test_absorb_right_singleton_to_pair_set():
    s = singleton(card("AC"))
    assert kind_after_absorb_right(s, card("AD")) == KIND_PAIR_SET


def test_absorb_right_singleton_illegal():
    s = singleton(card("AC"))
    assert kind_after_absorb_right(s, card("5H")) is None


def test_absorb_right_pair_run_to_run():
    s = _ccs("AC", "2C")
    assert kind_after_absorb_right(s, card("3C")) == KIND_RUN


def test_absorb_right_pair_run_wrong_suit_none():
    s = _ccs("AC", "2C")
    # 3D would break pure-run; can't degrade to rb mid-stack.
    assert kind_after_absorb_right(s, card("3D")) is None


def test_absorb_right_pair_rb_to_rb():
    s = _ccs("AC", "2D")
    assert kind_after_absorb_right(s, card("3C")) == KIND_RB


def test_absorb_right_pair_set_to_set():
    s = _ccs("AC", "AD")
    assert kind_after_absorb_right(s, card("AH")) == KIND_SET


def test_absorb_right_pair_set_duplicate_suit_none():
    # Boundary AD → AC is OK (same value, distinct suit), but AC is
    # already in target. Cross-card check should reject.
    s = _ccs("AD", "AH")
    assert kind_after_absorb_right(s, card("AH")) is None  # boundary fails too
    # Make a more devious case:
    s2 = _ccs("AD", "AH")
    # Add AD — same value as last (AH), distinct suit (D vs H), but D
    # already in target. Should be None.
    assert kind_after_absorb_right(s2, card("AD")) is None


def test_absorb_right_run_extends_to_run():
    s = _ccs("AC", "2C", "3C")
    assert kind_after_absorb_right(s, card("4C")) == KIND_RUN


def test_absorb_right_set_max_4_overflow_none():
    # Length-4 set + another card would be 5, exceeding max set size.
    s = _ccs("AC", "AD", "AS", "AH")
    # No 5th value-1 suit exists in single deck, but with deck=1 we
    # can construct one.
    fifth = (1, 0, 1)  # AC:1
    assert kind_after_absorb_right(s, fifth) is None


# --- kind_after_absorb_left -------------------------------------------------

def test_absorb_left_singleton_to_pair_run():
    s = singleton(card("2C"))
    assert kind_after_absorb_left(s, card("AC")) == KIND_PAIR_RUN


def test_absorb_left_run_extends():
    s = _ccs("2C", "3C", "4C")
    assert kind_after_absorb_left(s, card("AC")) == KIND_RUN


def test_absorb_left_pair_set_to_set():
    s = _ccs("AC", "AD")
    assert kind_after_absorb_left(s, card("AH")) == KIND_SET


def test_absorb_left_pair_run_wrong_card_none():
    s = _ccs("2C", "3C")
    # Adding 4C on the left would need succ(4)=2, no.
    assert kind_after_absorb_left(s, card("4C")) is None


def test_absorb_left_pair_set_duplicate_suit_none():
    s = _ccs("AD", "AH")
    # Adding AD on the left: same value, but D already in target.
    assert kind_after_absorb_left(s, card("AD")) is None


# --- absorb_right / absorb_left executors ----------------------------------

def test_absorb_right_executor_builds_correctly():
    s = _ccs("AC", "2C")
    new_kind = kind_after_absorb_right(s, card("3C"))
    out = absorb_right(s, card("3C"), new_kind)
    assert out.kind == KIND_RUN
    assert out.cards == _stack("AC", "2C", "3C")


def test_absorb_left_executor_builds_correctly():
    s = _ccs("2C", "3C", "4C")
    new_kind = kind_after_absorb_left(s, card("AC"))
    out = absorb_left(s, card("AC"), new_kind)
    assert out.kind == KIND_RUN
    assert out.cards == _stack("AC", "2C", "3C", "4C")


# --- splice ----------------------------------------------------------------

def test_kinds_after_splice_pure_run_breaks_suit_none():
    s = _ccs("AC", "2C", "3C", "4C", "5C")
    assert kinds_after_splice(s, card("3D"), 2, "left") is None


def test_kinds_after_splice_rb_legal_set_partial_split():
    # rb_run [AC,2D,3C,4D] + AS at position 1, side='left':
    #   left  = [AC, AS]      → pair_set
    #   right = [2D, 3C, 4D]  → rb
    s = _ccs("AC", "2D", "3C", "4D")
    kinds = kinds_after_splice(s, card("AS"), 1, "left")
    assert kinds == (KIND_PAIR_SET, KIND_RB)


def test_kinds_after_splice_rb_legal_right_side():
    # rb_run [AC,2D,3C,4D] + 4S at position 3, side='right':
    #   left  = [AC, 2D, 3C]
    #   right = [4S, 4D]
    s = _ccs("AC", "2D", "3C", "4D")
    kinds = kinds_after_splice(s, card("4S"), 3, "right")
    assert kinds == (KIND_RB, KIND_PAIR_SET)


def test_kinds_after_splice_invalid_side_raises():
    s = _ccs("AC", "2C", "3C", "4C")
    try:
        kinds_after_splice(s, card("5C"), 2, "middle")
    except ValueError:
        return
    raise AssertionError("expected ValueError")


def test_splice_executor_builds_correctly():
    s = _ccs("AC", "2D", "3C", "4D")
    kinds = kinds_after_splice(s, card("AS"), 1, "left")
    assert kinds is not None
    left_kind, right_kind = kinds
    left, right = splice(s, card("AS"), 1, "left", left_kind, right_kind)
    assert left.kind == KIND_PAIR_SET
    assert left.cards == _stack("AC", "AS")
    assert right.kind == KIND_RB
    assert right.cards == _stack("2D", "3C", "4D")


def test_splice_zero_position_left_gives_singleton():
    # k=0, side='left': left = (card,) (just the card alone),
    # right = full stack. Both classify; the splice "acts like" a
    # left-prepend that fails to merge.
    s = _ccs("AC", "2C", "3C", "4C")
    kinds = kinds_after_splice(s, card("5C"), 0, "left")
    assert kinds == (KIND_SINGLETON, KIND_RUN)


def test_splice_run_parent_parity_with_classifier():
    """Cross-check the parent-kind shortcut against the rigorous
    classifier across many positions and insert cards. Any disagreement
    is a bug in the fast path."""
    from classified_card_stack import _classify_raw, _splice_halves
    parents = [
        _ccs("AC", "2C", "3C", "4C", "5C"),         # length-5 run
        _ccs("AC", "2D", "3C", "4D", "5C"),         # length-5 rb
        _ccs("AC", "2C", "3C", "4C", "5C", "6C"),   # length-6 run
        _ccs("9C", "TC", "JC", "QC", "KC"),         # length-5 run high
    ]
    insert_cards = [
        card("AC"), card("AD"), card("3C"), card("3D"),
        card("5S"), card("5H"), card("KC"), card("6C"), card("6D"),
    ]
    for parent in parents:
        n = parent.n
        for pos in range(0, n + 1):
            for c in insert_cards:
                if c in parent.cards:
                    continue
                for side in ("left", "right"):
                    fast = kinds_after_splice(parent, c, pos, side)
                    left_cards, right_cards = _splice_halves(
                        parent, c, pos, side)
                    expected_left = _classify_raw(left_cards)
                    expected_right = _classify_raw(right_cards)
                    if expected_left is None or expected_right is None:
                        assert fast is None, (
                            f"fast={fast} expected=None at parent={parent.cards} "
                            f"card={c} pos={pos} side={side}")
                    else:
                        assert fast == (expected_left, expected_right), (
                            f"fast={fast} expected="
                            f"{(expected_left, expected_right)} at "
                            f"parent={parent.cards} card={c} "
                            f"pos={pos} side={side}")


# --- Equality + hashing -----------------------------------------------------

def test_equality_by_value():
    a = _ccs("AC", "2C", "3C")
    b = _ccs("AC", "2C", "3C")
    assert a == b
    assert hash(a) == hash(b)


def test_inequality_by_kind():
    a = _ccs("AC", "2C")
    b = _ccs("AC", "2D")
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
