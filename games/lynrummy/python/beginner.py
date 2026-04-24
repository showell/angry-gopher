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
    """Steal: extract a card from a length-3 rigid run,
    leaving a length-2 illegal remnant behind. The only
    justification is a later extend that repairs or reuses
    the orphan. Beginner-accessible but more expensive than
    peel (which keeps remnants legal)."""
    n = len(stack)
    kind = classify(stack)
    return (kind in ("pure_run", "rb_run")
            and n == 3 and (ci == 0 or ci == n - 1))


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
    """Same mechanic as a run-edge peel, but applied when the
    remnant is illegal (length 2). Caller justifies the mess
    by a later extend that repairs or reuses the orphan."""
    si, ci = _find(board, c)
    stack = board[si]
    new = [s[:] for s in board]
    if ci == 0:
        new[si] = stack[1:]
    else:
        new[si] = stack[:-1]
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


def extend(board, c, target_sig, side):
    """Extend loose `c` onto the stack whose card tuple at
    position 0 equals `target_sig`. `side` is 'left' or 'right'."""
    si_src, _ = _find(board, c)
    if len(board[si_src]) != 1:
        raise ValueError(f"extend: {label(c)} is not a loose singleton")
    si_tgt = None
    for i, s in enumerate(board):
        if i == si_src:
            continue
        if s and s[0] == target_sig:
            si_tgt = i
            break
    if si_tgt is None:
        raise ValueError(f"extend: no stack anchored by {label(target_sig)}")
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

def _line_peel(c, source):
    return f"peel {label(c)}"


def _line_pluck(c):
    return f"pluck {label(c)}"


def _line_extend(c, old_target, new_result, side):
    before = " ".join(label(x) for x in old_target)
    after = " ".join(label(x) for x in new_result)
    return f"extend {label(c)} on {before} to {after}"


def _looses(board):
    return [s[0] for s in board if len(s) == 1]


def _try_extract(board, shapes, verbs=("peel", "pluck")):
    """Yield (line, new_board, extracted_card, taboo_partners)
    for every legal extraction whose card matches `shapes`.
    `taboo_partners` is the set of cards the extracted card
    may no longer rejoin (only populated for steals — peel
    and pluck leave the remnant legal, so no estrangement)."""
    for si, stack in enumerate(board):
        if len(stack) <= 1:
            continue
        source_labels = " ".join(label(x) for x in stack)
        for ci, c in enumerate(stack):
            if (c[0], c[1]) not in shapes:
                continue
            if "peel" in verbs and _can_peel(stack, ci):
                yield f"peel {label(c)}", peel(board, c), c, frozenset()
            elif "pluck" in verbs and _can_pluck(stack, ci):
                yield f"pluck {label(c)}", pluck(board, c), c, frozenset()
            elif "steal" in verbs and _can_steal(stack, ci):
                partners = frozenset(x for x in stack if x != c)
                yield (f"steal {label(c)} from {source_labels}",
                       steal(board, c), c, partners)


def _try_extend(board, taboo=None):
    """Yield (line, new_board). Extend targets are restricted
    to trouble stacks. A loose may not rejoin a stack that
    contains any of its taboo cards (cards it was estranged
    from via a prior steal)."""
    taboo = taboo or {}

    def is_trouble(s):
        return classify(s) == "other"

    options = []
    for c in _looses(board):
        forbidden = taboo.get(c, frozenset())
        for si, stack in enumerate(board):
            if not stack or stack[0] == c:
                continue
            if not is_trouble(stack):
                continue
            if any(x in forbidden for x in stack):
                continue
            old_target = list(stack)
            for side in ("right", "left"):
                try:
                    new = extend(board, c, stack[0], side)
                except ValueError:
                    continue
                for s2 in new:
                    if c in s2:
                        if not partial_ok(s2):
                            break
                        result_legal = classify(s2) != "other"
                        priority = 0 if result_legal else 1
                        options.append((priority,
                                        _line_extend(c, old_target, s2, side),
                                        new))
                        break
    options.sort(key=lambda x: x[0])
    for _, line, new in options:
        yield line, new


def beginner_plan(board):
    """Returns list of (line, board_after) — at most 4 lines
    (two extract+extend pairs). A beginner tolerates at most
    two sacrifices of stability; past that, the mental load
    is intermediate-level. Returns None if no 4-line plan
    terminates with a clean board.

    Search is a bounded tree: at each of the two iterations,
    try every (extract, extend) pair. Accept the first full
    plan whose final board has no trouble stacks."""
    def search(board, steps, budget, taboo):
        if not trouble(board):
            return steps
        if budget == 0:
            return None
        # Preference ladder — always prefer extend to sacrifice,
        # prefer peel to steal. Direct neighbors only.
        for line, after in _try_extend(board, taboo):
            found = search(after, steps + [(line, after)],
                           budget, taboo)
            if found is not None:
                return found
        direct = neighbor_shapes(board)
        tiers = [
            (direct, ("peel", "pluck")),
            (direct, ("steal",)),
        ]
        for shapes, verbs in tiers:
            for pp_line, after_pp, stolen, partners in _try_extract(
                    board, shapes, verbs):
                # Augment taboo for steals: the stolen card is
                # estranged (deck-aware) from its former stackmates.
                new_taboo = taboo
                if partners:
                    new_taboo = dict(taboo)
                    new_taboo[stolen] = new_taboo.get(
                        stolen, frozenset()) | partners
                for ext_line, after in _try_extend(after_pp, new_taboo):
                    found = search(after,
                                   steps + [(pp_line, after_pp),
                                            (ext_line, after)],
                                   budget - 1, new_taboo)
                    if found is not None:
                        return found
        return None

    return search(board, [], budget=4, taboo={})


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
