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

import bfs_solver as bs
import primitives


def step_to_primitives(desc, board):
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
    t = desc["type"]
    if t == "extract_absorb":
        return _extract_absorb(desc, board)
    if t == "free_pull":
        return _free_pull(desc, board)
    if t == "push":
        return _push(desc, board)
    if t == "splice":
        return _splice(desc, board)
    if t == "shift":
        return _shift(desc, board)
    raise NotImplementedError(f"verb type {t!r} not supported")


# --- helpers --------------------------------------------------

def _split_after(sim, stack_content, k):
    """Emit a split primitive that puts the first `k` cards of
    `stack_content` into the left half and the rest into the
    right half. Translates to the underlying primitive
    `card_index` via the leftSplit/rightSplit convention in
    `strategy._apply_split` (left_count = ci+1 for ci+1 <= n//2;
    left_count = ci otherwise). Returns (prim, new_sim)."""
    n = len(stack_content)
    if not 1 <= k <= n - 1:
        raise ValueError(
            f"split-after k={k} out of range for n={n}")
    # Choose ci so left_count == k.
    if k <= n // 2:
        ci = k - 1  # leftSplit
    else:
        ci = k      # rightSplit
    si = primitives.find_stack_index(sim, stack_content)
    prim = {"action": "split", "stack_index": si, "card_index": ci}
    return prim, primitives.apply_locally(sim, prim)


def _merge(sim, source_content, target_content, side):
    """Emit a merge_stack primitive matching by content,
    advance `sim`, return (prim, new_sim)."""
    src = primitives.find_stack_index(sim, source_content)
    tgt = primitives.find_stack_index(sim, target_content)
    prim = {
        "action": "merge_stack",
        "source_stack": src,
        "target_stack": tgt,
        "side": side,
    }
    return prim, primitives.apply_locally(sim, prim)


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
        prim, sim = _split_after(sim, stack_content, 1)
        out.append(prim)
        return out, sim, [ext_card], [list(stack_content[1:])]
    if ci == n - 1 and n > 1:
        # Split off the last card: left=s[:-1], right=[s[-1]].
        prim, sim = _split_after(sim, stack_content, n - 1)
        out.append(prim)
        return out, sim, [ext_card], [list(stack_content[:-1])]
    # Interior: split after ci → [s[:ci]], [s[ci:]]. Then split
    # [s[ci:]] after 1 → [s[ci]] + [s[ci+1:]].
    prim, sim = _split_after(sim, stack_content, ci)
    out.append(prim)
    right_chunk = list(stack_content[ci:])
    prim, sim = _split_after(sim, right_chunk, 1)
    out.append(prim)
    return out, sim, [ext_card], [
        list(stack_content[:ci]),
        list(stack_content[ci + 1:]),
    ]


def _extract_absorb(desc, board):
    """Peel/pluck/yank/steal a card from a HELPER stack and
    merge it onto target. For set extracts we may need a
    follow-up merge to reconstitute the legal remnant."""
    source = list(desc["source"])
    ext_card = desc["ext_card"]
    target_before = list(desc["target_before"])
    side = desc["side"]
    verb = desc["verb"]
    kind = bs.classify(source)
    ci = source.index(ext_card)

    sim = list(board)
    out = []

    if verb in ("peel", "pluck", "yank"):
        # Same physical isolation regardless of verb. The
        # difference between peel/pluck/yank is which spawned
        # pieces qualify as helpers vs trouble — that's a
        # logical-layer concern; physically all are split-then-
        # merge.
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
            prim, sim = _merge(sim, tail_chunk, left_chunk,
                               "right")
            out.append(prim)

    elif verb == "steal" and kind in ("pure_run", "rb_run"):
        # End-steal of length-3 run: ci is 0 or 2.
        prims, sim, ext_singleton, _ = _isolate_card(
            sim, source, ci, kind)
        out.extend(prims)

    elif verb == "steal" and kind == "set":
        # Dismantle length-3 set into 3 singletons.
        prim, sim = _split_after(sim, source, 1)
        out.append(prim)
        # Now [source[0]] and [source[1], source[2]] exist.
        prim, sim = _split_after(sim, list(source[1:]), 1)
        out.append(prim)
        # Now three singletons: [source[0]], [source[1]],
        # [source[2]]. Identify the desired one by content.
        ext_singleton = [ext_card]

    else:
        raise NotImplementedError(
            f"verb {verb!r} kind {kind!r}")

    # Merge ext_card singleton onto target.
    prim, sim = _merge(sim, ext_singleton, target_before, side)
    out.append(prim)
    return out


