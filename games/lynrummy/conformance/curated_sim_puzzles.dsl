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

# Mined 64-card board from self-play seed 95, turn 6: the
# hardest solved move of the game (580583 solver steps; the
# reference consolidation runs 34 verb moves — but Steve solved it
# in SIX, kept 41/44 edges, all above rank 8: the 9H'-TC-JD-QC run
# is the key the sweep never finds).
puzzle sim_s95t6
  at (20,20): A♥ A♦ A♠
  at (137,20): 3♥ 4♣ 5♥
  at (254,20): 4♥ 4♣' 4♠
  at (371,20): K♥ K♦ K♠
  at (488,20): 2♦ 2♣ 2♠
  at (605,20): 3♦ 3♣ 3♠
  at (20,80): 5♦ 6♠ 7♥ 8♠ 9♥
  at (203,80): 7♦ 7♠ 7♣
  at (320,80): 8♦ 9♠ T♦ J♣
  at (470,80): J♦ Q♦ K♦'
  at (587,80): T♣ J♣' Q♣
  at (20,140): J♠ Q♥ K♠' A♦'
  at (170,140): Q♠ K♥' A♠' 2♥ 3♠'
  at (353,140): 4♥' 5♥' 6♥
  at (470,140): 7♥' 8♣ 9♦
  at (587,140): 7♦' 7♣' 7♠'
  at (20,200): A♣ 2♥' 3♣'
  at (137,200): Q♣' K♣ A♣'
  at (254,200): 4♠' 5♦' 6♣
  at (371,200): 9♥'

# Mined 62-card board from self-play seed 441, turn 5: the
# hardest solved move of the game (994264 solver steps — the
# closest any mined board has come to the 1M give-up line; the
# reference consolidation runs 22 verb moves).
puzzle sim_s441t5
  at (20,20): 6♥ 7♥ 8♥ 9♥
  at (170,20): 7♦ 7♣ 7♠
  at (287,20): 8♦ 9♣ T♦ J♣ Q♥
  at (470,20): 9♦ T♣ J♦
  at (587,20): Q♦ K♠ A♦ 2♠ 3♦ 4♠
  at (20,80): K♦ K♥ K♠' K♣
  at (170,80): 2♣ 3♥ 4♣ 5♥ 6♠
  at (353,80): 3♣ 4♥ 5♣
  at (470,80): Q♣ K♦' A♣ 2♦
  at (620,80): A♠ 2♥ 3♣'
  at (20,140): 3♠ 4♦ 5♠
  at (137,140): Q♦' Q♥' Q♠
  at (254,140): A♣' A♥ A♠'
  at (371,140): 4♣' 4♦' 4♥'
  at (488,140): 5♠' 6♦ 7♣' 8♦'
  at (20,200): 6♠' 7♥' 8♠ 9♦' T♠
  at (203,200): T♣'
