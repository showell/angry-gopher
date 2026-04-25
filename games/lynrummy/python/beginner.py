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

def _find(board, c):
    for si, stack in enumerate(board):
        for ci, x in enumerate(stack):
            if x == c:
                return si, ci
    raise ValueError(f"{label(c)} not on board")


def _can_peel(stack, ci):
    n = len(stack)
    kind = classify(stack)
    if kind == "set" and n >= 4:
        return True
    if kind in ("pure_run", "rb_run") and n >= 4 and (
            ci == 0 or ci == n - 1):
        return True
    return False


def _can_pluck(stack, ci):
    n = len(stack)
    kind = classify(stack)
    return (kind in ("pure_run", "rb_run")
            and 3 <= ci <= n - 4)


def _can_steal(stack, ci):
    """Steal: extract a card from a length-3 legal stack,
    leaving a length-2 illegal remnant behind. The only
    justification is a later move that reuses the extracted
    card. More expensive than peel (which keeps remnants
    legal). Length-3 runs steal from end positions only;
    length-3 sets steal from any position (sets are
    unordered)."""
    n = len(stack)
    kind = classify(stack)
    if n != 3:
        return False
    if kind in ("pure_run", "rb_run"):
        return ci == 0 or ci == n - 1
    if kind == "set":
        return True
    return False


def _can_yank(stack, ci):
    """Yank: pull from an inner-but-not-deep position of a
    long run. One side is a legal sub-run (length 3+); the
    other side is a singleton or 2-partial. Costlier than
    pluck (which leaves both halves legal), cheaper or equal
    to steal in the singleton case."""
    n = len(stack)
    kind = classify(stack)
    if kind not in ("pure_run", "rb_run"):
        return False
    if ci == 0 or ci == n - 1:
        return False
    if 3 <= ci <= n - 4:
        return False  # pluck
    left_len = ci
    right_len = n - ci - 1
    return (max(left_len, right_len) >= 3
            and min(left_len, right_len) >= 1)


def peel(board, c):
    si, ci = _find(board, c)
    stack = board[si]
    new = [s[:] for s in board]
    if classify(stack) == "set":
        new[si] = [x for x in stack if x != c]
    elif ci == 0:
        new[si] = stack[1:]
    else:
        new[si] = stack[:-1]
    new.append([c])
    return new


def steal(board, c):
    """Run steal: leaves a length-2 partial remnant.
    Set steal: fully dismantles the 3-set — the two
    non-stolen cards become individual singletons (rather
    than a 2-set partial). The mental model: with the third
    card gone there's no realistic path back to a set, so
    the partial framing is misleading."""
    si, ci = _find(board, c)
    stack = board[si]
    kind = classify(stack)
    new = [s[:] for i, s in enumerate(board) if i != si]
    if kind == "set":
        for x in stack:
            if x != c:
                new.append([x])
    else:
        if ci == 0:
            new.append(stack[1:])
        else:
            new.append(stack[:-1])
    new.append([c])
    return new


def pluck(board, c):
    si, ci = _find(board, c)
    stack = board[si]
    new = [s[:] for i, s in enumerate(board) if i != si]
    new.append(stack[:ci])
    new.append([c])
    new.append(stack[ci + 1:])
    return new


def yank(board, c):
    """Same split mechanic as pluck, but the call site has
    decided one half is a short partial (singleton or
    2-partial). The cost is paid by the caller via taboo +
    follow-up plans."""
    si, ci = _find(board, c)
    stack = board[si]
    new = [s[:] for i, s in enumerate(board) if i != si]
    new.append(stack[:ci])
    new.append([c])
    new.append(stack[ci + 1:])
    return new


def _absorb(board, c, target_sig, side):
    """Move loose `c` onto the stack anchored by `target_sig`
    on the named side. Mechanic for pulling the loose into
    its destination — never narrated as a verb. The narrator
    sees the trouble card as the actor doing the pull."""
    si_src, _ = _find(board, c)
    if len(board[si_src]) != 1:
        raise ValueError(f"absorb: {label(c)} is not a loose singleton")
    si_tgt = None
    for i, s in enumerate(board):
        if i == si_src:
            continue
        if s and s[0] == target_sig:
            si_tgt = i
            break
    if si_tgt is None:
        raise ValueError(f"absorb: no stack anchored by {label(target_sig)}")
    new = [s[:] for s in board]
    loose = new.pop(si_src)
    if si_tgt > si_src:
        si_tgt -= 1
    if side == "left":
        new[si_tgt] = loose + new[si_tgt]
    else:
        new[si_tgt] = new[si_tgt] + loose
    return new


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
    """`2C 3C 4C peel-pushes 2C 3C 4C [5C] {-5C- 5H 5S}` —
    target-before (a LEGAL stack) is the subject; the
    helper is extracted from `source` and pushed onto the
    target. Same shape as the pull line, just `-pushes`
    instead of `-pulls` and the absorber was already legal."""
    tb = _stack_label(target_before)
    res = _stack_with_marker(result, ext_card, "[{}]")
    src = _stack_with_marker(source, ext_card, "-{}-")
    return f"{tb} {verb}-pushes {res} {{{src}}}"


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


