"""
compare.py — outcome-based primitive-sequence comparator.

Applies both `expected` and `actual` primitive sequences to the
same initial state and compares the resulting boards + hands.
This dissolves every per-trick arbitrariness axis at once:
ordering, merge sides, loc choices, place_hand vs merge_hand
choices, etc. All roads that arrive at the same board are
equivalent.

Exposed:
    compare(expected, actual, initial_state) -> Report
"""

from strategy import (_apply_split, _apply_move, _apply_merge_stack,
                   _apply_merge_hand, _apply_place_hand,
                   _copy_board, _card_eq)


def _apply_primitive(board, prim):
    kind = prim.get("action")
    if kind == "split":
        return _apply_split(board, prim["stack_index"], prim["card_index"])
    if kind == "move_stack":
        return _apply_move(board, prim["stack_index"], prim["new_loc"])
    if kind == "merge_stack":
        return _apply_merge_stack(board, prim["source_stack"],
                                  prim["target_stack"], prim.get("side", "right"))
    if kind == "merge_hand":
        return _apply_merge_hand(board, prim["target_stack"],
                                 prim["hand_card"], prim.get("side", "right"))
    if kind == "place_hand":
        return _apply_place_hand(board, prim["hand_card"], prim["loc"])
    # complete_turn / undo not exercised by hint primitives.
    return board


def _run(primitives, initial_state):
    board = _copy_board(initial_state["board"])
    for p in primitives:
        board = _apply_primitive(board, p)
    return board


def _cards_in_stack(stack):
    return tuple(
        (bc["card"]["value"], bc["card"]["suit"], bc["card"]["origin_deck"])
        for bc in stack["board_cards"]
    )


def _board_signature(board):
    """Order-insensitive signature: the multiset of stack card
    lists. Locs are ignored entirely."""
    return sorted(_cards_in_stack(s) for s in board)


def compare(expected, actual, initial_state):
    """Outcome equivalence: apply both sequences to the given
    initial state; if the resulting boards have the same stack
    contents (order-insensitive, loc-irrelevant), they are
    EQUIVALENT. Otherwise DIFFERS, with a diff summary."""
    notes = []
    try:
        exp_board = _run(expected, initial_state)
        act_board = _run(actual, initial_state)
    except (IndexError, KeyError) as e:
        notes.append(f"simulation failed: {type(e).__name__}: {e}")
        return {"overall": "DIFFERS", "notes": notes}

    exp_sig = _board_signature(exp_board)
    act_sig = _board_signature(act_board)

    if exp_sig == act_sig:
        notes.append(
            f"outcomes match: {len(exp_sig)} stacks with identical cards"
        )
        return {"overall": "EQUIVALENT", "notes": notes}

    exp_only = [s for s in exp_sig if s not in act_sig]
    act_only = [s for s in act_sig if s not in exp_sig]
    if exp_only:
        notes.append(f"only in expected: {[_fmt_stack(s) for s in exp_only]}")
    if act_only:
        notes.append(f"only in actual:   {[_fmt_stack(s) for s in act_only]}")
    return {"overall": "DIFFERS", "notes": notes}


def _fmt_stack(cards):
    suits = "CDSH"
    vals = {1: "A", 10: "T", 11: "J", 12: "Q", 13: "K"}
    out = []
    for v, s, d in cards:
        vs = vals.get(v, str(v))
        out.append(f"{vs}{suits[s]}")
    return "[" + ",".join(out) + "]"
