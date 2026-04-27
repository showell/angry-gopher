"""
geometry_plan.py — the unified geometry post-pass for the
agent's primitive emission.

Verbs (`verbs.py`) emit a logical primitive sequence that's
geometry-agnostic. `plan_actions` walks the sequence and
injects pre-flight `move_stack` primitives anywhere a
primitive would otherwise produce a board where two stacks
are within PACK_GAP of each other.

The agent's invariant: after every primitive applies, no two
stacks overlap (with PACK_GAP padding — the human-feel
threshold, stricter than the referee's legal margin). A human
player relocates crowded stacks BEFORE building on them; the
agent matches by injecting MoveStacks at the points where the
next primitive would otherwise produce a too-close result.

Mirrors `Game.Agent.GeometryPlan` (Elm) verbatim.
"""

import geometry
import primitives
import strategy

PACK_GAP = 30


def plan_actions(board, actions):
    """Walk a primitive sequence; inject MoveStack pre-flights
    where the next primitive would land the post-board in a
    too-close state. Returns the augmented sequence."""
    out = []
    sim = list(board)
    for action in actions:
        emitted, sim = _plan_one(sim, action)
        out.extend(emitted)
    return out


def _plan_one(sim, action):
    """Plan one primitive. If post-board's NEW stacks are
    pack-gap-clear from PRE-EXISTING stacks, emit as is.
    Otherwise try a pre-flight MoveStack of the perturbed
    stack to a clear loc and re-emit.

    The diff-based check (new vs pre-existing) is the right
    shape: a split's two halves are inherently close (+8px
    sibling offset) but that's not a violation since they
    came from the same parent. The check only flags when a
    primitive's output is too close to a stack that was
    already on the board."""
    post = primitives.apply_locally(sim, action)
    if _is_clean_after_action(sim, post):
        return [action], post
    pre_flight = _pre_flight(sim, action)
    if pre_flight is not None:
        move_prim, new_action, new_post = pre_flight
        return [move_prim, new_action], new_post
    return [action], post


def _pre_flight(sim, action):
    """Compute a pre-flight move for a primitive whose
    post-board would overlap. Returns (move, new_action,
    post-state) or None if no helpful pre-flight exists for
    this primitive shape."""
    kind = action["action"]
    if kind == "split":
        return _pre_flight_split(sim, action)
    if kind == "merge_stack":
        return _pre_flight_merge_stack(sim, action)
    return None


def _pre_flight_split(sim, action):
    """Move the source stack to a pack-gap-cleared loc with
    room for its full size, then re-emit the split. The
    post-split spawn lands within the source's relocated
    footprint."""
    si = action["stack_index"]
    src = sim[si]
    source_size = len(src["board_cards"])
    others = [s for i, s in enumerate(sim) if i != si]
    new_loc = geometry.find_open_loc(others, card_count=source_size)
    if new_loc == src["loc"]:
        return None
    move = {"action": "move_stack",
            "stack_index": si, "new_loc": new_loc}
    after_move = primitives.apply_locally(sim, move)
    # The relocated source keeps its content; the index may
    # change. Find by content.
    src_content = primitives.cards_of(src)
    new_si = primitives.find_stack_index(after_move, src_content)
    new_split = {"action": "split",
                 "stack_index": new_si,
                 "card_index": action["card_index"]}
    after_split = primitives.apply_locally(after_move, new_split)
    return move, new_split, after_split


def _pre_flight_merge_stack(sim, action):
    """Move the merge target to a pack-gap-cleared loc that
    fits the augmented (source+target) stack, then re-emit
    the merge."""
    src_si = action["source_stack"]
    tgt_si = action["target_stack"]
    src = sim[src_si]
    tgt = sim[tgt_si]
    source_size = len(src["board_cards"])
    target_size = len(tgt["board_cards"])
    final_size = source_size + target_size
    others = [s for i, s in enumerate(sim) if i not in (src_si, tgt_si)]
    final_loc = geometry.find_open_loc(others, card_count=final_size)
    side = action.get("side", "right")
    if side == "left":
        target_loc = {
            "left": final_loc["left"] + source_size * geometry.CARD_PITCH,
            "top": final_loc["top"],
        }
    else:
        target_loc = final_loc
    if target_loc == tgt["loc"]:
        return None
    move = {"action": "move_stack",
            "stack_index": tgt_si, "new_loc": target_loc}
    after_move = primitives.apply_locally(sim, move)
    src_content = primitives.cards_of(src)
    tgt_content = primitives.cards_of(tgt)
    new_src_si = primitives.find_stack_index(after_move, src_content)
    new_tgt_si = primitives.find_stack_index(after_move, tgt_content)
    new_merge = {"action": "merge_stack",
                 "source_stack": new_src_si,
                 "target_stack": new_tgt_si,
                 "side": side}
    after_merge = primitives.apply_locally(after_move, new_merge)
    return move, new_merge, after_merge


def _is_clean_after_action(pre_board, post_board):
    """Diff-based pack-gap check: new stacks (in post-board
    but not pre-board) must be pack-gap-clear from pre-existing
    stacks (stacks that survived from pre-board to post-board).
    New-vs-new pairs (split siblings) are exempt — they're
    inherently close by the +8px split offset, but that's not
    a primitive emitting an overlap with the rest of the
    board, so we don't flag it.

    Out-of-bounds check applies to all stacks unconditionally.
    """
    pre_keys = {_stack_key(s) for s in pre_board}
    pre_existing = [s for s in post_board if _stack_key(s) in pre_keys]
    new_stacks = [s for s in post_board if _stack_key(s) not in pre_keys]

    for s in post_board:
        l, t, r, b = geometry.stack_rect(s)
        if (l < 0 or t < 0 or
                r > geometry.BOARD_MAX_WIDTH or
                b > geometry.BOARD_MAX_HEIGHT):
            return False

    for new in new_stacks:
        new_padded = geometry.pad_rect(
            geometry.stack_rect(new), PACK_GAP)
        for old in pre_existing:
            if geometry.rects_overlap(
                    new_padded, geometry.stack_rect(old)):
                return False
    return True


def _stack_key(s):
    """Identity for diffing pre/post boards. Stacks are
    identified by content + loc so that a stack moved to a
    new loc reads as 'new' and the original as 'removed'."""
    cards = tuple(
        (bc["card"]["value"], bc["card"]["suit"],
         bc["card"]["origin_deck"])
        for bc in s["board_cards"])
    return (s["loc"]["top"], s["loc"]["left"], cards)
