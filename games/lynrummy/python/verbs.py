"""
verbs.py — the VERB → PRIMITIVE layer.

Pipeline: VERBs → PRIMITIVEs → GESTUREs.
- VERBs are the high-level moves the BFS solver emits as DSL
  lines (extract_absorb / free_pull / push / splice / shift).
  Each carries a `desc` dict with the structural details.
- PRIMITIVEs are atomic UI ops (split, merge_stack, etc.) —
  see `primitives.py`.

Each verb is decomposed into a deterministic sequence of
primitives. Stacks are identified by CONTENT (tuple-list of
cards) at each step rather than by symbolic indices: after
each primitive is applied locally, the next primitive looks
up its inputs by content match. This avoids the index-shuffle
bookkeeping that the server's split/merge semantics impose
(split removes orig + appends two; merge_stack removes both +
appends one).
"""

import cards
import geometry
import primitives
import strategy
from move import (
    ExtractAbsorbDesc, FreePullDesc, PushDesc,
    ShiftDesc, SpliceDesc,
)


def move_to_primitives(desc, board):
    """Decompose one BFS DSL move into UI primitives.

    `desc` is the BFS solver's per-move dict. `board` is the
    server-state board (list of stack dicts) at the moment
    just BEFORE this move executes. Returns a list of
    primitives whose stack_index fields are concrete (resolved
    against the simulated post-each-primitive board).

    Every primitive's stack indexes are content-resolved per
    step, so callers can apply them sequentially through
    `primitives.apply_locally` and the indices will stay
    valid.
    """
    t = desc.type
    if isinstance(desc, ExtractAbsorbDesc):
        return _extract_absorb_prims(desc, board)
    if isinstance(desc, FreePullDesc):
        return _free_pull_prims(desc, board)
    if isinstance(desc, PushDesc):
        return _push_prims(desc, board)
    if isinstance(desc, SpliceDesc):
        return _splice_prims(desc, board)
    if isinstance(desc, ShiftDesc):
        return _shift_prims(desc, board)
    raise NotImplementedError(f"verb type {t!r} not supported")


# --- helpers --------------------------------------------------

def _plan_split_after(sim, stack_content, k):
    """Plan a split that puts the first `k` cards of
    `stack_content` into the left half and the rest into the
    right half. For end splits (k == 1 or k == n-1) emits one
    primitive. For INTERIOR splits the donor is pre-moved into
    a 4-side-clear region first per Steve's 2026-04-23 rule —
    the bump distances after a mid-stack split are
    unpredictable and can spawn pieces into neighbors.

    Returns (prims, new_sim)."""
    n = len(stack_content)
    if not 1 <= k <= n - 1:
        raise ValueError(
            f"split-after k={k} out of range for n={n}")

    out = []
    interior = k != 1 and k != n - 1
    if interior:
        si = primitives.find_stack_index(sim, stack_content)
        others = [s for i, s in enumerate(sim) if i != si]
        new_loc = geometry.find_open_loc(others, card_count=n)
        cur_loc = sim[si]["loc"]
        if new_loc != cur_loc:
            move = {"action": "move_stack",
                    "stack_index": si, "new_loc": new_loc}
            out.append(move)
            sim = primitives.apply_locally(sim, move)

    # Choose ci so left_count == k (per strategy._apply_split's
    # leftSplit/rightSplit convention).
    if k <= n // 2:
        ci = k - 1
    else:
        ci = k
    si = primitives.find_stack_index(sim, stack_content)
    split = {"action": "split", "stack_index": si,
             "card_index": ci}
    out.append(split)
    return out, primitives.apply_locally(sim, split)


def _plan_merge(sim, source_content, target_content, side):
    """Plan a content-addressed merge_stack with pre-flight
    geometry — delegates to `strategy._plan_merge_stack`
    which tries merge-in-place first and otherwise pre-moves
    the target into a hole sized for the EVENTUAL stack.

    Returns (prims, new_sim)."""
    src = primitives.find_stack_index(sim, source_content)
    tgt = primitives.find_stack_index(sim, target_content)
    return strategy._plan_merge_stack(sim, src, tgt, side)


