"""
Python-native STRATEGY layer: trick recognizers + hint priority
walker. Each trick function inspects the current board and hand,
decides whether a human-style play exists, and returns the
sequence of primitive wire actions a human would physically
perform. No trick_result, no compound form, no downstream
inference — the consumer POSTs each primitive directly.

Priority order (simplest-first):
  1. direct_play
  2. hand_stacks
  3. pair_peel
  4. split_for_set
  5. peel_for_run
  6. rb_swap
  7. loose_card_play

Two top-level entry points:

  - `enumerate_plays(hand, board)` — every firing trick in
    priority order, returned as `[{trick_id, primitives}, ...]`.
    Used by the DSL conformance runner and puzzle harness.
  - `choose_play(hand, board)` — the agent's next-play decision.
    Returns the top firing trick or `None`. Used by the
    auto-player. Thin wrapper over `enumerate_plays`.

Each per-trick function returns one primitive sequence or None.

Renamed from hints.py 2026-04-22 (STRATEGY_RENAME) to name the
layer honestly — tricks + hint priority jointly are strategy.
"""

from geometry import find_open_loc, find_violation, CARD_PITCH


# ============================================================
# Value + suit helpers. Mirrors games/lynrummy/stack_type.go.
# ============================================================

def _successor(v):
    return 1 if v == 13 else v + 1


def _predecessor(v):
    return 13 if v == 1 else v - 1


def _color(suit):
    # Clubs=0, Diamonds=1, Spades=2, Hearts=3.
    # Black = 0, 2. Red = 1, 3.
    return "black" if suit in (0, 2) else "red"


def _card_eq(a, b):
    return (a["value"] == b["value"]
            and a["suit"] == b["suit"]
            and a["origin_deck"] == b["origin_deck"])


# ============================================================
# Stack classification. Port of GetStackType for Set / PureRun /
# RedBlackRun. Everything else is "other."
# ============================================================

def _classify(cards):
    n = len(cards)
    if n < 3:
        return "other"
    values = [c["value"] for c in cards]
    suits = [c["suit"] for c in cards]

    if len(set(values)) == 1 and len(set(suits)) == len(suits):
        return "set"

    for i in range(1, n):
        if values[i] != _successor(values[i - 1]):
            return "other"

    if len(set(suits)) == 1:
        return "pure_run"

    colors = [_color(s) for s in suits]
    if all(colors[i] != colors[i - 1] for i in range(1, n)):
        return "rb_run"
    return "other"


def _trio_type(cards):
    """Classify exactly 3 cards — returns 'set', 'pure_run',
    'rb_run', or 'other'. Order-sensitive for runs; tries both
    natural and sorted-by-value ordering before giving up."""
    if len(cards) != 3:
        return "other"
    t = _classify(cards)
    if t != "other":
        return t
    sorted_cards = sorted(cards, key=lambda c: c["value"])
    return _classify(sorted_cards)


def _can_extract(stack, card_idx):
    """Port of Go CardStack.CanExtract."""
    cards = [bc["card"] for bc in stack["board_cards"]]
    size = len(cards)
    kind = _classify(cards)
    if kind == "set":
        return size >= 4
    if kind not in ("pure_run", "rb_run"):
        return False
    if size >= 4 and (card_idx == 0 or card_idx == size - 1):
        return True
    if card_idx >= 3 and (size - card_idx - 1) >= 3:
        return True
    return False


# ============================================================
# Board sim — Go's remove-and-reappend semantics. Used to
# compute primitive indices at emit time.
# ============================================================

def _copy_board(board):
    return [{"board_cards": list(s["board_cards"]), "loc": dict(s["loc"])}
            for s in board]


def _find_stack(board, card):
    for si, s in enumerate(board):
        for bc in s["board_cards"]:
            if _card_eq(bc["card"], card):
                return si
    return None


def _apply_split(board, si, ci):
    """Mirror Go's CardStack.Split loc rules: the two halves get
    distinct locations derived from the source loc + leftCount *
    CARD_PITCH + small nudges. Left and right use different rules
    depending on whether the split point is in the first or
    second half of the stack."""
    stack = board[si]
    size = len(stack["board_cards"])
    src_left = stack["loc"]["left"]
    src_top = stack["loc"]["top"]
    if ci + 1 <= size // 2:
        # leftSplit: left stays high/left, right hops right + 8.
        left_count = ci + 1
        left_loc = {"top": src_top - 4, "left": src_left - 2}
        right_loc = {"top": src_top,
                     "left": src_left + left_count * CARD_PITCH + 8}
    else:
        # rightSplit: left nudges left -8, right hops right + 4.
        left_count = ci
        left_loc = {"top": src_top, "left": src_left - 8}
        right_loc = {"top": src_top - 4,
                     "left": src_left + left_count * CARD_PITCH + 4}
    left = {"board_cards": stack["board_cards"][:left_count],
            "loc": left_loc}
    right = {"board_cards": stack["board_cards"][left_count:],
             "loc": right_loc}
    return board[:si] + board[si + 1:] + [left, right]


def _apply_move(board, si, new_loc):
    s = board[si]
    moved = {"board_cards": s["board_cards"], "loc": dict(new_loc)}
    return board[:si] + board[si + 1:] + [moved]


def _apply_merge_stack(board, src, tgt, side):
    s, t = board[src], board[tgt]
    if side == "left":
        new_cards = list(s["board_cards"]) + list(t["board_cards"])
        # Match Go's LeftMerge: the merged stack's left edge shifts
        # left by the width of the incoming cards.
        loc = {"left": t["loc"]["left"] - CARD_PITCH * len(s["board_cards"]),
               "top":  t["loc"]["top"]}
    else:
        new_cards = list(t["board_cards"]) + list(s["board_cards"])
        loc = dict(t["loc"])
    merged = {"board_cards": new_cards, "loc": loc}
    hi, lo = sorted((src, tgt), reverse=True)
    out = list(board)
    del out[hi]; del out[lo]
    return out + [merged]


