# Curated 6-line Lyn Rummy puzzles.
#
# Generated 2026-05-18 from agent self-play across seeds 101–140
# with MAX_PLAN_LENGTH temporarily bumped to 8 in bfs/engine_v2.ts.
# Each board is a dirty state that the BFS solver resolves in
# exactly 6 verb-level moves. Names encode the sorted verb-multiset
# + provenance (s<seed>t<turn>p<player>) so duplicates within a
# verb-shape are distinguishable.
#
# Format matches curated_4line_puzzles.dsl / curated_5line_puzzles.dsl.
# UI: views/puzzle.go consumes directly (served as Puzzle 33..47
# after the 4-line and 5-line catalogs).
#
# Deliberately NOT in test_curated_puzzles.ts's PLAN_LENGTHS array.
# The production MAX_PLAN_LENGTH cap is 5; adding 6 to conformance
# would silently encourage that cap to drift. These puzzles exist
# for the UI's difficulty stretch, not as a contract on solver
# capability.

puzzle 6line_peel_push_push_split_out_steal_steal_s113t1p0
  at (160,80): T♦ J♦ Q♦ K♦
  at (130,260): A♣ A♦ A♥
  at (62,20): K♠ A♠ 2♠
  at (52,407): 3♥' 3♦ 3♠
  at (187,332): 7♠ 7♣ 7♥'
  at (13,196): 5♦' 6♦ 7♦
  at (60,332): 2♣ 2♠' 2♦
  at (100,140): 2♥ 3♥ 4♥
  at (109,482): 4♣ 5♥ 6♠ 7♥ 8♣'
  at (52,482): 5♣

puzzle 6line_peel_pull_push_push_steal_steal_s111t1p0
  at (100,140): 2♥ 3♥ 4♥
  at (40,200): 7♠ 7♦ 7♣
  at (130,260): A♣ A♦ A♥
  at (70,320): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  at (52,392): K♦' A♣' 2♥'
  at (52,467): 6♥' 7♣' 8♥'
  at (52,542): 2♣' 3♦' 4♠
  at (152,80): T♦ J♦ Q♦
  at (111,20): A♠ 2♠ 3♠
  at (187,392): K♠ K♣ K♦
  at (187,467): Q♦'

puzzle 6line_peel_pull_push_push_steal_steal_s122t1p0
  at (100,140): 2♥ 3♥ 4♥
  at (40,200): 7♠ 7♦ 7♣
  at (130,260): A♣ A♦ A♥
  at (70,320): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  at (52,392): 8♥ 9♠' T♦'
  at (52,467): 3♣ 4♦ 5♠'
  at (52,542): 7♦' 8♠ 9♥'
  at (152,80): T♦ J♦ Q♦
  at (111,20): A♠ 2♠ 3♠
  at (187,392): K♠ K♣' K♦
  at (187,467): Q♥

puzzle 6line_pull_push_steal_steal_steal_steal_s106t1p0
  at (160,80): T♦ J♦ Q♦ K♦
  at (100,140): 2♥ 3♥ 4♥
  at (40,200): 7♠ 7♦ 7♣
  at (52,392): 4♠ 4♥' 4♣'
  at (52,467): 9♦' T♠ J♦'
  at (159,542): 5♥ 6♠ 7♥
  at (171,260): A♦ A♥ A♠'
  at (228,332): 3♦ 4♣ 5♦
  at (228,407): A♣ 2♣ 3♣'
  at (111,20): A♠ 2♠ 3♠
  at (19,272): K♠ K♦' K♣
  at (52,542): 5♣'

puzzle 6line_peel_peel_pull_pull_steal_steal_s112t1p0
  at (100,140): 2♥ 3♥ 4♥
  at (130,260): A♣ A♦ A♥
  at (52,392): 4♦ 5♠ 6♥' 7♣'
  at (52,542): K♠ K♥ K♣
  at (152,20): 2♠ 3♠ 4♠'
  at (58,463): Q♣ K♦ A♠ 2♥'
  at (127,80): 9♦' T♦ J♦ Q♦
  at (187,542): 7♦ 8♦ 9♦
  at (62,320): 2♣ 3♦ 4♣ 5♥ 6♠
  at (217,392): 7♥ 7♠ 7♣
  at (52,212): Q♦'

puzzle 6line_peel_pull_push_push_steal_steal_s114t1p0
  at (100,140): 2♥ 3♥ 4♥
  at (40,200): 7♠ 7♦ 7♣
  at (130,260): A♣ A♦ A♥
  at (52,392): 9♣' 9♥' 9♠
  at (52,467): 6♠' 6♦ 6♥
  at (70,320): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥ 8♠
  at (19,542): K♠ K♣' K♦
  at (144,80): T♦ J♦ Q♦
  at (152,20): 2♠ 3♠ 4♠'
  at (157,542): Q♣ K♦' A♠ 2♥'
  at (187,392): Q♣'

