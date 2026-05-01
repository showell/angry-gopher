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
    extends_tables,
    _kinds_after_splice_run,  # fast path: caller-knows-family entry
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
    absorber are never visited.

    Kind dispatch happens ONCE per stack here; the per-position
    inner loop uses precomputed (n, ci) → verb logic specialized
    to the stack's kind. Skips pair_*/singleton stacks entirely
    (nothing extracts from them)."""
    out = {}
    for hi, src in enumerate(helper):
        kind = src.kind
        n = src.n
        cards = src.cards
        if kind == KIND_RUN or kind == KIND_RB:
            # Run / rb: peel(end, n>=4), pluck(deep interior, n>=7),
            # yank(shallow non-end, n>=4), steal(n=3, end), split_out(n=3, i=1).
            if n == 3:
                # Length-3 run: ends are steal, middle is split_out.
                _add(out, cards, 0, hi, "steal")
                _add(out, cards, 1, hi, "split_out")
                _add(out, cards, 2, hi, "steal")
            else:
                # n >= 4: peel ends, pluck/yank interior.
                last = n - 1
                _add(out, cards, 0, hi, "peel")
                _add(out, cards, last, hi, "peel")
                # Interior positions 1..n-2.
                for ci in range(1, last):
                    if 3 <= ci <= n - 4:
                        verb = "pluck"
                    elif max(ci, n - ci - 1) >= 3 and min(ci, n - ci - 1) >= 1:
                        verb = "yank"
                    else:
                        continue
                    _add(out, cards, ci, hi, verb)
        elif kind == KIND_SET:
            if n >= 4:
                # peel any position
                for ci in range(n):
                    _add(out, cards, ci, hi, "peel")
            elif n == 3:
                # steal any position
                for ci in range(n):
                    _add(out, cards, ci, hi, "steal")
        # KIND_PAIR_RUN / KIND_PAIR_RB / KIND_PAIR_SET / KIND_SINGLETON:
        # nothing extracts. Skip the inner loop entirely.
    return out


def _add(out, cards, ci, hi, verb):
    c = cards[ci]
    out.setdefault((c[0], c[1]), []).append((hi, ci, verb))


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
    (raw card-list input is coerced once at entry).

    Orchestrates six move-type generators (one per move kind). Each
    is a small focused helper; the body here is dispatch only."""
    state = _maybe_classify(state)
    helper, trouble, growing, complete = state
    completion_inv = completion_inventory(helper, trouble)

    if _state_has_doomed_growing(growing, completion_inv):
        return

    extractable = extractable_index(helper)
    splice_helpers = _eligible_splice_helpers(helper)
    shift_helpers = _eligible_shift_helpers(helper)
    absorber_shapes = _build_absorber_shapes(trouble, growing)

    for absorber in absorber_shapes:
        yield from _yield_extract_absorbs(
            absorber, helper, trouble, growing, complete,
            extractable, completion_inv)
        yield from _yield_free_pulls(
            absorber, helper, trouble, growing, complete,
            completion_inv)

    yield from _yield_shifts(
        absorber_shapes, helper, trouble, growing, complete,
        shift_helpers, extractable, completion_inv)
    yield from _yield_splices(helper, trouble, growing, complete,
                              splice_helpers)
    yield from _yield_pushes(helper, trouble, growing, complete)
    yield from _yield_engulfs(helper, trouble, growing, complete)


def _state_has_doomed_growing(growing, completion_inv):
    """True if any growing 2-partial has no completion candidate in
    `completion_inv` — i.e., the partial can't graduate from any
    reachable child state. The state is dead; the caller short-
    circuits by yielding nothing."""
    for g in growing:
        if g.n == 2:
            if not (completion_shapes(g.cards) & completion_inv):
                return True
    return False


def _eligible_splice_helpers(helper):
    """HELPER stacks eligible to host a splice insertion: length-4+
    pure or rb runs (length-3 runs can't split into two length-3
    halves around an inserted card)."""
    return [
        (hi, h)
        for hi, h in enumerate(helper)
        if h.n >= 4 and h.kind in _RUN_FAMILY_KINDS
    ]


