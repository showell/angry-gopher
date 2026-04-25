"""
bfs_solver.py — four-bucket BFS for single-card puzzles.

State buckets:
  HELPER   - original-board complete stacks. Source for extracts.
  TROUBLE  - orphaned cards (singletons or 2-partials) not yet
             committed to a build.
  GROWING  - committed builds. Sealed: no extracts, no
             push-merge, no split. Only further absorption.
  COMPLETE - graduated GROWING stacks. Sealed forever.

Two move types (must touch a trouble card per Steve's invariant):
  (a) Absorb a neighbor into a trouble card. Source = HELPER
      (extract verb) or TROUBLE singleton. Target = TROUBLE
      or GROWING. Target moves to GROWING (or COMPLETE if
      result is legal length 3+).
  (b) Push a trouble card back to HELPER. Source = TROUBLE
      (singleton or 2-partial; NEVER GROWING — sealed).
      Target = HELPER stack such that result stays legal.

Frontier is a min-heap ranked by total trouble cards
(cards in TROUBLE + GROWING).

Heavy instrumentation: every frontier expansion emits a
narration line so a human can follow what the search is
"thinking" about.
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
    n = 0
    for s in trouble:
        n += len(s)
    for s in growing:
        n += len(s)
    return n


def _victory(trouble, growing):
    return not trouble and all(len(s) >= 3 for s in growing)


def _do_extract(helper, src_idx, ci, verb):
    """Extract a card from HELPER. Returns
    (new_helper, spawned_trouble_pieces, ext_card, source_before).
    spawned_trouble_pieces are the pieces of the damaged source
    stack that landed in TROUBLE (singletons or 2-partials)."""
    source = helper[src_idx]
    n = len(source)
    c = source[ci]
    new_helper = helper[:src_idx] + helper[src_idx + 1:]
    spawned = []
    if verb == "peel":
        kind = classify(source)
        if kind == "set":
            remnant = [x for x in source if x != c]
        elif ci == 0:
            remnant = source[1:]
        else:
            remnant = source[:-1]
        new_helper.append(remnant)
    elif verb == "pluck":
        new_helper.append(source[:ci])
        new_helper.append(source[ci + 1:])
    elif verb == "yank":
        left = source[:ci]
        right = source[ci + 1:]
        if len(left) >= 3:
            new_helper.append(left)
        else:
            spawned.append(left)
        if len(right) >= 3:
            new_helper.append(right)
        else:
            spawned.append(right)
    elif verb == "steal":
        kind = classify(source)
        if kind == "set":
            for x in source:
                if x != c:
                    spawned.append([x])
        else:
            if ci == 0:
                spawned.append(source[1:])
            else:
                spawned.append(source[:-1])
    else:
        raise ValueError(f"unknown verb {verb}")
    return new_helper, spawned, c, list(source)


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


def _enumerate_moves(state):
    """Yield (description_dict, new_state) for every legal
    1-line extension."""
    helper, trouble, growing, complete = state
    peelable = _peelable_index(helper)

    # All targets for absorption (move type a). Each entry:
    # (bucket_name, idx_in_bucket, target_stack).
    absorbers = []
    for ti, t in enumerate(trouble):
        absorbers.append(("trouble", ti, t))
    for gi, g in enumerate(growing):
        absorbers.append(("growing", gi, g))

    for bucket, idx, target in absorbers:
        # Neighbor shapes for this absorber.
        shapes = set()
        for c in target:
            shapes |= neighbors(c)

        # Source: HELPER stack via extract.
        for hi, src in enumerate(helper):
            kind = classify(src)
            n = len(src)
            for ci in range(n):
                c = src[ci]
                if (c[0], c[1]) not in shapes:
                    continue
                verb = _verb_for(kind, n, ci)
                if verb is None:
                    continue
                new_helper, spawned, ext_card, source = \
                    _do_extract(helper, hi, ci, verb)
                for side in ("right", "left"):
                    if side == "right":
                        merged = list(target) + [ext_card]
                    else:
                        merged = [ext_card] + list(target)
                    if not partial_ok(merged):
                        continue
                    nh = new_helper
                    if bucket == "trouble":
                        nt_base = [s for i, s in enumerate(trouble)
                                   if i != idx]
                        ng = list(growing)
                    else:
                        nt_base = list(trouble)
                        ng = [s for i, s in enumerate(growing)
                              if i != idx]
                    nt = nt_base + spawned
                    if classify(merged) != "other":
                        nc = complete + [merged]
                        ng_final = ng
                        graduated = True
                    else:
                        nc = list(complete)
                        ng_final = ng + [merged]
                        graduated = False
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
                    yield desc, (nh, nt, ng_final, nc)

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
                if side == "right":
                    merged = list(target) + [loose]
                else:
                    merged = [loose] + list(target)
                if not partial_ok(merged):
                    continue
                nh = list(helper)
                if bucket == "trouble":
                    nt = [s for i, s in enumerate(trouble)
                          if i != idx and i != li]
                    ng = list(growing)
                else:
                    nt = [s for i, s in enumerate(trouble)
                          if i != li]
                    ng = [s for i, s in enumerate(growing)
                          if i != idx]
                if classify(merged) != "other":
                    nc = complete + [merged]
                    ng_final = ng
                    graduated = True
                else:
                    nc = list(complete)
                    ng_final = ng + [merged]
                    graduated = False
                desc = {
                    "type": "free_pull",
                    "loose": loose,
                    "target_before": list(target),
                    "target_bucket_before": bucket,
                    "result": merged,
                    "side": side,
                    "graduated": graduated,
                }
                yield desc, (nh, nt, ng_final, nc)

    # Move type (d): SHIFT — when an end-card of a length-3
    # pure/rb run would normally be steal-pulled (sacrificing
    # the 2-partial remnant), scan HELPER for a peel-eligible
    # donor with the right replacement card. The run shifts:
    # peel donor's P, push P onto source's other end, pop
    # the stolen card. Source stays length-3 legal; donor
    # stays legal; the popped card absorbs onto trouble like
    # a steal-pull would. NO sacrifice.
    for bucket, idx, target in absorbers:
        shapes = set()
        for c in target:
            shapes |= neighbors(c)
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
                        if which_end == 2:
                            new_source = [p_card, source[0], source[1]]
                        else:
                            new_source = [source[1], source[2], p_card]
                        if classify(new_source) != kind:
                            continue
                        for absorb_side in ("right", "left"):
                            if absorb_side == "right":
                                merged = list(target) + [stolen]
                            else:
                                merged = [stolen] + list(target)
                            if not partial_ok(merged):
                                continue
                            nh = ([s for i, s in enumerate(helper)
                                   if i != src_idx
                                   and i != donor_idx]
                                  + [new_source, new_donor])
                            if bucket == "trouble":
                                nt_base = [
                                    s for i, s in enumerate(trouble)
                                    if i != idx]
                                ng = list(growing)
                            else:
                                nt_base = list(trouble)
                                ng = [s for i, s in enumerate(growing)
                                      if i != idx]
                            if classify(merged) != "other":
                                nc = complete + [merged]
                                ng_final = ng
                                graduated = True
                            else:
                                nc = list(complete)
                                ng_final = ng + [merged]
                                graduated = False
                            desc = {
                                "type": "shift",
                                "source": list(source),
                                "donor": list(donor),
                                "stolen": stolen,
                                "p_card": p_card,
                                "new_source": new_source,
                                "new_donor": new_donor,
                                "target_before": list(target),
                                "target_bucket_before": bucket,
                                "merged": merged,
                                "graduated": graduated,
                            }
                            yield desc, (nh, nt_base, ng_final, nc)

    # Move type (c): splice — insert a TROUBLE singleton
    # into a HELPER pure/rb run length 4+. The run splits
    # around the inserted card; both halves must be legal
    # length-3+. One physical gesture in actual Lyn Rummy
    # (drop the card into the middle of the run).
    for ti, t in enumerate(trouble):
        if len(t) != 1:
            continue
        loose = t[0]
        for hi, src in enumerate(helper):
            n = len(src)
            if n < 4:
                continue
            kind = classify(src)
            if kind not in ("pure_run", "rb_run"):
                continue
            for k in range(1, n):
                # C joins left half.
                left = list(src[:k]) + [loose]
                right = list(src[k:])
                if (len(left) >= 3 and len(right) >= 3
                        and classify(left) != "other"
                        and classify(right) != "other"):
                    nh = ([s for i, s in enumerate(helper)
                           if i != hi] + [left, right])
                    nt = [s for i, s in enumerate(trouble)
                          if i != ti]
                    desc = {
                        "type": "splice",
                        "loose": loose,
                        "source": list(src),
                        "k": k, "side": "left",
                        "left_result": left,
                        "right_result": right,
                    }
                    yield desc, (nh, nt, list(growing),
                                 list(complete))
                # C joins right half.
                left = list(src[:k])
                right = [loose] + list(src[k:])
                if (len(left) >= 3 and len(right) >= 3
                        and classify(left) != "other"
                        and classify(right) != "other"):
                    nh = ([s for i, s in enumerate(helper)
                           if i != hi] + [left, right])
                    nt = [s for i, s in enumerate(trouble)
                          if i != ti]
                    desc = {
                        "type": "splice",
                        "loose": loose,
                        "source": list(src),
                        "k": k, "side": "right",
                        "left_result": left,
                        "right_result": right,
                    }
                    yield desc, (nh, nt, list(growing),
                                 list(complete))

    # Move type (b): push a TROUBLE card onto a HELPER stack.
    for ti, t in enumerate(trouble):
        if len(t) > 2:
            continue
        for hi, h in enumerate(helper):
            for side in ("right", "left"):
                if side == "right":
                    merged = list(h) + list(t)
                else:
                    merged = list(t) + list(h)
                if classify(merged) == "other":
                    continue
                nh = ([s for i, s in enumerate(helper)
                       if i != hi] + [merged])
                nt = [s for i, s in enumerate(trouble) if i != ti]
                desc = {
                    "type": "push",
                    "trouble_before": list(t),
                    "target_before": list(h),
                    "result": merged,
                    "side": side,
                }
                yield desc, (nh, nt, list(growing), list(complete))


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
        return (f"shift {p} to pop {stolen} "
                f"[{new_donor} -> {shifted}]")
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


def _bfs_with_cap(initial, max_trouble, *, max_states, verbose):
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
        if verbose:
            print(f"\n--- level {level}: expanding "
                  f"{len(current_level)} program(s) ---")
        next_level = []
        for state, program in current_level:
            expansions += 1
            for desc, new_state in _enumerate_moves(state):
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
    helper = []
    trouble = []
    for s in board:
        if classify(s) == "other":
            trouble.append(s)
        else:
            helper.append(s)
    initial = (helper, trouble, [], [])

    total_expansions = 0
    for cap in range(1, max_trouble_outer + 1):
        if verbose:
            print(f"\n========== outer pass: max_trouble={cap} "
                  f"==========")
        plan, expansions, seen = _bfs_with_cap(
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
