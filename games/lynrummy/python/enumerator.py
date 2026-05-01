"""
enumerator.py — BFS move generator + focus rule + doomed-
third filter + extractable index.

The Python equivalent of `Game.Agent.Enumerator.elm`.

Internally operates on `ClassifiedCardStack`-shaped Buckets:
each bucket holds CCS objects, not raw card lists. The shape
is enforced at the BFS boundary by `solve_state_with_descs`
(via `classify_buckets`). Descriptors continue to hold raw
card tuples / lists for plan-line stability and downstream
serialization compatibility.

Entry: `enumerate_moves` accepts either a raw `Buckets`
(card-list stacks) or a CCS-shaped `Buckets`. Raw input is
classified once via `classify_buckets`. Internal sites pass
CCS-shaped Buckets directly so the coercion is a fast no-op.
"""

from buckets import Buckets, FocusedState, classify_buckets
from rules import RED, is_partial_ok, neighbors
from classified_card_stack import (
    ClassifiedCardStack,
    KIND_RUN, KIND_RB, KIND_SET,
    KIND_PAIR_RUN, KIND_PAIR_RB, KIND_PAIR_SET,
    KIND_SINGLETON,
    classify_stack, singleton, to_singletons,
    verb_for_position,
    peel, pluck, yank, steal, split_out,
    kind_after_absorb_right, kind_after_absorb_left,
    absorb_right, absorb_left,
    kinds_after_splice, splice,
)
from move import (
    ExtractAbsorbDesc, FreePullDesc, PushDesc,
    ShiftDesc, SpliceDesc,
)


# Length-3+ legal kinds. Used by graduate / push / engulf to
# decide whether a merge result has reached a complete group.
_LEGAL_LEN3_KINDS = (KIND_RUN, KIND_RB, KIND_SET)
_RUN_FAMILY_KINDS = (KIND_RUN, KIND_RB)


# --- Bucket transitions (pure helpers) ---

def drop_at(stacks, idx):
    """Stacks list with index `idx` dropped. Pure."""
    return stacks[:idx] + stacks[idx + 1:]


def remove_absorber(bucket_name, idx, trouble, growing):
    """Drop the absorber at (bucket_name, idx) from its bucket;
    the other bucket passes through unchanged. Returns
    (new_trouble, new_growing). Pure."""
    if bucket_name == "trouble":
        return drop_at(trouble, idx), list(growing)
    return list(trouble), drop_at(growing, idx)


def graduate(merged, growing, complete):
    """If `merged` (a CCS) classifies as a complete legal group,
    append it to COMPLETE; otherwise append it to GROWING.
    Returns (new_growing, new_complete, graduated_flag). Pure."""
    if merged.kind in _LEGAL_LEN3_KINDS:
        return list(growing), complete + [merged], True
    return growing + [merged], list(complete), False


# --- Doomed-third filter ---

def completion_inventory(helper, trouble):
    """Set of (value, suit) shapes available as candidate
    "third cards" to complete some 2-partial elsewhere on the
    board. Helper cards (any position — peelable, pluckable,
    or shiftable) plus trouble singletons (free-pullable).

    Excludes:
      - Trouble 2-partial members: they can't independently
        move; the whole pair pushes or stays put.
      - Growing: sealed against extracts; its cards can't
        become a third for OTHER partials.
      - Complete: sealed forever.
    """
    inv = set()
    for stack in helper:
        for c in stack.cards:
            inv.add((c[0], c[1]))
    for stack in trouble:
        if stack.n == 1:
            c = stack.cards[0]
            inv.add((c[0], c[1]))
    return inv


def completion_shapes(partial):
    """Return the set of (value, suit) shapes that would
    complete a 2-card `partial` into a legal length-3 stack.
    Caller compares against `completion_inventory`.

    `partial` is a 2-card iterable (CCS, tuple, or list)."""
    c1, c2 = partial[0], partial[1]
    v1, s1, _ = c1
    v2, s2, _ = c2
    if v1 == v2:
        # Set partial — distinct-suit third of same value.
        return {(v1, s) for s in range(4)
                if s != s1 and s != s2}
    # Run partial: c1, c2 consecutive (c2 = c1's successor).
    pred_v = 13 if v1 == 1 else v1 - 1
    succ_v = 1 if v2 == 13 else v2 + 1
    if s1 == s2:
        # Pure run — same-suit extensions on either end.
        return {(pred_v, s1), (succ_v, s2)}
    # rb run — opposite-color extensions on either end.
    pred_shapes = {(pred_v, s) for s in range(4)
                   if (s in RED) != (s1 in RED)}
    succ_shapes = {(succ_v, s) for s in range(4)
                   if (s in RED) != (s2 in RED)}
    return pred_shapes | succ_shapes


