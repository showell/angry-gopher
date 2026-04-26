"""
bfs_solver.py — four-bucket BFS for single-card puzzles.

State buckets:
  HELPER   - original-board complete stacks. Source for extracts.
  TROUBLE  - orphaned cards (singletons or 2-partials) not yet
             committed to a build.
  GROWING  - committed builds. Sealed against extracts and
             splits. Eligible for further absorption AND for
             engulfing a HELPER stack (move type b').
  COMPLETE - graduated GROWING stacks. Sealed forever.

Move types:
  (a)  Absorb a neighbor into TROUBLE or GROWING. Source =
       HELPER extract OR a TROUBLE singleton. Target moves
       to GROWING (or COMPLETE if the result is legal).
  (b)  Push a TROUBLE 1- or 2-partial onto a HELPER stack
       so the helper grows by 1-2 cards.
  (b') Engulf: a GROWING 2-partial swallows a HELPER stack
       into one legal stack that graduates to COMPLETE.
  (c)  Splice: insert a TROUBLE singleton into a HELPER
       pure/rb run, splitting it cleanly into two legal halves.
  (d)  Shift: peel a HELPER donor card to replace the stolen
       end of a length-3 run; no spawn.

Search: BFS by program length, with an outer iterative cap
on total trouble (cards in TROUBLE + GROWING). Within each
level, programs are sorted by trouble count so victory-
adjacent states are expanded earliest.

Pure-FP discipline: every state-transition helper takes
state, returns state, no mutation. State is a 4-tuple of
lists; lists are treated as immutable values by convention.

Verbose mode emits a narration line per expansion so a
human can follow what the search is "thinking" about.
"""

import beginner as b


classify = b.classify
partial_ok = b.partial_ok
neighbors = b.neighbors
label_d = b.label_d


def _stack_label(stack):
    return " ".join(label_d(c) for c in stack)


def _state_sig(helper, trouble, growing, complete):
    """Memoization key. Bucket order matters (HELPER vs
    COMPLETE differ in role) but stack order within a bucket
    doesn't."""
    def s(stacks):
        return tuple(sorted(tuple(sorted(st)) for st in stacks))
    return (s(helper), s(trouble), s(growing), s(complete))


def _trouble_count(trouble, growing):
    return sum(len(s) for s in trouble) + sum(len(s) for s in growing)


def _victory(trouble, growing):
    return not trouble and all(len(s) >= 3 for s in growing)


def _without(stacks, idx):
    """Stacks list with index `idx` dropped. Pure."""
    return stacks[:idx] + stacks[idx + 1:]


def _remove_absorber(bucket_name, idx, trouble, growing):
    """Drop the absorber at (bucket_name, idx) from its bucket;
    the other bucket passes through unchanged. Returns
    (new_trouble, new_growing). Pure."""
    if bucket_name == "trouble":
        return _without(trouble, idx), list(growing)
    return list(trouble), _without(growing, idx)


def _graduate(merged, growing, complete):
    """If `merged` classifies as a complete legal group,
    append it to COMPLETE; otherwise append it to GROWING.
    Returns (new_growing, new_complete, graduated_flag). Pure."""
    if classify(merged) != "other":
        return list(growing), complete + [merged], True
    return growing + [merged], list(complete), False


def _extract_pieces(source, ci, verb):
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
    if verb == "yank":
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


def _do_extract(helper, src_idx, ci, verb):
    """Extract a card from HELPER. Returns
    (new_helper, spawned_trouble_pieces, ext_card, source_before).

    Pure: produces a fresh helper list via concatenation; no
    mutation of the input."""
    source = helper[src_idx]
    helper_pieces, spawned = _extract_pieces(source, ci, verb)
    new_helper = (helper[:src_idx] + helper[src_idx + 1:]
                  + helper_pieces)
    return new_helper, spawned, source[ci], list(source)


def _verb_for(kind, n, ci):
    if b._can_peel_kind(kind, n, ci):
        return "peel"
    if b._can_pluck_kind(kind, n, ci):
        return "pluck"
    if b._can_yank_kind(kind, n, ci):
        return "yank"
    if b._can_steal_kind(kind, n, ci):
        return "steal"
    return None


