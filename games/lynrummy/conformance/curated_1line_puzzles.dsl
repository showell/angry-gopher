# Hand-crafted 1-line (Level 1) Lyn Rummy puzzles.
#
# The gentlest tier: every move is a trivial "drag a card onto the
# stack where it obviously belongs" — complete a pair, or extend a
# meld. No stack-breaking, no rearranging. Authored by hand (not mined)
# and kept in this deliberate teaching order, so — unlike the mined
# tiers — this file is NOT sorted by board card count:
#
#   1-3  complete a pair: set, pure run, rb run (drag the 3rd card)
#   4    all three pair types at once; 3 singletons, each with one home
#   5    long runs with context — append to a 5-run and a 4-card rb run
#   6    rb run that wraps K -> A -> 2
#   7    extend one run at BOTH ends
#   8    two parallel suited runs — match the suit, don't cross
#   9    extend one of each meld type (set / pure run / rb run) to 4
#   10   capstone: a run extended both ends + a set extended
#
# Plan length therefore varies per puzzle (1-3 moves); every move is an
# extend/complete. Puzzles 1-4 lay each loose card directly by its home
# (gentle); 5+ deliberately SCATTER the loose cards so the player has to
# work out which card goes where, not just drag straight up. UI:
# views/puzzle.go consumes directly. No conformance — surfacing-only.

# 1 — SET: two aces, drag the third.
puzzle 1line_set_intro
  at (130,200): A♠ A♥
  at (130,320): A♦

# 2 — PURE RUN: 2-3 of spades, drag the 4.
puzzle 1line_run_intro
  at (130,200): 2♠ 3♠
  at (130,320): 4♠

# 3 — RB RUN: red-black 5-6, drag the red 7.
puzzle 1line_rb_run_intro
  at (130,200): 5♥ 6♠
  at (130,320): 7♦

# 4 — All three pair types; each singleton has exactly one home.
puzzle 1line_three_pair_types
  at (100,90): K♠ K♥
  at (100,230): K♦
  at (320,90): 5♣ 6♣
  at (320,230): 7♣
  at (540,90): 9♥ T♠
  at (540,230): J♦

# 5 — Long runs with context: append to a 5-run and a 4-card rb run.
#     Loose cards swapped — 4♠ sits by the rb run, T♦ by the spade run.
puzzle 1line_long_runs
  at (60,110): Q♠ K♠ A♠ 2♠ 3♠
  at (60,240): T♦
  at (60,380): 6♦ 7♠ 8♥ 9♣
  at (60,500): 4♠

# 6 — RB run wrapping K -> A -> 2; the lone card is parked far away.
puzzle 1line_rb_wrap
  at (60,120): T♠ J♦ Q♠ K♦ A♠ 2♦
  at (480,400): 3♠

# 7 — Extend one run at BOTH ends; the low card sits right, the high left.
puzzle 1line_both_ends
  at (220,140): 5♥ 6♥ 7♥
  at (400,330): 4♥
  at (90,330): 8♥

# 8 — Two parallel suited runs; the loose cards sit under the WRONG suit.
puzzle 1line_two_suits
  at (110,110): 3♠ 4♠ 5♠
  at (430,110): 3♥ 4♥ 5♥
  at (430,280): 6♠
  at (110,280): 6♥

# 9 — Extend one of each meld type to four; loose cards rotated off-home.
puzzle 1line_extend_each_type
  at (90,90): 2♦ 3♦ 4♦
  at (340,90): 7♥ 8♠ 9♥
  at (590,90): Q♣ Q♥ Q♠
  at (590,300): 5♦
  at (90,300): T♠
  at (340,300): Q♦

# 10 — Capstone: run extended both ends + a set extended; all scattered.
puzzle 1line_capstone
  at (250,80): 5♣ 6♣ 7♣ 8♣
  at (520,300): 4♣
  at (80,180): 9♣
  at (340,420): 3♥ 3♠ 3♦
  at (60,470): 3♣