puzzle 6line_peel_peel_push_push_steal_yank_s123t1p0
  at (70,20): K♠ A♠ 2♠ 3♠
  at (160,80): T♦ J♦ Q♦ K♦
  at (100,140): 2♥ 3♥ 4♥
  at (40,200): 7♠ 7♦ 7♣
  at (130,260): A♣ A♦ A♥
  at (70,320): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  at (52,392): K♠' K♦' K♣
  at (52,467): 5♣ 5♠' 5♥'
  at (52,542): 8♠ 8♥' 8♦'
  at (187,392): 9♦ T♠ J♥'
  at (187,467): 4♦

puzzle 6line_peel_pull_push_push_steal_steal_s107t2p1
  at (52,392): J♠' J♣' J♦'
  at (52,467): 7♠ 7♦ 7♥'
  at (62,320): 2♣ 3♦ 4♣ 5♥ 6♠
  at (79,196): 7♦' 7♣ 7♥
  at (160,80): T♦ J♦ Q♦ K♦ A♦
  at (67,140): A♥ 2♥ 3♥ 4♥
  at (52,542): 9♦' 9♣' 9♥
  at (187,392): T♥ J♥' Q♥'
  at (187,467): 8♦ 9♠' T♦'
  at (29,20): Q♠' K♠ A♠ 2♠
  at (261,542): 2♦ 3♠ 4♦ 5♠
  at (217,212): K♦' A♣ 2♥'
  at (187,542): T♣'

puzzle 6line_pull_push_shift_splice_steal_steal_s108t2p1
  at (40,200): 7♠ 7♦ 7♣
  at (52,467): 9♣ T♣' J♣'
  at (52,542): 4♦ 5♦ 6♦'
  at (60,392): A♠' 2♦ 3♣'
  at (187,392): K♥' K♣ K♦
  at (187,467): 3♣ 4♦' 5♠'
  at (187,542): 6♥' 6♠' 6♣'
  at (70,320): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥ 8♠
  at (119,80): 9♦ T♦ J♦ Q♦
  at (100,140): 2♥ 3♥ 4♥ 5♥'
  at (152,20): 2♠ 3♠ 4♠
  at (262,152): A♣ A♦ A♠
  at (167,256): K♠ A♥ 2♣'
  at (292,227): 8♠'

puzzle 6line_push_push_push_splice_steal_steal_s128t2p1
  at (52,392): 8♣' 8♠ 8♥
  at (52,467): A♣ A♦ A♠'
  at (59,140): A♥ 2♥ 3♥
  at (172,212): 2♠' 2♣ 2♦
  at (103,320): 3♦ 4♣ 5♥ 6♠
  at (187,467): K♦' K♠' K♣'
  at (305,88): 9♦' T♦ J♦
  at (455,92): K♦ A♦' 2♦' 3♦'
  at (19,212): Q♠ Q♣ Q♦
  at (37,20): Q♠' K♠ A♠ 2♠ 3♠
  at (187,92): 5♣ 6♣' 7♣
  at (214,542): 7♠ 7♦ 7♥
  at (187,392): 3♣' 4♥ 5♠' 6♦ 7♠' 8♦' 9♠' T♥'
  at (52,542): 9♥

puzzle 6line_peel_pull_pull_push_steal_steal_s131t2p1
  at (40,200): 7♠ 7♦ 7♣
  at (130,260): A♣ A♦ A♥
  at (52,467): J♣ J♠' J♦'
  at (200,542): 6♠ 7♥ 8♠ 9♥' T♣
  at (187,467): 6♥' 6♦' 6♠'
  at (84,140): 2♥ 3♥ 4♥
  at (199,332): 5♥ 5♣ 5♠
  at (262,227): 9♣ 9♥ 9♠'
  at (158,76): T♦ J♦ Q♦
  at (337,302): K♣' K♥' K♠
  at (238,152): T♠' J♥ Q♣ K♦ A♠ 2♦'
  at (116,388): 2♠ 3♦' 4♠'
  at (289,407): 2♦ 3♠ 4♥'
  at (17,538): A♦' 2♣ 3♦ 4♣
  at (52,272): 7♣'