def _apply_merge_hand(board, target_idx, hand_card, side):
    t = board[target_idx]
    wrapper = {"card": hand_card, "state": 0}
    if side == "left":
        new_cards = [wrapper] + list(t["board_cards"])
        loc = {"left": t["loc"]["left"] - CARD_PITCH,
               "top":  t["loc"]["top"]}
    else:
        new_cards = list(t["board_cards"]) + [wrapper]
        loc = dict(t["loc"])
    merged = {"board_cards": new_cards, "loc": loc}
    return board[:target_idx] + board[target_idx + 1:] + [merged]


def _apply_place_hand(board, hand_card, loc):
    new_stack = {"board_cards": [{"card": hand_card, "state": 1}],
                 "loc": dict(loc)}
    return board + [new_stack]


# ============================================================
# Peel primitive — isolate a target card into its own stack via
# 1 or 2 splits. Used by every extraction-based trick. Returns
# (primitives, sim_after, isolated_card) or None if not
# extractable.
# ============================================================

def _emit_peel(sim, target_card, target_ci):
    stack_idx = _find_stack(sim, target_card)
    stack_size = len(sim[stack_idx]["board_cards"])
    prims = []

    if target_ci == 0:
        # Left edge: one split isolates the head.
        prims.append({"action": "split", "stack_index": stack_idx,
                      "card_index": 0})
        sim = _apply_split(sim, stack_idx, 0)
    elif target_ci == stack_size - 1:
        # Right edge: one split isolates the tail.
        prims.append({"action": "split", "stack_index": stack_idx,
                      "card_index": target_ci})
        sim = _apply_split(sim, stack_idx, target_ci)
    else:
        # Middle: two splits. First peel the right tail, target
        # ends up as the last card of the left piece; then split
        # that piece at its new last position.
        prims.append({"action": "split", "stack_index": stack_idx,
                      "card_index": target_ci + 1})
        sim = _apply_split(sim, stack_idx, target_ci + 1)
        # Re-locate the stack now containing the target.
        left_idx = _find_stack(sim, target_card)
        left_size = len(sim[left_idx]["board_cards"])
        tail_ci = left_size - 1
        prims.append({"action": "split", "stack_index": left_idx,
                      "card_index": tail_ci})
        sim = _apply_split(sim, left_idx, tail_ci)

    return prims, sim


def _fix_geometry(sim, prims):
    """Append move_stack primitives until the simulated board has
    no geometry violations (no overlap, all in bounds).

    Called at the end of each trick's emission as a safety net.
    Ideally rare — the trick emitters pre-plan via
    `_plan_merge_hand`, so intermediate frames stay clean during
    replay. A `_fix_geometry` move that appears AFTER a merge
    produces a visually broken intermediate frame (card partly
    off-board between the merge and the fix), which is why
    pre-planning is preferred wherever possible.
    """
    while True:
        bad_idx = find_violation(sim)
        if bad_idx is None:
            return sim
        stack = sim[bad_idx]
        others = [s for i, s in enumerate(sim) if i != bad_idx]
        new_loc = find_open_loc(others, card_count=len(stack["board_cards"]))
        prims.append({
            "action": "move_stack",
            "stack_index": bad_idx,
            "new_loc": new_loc,
        })
        sim = _apply_move(sim, bad_idx, new_loc)


def _plan_merge_stack(sim, src_idx, tgt_idx, side):
    """Emit primitives for merging sim[src_idx] onto sim[tgt_idx]
    on `side`, with pre-flight geometry planning. Parallel to
    `_plan_merge_hand` — same algorithm, applied to a board-
    to-board merge instead of a hand-card-to-board merge.

    Try merge-in-place first. If the merged stack fits without
    a bounds or overlap violation, emit just the merge. Otherwise
    find a hole sized for the EVENTUAL merged stack, move the
    target there first (accounting for the side-specific shift:
    a left-merge shifts the merged stack's top-left left by
    src_width * CARD_PITCH), then emit the merge. That way every
    intermediate frame in replay stays geometrically clean.

    Returns (primitives, sim_after).
    """
    src = sim[src_idx]
    tgt = sim[tgt_idx]
    final_size = len(src["board_cards"]) + len(tgt["board_cards"])

    # Merge-in-place if it stays legal. This is the common case
    # when the follow-up scan finds two stacks already close
    # enough that the merged stack fits at the target's current
    # loc — just drag source onto target's wing.
    merged_in_place = _apply_merge_stack(
        _copy_board(sim), src_idx, tgt_idx, side)
    if find_violation(merged_in_place) is None:
        return (
            [{"action": "merge_stack", "source_stack": src_idx,
              "target_stack": tgt_idx, "side": side}],
            merged_in_place,
        )

    # Eventual stack overflows at target's current loc. Find a
    # hole sized for the final merged stack, accounting for the
    # side-specific shift.
    others = [s for i, s in enumerate(sim)
              if i != src_idx and i != tgt_idx]
    final_loc = find_open_loc(others, card_count=final_size)
    src_width = len(src["board_cards"]) * CARD_PITCH
    if side == "left":
        tgt_loc = {"left": final_loc["left"] + src_width,
                   "top": final_loc["top"]}
    else:
        tgt_loc = final_loc

    # Move target first. _apply_move uses remove-and-append
    # semantics, so target ends up at len-1 and any index > tgt_idx
    # shifts down by 1. Source's post-move index depends on
    # whether it was before or after target in the original list.
    moved = _apply_move(_copy_board(sim), tgt_idx, tgt_loc)
    new_tgt_idx = len(moved) - 1
    new_src_idx = src_idx if src_idx < tgt_idx else src_idx - 1
    merged = _apply_merge_stack(moved, new_src_idx, new_tgt_idx, side)
    return (
        [
            {"action": "move_stack", "stack_index": tgt_idx,
             "new_loc": tgt_loc},
            {"action": "merge_stack", "source_stack": new_src_idx,
             "target_stack": new_tgt_idx, "side": side},
        ],
        merged,
    )


