"""
dsl_player.py — parse + execute a DSL script against a board.

The DSL describes the solve of a dirty board: cleanly legal
stacks plus some loose cards (formerly "hand" cards, now just
cards on the table per the hand→board isomorphism). The script
cleans the board — every final stack classifies as a legal
group, no looses remain.

Starting grammar (see `claude-steve/random008.md`):

Verbs (8):
    peel CARD from ANCHOR         → extract CARD as a loose
    park CARD                      → move loose to open workspace
    extend CARD onto ANCHOR [side:S] → merge loose into stack
    dissolve CARD CARD CARD        → break size-3 set into 3 looses
    home CARD into ANCHOR           → find legal slot on ANCHOR for CARD
    augment ANCHOR with CARD        → grow size-3 set by adding a card (TODO)
    swap CARD into ANCHOR slot:POS  → rb-swap with same-color twin (TODO)
    splice CARD into ANCHOR         → splice into pure run middle (TODO)
    restore STACK                   → reassemble set remnants (TODO)

Card labels (2-char rank+suit, optional `:deck`):
    KS      → value 13 spade, any deck
    KS:0    → value 13 spade, deck 0

Stack labels are anchors — the label of the stack's FIRST card.

First iteration implements: peel, park, extend, dissolve, home.
Enough to express the QH solve from puzzle 33.
"""

import strategy


RANK_MAP = {'A': 1, '2': 2, '3': 3, '4': 4, '5': 5, '6': 6, '7': 7,
            '8': 8, '9': 9, 'T': 10, 'J': 11, 'Q': 12, 'K': 13}
SUIT_MAP = {'C': 0, 'D': 1, 'S': 2, 'H': 3}


class DSLError(Exception):
    pass


def parse_card_label(label):
    """'KS' → (13, 2, None). 'KS:0' → (13, 2, 0). Returns
    (value, suit, deck_or_None)."""
    parts = label.split(":", 1)
    tok = parts[0]
    if len(tok) < 2:
        raise DSLError(f"card label too short: {label}")
    val = RANK_MAP.get(tok[0])
    suit = SUIT_MAP.get(tok[1])
    if val is None or suit is None:
        raise DSLError(f"unknown card label: {label}")
    deck = None
    if len(parts) == 2:
        deck = int(parts[1])
    return val, suit, deck


def _card_matches(c, val, suit, deck):
    if c["value"] != val or c["suit"] != suit:
        return False
    if deck is not None and c["origin_deck"] != deck:
        return False
    return True


def find_card(sim, label):
    """Return (stack_idx, card_idx, card). Raises on not-found
    or ambiguity (unless label specifies deck)."""
    val, suit, deck = parse_card_label(label)
    matches = []
    for si, s in enumerate(sim):
        for ci, bc in enumerate(s["board_cards"]):
            if _card_matches(bc["card"], val, suit, deck):
                matches.append((si, ci, bc["card"]))
    if not matches:
        raise DSLError(f"card {label} not found on board")
    if len(matches) > 1 and deck is None:
        raise DSLError(
            f"card {label} ambiguous ({len(matches)} matches); "
            f"use deck suffix like {label}:0 or {label}:1")
    return matches[0]


def find_stack_by_anchor(sim, label):
    """Return stack_idx where sim[idx].board_cards[0] matches the
    anchor label. Raises on not-found or ambiguity (unless label
    specifies deck)."""
    val, suit, deck = parse_card_label(label)
    matches = []
    for si, s in enumerate(sim):
        if not s["board_cards"]:
            continue
        if _card_matches(s["board_cards"][0]["card"], val, suit, deck):
            matches.append(si)
    if not matches:
        raise DSLError(f"stack anchored at {label} not found")
    if len(matches) > 1 and deck is None:
        raise DSLError(
            f"anchor {label} ambiguous ({len(matches)} matches); "
            f"use deck suffix like {label}:0 or {label}:1")
    return matches[0]


