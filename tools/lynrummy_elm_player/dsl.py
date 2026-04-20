"""
dsl.py — render a primitive wire-action sequence in a compact,
intent-forward notation. Output-only; no parser yet.

Turns this:

    split           {"stack_index": 0, "card_index": 2}
    split           {"stack_index": 3, "card_index": 0}
    move_stack      {"stack_index": 3, "new_loc": {"top":144,"left":256}}
    merge_hand      {"hand_card": 5H, "target_stack": 4, "side": "left"}
    merge_hand      {"hand_card": 5S, "target_stack": 4, "side": "right"}

into this:

    split [3D,4D,5D,6D,7D]  →  [3D,4D] | [5D,6D,7D]
    split [5D,6D,7D]        →  [5D] | [6D,7D]
    move [5D] to (256,144)
    add 5H onto [5D]             (left)
    add 5S onto [5H,5D]          (right)

Cards render as "<VAL><SUIT>"; deck is appended only when a stack
contains the same face from both decks. All the simulation logic
lives in render_sequence — it walks the actions using the same
remove-and-reappend semantics the Go referee uses.
"""

from decompose import _apply_split, _apply_move_stack


# --- Card rendering ---

_VAL = {1: "A", 11: "J", 12: "Q", 13: "K", 10: "T"}
_SUIT = {0: "C", 1: "D", 2: "S", 3: "H"}


def _card_str(c, show_deck=False):
    v = _VAL.get(c["value"], str(c["value"]))
    s = _SUIT[c["suit"]]
    if show_deck:
        return f"{v}{s}/d{c['origin_deck']}"
    return f"{v}{s}"


def _stack_cards_str(stack):
    """Concatenated card labels — 3D4D5D. Each card is exactly 2
    chars (value + suit), so no separator is needed. Deck suffix
    is appended only when two cards in the same stack share a
    value+suit (double-deck collision)."""
    cards = [bc["card"] for bc in stack["board_cards"]]
    labels = [(c["value"], c["suit"]) for c in cards]
    dup = len(labels) != len(set(labels))
    return "".join(_card_str(c, show_deck=dup) for c in cards)


# --- Action renderers ---

def _render_split(action, board):
    stack_idx = action["stack_index"]
    card_idx = action["card_index"]
    after, left_i, right_i = _apply_split(board, stack_idx, card_idx)
    left_str = _stack_cards_str(after[left_i])
    right_str = _stack_cards_str(after[right_i])
    return f"Click-split {left_str}/{right_str}"


def _render_move_stack(action, board):
    stack_idx = action["stack_index"]
    cards = _stack_cards_str(board[stack_idx])
    return f"Drag {cards} -> open"


def _render_place_hand(action, board):
    card = _card_str(action["hand_card"])
    return f"Drag {card} -> open"


def _render_merge_hand(action, board):
    card = _card_str(action["hand_card"])
    target = _stack_cards_str(board[action["target_stack"]])
    return f"Drag {card} -> {target}"


def _render_merge_stack(action, board):
    source = _stack_cards_str(board[action["source_stack"]])
    target = _stack_cards_str(board[action["target_stack"]])
    return f"Drag {source} -> {target}"


def _render_complete_turn(action, board):
    return "complete-turn"


def _render_undo(action, board):
    return "undo"


_RENDERERS = {
    "split":         _render_split,
    "move_stack":    _render_move_stack,
    "place_hand":    _render_place_hand,
    "merge_hand":    _render_merge_hand,
    "merge_stack":   _render_merge_stack,
    "complete_turn": _render_complete_turn,
    "undo":          _render_undo,
}


# --- Sequence walker ---

def render_sequence(actions, initial_state):
    """Walk actions against a simulated board, render each to a DSL
    line. Returns a list of strings (one per action). When
    simulation fails mid-sequence (e.g., action targets a stale
    index), the remaining lines fall back to a raw JSON dump so
    nothing is silently hidden."""
    board = [dict(s) for s in initial_state["board"]]
    # Deep-copy board_cards list so mutations don't leak.
    board = [{"board_cards": list(s["board_cards"]), "loc": s["loc"]}
             for s in board]

    out = []
    for a in actions:
        kind = a["action"]
        r = _RENDERERS.get(kind)
        if r is None:
            out.append(f"(unknown action: {a})")
            continue
        try:
            out.append(r(a, board))
        except (IndexError, KeyError) as e:
            out.append(f"(render failed at {kind}: {e}) -- {a}")
            # Don't advance the simulated board — any further
            # actions are probably unalignable too.
            continue
        # Advance simulation for the next action.
        try:
            board = _advance(board, a)
        except (IndexError, KeyError, ValueError):
            # Stop simulating; subsequent lines will render without
            # accurate board context, which is usually still useful.
            pass
    return out


def _advance(board, action):
    """Apply `action` to the simulated board, using the same
    remove-and-reappend semantics as the Go referee."""
    kind = action["action"]
    if kind == "split":
        new_board, _l, _r = _apply_split(
            board, action["stack_index"], action["card_index"]
        )
        return new_board
    if kind == "move_stack":
        new_board, _ = _apply_move_stack(
            board, action["stack_index"], action["new_loc"]
        )
        return new_board
    if kind == "place_hand":
        new_stack = {
            "board_cards": [{"card": action["hand_card"], "state": 1}],
            "loc": action["loc"],
        }
        return board + [new_stack]
    if kind == "merge_hand":
        tgt_idx = action["target_stack"]
        target = board[tgt_idx]
        hc = {"card": action["hand_card"], "state": 0}
        if action.get("side") == "left":
            new_cards = [hc] + list(target["board_cards"])
        else:
            new_cards = list(target["board_cards"]) + [hc]
        merged = {"board_cards": new_cards, "loc": target["loc"]}
        return board[:tgt_idx] + board[tgt_idx + 1:] + [merged]
    if kind == "merge_stack":
        src_idx = action["source_stack"]
        tgt_idx = action["target_stack"]
        src = board[src_idx]
        tgt = board[tgt_idx]
        if action.get("side") == "left":
            new_cards = list(src["board_cards"]) + list(tgt["board_cards"])
        else:
            new_cards = list(tgt["board_cards"]) + list(src["board_cards"])
        merged = {"board_cards": new_cards, "loc": tgt["loc"]}
        # Remove both from board (order matters: remove larger index first).
        hi, lo = sorted((src_idx, tgt_idx), reverse=True)
        new_board = list(board)
        del new_board[hi]
        del new_board[lo]
        return new_board + [merged]
    # complete_turn / undo don't advance the *board* state in any
    # way we render here.
    return board
