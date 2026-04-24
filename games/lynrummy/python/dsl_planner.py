"""
dsl_planner.py — generate a DSL program that cleans a dirty
board.

Commit axiom (Steve, 2026-04-24): once a loose card is
undeniably placed (board's loose-count drops), that reduction
is locked in. The planner never backtracks past a cleaner
board state. This bounds search to within a single straggler's
solve.

Strategies, in ascending cost:
  A. direct_home         — loose extends an existing legal stack
  B. splice              — dup loose splices into a run middle
  C. peel_and_home       — peel a partner, then home the loose
  D. build_via_pair      — peel two partners, build run with loose
  E. augment_then_splice — augment the splice run first
  F. dissolve_and_place  — dissolve a rigid size-3 set

Each strategy returns (program, new_board) if it reduces
loose-count by ≥ 1, else None. The driver `plan()` iteratively
applies the cheapest successful strategy, committing per the
axiom.
"""

import itertools
import strategy as sg
import dsl_player


# --- Card/label helpers ---

def _label(c):
    rank = {1: "A", 10: "T", 11: "J", 12: "Q", 13: "K"}.get(
        c["value"], str(c["value"]))
    suit = {0: "C", 1: "D", 2: "S", 3: "H"}.get(c["suit"], "?")
    return f"{rank}{suit}"


def _label_with_deck(c):
    return f"{_label(c)}:{c['origin_deck']}"


def _card_label(board, c):
    """Return a label for `c` that's unambiguous on `board`: plain
    rank+suit if unique, else with `:deck` suffix."""
    if _count_cards(board, _label(c)) > 1:
        return _label_with_deck(c)
    return _label(c)


def _anchor_label(board, si):
    """Return the unambiguous label for the stack's first card."""
    return _card_label(board, board[si]["board_cards"][0]["card"])


def _count_cards(board, label):
    """Count occurrences of (rank, suit) across both decks on `board`."""
    val_map = {"A":1,"2":2,"3":3,"4":4,"5":5,"6":6,"7":7,
               "8":8,"9":9,"T":10,"J":11,"Q":12,"K":13}
    suit_map = {"C":0,"D":1,"S":2,"H":3}
    v = val_map[label[0]]
    s_ = suit_map[label[1]]
    return sum(1 for s in board for bc in s["board_cards"]
               if bc["card"]["value"] == v and bc["card"]["suit"] == s_)


# --- Board scan helpers ---

def _loose_stacks(board):
    return [si for si, s in enumerate(board) if len(s["board_cards"]) == 1]


def _count_looses(board):
    return len(_loose_stacks(board))


def _non_loose_stacks(board):
    return [si for si, s in enumerate(board) if len(s["board_cards"]) >= 3]


def _peelable_cards(board):
    """(si, ci, card) for every card legally peelable per
    strategy._can_extract — edges of length-4+ runs or any
    position of a size-4+ set."""
    out = []
    for si, s in enumerate(board):
        if len(s["board_cards"]) < 2:
            continue
        for ci, bc in enumerate(s["board_cards"]):
            if sg._can_extract(s, ci):
                out.append((si, ci, bc["card"]))
    return out


def _all_anchor_labels(board):
    """Labels of all non-loose stack anchors (disambiguated)."""
    return [_anchor_label(board, ti) for ti in _non_loose_stacks(board)]


# --- Pre-pass: greedy merge adjacent runs ---

def try_greedy_merge(board):
    """Scan for any pair of non-loose stacks that combine into a
    legal longer group. Emits `merge` lines until no more fire.
    Pre-pass: consolidates fragmented runs before real reduction
    work begins. Steve's move on all-rigid-pure boards starts
    here — stitch the length-3 fragments back into longer runs
    that then provide donor slack."""
    program_lines = []
    cur = board
    while True:
        found = False
        n = len(cur)
        for a in range(n):
            if len(cur[a]["board_cards"]) < 2:
                continue
            for b in range(n):
                if a == b:
                    continue
                if len(cur[b]["board_cards"]) < 2:
                    continue
                for side in ("right", "left"):
                    trial = sg._apply_merge_stack(
                        sg._copy_board(cur), a, b, side)
                    anchor_card = (cur[b]["board_cards"][0]["card"]
                                   if side == "right"
                                   else cur[a]["board_cards"][0]["card"])
                    merged_si = sg._find_stack(trial, anchor_card)
                    merged = [bc["card"]
                              for bc in trial[merged_si]["board_cards"]]
                    if sg._classify(merged) == "other":
                        continue
                    if len(merged) <= max(len(cur[a]["board_cards"]),
                                          len(cur[b]["board_cards"])):
                        continue  # must grow
                    src_lbl = _anchor_label(cur, a)
                    tgt_lbl = _anchor_label(cur, b)
                    program_lines.append(
                        f"merge {src_lbl} onto {tgt_lbl} side:{side}")
                    cur = trial
                    found = True
                    break
                if found:
                    break
            if found:
                break
        if not found:
            break
    if not program_lines:
        return None
    # The merge doesn't consume any loose card — loose count
    # unchanged. So we don't match _try's contract. Instead,
    # return (program, new_board) directly and let plan() apply.
    return "\n".join(program_lines), cur


