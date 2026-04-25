"""
beginner.py — minimal LynRummy beginner solver.

No geometry. A board is a list of stacks; a stack is a list of
cards; a card is a tuple (value, suit, deck).

Three verbs:
  peel(board, c)      extract `c` from a run edge or size-4+ set
  pluck(board, c)     extract `c` from the middle of a slack run
                      (both remnants stay legal)
  extend(board, c,    move loose `c` onto the target stack on
         target_sig,  either side
         side)

The planner "beginner_plan" plays like a junior card player:
  - trouble card = any card not currently in a legal group
  - only consider plucking/peeling cards that are immediate
    neighbors of a trouble card (pure / rb / set partners)
  - after extracting a neighbor, immediately extend some loose
    (consuming or restructuring a trouble card)
  - iterate until the board has no trouble stacks
"""

from itertools import product

# --- Card + board model ---

RANKS = "A23456789TJQK"
SUITS = "CDSH"           # Clubs Diamonds Spades Hearts
RED = {1, 3}             # Diamonds, Hearts


def card(label, deck=0):
    """'5H' → (5, 3, 0). 'TC:1' → (10, 0, 1)."""
    if ":" in label:
        label, d = label.split(":")
        deck = int(d)
    return (RANKS.index(label[0]) + 1,
            SUITS.index(label[1]),
            deck)


def label(c):
    v, s, _ = c
    return RANKS[v - 1] + SUITS[s]


def label_d(c):
    """Label that includes deck suffix when non-zero. Used
    in DSL output where two cards of the same value+suit
    can co-exist (one per deck) and need to be told apart."""
    v, s, d = c
    base = RANKS[v - 1] + SUITS[s]
    return f"{base}:{d}" if d else base


def show(board):
    for stack in board:
        print(" ".join(label(c) for c in stack))


# --- Classification ---

def _succ(v):
    return 1 if v == 13 else v + 1


def _color(s):
    return "red" if s in RED else "black"


def classify(stack):
    n = len(stack)
    if n < 3:
        return "other"
    vals = [c[0] for c in stack]
    suits = [c[1] for c in stack]
    if len(set(vals)) == 1 and len(set(suits)) == len(suits):
        return "set"
    for i in range(1, n):
        if vals[i] != _succ(vals[i - 1]):
            return "other"
    if len(set(suits)) == 1:
        return "pure_run"
    colors = [_color(s) for s in suits]
    if all(colors[i] != colors[i - 1] for i in range(1, n)):
        return "rb_run"
    return "other"


def partial_ok(stack):
    """True if `stack` is a legal group OR a length-2 partial
    that could grow into one. Used to validate intermediate
    extends — a beginner is allowed to pair up two cards into a
    transient they'll finish on the next move."""
    n = len(stack)
    if n == 0:
        return True
    if n == 1:
        return True  # a lone card is a legit trouble state
    if n >= 3:
        return classify(stack) != "other"
    a, b = stack
    # Pair that could be a run partial:
    if _succ(a[0]) == b[0]:
        if a[1] == b[1]:
            return True  # pure-run partial
        if _color(a[1]) != _color(b[1]):
            return True  # rb-run partial
    # Pair that could be a set partial:
    if a[0] == b[0] and a[1] != b[1]:
        return True
    return False


# --- Trouble cards + neighbors ---

def trouble(board):
    """Cards that aren't currently in a legal group."""
    out = []
    for stack in board:
        if classify(stack) == "other":
            out.extend(stack)
    return out


def neighbors(c):
    """(value, suit) shapes that could sit adjacent to `c` in
    some valid group. Deck-agnostic."""
    v, s, _ = c
    c_color = _color(s)
    pred = 13 if v == 1 else v - 1
    succ = _succ(v)
    out = set()
    # pure run: same suit, ±1 value
    out.add((pred, s))
    out.add((succ, s))
    # rb run: opposite color, ±1 value
    for ss in range(4):
        if _color(ss) != c_color:
            out.add((pred, ss))
            out.add((succ, ss))
    # set: same value, different suit
    for ss in range(4):
        if ss != s:
            out.add((v, ss))
    return out


def almost_neighbors(c):
    """Shapes 2 values away in a plausible run — same color as
    `c`, since a run alternates colors and positions 2 apart
    share a color. For 6C (black): {4C, 4S, 8C, 8S}."""
    v, s, _ = c
    c_color = _color(s)
    def step_back(n, k):
        for _ in range(k):
            n = 13 if n == 1 else n - 1
        return n
    def step_fwd(n, k):
        for _ in range(k):
            n = _succ(n)
        return n
    pred2 = step_back(v, 2)
    succ2 = step_fwd(v, 2)
    out = set()
    for ss in range(4):
        if _color(ss) == c_color:
            out.add((pred2, ss))
            out.add((succ2, ss))
    return out