def has_doomed_third(partial, inventory):
    """True if NO completion shape for `partial` exists in
    `inventory` — i.e., the partial is doomed to remain a
    2-partial because no third card is available anywhere
    on the (helper + trouble-singletons) part of the board.

    Cheap pruning: skip moves that produce doomed partials
    before adding them to the BFS frontier."""
    return not (completion_shapes(partial) & inventory)


def admissible_merged(merged, completion_inv):
    """Gate every absorbed result. `merged` is a CCS — it
    classified successfully already (probe returned non-None),
    so legality is given. Only the doomed-third gate fires for
    length-2 results."""
    if merged.n == 2 and has_doomed_third(merged.cards, completion_inv):
        return False
    return True


# --- Extract dispatch ---

def do_extract(helper, src_idx, ci, verb):
    """Extract a card from HELPER. Returns
    (new_helper, spawned_trouble_pieces, ext_card, source_before_cards).

    `verb` is the precomputed verb_for_position(source, ci). Each
    verb has a custom executor that uses the parent kind family +
    length to derive the remnant kinds without re-classifying.

    Helper pieces: length-3+ stacks (run / rb / set) — stay in
    HELPER. Spawned pieces: length-1/2 (singleton / pair_*) —
    spawn to TROUBLE.

    Returns:
      - new_helper: list of CCS (helper without src + helper_pieces)
      - spawned: list of CCS (spawned trouble pieces)
      - ext_card: raw (value, suit, deck) tuple
      - source_before_cards: raw card tuple (for desc stability)
    """
    source = helper[src_idx]
    source_before_cards = list(source.cards)
    helper_pieces, spawned = _extract_pieces(source, ci, verb)
    new_helper = (helper[:src_idx] + helper[src_idx + 1:]
                  + helper_pieces)
    return new_helper, spawned, source.cards[ci], source_before_cards


def _extract_pieces(source, ci, verb):
    """Dispatch the extract verb to its CCS executor. Returns
    (helper_pieces, spawned_pieces) — each piece a CCS, each
    list bucket-routed by length (3+ → helper, <3 → trouble)."""
    if verb == "peel":
        _ext, remnant = peel(source, ci)
        return [remnant], []
    if verb == "pluck":
        _ext, left, right = pluck(source, ci)
        # Both halves length-3+ by can_pluck precondition.
        return [left, right], []
    if verb == "yank":
        _ext, left, right = yank(source, ci)
        helpers = []
        spawned = []
        for piece in (left, right):
            (helpers if piece.n >= 3 else spawned).append(piece)
        return helpers, spawned
    if verb == "split_out":
        _ext, left, right = split_out(source, ci)
        # Both halves are singletons by precondition.
        return [], [left, right]
    if verb == "steal":
        pieces = steal(source, ci)
        # steal returns (extracted, ...rest). For sets: rest is N-1
        # singletons. For run/rb: rest is one length-2 partial.
        return [], list(pieces[1:])
    raise ValueError(f"unknown verb {verb}")


def extractable_index(helper):
    """One-pass scan over HELPER, building a map from
    `(value, suit)` shape → list of (helper_idx, ci, verb).

    Caller (the absorber loop) inverts the old "for-each-card
    check shape" pattern into a direct "for-each-target-shape
    lookup" — helpers whose cards aren't neighbors of any
    absorber are never visited. `verb_for_position` runs once
    per (helper × ci); kind is read directly off each CCS, no
    classify pass needed."""
    out = {}
    for hi, src in enumerate(helper):
        for ci, c in enumerate(src.cards):
            verb = verb_for_position(src, ci)
            if verb is None:
                continue
            out.setdefault((c[0], c[1]), []).append((hi, ci, verb))
    return out