# --- extract + absorb ----------------------------------------

def _isolate_card(sim, stack_content, ci, kind):
    """Generate the split primitives needed to leave the card
    at index `ci` of `stack_content` as a singleton stack on
    `sim`. Returns (prims, new_sim, ext_card_content,
    remnant_pieces) where remnant_pieces is the list of
    leftover stack contents the splits create."""
    n = len(stack_content)
    ext_card = stack_content[ci]
    out = []

    if ci == 0 and n > 1:
        # Split off the first card: left=[s[0]], right=s[1:].
        prims, sim = _plan_split_after(sim, stack_content, 1)
        out.extend(prims)
        return out, sim, [ext_card], [list(stack_content[1:])]
    if ci == n - 1 and n > 1:
        # Split off the last card: left=s[:-1], right=[s[-1]].
        prims, sim = _plan_split_after(sim, stack_content, n - 1)
        out.extend(prims)
        return out, sim, [ext_card], [list(stack_content[:-1])]
    # Interior: split after ci → [s[:ci]], [s[ci:]]. Then split
    # [s[ci:]] after 1 → [s[ci]] + [s[ci+1:]].
    prims, sim = _plan_split_after(sim, stack_content, ci)
    out.extend(prims)
    right_chunk = list(stack_content[ci:])
    prims, sim = _plan_split_after(sim, right_chunk, 1)
    out.extend(prims)
    return out, sim, [ext_card], [
        list(stack_content[:ci]),
        list(stack_content[ci + 1:]),
    ]


def _extract_absorb_prims(desc, board):
    """Peel/pluck/yank/steal a card from a HELPER stack and
    merge it onto target. For set extracts we may need a
    follow-up merge to reconstitute the legal remnant."""
    source = list(desc.source)
    ext_card = desc.ext_card
    target_before = list(desc.target_before)
    side = desc.side
    verb = desc.verb
    kind = cards.classify(source)
    ci = source.index(ext_card)

    sim = list(board)
    out = []

    if verb in ("peel", "pluck", "yank", "split_out"):
        # Same physical isolation regardless of verb. The
        # difference between peel/pluck/yank/split_out is which
        # spawned pieces qualify as helpers vs trouble — that's
        # a logical-layer concern; physically all are split-
        # then-merge.
        prims, sim, ext_singleton, remnants = _isolate_card(
            sim, source, ci, kind)
        out.extend(prims)

        # Set peel from interior position: physically the
        # remnant is split into TWO pieces (left chunk + tail
        # chunk). The BFS solver treats the remnant as a
        # single legal set [a, b, d]; we need to merge the
        # two physical pieces back together to form it.
        if kind == "set" and len(remnants) == 2:
            left_chunk, tail_chunk = remnants
            # Merge tail_chunk onto left_chunk's right end.
            prims, sim = _plan_merge(sim, tail_chunk, left_chunk,
                                     "right")
            out.extend(prims)

    elif verb == "steal" and kind in ("pure_run", "rb_run"):
        # End-steal of length-3 run: ci is 0 or 2.
        prims, sim, ext_singleton, _ = _isolate_card(
            sim, source, ci, kind)
        out.extend(prims)

    elif verb == "steal" and kind == "set":
        # Dismantle length-3 set into 3 singletons.
        prims, sim = _plan_split_after(sim, source, 1)
        out.extend(prims)
        # Now [source[0]] and [source[1], source[2]] exist.
        prims, sim = _plan_split_after(sim, list(source[1:]), 1)
        out.extend(prims)
        # Now three singletons: [source[0]], [source[1]],
        # [source[2]]. Identify the desired one by content.
        ext_singleton = [ext_card]

    else:
        raise NotImplementedError(
            f"verb {verb!r} kind {kind!r}")

    # Merge ext_card singleton onto target.
    prims, sim = _plan_merge(sim, ext_singleton, target_before, side)
    out.extend(prims)
    return out


# --- free pull / push / push-merge ---------------------------