def neighbor_shapes(board):
    shapes = set()
    for c in trouble(board):
        shapes |= neighbors(c)
    return shapes


def almost_neighbor_shapes(board):
    shapes = set()
    for c in trouble(board):
        shapes |= almost_neighbors(c)
    return shapes


# --- Verb implementations (board → new board) ---

# --- Planner ---

def _stack_label(stack):
    return " ".join(label_d(x) for x in stack)


def _stack_with_marker(stack, marker_card, marker_template):
    """Render `stack` with `marker_card` wrapped in
    `marker_template` (e.g. '[{}]' or '-{}-')."""
    out = []
    for c in stack:
        s = label_d(c)
        if c == marker_card:
            s = marker_template.format(s)
        out.append(s)
    return " ".join(out)


def _free_pull_line(loose, trouble_before, result):
    return (f"{_stack_label(trouble_before)} pulls "
            f"{_stack_with_marker(result, loose, '[{}]')}")


def _compound_pull_line(verb, ext_card, source, trouble_before, result):
    """`5C 6C peel-pulls [4C] 5C 6C {-4C- 4D 4S 4H}` —
    trouble-before is the subject; the result stack shows
    the helper bracketed where it landed; the source stack
    (in braces) shows the helper struck through where it
    left."""
    tb = _stack_label(trouble_before)
    res = _stack_with_marker(result, ext_card, "[{}]")
    src = _stack_with_marker(source, ext_card, "-{}-")
    return f"{tb} {verb}-pulls {res} {{{src}}}"


def _compound_push_line(verb, ext_card, source, target_before, result):
    """`peel-pushes 2C 3C 4C [5C] {-5C- 5H 5S}` — the result
    shows the legal target with the helper bracketed where
    it landed; the source braces show where the helper came
    from with the extracted card struck. No leading subject:
    the target prefix in the result already names the
    absorber."""
    res = _stack_with_marker(result, ext_card, "[{}]")
    src = _stack_with_marker(source, ext_card, "-{}-")
    return f"{verb}-pushes {res} {{{src}}}"


def _looses(board):
    return [s[0] for s in board if len(s) == 1]


def _result_priority(stack):
    """Lower = preferred. Pure runs read most cleanly to a
    human eye (single suit), so the search tries pure-result
    moves first; sets next; rb_runs after; partials last."""
    kind = classify(stack)
    if kind == "pure_run":
        return 0
    if kind == "set":
        return 1
    if kind == "rb_run":
        return 2
    return 3


def _can_peel_kind(kind, n, ci):
    if kind == "set" and n >= 4:
        return True
    if kind in ("pure_run", "rb_run") and n >= 4 and (
            ci == 0 or ci == n - 1):
        return True
    return False


def _can_pluck_kind(kind, n, ci):
    return kind in ("pure_run", "rb_run") and 3 <= ci <= n - 4


def _can_yank_kind(kind, n, ci):
    if kind not in ("pure_run", "rb_run"):
        return False
    if ci == 0 or ci == n - 1 or 3 <= ci <= n - 4:
        return False
    left_len = ci
    right_len = n - ci - 1
    return (max(left_len, right_len) >= 3
            and min(left_len, right_len) >= 1)


def _can_steal_kind(kind, n, ci):
    if n != 3:
        return False
    if kind in ("pure_run", "rb_run"):
        return ci == 0 or ci == n - 1
    return kind == "set"