# --- verb handlers ---

def verb_peel(args, sim, prims):
    # peel CARD from ANCHOR
    if len(args) != 3 or args[1] != "from":
        raise DSLError("peel syntax: peel CARD from ANCHOR")
    card_label = args[0]
    _ = args[2]  # anchor is for human readability; find_card uses label alone
    si, ci, card = find_card(sim, card_label)
    if len(sim[si]["board_cards"]) == 1:
        return sim  # already loose
    n = len(sim[si]["board_cards"])
    kind = strategy._classify(
        [bc["card"] for bc in sim[si]["board_cards"]])

    # For set middle peel, emit the reassembly after _emit_peel.
    # For run peels (edge or middle), _emit_peel is sufficient —
    # both remnants stay legal as long as the length budgets hold.
    is_set_middle = (kind == "set" and n >= 4 and
                     0 < ci < n - 1)

    # Remember anchors for reassembly.
    below_first = None
    tail_first = None
    if is_set_middle:
        pre_cards = [bc["card"] for bc in sim[si]["board_cards"]]
        below_first = pre_cards[0]
        tail_first = pre_cards[ci + 1]

    peel_prims, sim = strategy._emit_peel(sim, card, ci)
    prims.extend(peel_prims)

    if is_set_middle:
        below_idx = strategy._find_stack(sim, below_first)
        tail_idx = strategy._find_stack(sim, tail_first)
        prims.append({"action": "merge_stack", "source_stack": tail_idx,
                      "target_stack": below_idx, "side": "right"})
        sim = strategy._apply_merge_stack(sim, tail_idx, below_idx, "right")

    return sim


def verb_park(args, sim, prims):
    # park CARD — moves a loose to an open location
    if len(args) != 1:
        raise DSLError("park syntax: park CARD")
    si, _, card = find_card(sim, args[0])
    if len(sim[si]["board_cards"]) != 1:
        raise DSLError(f"park expects a loose (size-1) stack; "
                       f"{args[0]} is in size-{len(sim[si]['board_cards'])} stack")
    others = [s for i, s in enumerate(sim) if i != si]
    new_loc = strategy.find_open_loc(others, card_count=3)
    if new_loc != sim[si]["loc"]:
        prims.append({"action": "move_stack",
                      "stack_index": si, "new_loc": new_loc})
        sim = strategy._apply_move(sim, si, new_loc)
    return sim


def _parse_side(args):
    side = "right"
    for arg in args:
        if arg.startswith("side:"):
            side = arg.split(":", 1)[1]
    return side


def verb_extend(args, sim, prims):
    # extend CARD onto ANCHOR [side:S]
    if len(args) < 3 or args[1] != "onto":
        raise DSLError("extend syntax: extend CARD onto ANCHOR [side:S]")
    card_label = args[0]
    anchor_label = args[2]
    side = _parse_side(args[3:])
    si, _, card = find_card(sim, card_label)
    if len(sim[si]["board_cards"]) != 1:
        raise DSLError(f"extend expects a loose source; "
                       f"{card_label} is in a larger stack")
    target_si = find_stack_by_anchor(sim, anchor_label)
    prims.append({"action": "merge_stack",
                  "source_stack": si,
                  "target_stack": target_si,
                  "side": side})
    return strategy._apply_merge_stack(sim, si, target_si, side)