def _plan_merge_hand(sim, target_idx, hand_card, side):
    """Emit primitives for merging `hand_card` onto `sim[target_idx]`
    on `side`, with pre-flight geometry planning.

    Humans plan this merge around the EVENTUAL stack: "the 6H
    goes to the left of the 789rb, so the final 4-card run is
    6-7-8-9." They look for a hole that fits the final stack,
    not the current one, and account for the side-specific
    offset (a left-merge shifts the stack's top-left by
    -CARD_PITCH). If the merge-in-place would violate bounds,
    move the target FIRST, then merge — so every frame in the
    replay shows a geometrically clean board.

    Returns (primitives, sim_after).
    """
    target = sim[target_idx]
    final_size = len(target["board_cards"]) + 1

    # Merge-in-place if it stays legal.
    merged_in_place = _apply_merge_hand(
        _copy_board(sim), target_idx, hand_card, side)
    if find_violation(merged_in_place) is None:
        return (
            [{"action": "merge_hand", "hand_card": hand_card,
              "target_stack": target_idx, "side": side}],
            merged_in_place,
        )

    # Pre-flight: find a hole sized for the EVENTUAL stack,
    # then translate back to the target's pre-merge loc so that
    # after the side-specific shift the final stack lands there.
    others = [s for i, s in enumerate(sim) if i != target_idx]
    final_loc = find_open_loc(others, card_count=final_size)
    if side == "left":
        target_loc = {"left": final_loc["left"] + CARD_PITCH,
                      "top": final_loc["top"]}
    else:
        target_loc = final_loc

    moved = _apply_move(_copy_board(sim), target_idx, target_loc)
    new_idx = len(moved) - 1
    merged = _apply_merge_hand(moved, new_idx, hand_card, side)
    return (
        [
            {"action": "move_stack", "stack_index": target_idx,
             "new_loc": target_loc},
            {"action": "merge_hand", "hand_card": hand_card,
             "target_stack": new_idx, "side": side},
        ],
        merged,
    )


# ============================================================
# 1. DIRECT_PLAY. A hand card extends a valid 3+ stack.
# ============================================================

def direct_play(hand, board):
    """Find a hand card that extends a valid stack on the board.
    Returns the primitive sequence that realizes the play, or
    None if no card extends anything."""
    for hc in hand:
        card = hc["card"]
        for si, s in enumerate(board):
            for side in ("right", "left"):
                result = _try_merge_hand(s, card, side)
                if result is None or _classify(result) == "other":
                    continue
                return _emit_direct_play(board, si, card, side)
    return None


def _emit_direct_play(board, target_idx, hand_card, side):
    """Physical execution of a direct_play. Delegates the whole
    "does the eventual stack fit?" decision to `_plan_merge_hand`,
    which merges in place when legal and otherwise moves the
    target first to a hole sized for the final stack."""
    prims, _sim = _plan_merge_hand(board, target_idx, hand_card, side)
    return prims


def _try_merge_hand(stack, hand_card, side):
    """Return the would-be card list after merging `hand_card` onto
    `stack` on the given side, or None if the merge's structure is
    obviously broken (duplicate identity)."""
    existing = [bc["card"] for bc in stack["board_cards"]]
    if any(_card_eq(c, hand_card) for c in existing):
        return None
    if side == "left":
        return [hand_card] + existing
    return existing + [hand_card]


# ============================================================
# 2. HAND_STACKS. Hand has a 3+ subset forming a valid group;
# place it on the board as a new stack.
# ============================================================

def hand_stacks(hand, board):
    group = _find_hand_group(hand)
    if group is None:
        return None
    # Physical: place the first card, then merge each subsequent.
    first, *rest = group
    loc = find_open_loc(board, card_count=len(group))
    prims = [{"action": "place_hand", "hand_card": first, "loc": loc}]
    # After place_hand, the new stack is at the END of the board.
    # Each merge keeps it at the end (remove+append preserves
    # the final position).
    sim = _apply_place_hand(_copy_board(board), first, loc)
    target_idx = len(sim) - 1
    for c in rest:
        step_prims, sim = _plan_merge_hand(sim, target_idx, c, "right")
        prims.extend(step_prims)
        target_idx = len(sim) - 1
    _fix_geometry(sim, prims)
    return prims


def _find_hand_group(hand):
    """Find a 3+ subset of hand cards that forms a Set or PureRun
    or RbRun. Returns cards in a natural order (ascending value for
    runs; sorted by suit for sets)."""
    cards = [hc["card"] for hc in hand]

    # Try sets first: group by value.
    by_value = {}
    for c in cards:
        by_value.setdefault(c["value"], []).append(c)
    for v, cs in by_value.items():
        picked = []
        seen_suits = set()
        for c in cs:
            if c["suit"] in seen_suits:
                continue
            picked.append(c)
            seen_suits.add(c["suit"])
        if len(picked) >= 3:
            picked.sort(key=lambda c: c["suit"])
            return picked

    # Then pure runs: group by suit, dedupe by value, find
    # consecutive chains. (Dedupe because a pure run can't
    # contain two cards of the same value — they'd be a dup.)
    by_suit = {}
    for c in cards:
        by_suit.setdefault(c["suit"], []).append(c)
    for suit, cs in by_suit.items():
        seen = set()
        unique = []
        for c in cs:
            if c["value"] in seen:
                continue
            seen.add(c["value"])
            unique.append(c)
        unique.sort(key=lambda c: c["value"])
        chain = []
        for c in unique:
            if chain and c["value"] == chain[-1]["value"] + 1:
                chain.append(c)
            else:
                if len(chain) >= 3:
                    return chain
                chain = [c]
        if len(chain) >= 3:
            return chain

    # RB runs: dedupe by value (first card wins), sort by value,
    # walk looking for consecutive values with alternating colors.
    by_value = {}
    for c in cards:
        if c["value"] not in by_value:
            by_value[c["value"]] = c
    sorted_cards = [by_value[v] for v in sorted(by_value)]
    chain = []
    for c in sorted_cards:
        if chain:
            same_succ = c["value"] == chain[-1]["value"] + 1
            alt_color = _color(c["suit"]) != _color(chain[-1]["suit"])
            if same_succ and alt_color:
                chain.append(c)
                continue
            if len(chain) >= 3:
                return chain
        chain = [c]
    if len(chain) >= 3:
        return chain

    return None