# --- Strategy A: direct_home ---

def try_direct_home(board):
    for li in _loose_stacks(board):
        loose = board[li]["board_cards"][0]["card"]
        lbl = _card_label(board, loose)
        for ti in _non_loose_stacks(board):
            program = f"home {lbl} into {_anchor_label(board, ti)}"
            result = _try(program, board)
            if result is not None:
                return program, result
    return None


# --- Strategy B: peel & home ---

def try_peel_and_home(board):
    """Peel a partner; then home either the loose or the peeled
    partner into some other legal stack."""
    for li in _loose_stacks(board):
        loose_lbl = _card_label(board, board[li]["board_cards"][0]["card"])
        for si, ci, pcard in _peelable_cards(board):
            if si == li:
                continue
            p_lbl = _card_label(board, pcard)
            donor_lbl = _anchor_label(board, si)
            peel = f"peel {p_lbl} from {donor_lbl}"
            for target in _all_anchor_labels(board):
                for subject in (loose_lbl, p_lbl):
                    program = f"{peel}\nhome {subject} into {target}"
                    result = _try(program, board)
                    if result is not None:
                        return program, result
    return None


# --- Strategy C: build_via_pair (peel two partners, form new group) ---

def try_build_via_pair(board):
    """Peel two partners, assemble a new 3-card group with the
    loose incorporated. Sorts the triple by value, builds
    left-to-right: lowest → middle → highest."""
    peelables = _peelable_cards(board)
    for li in _loose_stacks(board):
        loose = board[li]["board_cards"][0]["card"]
        loose_lbl = _card_label(board, loose)
        for (si1, _, p1), (si2, _, p2) in itertools.combinations(peelables, 2):
            if si1 == li or si2 == li or si1 == si2:
                continue
            triple = sorted([p1, loose, p2], key=lambda c: c["value"])
            if sg._classify(triple) == "other":
                continue
            low, mid, high = triple
            peels = (f"peel {_card_label(board, p1)} from "
                     f"{_anchor_label(board, si1)}\n"
                     f"peel {_card_label(board, p2)} from "
                     f"{_anchor_label(board, si2)}")
            low_lbl = _card_label(board, low)
            mid_lbl = _card_label(board, mid)
            high_lbl = _card_label(board, high)
            # Build left-to-right. Hand card uses `home` (runs
            # its own side search); board cards use explicit
            # `extend`.
            if loose is low:
                body = (f"extend {mid_lbl} onto {low_lbl} side:right\n"
                        f"home {high_lbl} into {low_lbl}")
            elif loose is high:
                body = (f"extend {mid_lbl} onto {low_lbl} side:right\n"
                        f"home {loose_lbl} into {low_lbl}")
            else:  # loose is middle
                body = (f"extend {loose_lbl} onto {low_lbl} side:right\n"
                        f"home {high_lbl} into {low_lbl}")
            program = f"{peels}\n{body}"
            result = _try(program, board)
            if result is not None:
                return program, result
    return None


# --- Strategy C2: splice dup into run middle (pure or rb) ---

def try_splice(board):
    for li in _loose_stacks(board):
        loose = board[li]["board_cards"][0]["card"]
        loose_lbl = _card_label(board, loose)
        for ti, ts in enumerate(board):
            if ti == li:
                continue
            cards = [bc["card"] for bc in ts["board_cards"]]
            if sg._classify(cards) not in ("pure_run", "rb_run"):
                continue
            for mid_i in range(2, len(cards) - 2):
                twin = cards[mid_i]
                if (twin["value"] == loose["value"]
                        and twin["suit"] == loose["suit"]
                        and twin["origin_deck"] != loose["origin_deck"]):
                    program = (f"splice {loose_lbl} into "
                               f"{_anchor_label(board, ti)}")
                    result = _try(program, board)
                    if result is not None:
                        return program, result
    return None