def _eligible_shift_helpers(helper):
    """HELPER stacks eligible to be the SHIFT source: exactly
    length-3 pure or rb runs."""
    return [
        (hi, h)
        for hi, h in enumerate(helper)
        if h.n == 3 and h.kind in _RUN_FAMILY_KINDS
    ]


def _build_absorber_shapes(trouble, growing):
    """Return [(bucket_name, idx, target_stack, extends, sorted_shapes), ...]
    for every absorber (TROUBLE entry or GROWING partial).

    `extends` is a dict `{(value, suit) → (right_kind, left_kind)}`
    earned at the moment the BFS commits to iterating this absorber:
    for any candidate card whose shape isn't a key, neither side
    legally absorbs it; for any key, one or both result kinds is non-
    None. The hot-path callers iterate this dict directly — no per-
    card probe.

    `sorted_shapes` is the iteration order for determinism (matching
    the Elm port). It's the keys of `extends`, sorted."""
    out = []
    for ti, t in enumerate(trouble):
        extends = extends_tables(t)
        out.append(("trouble", ti, t, extends, sorted(extends)))
    for gi, g in enumerate(growing):
        extends = extends_tables(g)
        out.append(("growing", gi, g, extends, sorted(extends)))
    return out


# --- Move type (a): extract+absorb ---

def _yield_extract_absorbs(absorber, helper, trouble, growing, complete,
                           extractable, completion_inv):
    """Source: HELPER stack via extract.

    Iterates the absorber's earned extends-shapes — every iteration
    is guaranteed to have at least one absorbing side. No per-card
    probe; (right_kind, left_kind) come straight from the absorber's
    extends dict."""
    bucket, idx, target, extends, sorted_shapes = absorber
    target_cards_list = list(target.cards)
    nt_base = None  # built lazily on first yield-eligible candidate
    ng = None
    for shape in sorted_shapes:
        right_kind, left_kind = extends[shape]
        for hi, ci, verb in extractable.get(shape, ()):
            ext_card = helper[hi].cards[ci]
            new_helper, spawned, _ext, source_cards = \
                do_extract(helper, hi, ci, verb)
            spawned_lists = [list(s.cards) for s in spawned]
            if nt_base is None:
                nt_base, ng = remove_absorber(bucket, idx, trouble, growing)
            nt = nt_base + spawned
            for side, new_kind, executor in (
                ("right", right_kind, absorb_right),
                ("left", left_kind, absorb_left),
            ):
                if new_kind is None:
                    continue
                merged = executor(target, ext_card, new_kind)
                if not admissible_merged(merged, completion_inv):
                    continue
                ng_final, nc, graduated = graduate(merged, ng, complete)
                desc = ExtractAbsorbDesc(
                    verb=verb,
                    source=source_cards,
                    ext_card=ext_card,
                    target_before=target_cards_list,
                    target_bucket_before=bucket,
                    result=list(merged.cards),
                    side=side,
                    graduated=graduated,
                    spawned=spawned_lists,
                )
                yield desc, Buckets(new_helper, nt, ng_final, nc)


# --- Move type (a'): free pull (TROUBLE singleton onto absorber) ---