# ============================================================
# 3. PAIR_PEEL. Two hand cards form a pair-need, one extractable
# board card completes the trio (set or run).
# ============================================================

def pair_peel(hand, board):
    for i in range(len(hand)):
        for j in range(i + 1, len(hand)):
            hca = hand[i]["card"]
            hcb = hand[j]["card"]
            if _card_eq(hca, hcb):
                continue
            needs = _pair_needs(hca, hcb)
            for need_value, need_suits in needs:
                for si, s in enumerate(board):
                    for ci, bc in enumerate(s["board_cards"]):
                        c = bc["card"]
                        if c["value"] != need_value:
                            continue
                        if c["suit"] not in need_suits:
                            continue
                        if not _can_extract(s, ci):
                            continue
                        # Validate the trio.
                        trio = [hca, hcb, c]
                        if _trio_type(trio) == "other":
                            continue
                        return _emit_extract_and_merge_two_hand(
                            board, c, ci, hca, hcb)
    return None


def _pair_needs(a, b):
    """Return [(value, [allowed_suits]), ...] completing the pair."""
    # Set pair.
    if a["value"] == b["value"] and a["suit"] != b["suit"]:
        allowed = [s for s in (0, 1, 2, 3)
                   if s != a["suit"] and s != b["suit"]]
        return [(a["value"], allowed)]

    # Run pair needs consecutive values.
    lo, hi = (a, b) if a["value"] < b["value"] else (b, a)
    if hi["value"] != _successor(lo["value"]):
        return []

    if a["suit"] == b["suit"]:
        return [
            (_predecessor(lo["value"]), [lo["suit"]]),
            (_successor(hi["value"]), [hi["suit"]]),
        ]
    if _color(a["suit"]) != _color(b["suit"]):
        opp_lo = _opposite_color_suits(_color(lo["suit"]))
        opp_hi = _opposite_color_suits(_color(hi["suit"]))
        return [
            (_predecessor(lo["value"]), opp_lo),
            (_successor(hi["value"]), opp_hi),
        ]
    return []


def _opposite_color_suits(color):
    if color == "red":
        return [2, 0]  # Spade, Club
    return [3, 1]      # Heart, Diamond


# ============================================================
# 4. SPLIT_FOR_SET. One hand card + two extractable board cards
# of same value → 3-set. Now with middle extractions.
# ============================================================

def split_for_set(hand, board):
    for hc in hand:
        hand_card = hc["card"]
        candidates = []
        for si, s in enumerate(board):
            for ci, bc in enumerate(s["board_cards"]):
                c = bc["card"]
                if c["value"] != hand_card["value"]:
                    continue
                if c["suit"] == hand_card["suit"]:
                    continue
                if not _can_extract(s, ci):
                    continue
                candidates.append((si, ci, c))

        # Pick two from DIFFERENT stacks with distinct suits.
        for i in range(len(candidates)):
            for j in range(i + 1, len(candidates)):
                si_a, ci_a, ca = candidates[i]
                si_b, ci_b, cb = candidates[j]
                if si_a == si_b:
                    continue
                if ca["suit"] == cb["suit"]:
                    continue
                trio = [hand_card, ca, cb]
                if _trio_type(trio) != "set":
                    continue
                return _emit_extract_and_merge_one_hand(
                    board, ca, ci_a, cb, ci_b, hand_card)
    return None


# ============================================================
# 5. PEEL_FOR_RUN. One hand card + two extractable board cards
# at value-1 and value+1 → 3-run. Middle extractions supported.
# ============================================================

def peel_for_run(hand, board):
    for hc in hand:
        v = hc["card"]["value"]
        prev_v = _predecessor(v)
        next_v = _successor(v)
        prevs = _find_peelable_at_value(board, prev_v, hc["card"])
        nexts = _find_peelable_at_value(board, next_v, hc["card"])
        if not prevs or not nexts:
            continue
        for (si_p, ci_p, cp) in prevs:
            for (si_n, ci_n, cn) in nexts:
                if si_p == si_n:
                    continue
                trio = [cp, hc["card"], cn]
                t = _trio_type(trio)
                if t not in ("pure_run", "rb_run"):
                    continue
                return _emit_peel_for_run(
                    board, cp, ci_p, cn, ci_n, hc["card"])
    return None