# --- Push / engulf merge primitive ---

def _absorb_seq(target, cards_to_add, side):
    """Sequentially absorb each card in `cards_to_add` onto `target`
    via the probe + executor pair on `side`. Returns the resulting
    CCS, or None if any absorption step is illegal.

    For side='right': cards append in order to the right of target.
    For side='left':  cards prepend in REVERSE order so the resulting
    stack is `cards_to_add ++ target.cards` (i.e., the leftmost card
    of cards_to_add ends up leftmost in the merged stack)."""
    current = target
    if side == "right":
        for c in cards_to_add:
            new_kind = kind_after_absorb_right(current, c)
            if new_kind is None:
                return None
            current = absorb_right(current, c, new_kind)
        return current
    # side == "left": prepend in reverse so each card lands at the
    # current left edge, accumulating to the original left-prepended
    # order overall.
    for c in reversed(cards_to_add):
        new_kind = kind_after_absorb_left(current, c)
        if new_kind is None:
            return None
        current = absorb_left(current, c, new_kind)
    return current


# --- Move generator ---

def _maybe_classify(buckets):
    """Coerce raw-list buckets to CCS-shaped buckets. No-op if
    already CCS. Allows test entry points to pass raw 4-tuples.
    Will be retired in a later integration step once all callers
    construct CCS-shaped buckets at their own boundaries."""
    if not isinstance(buckets, Buckets):
        buckets = Buckets(*buckets)
    # Detect: first non-empty stack — if it's a CCS, no work.
    for bucket in buckets:
        for stack in bucket:
            if isinstance(stack, ClassifiedCardStack):
                return buckets
            return classify_buckets(buckets)
    # All buckets empty — nothing to classify, but ensure typed.
    return buckets