puzzle 6line_peel_pull_push_splice_steal_steal_s127t2p1
  at (40,200): 7♠ 7♦ 7♣ 7♥'
  at (19,392): 5♠' 6♥ 7♣' 8♦'
  at (67,140): A♥ 2♥ 3♥ 4♥
  at (187,392): 5♦ 5♣' 5♠
  at (187,467): 6♣' 6♥' 6♠'
  at (134,542): A♣' 2♦' 3♣'
  at (262,227): T♦ T♣ T♠'
  at (314,152): Q♠' K♠ A♠ 2♠ 3♠
  at (60,467): 2♠' 3♦' 4♣'
  at (234,80): Q♦ K♦ A♦
  at (262,542): J♣ J♠' J♦
  at (87,256): K♣ A♣ 2♣
  at (152,320): 4♣ 5♥ 6♠ 7♥ 8♣'
  at (322,392): 3♥' 3♣ 3♦
  at (52,542): 7♠'

puzzle 6line_peel_push_push_split_out_steal_steal_s120t3p0
  at (52,392): 8♦ 8♥' 8♣'
  at (95,256): K♣' A♣ 2♣'
  at (217,407): Q♥' K♥' A♥ 2♥ 3♥
  at (154,152): T♦ J♣ Q♦'
  at (234,80): Q♦ K♦ A♦
  at (78,20): K♠ A♠ 2♠
  at (232,227): 6♠' 7♦' 8♠'
  at (292,152): 4♥' 4♣' 4♦
  at (52,467): T♠ J♦ Q♠ K♥
  at (397,302): 2♦' 3♠ 4♥
  at (89,538): 5♣' 6♣' 7♣
  at (236,332): 3♦ 4♣ 5♦' 6♣
  at (333,482): 2♥' 2♠' 2♣
  at (359,227): 3♥' 4♠' 5♥ 6♠
  at (32,200): 7♠ 7♦ 7♥
  at (52,92): T♥'

puzzle 6line_peel_peel_push_push_steal_yank_s134t3p0
  at (152,80): T♦ J♦ Q♦
  at (19,467): K♠ K♣' K♦
  at (48,200): 7♥ 7♦ 7♣
  at (157,467): K♣ A♣ 2♣
  at (320,268): 4♣ 5♥ 6♠
  at (187,152): A♠ 2♥' 3♠ 4♦ 5♣' 6♦ 7♠ 8♥' 9♠'
  at (260,343): T♥' J♥ Q♥ K♥
  at (443,347): 2♥ 3♥ 4♥
  at (19,92): A♥ A♦ A♣'
  at (52,392): 4♠' 5♦' 6♣ 7♦'
  at (345,418): 9♠ T♦' J♣ Q♦' K♠' A♦' 2♠ 3♦ 4♣'
  at (52,272): 8♠' 8♣' 8♥
  at (52,542): 9♣'

puzzle 6line_push_push_push_splice_steal_steal_s104t2p1
  at (100,140): 2♥ 3♥ 4♥
  at (40,200): 7♠ 7♦ 7♣
  at (52,542): 2♣ 2♦' 2♠
  at (187,542): 9♣ 9♠ 9♥'
  at (217,332): 3♣ 4♦' 5♣' 6♦'
  at (192,467): 3♦ 4♣ 5♥ 6♠ 7♥ 8♠'
  at (292,227): Q♥' K♣' A♥' 2♣' 3♦'
  at (53,20): Q♠ K♠ A♠ 2♠' 3♠ 4♠' 5♠
  at (93,392): T♣' J♣ Q♣
  at (160,80): T♦ J♦ Q♦
  at (171,260): A♦ A♥ A♠'
  at (322,542): Q♠' K♦ A♣
  at (232,152): 8♥' 9♣' T♥' J♠ Q♦'
  at (52,272): 8♥

# --- The sweep-tail monster (added 2026-07-13) ---
# Not a 6-line puzzle: this is the worst-case board from the zig
# solver's 100k-board timing probe (board bits 0x7fcbffffdfefb, one
# deck, 45 cards) — solvable, zig-verified, but it took the rank sweep
# a full second: 7 cut matchings refuted at ~60k futile states each
# before the winning arrangement. Served last, as a human stretch
# puzzle; the Hint button's BFS will NOT crack this one. Rollbackable
# commit by design.
puzzle monster_sweep_tail_45c_7fcbffffdfefb
  at (40,80): A♥ 2♥ 4♥ 5♥ 6♥ 7♥ 8♥ T♥ J♥ Q♥ K♥
  at (40,200): A♦ 2♦ 3♦ 4♦ 6♦ 7♦ 8♦ 9♦ T♦ J♦ Q♦ K♦
  at (40,320): A♣ 2♣ 3♣ 4♣ 5♣ 6♣ 7♣ 8♣ 9♣ T♣ J♣ Q♣
  at (40,440): A♠ 4♠ 5♠ 6♠ 7♠ 8♠ 9♠ T♠ J♠ Q♠
