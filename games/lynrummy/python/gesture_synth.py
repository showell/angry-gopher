"""
gesture_synth — build a pointer-path envelope for a Python-
originated primitive, in viewport coordinates that Elm can
honor at replay time.

**Rule:** Python only synthesizes a path for primitives whose
endpoints Python actually KNOWS in viewport coords. That means
intra-board moves (source and target both pinned by the
shared board geometry). Hand origins aren't pinned — they live
in Elm's DOM — so Python doesn't speculate about them. For
hand-originated actions (merge_hand, place_hand), Python
returns None and Elm synthesizes at replay time from its own
DOM knowledge.

This follows the "record facts, decide later" principle: don't
put speculative coordinates on the wire.

## Usage

    from gesture_synth import synthesize, drag_endpoints
    endpoints = drag_endpoints(primitive, board_before)
    if endpoints is not None:
        meta = synthesize(*endpoints)
        client.send_action(session_id, primitive, gesture_metadata=meta)
    else:
        client.send_action(session_id, primitive)
"""

import math
import time

from geometry import CARD_PITCH, CARD_HEIGHT

DEFAULT_SAMPLES = 20

# Drag velocity, ms per pixel. Tuned by feel 2026-04-21 (from
# 80 → 15 → 5). 5 reads well when watching an agent game
# replay — the perceived pace is the target, not a measurement
# of real human mouse speed. Kept in sync with Elm's
# `dragMsPerPixel` in `Main/Replay/Space.elm`.
DRAG_MS_PER_PIXEL = 5


def _distance(start, end):
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    return (dx * dx + dy * dy) ** 0.5


def _ease_in_out(frac):
    """Quintic smootherstep: 6f⁵ − 15f⁴ + 10f³. Peak derivative
    1.875 at f=0.5 (vs cosine's π/2 ≈ 1.57), zero derivative at
    both ends AND zero second derivative there. Result: a more
    pronounced plateau at start/end and a quicker rush through
    the middle than cosine. Endpoints still land exactly (f(0)=0,
    f(1)=1) so tests that check first/last sample still pass."""
    f3 = frac * frac * frac
    return f3 * (frac * (frac * 6 - 15) + 10)


def synthesize(start, end, *, samples=DEFAULT_SAMPLES, path_frame="board",
               ms_per_pixel=None):
    """Build a gesture_metadata envelope with an ease-in-ease-out
    path from `start` to `end`. `start` and `end` are `(x, y)`
    tuples in the coordinate frame named by `path_frame`:

      - `"board"` — board-frame coords, origin at the board's
        top-left. Use for intra-board drags.
      - `"viewport"` — viewport-frame coords. Only valid for
        drags that CROSS the board widget boundary (hand→board).
        Python doesn't emit this frame today; Python only
        synthesizes intra-board drags.

    Duration is proportional to distance at `DRAG_MS_PER_PIXEL`.
    Samples are emitted at uniform time intervals with eased
    position (slow start, peak velocity at the midpoint, slow
    end). Elm linearly interpolates between samples at replay
    time; 20 samples is enough for the curve to read smoothly
    through the fast middle."""
    pace = ms_per_pixel if ms_per_pixel is not None else DRAG_MS_PER_PIXEL
    duration_ms = max(100, _distance(start, end) * pace)
    t0_ms = time.time() * 1000
    if samples < 2:
        samples = 2
    path = []
    for i in range(samples):
        frac = i / (samples - 1)
        pos = _ease_in_out(frac)
        path.append({
            "t": t0_ms + frac * duration_ms,
            "x": round(start[0] + (end[0] - start[0]) * pos),
            "y": round(start[1] + (end[1] - start[1]) * pos),
        })
    return {
        "path": path,
        "path_frame": path_frame,
        "pointer_type": "synthetic",
    }


def _stack_center(stack):
    """Board-frame point at the center of a stack's bounding
    box. The "grab anywhere on the stack" start point for drags
    that pick up a whole stack."""
    size = len(stack["board_cards"])
    return (stack["loc"]["left"] + size * CARD_PITCH // 2,
            stack["loc"]["top"] + CARD_HEIGHT // 2)


def _stack_edge(stack, side):
    """Board-frame point at a stack's left- or right-edge,
    vertically centered. The drop-target point for actions that
    merge onto a stack's side."""
    size = len(stack["board_cards"])
    edge_x = stack["loc"]["left"] + (size * CARD_PITCH if side == "right" else 0)
    return (edge_x, stack["loc"]["top"] + CARD_HEIGHT // 2)


def drag_endpoints(prim, board_before):
    """Compute `(start, end)` viewport coords for a primitive's
    drag, or None if Python can't honestly supply them.

    Hand-origin actions (merge_hand, place_hand) return None:
    Python doesn't know where hand cards sit in the viewport.
    Elm synthesizes those at replay time from its own DOM
    knowledge. Don't speculate here.

    Intra-board actions have pinned endpoints on both sides,
    so Python can emit a faithful path in shared viewport
    coords.
    """
    kind = prim["action"]

    if kind == "move_stack":
        src_idx = prim["stack_index"]
        if src_idx >= len(board_before):
            return None
        src = board_before[src_idx]
        new_loc = prim["new_loc"]
        size = len(src["board_cards"])
        start = _stack_center(src)
        end = (new_loc["left"] + size * CARD_PITCH // 2,
               new_loc["top"] + CARD_HEIGHT // 2)
        return start, end

    if kind == "merge_stack":
        src_idx = prim["source_stack"]
        tgt_idx = prim["target_stack"]
        if src_idx >= len(board_before) or tgt_idx >= len(board_before):
            return None
        src = board_before[src_idx]
        tgt = board_before[tgt_idx]
        side = prim.get("side", "right")
        start = _stack_center(src)
        end = _stack_edge(tgt, side)
        return start, end

    # merge_hand / place_hand: hand origin unknowable to Python.
    # split: intra-board but the wire carries no target loc;
    # add when Split synthesis policy is decided.
    return None