def _do_extract(complete, trouble, src_idx, ci, verb):
    """Apply an extract verb to complete[src_idx] at ci.
    Returns (new_complete, new_trouble, ext_card, source, partners).
    Steve's invariant in code: ONE complete stack damaged,
    becoming 0/1/2 new trouble pieces; loose enters trouble."""
    source = complete[src_idx]
    n = len(source)
    c = source[ci]
    nc = complete[:src_idx] + complete[src_idx + 1:]
    nt = list(trouble)
    if verb == "peel":
        kind = classify(source)
        if kind == "set":
            remnant = [x for x in source if x != c]
        elif ci == 0:
            remnant = source[1:]
        else:
            remnant = source[:-1]
        nc.append(remnant)
        nt.append([c])
        return nc, nt, c, list(source), frozenset()
    if verb == "pluck":
        nc.append(source[:ci])
        nc.append(source[ci + 1:])
        nt.append([c])
        return nc, nt, c, list(source), frozenset()
    if verb == "yank":
        left = source[:ci]
        right = source[ci + 1:]
        (nc if len(left) >= 3 else nt).append(left)
        (nc if len(right) >= 3 else nt).append(right)
        nt.append([c])
        partners = frozenset(x for x in source if x != c)
        return nc, nt, c, list(source), partners
    if verb == "steal":
        kind = classify(source)
        if kind == "set":
            for x in source:
                if x != c:
                    nt.append([x])
        else:
            if ci == 0:
                nt.append(source[1:])
            else:
                nt.append(source[:-1])
        nt.append([c])
        partners = frozenset(x for x in source if x != c)
        return nc, nt, c, list(source), partners
    raise ValueError(f"unknown verb {verb}")


def _try_extracts(complete, trouble, shapes):
    """Yield (verb, ext_card, source, new_complete, new_trouble,
    partners) for every legal extraction whose card matches
    `shapes`. Operates only on the complete bucket — extracts
    take from legal stacks."""
    for src_idx, source in enumerate(complete):
        n = len(source)
        kind = classify(source)
        for ci, c in enumerate(source):
            if (c[0], c[1]) not in shapes:
                continue
            if _can_peel_kind(kind, n, ci):
                nc, nt, ec, src, p = _do_extract(
                    complete, trouble, src_idx, ci, "peel")
                yield "peel", ec, src, nc, nt, p
            elif _can_pluck_kind(kind, n, ci):
                nc, nt, ec, src, p = _do_extract(
                    complete, trouble, src_idx, ci, "pluck")
                yield "pluck", ec, src, nc, nt, p
            elif _can_yank_kind(kind, n, ci):
                nc, nt, ec, src, p = _do_extract(
                    complete, trouble, src_idx, ci, "yank")
                yield "yank", ec, src, nc, nt, p
            elif _can_steal_kind(kind, n, ci):
                nc, nt, ec, src, p = _do_extract(
                    complete, trouble, src_idx, ci, "steal")
                yield "steal", ec, src, nc, nt, p


def _loose_indices(trouble, only_loose=None):
    """Indices in trouble pointing at singleton stacks.
    When only_loose is given, returns [idx] for that
    specific loose — using trouble[-1] as the fast path
    since extracts always append the new loose at the end."""
    if only_loose is not None:
        if trouble and len(trouble[-1]) == 1 and trouble[-1][0] == only_loose:
            return [len(trouble) - 1]
        for i, s in enumerate(trouble):
            if len(s) == 1 and s[0] == only_loose:
                return [i]
        return []
    return [i for i, s in enumerate(trouble) if len(s) == 1]


def _try_pushes(complete, trouble, taboo=None, only_loose=None):
    """Push: a loose (singleton trouble stack) lands on a
    complete stack such that the result is still complete.
    Yields (loose, target_before, side, new_complete,
    new_trouble, result)."""
    taboo = taboo or {}
    for src_idx in _loose_indices(trouble, only_loose):
        loose = trouble[src_idx][0]
        forbidden = taboo.get(loose, frozenset())
        for tgt_idx, tgt in enumerate(complete):
            if any(x in forbidden for x in tgt):
                continue
            for side in ("right", "left"):
                merged = (list(tgt) + [loose] if side == "right"
                          else [loose] + list(tgt))
                if classify(merged) == "other":
                    continue
                nc = ([s for i, s in enumerate(complete)
                       if i != tgt_idx] + [merged])
                nt = [s for i, s in enumerate(trouble)
                      if i != src_idx]
                yield loose, list(tgt), side, nc, nt, merged


def _push_line(loose, target_before, result):
    """`pushes-onto [AH] 2H 3H 4H` — the bracket marks where
    the loose landed; the unbracketed cards are the target's
    pre-existing cards. No leading subject (would repeat the
    bracket) and no source braces (would repeat the result
    minus bracket)."""
    return (f"pushes-onto "
            f"{_stack_with_marker(result, loose, '[{}]')}")