def verb_dissolve(args, sim, prims):
    # dissolve CARD CARD CARD — break size-3 set into three looses.
    if len(args) != 3:
        raise DSLError("dissolve expects exactly 3 card labels")
    infos = [find_card(sim, a) for a in args]
    stack_idxs = {info[0] for info in infos}
    if len(stack_idxs) != 1:
        raise DSLError(f"dissolve: the 3 cards must be in the same stack; "
                       f"got stacks {stack_idxs}")
    si = next(iter(stack_idxs))
    if len(sim[si]["board_cards"]) != 3:
        raise DSLError(f"dissolve expects a size-3 stack; "
                       f"got size {len(sim[si]['board_cards'])}")
    # Two splits: first at ci=0 (peels left card), then the
    # remaining [mid,right] at ci=0 (peels middle).
    # We track by content, not index, since splits shuffle indices.
    c0 = sim[si]["board_cards"][0]["card"]
    c1 = sim[si]["board_cards"][1]["card"]
    c2 = sim[si]["board_cards"][2]["card"]

    prims.append({"action": "split", "stack_index": si, "card_index": 0})
    sim = strategy._apply_split(sim, si, 0)

    # Find the [c1, c2] stack.
    pair_si = strategy._find_stack(sim, c1)
    prims.append({"action": "split", "stack_index": pair_si, "card_index": 0})
    sim = strategy._apply_split(sim, pair_si, 0)
    return sim


def verb_home(args, sim, prims):
    # home CARD into ANCHOR — merge loose into legal slot on anchor.
    # Try left then right; whichever keeps the target legal wins.
    if len(args) != 3 or args[1] != "into":
        raise DSLError("home syntax: home CARD into ANCHOR")
    card_label = args[0]
    anchor_label = args[2]
    si, _, card = find_card(sim, card_label)
    if len(sim[si]["board_cards"]) != 1:
        raise DSLError(f"home expects a loose source; "
                       f"{card_label} is in a larger stack")
    target_si = find_stack_by_anchor(sim, anchor_label)
    target_anchor = sim[target_si]["board_cards"][0]["card"]

    for side in ("left", "right"):
        trial = strategy._copy_board(sim)
        trial = strategy._apply_merge_stack(
            trial, si, target_si, side)
        # Re-find the merged stack.
        merged_si = strategy._find_stack(trial, target_anchor)
        # Target might land before anchor; search by the source card too.
        cards_after = [bc["card"] for bc in trial[merged_si]["board_cards"]]
        # If merged stack doesn't contain `card`, it must have landed elsewhere.
        if not any(strategy._card_eq(c, card) for c in cards_after):
            merged_si = strategy._find_stack(trial, card)
            cards_after = [bc["card"] for bc in trial[merged_si]["board_cards"]]
        if strategy._classify(cards_after) != "other":
            prims.append({"action": "merge_stack",
                          "source_stack": si,
                          "target_stack": target_si,
                          "side": side})
            return strategy._apply_merge_stack(sim, si, target_si, side)
    raise DSLError(
        f"home: no legal side (left/right) merges {card_label} "
        f"into stack anchored at {anchor_label}")


def _color(suit):
    return "black" if suit in (0, 2) else "red"