def _try_extract(board, shapes, verbs=("peel", "pluck")):
    """Yield (verb_name, extracted_card, source_stack, new_board,
    taboo_partners) for every legal extraction whose card
    matches `shapes`."""
    for si, stack in enumerate(board):
        if len(stack) <= 1:
            continue
        source = list(stack)
        for ci, c in enumerate(stack):
            if (c[0], c[1]) not in shapes:
                continue
            if "peel" in verbs and _can_peel(stack, ci):
                yield "peel", c, source, peel(board, c), frozenset()
            elif "pluck" in verbs and _can_pluck(stack, ci):
                yield "pluck", c, source, pluck(board, c), frozenset()
            elif "yank" in verbs and _can_yank(stack, ci):
                partners = frozenset(x for x in stack if x != c)
                yield "yank", c, source, yank(board, c), partners
            elif "steal" in verbs and _can_steal(stack, ci):
                partners = frozenset(x for x in stack if x != c)
                yield "steal", c, source, steal(board, c), partners


def _try_pushes(board, taboo=None, only_loose=None):
    """Push: a loose card lands on a LEGAL stack such that
    the result is also legal (3-set growing to 4-set, run
    growing by one card on an end). Push is Δ trouble ≤ 0:
    the loose dissolves into a legal stack with no source-
    side disruption."""
    taboo = taboo or {}
    options = []
    looses = [only_loose] if only_loose is not None else _looses(board)
    for c in looses:
        forbidden = taboo.get(c, frozenset())
        for si, stack in enumerate(board):
            if not stack or stack[0] == c:
                continue
            if classify(stack) == "other":
                continue
            if any(x in forbidden for x in stack):
                continue
            old_target = list(stack)
            for side in ("right", "left"):
                try:
                    new = _absorb(board, c, stack[0], side)
                except ValueError:
                    continue
                for s2 in new:
                    if c in s2:
                        if classify(s2) == "other":
                            break
                        priority = _result_priority(s2)
                        options.append(
                            (priority, c, old_target, side, new, list(s2)))
                        break
    options.sort(key=lambda x: x[0])
    for _, c, tgt, side, new, result in options:
        yield c, tgt, side, new, result


def _push_line(loose, target_before, result):
    return (f"{label_d(loose)} pushes-onto "
            f"{_stack_with_marker(result, loose, '[{}]')} "
            f"{{{_stack_label(target_before)}}}")


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
    """`2C:1 3C 4C push-merges 2C:1 3C 4C [5C 6C]` —
    target-before (legal) is the subject; the whole 2-partial
    source is bracketed where it landed in the result."""
    block_size = len(source_partial)
    return (f"{_stack_label(target_before)} push-merges "
            f"{_stack_with_block(result, block_size, side)}")


def _try_push_merges(board, taboo=None):
    """Push-merge: a 2-partial trouble stack glues onto a
    legal stack such that the combined stack is legal. Both
    partial cards absorbed at once. Δ trouble = -2."""
    taboo = taboo or {}
    options = []
    for src_si, src_stack in enumerate(board):
        if len(src_stack) != 2:
            continue
        if classify(src_stack) != "other":
            continue
        forbidden_a = taboo.get(src_stack[0], frozenset())
        forbidden_b = taboo.get(src_stack[1], frozenset())
        for tgt_si, tgt_stack in enumerate(board):
            if tgt_si == src_si:
                continue
            if classify(tgt_stack) == "other":
                continue
            if any(x in forbidden_a or x in forbidden_b for x in tgt_stack):
                continue
            for side in ("right", "left"):
                if side == "right":
                    merged = list(tgt_stack) + list(src_stack)
                else:
                    merged = list(src_stack) + list(tgt_stack)
                if classify(merged) == "other":
                    continue
                new = [s[:] for i, s in enumerate(board)
                       if i != src_si and i != tgt_si]
                new.append(merged)
                priority = _result_priority(merged)
                options.append(
                    (priority, list(src_stack), list(tgt_stack),
                     side, new, merged))
    options.sort(key=lambda x: x[0])
    for _, sp, tgt, side, new, result in options:
        yield sp, tgt, side, new, result


