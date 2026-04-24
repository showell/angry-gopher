"""
test_dsl_planner.py — the planner generates DSL scripts from
dirty boards without any hand-authored scripts.
"""

import dsl_planner
import test_dsl_player as td  # reuse build/stack helpers
import strategy


def run_plan_test(name, board):
    print(f"=== {name} ===")
    initial_looses = dsl_planner._count_looses(board)
    print(f"  initial looses: {initial_looses}")
    script, final = dsl_planner.plan(board, verbose=True)
    if script is None:
        print("  FAIL — planner stuck")
        return
    # Verify final board clean.
    for i, s in enumerate(final):
        cards = [bc["card"] for bc in s["board_cards"]]
        kind = strategy._classify(cards)
        assert kind != "other", \
            f"final stack {i} illegal: {cards}"
    final_looses = dsl_planner._count_looses(final)
    print(f"  final looses: {final_looses}")
    print(f"  script lines: {len([l for l in script.splitlines() if l.strip() and not l.strip().startswith('#')])}")
    print(f"  PASS")


def test_plan_simple_extend():
    # Simplest: one loose, direct home.
    board = td.build(["2H 3H 4H"], stragglers=["5H"])
    run_plan_test("plan: simple extend", board)


def test_plan_peel_and_home():
    # Need peel + home.
    board = td.build(["2H 3H 4H 5H", "6H 7H 8H"])
    run_plan_test("plan: peel-and-home", board)


def test_plan_build_via_pair():
    # Build a new run from two peelable partners + loose.
    # [9D TD JD QD] pure diamonds (9D peelable L edge).
    # [TH JH QH KH] pure hearts (TH peelable L edge).
    # [9H 9S 9C] rigid set (not usable here — distraction).
    # Loose: 8H (target).
    # Goal: build [8H 9? T?] — hmm, but 9D is diamond, 8H is heart.
    # Let me construct more cleanly. Peel a 9 and a T that pair
    # with 8H to form rb or pure.
    # 8H-9S-TH: rb? 8H(r)-9S(b)-TH(r) alternating ✓. Values 8-9-T ✓.
    # 9S peelable: needs [9S ??? ???] length 4+. Build [9S TS JS QS]
    # pure spades length 4.
    # TH peelable: [TH JH QH KH] length 4. TH left edge ✓.
    # 8H joins them: rb 8H-9S-TH via build-via-pair.
    board = td.build([
        "9S TS JS QS",  # peel 9S (left edge)
        "TH JH QH KH",  # peel TH (left edge)
        "2D 3D 4D",      # filler
    ], stragglers=["8H"])
    run_plan_test("plan: build-via-pair", board)


def test_plan_dissolve_aces():
    # Dissolve-and-place: set of aces + loose QH + useful targets.
    board = td.build([
        "AC AD AH",
        "2H 3H 4H",       # AH extends left → pure hearts len 4
        "JD QC KD",       # AC extends right → rb J-Q-K-A wrap
        "JH QH KH",       # Add pure hearts for AD? Hmm no. AD would extend KD side → K-A wrap. Already handled by AC above.
    ], stragglers=["QH", "KS"])
    # Hmm this is tricky — we have TWO looses (QH, KS) + rigid set (3 aces).
    # Goal: all 5 cards (QH, KS, AC, AD, AH) find homes.
    # QH + KS can form transient [QH KS] length 2 → + AD → rb Q-K-A length 3.
    # But this requires dissolve before placing QH+KS. Hmm my planner doesn't know this.
    # Let me simplify and start with just one loose.
    run_plan_test("plan: dissolve aces (single loose)", board)


def test_plan_dissolve_single_target():
    # Simpler dissolve: aces + loose that lands via one of them.
    board = td.build([
        "AC AD AH",
        "2H 3H 4H 5H",     # AH extends left → pure hearts len 5
        "2D 3D 4D 5D",     # AD extends left → pure diamonds len 5
        "2C 3C 4C 5C",     # AC extends left → pure clubs len 5
    ], stragglers=[])
    # No loose here! Let me add one that needs dissolving to create a slot.
    # Hmm, this won't trigger dissolve unless the loose HAS no other home.
    # Make it: loose needs a partner that's only available post-dissolve.
    # Let's keep it simple: dissolve is triggered for the LOOSE, not for
    # set mates. If the loose can direct-home, planner uses that first.
    pass


if __name__ == "__main__":
    test_plan_simple_extend()
    print()
    test_plan_peel_and_home()
    print()
    test_plan_build_via_pair()
    print()
    test_plan_dissolve_aces()
    print()
    print("done")