def enumerate_moves(state):
    """Yield (description_dict, new_state) for every legal
    1-line extension. `state` is a Buckets of CCS-shaped stacks
    (raw card-list input is coerced once at entry)."""
    state = _maybe_classify(state)
    helper, trouble, growing, complete = state
    completion_inv = completion_inventory(helper, trouble)

    # State-level doomed-growing filter. If any growing
    # 2-partial has no completion candidate in this state's
    # (helper + trouble-singletons) inventory, the partial
    # will NEVER graduate. The state is dead — yield nothing.
    for g in growing:
        if g.n == 2:
            shapes = completion_shapes(g.cards)
            if not (shapes & completion_inv):
                return

    extractable = extractable_index(helper)

    # Pre-filter helpers by their splice / shift eligibility
    # so the inner loops below don't rescan all of HELPER each
    # iteration. Splice wants length-4+ pure/rb runs; shift
    # wants length-3 pure/rb runs.
    splice_helpers = [
        (hi, h)
        for hi, h in enumerate(helper)
        if h.n >= 4 and h.kind in _RUN_FAMILY_KINDS
    ]
    shift_helpers = [
        (hi, h)
        for hi, h in enumerate(helper)
        if h.n == 3 and h.kind in _RUN_FAMILY_KINDS
    ]

    # All targets for absorption (move type a). Each entry:
    # (bucket_name, idx_in_bucket, target_stack, sorted_shapes,
    # shapes_set). Sorted shapes drive deterministic iteration
    # in the absorb loop (matching the Elm port's order); the
    # set form is for O(1) membership tests in free-pull / shift.
    absorber_shapes = []
    for bucket, idx, t in (
        [("trouble", ti, t) for ti, t in enumerate(trouble)]
        + [("growing", gi, g) for gi, g in enumerate(growing)]
    ):
        s_set = set().union(*(neighbors(c) for c in t.cards))
        absorber_shapes.append((bucket, idx, t, sorted(s_set), s_set))

    for bucket, idx, target, shapes, shapes_set in absorber_shapes:
        # Source: HELPER stack via extract. Inverted loop —
        # iterate the ABSORBER's neighbor shapes and look up
        # extractable cards directly, instead of walking every
        # helper × position to filter.
        for shape in shapes:
            for hi, ci, verb in extractable.get(shape, ()):
                new_helper, spawned, ext_card, source_cards = \
                    do_extract(helper, hi, ci, verb)
                for side in ("right", "left"):
                    if side == "right":
                        new_kind = kind_after_absorb_right(target, ext_card)
                    else:
                        new_kind = kind_after_absorb_left(target, ext_card)
                    if new_kind is None:
                        continue
                    if side == "right":
                        merged = absorb_right(target, ext_card, new_kind)
                    else:
                        merged = absorb_left(target, ext_card, new_kind)
                    if not admissible_merged(merged, completion_inv):
                        continue
                    nt_base, ng = remove_absorber(
                        bucket, idx, trouble, growing)
                    nt = nt_base + spawned
                    ng_final, nc, graduated = graduate(
                        merged, ng, complete)
                    desc = ExtractAbsorbDesc(
                        verb=verb,
                        source=source_cards,
                        ext_card=ext_card,
                        target_before=list(target.cards),
                        target_bucket_before=bucket,
                        result=list(merged.cards),
                        side=side,
                        graduated=graduated,
                        spawned=[list(s.cards) for s in spawned],
                    )
                    yield desc, Buckets(new_helper, nt, ng_final, nc)

        # Source: TROUBLE singleton (free pull).
        for li, loose_stack in enumerate(trouble):
            if loose_stack.n != 1:
                continue
            if bucket == "trouble" and li == idx:
                continue  # can't absorb a stack onto itself
            loose = loose_stack.cards[0]
            if (loose[0], loose[1]) not in shapes_set:
                continue
            for side in ("right", "left"):
                if side == "right":
                    new_kind = kind_after_absorb_right(target, loose)
                else:
                    new_kind = kind_after_absorb_left(target, loose)
                if new_kind is None:
                    continue
                if side == "right":
                    merged = absorb_right(target, loose, new_kind)
                else:
                    merged = absorb_left(target, loose, new_kind)
                if not admissible_merged(merged, completion_inv):
                    continue
                # Both the absorber AND the loose-source come
                # out of TROUBLE — drop both at once.
                nt_base, ng = remove_absorber(
                    bucket, idx, trouble, growing)
                if bucket == "trouble":
                    li_in_base = li - 1 if li > idx else li
                    nt = drop_at(nt_base, li_in_base)
                else:
                    nt = drop_at(nt_base, li)
                ng_final, nc, graduated = graduate(
                    merged, ng, complete)
                desc = FreePullDesc(
                    loose=loose,
                    target_before=list(target.cards),
                    target_bucket_before=bucket,
                    result=list(merged.cards),
                    side=side,
                    graduated=graduated,
                )
                yield desc, Buckets(list(helper), nt, ng_final, nc)

    # Move type (d): SHIFT — when an end-card of a length-3
    # pure/rb run would normally be steal-pulled, scan HELPER for
    # a peel-eligible donor with the right replacement card.
    for bucket, idx, target, _shapes, shapes_set in absorber_shapes:
        for src_idx, source in shift_helpers:
            kind = source.kind  # KIND_RUN or KIND_RB
            for which_end in (0, 2):
                stolen = source.cards[which_end]
                if (stolen[0], stolen[1]) not in shapes_set:
                    continue
                # Compute replacement card requirement at the
                # OPPOSITE end of source.
                if which_end == 2:
                    anchor = source.cards[0]
                    p_value = 13 if anchor[0] == 1 else anchor[0] - 1
                else:
                    anchor = source.cards[2]
                    p_value = 1 if anchor[0] == 13 else anchor[0] + 1
                anchor_red = anchor[1] in RED
                if kind == KIND_RUN:
                    needed_suits = (anchor[1],)
                else:
                    needed_suits = tuple(
                        s for s in range(4)
                        if (s in RED) != anchor_red)
                # Donor candidates: peel-eligible cards in
                # length-4+ helpers — collected across all needed
                # suits then sorted by board position.
                candidates = sorted(
                    (donor_idx, _ci)
                    for p_suit in needed_suits
                    for donor_idx, _ci, verb in
                        extractable.get((p_value, p_suit), ())
                    if verb == "peel"
                    and donor_idx != src_idx
                    and helper[donor_idx].n >= 4
                )
                for donor_idx, _ci in candidates:
                    donor = helper[donor_idx]
                    p_card = donor.cards[_ci]
                    # Compute new_donor via the peel executor.
                    _ext, new_donor = peel(donor, _ci)
                    # Compute new_source: rebuild around p_card.
                    if which_end == 2:
                        new_source_cards = (p_card, source.cards[0], source.cards[1])
                    else:
                        new_source_cards = (source.cards[1], source.cards[2], p_card)
                    new_source = classify_stack(new_source_cards)
                    if new_source is None or new_source.kind != kind:
                        continue
                    # Helper drop: src_idx + donor_idx
                    # (descending so removals don't shift each other),
                    # then append the rebuilt source and shrunken donor.
                    hi_lo = sorted((src_idx, donor_idx), reverse=True)
                    nh = list(helper)
                    for i in hi_lo:
                        nh = drop_at(nh, i)
                    nh = nh + [new_source, new_donor]
                    for absorb_side in ("right", "left"):
                        if absorb_side == "right":
                            new_kind = kind_after_absorb_right(target, stolen)
                        else:
                            new_kind = kind_after_absorb_left(target, stolen)
                        if new_kind is None:
                            continue
                        if absorb_side == "right":
                            merged = absorb_right(target, stolen, new_kind)
                        else:
                            merged = absorb_left(target, stolen, new_kind)
                        if not admissible_merged(merged, completion_inv):
                            continue
                        nt_base, ng = remove_absorber(
                            bucket, idx, trouble, growing)
                        ng_final, nc, graduated = graduate(
                            merged, ng, complete)
                        desc = ShiftDesc(
                            source=list(source.cards),
                            donor=list(donor.cards),
                            stolen=stolen,
                            p_card=p_card,
                            which_end=which_end,
                            new_source=list(new_source.cards),
                            new_donor=list(new_donor.cards),
                            target_before=list(target.cards),
                            target_bucket_before=bucket,
                            merged=list(merged.cards),
                            side=absorb_side,
                            graduated=graduated,
                        )
                        yield desc, Buckets(nh, nt_base, ng_final, nc)

    # Move type (c): splice — insert a TROUBLE singleton into a
    # HELPER pure/rb run length 4+. The run splits around the
    # inserted card; both halves must be legal length-3+.
    for ti, t in enumerate(trouble):
        if t.n != 1:
            continue
        loose = t.cards[0]
        for hi, src in splice_helpers:
            n = src.n
            for k in range(1, n):
                for side in ("left", "right"):
                    kinds = kinds_after_splice(src, loose, k, side)
                    if kinds is None:
                        continue
                    left_kind, right_kind = kinds
                    # Both halves must be length-3+ legal groups
                    # for splice (no length-2 allowed in splice).
                    if (left_kind not in _LEGAL_LEN3_KINDS
                            or right_kind not in _LEGAL_LEN3_KINDS):
                        continue
                    left, right = splice(src, loose, k, side, left_kind, right_kind)
                    nh = drop_at(helper, hi) + [left, right]
                    nt = drop_at(trouble, ti)
                    desc = SpliceDesc(
                        loose=loose,
                        source=list(src.cards),
                        k=k, side=side,
                        left_result=list(left.cards),
                        right_result=list(right.cards),
                    )
                    yield desc, Buckets(nh, nt, list(growing),
                                        list(complete))

    # Move type (b): push a TROUBLE 1- or 2-partial onto a
    # HELPER stack so the result stays legal.
    pushable_trouble = [(ti, t) for ti, t in enumerate(trouble)
                        if t.n <= 2]
    for ti, t in pushable_trouble:
        for hi, h in enumerate(helper):
            for side in ("right", "left"):
                if side == "right":
                    merged = _absorb_seq(h, t.cards, "right")
                else:
                    merged = _absorb_seq(h, t.cards, "left")
                if merged is None:
                    continue
                nh = drop_at(helper, hi) + [merged]
                nt = drop_at(trouble, ti)
                desc = PushDesc(
                    trouble_before=list(t.cards),
                    target_before=list(h.cards),
                    result=list(merged.cards),
                    side=side,
                )
                yield desc, Buckets(nh, nt, list(growing), list(complete))

    # Move type (b'): a GROWING 2-partial engulfs a HELPER stack.
    for gi, g in enumerate(growing):
        for hi, h in enumerate(helper):
            for side in ("right", "left"):
                if side == "right":
                    merged = _absorb_seq(h, g.cards, "right")
                else:
                    merged = _absorb_seq(h, g.cards, "left")
                if merged is None:
                    continue
                nh = drop_at(helper, hi)
                ng = drop_at(growing, gi)
                nc = complete + [merged]
                desc = PushDesc(
                    trouble_before=list(g.cards),
                    target_before=list(h.cards),
                    result=list(merged.cards),
                    side=side,
                )
                yield desc, Buckets(nh, list(trouble), ng, nc)