# --- Strategy C3: augment-then-splice ---
# When a loose dup could splice into a pure run, but that run
# is too short, try augmenting one or both sides with peelable
# cards first.

def try_augment_then_splice(board):
    # Chain-aware: each needed augment tries direct peel first,
    # then prep-peel-extend-peel (if the augment card is blocked
    # but its stack can be slackened by another augment). Caps
    # at 3 augments per side total.
    for li in _loose_stacks(board):
        loose = board[li]["board_cards"][0]["card"]
        lval, lsuit, ldeck = loose["value"], loose["suit"], loose["origin_deck"]
        loose_lbl = _label_with_deck(loose) if _count_cards(board, _label(loose)) > 1 else _label(loose)

        for ti, ts in enumerate(board):
            if ti == li:
                continue
            cards = [bc["card"] for bc in ts["board_cards"]]
            kind = sg._classify(cards)
            if kind not in ("pure_run", "rb_run"):
                continue
            twin_i = None
            for i, c in enumerate(cards):
                if (c["value"] == lval and c["suit"] == lsuit
                        and c["origin_deck"] != ldeck):
                    twin_i = i
                    break
            if twin_i is None:
                continue
            left_slack = twin_i
            right_slack = len(cards) - twin_i - 1
            need_left = max(0, 2 - left_slack)
            need_right = max(0, 2 - right_slack)
            if need_left > 3 or need_right > 3:
                continue

            # Plan each augment against the running trial state
            # (left first, then right). If left-then-right fails
            # because both want the same donor, retry right-then-
            # left. Tracking the edge as augments apply keeps
            # each predecessor/successor computation correct.
            for order in ("LR", "RL"):
                trial_board = sg._copy_board(board)
                script_lines = []
                current_cards = cards[:]
                current_anchor_card = current_cards[0]

                def apply_side(side, trial, lines, cur_cards, cur_anchor):
                    # Mutates lines, returns (trial, cur_cards, cur_anchor,
                    # ok). `side` is "left" or "right".
                    passes = need_left if side == "left" else need_right
                    for _ in range(passes):
                        edge_card = cur_cards[0] if side == "left" else cur_cards[-1]
                        val_needed = (sg._predecessor(edge_card["value"])
                                      if side == "left"
                                      else sg._successor(edge_card["value"]))
                        suit_needed = lsuit if kind == "pure_run" else None
                        color_opp = edge_card["suit"] if kind == "rb_run" else None
                        aug = _plan_peel(
                            trial, val_needed, suit=suit_needed,
                            color_opposite_to=color_opp,
                            exclude_stacks={li})
                        if aug is None:
                            return trial, cur_cards, cur_anchor, False
                        prep_lines, trial, aug_card = aug
                        aug_lbl = (_label_with_deck(aug_card)
                                   if _count_cards(board, _label(aug_card)) > 1
                                   else _label(aug_card))
                        cur_anchor_lbl = (_label_with_deck(cur_anchor)
                                          if _count_cards(board, _label(cur_anchor)) > 1
                                          else _label(cur_anchor))
                        lines.extend(prep_lines)
                        lines.append(
                            f"extend {aug_lbl} onto {cur_anchor_lbl} side:{side}")
                        try:
                            _, trial = dsl_player.run(
                                "\n".join(lines), board,
                                validate_clean=False)
                        except dsl_player.DSLError:
                            return trial, cur_cards, cur_anchor, False
                        if side == "left":
                            cur_cards = [aug_card] + cur_cards
                            cur_anchor = aug_card
                        else:
                            cur_cards = cur_cards + [aug_card]
                    return trial, cur_cards, cur_anchor, True

                sides = ("left", "right") if order == "LR" else ("right", "left")
                ok = True
                for side in sides:
                    trial_board, current_cards, current_anchor_card, side_ok = \
                        apply_side(side, trial_board, script_lines,
                                   current_cards, current_anchor_card)
                    if not side_ok:
                        ok = False
                        break
                if not ok:
                    continue

                current_anchor_lbl = (_label_with_deck(current_anchor_card)
                                      if _count_cards(board, _label(current_anchor_card)) > 1
                                      else _label(current_anchor_card))
                script_lines.append(
                    f"splice {loose_lbl} into {current_anchor_lbl}")
                script = "\n".join(script_lines)
                res = _try(script, board)
                if res is not None:
                    return script, res
    return None