def _peelable_index(helper):
    """Map (value, suit) → list of (donor_idx, ci, new_donor)
    for every card in HELPER that can be peeled WITHOUT
    source damage:
      - Set length 4+: any position; new_donor is the set
        minus that card.
      - Pure/rb run length 4+: end positions only;
        new_donor is the run minus the end card.
    Used by SHIFT (and potentially others) for O(1) lookup
    instead of re-scanning all HELPER stacks per move."""
    out = {}
    for di, donor in enumerate(helper):
        n = len(donor)
        if n < 4:
            continue
        kind = classify(donor)
        if kind == "set":
            for ci, c in enumerate(donor):
                out.setdefault((c[0], c[1]), []).append(
                    (di, ci, [x for x in donor if x != c]))
        elif kind in ("pure_run", "rb_run"):
            for ci in (0, n - 1):
                c = donor[ci]
                new_donor = donor[1:] if ci == 0 else donor[:-1]
                out.setdefault((c[0], c[1]), []).append(
                    (di, ci, new_donor))
    return out


def enumerate_moves(state):
    """Yield (description_dict, new_state) for every legal
    1-line extension."""
    helper, trouble, growing, complete = state
    peelable = _peelable_index(helper)

    # All targets for absorption (move type a). Each entry:
    # (bucket_name, idx_in_bucket, target_stack).
    absorbers = (
        [("trouble", ti, t) for ti, t in enumerate(trouble)]
        + [("growing", gi, g) for gi, g in enumerate(growing)]
    )

    for bucket, idx, target in absorbers:
        # Neighbor shapes for this absorber.
        shapes = set().union(*(neighbors(c) for c in target))

        # Source: HELPER stack via extract.
        for hi, src in enumerate(helper):
            kind = classify(src)
            n = len(src)
            for ci, c in enumerate(src):
                if (c[0], c[1]) not in shapes:
                    continue
                verb = _verb_for(kind, n, ci)
                if verb is None:
                    continue
                new_helper, spawned, ext_card, source = \
                    _do_extract(helper, hi, ci, verb)
                for side in ("right", "left"):
                    merged = ([*target, ext_card] if side == "right"
                              else [ext_card, *target])
                    if not partial_ok(merged):
                        continue
                    nt_base, ng = _remove_absorber(
                        bucket, idx, trouble, growing)
                    nt = nt_base + spawned
                    ng_final, nc, graduated = _graduate(
                        merged, ng, complete)
                    desc = {
                        "type": "extract_absorb",
                        "verb": verb,
                        "source": source,
                        "ext_card": ext_card,
                        "target_before": list(target),
                        "target_bucket_before": bucket,
                        "result": merged,
                        "side": side,
                        "graduated": graduated,
                        "spawned": list(spawned),
                    }
                    yield desc, (new_helper, nt, ng_final, nc)

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
                if not partial_ok(merged):
                    continue
                # Both the absorber AND the loose-source come
                # out of TROUBLE — drop both at once.
                nt_base, ng = _remove_absorber(
                    bucket, idx, trouble, growing)
                if bucket == "trouble":
                    # _remove_absorber dropped idx; also drop
                    # li (its position in nt_base shifted iff
                    # li > idx).
                    li_in_base = li - 1 if li > idx else li
                    nt = _without(nt_base, li_in_base)
                else:
                    nt = _without(nt_base, li)
                ng_final, nc, graduated = _graduate(
                    merged, ng, complete)
                desc = {
                    "type": "free_pull",
                    "loose": loose,
                    "target_before": list(target),
                    "target_bucket_before": bucket,
                    "result": merged,
                    "side": side,
                    "graduated": graduated,
                }
                yield desc, (list(helper), nt, ng_final, nc)

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
                anchor_red = anchor[1] in b.RED
                if kind == "pure_run":
                    needed_suits = (anchor[1],)
                else:
                    needed_suits = tuple(
                        s for s in range(4)
                        if (s in b.RED) != anchor_red)
                # Lookup donor candidates via the peelable
                # index — O(1) per (value, suit) pair.
                for p_suit in needed_suits:
                    for donor_idx, _ci, new_donor in \
                            peelable.get((p_value, p_suit), ()):
                        if donor_idx == src_idx:
                            continue
                        donor = helper[donor_idx]
                        p_card = donor[_ci]
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
                            nh = _without(nh, i)
                        nh = nh + [new_source, new_donor]
                        for absorb_side in ("right", "left"):
                            merged = (
                                [*target, stolen]
                                if absorb_side == "right"
                                else [stolen, *target])
                            if not partial_ok(merged):
                                continue
                            nt_base, ng = _remove_absorber(
                                bucket, idx, trouble, growing)
                            ng_final, nc, graduated = _graduate(
                                merged, ng, complete)
                            desc = {
                                "type": "shift",
                                "source": list(source),
                                "donor": list(donor),
                                "stolen": stolen,
                                "p_card": p_card,
                                "which_end": which_end,
                                "new_source": new_source,
                                "new_donor": new_donor,
                                "target_before": list(target),
                                "target_bucket_before": bucket,
                                "merged": merged,
                                "side": absorb_side,
                                "graduated": graduated,
                            }
                            yield desc, (nh, nt_base, ng_final, nc)

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
                    nh = _without(helper, hi) + [left, right]
                    nt = _without(trouble, ti)
                    desc = {
                        "type": "splice",
                        "loose": loose,
                        "source": list(src),
                        "k": k, "side": side,
                        "left_result": left,
                        "right_result": right,
                    }
                    yield desc, (nh, nt, list(growing),
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
                nh = _without(helper, hi) + [merged]
                nt = _without(trouble, ti)
                desc = {
                    "type": "push",
                    "trouble_before": list(t),
                    "target_before": list(h),
                    "result": merged,
                    "side": side,
                }
                yield desc, (nh, nt, list(growing), list(complete))

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
                nh = _without(helper, hi)
                ng = _without(growing, gi)
                nc = complete + [merged]
                desc = {
                    "type": "push",
                    "trouble_before": list(g),
                    "target_before": list(h),
                    "result": merged,
                    "side": side,
                }
                yield desc, (nh, list(trouble), ng, nc)


def describe_move(desc):
    """Render a one-line DSL string for a move."""
    if desc["type"] == "free_pull":
        loose = label_d(desc["loose"])
        bucket = desc["target_bucket_before"]
        tb = _stack_label(desc["target_before"])
        result = _stack_label(desc["result"])
        graduated = " [→COMPLETE]" if desc["graduated"] else ""
        return (f"pull {loose} onto {bucket} [{tb}] → "
                f"[{result}]{graduated}")
    if desc["type"] == "extract_absorb":
        verb = desc["verb"]
        ec = label_d(desc["ext_card"])
        src = _stack_label(desc["source"])
        bucket = desc["target_bucket_before"]
        tb = _stack_label(desc["target_before"])
        result = _stack_label(desc["result"])
        spawned = ""
        if desc["spawned"]:
            spawned = (" ; spawn TROUBLE: "
                       + ", ".join("[" + _stack_label(s) + "]"
                                   for s in desc["spawned"]))
        graduated = " [→COMPLETE]" if desc["graduated"] else ""
        return (f"{verb} {ec} from HELPER [{src}], "
                f"absorb onto {bucket} [{tb}] → "
                f"[{result}]{graduated}{spawned}")
    if desc["type"] == "shift":
        p = label_d(desc["p_card"])
        stolen = label_d(desc["stolen"])
        new_donor = _stack_label(desc["new_donor"])
        new_source = desc["new_source"]
        p_idx = new_source.index(desc["p_card"])
        rest = [c for c in new_source if c != desc["p_card"]]
        rest_label = " ".join(label_d(c) for c in rest)
        if p_idx == 0:
            shifted = f"{p} + {rest_label}"
        else:
            shifted = f"{rest_label} + {p}"
        bucket = desc["target_bucket_before"]
        tb = _stack_label(desc["target_before"])
        merged = _stack_label(desc["merged"])
        graduated = " [→COMPLETE]" if desc["graduated"] else ""
        return (f"shift {p} to pop {stolen} "
                f"[{new_donor} -> {shifted}]; "
                f"absorb onto {bucket} [{tb}] → "
                f"[{merged}]{graduated}")
    if desc["type"] == "splice":
        loose = label_d(desc["loose"])
        src = _stack_label(desc["source"])
        left = _stack_label(desc["left_result"])
        right = _stack_label(desc["right_result"])
        return (f"splice [{loose}] into HELPER [{src}] → "
                f"[{left}] + [{right}]")
    if desc["type"] == "push":
        tb = _stack_label(desc["trouble_before"])
        target = _stack_label(desc["target_before"])
        result = _stack_label(desc["result"])
        return (f"push TROUBLE [{tb}] onto HELPER [{target}] → "
                f"[{result}]")
    return str(desc)


def bfs_with_cap(initial, max_trouble, *, max_states, verbose):
    """Pure BFS by program length. Bounded by max_trouble:
    states whose total trouble exceeds the cap never enter
    the frontier. At each level we expand EVERY program of
    that length, generating all level+1 programs, before
    looking at any longer programs. First victory found at
    level N returns the (shortest-under-cap) plan."""
    if _trouble_count(initial[1], initial[2]) > max_trouble:
        return None, 0, 0
    if _victory(initial[1], initial[2]):
        return [], 0, 1
    seen = {_state_sig(*initial)}
    current_level = [(initial, [])]
    expansions = 0
    level = 0
    while current_level:
        level += 1
        # Sort within the level by trouble count of the
        # current state — pure speedup: iteration order
        # within BFS-by-length doesn't affect which plans
        # are reachable, but lowest-trouble-first means
        # victory-bearing states tend to be expanded earlier
        # and we exit on first hit.
        current_level.sort(
            key=lambda e: _trouble_count(e[0][1], e[0][2]))
        if verbose:
            print(f"\n--- level {level}: expanding "
                  f"{len(current_level)} program(s) ---")
        next_level = []
        for state, program in current_level:
            expansions += 1
            for desc, new_state in enumerate_moves(state):
                _, t, g, _ = new_state
                tc = _trouble_count(t, g)
                if tc > max_trouble:
                    continue
                sig = _state_sig(*new_state)
                if sig in seen:
                    continue
                seen.add(sig)
                new_program = program + [describe_move(desc)]
                if _victory(t, g):
                    if verbose:
                        print(f"  VICTORY at level {level}: "
                              f"{len(new_program)}-line plan, "
                              f"{expansions} expansions, "
                              f"{len(seen)} states")
                    return new_program, expansions, len(seen)
                next_level.append((new_state, new_program))
            if expansions >= max_states:
                if verbose:
                    print(f"  EXHAUSTED max_states={max_states}")
                return None, expansions, len(seen)
        if verbose:
            print(f"  level {level} → "
                  f"{len(next_level)} program(s) at level {level + 1}")
        current_level = next_level
    return None, expansions, len(seen)


def solve(board, *, max_trouble_outer=8, max_states=10000,
          verbose=True):
    """Outer iterative-deepening on max_trouble. Inner BFS
    runs with the cap; if it exhausts without finding a
    solution, bump the cap by 1 and retry. The hope: caps
    below the puzzle's true peak trouble fail FAST (the
    frontier dies quickly because most moves exceed the cap)."""
    helper = [s for s in board if classify(s) != "other"]
    trouble = [s for s in board if classify(s) == "other"]
    initial = (helper, trouble, [], [])

    total_expansions = 0
    for cap in range(1, max_trouble_outer + 1):
        if verbose:
            print(f"\n========== outer pass: max_trouble={cap} "
                  f"==========")
        plan, expansions, seen = bfs_with_cap(
            initial, cap, max_states=max_states, verbose=verbose)
        total_expansions += expansions
        if plan is not None:
            if verbose:
                print(f"\nVICTORY at cap={cap} in {len(plan)} "
                      f"lines, total expansions across passes: "
                      f"{total_expansions}")
            return plan
        if verbose:
            print(f"  → cap={cap} exhausted "
                  f"({expansions} expansions, {seen} states)")
    return None


if __name__ == "__main__":
    import sqlite3
    import json
    import sys

    sid = int(sys.argv[1]) if len(sys.argv) > 1 else 128
    conn = sqlite3.connect("/home/steve/AngryGopher/prod/gopher.db")
    row = conn.execute(
        "SELECT initial_state_json FROM lynrummy_puzzle_seeds "
        "WHERE session_id=?", (sid,)).fetchone()
    state = json.loads(row[0])

    def s2b(state):
        return [[(bc["card"]["value"], bc["card"]["suit"],
                  bc["card"]["origin_deck"])
                 for bc in stack["board_cards"]]
                for stack in state["board"]]

    hand = state["hands"][state["active_player_index"]]["hand_cards"]
    trouble_card = (hand[0]["card"]["value"], hand[0]["card"]["suit"],
                    hand[0]["card"]["origin_deck"])
    board = s2b(state) + [[trouble_card]]
    print(f"=== bfs_solver session {sid} (trouble={label_d(trouble_card)}) ===")
    plan = solve(board, max_states=200)
    if plan:
        print("\nFinal plan:")
        for i, l in enumerate(plan, 1):
            print(f"  {i}. {l}")
    else:
        print("\nNo plan found.")