# --- Focus rule + lineage tracking ---

def move_touches_focus(desc, focus):
    """True iff this move grows or consumes the focus stack
    (identified by content tuple).

    `focus` is a tuple of raw card tuples. Descriptors hold raw
    cards in target_before/trouble_before/loose, so this stays
    a content-based comparison even after CCS integration."""
    t = desc.type
    if isinstance(desc, ExtractAbsorbDesc) or isinstance(desc, ShiftDesc):
        return tuple(desc.target_before) == focus
    if isinstance(desc, FreePullDesc):
        if tuple(desc.target_before) == focus:
            return True
        return len(focus) == 1 and focus[0] == desc.loose
    if isinstance(desc, SpliceDesc):
        return len(focus) == 1 and focus[0] == desc.loose
    if isinstance(desc, PushDesc):
        return tuple(desc.trouble_before) == focus
    return False


def update_lineage(lineage, desc):
    """Compute the new lineage tuple after applying the move.
    Caller has already verified the move touches lineage[0]."""
    focus = lineage[0]
    rest = list(lineage[1:])

    if isinstance(desc, ExtractAbsorbDesc):
        spawned = tuple(tuple(s) for s in desc.spawned)
        if desc.graduated:
            new = rest
        else:
            new = [tuple(desc.result)] + rest
        return tuple(new) + spawned

    if isinstance(desc, ShiftDesc):
        if desc.graduated:
            return tuple(rest)
        return (tuple(desc.merged),) + tuple(rest)

    if isinstance(desc, FreePullDesc):
        target_before = tuple(desc.target_before)
        result = tuple(desc.result)
        graduated = desc.graduated
        if target_before == focus:
            loose_entry = (desc.loose,)
            if loose_entry in rest:
                rest.remove(loose_entry)
            if graduated:
                return tuple(rest)
            return (result,) + tuple(rest)
        if target_before in rest:
            ti = rest.index(target_before)
            if graduated:
                rest.pop(ti)
            else:
                rest[ti] = result
        return tuple(rest)

    return tuple(rest)