def verb_swap(args, sim, prims):
    # swap LOOSE for KICKED
    # Edge-or-middle rb slot replacement. Kicked is left as a
    # new loose; the caller homes it in a subsequent line.
    if len(args) != 3 or args[1] != "for":
        raise DSLError("swap syntax: swap LOOSE for KICKED")
    loose_lbl, _, kicked_lbl = args
    loose_si, _, loose = find_card(sim, loose_lbl)
    if len(sim[loose_si]["board_cards"]) != 1:
        raise DSLError("swap: LOOSE must be size-1")
    # Find KICKED in a multi-card stack (exclude the loose itself).
    val, suit, deck = parse_card_label(kicked_lbl)
    kicked_info = None
    for si, s in enumerate(sim):
        if si == loose_si:
            continue
        if len(s["board_cards"]) < 2:
            continue
        for ci, bc in enumerate(s["board_cards"]):
            if _card_matches(bc["card"], val, suit, deck):
                kicked_info = (si, ci, bc["card"])
                break
        if kicked_info:
            break
    if kicked_info is None:
        raise DSLError(f"swap: {kicked_lbl} not in any multi-card stack")
    kicked_si, kicked_ci, kicked = kicked_info
    run_cards = [bc["card"] for bc in sim[kicked_si]["board_cards"]]
    n = len(run_cards)

    # Legality checks for rb color-slot swap.
    if loose["value"] != kicked["value"]:
        raise DSLError("swap: values differ")
    if _color(loose["suit"]) != _color(kicked["suit"]):
        raise DSLError("swap: colors differ")
    if loose["suit"] == kicked["suit"]:
        raise DSLError("swap: must be different suits")
    swapped = list(run_cards)
    swapped[kicked_ci] = loose
    if strategy._classify(swapped) != "rb_run":
        raise DSLError(f"swap: result isn't rb_run: {swapped}")

    left_anchor = run_cards[0] if kicked_ci > 0 else None
    right_anchor = run_cards[kicked_ci + 1] if kicked_ci < n - 1 else None

    peel_prims, sim = strategy._emit_peel(sim, kicked, kicked_ci)
    prims.extend(peel_prims)

    loose_si_now = strategy._find_stack(sim, loose)
    if kicked_ci == 0:
        # Left-edge swap: loose takes the former kicked's spot.
        right_si = strategy._find_stack(sim, right_anchor)
        prims.append({"action": "merge_stack", "source_stack": loose_si_now,
                      "target_stack": right_si, "side": "left"})
        sim = strategy._apply_merge_stack(sim, loose_si_now, right_si, "left")
    elif kicked_ci == n - 1:
        left_si = strategy._find_stack(sim, left_anchor)
        prims.append({"action": "merge_stack", "source_stack": loose_si_now,
                      "target_stack": left_si, "side": "right"})
        sim = strategy._apply_merge_stack(sim, loose_si_now, left_si, "right")
    else:
        # Middle swap: loose bridges left and right remnants.
        left_si = strategy._find_stack(sim, left_anchor)
        prims.append({"action": "merge_stack", "source_stack": loose_si_now,
                      "target_stack": left_si, "side": "right"})
        sim = strategy._apply_merge_stack(sim, loose_si_now, left_si, "right")
        bridge_si = strategy._find_stack(sim, loose)
        right_si = strategy._find_stack(sim, right_anchor)
        prims.append({"action": "merge_stack", "source_stack": right_si,
                      "target_stack": bridge_si, "side": "right"})
        sim = strategy._apply_merge_stack(sim, right_si, bridge_si, "right")
    return sim


def verb_splice(args, sim, prims):
    # splice LOOSE into ANCHOR
    # Hand dup splices into a pure OR rb run at a middle-twin
    # position with 2+ cards on each side. Both halves stay
    # legally classified: pure→pure, rb→rb (alternation
    # preserved by construction).
    if len(args) != 3 or args[1] != "into":
        raise DSLError("splice syntax: splice LOOSE into ANCHOR")
    loose_lbl, _, anchor_lbl = args
    loose_si, _, loose = find_card(sim, loose_lbl)
    if len(sim[loose_si]["board_cards"]) != 1:
        raise DSLError("splice: LOOSE must be size-1")
    target_si = find_stack_by_anchor(sim, anchor_lbl)
    target = [bc["card"] for bc in sim[target_si]["board_cards"]]
    if strategy._classify(target) not in ("pure_run", "rb_run"):
        raise DSLError("splice: anchor stack must be a pure or rb run")
    n = len(target)
    split_at = None
    for i in range(2, n - 2):
        twin = target[i]
        if (twin["value"] == loose["value"]
                and twin["suit"] == loose["suit"]
                and twin["origin_deck"] != loose["origin_deck"]):
            split_at = i
            break
    if split_at is None:
        raise DSLError(
            f"splice: no middle twin of {loose_lbl} in {anchor_lbl} "
            f"(need ≥2 cards on each side of an origin_deck twin)")
    right_first = target[split_at + 1]
    # Pick split ci so `_apply_split` produces left=[0..split_at]
    # (size split_at+1) and right=[split_at+1..]. The call's
    # left-count depends on which half the cut is in; see
    # `_apply_split` in strategy.py. Rule: if (split_at+1) is
    # in the first half of the stack, use ci=split_at (leftSplit
    # path); else ci=split_at+1 (rightSplit path).
    n = len(target)
    if split_at + 1 <= n // 2:
        split_ci = split_at
    else:
        split_ci = split_at + 1
    prims.append({"action": "split", "stack_index": target_si,
                  "card_index": split_ci})
    sim = strategy._apply_split(sim, target_si, split_ci)
    right_si = strategy._find_stack(sim, right_first)
    new_loc = strategy.find_open_loc(sim, card_count=3)
    if new_loc != sim[right_si]["loc"]:
        prims.append({"action": "move_stack", "stack_index": right_si,
                      "new_loc": new_loc})
        sim = strategy._apply_move(sim, right_si, new_loc)
    right_si = strategy._find_stack(sim, right_first)
    loose_si_now = strategy._find_stack(sim, loose)
    prims.append({"action": "merge_stack", "source_stack": loose_si_now,
                  "target_stack": right_si, "side": "left"})
    return strategy._apply_merge_stack(sim, loose_si_now, right_si, "left")


