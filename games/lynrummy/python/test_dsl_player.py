"""
test_dsl_player.py — DSL scripts execute cleanly against
synthetic boards.

Each test builds a small board from card labels + a list of
loose stragglers, runs a DSL script, and asserts the final
board is clean. Synthetic boards keep card identities
unambiguous (single deck) so the DSL stays terse.
"""

import dsl_player
import strategy


SUITS = {"C": 0, "D": 1, "S": 2, "H": 3}
RANKS = {"A": 1, "2": 2, "3": 3, "4": 4, "5": 5, "6": 6, "7": 7,
         "8": 8, "9": 9, "T": 10, "J": 11, "Q": 12, "K": 13}


def card(label, deck=0):
    # Label optionally has `:deck` suffix for multi-deck tests.
    if ":" in label:
        base, d = label.split(":", 1)
        return {"value": RANKS[base[0]], "suit": SUITS[base[1]],
                "origin_deck": int(d)}
    return {"value": RANKS[label[0]], "suit": SUITS[label[1]],
            "origin_deck": deck}


def stack(labels_str, at=None, deck=0):
    cards = [{"card": card(lbl, deck), "state": 0}
             for lbl in labels_str.split()]
    return {"board_cards": cards,
            "loc": at or {"top": 0, "left": 0}}


def build(stacks, stragglers=(), deck=0):
    """Produce a board from a list of stack specs + loose card
    labels. Auto-assigns non-overlapping locations via
    find_open_loc so tests don't fiddle with geometry."""
    board = []
    for spec in stacks:
        if isinstance(spec, str):
            spec = stack(spec, deck=deck)
        loc = strategy.find_open_loc(
            board, card_count=len(spec["board_cards"]))
        spec = dict(spec, loc=loc)
        board.append(spec)
    for lbl in stragglers:
        loc = strategy.find_open_loc(board, card_count=1)
        board.append({"board_cards": [{"card": card(lbl, deck), "state": 0}],
                      "loc": loc})
    return board


def run_test(name, board, script):
    print(f"=== {name} ===")
    prims, final = dsl_player.run(script, board)
    print(f"  primitives: {len(prims)}")
    for i, s in enumerate(final):
        cards = [bc["card"] for bc in s["board_cards"]]
        kind = strategy._classify(cards)
        assert kind != "other", \
            f"final stack {i} {[dsl_player._label(c) for c in cards]} illegal"
    print(f"  final: {len(final)} legal stacks")
    print("  PASS")


# ------------------------------------------------------------
# Test 1 — simplest extend. Loose 5H joins pure-hearts length 3.
# ------------------------------------------------------------

def test_simple_extend():
    board = build(["2H 3H 4H"], stragglers=["5H"])
    run_test("simple extend", board, "home 5H into 2H")


# ------------------------------------------------------------
# Test 2 — peel + extend. Need 5H but it's trapped mid-pure-hearts;
# peel it off the edge of a length-4 pure run, then extend another
# target run.
# ------------------------------------------------------------

def test_peel_and_extend():
    # Board:
    #   [2H 3H 4H 5H] pure hearts length 4 (5H peelable from right edge)
    #   [6H 7H 8H] pure hearts length 3 (needs 5H left to become len 4)
    # Actually, to make 6H-7H-8H a valid home for 5H, we extend left.
    board = build(["2H 3H 4H 5H", "6H 7H 8H"])
    # Wait — this creates value overlap but with only deck=0 we'd
    # have two 5Hs which would conflict. Let me instead use different
    # values: peel a card from one stack, extend another.
    # Drop and redo:


def test_peel_from_edge_and_home():
    # Donor: [2H 3H 4H 5H] — 5H peelable right edge.
    # Acceptor: [6H 7H 8H] — can extend left with 5H.
    # Result: [2H 3H 4H] + [5H 6H 7H 8H].
    board = build(["2H 3H 4H 5H", "6H 7H 8H"])
    run_test("peel right edge + home left", board, """
        peel 5H from 2H
        home 5H into 6H
    """)