def _stack_with_block(stack, block_size, side):
    """Render `stack` with `block_size` contiguous cards
    bracketed on the named side. Used for push-merge: the
    whole 2-partial source becomes a [bracketed] chunk
    glued onto the legal target."""
    if side == "right":
        head, block = stack[:-block_size], stack[-block_size:]
        head_s = " ".join(label_d(c) for c in head)
        block_s = " ".join(label_d(c) for c in block)
        return f"{head_s} [{block_s}]" if head_s else f"[{block_s}]"
    block, tail = stack[:block_size], stack[block_size:]
    block_s = " ".join(label_d(c) for c in block)
    tail_s = " ".join(label_d(c) for c in tail)
    return f"[{block_s}] {tail_s}" if tail_s else f"[{block_s}]"


def _push_merge_line(source_partial, target_before, side, result):
    """`push-merges 2C:1 3C 4C [5C 6C]` — the result shows
    the legal target with the absorbed 2-partial bracketed
    as a contiguous block; no leading subject (would repeat
    the target prefix in the result)."""
    block_size = len(source_partial)
    return (f"push-merges "
            f"{_stack_with_block(result, block_size, side)}")


def _try_push_merges(complete, trouble, taboo=None):
    """Push-merge: a 2-partial trouble glues onto a complete
    stack such that the merged result is still complete.
    Both partial cards absorbed at once. Yields (src_partial,
    target_before, side, new_complete, new_trouble, result)."""
    taboo = taboo or {}
    for src_idx, src in enumerate(trouble):
        if len(src) != 2:
            continue
        forbidden_a = taboo.get(src[0], frozenset())
        forbidden_b = taboo.get(src[1], frozenset())
        for tgt_idx, tgt in enumerate(complete):
            if any(x in forbidden_a or x in forbidden_b for x in tgt):
                continue
            for side in ("right", "left"):
                merged = (list(tgt) + list(src) if side == "right"
                          else list(src) + list(tgt))
                if classify(merged) == "other":
                    continue
                nc = ([s for i, s in enumerate(complete)
                       if i != tgt_idx] + [merged])
                nt = [s for i, s in enumerate(trouble)
                      if i != src_idx]
                yield list(src), list(tgt), side, nc, nt, merged


def _try_pulls(complete, trouble, taboo=None, only_loose=None):
    """Pull: a loose (singleton in trouble) absorbs onto
    another trouble stack. Result lands in complete bucket
    (if it classifies legal) or back in trouble (still
    partial). Yields (loose, target_before, side,
    new_complete, new_trouble, result)."""
    taboo = taboo or {}
    for src_idx in _loose_indices(trouble, only_loose):
        loose = trouble[src_idx][0]
        forbidden = taboo.get(loose, frozenset())
        for tgt_idx, tgt in enumerate(trouble):
            if tgt_idx == src_idx:
                continue
            if any(x in forbidden for x in tgt):
                continue
            for side in ("right", "left"):
                merged = (list(tgt) + [loose] if side == "right"
                          else [loose] + list(tgt))
                if not partial_ok(merged):
                    continue
                nt_base = [s for i, s in enumerate(trouble)
                           if i != src_idx and i != tgt_idx]
                if classify(merged) != "other":
                    nc = list(complete) + [merged]
                    nt = nt_base
                else:
                    nc = list(complete)
                    nt = nt_base + [merged]
                yield loose, list(tgt), side, nc, nt, merged