def verb_merge(args, sim, prims):
    # merge SRC_ANCHOR onto TGT_ANCHOR side:S
    # Unlike `extend`, SRC may be any stack, not just a loose.
    # Useful as a greedy pre-pass that stitches fragmented runs
    # back into long runs before real reduction work begins.
    if len(args) < 3 or args[1] != "onto":
        raise DSLError("merge syntax: merge SRC_ANCHOR onto TGT_ANCHOR [side:S]")
    src_anchor, _, tgt_anchor = args[:3]
    side = _parse_side(args[3:])
    src_si = find_stack_by_anchor(sim, src_anchor)
    tgt_si = find_stack_by_anchor(sim, tgt_anchor)
    if src_si == tgt_si:
        raise DSLError("merge: source and target stacks are the same")
    prims.append({"action": "merge_stack", "source_stack": src_si,
                  "target_stack": tgt_si, "side": side})
    return strategy._apply_merge_stack(sim, src_si, tgt_si, side)


VERBS = {
    "peel": verb_peel,
    "park": verb_park,
    "extend": verb_extend,
    "merge": verb_merge,
    "dissolve": verb_dissolve,
    "home": verb_home,
    "swap": verb_swap,
    "splice": verb_splice,
}


def parse_script(text):
    """Yield (verb, args, line_num) tuples."""
    out = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        out.append((parts[0], parts[1:], lineno))
    return out


def run(script, board, *, validate_clean=True):
    """Execute a DSL script against a copy of `board`. Returns
    (primitives, final_board). Raises DSLError on any verb
    failure.

    With validate_clean=True (default), additionally enforces
    that every final stack classifies as a legal group — the
    "script must leave a clean board" contract used by the
    outer completion checker.

    With validate_clean=False, trial/partial scripts may leave
    loose singletons behind. Used by the planner when it runs
    sub-scripts that will be extended before verification."""
    sim = strategy._copy_board(board)
    prims = []
    for verb, args, lineno in parse_script(script):
        handler = VERBS.get(verb)
        if handler is None:
            raise DSLError(f"line {lineno}: unknown verb: {verb}")
        try:
            sim = handler(args, sim, prims)
        except DSLError as e:
            raise DSLError(f"line {lineno} ({verb}): {e}") from None
    if validate_clean:
        for i, s in enumerate(sim):
            cards = [bc["card"] for bc in s["board_cards"]]
            if strategy._classify(cards) == "other":
                raise DSLError(
                    f"final stack {i} {[_label(c) for c in cards]} "
                    f"is not a legal group")
    return prims, sim


def _label(c):
    rank = {1: "A", 10: "T", 11: "J", 12: "Q", 13: "K"}.get(
        c["value"], str(c["value"]))
    suit = {0: "C", 1: "D", 2: "S", 3: "H"}.get(c["suit"], "?")
    return f"{rank}{suit}"
