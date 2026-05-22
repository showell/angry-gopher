# Curated 5-line Lyn Rummy puzzles.
#
# Generated 2026-05-18 from agent self-play across seeds 1–30.
# Each board is a dirty state that the BFS solver resolves in exactly 5
# verb-level moves. Names encode the sorted verb-multiset + provenance
# (s<seed>t<turn>p<player>) so duplicates within a verb-shape are distinguishable.
#
# Format matches curated_4line_puzzles.dsl — `puzzle <name>` header +
# indented `at (left,top): cards` body. UI: views/puzzle.go consumes
# directly. Conformance: test/test_curated_puzzles.ts asserts plan_length
# === 5 (per-file constant).

puzzle 5line_peel_push_set_peel_steal_yank_s20t1p0
  at (160,80): T♦ J♦ Q♦ K♦
  at (40,200): 7♠ 7♦ 7♣
  at (52,392): 4♠' 5♦' 6♣'
  at (126,542): 2♠ 3♠ 4♠
  at (187,392): K♠ A♠ 2♠'
  at (111,320): 3♦ 4♣ 5♥ 6♠ 7♥ 8♠'
  at (187,467): A♣ 2♣ 3♣'
  at (59,140): A♥' 2♥ 3♥
  at (273,152): 2♥' 3♣ 4♥
  at (171,260): A♦ A♥ A♠'
  at (52,272): Q♦'

puzzle 5line_push_set_peel_shift_splice_split_out_s23t1p0
  at (130,260): A♣ A♦ A♥
  at (52,392): 3♥' 4♠' 5♦'
  at (201,80): J♦ Q♦ K♦
  at (108,140): 2♥ 3♥ 4♥
  at (62,20): K♠ A♠ 2♠
  at (52,467): 3♦ 3♣ 3♠
  at (179,407): Q♦' K♣ A♥' 2♣ 3♦' 4♣ 5♥ 6♠
  at (187,332): 7♥ 7♦ 7♣
  at (52,542): 6♥ 7♠ 8♦' 9♠ T♦ J♣' Q♥
  at (52,92): 2♥'

puzzle 5line_peel_peel_peel_push_split_out_s10t2p1
  at (236,136): 6♥ 6♦' 6♠
  at (141,212): A♥ 2♥ 3♥
  at (157,467): Q♠' K♥' A♣'
  at (62,20): K♠ A♠ 2♠ 3♠'
  at (318,212): A♦ 2♣ 3♦
  at (119,80): 9♦' T♦ J♦
  at (228,542): A♣ 2♦' 3♠ 4♥ 5♠
  at (93,362): J♦' Q♦' K♦
  at (273,362): 8♣ 9♣ T♣
  at (93,542): 7♦ 7♥ 7♣
  at (322,287): 8♦ 9♣' T♦' J♠ Q♦ K♣ A♦'
  at (149,287): 3♦' 4♣ 5♥
  at (292,437): 5♠' 6♠' 7♠ 8♠ 9♠
  at (52,92): 9♠'

puzzle 5line_peel_peel_push_steal_yank_s1t2p1
  at (40,200): 7♠ 7♦ 7♣
  at (19,542): K♠ K♥' K♦
  at (187,467): A♦ 2♠' 3♥
  at (193,320): 5♦' 6♠ 7♥ 8♠'
  at (269,92): A♥ 2♣ 3♦ 4♣ 5♥
  at (184,392): 3♣' 4♥' 5♠
  at (19,92): 6♦ 6♣' 6♠'
  at (348,167): T♠' J♠' Q♠ K♠' A♠ 2♠ 3♠
  at (52,317): 8♥' 9♠ T♦
  at (254,242): Q♦ K♦' A♦' 2♦ 3♦' 4♦
  at (231,542): Q♣' K♥ A♣ 2♥ 3♠' 4♥
  at (52,392): T♣ J♦ Q♣
  at (52,467): T♥

puzzle 5line_peel_push_push_steal_yank_s2t2p1
  at (40,200): 7♠ 7♦ 7♣
  at (130,260): A♣ A♦ A♥
  at (52,392): T♥ T♣' T♠
  at (52,467): 8♠' 8♦ 8♣
  at (187,467): 9♣' T♥' J♣
  at (187,542): Q♣ Q♥' Q♦'
  at (431,223): 7♥ 8♠ 9♥
  at (119,80): 9♦' T♦ J♦ Q♦ K♦'
  at (52,542): K♠ K♣' K♥'
  at (152,20): 2♠ 3♠ 4♠
  at (226,388): Q♣' K♦ A♠
  at (303,302): 3♦ 4♣ 5♥ 6♠ 7♦'
  at (322,467): 5♦ 5♠ 5♣
  at (141,140): 3♥ 4♥ 5♥'
  at (262,227): 2♣ 2♠' 2♥
  at (52,92): 7♠'

puzzle 5line_push_push_shift_steal_steal_s3t2p1
  at (130,260): A♣ A♦ A♥
  at (152,80): T♦ J♦ Q♦
  at (81,200): 7♦ 7♣ 7♥
  at (187,332): 5♠ 6♠ 7♠
  at (149,542): 2♣ 3♦ 4♣ 5♥ 6♠'
  at (232,152): 2♣' 3♦' 4♠'
  at (262,227): 8♣ 9♥ T♠'
  at (322,302): 2♠' 3♥' 4♣' 5♦ 6♣'
  at (52,407): K♠ K♥ K♦ K♣
  at (386,403): 8♥' 9♣ T♥
  at (352,482): 3♠ 4♥' 5♣' 6♥ 7♣' 8♦'
  at (70,20): K♠' A♠ 2♠ 3♠'
  at (217,407): 2♥ 3♥ 4♥ 5♥'
  at (52,92): T♥'