def _emit_peel_for_run(board, target_low, ci_low, target_high, ci_high,
                       hand_card):
    """For a run, build the stack monotonically so every
    intermediate is a valid partial run:
      1. peel target_low
      2. move target_low to open
      3. merge_hand hand_card onto target_low (right) → [low, mid]
      4. peel target_high
      5. merge_stack target_high onto [low, mid] (right) → [low, mid, high]

    Every step leaves only complete-or-growing stacks; no gap
    pairs like [9C, 11C] get created."""
    sim = _copy_board(board)
    prims = []

    # 1. Peel low.
    peel_prims, sim = _emit_peel(sim, target_low, ci_low)
    prims.extend(peel_prims)

    # 2. Move low to an open spot with room for 3.
    low_idx = _find_stack(sim, target_low)
    new_loc = find_open_loc(sim, card_count=3)
    prims.append({"action": "move_stack", "stack_index": low_idx,
                  "new_loc": new_loc})
    sim = _apply_move(sim, low_idx, new_loc)

    # 3. Merge hand card onto low (right) — forms [low, mid].
    low_idx = _find_stack(sim, target_low)
    step_prims, sim = _plan_merge_hand(sim, low_idx, hand_card, "right")
    prims.extend(step_prims)

    # 4. Peel high.
    peel_prims, sim = _emit_peel(sim, target_high, ci_high)
    prims.extend(peel_prims)

    # 5. Merge high onto [low, mid] (right) — forms [low, mid, high].
    high_idx = _find_stack(sim, target_high)
    dst_idx = _find_stack(sim, target_low)
    prims.append({"action": "merge_stack", "source_stack": high_idx,
                  "target_stack": dst_idx, "side": "right"})
    sim = _apply_merge_stack(sim, high_idx, dst_idx, "right")

    _fix_geometry(sim, prims)
    return prims


def _find_peelable_at_value(board, value, exclude):
    out = []
    for si, s in enumerate(board):
        for ci, bc in enumerate(s["board_cards"]):
            c = bc["card"]
            if c["value"] != value:
                continue
            if _card_eq(c, exclude):
                continue
            if not _can_extract(s, ci):
                continue
            out.append((si, ci, c))
    return out


# ============================================================
# Shared emitter: extract two board targets, combine with one
# hand card (split_for_set, peel_for_run).
# ============================================================

def _emit_extract_and_merge_one_hand(board, target_a, ci_a,
                                      target_b, ci_b, hand_card,
                                      low_goes_left=False):
    sim = _copy_board(board)
    prims = []

    # Peel A.
    peeled_a, sim = _emit_peel(sim, target_a, ci_a)
    prims.extend(peeled_a)

    # Drag A to an open spot big enough for the final 3-group.
    a_idx = _find_stack(sim, target_a)
    new_loc = find_open_loc(sim, card_count=3)
    prims.append({"action": "move_stack", "stack_index": a_idx,
                  "new_loc": new_loc})
    sim = _apply_move(sim, a_idx, new_loc)

    # Peel B.
    peeled_b, sim = _emit_peel(sim, target_b, ci_b)
    prims.extend(peeled_b)

    # Merge B onto A. For runs, order matters — the lower-value
    # card goes left of the higher, so whichever is "A" decides
    # the side.
    src = _find_stack(sim, target_b)
    dst = _find_stack(sim, target_a)
    if low_goes_left:
        side = "right" if target_b["value"] > target_a["value"] else "left"
    else:
        side = "right"
    prims.append({"action": "merge_stack", "source_stack": src,
                  "target_stack": dst, "side": side})
    sim = _apply_merge_stack(sim, src, dst, side)

    # Merge the hand card. For runs, its side depends on its value
    # vs the current stack's min/max.
    dst = _find_stack(sim, target_a)
    if low_goes_left:
        current = [bc["card"] for bc in sim[dst]["board_cards"]]
        lo = min(c["value"] for c in current)
        hi = max(c["value"] for c in current)
        if hand_card["value"] < lo:
            hand_side = "left"
        elif hand_card["value"] > hi:
            hand_side = "right"
        else:
            hand_side = "right"  # middle — value already bracketed
    else:
        hand_side = "right"
    step_prims, sim = _plan_merge_hand(sim, dst, hand_card, hand_side)
    prims.extend(step_prims)

    _fix_geometry(sim, prims)
    return prims


# ============================================================
# Shared emitter: extract one board target, combine with two
# hand cards (pair_peel).
# ============================================================

def _emit_extract_and_merge_two_hand(board, target, ci,
                                      hand_a, hand_b):
    sim = _copy_board(board)
    prims = []

    peeled, sim = _emit_peel(sim, target, ci)
    prims.extend(peeled)

    t_idx = _find_stack(sim, target)
    new_loc = find_open_loc(sim, card_count=3)
    prims.append({"action": "move_stack", "stack_index": t_idx,
                  "new_loc": new_loc})
    sim = _apply_move(sim, t_idx, new_loc)

    # Order hand cards so each merge produces a valid ascending
    # intermediate. For a set (all cards same value) the order
    # doesn't matter. For a run-pair it does: the card closer in
    # value to the target must merge first so the intermediate
    # stack is a 2-card partial run (consecutive, ascending),
    # not a gap pair.
    def _dist(c):
        return abs(c["value"] - target["value"])
    ordered = sorted([hand_a, hand_b], key=_dist)

    for hc in ordered:
        t_idx = _find_stack(sim, target)
        side = _merge_side_for_run(sim[t_idx], hc, target)
        step_prims, sim = _plan_merge_hand(sim, t_idx, hc, side)
        prims.extend(step_prims)
    _fix_geometry(sim, prims)
    return prims


def _merge_side_for_run(stack, new_card, anchor_card):
    """Pick a side for merging `new_card` onto `stack`. For sets
    the side doesn't matter; default right. For runs, place the
    card on the side that keeps ascending order."""
    existing = [bc["card"] for bc in stack["board_cards"]]
    all_same_value = all(c["value"] == existing[0]["value"] for c in existing)
    if all_same_value and new_card["value"] == existing[0]["value"]:
        return "right"  # set — side irrelevant
    current_values = [c["value"] for c in existing]
    lo = min(current_values)
    hi = max(current_values)
    if new_card["value"] < lo:
        return "left"
    if new_card["value"] > hi:
        return "right"
    return "right"