def beginner_plan(board, *, max_compound=6, max_nodes=200_000,
                  max_seconds=10.0, verbose=False):
    """Returns list of (line, board_after) — the SHORTEST plan
    using up to `max_compound` compound moves. Returns None if
    no plan terminates within node/time budgets.

    Uses iterative deepening (IDDFS): try depth=1 first, then
    2, then 3, etc. Returns the first plan found, which is
    guaranteed to be shortest. DFS skeleton at each depth
    keeps memory linear; cumulative cost is dominated by the
    final depth.

    Safety nets:
      - max_compound: depth cap
      - max_nodes: total search-node count across all depths
      - max_seconds: wall-clock cap across all depths
      - per-depth visited cache: skip seen board states
    """
    import time

    state = {"nodes": 0, "deadline": time.time() + max_seconds}

    def _state_sig(complete, trouble):
        c_sig = tuple(sorted(tuple(sorted(s)) for s in complete))
        t_sig = tuple(sorted(tuple(sorted(s)) for s in trouble))
        return (c_sig, t_sig)

    def _trouble_count(trouble):
        n = 0
        for s in trouble:
            n += len(s)
        return n

    def _shapes_from_trouble(trouble):
        out = set()
        for s in trouble:
            for c in s:
                out |= neighbors(c)
        return out

    def search(complete, trouble, steps, budget, taboo, visited):
        state["nodes"] += 1
        if state["nodes"] > max_nodes:
            return None
        if time.time() > state["deadline"]:
            return None
        if not trouble:
            return steps  # all stacks complete
        if budget == 0:
            return None
        sig = _state_sig(complete, trouble)
        prev_budget = visited.get(sig, -1)
        if budget <= prev_budget:
            return None
        visited[sig] = budget

        shapes = _shapes_from_trouble(trouble)

        # Collect every candidate move in one flat list. Each
        # entry is (trouble_count_after, budget_cost, line,
        # new_complete, new_trouble, taboo).
        candidates = []

        for loose, tb, _side, nc, nt, result in \
                _try_pulls(complete, trouble, taboo):
            line = _free_pull_line(loose, tb, result)
            candidates.append(
                (_trouble_count(nt), 0, line, nc, nt, taboo))

        for loose, tb, _side, nc, nt, result in \
                _try_pushes(complete, trouble, taboo):
            line = _push_line(loose, tb, result)
            candidates.append(
                (_trouble_count(nt), 0, line, nc, nt, taboo))

        for src_partial, tb, side, nc, nt, result in \
                _try_push_merges(complete, trouble, taboo):
            line = _push_merge_line(src_partial, tb, side, result)
            candidates.append(
                (_trouble_count(nt), 0, line, nc, nt, taboo))

        for verb, ec, src, post_c, post_t, partners in \
                _try_extracts(complete, trouble, shapes):
            new_taboo = taboo
            if partners:
                new_taboo = dict(taboo)
                new_taboo[ec] = (
                    new_taboo.get(ec, frozenset()) | partners)
            for loose, tb, _side, nc, nt, result in \
                    _try_pulls(post_c, post_t, new_taboo,
                               only_loose=ec):
                line = _compound_pull_line(verb, ec, src, tb, result)
                candidates.append(
                    (_trouble_count(nt), 1, line, nc, nt, new_taboo))
            for loose, tb, _side, nc, nt, result in \
                    _try_pushes(post_c, post_t, new_taboo,
                                only_loose=ec):
                line = _compound_push_line(verb, ec, src, tb, result)
                candidates.append(
                    (_trouble_count(nt), 1, line, nc, nt, new_taboo))

        candidates.sort(key=lambda x: (x[0], x[1]))
        for _t, b_cost, line, nc, nt, ct in candidates:
            after_board = list(nc) + list(nt)
            found = search(nc, nt,
                           steps + [(line, after_board)],
                           budget - b_cost, ct, visited)
            if found is not None:
                return found
        return None

    # Partition the input board into complete and trouble buckets.
    init_complete = []
    init_trouble = []
    for s in board:
        if classify(s) == "other":
            init_trouble.append(s)
        else:
            init_complete.append(s)

    start = time.time()
    plan = None
    for depth_limit in range(1, max_compound + 1):
        plan = search(init_complete, init_trouble, [],
                      depth_limit, {}, {})
        if plan is not None:
            break
        if (state["nodes"] > max_nodes
                or time.time() > state["deadline"]):
            break
    elapsed = time.time() - start
    if verbose:
        if plan:
            status = f"solved at depth {len(plan)}"
        elif state["nodes"] > max_nodes:
            status = "exhausted (nodes)"
        elif time.time() > state["deadline"]:
            status = "exhausted (time)"
        else:
            status = "stuck"
        print(f"  [search] nodes={state['nodes']:>6}  "
              f"time={elapsed:.2f}s  {status}")
    return plan


# --- Harness ---

def run(board, d2_card):
    """Show the starting board, then solve for `d2_card` as the
    stuck-card, printing after every step."""
    print("initial board:")
    show(board)
    print()
    board = board + [[d2_card]]
    print("after dropping trouble card:")
    show(board)
    print()
    plan = beginner_plan(board)
    if plan is None:
        print("STUCK")
        return
    for i, (line, state) in enumerate(plan, 1):
        print(f"step {i}: {line}")
        show(state)
        print()


def canonical_deck():
    """4/8 deck: two sets + long wrap runs + short 5-6-7 runs."""
    board = []
    board.append([card(f"4{s}") for s in SUITS])
    board.append([card(f"8{s}") for s in SUITS])
    for s in SUITS:
        board.append([card(f"{r}{s}") for r in "9TJQKA23"])
    for s in SUITS:
        board.append([card(f"{r}{s}") for r in "567"])
    return board


if __name__ == "__main__":
    run(canonical_deck(), card("2C", deck=1))