puzzle 5line_peel_peel_peel_yank_yank_s6t2p1
  at (40,200): 7♠ 7♦ 7♣
  at (164,227): J♥ Q♠ K♥'
  at (187,407): Q♣' K♦ A♣
  at (103,20): A♠ 2♠ 3♠ 4♠
  at (11,302): T♥ J♣' Q♦' K♠ A♥
  at (399,167): 8♦' 9♦' T♦ J♦ Q♦ K♦' A♦'
  at (217,92): 3♠' 4♥ 5♠' 6♥' 7♣' 8♥
  at (51,140): A♥' 2♥ 3♥
  at (52,377): 4♠' 4♣ 4♥'
  at (333,482): 6♦' 7♦' 8♦
  at (183,542): 5♥ 6♠ 7♥
  at (202,302): A♦ 2♣ 3♦ 4♣' 5♦' 6♣
  at (52,452): 3♣

puzzle 5line_peel_push_push_steal_steal_s24t6p1
  at (130,260): A♣ A♦ A♥
  at (193,80): J♦ Q♦ K♦
  at (262,227): A♠' A♣' A♥'
  at (52,92): T♦ T♠' T♥
  at (52,167): 7♦ 7♣ 7♥
  at (255,298): 6♥ 6♦' 6♠
  at (322,377): 5♥ 5♠ 5♦
  at (52,332): 3♦ 3♠ 3♥
  at (52,407): 2♥ 3♥' 4♥
  at (604,92): 4♦' 5♣ 6♦
  at (184,482): 2♣' 3♣' 4♣'
  at (179,152): K♠ A♦' 2♣
  at (187,377): 2♠ 3♦' 4♣
  at (380,88): J♥ Q♠' K♥' A♠ 2♥'
  at (363,452): 8♠' 9♥' T♣' J♥'
  at (93,542): 7♠ 8♠ 9♠
  at (322,527): 6♠' 7♥' 8♣'
  at (52,242): J♣

puzzle 5line_peel_push_steal_steal_yank_s27t5p0
  at (130,260): A♣ A♦ A♥
  at (52,392): 8♣' 8♦ 8♥
  at (93,467): A♥' 2♥ 3♥ 4♥ 5♥ 6♥
  at (263,76): K♦ K♣' K♥
  at (141,542): 3♦' 4♠ 5♦
  at (0,312): 2♠' 2♥' 2♣
  at (277,152): 7♦ 7♣ 7♠'
  at (313,538): 5♥' 6♥' 7♥
  at (29,20): Q♠' K♠ A♠
  at (322,377): 2♠ 3♦ 4♣
  at (262,227): 3♠ 4♦ 5♣ 6♦
  at (322,452): Q♠ Q♥' Q♦' Q♣'
  at (113,152): 5♠ 6♠ 7♠ 8♠
  at (344,302): J♦ Q♦ K♦'
  at (44,92): 9♥' 9♦ 9♠
  at (19,542): 9♣ T♦ J♣'
  at (52,167): 4♣'

puzzle 5line_peel_peel_set_peel_steal_yank_s30t3p0
  at (100,140): 2♥ 3♥ 4♥
  at (40,200): 7♠ 7♦ 7♣
  at (19,332): K♠ K♥ K♦
  at (187,407): 5♥ 5♠ 5♦'
  at (171,260): A♦ A♥ A♠
  at (322,407): 9♠ 9♥' 9♣'
  at (147,478): A♦' 2♣ 3♦
  at (491,478): A♠' 2♠' 3♠
  at (605,302): K♦' A♣ 2♥'
  at (19,482): Q♥ Q♣ Q♦'
  at (157,332): 8♦' 9♦' T♦
  at (323,298): 5♦ 6♠ 7♥ 8♣' 9♥ T♠' J♦
  at (277,482): 4♣ 4♠ 4♦' 4♥'
  at (483,227): 3♣' 4♣' 5♣ 6♣
  at (281,152): J♣ Q♦ K♣' A♥'
  at (52,407): 2♣' 2♦' 2♠
  at (307,227): Q♥'

puzzle 5line_peel_pull_push_steal_yank_s5t9p0
  at (52,272): 3♦ 3♣ 3♥'
  at (232,152): 8♦' 8♥' 8♣
  at (277,497): K♥ K♣' K♦
  at (32,200): 7♠ 7♦ 7♣
  at (367,92): 4♥' 4♦' 4♣
  at (142,347): A♦ A♠' A♥
  at (502,92): 2♦' 2♥ 2♠'
  at (449,302): 5♦' 6♣' 7♥'
  at (396,422): 3♥ 4♥ 5♥ 6♥'
  at (322,227): 6♠ 7♠' 8♠
  at (193,418): 8♥ 9♠ T♥
  at (543,167): 6♣ 7♥ 8♣' 9♥ T♣
  at (412,497): Q♠' Q♥ Q♦
  at (86,20): K♠ A♠ 2♠ 3♠
  at (547,497): 9♦ T♦ J♦ Q♦' K♦' A♦' 2♦
  at (93,92): 5♦ 6♦ 7♦'
  at (65,538): K♣ A♣ 2♣
  at (19,347): 3♣' 4♦ 5♣
  at (52,422): T♥'