def _yield_free_pulls(absorber, helper, trouble, growing, complete,
                      completion_inv):
    """Source: a TROUBLE singleton, absorbed onto another absorber.
    Both the absorber and the loose source come out of TROUBLE/GROWING
    in one move."""
    bucket, idx, target, extends, _sorted_shapes = absorber
    target_cards_list = list(target.cards)
    for li, loose_stack in enumerate(trouble):
        if loose_stack.n != 1:
            continue
        if bucket == "trouble" and li == idx:
            continue  # can't absorb a stack onto itself
        loose = loose_stack.cards[0]
        kinds = extends.get((loose[0], loose[1]))
        if kinds is None:
            continue
        right_kind, left_kind = kinds
        for side, new_kind, executor in (
            ("right", right_kind, absorb_right),
            ("left", left_kind, absorb_left),
        ):
            if new_kind is None:
                continue
            merged = executor(target, loose, new_kind)
            if not admissible_merged(merged, completion_inv):
                continue
            nt_base, ng = remove_absorber(bucket, idx, trouble, growing)
            if bucket == "trouble":
                li_in_base = li - 1 if li > idx else li
                nt = drop_at(nt_base, li_in_base)
            else:
                nt = drop_at(nt_base, li)
            ng_final, nc, graduated = graduate(merged, ng, complete)
            desc = FreePullDesc(
                loose=loose,
                target_before=target_cards_list,
                target_bucket_before=bucket,
                result=list(merged.cards),
                side=side,
                graduated=graduated,
            )
            yield desc, Buckets(list(helper), nt, ng_final, nc)


# --- Move type (d): SHIFT ---

def _yield_shifts(absorber_shapes, helper, trouble, growing, complete,
                  shift_helpers, extractable, completion_inv):
    """SHIFT — when an end-card of a length-3 pure/rb run would
    normally be steal-pulled (sacrificing the 2-partial remnant),
    scan HELPER for a peel-eligible donor with the right replacement
    card. The run shifts: peel donor's P, push P onto source's other
    end, pop the stolen card. Source stays length-3 legal; donor stays
    legal; the popped card absorbs onto trouble like a steal-pull
    would. NO sacrifice."""
    for absorber in absorber_shapes:
        for src_idx, source in shift_helpers:
            for which_end in (0, 2):
                yield from _yield_shifts_for_endpoint(
                    absorber, helper, trouble, growing, complete,
                    src_idx, source, which_end,
                    extractable, completion_inv)


def _yield_shifts_for_endpoint(absorber, helper, trouble, growing, complete,
                               src_idx, source, which_end,
                               extractable, completion_inv):
    """All shift moves rooted at (source, which_end) for one absorber."""
    bucket, idx, target, extends, _sorted_shapes = absorber
    stolen = source.cards[which_end]
    kinds = extends.get((stolen[0], stolen[1]))
    if kinds is None:
        return
    right_kind, left_kind = kinds
    p_value, needed_suits = _shift_replacement_requirement(source, which_end)
    candidates = _shift_donor_candidates(
        helper, src_idx, p_value, needed_suits, extractable)
    for donor_idx, _ci in candidates:
        donor = helper[donor_idx]
        p_card = donor.cards[_ci]
        _ext, new_donor = peel(donor, _ci)
        new_source = _shift_rebuild_source(source, p_card, which_end)
        if new_source is None or new_source.kind != source.kind:
            continue
        nh = _shift_rebuild_helper(helper, src_idx, donor_idx,
                                   new_source, new_donor)
        for absorb_side, new_kind, executor in (
            ("right", right_kind, absorb_right),
            ("left", left_kind, absorb_left),
        ):
            if new_kind is None:
                continue
            merged = executor(target, stolen, new_kind)
            if not admissible_merged(merged, completion_inv):
                continue
            nt_base, ng = remove_absorber(bucket, idx, trouble, growing)
            ng_final, nc, graduated = graduate(merged, ng, complete)
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


def _shift_replacement_requirement(source, which_end):
    """Compute the (value, allowed_suits) signature that the
    replacement card P must meet to extend `source` at the OPPOSITE
    end after `which_end` is stolen."""
    if which_end == 2:
        anchor = source.cards[0]
        p_value = 13 if anchor[0] == 1 else anchor[0] - 1
    else:
        anchor = source.cards[2]
        p_value = 1 if anchor[0] == 13 else anchor[0] + 1
    anchor_red = anchor[1] in RED
    if source.kind == KIND_RUN:
        needed_suits = (anchor[1],)
    else:
        needed_suits = tuple(s for s in range(4)
                             if (s in RED) != anchor_red)
    return p_value, needed_suits


