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

import time

from geometry import (
    CARD_PITCH, CARD_HEIGHT,
    BOARD_MAX_WIDTH, BOARD_MAX_HEIGHT,
    BOARD_VIEWPORT_LEFT, BOARD_VIEWPORT_TOP,
)

# Canonical viewport. Large enough to contain the pinned board
# plus a generous hand area. Elm renders at these coords; Python
# generates paths in the same frame.
VIEWPORT = {
    "width": BOARD_VIEWPORT_LEFT + BOARD_MAX_WIDTH + 40,
    "height": BOARD_VIEWPORT_TOP + BOARD_MAX_HEIGHT + 100,
}

DEFAULT_SAMPLES = 12

# Drag velocity. Placeholder — Steve will measure real human
# velocity soon. Exaggerated slowness is acceptable for now.
DRAG_MS_PER_PIXEL = 80


def _distance(start, end):
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    return (dx * dx + dy * dy) ** 0.5


def synthesize(start, end, *, samples=DEFAULT_SAMPLES):
    """Build a gesture_metadata envelope with a straight-line
    path from `start` to `end`. `start` and `end` are `(x, y)`
    tuples in VIEWPORT pixel coordinates. Duration is proportional
    to distance at `DRAG_MS_PER_PIXEL` — the drag takes longer
    the farther it goes, matching human drag pacing."""
    duration_ms = max(100, _distance(start, end) * DRAG_MS_PER_PIXEL)
    t0_ms = time.time() * 1000
    if samples < 2:
        samples = 2
    # x/y are stored as ints in the Elm decoder. Round per-sample.
    path = []
    for i in range(samples):
        frac = i / (samples - 1)
        path.append({
            "t": t0_ms + frac * duration_ms,
            "x": round(start[0] + (end[0] - start[0]) * frac),
            "y": round(start[1] + (end[1] - start[1]) * frac),
        })
    return {
        "path": path,
        "pointer_type": "synthetic",
        "viewport": VIEWPORT,
        "device_pixel_ratio": 1.0,
    }


def _stack_viewport_rect(stack):
    """Translate a board stack's internal loc into viewport
    coords using the pinned board offset."""
    return (
        BOARD_VIEWPORT_LEFT + stack["loc"]["left"],
        BOARD_VIEWPORT_TOP + stack["loc"]["top"],
    )


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
        src = board_before[prim["stack_index"]]
        new_loc = prim["new_loc"]
        size = len(src["board_cards"])
        src_left, src_top = _stack_viewport_rect(src)
        start = (src_left + size * CARD_PITCH // 2,
                 src_top + CARD_HEIGHT // 2)
        end_left = BOARD_VIEWPORT_LEFT + new_loc["left"]
        end_top = BOARD_VIEWPORT_TOP + new_loc["top"]
        end = (end_left + size * CARD_PITCH // 2,
               end_top + CARD_HEIGHT // 2)
        return start, end

    # merge_hand / place_hand: hand origin unknowable to Python.
    # split / merge_stack: intra-board but we don't yet need paths
    # for them; add as downstream tricks surface the need.
    return None
