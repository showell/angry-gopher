# hint_dirty_board.dsl — pin the dirty-board contract for the
# hand-aware hint surface.
#
# `findPlay` must NEVER recommend a play that leaves trouble on
# the board. The triple-in-hand short-circuit (tier a in
# `hand_play.ts:findPlay`) is the only path that doesn't run
# BFS over the augmented board, so it's the only path that
# can in principle skip the dirty-board constraint. These
# scenarios pin the constraint at that boundary: when the
# existing board has trouble AND the hand contains a
# length-3 legal triple, the triple-place short-circuit must
# NOT fire.
#
# Pinned for T♠_ELM_INTEGRATION Phase 1 (2026-05-05) after a
# real-play observation that hints could surface a "place
# triple" recommendation while a partial sat on the board
# from earlier in the same turn.

scenario triple_in_hand_with_dirty_board_returns_no_hint
  desc: hand contains a triple [7♦ 8♦ 9♦] but the board has a dangling partial [5♣ 6♣] that no card on the board OR in hand can complete. The triple-in-hand short-circuit MUST NOT fire — placing the triple alone would leave [5♣ 6♣] dirty. With no completing third reachable for [5♣ 6♣], findPlay returns null and the hint is empty.
  op: hint_for_hand
  hand: 7♦ 8♦ 9♦
  board:
    - 5♣ 6♣
  expect_steps:

# --- loner flag: a hand-origin loner should be finished with BOARD cards
#     first, not by projecting more hand cards. Real seed-42 game-2 mid-turn
#     state (uid 16): the 2♠ we just laid onto an empty spot completes into a
#     set of 2s using two board peels — no hand card needed. WITHOUT the loner
#     flag the solver projects [8♥ 9♣] and bundles an unrelated 8-9-T run;
#     WITH it, the hint is just the two board peels that finish the 2♠.

# --- loner needs a hand PAIR: board-only fails, so the solver projects a
#     pair and the loner is pulled onto it. Real Stephen2 game-5 state: T♠'
#     laid onto an empty spot; no 8/9/J/Q or ten is extractable from the
#     board without stranding cards, so no board-only finish exists. The
#     pair [8♠' 9♥] lands and the T♠' completes it. The whole hint reads as
#     ONE line (the pair-landing-pad compression).

scenario loner_ts_completed_with_hand_pair
  desc: T♠' was just placed from hand onto an empty spot (loner=true). Board-only fails; the solver projects the hand pair [8♠' 9♥] and pulls the T♠' onto it. Compresses to a single place-with line.
  op: hint_for_hand
  loner: true
  hand: 4♥' 6♥' 9♥ 8♠' 9♠' J♠' A♦' 9♦' J♦' 3♣ 5♣ 6♣ J♣ Q♣
  board:
    - K♠ A♠ 2♠ 3♠
    - T♦ J♦ Q♦ K♦
    - 2♥ 3♥ 4♥
    - 7♠ 7♦ 7♣
    - A♣ A♦ A♥
    - 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    - T♠'
  expect_steps:
    - place 8♠ and 9♥ with the T♠ on the board

scenario loner_2s_finished_with_board_cards
  desc: 2♠ was just placed from hand onto an empty spot (loner=true). The board can be made fully legal by peeling 2♣ and 2♥ onto it (a set of 2s) — zero new hand cards. The hint is board-only; no "place from hand" line.
  op: hint_for_hand
  loner: true
  hand: 8♥ 4♦ 8♦ 6♣' 9♣'
  board:
    - K♠ A♠ 2♠
    - T♦ J♦ Q♦ K♦
    - 2♥ 3♥ 4♥ 5♥'
    - 7♠ 7♦ 7♣
    - A♣ A♦ A♥ A♠'
    - 2♣ 3♦ 4♣ 5♥ 6♠'
    - 5♦' 6♠ 7♥
    - T♠' J♥' Q♠
    - 2♥' 3♠ 4♥'
    - 2♠'
  expect_steps:
    - peel 2♣ from 2♣ 3♦ 4♣ 5♥ 6♠ onto 2♠
    - peel 2♥ from 2♥ 3♥ 4♥ 5♥ onto 2♣ 2♠
