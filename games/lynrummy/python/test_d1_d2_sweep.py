"""
test_d1_d2_sweep.py — construct a 52-card all-deck-1 board with
{4s, 8s} as sets and the remaining 11-per-suit as two pure runs
(length-8 wrap + length-3 mid). For each of the 52 deck-2 cards,
drop it as a loose and ask the planner to clean up.

Reports which cards solve cleanly, which get the planner stuck.
"""

import test_dsl_player as td
import dsl_player
import dsl_planner
import strategy


# ------------------------------------------------------------
# Rock-solid Claude-completeness checker.
#
# "Claude-complete" = the planner can place every card in the
# deck on this initial board, where "place" means:
#   Layer 1 — planner claims success (plan() returns a script).
#   Layer 2 — re-executing the script from scratch against a
#             fresh copy of the initial board lands on the same
#             final state (no hidden mutation, script is
#             deterministic under the verbs).
#   Layer 3 — the final board is fully legal: every stack
#             classifies as set / pure_run / rb_run.
#   Layer 4 — card conservation: the bag of (value, suit, deck)
#             tuples in the final board equals the initial's.
#             No card created, lost, or duplicated.
#
# Any failure is reported; only Layer 1+2+3+4 all passing counts
# as solved.
# ------------------------------------------------------------


def _card_bag(board):
    out = []
    for s in board:
        for bc in s["board_cards"]:
            c = bc["card"]
            out.append((c["value"], c["suit"], c["origin_deck"]))
    return sorted(out)


def _fully_legal(board):
    for i, s in enumerate(board):
        cards = [bc["card"] for bc in s["board_cards"]]
        if strategy._classify(cards) == "other":
            return False, (
                f"stack {i} (size {len(cards)}) not a legal group: "
                f"{[dsl_player._label(c) for c in cards]}"
            )
    return True, None


def verify_claim(initial_board, script, planner_final):
    """Returns (ok, reason). Runs all four layers."""
    try:
        _, rerun = dsl_player.run(script, initial_board)
    except dsl_player.DSLError as e:
        return False, f"layer-2 rerun error: {e}"
    if _card_bag(rerun) != _card_bag(planner_final):
        return False, "layer-2 rerun produced different card bag than planner"
    ok, reason = _fully_legal(rerun)
    if not ok:
        return False, f"layer-3 illegal final: {reason}"
    if _card_bag(initial_board) != _card_bag(rerun):
        return False, "layer-4 card conservation failed"
    return True, None


def _wipe_locs(board):
    """Assign non-overlapping locations via find_open_loc."""
    laid = []
    for spec in board:
        loc = strategy.find_open_loc(
            laid, card_count=len(spec["board_cards"]))
        spec = dict(spec, loc=loc)
        laid.append(spec)
    return laid


def build_d1_board_all_pure():
    """All eight non-set stacks are pure runs. Simplest canned
    corpus."""
    stacks = []
    stacks.append(td.stack("4C:0 4D:0 4S:0 4H:0"))
    stacks.append(td.stack("8C:0 8D:0 8S:0 8H:0"))
    for suit in "CDSH":
        stacks.append(td.stack(" ".join(f"{r}{suit}:0" for r in "9TJQKA23")))
    for suit in "CDSH":
        stacks.append(td.stack(" ".join(f"{r}{suit}:0" for r in "567")))
    return _wipe_locs(stacks)


def build_d1_board_half_rb():
    """Half pure, half rb. Clubs + hearts keep pure runs;
    diamonds and spades weave into rb runs (two long, two
    short). Exact same 52 cards total."""
    stacks = []
    stacks.append(td.stack("4C:0 4D:0 4S:0 4H:0"))
    stacks.append(td.stack("8C:0 8D:0 8S:0 8H:0"))
    # Pure long runs: clubs + hearts.
    stacks.append(td.stack(" ".join(f"{r}C:0" for r in "9TJQKA23")))
    stacks.append(td.stack(" ".join(f"{r}H:0" for r in "9TJQKA23")))
    # rb long A: starts red (D), alternates D-S by position.
    #   9D TS JD QS KD AS 2D 3S
    stacks.append(td.stack("9D:0 TS:0 JD:0 QS:0 KD:0 AS:0 2D:0 3S:0"))
    # rb long B: starts black (S), uses remaining diamond/spade cards.
    #   9S TD JS QD KS AD 2S 3D
    stacks.append(td.stack("9S:0 TD:0 JS:0 QD:0 KS:0 AD:0 2S:0 3D:0"))
    # Pure short runs: clubs + hearts.
    stacks.append(td.stack("5C:0 6C:0 7C:0"))
    stacks.append(td.stack("5H:0 6H:0 7H:0"))
    # rb short A + B using remaining diamond/spade.
    stacks.append(td.stack("5D:0 6S:0 7D:0"))
    stacks.append(td.stack("5S:0 6D:0 7S:0"))
    return _wipe_locs(stacks)


