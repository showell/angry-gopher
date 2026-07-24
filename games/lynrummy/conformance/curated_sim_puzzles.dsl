# Curated sim-mined Lyn Rummy puzzles.
#
# Mined from zig agent self-play (games/lynrummy/zig/sim.zig) by
# ops/mine_lynrummy_puzzle: each board is the HARDEST SOLVED MOVE of
# one full simulated game — the probe arrangement whose cover cost
# the converged solver the most steps. The probed hand card(s) sit on
# the board as loose singletons; everything else is the agent's own
# clean melds at that moment, so the shape is "the table is tidy,
# now work this card in."
#
# Unlike the N-line catalogs, difficulty here is measured in solver
# steps, not plan length — the reference consolidation length is in
# each puzzle's comment, and a shorter human line may well exist.
# Names encode provenance: sim_s<seed>t<turn>.
#
# Format matches curated_6line_puzzles.dsl. Solvability is enforced
# by games/lynrummy/puzzle_gate.zig (counts pinned there).

# Mined 57-card board from self-play seed 107, turn 4: the
# hardest solved move of the game (623630 solver steps; the
# reference consolidation runs 15 verb moves).
puzzle sim_s107t4
  at (20,20): 7♥ 8♠ 9♥ T♣
  at (170,20): T♥ T♦ T♣' T♠
  at (320,20): K♥ A♥ 2♥ 3♥ 4♥
  at (503,20): J♦ J♣ J♠
  at (620,20): Q♦ K♦ A♦
  at (20,80): 2♣ 3♦ 4♣ 5♥ 6♠
  at (203,80): 5♣ 6♣ 7♣
  at (320,80): 3♠ 4♦ 5♠
  at (437,80): Q♠ K♦' A♣
  at (554,80): 7♥' 7♦ 7♠
  at (671,80): 9♥' 9♣ 9♠
  at (20,140): 7♦' 8♦ 9♦
  at (137,140): 2♣' 2♦ 2♥'
  at (254,140): J♣' J♥ J♦'
  at (371,140): 9♠' T♦' J♠' Q♥
  at (521,140): Q♠' K♠ A♠ 2♠
  at (671,140): 5♣'