def _shift_donor_candidates(helper, src_idx, p_value, needed_suits,
                            extractable):
    """Peel-eligible donor cards in length-4+ helpers matching
    (p_value, suit) for any suit in `needed_suits`. Sorted by
    (donor_idx, ci) for deterministic iteration order."""
    return sorted(
        (donor_idx, ci)
        for p_suit in needed_suits
        for donor_idx, ci, verb in extractable.get((p_value, p_suit), ())
        if verb == "peel"
        and donor_idx != src_idx
        and helper[donor_idx].n >= 4
    )


def _shift_rebuild_source(source, p_card, which_end):
    """The shifted source: drop the stolen end, push p_card onto the
    other end. Returns the classified CCS or None if it doesn't
    classify."""
    if which_end == 2:
        new_cards = (p_card, source.cards[0], source.cards[1])
    else:
        new_cards = (source.cards[1], source.cards[2], p_card)
    return classify_stack(new_cards)


def _shift_rebuild_helper(helper, src_idx, donor_idx, new_source, new_donor):
    """Drop both src and donor (descending so removals don't shift
    each other), then append the rebuilt source and shrunken donor."""
    nh = list(helper)
    for i in sorted((src_idx, donor_idx), reverse=True):
        nh = drop_at(nh, i)
    return nh + [new_source, new_donor]


# --- Move type (c): splice ---

def _yield_splices(helper, trouble, growing, complete, splice_helpers):
    """Insert a TROUBLE singleton into a HELPER pure/rb run length 4+.
    The run splits around the inserted card; both halves must be legal
    length-3+. One physical gesture in actual Lyn Rummy."""
    growing_snapshot = None  # build lazily on first yield
    complete_snapshot = None
    for ti, t in enumerate(trouble):
        if t.n != 1:
            continue
        loose = t.cards[0]
        for hi, src in splice_helpers:
            # `splice_helpers` already filtered to KIND_RUN / KIND_RB,
            # so family == src.kind. Bypass `kinds_after_splice`
            # (which re-derives family per call) and call the run/rb
            # specialization directly.
            family = src.kind
            src_cards = src.cards
            n = src.n
            for k in range(1, n):
                for side in ("left", "right"):
                    kinds = _kinds_after_splice_run(
                        src_cards, loose, k, side, family)
                    if kinds is None:
                        continue
                    left_kind, right_kind = kinds
                    if (left_kind not in _LEGAL_LEN3_KINDS
                            or right_kind not in _LEGAL_LEN3_KINDS):
                        continue
                    left, right = splice(src, loose, k, side,
                                         left_kind, right_kind)
                    nh = drop_at(helper, hi) + [left, right]
                    nt = drop_at(trouble, ti)
                    if growing_snapshot is None:
                        growing_snapshot = list(growing)
                        complete_snapshot = list(complete)
                    desc = SpliceDesc(
                        loose=loose,
                        source=list(src.cards),
                        k=k, side=side,
                        left_result=list(left.cards),
                        right_result=list(right.cards),
                    )
                    yield desc, Buckets(nh, nt,
                                        list(growing_snapshot),
                                        list(complete_snapshot))


# --- Move type (b): push TROUBLE onto HELPER ---

def _yield_pushes(helper, trouble, growing, complete):
    """Push a TROUBLE 1- or 2-partial onto a HELPER stack so the
    result stays legal (the helper grows by 1 or 2 cards)."""
    for ti, t in enumerate(trouble):
        if t.n > 2:
            continue
        for hi, h in enumerate(helper):
            for side in ("right", "left"):
                merged = _absorb_seq(h, t.cards, side)
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


# --- Move type (b'): a GROWING 2-partial engulfs a HELPER stack ---

def _yield_engulfs(helper, trouble, growing, complete):
    """A GROWING 2-partial engulfs a HELPER stack — the growing build
    absorbs the helper into a single legal stack and graduates to
    COMPLETE."""
    for gi, g in enumerate(growing):
        for hi, h in enumerate(helper):
            for side in ("right", "left"):
                merged = _absorb_seq(h, g.cards, side)
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