def _plan_peel(board, value, *, suit=None, color_opposite_to=None,
               exclude_stacks=frozenset()):
    """Return (prep_lines, board_after_prep, peel_card) such that
    the card is loose in `board_after_prep`. Tries direct peel
    first; if that fails, tries a single prep-augment of the
    donor stack (making the card an edge or slack-set member).
    Returns None if unreachable."""
    # Direct peel.
    for si, ci, c in _peelable_cards(board):
        if si in exclude_stacks:
            continue
        if c["value"] != value:
            continue
        if suit is not None and c["suit"] != suit:
            continue
        if color_opposite_to is not None:
            ref_color = "black" if color_opposite_to in (0, 2) else "red"
            c_color = "black" if c["suit"] in (0, 2) else "red"
            if c_color == ref_color:
                continue
        # Emit peel line.
        donor_anchor = _disamb_anchor(
            board, _label(board[si]["board_cards"][0]["card"]), si)
        c_lbl = _label_with_deck(c) if _count_cards(board, _label(c)) > 1 else _label(c)
        line = f"peel {c_lbl} from {donor_anchor}"
        try:
            _, after = dsl_player.run(line, board, validate_clean=False)
        except dsl_player.DSLError:
            continue
        return [line], after, c

    # Prep-augment: find a rigid-pure stack of length 3 whose
    # edge (ci=0 or ci=n-1) matches (value, suit/color). If we
    # can augment that stack with a peelable card (from another
    # stack) at the OPPOSITE edge, the edge card we want becomes
    # peelable.
    for si, s in enumerate(board):
        if si in exclude_stacks:
            continue
        cards = [bc["card"] for bc in s["board_cards"]]
        kind_s = sg._classify(cards)
        if kind_s not in ("pure_run", "rb_run") or len(cards) != 3:
            continue
        # Check target value at left or right edge.
        for edge_ci in (0, len(cards) - 1):
            ec = cards[edge_ci]
            if ec["value"] != value:
                continue
            if suit is not None and ec["suit"] != suit:
                continue
            if color_opposite_to is not None:
                ref_color = "black" if color_opposite_to in (0, 2) else "red"
                ec_color = "black" if ec["suit"] in (0, 2) else "red"
                if ec_color == ref_color:
                    continue
            # Augment the OPPOSITE edge so the target becomes a
            # non-breaking edge of a length-4 stack.
            if edge_ci == 0:
                # Target at left. Augment right with successor-valued
                # same-suit (pure) or opposite-color (rb) card.
                add_val = sg._successor(cards[-1]["value"])
                add_suit = cards[0]["suit"] if kind_s == "pure_run" else None
                add_color_opp = cards[-1]["suit"] if kind_s == "rb_run" else None
            else:
                # Target at right. Augment left.
                add_val = sg._predecessor(cards[0]["value"])
                add_suit = cards[0]["suit"] if kind_s == "pure_run" else None
                add_color_opp = cards[0]["suit"] if kind_s == "rb_run" else None
            sub = _plan_peel(
                board, add_val, suit=add_suit,
                color_opposite_to=add_color_opp,
                exclude_stacks=exclude_stacks | {si})
            if sub is None:
                continue
            sub_lines, sub_board, sub_card = sub
            # Extend sub_card onto the rigid stack.
            anchor_lbl = _disamb_anchor(
                board, _label(cards[0]), si)
            sub_card_lbl = _label_with_deck(sub_card) if _count_cards(board, _label(sub_card)) > 1 else _label(sub_card)
            extend_side = "right" if edge_ci == 0 else "left"
            extend_line = f"extend {sub_card_lbl} onto {anchor_lbl} side:{extend_side}"
            try:
                _, after_extend = dsl_player.run(
                    "\n".join(sub_lines + [extend_line]), board,
                    validate_clean=False)
            except dsl_player.DSLError:
                continue
            # Now peel the target from its edge.
            ec_lbl = _label_with_deck(ec) if _count_cards(board, _label(ec)) > 1 else _label(ec)
            # After extend, find the new anchor (may have changed if extend was left).
            new_anchor = cards[0] if extend_side == "right" else sub_card
            new_anchor_lbl = _label_with_deck(new_anchor) if _count_cards(board, _label(new_anchor)) > 1 else _label(new_anchor)
            peel_line = f"peel {ec_lbl} from {new_anchor_lbl}"
            try:
                _, after_peel = dsl_player.run(
                    "\n".join(sub_lines + [extend_line, peel_line]),
                    board, validate_clean=False)
            except dsl_player.DSLError:
                continue
            return sub_lines + [extend_line, peel_line], after_peel, ec
    return None