# ------------------------------------------------------------
# Test 3 — dissolve + home. Size-3 rigid set of aces dissolves
# into three looses, each finds a home. Plus a loose QH joins
# two looses to build a Q-K-A wrap.
# ------------------------------------------------------------

def test_dissolve_and_home():
    board = build([
        "AC AD AH",          # rigid set of aces
        "2H 3H 4H",          # pure hearts — AH extends left
        "JD QC KD",          # rb run — AC extends right (K-A wrap)
    ], stragglers=["QH", "KS"])
    run_test("dissolve aces + build Q-K-A wrap", board, """
        # Combine the two looses first (QH + KS); transient stack.
        extend QH onto KS side:left

        # Dissolve the aces. Calibrated leap.
        dissolve AC AD AH

        # Each ace finds a home.
        home AH into 2H            # A-2-3-4 pure hearts wrap left
        home AC into JD            # J-Q-K-A rb wrap right
        home AD into QH            # Q-K-A on the transient [QH KS]
    """)


# ------------------------------------------------------------
# Test 4 — augment-then-peel. A size-3 rigid set is grown to 4 by
# donating a same-value card from an adjacent slack run, then the
# set becomes peelable.
#
# This one surfaces the need for a new verb: `augment`.
# ------------------------------------------------------------

def test_augment_then_peel():
    # Augment a size-3 set to slack by donating from a slack
    # pure run, then peel a different suit out of the now-slack
    # set. Use the freed card plus another peel to assemble a
    # new pure run for the loose.
    #
    # Final:
    #   [8H 9H 10H]  — new pure hearts (what we built)
    #   [9S 9C 9D]   — original set, reformed with 9D instead of 9H
    #   [10D JD QD]  — diamonds minus 9D (length-3 pure)
    #   [JH QH KH]   — hearts minus 10H (length-3 pure)
    board = build([
        "9H 9S 9C",          # rigid set of 9s
        "9D TD JD QD",       # slack pure diamonds (9D left-edge peelable)
        "TH JH QH KH",       # slack pure hearts (TH left-edge peelable)
    ], stragglers=["8H"])
    run_test("augment + peel + build pure run", board, """
        peel   9D from 9D            # peel 9D off its diamond run
        extend 9D onto 9H side:right # augment set → slack
        peel   9H from 9H            # peel 9H (set-slack, left edge)
        peel   TH from TH            # peel TH (run left edge)
        extend 8H onto 9H side:left  # transient [8H 9H]
        home   TH into 8H            # [8H 9H TH] pure hearts
    """)


def test_middle_swap_then_home():
    # rb_run [TC JH QC KH] — slot ci=1 is JH (red middle).
    # Loose JD (red) swaps for JH. Kicked JH homes to pure hearts.
    board = build([
        "TC JH QC KH",     # rb length 4 (black-red-black-red)
        "8H 9H TH",        # pure hearts length 3 (extend right with JH)
    ], stragglers=["JD"])
    run_test("middle rb_swap + home kicked", board, """
        swap JD for JH
        home JH into 8H
    """)


def test_splice():
    # Pure diamonds length 5 with dup at middle (deck 1 of 4D).
    # Splice dup 4D into the middle: split after twin 4D, merge
    # hand dup onto right fragment's left edge. Result: two
    # legal pure diamond length-3 runs.
    board = build([
        stack("2D:0 3D:0 4D:0 5D:0 6D:0"),  # pure diamonds len 5
    ], stragglers=["4D:1"])
    run_test("splice dup into pure run middle", board, """
        splice 4D:1 into 2D:0
    """)


if __name__ == "__main__":
    test_simple_extend()
    print()
    test_peel_from_edge_and_home()
    print()
    test_dissolve_and_home()
    print()
    test_augment_then_peel()
    print()
    test_middle_swap_then_home()
    print()
    test_splice()
    print()
    print("done")