def _free_pull_prims(desc, board):
    """A loose TROUBLE singleton is already on the board;
    merge it onto target."""
    loose = desc.loose
    target_before = list(desc.target_before)
    side = desc.side
    prims, _sim = _plan_merge(list(board), [loose],
                              target_before, side)
    return prims


def _push_prims(desc, board):
    """Push a TROUBLE singleton or 2-partial onto a HELPER
    stack. The trouble cards are already on the board as a
    single stack (singleton or 2-partial)."""
    trouble_before = list(desc.trouble_before)
    target_before = list(desc.target_before)
    side = desc.side
    prims, _sim = _plan_merge(list(board), trouble_before,
                              target_before, side)
    return prims


# --- splice --------------------------------------------------

def _splice_prims(desc, board):
    """Insert a TROUBLE singleton into a HELPER pure/rb run.
    Physically: split the run at k, then merge the loose onto
    the half it joins (per `side`). The other half persists
    untouched."""
    loose = desc.loose
    src = list(desc.source)
    k = desc.k
    side = desc.side

    sim = list(board)
    prims, sim = _plan_split_after(sim, src, k)
    # `side == "left"`  : loose joins LEFT half  → src[:k] + [loose]
    # `side == "right"` : loose joins RIGHT half → [loose] + src[k:]
    if side == "left":
        merge_prims, _ = _plan_merge(
            sim, [loose], list(src[:k]), "right")
    else:
        merge_prims, _ = _plan_merge(
            sim, [loose], list(src[k:]), "left")
    return list(prims) + merge_prims


# --- shift ---------------------------------------------------

def _shift_prims(desc, board):
    """Shift verb: p_card moves from donor INTO source's
    opposite-end position, displacing stolen, which then
    absorbs onto target.

    The primitive ordering reflects the LOGIC of the shift —
    the user sees `p_card` physically join `source` (the
    moment the swap happens), then `stolen` pop out and
    absorb. The earlier ordering pre-disassembled the source
    before `p_card` interacted with it, which obscured the
    swap — fixed 2026-04-27 per Steve's "primitives should
    demonstrate the logic" reframing.

    Sequence:
      1. Isolate `p_card` from donor (split, plus
         interior-set reassemble if applicable).
      2. Merge `p_card` onto source on the OPPOSITE side from
         `stolen`. Source becomes augmented (length+1).
      3. Pop `stolen` off the augmented source by splitting at
         its end.
      4. Merge stolen onto target."""
    source = list(desc.source)
    donor = list(desc.donor)
    stolen = desc.stolen
    p_card = desc.p_card
    which_end = desc.which_end
    target_before = list(desc.target_before)
    side = desc.side

    sim = list(board)
    out = []

    # 1. Isolate p_card from donor.
    pi = donor.index(p_card)
    kind = cards.classify(donor)
    prims, sim, _ext, donor_remnants = _isolate_card(
        sim, donor, pi, kind)
    out.extend(prims)
    if kind == "set" and len(donor_remnants) == 2:
        left_chunk, tail_chunk = donor_remnants
        prims, sim = _plan_merge(sim, tail_chunk, left_chunk, "right")
        out.extend(prims)

    # 2. Merge p_card onto source. p_card joins the OPPOSITE
    # side from stolen, so that splitting at the stolen end
    # next yields the correct new_source.
    if which_end == 0:
        # stolen at LEFT of source; p_card joins RIGHT.
        prims, sim = _plan_merge(sim, [p_card], source, "right")
        augmented_source = source + [p_card]
        split_k = 1
    else:
        # stolen at RIGHT of source; p_card joins LEFT.
        prims, sim = _plan_merge(sim, [p_card], source, "left")
        augmented_source = [p_card] + source
        split_k = len(source)
    out.extend(prims)

    # 3. Pop stolen off the augmented source.
    prims, sim = _plan_split_after(sim, augmented_source, split_k)
    out.extend(prims)

    # 4. Merge stolen onto target.
    prims, sim = _plan_merge(sim, [stolen], target_before, side)
    out.extend(prims)
    return out
