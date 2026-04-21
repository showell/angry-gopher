"""
gesture_synth — build a plausible pointer-path envelope for a
Python-originated primitive.

The Elm client captures real mouse telemetry for every drag and
posts it alongside the WireAction. Python primitives carry no
physical telemetry by default — so the Instant Replay sees a
teleport. This module fills that gap by synthesizing a
straight-line drag with timing samples, enough to render as
visible motion.

Not behavior-accurate: Python has no DOM, no real pointer
events. The goal is *pseudo-realistic* — a replay watcher sees
a stack move along a path rather than jumping.

## Usage

    from gesture_synth import synthesize, drag_endpoints
    start, end = drag_endpoints(primitive, board_before)
    meta = synthesize(start, end)
    client.send_action(session_id, primitive, gesture_metadata=meta)
"""

import time

from geometry import CARD_PITCH, CARD_HEIGHT, BOARD_MAX_WIDTH, BOARD_MAX_HEIGHT

# Approximate viewport. The Elm app sizes itself to the parent;
# these values match the board-area bounds plus the hand area
# below, which is roughly one card row deep per suit.
VIEWPORT = {"width": BOARD_MAX_WIDTH, "height": BOARD_MAX_HEIGHT + 240}

# Approximate hand-card "home" zone. Hand cards are rendered in
# a flow layout below the board — a real drag originates from
# whichever card the human picked up. Python doesn't track per-
# card screen positions; we use a single fixed point near the
# center of the hand area as the synthetic origin. Good enough
# for "you see a drag starting from the hand region."
HAND_ORIGIN_X = 300
HAND_ORIGIN_Y = BOARD_MAX_HEIGHT + 100

DEFAULT_DURATION_MS = 300
DEFAULT_SAMPLES = 12


def synthesize(start, end, *, duration_ms=DEFAULT_DURATION_MS,
               samples=DEFAULT_SAMPLES):
    """Build a gesture_metadata envelope with a straight-line
    path from `start` to `end`. `start` and `end` are `(x, y)`
    tuples in CSS pixel coordinates. `duration_ms` controls the
    total drag time; `samples` is the number of intermediate
    points (including endpoints)."""
    t0_ms = time.time() * 1000
    if samples < 2:
        samples = 2
    path = []
    for i in range(samples):
        frac = i / (samples - 1)
        path.append({
            "t": t0_ms + frac * duration_ms,
            "x": start[0] + (end[0] - start[0]) * frac,
            "y": start[1] + (end[1] - start[1]) * frac,
        })
    return {
        "path": path,
        "pointer_type": "synthetic",
        "viewport": VIEWPORT,
        "device_pixel_ratio": 1.0,
    }


def drag_endpoints(prim, board_before):
    """Compute the (start, end) pixel coords for a primitive's
    drag, given the board state BEFORE the primitive applies.

    Returns None for primitives that don't involve a drag
    (complete_turn, undo)."""
    kind = prim["action"]
    if kind == "merge_hand":
        target = board_before[prim["target_stack"]]
        loc = target["loc"]
        target_size = len(target["board_cards"])
        # The hand card is dragged from the hand zone to the
        # target's merge edge. Right-side: dropped at the right
        # edge of the target. Left-side: at the left edge.
        if prim.get("side", "right") == "right":
            end_x = loc["left"] + target_size * CARD_PITCH
        else:
            end_x = loc["left"]
        end_y = loc["top"] + CARD_HEIGHT // 2
        return (HAND_ORIGIN_X, HAND_ORIGIN_Y), (end_x, end_y)

    if kind == "move_stack":
        src = board_before[prim["stack_index"]]
        new_loc = prim["new_loc"]
        size = len(src["board_cards"])
        # Drag is from the stack's center to the new loc's center.
        start = (src["loc"]["left"] + size * CARD_PITCH // 2,
                 src["loc"]["top"] + CARD_HEIGHT // 2)
        end = (new_loc["left"] + size * CARD_PITCH // 2,
               new_loc["top"] + CARD_HEIGHT // 2)
        return start, end

    # Other primitive kinds: add endpoints as subsequent tricks
    # need them (split, merge_stack, place_hand). For now return
    # None — the caller falls back to no gesture_metadata.
    return None