# Module flag for analysis tooling.
FOCUS_ENABLED = True


def enumerate_focused(state):
    """Wrap enumerate_moves with the focus-only filter and
    lineage bookkeeping. Yields (desc, new_FocusedState)."""
    if not state.lineage:
        return
    focus = state.lineage[0]
    if not FOCUS_ENABLED:
        for desc, new_buckets in enumerate_moves(state.buckets):
            yield desc, FocusedState(buckets=new_buckets,
                                     lineage=state.lineage)
        return
    for desc, new_buckets in enumerate_moves(state.buckets):
        if not move_touches_focus(desc, focus):
            continue
        new_lineage = update_lineage(state.lineage, desc)
        yield desc, FocusedState(buckets=new_buckets,
                                 lineage=new_lineage)


def initial_lineage(trouble, growing):
    """Lineage starts as trouble entries (board-position order)
    followed by any pre-existing growing 2-partials. Both are
    in-flight commitments that need to be carried to a legal
    home before victory.

    Accepts either CCS-shaped or raw bucket lists. Returns a
    tuple of raw card tuples for content-based identity."""
    def _to_card_tuple(stack):
        if isinstance(stack, ClassifiedCardStack):
            return stack.cards
        return tuple(stack)
    return (tuple(_to_card_tuple(s) for s in trouble)
            + tuple(_to_card_tuple(s) for s in growing))
