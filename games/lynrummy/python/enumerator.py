"""
enumerator.py — BFS move generator + focus rule + doomed-
third filter + extractable index.

The Python equivalent of `Game.Agent.Enumerator.elm`. See
`enumerator.claude` for the full overview.
"""

from buckets import Buckets, FocusedState
from cards import (
    RED, classify, neighbors, is_partial_ok,
    can_peel, can_pluck, can_yank,
    can_steal, can_split_out,
)
from move import (
    ExtractAbsorbDesc, FreePullDesc, PushDesc,
    ShiftDesc, SpliceDesc,
)


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
    """If `merged` classifies as a complete legal group,
    append it to COMPLETE; otherwise append it to GROWING.
    Returns (new_growing, new_complete, graduated_flag). Pure."""
    if classify(merged) != "other":
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
        for c in stack:
            inv.add((c[0], c[1]))
    for stack in trouble:
        if len(stack) == 1:
            c = stack[0]
            inv.add((c[0], c[1]))
    return inv


def completion_shapes(partial):
    """Return the set of (value, suit) shapes that would
    complete a 2-card `partial` into a legal length-3 stack.
    Caller compares against `completion_inventory`."""
    c1, c2 = partial
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


def admissible_partial(merged, inventory):
    """Gate every absorbed result: legal as a partial AND (if
    length-2) has a completion candidate somewhere in
    `inventory`. Lifted from the three sites
    (extract_absorb / free_pull / shift) that share the gate."""
    if not is_partial_ok(merged):
        return False
    if len(merged) == 2 and has_doomed_third(merged, inventory):
        return False
    return True


# --- Extract physics ---

def extract_pieces(source, ci, verb):
    """Return (helper_pieces, spawned_pieces) — the post-extract
    pieces of `source` after removing the card at `ci` per
    `verb`. Helper pieces are length-3+ legal stacks that stay
    in HELPER; spawned pieces are short remnants that land in
    TROUBLE.

    Pure: takes a stack, returns lists. No mutation."""
    c = source[ci]
    if verb == "peel":
        kind = classify(source)
        if kind == "set":
            remnant = [x for x in source if x != c]
        elif ci == 0:
            remnant = source[1:]
        else:
            remnant = source[:-1]
        return [remnant], []
    if verb == "pluck":
        return [source[:ci], source[ci + 1:]], []
    if verb == "yank" or verb == "split_out":
        # split_out is the n=3, ci=1 specialization of yank:
        # both halves are singletons that go to TROUBLE.
        left = source[:ci]
        right = source[ci + 1:]
        helpers = [s for s in (left, right) if len(s) >= 3]
        spawned = [s for s in (left, right) if len(s) < 3]
        return helpers, spawned
    if verb == "steal":
        kind = classify(source)
        if kind == "set":
            return [], [[x] for x in source if x != c]
        remnant = source[1:] if ci == 0 else source[:-1]
        return [], [remnant]
    raise ValueError(f"unknown verb {verb}")


def do_extract(helper, src_idx, ci, verb):
    """Extract a card from HELPER. Returns
    (new_helper, spawned_trouble_pieces, ext_card, source_before).

    Pure: produces a fresh helper list via concatenation; no
    mutation of the input."""
    source = helper[src_idx]
    helper_pieces, spawned = extract_pieces(source, ci, verb)
    new_helper = (helper[:src_idx] + helper[src_idx + 1:]
                  + helper_pieces)
    return new_helper, spawned, source[ci], list(source)


def verb_for(kind, n, ci):
    if can_peel(kind, n, ci):
        return "peel"
    if can_pluck(kind, n, ci):
        return "pluck"
    if can_yank(kind, n, ci):
        return "yank"
    if can_steal(kind, n, ci):
        return "steal"
    if can_split_out(kind, n, ci):
        return "split_out"
    return None


def extractable_index(helper):
    """One-pass scan over HELPER, classifying each stack and
    determining which (helper_idx, ci, verb) tuples are
    legal extracts. Maps `(value, suit)` shape →
    list of (helper_idx, ci, verb).

    Built once per state. The absorber loop inverts the old
    "for-each-card check shape" pattern into a direct
    "for-each-target-shape lookup" — helpers whose cards
    aren't neighbors of any absorber are never visited.

    classify() runs once per helper here, not once per
    (helper × absorber) as before. verb_for runs once per
    (helper × ci), not once per (absorber × helper × ci).
    """
    out = {}
    for hi, src in enumerate(helper):
        kind = classify(src)
        n = len(src)
        for ci, c in enumerate(src):
            verb = verb_for(kind, n, ci)
            if verb is None:
                continue
            out.setdefault((c[0], c[1]), []).append(
                (hi, ci, verb))
    return out