# ============================================================
# 6. RB_SWAP. Swap a same-color card into an rb run; kicked card
# goes to a home (set or pure run).
# ============================================================

def rb_swap(hand, board):
    for hc in hand:
        swap_in = hc["card"]
        swap_in_color = _color(swap_in["suit"])
        for si, s in enumerate(board):
            if _classify([bc["card"] for bc in s["board_cards"]]) != "rb_run":
                continue
            cards = [bc["card"] for bc in s["board_cards"]]
            for ci, bc in enumerate(cards):
                if bc["value"] != swap_in["value"]:
                    continue
                if _color(bc["suit"]) != swap_in_color:
                    continue
                if bc["suit"] == swap_in["suit"]:
                    continue
                # Does the rb run stay rb after substitution?
                swapped = list(cards)
                swapped[ci] = swap_in
                if _classify(swapped) != "rb_run":
                    continue
                home = _find_kicked_home(board, si, bc)
                if home is None:
                    continue
                return _emit_rb_swap(board, si, ci, bc, swap_in, home)
    return None


def _find_kicked_home(board, skip_idx, kicked):
    """Return (stack_idx, side) for the kicked card's home, or
    None. Matches Go's findKickedHome."""
    for j, s in enumerate(board):
        if j == skip_idx:
            continue
        cards = [bc["card"] for bc in s["board_cards"]]
        kind = _classify(cards)
        # Set with <4 cards missing kicked's suit.
        if kind == "set" and len(cards) < 4 and cards[0]["value"] == kicked["value"]:
            if not any(c["suit"] == kicked["suit"] for c in cards):
                return (j, "right")
        # Pure run accepting kicked at either end.
        if kind == "pure_run" and cards[0]["suit"] == kicked["suit"]:
            if kicked["value"] == _predecessor(cards[0]["value"]):
                return (j, "left")
            if kicked["value"] == _successor(cards[-1]["value"]):
                return (j, "right")
    return None


def _emit_rb_swap(board, run_si, run_ci, kicked, swap_in, home):
    """RB swap sequence:
      1. isolate kicked card from rb run (1-2 splits)
      2. pick up kicked card; it stays as a singleton momentarily
      3. play swap_in from hand into the run's gap (merge_hand)
         onto the left or right remnant, then
      4. merge the two run remnants back together with swap_in
         in the middle
      5. merge kicked onto its home
    """
    home_idx, home_side = home
    home_anchor = board[home_idx]["board_cards"][0]["card"]

    sim = _copy_board(board)
    prims = []
    stack_size = len(board[run_si]["board_cards"])
    at_left_edge = run_ci == 0
    at_right_edge = run_ci == stack_size - 1

    # Step 1: peel the kicked card.
    if at_left_edge or at_right_edge:
        peel_prims, sim = _emit_peel(sim, kicked, run_ci)
        prims.extend(peel_prims)
    else:
        # Middle: two splits.
        peel_prims, sim = _emit_peel(sim, kicked, run_ci)
        prims.extend(peel_prims)

    # Identify the remnants we still need to handle.
    # For an end peel: only one remnant exists (the other half of
    # the original run). For a middle peel: two remnants — the
    # left and right halves.
    #
    # We need to:
    #  - merge swap_in into the appropriate remnant(s)
    #  - fuse the two run halves (middle case) back into one run
    #
    # The cleanest strategy is to walk the pre-peel cards to
    # identify the remnants' identities, then:
    #  - For end peels, the sole remnant gets swap_in added to the
    #    edge that the kicked card vacated.
    #  - For middle peels, merge_hand swap_in onto the LEFT
    #    remnant (right side of left remnant), then merge_stack
    #    the right remnant onto it.
    pre_cards = [bc["card"] for bc in board[run_si]["board_cards"]]
    left_cards = pre_cards[:run_ci]
    right_cards = pre_cards[run_ci + 1:]

    if at_left_edge:
        # Remnant = right_cards. Swap_in goes to the LEFT of it.
        anchor = right_cards[0]
        r_idx = _find_stack(sim, anchor)
        step_prims, sim = _plan_merge_hand(sim, r_idx, swap_in, "left")
        prims.extend(step_prims)
    elif at_right_edge:
        anchor = left_cards[-1]
        r_idx = _find_stack(sim, anchor)
        step_prims, sim = _plan_merge_hand(sim, r_idx, swap_in, "right")
        prims.extend(step_prims)
    else:
        # Middle case: merge swap_in onto the right of the left
        # remnant, then merge the right remnant onto it.
        left_anchor = left_cards[-1]
        left_idx = _find_stack(sim, left_anchor)
        step_prims, sim = _plan_merge_hand(sim, left_idx, swap_in, "right")
        prims.extend(step_prims)
        # Merge right remnant.
        right_anchor = right_cards[0]
        right_idx = _find_stack(sim, right_anchor)
        merged_idx = _find_stack(sim, left_anchor)
        prims.append({"action": "merge_stack",
                      "source_stack": right_idx,
                      "target_stack": merged_idx, "side": "right"})
        sim = _apply_merge_stack(sim, right_idx, merged_idx, "right")

    # Finally, merge the kicked card onto its home.
    kicked_idx = _find_stack(sim, kicked)
    home_now = _find_stack(sim, home_anchor)
    prims.append({"action": "merge_stack",
                  "source_stack": kicked_idx,
                  "target_stack": home_now, "side": home_side})
    sim = _apply_merge_stack(sim, kicked_idx, home_now, home_side)

    _fix_geometry(sim, prims)
    return prims


# ============================================================
# 7. LOOSE_CARD_PLAY. Peel a board card, land it on another
# stack, then play a stranded hand card.
# ============================================================

