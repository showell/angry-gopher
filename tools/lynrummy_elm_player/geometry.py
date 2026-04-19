"""
Client-side LynRummy board geometry — collision detection and
open-spot finding. The server produces logical board deltas at
dummyLoc = (0, 0); clients (this Python auto_player, the Elm UI)
decide where stacks actually sit. The referee enforces the
"no overlap, in bounds" rule at complete_turn time.

Different clients/humans may arrange stacks differently (Steve's
observation: "human players have very different tidying
approaches"). This module is one style — find the first
row-major open slot.

Pure functions on state dicts as returned by the /state endpoint.
No HTTP, no mutation.
"""

# Card-layout constants. Match games/lynrummy/card_stack.go
# (CardWidth=27) and games/lynrummy/board_geometry.go (CardHeight
# = 40, CardPitch = CardWidth + 6 = 33).
CARD_WIDTH = 27
CARD_PITCH = CARD_WIDTH + 6
CARD_HEIGHT = 40

# Board region. Match the referee's bounds in
# views/lynrummy_elm.go (ValidateTurnComplete call site).
BOARD_MAX_WIDTH = 800
BOARD_MAX_HEIGHT = 600
BOARD_MARGIN = 5

# Placement-sweep granularity in pixels.
PLACE_STEP = 10


def stack_width(card_count):
    """Pixel width of a stack with n cards. 0 for n <= 0."""
    if card_count <= 0:
        return 0
    return CARD_WIDTH + (card_count - 1) * CARD_PITCH


def stack_rect(stack):
    """Bounding rect of a board stack (left, top, right, bottom).

    `stack` is a state-dict stack: {"loc":{"top","left"},
    "board_cards":[...]}.
    """
    left = stack["loc"]["left"]
    top = stack["loc"]["top"]
    return (
        left,
        top,
        left + stack_width(len(stack["board_cards"])),
        top + CARD_HEIGHT,
    )


def rects_overlap(a, b):
    """Axis-aligned rect overlap (exclusive edges)."""
    al, at, ar, ab = a
    bl, bt, br, bb = b
    return al < br and ar > bl and at < bb and ab > bt


def pad_rect(r, margin):
    l, t, rr, b = r
    return (l - margin, t - margin, rr + margin, b + margin)


def find_open_loc(existing, card_count):
    """Return {"top","left"} for a new stack of `card_count` cards
    that does not overlap any stack in `existing`.

    Sweeps row-major from (0, 0) in PLACE_STEP increments. Falls
    back to bottom-left corner if nothing fits.

    `existing` is a list of state-dict stacks.
    """
    new_w = stack_width(card_count)
    new_h = CARD_HEIGHT

    existing_rects = [stack_rect(s) for s in existing]

    top = 0
    while top + new_h <= BOARD_MAX_HEIGHT:
        left = 0
        while left + new_w <= BOARD_MAX_WIDTH:
            candidate = (
                left - BOARD_MARGIN,
                top - BOARD_MARGIN,
                left + new_w + BOARD_MARGIN,
                top + new_h + BOARD_MARGIN,
            )
            collides = any(rects_overlap(candidate, er) for er in existing_rects)
            if not collides:
                return {"top": top, "left": left}
            left += PLACE_STEP
        top += PLACE_STEP

    fallback_top = max(0, BOARD_MAX_HEIGHT - new_h)
    return {"top": fallback_top, "left": 0}


def out_of_bounds(stack):
    """True if the stack's bounding rect extends past the board."""
    l, t, r, b = stack_rect(stack)
    return l < 0 or t < 0 or r > BOARD_MAX_WIDTH or b > BOARD_MAX_HEIGHT


def loc_clears_others(loc, card_count, board, exclude_indices=()):
    """True if a stack of `card_count` cards anchored at `loc`
    fits in bounds and doesn't overlap (padded by margin) any
    stack in `board` except those whose indices are in
    `exclude_indices`. Mirrors the referee's two checks:
    bounds-in, and padded-overlap-free.
    """
    rect = (
        loc["left"],
        loc["top"],
        loc["left"] + stack_width(card_count),
        loc["top"] + CARD_HEIGHT,
    )
    if (rect[0] < 0 or rect[1] < 0 or
            rect[2] > BOARD_MAX_WIDTH or rect[3] > BOARD_MAX_HEIGHT):
        return False
    padded = pad_rect(rect, BOARD_MARGIN)
    for i, s in enumerate(board):
        if i in exclude_indices:
            continue
        if rects_overlap(padded, stack_rect(s)):
            return False
    return True


def find_violation(board):
    """Return the index of a stack that breaks the geometry rule,
    or None. Checks out-of-bounds first, then pairwise padded
    overlap (the referee's "too close" / "actual overlap" combo).

    Returns the FIRST offending stack rather than a full report —
    callers iterate: fix one, re-check, repeat until stable.
    """
    for i, s in enumerate(board):
        if out_of_bounds(s):
            return i

    rects = [stack_rect(s) for s in board]
    for i in range(len(rects)):
        padded_i = pad_rect(rects[i], BOARD_MARGIN)
        for j in range(i + 1, len(rects)):
            if rects_overlap(padded_i, rects[j]):
                # Move the later-indexed stack — it's the one
                # that was appended most recently by a trick or
                # by a growing neighbor, so relocating it
                # (rather than the settled stack) is the less
                # disruptive choice.
                return j
    return None