# --- Move generator ---

def enumerate_moves(state):
    """Yield (description_dict, new_state) for every legal
    1-line extension."""
    helper, trouble, growing, complete = state
    completion_inv = completion_inventory(helper, trouble)

    # State-level doomed-growing filter. If any growing
    # 2-partial has no completion candidate in this state's
    # (helper + trouble-singletons) inventory, the partial
    # will NEVER graduate. The state is dead — yield nothing.
    # The doomed-third filter at merge time admits partials
    # whose completion is available AT ADMISSION; this guard
    # catches partials whose completion has since been
    # consumed elsewhere.
    for g in growing:
        if len(g) == 2:
            shapes = completion_shapes(g)
            if not (shapes & completion_inv):
                return

    extractable = extractable_index(helper)

    # All targets for absorption (move type a). Each entry:
    # (bucket_name, idx_in_bucket, target_stack).
    absorbers = (
        [("trouble", ti, t) for ti, t in enumerate(trouble)]
        + [("growing", gi, g) for gi, g in enumerate(growing)]
    )

    for bucket, idx, target in absorbers:
        # Neighbor shapes for this absorber. Sorted so move
        # enumeration is deterministic across runs AND across
        # the Python/Elm port (Elm's shapes are list-ordered;
        # we sort to match).
        shapes = sorted(set().union(*(neighbors(c) for c in target)))

        # Source: HELPER stack via extract. Inverted loop —
        # iterate the ABSORBER's neighbor shapes and look up
        # extractable cards directly, instead of walking every
        # helper × position to filter.
        for shape in shapes:
            for hi, ci, verb in extractable.get(shape, ()):
                new_helper, spawned, ext_card, source = \
                    do_extract(helper, hi, ci, verb)
                for side in ("right", "left"):
                    merged = ([*target, ext_card] if side == "right"
                              else [ext_card, *target])
                    if not admissible_partial(merged, completion_inv):
                        continue
                    nt_base, ng = remove_absorber(
                        bucket, idx, trouble, growing)
                    nt = nt_base + spawned
                    ng_final, nc, graduated = graduate(
                        merged, ng, complete)
                    desc = ExtractAbsorbDesc(
                        verb=verb,
                        source=source,
                        ext_card=ext_card,
                        target_before=list(target),
                        target_bucket_before=bucket,
                        result=merged,
                        side=side,
                        graduated=graduated,
                        spawned=list(spawned),
                    )
                    yield desc, Buckets(new_helper, nt, ng_final, nc)

        # Source: TROUBLE singleton (free pull).
        for li, loose_stack in enumerate(trouble):
            if len(loose_stack) != 1:
                continue
            if bucket == "trouble" and li == idx:
                continue  # can't absorb a stack onto itself
            loose = loose_stack[0]
            if (loose[0], loose[1]) not in shapes:
                continue
            for side in ("right", "left"):
                merged = ([*target, loose] if side == "right"
                          else [loose, *target])
                if not admissible_partial(merged, completion_inv):
                    continue
                # Both the absorber AND the loose-source come
                # out of TROUBLE — drop both at once.
                nt_base, ng = remove_absorber(
                    bucket, idx, trouble, growing)
                if bucket == "trouble":
                    # remove_absorber dropped idx; also drop
                    # li (its position in nt_base shifted iff
                    # li > idx).
                    li_in_base = li - 1 if li > idx else li
                    nt = drop_at(nt_base, li_in_base)
                else:
                    nt = drop_at(nt_base, li)
                ng_final, nc, graduated = graduate(
                    merged, ng, complete)
                desc = FreePullDesc(
                    loose=loose,
                    target_before=list(target),
                    target_bucket_before=bucket,
                    result=merged,
                    side=side,
                    graduated=graduated,
                )
                yield desc, Buckets(list(helper), nt, ng_final, nc)

    # Move type (d): SHIFT — when an end-card of a length-3
    # pure/rb run would normally be steal-pulled (sacrificing
    # the 2-partial remnant), scan HELPER for a peel-eligible
    # donor with the right replacement card. The run shifts:
    # peel donor's P, push P onto source's other end, pop
    # the stolen card. Source stays length-3 legal; donor
    # stays legal; the popped card absorbs onto trouble like
    # a steal-pull would. NO sacrifice.
    for bucket, idx, target in absorbers:
        shapes = set().union(*(neighbors(c) for c in target))
        for src_idx, source in enumerate(helper):
            if len(source) != 3:
                continue
            kind = classify(source)
            if kind not in ("pure_run", "rb_run"):
                continue
            for which_end in (0, 2):
                stolen = source[which_end]
                if (stolen[0], stolen[1]) not in shapes:
                    continue
                # Compute replacement card requirement at the
                # OPPOSITE end of source.
                if which_end == 2:
                    anchor = source[0]
                    p_value = 13 if anchor[0] == 1 else anchor[0] - 1
                else:
                    anchor = source[2]
                    p_value = 1 if anchor[0] == 13 else anchor[0] + 1
                anchor_red = anchor[1] in RED
                if kind == "pure_run":
                    needed_suits = (anchor[1],)
                else:
                    needed_suits = tuple(
                        s for s in range(4)
                        if (s in RED) != anchor_red)
                # Donor candidates: peel-eligible cards in
                # length-4+ helpers — read out of the
                # extractable index, filtered to peels.
                for p_suit in needed_suits:
                    for donor_idx, _ci, verb in \
                            extractable.get((p_value, p_suit), ()):
                        if verb != "peel" or donor_idx == src_idx:
                            continue
                        donor = helper[donor_idx]
                        if len(donor) < 4:
                            continue
                        p_card = donor[_ci]
                        # Compute new_donor: set drops the
                        # peeled card; run drops the end card.
                        if classify(donor) == "set":
                            new_donor = [x for x in donor
                                         if x != p_card]
                        else:
                            new_donor = (donor[1:] if _ci == 0
                                         else donor[:-1])
                        new_source = (
                            [p_card, source[0], source[1]]
                            if which_end == 2
                            else [source[1], source[2], p_card])
                        if classify(new_source) != kind:
                            continue
                        # Helper drop: src_idx + donor_idx
                        # (descending so removals don't shift
                        # each other), then append the rebuilt
                        # source and shrunken donor.
                        hi_lo = sorted((src_idx, donor_idx),
                                       reverse=True)
                        nh = list(helper)
                        for i in hi_lo:
                            nh = drop_at(nh, i)
                        nh = nh + [new_source, new_donor]
                        for absorb_side in ("right", "left"):
                            merged = (
                                [*target, stolen]
                                if absorb_side == "right"
                                else [stolen, *target])
                            if not admissible_partial(merged, completion_inv):
                                continue
                            nt_base, ng = remove_absorber(
                                bucket, idx, trouble, growing)
                            ng_final, nc, graduated = graduate(
                                merged, ng, complete)
                            desc = ShiftDesc(
                                source=list(source),
                                donor=list(donor),
                                stolen=stolen,
                                p_card=p_card,
                                which_end=which_end,
                                new_source=new_source,
                                new_donor=new_donor,
                                target_before=list(target),
                                target_bucket_before=bucket,
                                merged=merged,
                                side=absorb_side,
                                graduated=graduated,
                            )
                            yield desc, Buckets(nh, nt_base, ng_final, nc)

    # Move type (c): splice — insert a TROUBLE singleton
    # into a HELPER pure/rb run length 4+. The run splits
    # around the inserted card; both halves must be legal
    # length-3+. One physical gesture in actual Lyn Rummy
    # (drop the card into the middle of the run).
    def _splice_halves(side, src, k, loose):
        """Return (left, right) for the named splice side."""
        if side == "left":
            return list(src[:k]) + [loose], list(src[k:])
        return list(src[:k]), [loose, *src[k:]]

    def _splice_legal(left, right):
        return (len(left) >= 3 and len(right) >= 3
                and classify(left) != "other"
                and classify(right) != "other")

    for ti, t in enumerate(trouble):
        if len(t) != 1:
            continue
        loose = t[0]
        for hi, src in enumerate(helper):
            n = len(src)
            if n < 4 or classify(src) not in ("pure_run", "rb_run"):
                continue
            for k in range(1, n):
                for side in ("left", "right"):
                    left, right = _splice_halves(
                        side, src, k, loose)
                    if not _splice_legal(left, right):
                        continue
                    nh = drop_at(helper, hi) + [left, right]
                    nt = drop_at(trouble, ti)
                    desc = SpliceDesc(
                        loose=loose,
                        source=list(src),
                        k=k, side=side,
                        left_result=left,
                        right_result=right,
                    )
                    yield desc, Buckets(nh, nt, list(growing),
                                        list(complete))

    # Move type (b): push a TROUBLE 1- or 2-partial onto a
    # HELPER stack so the result stays legal (the helper grows
    # by 1 or 2 cards).
    for ti, t in enumerate(trouble):
        if len(t) > 2:
            continue
        for hi, h in enumerate(helper):
            for side in ("right", "left"):
                merged = ([*h, *t] if side == "right"
                          else [*t, *h])
                if classify(merged) == "other":
                    continue
                nh = drop_at(helper, hi) + [merged]
                nt = drop_at(trouble, ti)
                desc = PushDesc(
                    trouble_before=list(t),
                    target_before=list(h),
                    result=merged,
                    side=side,
                )
                yield desc, Buckets(nh, nt, list(growing), list(complete))

    # Move type (b'): a GROWING 2-partial engulfs a HELPER
    # stack — the growing build absorbs the helper into a
    # single legal stack and graduates to COMPLETE. The
    # expert "we already have AC2D, just engulf [3S 4D 5C]"
    # one-gesture move that lands a 5-long rb-run in one go.
    for gi, g in enumerate(growing):
        for hi, h in enumerate(helper):
            for side in ("right", "left"):
                merged = ([*h, *g] if side == "right"
                          else [*g, *h])
                if classify(merged) == "other":
                    continue
                nh = drop_at(helper, hi)
                ng = drop_at(growing, gi)
                nc = complete + [merged]
                desc = PushDesc(
                    trouble_before=list(g),
                    target_before=list(h),
                    result=merged,
                    side=side,
                )
                yield desc, Buckets(nh, list(trouble), ng, nc)