def build_d1_board_rigid_half_rb():
    """Take all-rigid-pure and flip the middle runs (4-5-6 and
    7-8-9 per suit) into rb 3-card runs that weave suits
    together. [A 2 3] and [T J Q K] per suit stay pure. Greedy
    merge still consolidates some pure fragments, but the rb
    middles resist simple stitching."""
    stacks = []
    for suit in "CDSH":
        stacks.append(td.stack(" ".join(f"{r}{suit}:0" for r in "A23")))
        stacks.append(td.stack(" ".join(f"{r}{suit}:0" for r in "TJQK")))
    # rb 4-5-6 (values 4,5,6 alternating colors).
    stacks.append(td.stack("4D:0 5C:0 6D:0"))
    stacks.append(td.stack("4H:0 5S:0 6H:0"))
    stacks.append(td.stack("4C:0 5D:0 6C:0"))
    stacks.append(td.stack("4S:0 5H:0 6S:0"))
    # rb 7-8-9.
    stacks.append(td.stack("7D:0 8C:0 9D:0"))
    stacks.append(td.stack("7H:0 8S:0 9H:0"))
    stacks.append(td.stack("7C:0 8D:0 9C:0"))
    stacks.append(td.stack("7S:0 8H:0 9S:0"))
    return _wipe_locs(stacks)


def build_d1_board_all_sets():
    """Thirteen size-4 sets, one per value. No runs. Sets can't
    be greedy-merged with each other, so the pre-pass has
    nothing to do. D2 cards must rely on peel+build-via-pair
    to form new pure runs."""
    stacks = []
    for v in "A23456789TJQK":
        stacks.append(td.stack(f"{v}C:0 {v}D:0 {v}S:0 {v}H:0"))
    return _wipe_locs(stacks)


def build_d1_board_all_rigid_pure():
    """Adversarial arrangement: no sets, all pure runs, each
    suit split into 3+3+3+4. Only one length-4 donor per suit;
    the rest are rigid length-3. Tests chained augmentation."""
    stacks = []
    for suit in "CDSH":
        stacks.append(td.stack(" ".join(f"{r}{suit}:0" for r in "A23")))
        stacks.append(td.stack(" ".join(f"{r}{suit}:0" for r in "456")))
        stacks.append(td.stack(" ".join(f"{r}{suit}:0" for r in "789")))
        stacks.append(td.stack(" ".join(f"{r}{suit}:0" for r in "TJQK")))
    return _wipe_locs(stacks)


def build_d1_board_four_long():
    """Smallest possible stack count: each suit as one length-13
    pure run (wraps K-A-2-3 back to 4). No sets; no short runs;
    no donor pool for augmentation. Splice is the only
    reduction mechanism."""
    stacks = []
    for suit in "CDSH":
        # Run 4-5-6-...-K-A-2-3 (13 values wrapping K→A).
        stacks.append(td.stack(" ".join(
            f"{r}{suit}:0" for r in "456789TJQKA23")))
    return _wipe_locs(stacks)


def build_d1_board_rigid_heavy():
    """Lots of rigid length-3 runs; only one slack run per suit.
    Stresses augment-then-splice with long augment chains."""
    stacks = []
    stacks.append(td.stack("4C:0 4D:0 4S:0 4H:0"))
    stacks.append(td.stack("8C:0 8D:0 8S:0 8H:0"))
    for suit in "CDSH":
        stacks.append(td.stack(" ".join(f"{r}{suit}:0" for r in "A23")))
        stacks.append(td.stack(" ".join(f"{r}{suit}:0" for r in "567")))
        stacks.append(td.stack(" ".join(f"{r}{suit}:0" for r in "9TJQK")))
    return _wipe_locs(stacks)