def _find_peelable_fitting(board, value, *, suit=None,
                            color_opposite_to=None, exclude=()):
    """Find a peelable card of given value, optionally filtered
    by exact suit (pure-run augmentation) or by opposite color
    of a reference suit (rb-run augmentation)."""
    excluded = set(exclude)
    for si, ci, c in _peelable_cards(board):
        if si in excluded:
            continue
        if c["value"] != value:
            continue
        if suit is not None and c["suit"] != suit:
            continue
        if color_opposite_to is not None:
            ref_color = "black" if color_opposite_to in (0, 2) else "red"
            c_color = "black" if c["suit"] in (0, 2) else "red"
            if c_color == ref_color:
                continue
        return si, c
    return None


# --- Strategy D: dissolve-and-place ---

def try_dissolve_and_place(board):
    """Find a rigid size-3 set; trial-dissolve; see if every
    dissolved card + the loose can find homes. Calibrated leap."""
    for si, s in enumerate(board):
        if len(s["board_cards"]) != 3:
            continue
        raw = [bc["card"] for bc in s["board_cards"]]
        if sg._classify(raw) != "set":
            continue
        # Try: dissolve + home each card somewhere.
        card_labels = [_label_with_deck(c) if _count_cards(board, _label(c)) > 1 else _label(c)
                       for c in raw]
        # Enumerate all (target1, target2, target3) homes combinations.
        anchors = _all_anchor_labels(board)
        for homes in itertools.product(anchors, repeat=3):
            # Also need to place any loose from the hand.
            looses = _loose_stacks(board)
            if not looses:
                break
            for li in looses:
                loose = board[li]["board_cards"][0]["card"]
                loose_lbl = _label_with_deck(loose) if _count_cards(board, _label(loose)) > 1 else _label(loose)
                for loose_home in anchors:
                    script = (
                        f"dissolve {' '.join(card_labels)}\n"
                        f"home {card_labels[0]} into {homes[0]}\n"
                        f"home {card_labels[1]} into {homes[1]}\n"
                        f"home {card_labels[2]} into {homes[2]}\n"
                        f"home {loose_lbl} into {loose_home}\n"
                    )
                    result = _try(script, board)
                    if result is not None:
                        return script, result
    return None


# --- Driver ---

STRATEGIES = [
    ("direct_home", try_direct_home),
    ("splice", try_splice),
    ("peel_and_home", try_peel_and_home),
    ("build_via_pair", try_build_via_pair),
    ("augment_then_splice", try_augment_then_splice),
    ("dissolve_and_place", try_dissolve_and_place),
]


def _try(script, board):
    """Run a DSL script; return new_board iff loose-count
    strictly decreased (per commit axiom), else None.

    Partial trials — we don't require the script's final state
    to be fully clean, because multiple looses may remain from
    other reductions. Only the final full-script verification
    (in the sweep's Layer 2 check) enforces cleanliness."""
    try:
        _, new_board = dsl_player.run(script, board, validate_clean=False)
    except dsl_player.DSLError:
        return None
    if _count_looses(new_board) < _count_looses(board):
        return new_board
    return None


def plan(board, verbose=False):
    """Iteratively reduce loose-count to zero. Returns (program,
    final_board) on success, (None, board_stuck) on failure.

    Order:
      1. Greedy-merge pre-pass — stitch any fragmented runs
         into longer runs. Doesn't reduce loose-count but often
         unlocks slack donors that later strategies need.
      2. Commit axiom: each outer iteration must strictly
         reduce loose-count; once reduced, never reconsidered.
    """
    programs = []

    # Pre-pass.
    merge_result = try_greedy_merge(board)
    if merge_result is not None:
        merge_prog, board = merge_result
        programs.append(merge_prog)
        if verbose:
            n = len(merge_prog.splitlines())
            print(f"  [greedy_merge] consolidated {n} stack pair(s)")

    iteration = 0
    while _count_looses(board) > 0 and iteration < 50:
        iteration += 1
        progress = False
        for name, fn in STRATEGIES:
            result = fn(board)
            if result is not None:
                program, new_board = result
                if verbose:
                    print(f"  [{name}] "
                          f"reduced {_count_looses(board)} → "
                          f"{_count_looses(new_board)}")
                programs.append(program)
                board = new_board
                progress = True
                break
        if not progress:
            return None, board
    return "\n\n".join(programs), board