# --- Focus rule + lineage tracking ---

def move_touches_focus(desc, focus):
    """True iff this move grows or consumes the focus stack
    (identified by content tuple)."""
    t = desc.type
    if isinstance(desc, ExtractAbsorbDesc) or isinstance(desc, ShiftDesc):
        return tuple(desc.target_before) == focus
    if isinstance(desc, FreePullDesc):
        # Either target=focus (focus grew) or loose=focus
        # (focus singleton consumed onto a queued sibling).
        if tuple(desc.target_before) == focus:
            return True
        return len(focus) == 1 and focus[0] == desc.loose
    if isinstance(desc, SpliceDesc):
        return len(focus) == 1 and focus[0] == desc.loose
    if isinstance(desc, PushDesc):
        # Both b (trouble pushed onto helper) and b' (growing
        # engulfs helper) carry trouble_before = the consumed
        # entry's content.
        return tuple(desc.trouble_before) == focus
    return False


def update_lineage(lineage, desc):
    """Compute the new lineage tuple after applying the move.
    Caller has already verified the move touches lineage[0]."""
    focus = lineage[0]
    rest = list(lineage[1:])

    if isinstance(desc, ExtractAbsorbDesc):
        # Focus (target) grew; spawn fragments append.
        spawned = tuple(tuple(s) for s in desc.spawned)
        if desc.graduated:
            new = rest
        else:
            new = [tuple(desc.result)] + rest
        return tuple(new) + spawned

    if isinstance(desc, ShiftDesc):
        # Same as ExtractAbsorb but uses `merged` and produces
        # no spawned trouble.
        if desc.graduated:
            return tuple(rest)
        return (tuple(desc.merged),) + tuple(rest)

    if isinstance(desc, FreePullDesc):
        target_before = tuple(desc.target_before)
        result = tuple(desc.result)
        graduated = desc.graduated
        if target_before == focus:
            # Focus grew; the loose was a queued singleton —
            # remove it from rest by content match.
            loose_entry = (desc.loose,)
            if loose_entry in rest:
                rest.remove(loose_entry)
            if graduated:
                return tuple(rest)
            return (result,) + tuple(rest)
        # Focus is the loose (singleton); target is a queued
        # sibling that just grew.
        if target_before in rest:
            ti = rest.index(target_before)
            if graduated:
                rest.pop(ti)
            else:
                rest[ti] = result
        return tuple(rest)

    # SpliceDesc / PushDesc — focus is consumed, no growth tracked.
    return tuple(rest)


# Module flag for analysis tooling. Production keeps this True;
# `analyze_focus_block.py` flips it to False to replay BFS
# without the focus-only restriction so we can diff plans.
FOCUS_ENABLED = True


def enumerate_focused(state):
    """Wrap enumerate_moves with the focus-only filter and
    lineage bookkeeping. Yields (desc, new_FocusedState)."""
    if not state.lineage:
        return
    focus = state.lineage[0]
    if not FOCUS_ENABLED:
        # Bypass: yield every legal move; freeze lineage so the
        # dedup key reduces to the bucket signature.
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
    home before victory."""
    return (tuple(tuple(s) for s in trouble)
            + tuple(tuple(s) for s in growing))