def loose_card_play(hand, board):
    # Stranded hand cards = those that can't directly play.
    stranded = []
    for hc in hand:
        if not _card_extends_any(hc["card"], board):
            stranded.append(hc)
    if not stranded:
        return None

    for src_si, src in enumerate(board):
        for src_ci, bc in enumerate(src["board_cards"]):
            if not _can_extract(src, src_ci):
                continue
            peeled = bc["card"]
            for dst_si, dst in enumerate(board):
                if dst_si == src_si:
                    continue
                # Try placing peeled onto dst; valid if the result
                # is a complete stack (not Incomplete).
                for side in ("right", "left"):
                    result = _try_merge_stack_shape(dst, peeled, side)
                    if result is None or _classify(result) == "other":
                        continue
                    # Simulate the post-move board and check that
                    # a stranded hand card has a home.
                    sim = _simulate_loose_move(
                        board, src_si, src_ci, dst_si, peeled, side)
                    for hc in stranded:
                        if _card_extends_any(hc["card"], sim):
                            return _emit_loose_move(
                                board, src_si, src_ci, peeled,
                                dst_si, side, hc["card"], sim)
    return None


def _card_extends_any(card, board):
    for s in board:
        for side in ("right", "left"):
            result = _try_merge_hand(s, card, side)
            if result is not None and _classify(result) != "other":
                return True
    return False


def _try_merge_stack_shape(stack, card, side):
    """Shape-check for dropping a single card as a stack onto
    `stack`. Returns the resulting card list or None if there's a
    dup or the shape is Bogus; Incomplete returns the card list so
    the caller can gate on _classify."""
    existing = [bc["card"] for bc in stack["board_cards"]]
    if any(_card_eq(c, card) for c in existing):
        return None
    return [card] + existing if side == "left" else existing + [card]


def _simulate_loose_move(board, src_si, src_ci, dst_si,
                          peeled, side):
    """Return the board after peeling `peeled` from src and
    merging it onto dst. Uses Go's remove-and-reappend semantics."""
    sim = _copy_board(board)
    src_stack = sim[src_si]
    dst_stack = sim[dst_si]
    # Build the residual source.
    cards = src_stack["board_cards"]
    size = len(cards)
    if src_ci == 0:
        residual = {"board_cards": cards[1:], "loc": dict(src_stack["loc"])}
    elif src_ci == size - 1:
        residual = {"board_cards": cards[:size - 1], "loc": dict(src_stack["loc"])}
    else:
        # Middle / set peel.
        kind = _classify([bc["card"] for bc in cards])
        if kind == "set" and size >= 4:
            remaining = cards[:src_ci] + cards[src_ci + 1:]
            residual = {"board_cards": remaining, "loc": dict(src_stack["loc"])}
        else:
            # Middle run peel — Go's peelIntoResidual returns the
            # LEFT half. Mirror that.
            residual = {"board_cards": cards[:src_ci], "loc": dict(src_stack["loc"])}
    # Build the merged destination.
    dst_cards = [bc["card"] for bc in dst_stack["board_cards"]]
    if side == "left":
        new_dst_cards = [peeled] + dst_cards
    else:
        new_dst_cards = dst_cards + [peeled]
    merged = {"board_cards": [{"card": c, "state": 0}
                              for c in new_dst_cards],
              "loc": dict(dst_stack["loc"])}
    # Remove both stacks; append residual + merged.
    hi, lo = sorted((src_si, dst_si), reverse=True)
    out = list(sim)
    del out[hi]; del out[lo]
    return out + [residual, merged]


def _emit_loose_move(board, src_si, src_ci, peeled, dst_si,
                     side, hand_card, post_move_sim):
    """Physical sequence for loose_card_play:
      1. peel the board card (1-2 splits)
      2. merge it onto the destination stack (merge_stack)
      3. play the stranded hand card onto whichever post-move
         stack accepts it (merge_hand)
    """
    sim = _copy_board(board)
    prims = []

    # Step 1: peel.
    peel_prims, sim = _emit_peel(sim, peeled, src_ci)
    prims.extend(peel_prims)

    # Step 2: merge peeled onto destination.
    src_idx = _find_stack(sim, peeled)
    dst_anchor = board[dst_si]["board_cards"][0]["card"]
    dst_idx = _find_stack(sim, dst_anchor)
    prims.append({"action": "merge_stack", "source_stack": src_idx,
                  "target_stack": dst_idx, "side": side})
    sim = _apply_merge_stack(sim, src_idx, dst_idx, side)

    # Step 3: find where the hand card lands.
    for i, s in enumerate(sim):
        for test_side in ("right", "left"):
            result = _try_merge_hand(s, hand_card, test_side)
            if result is None or _classify(result) == "other":
                continue
            step_prims, sim = _plan_merge_hand(sim, i, hand_card, test_side)
            prims.extend(step_prims)
            _fix_geometry(sim, prims)
            return prims
    # Shouldn't reach here given the caller's stranded-card check.
    _fix_geometry(sim, prims)
    return prims


# ============================================================
# Top-level dispatcher. Walks tricks in priority order and
# returns the first firing. Matches Go's HintPriorityOrder.
# ============================================================

TRICK_ORDER = [
    ("direct_play",      direct_play),
    ("hand_stacks",      hand_stacks),
    ("pair_peel",        pair_peel),
    ("split_for_set",    split_for_set),
    ("peel_for_run",     peel_for_run),
    ("rb_swap",          rb_swap),
    ("loose_card_play",  loose_card_play),
]


