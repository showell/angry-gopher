"""
primitives.py — the PRIMITIVE → GESTURE layer.

Pipeline: VERBs → PRIMITIVEs → GESTUREs.
- VERBs live in `verbs.py` and `bfs_solver.py` (DSL output).
- PRIMITIVEs are atomic UI ops: split, merge_stack, merge_hand,
  move_stack, place_hand. Internal shape uses index-based stack
  refs.
- GESTUREs are wire format (CardStack-ref) plus drag-path metadata.

This module is the canonical home for primitive utilities. Any
caller sending primitives to the server should import from here
rather than copy-pasting `_to_wire_shape` / `_apply_locally` /
`_send_one` (the historical drift).
"""

import gesture_synth
import strategy


def to_wire_shape(prim, board):
    """Translate an internal index-based primitive to the
    CardStack-ref wire shape the server expects. strategy.py and
    `apply_locally` keep using the index shape; translation is
    localized to the send boundary."""
    kind = prim["action"]
    if kind == "split":
        return {
            "action": "split",
            "stack": board[prim["stack_index"]],
            "card_index": prim["card_index"],
        }
    if kind == "merge_stack":
        return {
            "action": "merge_stack",
            "source": board[prim["source_stack"]],
            "target": board[prim["target_stack"]],
            "side": prim.get("side", "right"),
        }
    if kind == "merge_hand":
        return {
            "action": "merge_hand",
            "hand_card": prim["hand_card"],
            "target": board[prim["target_stack"]],
            "side": prim.get("side", "right"),
        }
    if kind == "move_stack":
        return {
            "action": "move_stack",
            "stack": board[prim["stack_index"]],
            "new_loc": prim["new_loc"],
        }
    return prim


def apply_locally(board, prim):
    """Mirror of what the server does to a board on receiving
    this primitive. Lets gesture synthesis see the correct
    pre-primitive state for the NEXT primitive in the same
    trick without a /state round-trip."""
    kind = prim["action"]
    if kind == "merge_hand":
        return strategy._apply_merge_hand(
            board, prim["target_stack"], prim["hand_card"],
            prim.get("side", "right"))
    if kind == "merge_stack":
        return strategy._apply_merge_stack(
            board, prim["source_stack"], prim["target_stack"],
            prim.get("side", "right"))
    if kind == "move_stack":
        return strategy._apply_move(
            board, prim["stack_index"], prim["new_loc"])
    if kind == "split":
        return strategy._apply_split(
            board, prim["stack_index"], prim["card_index"])
    if kind == "place_hand":
        return strategy._apply_place_hand(
            board, prim["hand_card"], prim["loc"])
    return board


def send_one(client, session_id, prim, board, *, verbose=False):
    """Synthesize gesture metadata, translate to wire shape, POST
    the primitive, advance the local board. Returns the new
    board, or None on send error."""
    endpoints = gesture_synth.drag_endpoints(prim, board)
    meta = (gesture_synth.synthesize(*endpoints)
            if endpoints is not None else None)
    wire = to_wire_shape(prim, board)
    try:
        client.send_action(session_id, wire, gesture_metadata=meta)
    except RuntimeError as e:
        if verbose:
            print(f"  send failed: {e}")
        return None
    if verbose:
        kind = prim["action"]
        path_ct = len(meta["path"]) if meta and "path" in meta else 0
        print(f"  sent {kind} (gesture={path_ct} samples)")
    return apply_locally(board, prim)


def cards_of(stack):
    """Tuple-list of (value, suit, deck) for a wire-shape stack
    dict. Inverse of to_wire_shape's perspective on a stack."""
    return [(bc["card"]["value"], bc["card"]["suit"],
             bc["card"]["origin_deck"])
            for bc in stack["board_cards"]]


def find_stack_index(board, cards):
    """Index of the stack on `board` whose content matches the
    `cards` tuple-list exactly. Raises ValueError if absent."""
    target = list(cards)
    for i, s in enumerate(board):
        if cards_of(s) == target:
            return i
    raise ValueError(f"stack {target} not found on board")
