"""test_classified_card_stack.py — Coverage for ClassifiedCardStack
data structure + the pure-function API.

Sections:
  - classify_stack: the rigorous classifier across all 7 kinds plus
    rejection paths
  - singleton: trivial constructor
  - remove_card: 1, 2, or 3-piece decomposition for every parent kind
  - insert_right / insert_left: legal and illegal extensions
  - concat: stack-to-stack concatenation
  - splice: in-place fragmentation with side='left' / 'right'
  - to_singletons: atomization
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
    classify_stack, singleton,
    remove_card, insert_right, insert_left, concat, splice, to_singletons,
)


def _stack(*labels):
    return tuple(card(lbl) for lbl in labels)


def _ccs(*labels):
    """Shortcut: build a CCS from labels via classify_stack."""
    s = classify_stack(_stack(*labels))
    assert s is not None, f"unexpected None classifying {labels}"
    return s


# --- classify_stack ----------------------------------------------------------

def test_classify_singleton():
    s = classify_stack(_stack("AC"))
    assert s.kind == KIND_SINGLETON
    assert len(s) == 1


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


def test_classify_set_3_cards():
    assert classify_stack(_stack("AC", "AD", "AH")).kind == KIND_SET


def test_classify_set_4_cards():
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


def test_classify_rb_swap_at_index_1_breaks_sameness():
    # Two reds in a row at the start — invalid rb.
    assert classify_stack(_stack("AD", "2H", "3C")) is None


# --- singleton --------------------------------------------------------------

def test_singleton_constructor():
    s = singleton(card("5H"))
    assert s.kind == KIND_SINGLETON
    assert len(s) == 1
    assert s.cards == (card("5H"),)


# --- remove_card: singleton -------------------------------------------------

def test_remove_card_from_singleton():
    s = singleton(card("AC"))
    pieces = remove_card(s, card("AC"))
    assert len(pieces) == 1
    assert pieces[0].kind == KIND_SINGLETON
    assert pieces[0].cards == (card("AC"),)


def test_remove_card_singleton_wrong_card_raises():
    s = singleton(card("AC"))
    try:
        remove_card(s, card("2D"))
    except ValueError:
        return
    raise AssertionError("expected ValueError")


# --- remove_card: pair_X ----------------------------------------------------

def test_remove_card_from_pair_run():
    s = _ccs("AC", "2C")
    pieces = remove_card(s, card("AC"))
    assert len(pieces) == 2
    assert pieces[0].cards == (card("AC"),)  # extracted
    assert pieces[0].kind == KIND_SINGLETON
    assert pieces[1].cards == (card("2C"),)
    assert pieces[1].kind == KIND_SINGLETON


def test_remove_card_from_pair_rb_other_position():
    s = _ccs("AC", "2D")
    pieces = remove_card(s, card("2D"))
    assert len(pieces) == 2
    assert pieces[0].cards == (card("2D"),)  # extracted
    assert pieces[1].cards == (card("AC"),)
    assert pieces[1].kind == KIND_SINGLETON


def test_remove_card_from_pair_set():
    s = _ccs("AC", "AH")
    pieces = remove_card(s, card("AC"))
    assert len(pieces) == 2
    assert pieces[0].cards == (card("AC"),)
    assert pieces[1].cards == (card("AH"),)
    assert pieces[1].kind == KIND_SINGLETON


# --- remove_card: run / rb (length 3+) --------------------------------------

def test_remove_card_run_left_end():
    s = _ccs("AC", "2C", "3C")
    pieces = remove_card(s, card("AC"))
    # extracted + right (length 2 → pair_run); no left half
    assert len(pieces) == 2
    assert pieces[0].cards == (card("AC"),)
    assert pieces[1].cards == _stack("2C", "3C")
    assert pieces[1].kind == KIND_PAIR_RUN


def test_remove_card_run_right_end():
    s = _ccs("AC", "2C", "3C")
    pieces = remove_card(s, card("3C"))
    assert len(pieces) == 2
    assert pieces[0].cards == (card("3C"),)
    assert pieces[1].cards == _stack("AC", "2C")
    assert pieces[1].kind == KIND_PAIR_RUN


def test_remove_card_run_middle_split_out():
    # Length-3 run, remove middle → both halves singletons.
    s = _ccs("AC", "2C", "3C")
    pieces = remove_card(s, card("2C"))
    assert len(pieces) == 3
    assert pieces[0].cards == (card("2C"),)
    assert pieces[1].cards == (card("AC"),)
    assert pieces[1].kind == KIND_SINGLETON
    assert pieces[2].cards == (card("3C"),)
    assert pieces[2].kind == KIND_SINGLETON


def test_remove_card_run_long_left_end_stays_run():
    # 4-card run, remove leftmost → suffix length 3 stays run.
    s = _ccs("AC", "2C", "3C", "4C")
    pieces = remove_card(s, card("AC"))
    assert len(pieces) == 2
    assert pieces[1].kind == KIND_RUN
    assert pieces[1].cards == _stack("2C", "3C", "4C")


def test_remove_card_run_long_yank_index_1():
    # 4-card run, remove index 1 → left=singleton AC, right=pair_run 3C4C.
    s = _ccs("AC", "2C", "3C", "4C")
    pieces = remove_card(s, card("2C"))
    assert len(pieces) == 3
    assert pieces[0].cards == (card("2C"),)
    assert pieces[1].cards == (card("AC"),)
    assert pieces[1].kind == KIND_SINGLETON
    assert pieces[2].cards == _stack("3C", "4C")
    assert pieces[2].kind == KIND_PAIR_RUN


def test_remove_card_run_pluck_two_runs():
    # 7-card run, remove index 3 → both halves length-3 runs.
    s = _ccs("AC", "2C", "3C", "4C", "5C", "6C", "7C")
    pieces = remove_card(s, card("4C"))
    assert len(pieces) == 3
    assert pieces[0].cards == (card("4C"),)
    assert pieces[1].kind == KIND_RUN
    assert pieces[1].cards == _stack("AC", "2C", "3C")
    assert pieces[2].kind == KIND_RUN
    assert pieces[2].cards == _stack("5C", "6C", "7C")


def test_remove_card_rb_run_left_end():
    s = _ccs("AC", "2D", "3C")
    pieces = remove_card(s, card("AC"))
    assert len(pieces) == 2
    assert pieces[1].kind == KIND_PAIR_RB
    assert pieces[1].cards == _stack("2D", "3C")


def test_remove_card_rb_run_middle_long():
    # 5-card rb, remove index 2 → left=pair_rb (length 2), right=pair_rb.
    s = _ccs("AC", "2D", "3C", "4D", "5C")
    pieces = remove_card(s, card("3C"))
    assert len(pieces) == 3
    assert pieces[1].kind == KIND_PAIR_RB
    assert pieces[2].kind == KIND_PAIR_RB


def test_remove_card_run_card_not_present_raises():
    s = _ccs("AC", "2C", "3C")
    try:
        remove_card(s, card("4C"))
    except ValueError:
        return
    raise AssertionError("expected ValueError")


# --- remove_card: set -------------------------------------------------------

def test_remove_card_set_3_to_pair_set():
    s = _ccs("AC", "AD", "AH")
    pieces = remove_card(s, card("AC"))
    assert len(pieces) == 2
    assert pieces[0].cards == (card("AC"),)
    assert pieces[1].kind == KIND_PAIR_SET
    assert pieces[1].cards == _stack("AD", "AH")


def test_remove_card_set_4_stays_set():
    s = _ccs("AC", "AD", "AS", "AH")
    pieces = remove_card(s, card("AS"))
    assert len(pieces) == 2
    assert pieces[0].cards == (card("AS"),)
    assert pieces[1].kind == KIND_SET
    assert pieces[1].cards == _stack("AC", "AD", "AH")


# --- insert_right / insert_left --------------------------------------------

def test_insert_right_singleton_to_pair_run():
    s = singleton(card("AC"))
    out = insert_right(s, card("2C"))
    assert out.kind == KIND_PAIR_RUN
    assert out.cards == _stack("AC", "2C")


def test_insert_right_singleton_to_pair_rb():
    s = singleton(card("AC"))
    out = insert_right(s, card("2D"))
    assert out.kind == KIND_PAIR_RB


def test_insert_right_singleton_to_pair_set():
    s = singleton(card("AC"))
    out = insert_right(s, card("AD"))
    assert out.kind == KIND_PAIR_SET


def test_insert_right_singleton_illegal():
    s = singleton(card("AC"))
    assert insert_right(s, card("5H")) is None


def test_insert_right_pair_run_to_run():
    s = _ccs("AC", "2C")
    out = insert_right(s, card("3C"))
    assert out.kind == KIND_RUN
    assert len(out) == 3


def test_insert_right_pair_run_wrong_suit():
    s = _ccs("AC", "2C")
    # 3D would break pure-run; cannot become rb mid-run either.
    assert insert_right(s, card("3D")) is None


def test_insert_right_run_extends():
    s = _ccs("AC", "2C", "3C")
    out = insert_right(s, card("4C"))
    assert out.kind == KIND_RUN
    assert len(out) == 4


def test_insert_left_singleton_to_pair_run():
    s = singleton(card("2C"))
    out = insert_left(s, card("AC"))
    assert out.kind == KIND_PAIR_RUN
    assert out.cards == _stack("AC", "2C")


def test_insert_left_run_extends():
    s = _ccs("2C", "3C", "4C")
    out = insert_left(s, card("AC"))
    assert out.kind == KIND_RUN
    assert len(out) == 4


def test_insert_left_pair_set_to_set():
    s = _ccs("AC", "AD")
    out = insert_left(s, card("AH"))
    assert out.kind == KIND_SET


# --- concat ----------------------------------------------------------------

def test_concat_run_pair_run_to_run():
    left = _ccs("AC", "2C", "3C")
    right = _ccs("4C", "5C")
    out = concat(left, right)
    assert out.kind == KIND_RUN
    assert len(out) == 5


def test_concat_pair_run_singleton_to_run():
    left = _ccs("AC", "2C")
    right = singleton(card("3C"))
    out = concat(left, right)
    assert out.kind == KIND_RUN


def test_concat_singletons_to_pair_set():
    left = singleton(card("AC"))
    right = singleton(card("AD"))
    out = concat(left, right)
    assert out.kind == KIND_PAIR_SET


def test_concat_illegal():
    left = _ccs("AC", "2C")
    right = _ccs("AD", "AH")
    assert concat(left, right) is None


# --- splice ----------------------------------------------------------------

def test_splice_pure_run_loose_breaks_suit():
    # Splicing a different-suit card into a pure_run can never
    # produce a legal pure_run half (third card would break suit
    # and rb requires alternation from card 0).
    s = _ccs("AC", "2C", "3C", "4C", "5C")
    assert splice(s, card("3D"), 2, "left") is None


def test_splice_rb_loose_value_not_consecutive():
    # rb_run [AC,2D,3C,4D] + loose 5H at position 2, side='left':
    # left = [AC,2D,5H] — values 1,2,5 not consecutive. None.
    s = _ccs("AC", "2D", "3C", "4D")
    assert splice(s, card("5H"), 2, "left") is None


def test_splice_rb_run_legal_left_side_to_pair_set_plus_rb():
    # rb_run [AC,2D,3C,4D] + loose AS at position 1, side='left':
    #   left = src[:1] + (AS,) = [AC, AS]            → pair_set
    #   right = src[1:] = [2D, 3C, 4D]               → rb
    s = _ccs("AC", "2D", "3C", "4D")
    out = splice(s, card("AS"), 1, "left")
    assert out is not None
    left_h, right_h = out
    assert left_h.kind == KIND_PAIR_SET
    assert left_h.cards == _stack("AC", "AS")
    assert right_h.kind == KIND_RB
    assert right_h.cards == _stack("2D", "3C", "4D")


def test_splice_rb_run_legal_right_side_to_rb_plus_pair_set():
    # rb_run [AC,2D,3C,4D] + loose 4S at position 3, side='right':
    #   left = src[:3] = [AC,2D,3C]                  → rb
    #   right = (4S,) + src[3:] = [4S, 4D]           → pair_set
    s = _ccs("AC", "2D", "3C", "4D")
    out = splice(s, card("4S"), 3, "right")
    assert out is not None
    left_h, right_h = out
    assert left_h.kind == KIND_RB
    assert left_h.cards == _stack("AC", "2D", "3C")
    assert right_h.kind == KIND_PAIR_SET
    assert right_h.cards == _stack("4S", "4D")


def test_splice_pure_run_legal_into_set_split():
    # pure_run [2C,3C,4C,5C] + loose 2H at position 1, side='left':
    #   left = [2C, 2H]              → pair_set
    #   right = [3C, 4C, 5C]         → run
    s = _ccs("2C", "3C", "4C", "5C")
    out = splice(s, card("2H"), 1, "left")
    assert out is not None
    left_h, right_h = out
    assert left_h.kind == KIND_PAIR_SET
    assert right_h.kind == KIND_RUN


def test_splice_at_end_position_right():
    # k = n with side='right': left = full stack, right = (loose,).
    # Both halves classify: left stays the original kind, right is
    # a singleton. (BFS only explores k in 1..n-1, but the function
    # handles edge positions cleanly.)
    s = _ccs("AC", "2C", "3C", "4C")
    out = splice(s, card("5C"), 4, "right")
    assert out is not None
    left_h, right_h = out
    assert left_h.kind == KIND_RUN
    assert left_h.cards == _stack("AC", "2C", "3C", "4C")
    assert right_h.kind == KIND_SINGLETON
    assert right_h.cards == (card("5C"),)


def test_splice_at_zero_position_right_gives_none():
    # k=0 side='right': left = empty (cards[:0]), invalid.
    s = _ccs("AC", "2C", "3C", "4C")
    assert splice(s, card("5C"), 0, "right") is None


def test_splice_invalid_side():
    s = _ccs("AC", "2C", "3C", "4C")
    try:
        splice(s, card("5C"), 2, "middle")
    except ValueError:
        return
    raise AssertionError("expected ValueError on bad side")


# --- to_singletons ----------------------------------------------------------

def test_to_singletons_set():
    s = _ccs("AC", "AD", "AH")
    pieces = to_singletons(s)
    assert len(pieces) == 3
    for p in pieces:
        assert p.kind == KIND_SINGLETON


def test_to_singletons_run():
    s = _ccs("AC", "2C", "3C", "4C")
    pieces = to_singletons(s)
    assert len(pieces) == 4
    for i, p in enumerate(pieces):
        assert p.kind == KIND_SINGLETON
        assert p.cards == (s.cards[i],)


def test_to_singletons_singleton_input():
    s = singleton(card("5H"))
    pieces = to_singletons(s)
    assert len(pieces) == 1


# --- Equality + hashing -----------------------------------------------------

def test_equality_by_value():
    a = _ccs("AC", "2C", "3C")
    b = _ccs("AC", "2C", "3C")
    assert a == b
    assert hash(a) == hash(b)


def test_inequality_by_kind_differs():
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