def _invariant_clean(board, prims):
    """Simulate applying `prims` to `board`; return (ok, reason).
    `ok` is True iff every resulting stack is a valid complete
    group (set / pure run / rb run). Used as a post-emission
    self-check so that a buggy emitter CANNOT ship a sequence
    that would leave the board with incomplete stacks at turn
    end. Enforced invariant: tricks never wreck the board."""
    sim = _copy_board(board)
    for p in prims:
        kind = p.get("action")
        if kind == "split":
            sim = _apply_split(sim, p["stack_index"], p["card_index"])
        elif kind == "move_stack":
            sim = _apply_move(sim, p["stack_index"], p["new_loc"])
        elif kind == "merge_stack":
            sim = _apply_merge_stack(sim, p["source_stack"],
                                     p["target_stack"], p.get("side", "right"))
        elif kind == "merge_hand":
            sim = _apply_merge_hand(sim, p["target_stack"],
                                    p["hand_card"], p.get("side", "right"))
        elif kind == "place_hand":
            sim = _apply_place_hand(sim, p["hand_card"], p["loc"])
    for i, s in enumerate(sim):
        cards = [bc["card"] for bc in s["board_cards"]]
        kind = _classify(cards)
        if kind == "other":
            return False, f"stack {i} ({cards}) is incomplete"
    return True, None


def enumerate_plays(hand, board):
    """Return list of {trick_id, primitives} — one per firing trick
    in priority order whose emission actually leaves a clean board.
    A trick that would violate the invariant is refused entirely.

    Used by the agent (via `choose_play`) and by the DSL
    conformance runner (which tests the full enumeration against
    scenario expectations — the DSL op name stays
    `build_suggestions` because the concept is shared with Elm,
    where the output feeds a human-facing hint surface).
    """
    out = []
    for name, fn in TRICK_ORDER:
        prims = fn(hand, board)
        if prims is None:
            continue
        ok, reason = _invariant_clean(board, prims)
        if not ok:
            # Silently refuse. The emitter for this trick has a
            # bug or this particular state falls outside the
            # emitter's supported shapes. Either way we don't
            # hand the agent a board-wrecking sequence.
            continue
        out.append({"trick_id": name, "primitives": prims})
    return out


def choose_play(hand, board):
    """The agent's next-play decision. Returns the top firing
    trick's `{trick_id, primitives}` dict, or `None` if no trick
    fires.

    Thin wrapper over `enumerate_plays` — this is what the
    auto-player uses in its turn loop. Named to reflect what the
    Python side does (pick a play) as opposed to what Elm does
    (build hint suggestions for a human to choose from).
    """
    plays = enumerate_plays(hand, board)
    return plays[0] if plays else None


# ============================================================
# Follow-up merge — orthogonal to tricks.
#
# After a trick fires, the board has at least one "new" stack.
# New stacks can have intra-board merge partners that didn't
# exist pre-trick. This function scans the board and emits
# merge_stack primitives for any pair that combines into a
# valid complete group.
#
# Not a trick: it doesn't consume hand cards, has no place in
# the priority order, and runs unconditionally after any play
# that changed the board. "Merging stacks is just something
# you should do."
# ============================================================


def _stack_sig(stack):
    """Hashable signature of a stack's card sequence. Used to
    locate a stack in a later board state after indices have
    shifted (merges remove two stacks and append one)."""
    return tuple(
        (bc["card"]["value"], bc["card"]["suit"], bc["card"]["origin_deck"])
        for bc in stack["board_cards"]
    )


def _stack_index_by_sig(board, sig):
    for i, s in enumerate(board):
        if _stack_sig(s) == sig:
            return i
    return None


def find_follow_up_merges(board):
    """Scan every pair of stacks; for each pair that forms a
    valid complete group (set / pure_run / rb_run) when merged
    on either side, emit a merge_stack primitive. Returns a
    list of primitives.

    V1: single pass, no cascade. Each stack participates in at
    most one merge per call — a freshly-merged stack doesn't
    get re-scanned for further partners in the same call. If
    two independent pairs both merge cleanly, both are emitted.

    Scan is quadratic but N is small (~10 stacks). Pair
    selection is deterministic: iterate src in ascending order,
    take the first tgt that merges cleanly.
    """
    # Collect independent mergeable pairs on the initial board.
    consumed = set()
    pairs = []  # [(src_sig, tgt_sig, side)]
    n = len(board)
    for src in range(n):
        if src in consumed:
            continue
        src_cards = [bc["card"] for bc in board[src]["board_cards"]]
        for tgt in range(n):
            if tgt == src or tgt in consumed:
                continue
            tgt_cards = [bc["card"] for bc in board[tgt]["board_cards"]]
            matched_side = _pair_merge_side(src_cards, tgt_cards)
            if matched_side is not None:
                pairs.append((_stack_sig(board[src]),
                              _stack_sig(board[tgt]),
                              matched_side))
                consumed.add(src)
                consumed.add(tgt)
                break

    # Apply each pair in order, looking up current indices via
    # signature so the emitted primitives are correct against
    # the evolving sim state. Delegates the per-pair physical
    # execution to `_plan_merge_stack`: in-place merge when the
    # merged stack fits at the target's current loc, otherwise
    # a move_stack (of the target) to a hole sized for the
    # eventual stack, THEN the merge. Same algorithm as
    # `_plan_merge_hand` for hand-to-board merges.
    prims = []
    sim = _copy_board(board)
    for src_sig, tgt_sig, side in pairs:
        cur_src = _stack_index_by_sig(sim, src_sig)
        cur_tgt = _stack_index_by_sig(sim, tgt_sig)
        if cur_src is None or cur_tgt is None:
            continue
        step_prims, sim = _plan_merge_stack(sim, cur_src, cur_tgt, side)
        prims.extend(step_prims)
    return prims


def _pair_merge_side(src_cards, tgt_cards):
    """If src+tgt merge cleanly on some side, return that side.
    Returns None if neither side produces a complete group."""
    for side in ("left", "right"):
        combined = (src_cards + tgt_cards) if side == "left" else (tgt_cards + src_cards)
        if _classify(combined) in ("set", "pure_run", "rb_run"):
            return side
    return None


