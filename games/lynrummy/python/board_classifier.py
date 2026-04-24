"""
board_classifier.py — tag every card and stack on a board with
strategic adjectives (per random008.md's vocabulary).

Produces the typed view of the board that a planner reads. This
is the "what roles can each thing play?" layer: looking at a
slack stack and asking "what do I have available?" is faster
than re-deriving the answer every time a verb considers a move.

Output shape:
    cards: {(stack_idx, card_idx): set_of_adjective_strings}
    stacks: {stack_idx: set_of_adjective_strings}

Adjectives currently emitted:

Card:
  - loose        → card is the only card in its stack
  - peelable     → can be extracted legally (edge of slack run,
                   or any position of a 4+-card set)
  - trapped      → in a rigid stack or too-deep mid-run; no
                   clean liberation without augment-style help
  - edge         → at index 0 or n-1 of its stack (positional)
  - dup          → a duplicate-suit-value card exists elsewhere

Stack:
  - slack        → run length ≥ 4, or set size ≥ 4 (donatable)
  - rigid        → size exactly 3; peeling breaks it
  - singleton    → size 1 (the "stack" is just a loose card)
  - pure_run / rb_run / set → mechanical kind
"""

import strategy


def classify(board):
    cards = {}
    stacks = {}

    # First pass: stack kind + size-based adjectives.
    for si, s in enumerate(board):
        raw = [bc["card"] for bc in s["board_cards"]]
        n = len(raw)
        kind = strategy._classify(raw)

        sadjs = {kind}  # e.g., "pure_run" or "other"
        if n == 1:
            sadjs.add("singleton")
        if kind in ("set",) and n >= 4:
            sadjs.add("slack")
        if kind in ("pure_run", "rb_run") and n >= 4:
            sadjs.add("slack")
        if kind in ("set", "pure_run", "rb_run") and n == 3:
            sadjs.add("rigid")
        stacks[si] = sadjs

        for ci, bc in enumerate(s["board_cards"]):
            adjs = set()
            if n == 1:
                adjs.add("loose")
            if ci == 0 or ci == n - 1:
                adjs.add("edge")
            if strategy._can_extract(s, ci):
                adjs.add("peelable")
            elif "rigid" in sadjs or kind == "other":
                adjs.add("trapped")
            cards[(si, ci)] = adjs

    # Second pass: cross-card adjectives (dup detection).
    seen = {}  # (value, suit) -> list of (si, ci)
    for si, s in enumerate(board):
        for ci, bc in enumerate(s["board_cards"]):
            c = bc["card"]
            key = (c["value"], c["suit"])
            seen.setdefault(key, []).append((si, ci))
    for key, positions in seen.items():
        if len(positions) > 1:
            for pos in positions:
                cards[pos].add("dup")

    return cards, stacks


def pretty_print(board):
    cards, stacks = classify(board)
    for si, s in enumerate(board):
        sadjs = stacks[si]
        label_bits = []
        for ci, bc in enumerate(s["board_cards"]):
            label = _label(bc["card"])
            adjs = cards[(si, ci)]
            if adjs:
                label_bits.append(f"{label}({','.join(sorted(adjs))})")
            else:
                label_bits.append(label)
        print(f"  [{si:2}] {{{','.join(sorted(sadjs))}}}: {' '.join(label_bits)}")


def _label(c):
    rank = {1: "A", 11: "J", 12: "Q", 13: "K"}.get(c["value"], str(c["value"]))
    suit = {0: "C", 1: "D", 2: "S", 3: "H"}.get(c["suit"], "?")
    return f"{rank}{suit}"