def _try_pulls(board, taboo=None, only_loose=None):
    """For each loose card and each trouble stack, yield a
    pull: trouble absorbs the loose onto its stack. The
    trouble stack is the actor; the loose is the helper.

    `only_loose` restricts the loose to a single card —
    used by compound moves so the just-extracted helper is
    the one absorbed (and not the original trouble singleton
    inverting the role).

    Yield (loose, trouble_stack_before, side, new_board,
    trouble_stack_after). A loose may not rejoin a stack
    that contains any of its taboo cards."""
    taboo = taboo or {}

    def is_trouble(s):
        return classify(s) == "other"

    options = []
    looses = [only_loose] if only_loose is not None else _looses(board)
    for c in looses:
        forbidden = taboo.get(c, frozenset())
        for si, stack in enumerate(board):
            if not stack or stack[0] == c:
                continue
            if not is_trouble(stack):
                continue
            if any(x in forbidden for x in stack):
                continue
            old_trouble = list(stack)
            for side in ("right", "left"):
                try:
                    new = _absorb(board, c, stack[0], side)
                except ValueError:
                    continue
                for s2 in new:
                    if c in s2:
                        if not partial_ok(s2):
                            break
                        priority = _result_priority(s2)
                        options.append(
                            (priority, c, old_trouble, side, new, list(s2)))
                        break
    options.sort(key=lambda x: x[0])
    for _, c, tgt, side, new, result in options:
        yield c, tgt, side, new, result


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

    def _board_sig(board):
        return tuple(sorted(tuple(sorted(s)) for s in board))

    def search(board, steps, budget, taboo, visited):
        state["nodes"] += 1
        if state["nodes"] > max_nodes:
            return None
        if time.time() > state["deadline"]:
            return None
        if not trouble(board):
            return steps
        if budget == 0:
            return None
        sig = _board_sig(board)
        if sig in visited:
            return None
        visited.add(sig)

        # Tier 0a: free pull. A loose already on the board
        # gets pulled in by some trouble stack — no extract
        # cost, no budget decrement.
        for loose, trouble_before, side, after, result in \
                _try_pulls(board, taboo):
            line = _free_pull_line(loose, trouble_before, result)
            found = search(after,
                           steps + [(line, after)],
                           budget, taboo, visited)
            if found is not None:
                return found

        # Tier 0b: free push. A loose lands on a legal stack
        # whose result is also legal — orphan absorbed, no
        # source-side disruption, no budget decrement.
        for loose, target_before, side, after, result in \
                _try_pushes(board, taboo):
            line = _push_line(loose, target_before, result)
            found = search(after,
                           steps + [(line, after)],
                           budget, taboo, visited)
            if found is not None:
                return found

        # Tier 0c: free push-merge. A 2-partial trouble glues
        # onto a legal stack such that the combined stack is
        # legal. Both partial cards dissolve at once.
        for src_partial, target_before, side, after, result in \
                _try_push_merges(board, taboo):
            line = _push_merge_line(src_partial, target_before,
                                    side, result)
            found = search(after,
                           steps + [(line, after)],
                           budget, taboo, visited)
            if found is not None:
                return found

        direct = neighbor_shapes(board)
        tiers = [
            (direct, ("peel", "pluck")),
            (direct, ("yank",)),
            (direct, ("steal",)),
        ]
        for shapes, verbs in tiers:
            for verb_name, ext_card, source, after_pp, partners \
                    in _try_extract(board, shapes, verbs):
                new_taboo = taboo
                if partners:
                    new_taboo = dict(taboo)
                    new_taboo[ext_card] = new_taboo.get(
                        ext_card, frozenset()) | partners
                # Compound: extract + pull (loose absorbs onto
                # trouble).
                for loose, trouble_before, _side, after, result in \
                        _try_pulls(after_pp, new_taboo,
                                   only_loose=ext_card):
                    line = _compound_pull_line(
                        verb_name, ext_card, source,
                        trouble_before, result)
                    found = search(after,
                                   steps + [(line, after)],
                                   budget - 1, new_taboo, visited)
                    if found is not None:
                        return found
                # Compound: extract + push (loose lands on a
                # legal stack such that it stays legal).
                for loose, target_before, _side, after, result in \
                        _try_pushes(after_pp, new_taboo,
                                    only_loose=ext_card):
                    line = _compound_push_line(
                        verb_name, ext_card, source,
                        target_before, result)
                    found = search(after,
                                   steps + [(line, after)],
                                   budget - 1, new_taboo, visited)
                    if found is not None:
                        return found
        return None

    start = time.time()
    plan = None
    for depth_limit in range(1, max_compound + 1):
        plan = search(board, [], depth_limit, {}, set())
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