def build_d1_board_no_sets():
    """Zero sets. Each suit split into two medium runs:
    low (4-9, length 6) and high (T-J-Q-K-A-2-3, length 7).
    No set-donor pool — augments must use run edges only."""
    stacks = []
    for suit in "CDSH":
        stacks.append(td.stack(" ".join(f"{r}{suit}:0" for r in "456789")))
    for suit in "CDSH":
        stacks.append(td.stack(" ".join(f"{r}{suit}:0" for r in "TJQKA23")))
    return _wipe_locs(stacks)


def build_d1_board_no_4set():
    """Drop the 4s set; distribute 4s into mid runs 4-5-6-7
    (pure). Only the 8s set remains. Halves the set-donor pool
    available for augment-style tricks."""
    stacks = []
    stacks.append(td.stack("8C:0 8D:0 8S:0 8H:0"))
    for suit in "CDSH":
        stacks.append(td.stack(" ".join(f"{r}{suit}:0" for r in "9TJQKA23")))
    for suit in "CDSH":
        stacks.append(td.stack(" ".join(f"{r}{suit}:0" for r in "4567")))
    return _wipe_locs(stacks)


def build_d1_board_all_rb():
    """All eight non-set stacks are rb runs. Pure-splice can't
    fire at all; every splice must use the rb path."""
    stacks = []
    stacks.append(td.stack("4C:0 4D:0 4S:0 4H:0"))
    stacks.append(td.stack("8C:0 8D:0 8S:0 8H:0"))
    # Four rb long runs (9-T-J-Q-K-A-2-3), each alternating.
    stacks.append(td.stack("9D:0 TC:0 JD:0 QC:0 KD:0 AC:0 2D:0 3C:0"))
    stacks.append(td.stack("9H:0 TS:0 JH:0 QS:0 KH:0 AS:0 2H:0 3S:0"))
    stacks.append(td.stack("9C:0 TD:0 JC:0 QD:0 KC:0 AD:0 2C:0 3D:0"))
    stacks.append(td.stack("9S:0 TH:0 JS:0 QH:0 KS:0 AH:0 2S:0 3H:0"))
    # Four rb short runs (5-6-7), alternating.
    stacks.append(td.stack("5D:0 6C:0 7D:0"))
    stacks.append(td.stack("5H:0 6S:0 7H:0"))
    stacks.append(td.stack("5C:0 6D:0 7C:0"))
    stacks.append(td.stack("5S:0 6H:0 7S:0"))
    return _wipe_locs(stacks)


# Default: use the half-rb variant for sweep.
def build_d1_board():
    return build_d1_board_rigid_half_rb()


def all_d2_cards():
    out = []
    for suit in range(4):
        for value in range(1, 14):
            out.append({"value": value, "suit": suit, "origin_deck": 1})
    return out


def run_sweep():
    solved, stuck, bogus = [], [], []
    for d2 in all_d2_cards():
        board = build_d1_board()
        loc = strategy.find_open_loc(board, card_count=1)
        initial = board + [{"board_cards": [{"card": d2, "state": 0}], "loc": loc}]
        script, final = dsl_planner.plan(initial)
        lbl = dsl_player._label(d2)
        if script is None:
            stuck.append(lbl)
            continue
        ok, reason = verify_claim(initial, script, final)
        if not ok:
            bogus.append((lbl, reason))
            continue
        solved.append((lbl, len(script.splitlines())))
    print(f"solved (verified): {len(solved)}/52")
    print(f"stuck:             {len(stuck)}/52")
    print(f"bogus claims:      {len(bogus)}/52")
    if stuck:
        print("stuck cards:", stuck)
    if bogus:
        print("bogus claims (planner said solved but check failed):")
        for lbl, reason in bogus:
            print(f"  {lbl}: {reason}")
    print()
    print("sample solved (card → script lines):")
    for lbl, n in solved[:10]:
        print(f"  {lbl}: {n}")


if __name__ == "__main__":
    run_sweep()
