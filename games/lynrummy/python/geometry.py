"""
Client-side LynRummy board geometry — collision detection and
open-spot finding. The server produces logical board deltas at
dummyLoc = (0, 0); clients (this Python auto_player, the Elm UI)
decide where stacks actually sit. The referee enforces the
"no overlap, in bounds" rule at complete_turn time.

Different clients/humans arrange stacks differently (Steve's
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
# Margin bumped 5 → 7 on 2026-04-23 (CROWDED_BOARDS) after
# BOARD_LAB captures revealed that gap=7 between stacks
# reads as overlap to humans even though the old
# gap-must-be-at-least-5 rule accepted it. Keep in sync
# with Elm's Main.Apply.refereeBounds + Go's uses of
# BoardBounds{Margin: 7}.
BOARD_MAX_WIDTH = 800
BOARD_MAX_HEIGHT = 600
BOARD_MARGIN = 7

# Where the 800x600 board div sits in the viewport. Pinned so
# that Python (which has no DOM) and Elm agree on the viewport
# coordinate of every board stack: viewport = stack.loc +
# (BOARD_VIEWPORT_LEFT, BOARD_VIEWPORT_TOP).
#
# If you change these, update `boardViewportLeft` /
# `boardViewportTop` in
# games/lynrummy/elm/src/Game/BoardGeometry.elm
# to match.
BOARD_VIEWPORT_LEFT = 300
BOARD_VIEWPORT_TOP = 100

# Placement-sweep granularity in pixels (fallback path only).
PLACE_STEP = 10

# Packing gaps — the size of the "breathing room" the agent
# leaves between adjacent stacks. Bigger than BOARD_MARGIN:
# the referee enforces the legal-minimum 5px, but a board
# packed at that margin reads as robotic AND leaves adjacent
# stacks looking ambiguous (is that one stack or two?).
#
# Tuned to roughly one card width — close enough to CARD_WIDTH
# that an empty gap reads as "a card could fit there" but not
# so wide that the board sprawls.
PACK_GAP_X = 30
PACK_GAP_Y = 30

# Anti-alignment offset. A fixed +2px nudge applied to every
# placement. Keeps output deterministic while breaking
# pixel-perfect alignment with grid multiples — enough to make
# the board not read as machine-tidied. Same inputs → same
# output, always.
ANTI_ALIGN_PX = 2

# Starting anchor when the board is empty. Hand-feel default;
# a little down-and-right from the top-left corner.
BOARD_START = (24, 24)  # (left, top)


# Preferred scan origin on a non-empty board — tuned 2026-04-23
# from BOARD_LAB human captures (Steve, Joshua, Emma). Humans
# don't land pre-moves near the (0, 0) corner; they favor a
# zone with some inset on both axes. (50, 90) is the lower-left
# edge of the observed landing cluster, chosen so the row-major
# scan hits it first before walking rightward/downward.
#
# "Toward the hand" — the hand column sits off the board to
# its left, so minimizing the upcoming hand-card drag means
# preferring LOW x among valid candidates. Scanning left-to-right
# from left=50 honors that while staying clear of the margin.
HUMAN_PREFERRED_ORIGIN = (50, 90)  # (left, top)


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

    Human-biased placement (2026-04-23 update, driven by
    BOARD_LAB captures from three humans). The scan starts at
    `HUMAN_PREFERRED_ORIGIN` — a zone humans actually use —
    instead of the raw board margin. Rationale:

      - Humans don't land pre-moves at (7, 7). Captured data
        shows landing locs in the `y ≈ 60-120`, `x ≈ 40-500`
        band, never in the extreme top-left corner.
      - The hand column sits off the board to its LEFT in
        viewport frame, so pre-moves that shorten the
        hand-card's upcoming drag live toward LOW x in
        board frame. Scanning left-to-right from a
        non-corner origin hits that zone first.
      - Everything else (first-fit, PACK_GAP breathing room,
        ANTI_ALIGN nudge, crowded-fallback) stays the same.

    100% deterministic. Same board state → same placement.

    `existing` is a list of state-dict stacks.
    """
    new_w = stack_width(card_count)
    new_h = CARD_HEIGHT
    existing_rects = [stack_rect(s) for s in existing]

    # Empty board → fixed starting anchor.
    if not existing_rects:
        left, top = BOARD_START
        return _anti_align(left, top, new_w, new_h)

    # First-fit scan at packing gap. Tighter step than the
    # legal-margin fallback so the 2px anti-align offset
    # actually lands off-grid.
    step = 15
    origin_left, origin_top = HUMAN_PREFERRED_ORIGIN
    min_left = BOARD_MARGIN
    min_top = BOARD_MARGIN
    max_left = BOARD_MAX_WIDTH - new_w - BOARD_MARGIN
    max_top = BOARD_MAX_HEIGHT - new_h - BOARD_MARGIN

    # Clamp the preferred origin in case a future
    # HUMAN_PREFERRED_ORIGIN is too close to the right/bottom
    # edge for the requested stack size.
    start_left = min(max(origin_left, min_left), max_left)
    start_top = min(max(origin_top, min_top), max_top)

    top = start_top
    while top <= max_top:
        left = start_left
        while left <= max_left:
            padded = (
                left - PACK_GAP_X,
                top - PACK_GAP_Y,
                left + new_w + PACK_GAP_X,
                top + new_h + PACK_GAP_Y,
            )
            if not any(rects_overlap(padded, er) for er in existing_rects):
                return _anti_align(left, top, new_w, new_h)
            left += step
        top += step

    # Preferred-zone scan exhausted — widen to the whole
    # board (including the top-left corner) before falling
    # through to the legal-margin crowded fallback.
    top = min_top
    while top <= max_top:
        left = min_left
        while left <= max_left:
            padded = (
                left - PACK_GAP_X,
                top - PACK_GAP_Y,
                left + new_w + PACK_GAP_X,
                top + new_h + PACK_GAP_Y,
            )
            if not any(rects_overlap(padded, er) for er in existing_rects):
                return _anti_align(left, top, new_w, new_h)
            left += step
        top += step

    # Board too crowded for the packing gap — drop to legal margin.
    return _grid_sweep_open_loc(existing_rects, new_w, new_h)


def _anti_align(left, top, new_w, new_h):
    """Apply the fixed ANTI_ALIGN_PX offset, clamped to bounds."""
    jl = min(left + ANTI_ALIGN_PX, BOARD_MAX_WIDTH - new_w)
    jt = min(top + ANTI_ALIGN_PX, BOARD_MAX_HEIGHT - new_h)
    return {"top": jt, "left": jl}


def _grid_sweep_open_loc(existing_rects, new_w, new_h):
    """Deterministic row-major sweep at the legal (BOARD_MARGIN)
    padding. Only used when packed-by-clearance can't satisfy
    the human-style spacing — the board is crowded enough that
    legal-minimum is the best we can do.
    """
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
            if not any(rects_overlap(candidate, er) for er in existing_rects):
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