# --- free pull / push / push-merge ---------------------------

def _free_pull(desc, board):
    """A loose TROUBLE singleton is already on the board;
    merge it onto target."""
    loose = desc["loose"]
    target_before = list(desc["target_before"])
    side = desc["side"]
    sim = list(board)
    prim, _sim = _merge(sim, [loose], target_before, side)
    return [prim]


def _push(desc, board):
    """Push a TROUBLE singleton or 2-partial onto a HELPER
    stack. The trouble cards are already on the board as a
    single stack (singleton or 2-partial)."""
    trouble_before = list(desc["trouble_before"])
    target_before = list(desc["target_before"])
    side = desc["side"]
    sim = list(board)
    prim, _sim = _merge(sim, trouble_before, target_before, side)
    return [prim]


# --- splice --------------------------------------------------

def _splice(desc, board):
    """Insert a TROUBLE singleton into a HELPER pure/rb run.
    Physically: split the run at k, then merge the loose
    onto the half it joins (per `side`). The other half
    persists as new_helper-side stack untouched."""
    loose = desc["loose"]
    src = list(desc["source"])
    k = desc["k"]
    side = desc["side"]
    left = list(desc["left_result"])
    right = list(desc["right_result"])

    sim = list(board)
    prim, sim = _split_after(sim, src, k)
    out = [prim]

    # After split: [src[:k]] and [src[k:]] both on board.
    # `side == "left"`  : loose joins LEFT half  → left = src[:k] + [loose]
    # `side == "right"` : loose joins RIGHT half → right = [loose] + src[k:]
    if side == "left":
        # Merge loose onto src[:k] right.
        prim, sim = _merge(sim, [loose], list(src[:k]), "right")
    else:
        # Merge loose onto src[k:] left.
        prim, sim = _merge(sim, [loose], list(src[k:]), "left")
    out.append(prim)

    # Sanity: the resulting halves should match desc.
    # (No-op if the merge sides are correctly chosen.)
    _ = (left, right)
    return out


# --- shift ---------------------------------------------------

def _shift(desc, board):
    """Length-3 run end-steal with replacement: peel p_card
    from a donor, push it onto source's opposite end, pop the
    stolen card, absorb it onto target. Source stays length-3
    legal; donor stays legal; no trouble is spawned."""
    source = list(desc["source"])
    donor = list(desc["donor"])
    stolen = desc["stolen"]
    p_card = desc["p_card"]
    which_end = desc["which_end"]
    target_before = list(desc["target_before"])
    side = desc["side"]

    sim = list(board)
    out = []

    # 1. Peel p_card from donor (donor is length 4+).
    pi = donor.index(p_card)
    kind = bs.classify(donor)
    prims, sim, _ext, donor_remnants = _isolate_card(
        sim, donor, pi, kind)
    out.extend(prims)
    if kind == "set" and len(donor_remnants) == 2:
        left_chunk, tail_chunk = donor_remnants
        prim, sim = _merge(sim, tail_chunk, left_chunk, "right")
        out.append(prim)

    # 2. Split source to isolate the stolen card.
    if which_end == 2:
        # Stolen at right end; split source after 2 →
        # [source[:2]] + [stolen].
        prim, sim = _split_after(sim, source, 2)
        out.append(prim)
        source_remainder = list(source[:2])
        # Merge p onto remainder LEFT → [p, a, b].
        prim, sim = _merge(sim, [p_card], source_remainder, "left")
        out.append(prim)
    else:
        # Stolen at left end; split source after 1 →
        # [stolen] + [source[1:]].
        prim, sim = _split_after(sim, source, 1)
        out.append(prim)
        source_remainder = list(source[1:])
        # Merge p onto remainder RIGHT → [b, c, p].
        prim, sim = _merge(sim, [p_card], source_remainder, "right")
        out.append(prim)

    # 3. Merge stolen onto target.
    prim, sim = _merge(sim, [stolen], target_before, side)
    out.append(prim)
    return out
