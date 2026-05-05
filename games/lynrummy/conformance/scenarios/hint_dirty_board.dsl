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
# Pinned for TS_ELM_INTEGRATION Phase 1 (2026-05-05) after a
# real-play observation that hints could surface a "place
# triple" recommendation while a partial sat on the board
# from earlier in the same turn.

scenario triple_in_hand_with_dirty_board_returns_no_hint
  desc: hand contains a triple [7D 8D 9D] but the board has a dangling partial [5C 6C] that no card on the board OR in hand can complete. The triple-in-hand short-circuit MUST NOT fire — placing the triple alone would leave [5C 6C] dirty. With no completing third reachable for [5C 6C], findPlay returns null and the hint is empty.
  op: hint_for_hand
  hand: 7D 8D 9D
  board:
    - 5C 6C
  expect_steps:
