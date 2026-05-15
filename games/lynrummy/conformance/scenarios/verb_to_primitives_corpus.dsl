# verb_to_primitives_corpus — corpus of verb→primitive scenarios.
#
# Auto-converted from the now-retired primitives_fixtures.json on
# 2026-05-03. Each scenario was a BFS plan step in one of 25 mined
# puzzles. Together they cover ~250 primitives across the verb
# pipeline.
#
# The hand-authored sibling `verb_to_primitives.dsl` covers each
# verb category with explicit edge cases. This corpus file is the
# bulk regression contract.
#
# Card label convention: `4♦'` = deck-1 4♦ (mirrors the existing
# replay_walkthroughs.dsl). T♠ runner accepts `'` natively (legacy `:1` also tolerated) at
# the parse boundary.
#
# Coordinate convention: `at (top, left)` per established DSL shape.

scenario mined_001_4♠_4♣p1_step_01
  desc: mined_001_4♠_4♣p1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): 2♥ 3♥ 4♥
    at (52,107): 7♠ 7♦ 7♣
    at (52,182): A♣ A♦ A♥
    at (52,257): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,332): 2♦' 3♠' 4♦'
    at (52,407): A♠ 2♠ 3♠
    at (52,482): K♦' K♥' K♠
    at (187,92): J♦ Q♦ K♦
    at (187,167): T♠ T♣' T♦
    at (187,332): 4♠ 4♣'
  verb: steal
  source: 2♦' 3♠' 4♦'
  ext_card: 4♦'
  target_before: 4♠ 4♣'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [2♦' 3♠' 4♦'] at (52,332) @2
      - merge_stack [4♦'] at (122,328) -> [4♠ 4♣'] at (187,332) /right
scenario mined_001_4♠_4♣p1_step_02
  desc: mined_001_4♠_4♣p1 step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): 2♥ 3♥ 4♥
    at (52,107): 7♠ 7♦ 7♣
    at (52,182): A♣ A♦ A♥
    at (52,257): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,407): A♠ 2♠ 3♠
    at (52,482): K♦' K♥' K♠
    at (187,92): J♦ Q♦ K♦
    at (187,167): T♠ T♣' T♦
    at (44,332): 2♦' 3♠'
    at (187,332): 4♠ 4♣' 4♦'
  verb: steal
  source: A♣ A♦ A♥
  ext_card: A♣
  target_before: 2♦' 3♠'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [A♣ A♦ A♥] at (52,182) @0
      - move_stack [A♦ A♥] at (93,182) -> (187,407)
      - split [A♦ A♥] at (187,407) @0
      - merge_stack [A♣] at (50,178) -> [2♦' 3♠'] at (44,332) /left
scenario mined_001_4♠_4♣p1_step_03
  desc: mined_001_4♠_4♣p1 step 3 (push).
  op: verb_to_primitives
  board:
    at (26,26): 2♥ 3♥ 4♥
    at (52,107): 7♠ 7♦ 7♣
    at (52,257): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,407): A♠ 2♠ 3♠
    at (52,482): K♦' K♥' K♠
    at (187,92): J♦ Q♦ K♦
    at (187,167): T♠ T♣' T♦
    at (187,332): 4♠ 4♣' 4♦'
    at (185,403): A♦
    at (228,407): A♥
    at (11,332): A♣ 2♦' 3♠'
  verb: push
  trouble_before: A♦
  target_before: 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  side: left
  expect:
    primitives:
      - merge_stack [A♦] at (185,403) -> [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] at (52,257) /left
scenario mined_001_4♠_4♣p1_step_04
  desc: mined_001_4♠_4♣p1 step 4 (push).
  op: verb_to_primitives
  board:
    at (26,26): 2♥ 3♥ 4♥
    at (52,107): 7♠ 7♦ 7♣
    at (52,407): A♠ 2♠ 3♠
    at (52,482): K♦' K♥' K♠
    at (187,92): J♦ Q♦ K♦
    at (187,167): T♠ T♣' T♦
    at (187,332): 4♠ 4♣' 4♦'
    at (228,407): A♥
    at (11,332): A♣ 2♦' 3♠'
    at (19,257): A♦ 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  verb: push
  trouble_before: A♥
  target_before: 2♥ 3♥ 4♥
  side: left
  expect:
    primitives:
      - move_stack [2♥ 3♥ 4♥] at (26,26) -> (220,482)
      - merge_stack [A♥] at (228,407) -> [2♥ 3♥ 4♥] at (220,482) /left
scenario mined_002_Q♦p1_step_01
  desc: mined_002_Q♦p1 step 1 (shift).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): A♠ 2♠ 3♠
    at (52,182): K♦' K♥' K♠
    at (52,257): J♦ Q♦ K♦
    at (52,332): T♠ T♣' T♦
    at (52,407): 4♠ 4♣' 4♦'
    at (52,482): A♣ 2♦' 3♠'
    at (187,92): A♥ 2♥ 3♥ 4♥
    at (187,167): A♦ 2♣ 3♦ 4♣
    at (187,242): 6♠ 7♥ 8♠
    at (187,317): 5♣ 5♦ 5♥
    at (187,392): Q♦'
  verb: shift
  source: J♦ Q♦ K♦
  donor: A♦ 2♣ 3♦ 4♣
  stolen: J♦
  p_card: A♦
  which_end: left
  target_before: Q♦'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [A♦ 2♣ 3♦ 4♣] at (187,167) @0
      - move_stack [J♦ Q♦ K♦] at (52,257) -> (187,467)
      - merge_stack [A♦] at (185,163) -> [J♦ Q♦ K♦] at (187,467) /right
      - split [J♦ Q♦ K♦ A♦] at (187,467) @0
      - move_stack [Q♦'] at (187,392) -> (85,257)
      - merge_stack [J♦] at (185,463) -> [Q♦'] at (85,257) /left
scenario mined_002_Q♦p1_step_02
  desc: mined_002_Q♦p1 step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): A♠ 2♠ 3♠
    at (52,182): K♦' K♥' K♠
    at (52,332): T♠ T♣' T♦
    at (52,407): 4♠ 4♣' 4♦'
    at (52,482): A♣ 2♦' 3♠'
    at (187,92): A♥ 2♥ 3♥ 4♥
    at (187,242): 6♠ 7♥ 8♠
    at (187,317): 5♣ 5♦ 5♥
    at (228,167): 2♣ 3♦ 4♣
    at (228,467): Q♦ K♦ A♦
    at (52,257): J♦ Q♦'
  verb: steal
  source: K♦' K♥' K♠
  ext_card: K♦'
  target_before: J♦ Q♦'
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [K♦' K♥' K♠] at (52,182) @0
      - move_stack [K♥' K♠] at (93,182) -> (187,392)
      - split [K♥' K♠] at (187,392) @0
      - merge_stack [K♦'] at (50,178) -> [J♦ Q♦'] at (52,257) /right
scenario mined_002_Q♦p1_step_03
  desc: mined_002_Q♦p1 step 3 (push).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): A♠ 2♠ 3♠
    at (52,332): T♠ T♣' T♦
    at (52,407): 4♠ 4♣' 4♦'
    at (52,482): A♣ 2♦' 3♠'
    at (187,92): A♥ 2♥ 3♥ 4♥
    at (187,242): 6♠ 7♥ 8♠
    at (187,317): 5♣ 5♦ 5♥
    at (228,167): 2♣ 3♦ 4♣
    at (228,467): Q♦ K♦ A♦
    at (185,388): K♥'
    at (228,392): K♠
    at (52,257): J♦ Q♦' K♦'
  verb: push
  trouble_before: K♥'
  target_before: A♣ 2♦' 3♠'
  side: left
  expect:
    primitives:
      - merge_stack [K♥'] at (185,388) -> [A♣ 2♦' 3♠'] at (52,482) /left
scenario mined_002_Q♦p1_step_04
  desc: mined_002_Q♦p1 step 4 (push).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): A♠ 2♠ 3♠
    at (52,332): T♠ T♣' T♦
    at (52,407): 4♠ 4♣' 4♦'
    at (187,92): A♥ 2♥ 3♥ 4♥
    at (187,242): 6♠ 7♥ 8♠
    at (187,317): 5♣ 5♦ 5♥
    at (228,167): 2♣ 3♦ 4♣
    at (228,467): Q♦ K♦ A♦
    at (228,392): K♠
    at (52,257): J♦ Q♦' K♦'
    at (19,482): K♥' A♣ 2♦' 3♠'
  verb: push
  trouble_before: K♠
  target_before: A♠ 2♠ 3♠
  side: left
  expect:
    primitives:
      - merge_stack [K♠] at (228,392) -> [A♠ 2♠ 3♠] at (52,107) /left
scenario mined_003_6♦_step_01
  desc: mined_003_6♦ step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): 2♥ 3♥ 4♥
    at (52,107): 7♠ 7♦ 7♣
    at (52,182): A♣ A♦ A♥
    at (52,257): 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,332): 2♦' 2♥' 2♣
    at (52,407): J♦ Q♦ K♦
    at (52,482): 8♦' 9♣ T♦
    at (187,92): 7♥' 8♠ 9♥'
    at (187,167): Q♠' Q♣' Q♥
    at (187,332): A♠ 2♠ 3♠
    at (187,407): K♦' K♣' K♠
    at (187,482): 6♦
  verb: steal
  source: 7♠ 7♦ 7♣
  ext_card: 7♣
  target_before: 6♦
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [7♠ 7♦ 7♣] at (52,107) @2
      - move_stack [7♠ 7♦] at (44,107) -> (247,242)
      - split [7♠ 7♦] at (247,242) @0
      - merge_stack [7♣] at (122,103) -> [6♦] at (187,482) /right
scenario mined_003_6♦_step_02
  desc: mined_003_6♦ step 2 (push).
  op: verb_to_primitives
  board:
    at (26,26): 2♥ 3♥ 4♥
    at (52,182): A♣ A♦ A♥
    at (52,257): 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,332): 2♦' 2♥' 2♣
    at (52,407): J♦ Q♦ K♦
    at (52,482): 8♦' 9♣ T♦
    at (187,92): 7♥' 8♠ 9♥'
    at (187,167): Q♠' Q♣' Q♥
    at (187,332): A♠ 2♠ 3♠
    at (187,407): K♦' K♣' K♠
    at (245,238): 7♠
    at (288,242): 7♦
    at (187,482): 6♦ 7♣
  verb: push
  trouble_before: 6♦ 7♣
  target_before: 8♦' 9♣ T♦
  side: left
  expect:
    primitives:
      - move_stack [8♦' 9♣ T♦] at (52,482) -> (358,482)
      - merge_stack [6♦ 7♣] at (187,482) -> [8♦' 9♣ T♦] at (358,482) /left
scenario mined_003_6♦_step_03
  desc: mined_003_6♦ step 3 (free_pull).
  op: verb_to_primitives
  board:
    at (26,26): 2♥ 3♥ 4♥
    at (52,182): A♣ A♦ A♥
    at (52,257): 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,332): 2♦' 2♥' 2♣
    at (52,407): J♦ Q♦ K♦
    at (187,92): 7♥' 8♠ 9♥'
    at (187,167): Q♠' Q♣' Q♥
    at (187,332): A♠ 2♠ 3♠
    at (187,407): K♦' K♣' K♠
    at (245,238): 7♠
    at (288,242): 7♦
    at (52,482): 6♦ 7♣ 8♦' 9♣ T♦
  verb: free_pull
  loose: 7♦
  target_before: 7♠
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - merge_stack [7♦] at (288,242) -> [7♠] at (245,238) /right
scenario mined_003_6♦_step_04
  desc: mined_003_6♦ step 4 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): 2♥ 3♥ 4♥
    at (52,182): A♣ A♦ A♥
    at (52,257): 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,332): 2♦' 2♥' 2♣
    at (52,407): J♦ Q♦ K♦
    at (187,92): 7♥' 8♠ 9♥'
    at (187,167): Q♠' Q♣' Q♥
    at (187,332): A♠ 2♠ 3♠
    at (187,407): K♦' K♣' K♠
    at (52,482): 6♦ 7♣ 8♦' 9♣ T♦
    at (245,238): 7♠ 7♦
  verb: peel
  source: 3♦ 4♣ 5♥ 6♠ 7♥
  ext_card: 7♥
  target_before: 7♠ 7♦
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [3♦ 4♣ 5♥ 6♠ 7♥] at (52,257) @4
      - merge_stack [7♥] at (188,253) -> [7♠ 7♦] at (245,238) /right
scenario mined_004_5♣_6♦p1_step_01
  desc: mined_004_5♣_6♦p1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 4♠' 5♦' 6♣
    at (187,182): 5♣ 6♦'
  verb: steal
  source: 7♠ 7♦ 7♣
  ext_card: 7♣
  target_before: 5♣ 6♦'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [7♠ 7♦ 7♣] at (52,257) @2
      - move_stack [7♠ 7♦] at (44,257) -> (187,257)
      - split [7♠ 7♦] at (187,257) @0
      - merge_stack [7♣] at (122,253) -> [5♣ 6♦'] at (187,182) /right
scenario mined_004_5♣_6♦p1_step_02
  desc: mined_004_5♣_6♦p1 step 2 (free_pull).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 4♠' 5♦' 6♣
    at (185,253): 7♠
    at (228,257): 7♦
    at (187,182): 5♣ 6♦' 7♣
  verb: free_pull
  loose: 7♦
  target_before: 7♠
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - merge_stack [7♦] at (228,257) -> [7♠] at (185,253) /right
scenario mined_004_5♣_6♦p1_step_03
  desc: mined_004_5♣_6♦p1 step 3 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 4♠' 5♦' 6♣
    at (187,182): 5♣ 6♦' 7♣
    at (185,253): 7♠ 7♦
  verb: peel
  source: 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  ext_card: 7♥
  target_before: 7♠ 7♦
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] at (52,407) @5
      - merge_stack [7♥] at (221,403) -> [7♠ 7♦] at (185,253) /right
scenario mined_005_2♥p1_step_01
  desc: mined_005_2♥p1 step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): A♣ A♦ A♥
    at (52,332): 4♠' 5♦' 6♣
    at (52,407): 5♣ 6♦' 7♣
    at (52,482): 2♣ 3♦ 4♣ 5♥ 6♠
    at (187,182): 7♠ 7♦ 7♥
    at (187,257): 2♥'
  verb: peel
  source: K♠ A♠ 2♠ 3♠
  ext_card: 3♠
  target_before: 2♥'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [K♠ A♠ 2♠ 3♠] at (26,26) @3
      - merge_stack [3♠] at (129,22) -> [2♥'] at (187,257) /right
scenario mined_005_2♥p1_step_02
  desc: mined_005_2♥p1 step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): A♣ A♦ A♥
    at (52,332): 4♠' 5♦' 6♣
    at (52,407): 5♣ 6♦' 7♣
    at (52,482): 2♣ 3♦ 4♣ 5♥ 6♠
    at (187,182): 7♠ 7♦ 7♥
    at (18,26): K♠ A♠ 2♠
    at (187,257): 2♥' 3♠
  verb: steal
  source: A♣ A♦ A♥
  ext_card: A♣
  target_before: 2♥' 3♠
  target_bucket: growing
  side: left
  expect:
    primitives:
      - split [A♣ A♦ A♥] at (52,257) @0
      - move_stack [A♦ A♥] at (93,257) -> (187,332)
      - split [A♦ A♥] at (187,332) @0
      - merge_stack [A♣] at (50,253) -> [2♥' 3♠] at (187,257) /left
scenario mined_005_2♥p1_step_03
  desc: mined_005_2♥p1 step 3 (push).
  op: verb_to_primitives
  board:
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,332): 4♠' 5♦' 6♣
    at (52,407): 5♣ 6♦' 7♣
    at (52,482): 2♣ 3♦ 4♣ 5♥ 6♠
    at (187,182): 7♠ 7♦ 7♥
    at (18,26): K♠ A♠ 2♠
    at (185,328): A♦
    at (228,332): A♥
    at (154,257): A♣ 2♥' 3♠
  verb: push
  trouble_before: A♦
  target_before: T♦ J♦ Q♦ K♦
  side: right
  expect:
    primitives:
      - merge_stack [A♦] at (185,328) -> [T♦ J♦ Q♦ K♦] at (52,107) /right
scenario mined_005_2♥p1_step_04
  desc: mined_005_2♥p1 step 4 (push).
  op: verb_to_primitives
  board:
    at (52,182): 2♥ 3♥ 4♥
    at (52,332): 4♠' 5♦' 6♣
    at (52,407): 5♣ 6♦' 7♣
    at (52,482): 2♣ 3♦ 4♣ 5♥ 6♠
    at (187,182): 7♠ 7♦ 7♥
    at (18,26): K♠ A♠ 2♠
    at (228,332): A♥
    at (154,257): A♣ 2♥' 3♠
    at (52,107): T♦ J♦ Q♦ K♦ A♦
  verb: push
  trouble_before: A♥
  target_before: 2♥ 3♥ 4♥
  side: left
  expect:
    primitives:
      - merge_stack [A♥] at (228,332) -> [2♥ 3♥ 4♥] at (52,182) /left
scenario mined_006_6♣p1_step_01
  desc: mined_006_6♣p1 step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): 4♠' 5♦' 6♣
    at (52,107): 5♣ 6♦' 7♣
    at (52,182): 7♠ 7♦ 7♥
    at (52,257): K♠ A♠ 2♠
    at (52,332): 3♦ 4♣ 5♥ 6♠
    at (52,407): K♠' A♦ 2♣
    at (52,482): T♦ J♦ Q♦
    at (187,92): A♥ 2♥ 3♥
    at (187,167): Q♣ K♦ A♣
    at (187,242): A♣' 2♥' 3♠ 4♥
    at (187,407): 6♣'
  verb: peel
  source: 3♦ 4♣ 5♥ 6♠
  ext_card: 6♠
  target_before: 6♣'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [3♦ 4♣ 5♥ 6♠] at (52,332) @3
      - merge_stack [6♠] at (155,328) -> [6♣'] at (187,407) /right
scenario mined_006_6♣p1_step_02
  desc: mined_006_6♣p1 step 2 (extract_absorb/split_out).
  op: verb_to_primitives
  board:
    at (26,26): 4♠' 5♦' 6♣
    at (52,107): 5♣ 6♦' 7♣
    at (52,182): 7♠ 7♦ 7♥
    at (52,257): K♠ A♠ 2♠
    at (52,407): K♠' A♦ 2♣
    at (52,482): T♦ J♦ Q♦
    at (187,92): A♥ 2♥ 3♥
    at (187,167): Q♣ K♦ A♣
    at (187,242): A♣' 2♥' 3♠ 4♥
    at (44,332): 3♦ 4♣ 5♥
    at (187,407): 6♣' 6♠
  verb: split_out
  source: 5♣ 6♦' 7♣
  ext_card: 6♦'
  target_before: 6♣' 6♠
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [5♣ 6♦' 7♣] at (52,107) @0
      - split [6♦' 7♣] at (93,107) @0
      - merge_stack [6♦'] at (91,103) -> [6♣' 6♠] at (187,407) /right
scenario mined_006_6♣p1_step_03
  desc: mined_006_6♣p1 step 3 (push).
  op: verb_to_primitives
  board:
    at (26,26): 4♠' 5♦' 6♣
    at (52,182): 7♠ 7♦ 7♥
    at (52,257): K♠ A♠ 2♠
    at (52,407): K♠' A♦ 2♣
    at (52,482): T♦ J♦ Q♦
    at (187,92): A♥ 2♥ 3♥
    at (187,167): Q♣ K♦ A♣
    at (187,242): A♣' 2♥' 3♠ 4♥
    at (44,332): 3♦ 4♣ 5♥
    at (50,103): 5♣
    at (213,332): 7♣
    at (187,407): 6♣' 6♠ 6♦'
  verb: push
  trouble_before: 5♣
  target_before: A♣' 2♥' 3♠ 4♥
  side: right
  expect:
    primitives:
      - merge_stack [5♣] at (50,103) -> [A♣' 2♥' 3♠ 4♥] at (187,242) /right
scenario mined_006_6♣p1_step_04
  desc: mined_006_6♣p1 step 4 (push).
  op: verb_to_primitives
  board:
    at (26,26): 4♠' 5♦' 6♣
    at (52,182): 7♠ 7♦ 7♥
    at (52,257): K♠ A♠ 2♠
    at (52,407): K♠' A♦ 2♣
    at (52,482): T♦ J♦ Q♦
    at (187,92): A♥ 2♥ 3♥
    at (187,167): Q♣ K♦ A♣
    at (44,332): 3♦ 4♣ 5♥
    at (213,332): 7♣
    at (187,407): 6♣' 6♠ 6♦'
    at (187,242): A♣' 2♥' 3♠ 4♥ 5♣
  verb: push
  trouble_before: 7♣
  target_before: 7♠ 7♦ 7♥
  side: right
  expect:
    primitives:
      - move_stack [7♠ 7♦ 7♥] at (52,182) -> (187,482)
      - merge_stack [7♣] at (213,332) -> [7♠ 7♦ 7♥] at (187,482) /right
scenario mined_007_5♣p1_6♣_step_01
  desc: mined_007_5♣p1_6♣ step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 9♥' T♣' J♥
    at (187,182): 5♣' 6♣
  verb: steal
  source: 7♠ 7♦ 7♣
  ext_card: 7♣
  target_before: 5♣' 6♣
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [7♠ 7♦ 7♣] at (52,257) @2
      - move_stack [7♠ 7♦] at (44,257) -> (187,257)
      - split [7♠ 7♦] at (187,257) @0
      - merge_stack [7♣] at (122,253) -> [5♣' 6♣] at (187,182) /right
scenario mined_007_5♣p1_6♣_step_02
  desc: mined_007_5♣p1_6♣ step 2 (free_pull).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 9♥' T♣' J♥
    at (185,253): 7♠
    at (228,257): 7♦
    at (187,182): 5♣' 6♣ 7♣
  verb: free_pull
  loose: 7♦
  target_before: 7♠
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - merge_stack [7♦] at (228,257) -> [7♠] at (185,253) /right
scenario mined_007_5♣p1_6♣_step_03
  desc: mined_007_5♣p1_6♣ step 3 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 9♥' T♣' J♥
    at (187,182): 5♣' 6♣ 7♣
    at (185,253): 7♠ 7♦
  verb: peel
  source: 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  ext_card: 7♥
  target_before: 7♠ 7♦
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] at (52,407) @5
      - merge_stack [7♥] at (221,403) -> [7♠ 7♦] at (185,253) /right
scenario mined_008_Q♥p1_step_01
  desc: mined_008_Q♥p1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): T♦ J♦ Q♦ K♦
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): A♣ A♦ A♥
    at (52,257): 9♥' T♣' J♥
    at (52,332): 5♣' 6♣ 7♣
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠
    at (52,482): 7♠ 7♦ 7♥
    at (187,92): A♠ 2♠ 3♠
    at (187,167): J♠' Q♠' K♠
    at (187,242): Q♥'
  verb: steal
  source: J♠' Q♠' K♠
  ext_card: J♠'
  target_before: Q♥'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [J♠' Q♠' K♠] at (187,167) @0
      - move_stack [Q♥'] at (187,242) -> (220,242)
      - merge_stack [J♠'] at (185,163) -> [Q♥'] at (220,242) /left
scenario mined_008_Q♥p1_step_02
  desc: mined_008_Q♥p1 step 2 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): T♦ J♦ Q♦ K♦
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): A♣ A♦ A♥
    at (52,257): 9♥' T♣' J♥
    at (52,332): 5♣' 6♣ 7♣
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠
    at (52,482): 7♠ 7♦ 7♥
    at (187,92): A♠ 2♠ 3♠
    at (228,167): Q♠' K♠
    at (187,242): J♠' Q♥'
  verb: peel
  source: T♦ J♦ Q♦ K♦
  ext_card: T♦
  target_before: J♠' Q♥'
  target_bucket: growing
  side: left
  expect:
    primitives:
      - split [T♦ J♦ Q♦ K♦] at (26,26) @0
      - move_stack [J♠' Q♥'] at (187,242) -> (220,242)
      - merge_stack [T♦] at (24,22) -> [J♠' Q♥'] at (220,242) /left
scenario mined_008_Q♥p1_step_03
  desc: mined_008_Q♥p1 step 3 (push).
  op: verb_to_primitives
  board:
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): A♣ A♦ A♥
    at (52,257): 9♥' T♣' J♥
    at (52,332): 5♣' 6♣ 7♣
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠
    at (52,482): 7♠ 7♦ 7♥
    at (187,92): A♠ 2♠ 3♠
    at (228,167): Q♠' K♠
    at (228,317): J♦ Q♦ K♦
    at (187,242): T♦ J♠' Q♥'
  verb: push
  trouble_before: Q♠' K♠
  target_before: A♠ 2♠ 3♠
  side: left
  expect:
    primitives:
      - move_stack [A♠ 2♠ 3♠] at (187,92) -> (253,92)
      - merge_stack [Q♠' K♠] at (228,167) -> [A♠ 2♠ 3♠] at (253,92) /left
scenario mined_009_J♣_step_01
  desc: mined_009_J♣ step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): A♣ A♦ A♥
    at (52,107): 9♥' T♣' J♥
    at (52,182): 5♣' 6♣ 7♣
    at (52,257): 2♣ 3♦ 4♣ 5♥ 6♠
    at (52,332): 7♠ 7♦ 7♥
    at (52,407): J♦ Q♦ K♦
    at (52,482): Q♠' K♠ A♠ 2♠ 3♠
    at (187,92): 9♠ T♦ J♠' Q♥'
    at (187,167): 2♥ 3♥ 4♥ 5♥'
    at (187,332): J♣
  verb: peel
  source: 9♠ T♦ J♠' Q♥'
  ext_card: Q♥'
  target_before: J♣
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [9♠ T♦ J♠' Q♥'] at (187,92) @3
      - merge_stack [Q♥'] at (290,88) -> [J♣] at (187,332) /right
scenario mined_009_J♣_step_02
  desc: mined_009_J♣ step 2 (extract_absorb/yank).
  op: verb_to_primitives
  board:
    at (26,26): A♣ A♦ A♥
    at (52,107): 9♥' T♣' J♥
    at (52,182): 5♣' 6♣ 7♣
    at (52,257): 2♣ 3♦ 4♣ 5♥ 6♠
    at (52,332): 7♠ 7♦ 7♥
    at (52,407): J♦ Q♦ K♦
    at (52,482): Q♠' K♠ A♠ 2♠ 3♠
    at (187,167): 2♥ 3♥ 4♥ 5♥'
    at (179,92): 9♠ T♦ J♠'
    at (187,332): J♣ Q♥'
  verb: yank
  source: Q♠' K♠ A♠ 2♠ 3♠
  ext_card: K♠
  target_before: J♣ Q♥'
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [Q♠' K♠ A♠ 2♠ 3♠] at (52,482) @0
      - split [K♠ A♠ 2♠ 3♠] at (93,482) @0
      - merge_stack [K♠] at (91,478) -> [J♣ Q♥'] at (187,332) /right
scenario mined_009_J♣_step_03
  desc: mined_009_J♣ step 3 (push).
  op: verb_to_primitives
  board:
    at (26,26): A♣ A♦ A♥
    at (52,107): 9♥' T♣' J♥
    at (52,182): 5♣' 6♣ 7♣
    at (52,257): 2♣ 3♦ 4♣ 5♥ 6♠
    at (52,332): 7♠ 7♦ 7♥
    at (52,407): J♦ Q♦ K♦
    at (187,167): 2♥ 3♥ 4♥ 5♥'
    at (179,92): 9♠ T♦ J♠'
    at (50,478): Q♠'
    at (153,482): A♠ 2♠ 3♠
    at (187,332): J♣ Q♥' K♠
  verb: push
  trouble_before: Q♠'
  target_before: 9♥' T♣' J♥
  side: right
  expect:
    primitives:
      - move_stack [9♥' T♣' J♥] at (52,107) -> (187,407)
      - merge_stack [Q♠'] at (50,478) -> [9♥' T♣' J♥] at (187,407) /right
scenario mined_010_3♥p1_step_01
  desc: mined_010_3♥p1 step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): T♦ J♦ Q♦ K♦
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,257): A♣ A♦ A♥
    at (52,332): 9♥' 9♣ 9♦
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠
    at (52,482): 5♦' 6♣' 7♥
    at (187,92): A♠ 2♠ 3♠
    at (187,167): K♣' K♦' K♠
    at (187,242): T♣' J♦' Q♠
    at (187,317): 3♥'
  verb: peel
  source: 2♣ 3♦ 4♣ 5♥ 6♠
  ext_card: 2♣
  target_before: 3♥'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [2♣ 3♦ 4♣ 5♥ 6♠] at (52,407) @0
      - move_stack [3♥'] at (187,317) -> (220,317)
      - merge_stack [2♣] at (50,403) -> [3♥'] at (220,317) /left
scenario mined_010_3♥p1_step_02
  desc: mined_010_3♥p1 step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): T♦ J♦ Q♦ K♦
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,257): A♣ A♦ A♥
    at (52,332): 9♥' 9♣ 9♦
    at (52,482): 5♦' 6♣' 7♥
    at (187,92): A♠ 2♠ 3♠
    at (187,167): K♣' K♦' K♠
    at (187,242): T♣' J♦' Q♠
    at (93,407): 3♦ 4♣ 5♥ 6♠
    at (187,317): 2♣ 3♥'
  verb: steal
  source: A♣ A♦ A♥
  ext_card: A♦
  target_before: 2♣ 3♥'
  target_bucket: growing
  side: left
  expect:
    primitives:
      - split [A♣ A♦ A♥] at (52,257) @0
      - move_stack [A♦ A♥] at (93,257) -> (187,482)
      - split [A♦ A♥] at (187,482) @0
      - move_stack [2♣ 3♥'] at (187,317) -> (220,317)
      - merge_stack [A♦] at (185,478) -> [2♣ 3♥'] at (220,317) /left
scenario mined_010_3♥p1_step_03
  desc: mined_010_3♥p1 step 3 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): T♦ J♦ Q♦ K♦
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,332): 9♥' 9♣ 9♦
    at (52,482): 5♦' 6♣' 7♥
    at (187,92): A♠ 2♠ 3♠
    at (187,167): K♣' K♦' K♠
    at (187,242): T♣' J♦' Q♠
    at (93,407): 3♦ 4♣ 5♥ 6♠
    at (50,253): A♣
    at (228,482): A♥
    at (187,317): A♦ 2♣ 3♥'
  verb: peel
  source: T♦ J♦ Q♦ K♦
  ext_card: K♦
  target_before: A♣
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [T♦ J♦ Q♦ K♦] at (26,26) @3
      - merge_stack [K♦] at (129,22) -> [A♣] at (50,253) /left
scenario mined_010_3♥p1_step_04
  desc: mined_010_3♥p1 step 4 (push).
  op: verb_to_primitives
  board:
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,332): 9♥' 9♣ 9♦
    at (52,482): 5♦' 6♣' 7♥
    at (187,92): A♠ 2♠ 3♠
    at (187,167): K♣' K♦' K♠
    at (187,242): T♣' J♦' Q♠
    at (93,407): 3♦ 4♣ 5♥ 6♠
    at (228,482): A♥
    at (187,317): A♦ 2♣ 3♥'
    at (18,26): T♦ J♦ Q♦
    at (17,253): K♦ A♣
  verb: push
  trouble_before: K♦ A♣
  target_before: T♣' J♦' Q♠
  side: right
  expect:
    primitives:
      - merge_stack [K♦ A♣] at (17,253) -> [T♣' J♦' Q♠] at (187,242) /right
scenario mined_010_3♥p1_step_05
  desc: mined_010_3♥p1 step 5 (push).
  op: verb_to_primitives
  board:
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,332): 9♥' 9♣ 9♦
    at (52,482): 5♦' 6♣' 7♥
    at (187,92): A♠ 2♠ 3♠
    at (187,167): K♣' K♦' K♠
    at (93,407): 3♦ 4♣ 5♥ 6♠
    at (228,482): A♥
    at (187,317): A♦ 2♣ 3♥'
    at (18,26): T♦ J♦ Q♦
    at (187,242): T♣' J♦' Q♠ K♦ A♣
  verb: push
  trouble_before: A♥
  target_before: 2♥ 3♥ 4♥
  side: left
  expect:
    primitives:
      - merge_stack [A♥] at (228,482) -> [2♥ 3♥ 4♥] at (52,107) /left
scenario mined_011_J♣_step_01
  desc: mined_011_J♣ step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): 9♥' 9♣ 9♦
    at (52,182): A♠ 2♠ 3♠
    at (52,257): K♣' K♦' K♠
    at (52,332): A♦ 2♣ 3♥'
    at (52,407): T♦ J♦ Q♦
    at (52,482): T♣' J♦' Q♠ K♦ A♣
    at (187,92): A♥ 2♥ 3♥ 4♥
    at (187,167): 4♣ 5♥ 6♠
    at (187,242): 6♣' 7♥ 8♠
    at (187,317): 3♦ 4♦ 5♦'
    at (187,392): J♣
  verb: peel
  source: T♣' J♦' Q♠ K♦ A♣
  ext_card: T♣'
  target_before: J♣
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [T♣' J♦' Q♠ K♦ A♣] at (52,482) @0
      - move_stack [J♣] at (187,392) -> (220,392)
      - merge_stack [T♣'] at (50,478) -> [J♣] at (220,392) /left
scenario mined_011_J♣_step_02
  desc: mined_011_J♣ step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): 9♥' 9♣ 9♦
    at (52,182): A♠ 2♠ 3♠
    at (52,257): K♣' K♦' K♠
    at (52,332): A♦ 2♣ 3♥'
    at (52,407): T♦ J♦ Q♦
    at (187,92): A♥ 2♥ 3♥ 4♥
    at (187,167): 4♣ 5♥ 6♠
    at (187,242): 6♣' 7♥ 8♠
    at (187,317): 3♦ 4♦ 5♦'
    at (93,482): J♦' Q♠ K♦ A♣
    at (187,392): T♣' J♣
  verb: steal
  source: 9♥' 9♣ 9♦
  ext_card: 9♣
  target_before: T♣' J♣
  target_bucket: growing
  side: left
  expect:
    primitives:
      - split [9♥' 9♣ 9♦] at (52,107) @0
      - move_stack [9♣ 9♦] at (93,107) -> (262,467)
      - split [9♣ 9♦] at (262,467) @0
      - move_stack [T♣' J♣] at (187,392) -> (220,392)
      - merge_stack [9♣] at (260,463) -> [T♣' J♣] at (220,392) /left
scenario mined_011_J♣_step_03
  desc: mined_011_J♣ step 3 (push).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,182): A♠ 2♠ 3♠
    at (52,257): K♣' K♦' K♠
    at (52,332): A♦ 2♣ 3♥'
    at (52,407): T♦ J♦ Q♦
    at (187,92): A♥ 2♥ 3♥ 4♥
    at (187,167): 4♣ 5♥ 6♠
    at (187,242): 6♣' 7♥ 8♠
    at (187,317): 3♦ 4♦ 5♦'
    at (93,482): J♦' Q♠ K♦ A♣
    at (50,103): 9♥'
    at (303,467): 9♦
    at (187,392): 9♣ T♣' J♣
  verb: push
  trouble_before: 9♥'
  target_before: 6♣' 7♥ 8♠
  side: right
  expect:
    primitives:
      - merge_stack [9♥'] at (50,103) -> [6♣' 7♥ 8♠] at (187,242) /right
scenario mined_011_J♣_step_04
  desc: mined_011_J♣ step 4 (push).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,182): A♠ 2♠ 3♠
    at (52,257): K♣' K♦' K♠
    at (52,332): A♦ 2♣ 3♥'
    at (52,407): T♦ J♦ Q♦
    at (187,92): A♥ 2♥ 3♥ 4♥
    at (187,167): 4♣ 5♥ 6♠
    at (187,317): 3♦ 4♦ 5♦'
    at (93,482): J♦' Q♠ K♦ A♣
    at (303,467): 9♦
    at (187,392): 9♣ T♣' J♣
    at (187,242): 6♣' 7♥ 8♠ 9♥'
  verb: push
  trouble_before: 9♦
  target_before: T♦ J♦ Q♦
  side: left
  expect:
    primitives:
      - merge_stack [9♦] at (303,467) -> [T♦ J♦ Q♦] at (52,407) /left
scenario mined_012_Q♣_K♣_step_01
  desc: mined_012_Q♣_K♣ step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 4♦' 5♠ 6♦'
    at (187,182): Q♣ K♣
  verb: steal
  source: A♣ A♦ A♥
  ext_card: A♣
  target_before: Q♣ K♣
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [A♣ A♦ A♥] at (52,332) @0
      - move_stack [A♦ A♥] at (93,332) -> (112,332)
      - split [A♦ A♥] at (112,332) @0
      - merge_stack [A♣] at (50,328) -> [Q♣ K♣] at (187,182) /right
scenario mined_012_Q♣_K♣_step_02
  desc: mined_012_Q♣_K♣ step 2 (push).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 4♦' 5♠ 6♦'
    at (110,328): A♦
    at (153,332): A♥
    at (187,182): Q♣ K♣ A♣
  verb: push
  trouble_before: A♦
  target_before: T♦ J♦ Q♦ K♦
  side: right
  expect:
    primitives:
      - merge_stack [A♦] at (110,328) -> [T♦ J♦ Q♦ K♦] at (52,107) /right
scenario mined_012_Q♣_K♣_step_03
  desc: mined_012_Q♣_K♣ step 3 (push).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 4♦' 5♠ 6♦'
    at (153,332): A♥
    at (187,182): Q♣ K♣ A♣
    at (52,107): T♦ J♦ Q♦ K♦ A♦
  verb: push
  trouble_before: A♥
  target_before: 2♥ 3♥ 4♥
  side: left
  expect:
    primitives:
      - merge_stack [A♥] at (153,332) -> [2♥ 3♥ 4♥] at (52,182) /left
scenario mined_013_A♥p1_step_01
  desc: mined_013_A♥p1 step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 7♠ 7♦ 7♣
    at (52,182): T♦ J♦ Q♦ K♦ A♦
    at (52,257): A♥ 2♥ 3♥
    at (52,332): 4♠' 4♦ 4♥
    at (52,407): 2♦ 3♣' 4♦' 5♠ 6♦'
    at (52,482): 3♦ 4♣ 5♥ 6♠ 7♥
    at (187,92): K♣ A♣ 2♣
    at (187,257): T♣' J♥ Q♣
    at (187,332): A♥'
  verb: peel
  source: K♠ A♠ 2♠ 3♠
  ext_card: K♠
  target_before: A♥'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [K♠ A♠ 2♠ 3♠] at (26,26) @0
      - move_stack [A♥'] at (187,332) -> (220,332)
      - merge_stack [K♠] at (24,22) -> [A♥'] at (220,332) /left
scenario mined_013_A♥p1_step_02
  desc: mined_013_A♥p1 step 2 (extract_absorb/split_out).
  op: verb_to_primitives
  board:
    at (52,107): 7♠ 7♦ 7♣
    at (52,182): T♦ J♦ Q♦ K♦ A♦
    at (52,257): A♥ 2♥ 3♥
    at (52,332): 4♠' 4♦ 4♥
    at (52,407): 2♦ 3♣' 4♦' 5♠ 6♦'
    at (52,482): 3♦ 4♣ 5♥ 6♠ 7♥
    at (187,92): K♣ A♣ 2♣
    at (187,257): T♣' J♥ Q♣
    at (288,167): A♠ 2♠ 3♠
    at (187,332): K♠ A♥'
  verb: split_out
  source: A♠ 2♠ 3♠
  ext_card: 2♠
  target_before: K♠ A♥'
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [A♠ 2♠ 3♠] at (288,167) @0
      - split [2♠ 3♠] at (329,167) @0
      - merge_stack [2♠] at (327,163) -> [K♠ A♥'] at (187,332) /right
scenario mined_013_A♥p1_step_03
  desc: mined_013_A♥p1 step 3 (push).
  op: verb_to_primitives
  board:
    at (52,107): 7♠ 7♦ 7♣
    at (52,182): T♦ J♦ Q♦ K♦ A♦
    at (52,257): A♥ 2♥ 3♥
    at (52,332): 4♠' 4♦ 4♥
    at (52,407): 2♦ 3♣' 4♦' 5♠ 6♦'
    at (52,482): 3♦ 4♣ 5♥ 6♠ 7♥
    at (187,92): K♣ A♣ 2♣
    at (187,257): T♣' J♥ Q♣
    at (286,163): A♠
    at (288,407): 3♠
    at (187,332): K♠ A♥' 2♠
  verb: push
  trouble_before: A♠
  target_before: 2♦ 3♣' 4♦' 5♠ 6♦'
  side: left
  expect:
    primitives:
      - merge_stack [A♠] at (286,163) -> [2♦ 3♣' 4♦' 5♠ 6♦'] at (52,407) /left
scenario mined_013_A♥p1_step_04
  desc: mined_013_A♥p1 step 4 (splice).
  op: verb_to_primitives
  board:
    at (52,107): 7♠ 7♦ 7♣
    at (52,182): T♦ J♦ Q♦ K♦ A♦
    at (52,257): A♥ 2♥ 3♥
    at (52,332): 4♠' 4♦ 4♥
    at (52,482): 3♦ 4♣ 5♥ 6♠ 7♥
    at (187,92): K♣ A♣ 2♣
    at (187,257): T♣' J♥ Q♣
    at (288,407): 3♠
    at (187,332): K♠ A♥' 2♠
    at (19,407): A♠ 2♦ 3♣' 4♦' 5♠ 6♦'
  verb: splice
  loose: 3♠
  source: A♠ 2♦ 3♣' 4♦' 5♠ 6♦'
  k: 2
  side: left
  expect:
    primitives:
      - move_stack [A♠ 2♦ 3♣' 4♦' 5♠ 6♦'] at (19,407) -> (52,407)
      - split [A♠ 2♦ 3♣' 4♦' 5♠ 6♦'] at (52,407) @1
      - move_stack [A♠ 2♦] at (50,403) -> (247,167)
      - merge_stack [3♠] at (288,407) -> [A♠ 2♦] at (247,167) /right
scenario mined_014_5♣_step_01
  desc: mined_014_5♣ step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): T♦ J♦ Q♦ K♦ A♦
    at (52,182): A♥ 2♥ 3♥
    at (52,257): 4♠' 4♦ 4♥
    at (52,332): 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,407): K♣ A♣ 2♣
    at (52,482): T♣' J♥ Q♣
    at (187,182): K♠ A♥' 2♠
    at (187,257): 3♣' 4♦' 5♠ 6♦'
    at (187,407): A♠ 2♦ 3♠
    at (187,482): 5♣
  verb: peel
  source: 3♣' 4♦' 5♠ 6♦'
  ext_card: 6♦'
  target_before: 5♣
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [3♣' 4♦' 5♠ 6♦'] at (187,257) @3
      - merge_stack [6♦'] at (290,253) -> [5♣] at (187,482) /right
scenario mined_014_5♣_step_02
  desc: mined_014_5♣ step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): T♦ J♦ Q♦ K♦ A♦
    at (52,182): A♥ 2♥ 3♥
    at (52,257): 4♠' 4♦ 4♥
    at (52,332): 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,407): K♣ A♣ 2♣
    at (52,482): T♣' J♥ Q♣
    at (187,182): K♠ A♥' 2♠
    at (187,407): A♠ 2♦ 3♠
    at (179,257): 3♣' 4♦' 5♠
    at (187,482): 5♣ 6♦'
  verb: steal
  source: 7♠ 7♦ 7♣
  ext_card: 7♣
  target_before: 5♣ 6♦'
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [7♠ 7♦ 7♣] at (26,26) @2
      - move_stack [7♠ 7♦] at (18,26) -> (247,92)
      - split [7♠ 7♦] at (247,92) @0
      - merge_stack [7♣] at (96,22) -> [5♣ 6♦'] at (187,482) /right
scenario mined_014_5♣_step_03
  desc: mined_014_5♣ step 3 (free_pull).
  op: verb_to_primitives
  board:
    at (52,107): T♦ J♦ Q♦ K♦ A♦
    at (52,182): A♥ 2♥ 3♥
    at (52,257): 4♠' 4♦ 4♥
    at (52,332): 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,407): K♣ A♣ 2♣
    at (52,482): T♣' J♥ Q♣
    at (187,182): K♠ A♥' 2♠
    at (187,407): A♠ 2♦ 3♠
    at (179,257): 3♣' 4♦' 5♠
    at (245,88): 7♠
    at (288,92): 7♦
    at (187,482): 5♣ 6♦' 7♣
  verb: free_pull
  loose: 7♦
  target_before: 7♠
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - merge_stack [7♦] at (288,92) -> [7♠] at (245,88) /right
scenario mined_014_5♣_step_04
  desc: mined_014_5♣ step 4 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (52,107): T♦ J♦ Q♦ K♦ A♦
    at (52,182): A♥ 2♥ 3♥
    at (52,257): 4♠' 4♦ 4♥
    at (52,332): 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,407): K♣ A♣ 2♣
    at (52,482): T♣' J♥ Q♣
    at (187,182): K♠ A♥' 2♠
    at (187,407): A♠ 2♦ 3♠
    at (179,257): 3♣' 4♦' 5♠
    at (187,482): 5♣ 6♦' 7♣
    at (245,88): 7♠ 7♦
  verb: peel
  source: 3♦ 4♣ 5♥ 6♠ 7♥
  ext_card: 7♥
  target_before: 7♠ 7♦
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [3♦ 4♣ 5♥ 6♠ 7♥] at (52,332) @4
      - merge_stack [7♥] at (188,328) -> [7♠ 7♦] at (245,88) /right
scenario mined_015_3♣p1_step_01
  desc: mined_015_3♣p1 step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,257): A♣ A♦ A♥
    at (52,332): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,407): 9♠ T♠' J♠
    at (52,482): J♦ Q♦ K♦
    at (187,92): 8♦ 9♦ T♦
    at (187,167): 2♥' 2♣' 2♦
    at (187,242): 3♣'
  verb: peel
  source: 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  ext_card: 2♣
  target_before: 3♣'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] at (52,332) @0
      - move_stack [3♣'] at (187,242) -> (220,242)
      - merge_stack [2♣] at (50,328) -> [3♣'] at (220,242) /left
scenario mined_015_3♣p1_step_02
  desc: mined_015_3♣p1 step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,257): A♣ A♦ A♥
    at (52,407): 9♠ T♠' J♠
    at (52,482): J♦ Q♦ K♦
    at (187,92): 8♦ 9♦ T♦
    at (187,167): 2♥' 2♣' 2♦
    at (93,332): 3♦ 4♣ 5♥ 6♠ 7♥
    at (187,242): 2♣ 3♣'
  verb: steal
  source: A♣ A♦ A♥
  ext_card: A♣
  target_before: 2♣ 3♣'
  target_bucket: growing
  side: left
  expect:
    primitives:
      - split [A♣ A♦ A♥] at (52,257) @0
      - move_stack [A♦ A♥] at (93,257) -> (187,407)
      - split [A♦ A♥] at (187,407) @0
      - merge_stack [A♣] at (50,253) -> [2♣ 3♣'] at (187,242) /left
scenario mined_015_3♣p1_step_03
  desc: mined_015_3♣p1 step 3 (push).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,407): 9♠ T♠' J♠
    at (52,482): J♦ Q♦ K♦
    at (187,92): 8♦ 9♦ T♦
    at (187,167): 2♥' 2♣' 2♦
    at (93,332): 3♦ 4♣ 5♥ 6♠ 7♥
    at (185,403): A♦
    at (228,407): A♥
    at (52,257): A♣ 2♣ 3♣'
  verb: push
  trouble_before: A♦
  target_before: J♦ Q♦ K♦
  side: right
  expect:
    primitives:
      - merge_stack [A♦] at (185,403) -> [J♦ Q♦ K♦] at (52,482) /right
scenario mined_015_3♣p1_step_04
  desc: mined_015_3♣p1 step 4 (push).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,407): 9♠ T♠' J♠
    at (187,92): 8♦ 9♦ T♦
    at (187,167): 2♥' 2♣' 2♦
    at (93,332): 3♦ 4♣ 5♥ 6♠ 7♥
    at (228,407): A♥
    at (52,257): A♣ 2♣ 3♣'
    at (52,482): J♦ Q♦ K♦ A♦
  verb: push
  trouble_before: A♥
  target_before: 2♥ 3♥ 4♥
  side: left
  expect:
    primitives:
      - merge_stack [A♥] at (228,407) -> [2♥ 3♥ 4♥] at (52,107) /left
scenario mined_016_T♣p1_step_01
  desc: mined_016_T♣p1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): 8♦ 9♦ T♦
    at (52,182): 2♥' 2♣' 2♦
    at (52,257): 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,332): A♣ 2♣ 3♣'
    at (52,407): A♥ 2♥ 3♥ 4♥
    at (52,482): A♠ 2♠ 3♠
    at (187,92): J♦ Q♦ K♦
    at (187,167): Q♥ K♠ A♦
    at (187,332): 9♠ T♠' J♠ Q♠
    at (187,482): T♣'
  verb: steal
  source: J♦ Q♦ K♦
  ext_card: J♦
  target_before: T♣'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [J♦ Q♦ K♦] at (187,92) @0
      - merge_stack [J♦] at (185,88) -> [T♣'] at (187,482) /right
scenario mined_016_T♣p1_step_02
  desc: mined_016_T♣p1 step 2 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): 8♦ 9♦ T♦
    at (52,182): 2♥' 2♣' 2♦
    at (52,257): 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,332): A♣ 2♣ 3♣'
    at (52,407): A♥ 2♥ 3♥ 4♥
    at (52,482): A♠ 2♠ 3♠
    at (187,167): Q♥ K♠ A♦
    at (187,332): 9♠ T♠' J♠ Q♠
    at (228,92): Q♦ K♦
    at (187,482): T♣' J♦
  verb: peel
  source: 9♠ T♠' J♠ Q♠
  ext_card: Q♠
  target_before: T♣' J♦
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [9♠ T♠' J♠ Q♠] at (187,332) @3
      - merge_stack [Q♠] at (290,328) -> [T♣' J♦] at (187,482) /right
scenario mined_016_T♣p1_step_03
  desc: mined_016_T♣p1 step 3 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): 8♦ 9♦ T♦
    at (52,182): 2♥' 2♣' 2♦
    at (52,257): 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,332): A♣ 2♣ 3♣'
    at (52,407): A♥ 2♥ 3♥ 4♥
    at (52,482): A♠ 2♠ 3♠
    at (187,167): Q♥ K♠ A♦
    at (228,92): Q♦ K♦
    at (179,332): 9♠ T♠' J♠
    at (187,482): T♣' J♦ Q♠
  verb: steal
  source: Q♥ K♠ A♦
  ext_card: A♦
  target_before: Q♦ K♦
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [Q♥ K♠ A♦] at (187,167) @2
      - merge_stack [A♦] at (257,163) -> [Q♦ K♦] at (228,92) /right
scenario mined_016_T♣p1_step_04
  desc: mined_016_T♣p1 step 4 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): 8♦ 9♦ T♦
    at (52,182): 2♥' 2♣' 2♦
    at (52,257): 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,332): A♣ 2♣ 3♣'
    at (52,407): A♥ 2♥ 3♥ 4♥
    at (52,482): A♠ 2♠ 3♠
    at (179,332): 9♠ T♠' J♠
    at (187,482): T♣' J♦ Q♠
    at (179,167): Q♥ K♠
    at (228,92): Q♦ K♦ A♦
  verb: peel
  source: A♥ 2♥ 3♥ 4♥
  ext_card: A♥
  target_before: Q♥ K♠
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [A♥ 2♥ 3♥ 4♥] at (52,407) @0
      - merge_stack [A♥] at (50,403) -> [Q♥ K♠] at (179,167) /right
scenario mined_017_5♦p1_6♦p1_step_01
  desc: mined_017_5♦p1_6♦p1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 5♦' 6♦'
  verb: steal
  source: 7♠ 7♦ 7♣
  ext_card: 7♦
  target_before: 5♦' 6♦'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [7♠ 7♦ 7♣] at (52,257) @0
      - move_stack [7♦ 7♣] at (93,257) -> (112,257)
      - split [7♦ 7♣] at (112,257) @0
      - merge_stack [7♦] at (110,253) -> [5♦' 6♦'] at (52,482) /right
scenario mined_017_5♦p1_6♦p1_step_02
  desc: mined_017_5♦p1_6♦p1 step 2 (free_pull).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (50,253): 7♠
    at (153,257): 7♣
    at (52,482): 5♦' 6♦' 7♦
  verb: free_pull
  loose: 7♣
  target_before: 7♠
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - merge_stack [7♣] at (153,257) -> [7♠] at (50,253) /right
scenario mined_017_5♦p1_6♦p1_step_03
  desc: mined_017_5♦p1_6♦p1 step 3 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 5♦' 6♦' 7♦
    at (50,253): 7♠ 7♣
  verb: peel
  source: 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  ext_card: 7♥
  target_before: 7♠ 7♣
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] at (52,407) @5
      - merge_stack [7♥] at (221,403) -> [7♠ 7♣] at (50,253) /right
scenario mined_018_2♠p1_3♥p1_step_01
  desc: mined_018_2♠p1_3♥p1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,257): A♣ A♦ A♥
    at (52,332): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,407): 7♠' 8♦' 9♣'
    at (52,482): 3♣' 4♥' 5♠'
    at (187,92): J♦ Q♦ K♦
    at (187,167): T♠ T♣ T♦
    at (187,242): 2♠' 3♥'
  verb: steal
  source: A♣ A♦ A♥
  ext_card: A♦
  target_before: 2♠' 3♥'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [A♣ A♦ A♥] at (52,257) @0
      - move_stack [A♦ A♥] at (93,257) -> (187,407)
      - split [A♦ A♥] at (187,407) @0
      - merge_stack [A♦] at (185,403) -> [2♠' 3♥'] at (187,242) /left
scenario mined_018_2♠p1_3♥p1_step_02
  desc: mined_018_2♠p1_3♥p1 step 2 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,332): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,407): 7♠' 8♦' 9♣'
    at (52,482): 3♣' 4♥' 5♠'
    at (187,92): J♦ Q♦ K♦
    at (187,167): T♠ T♣ T♦
    at (50,253): A♣
    at (228,407): A♥
    at (112,257): A♦ 2♠' 3♥'
  verb: peel
  source: 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  ext_card: 2♣
  target_before: A♣
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] at (52,332) @0
      - move_stack [A♣] at (50,253) -> (187,482)
      - merge_stack [2♣] at (50,328) -> [A♣] at (187,482) /right
scenario mined_018_2♠p1_3♥p1_step_03
  desc: mined_018_2♠p1_3♥p1 step 3 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,407): 7♠' 8♦' 9♣'
    at (52,482): 3♣' 4♥' 5♠'
    at (187,92): J♦ Q♦ K♦
    at (187,167): T♠ T♣ T♦
    at (228,407): A♥
    at (112,257): A♦ 2♠' 3♥'
    at (93,332): 3♦ 4♣ 5♥ 6♠ 7♥
    at (187,482): A♣ 2♣
  verb: steal
  source: 3♣' 4♥' 5♠'
  ext_card: 3♣'
  target_before: A♣ 2♣
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [3♣' 4♥' 5♠'] at (52,482) @0
      - merge_stack [3♣'] at (50,478) -> [A♣ 2♣] at (187,482) /right
scenario mined_018_2♠p1_3♥p1_step_04
  desc: mined_018_2♠p1_3♥p1 step 4 (push).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,407): 7♠' 8♦' 9♣'
    at (187,92): J♦ Q♦ K♦
    at (187,167): T♠ T♣ T♦
    at (228,407): A♥
    at (112,257): A♦ 2♠' 3♥'
    at (93,332): 3♦ 4♣ 5♥ 6♠ 7♥
    at (93,482): 4♥' 5♠'
    at (187,482): A♣ 2♣ 3♣'
  verb: push
  trouble_before: A♥
  target_before: 2♥ 3♥ 4♥
  side: left
  expect:
    primitives:
      - merge_stack [A♥] at (228,407) -> [2♥ 3♥ 4♥] at (52,107) /left
scenario mined_018_2♠p1_3♥p1_step_05
  desc: mined_018_2♠p1_3♥p1 step 5 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,182): 7♠ 7♦ 7♣
    at (52,407): 7♠' 8♦' 9♣'
    at (187,92): J♦ Q♦ K♦
    at (187,167): T♠ T♣ T♦
    at (112,257): A♦ 2♠' 3♥'
    at (93,332): 3♦ 4♣ 5♥ 6♠ 7♥
    at (93,482): 4♥' 5♠'
    at (187,482): A♣ 2♣ 3♣'
    at (19,107): A♥ 2♥ 3♥ 4♥
  verb: peel
  source: K♠ A♠ 2♠ 3♠
  ext_card: 3♠
  target_before: 4♥' 5♠'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [K♠ A♠ 2♠ 3♠] at (26,26) @3
      - merge_stack [3♠] at (129,22) -> [4♥' 5♠'] at (93,482) /left
scenario mined_019_2♦_step_01
  desc: mined_019_2♦ step 1 (extract_absorb/split_out).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): J♦ Q♦ K♦
    at (52,182): T♣' T♥ T♦
    at (52,257): 5♣' 6♦ 7♣'
    at (52,332): 6♠ 7♥ 8♣'
    at (52,407): A♣ 2♦' 3♠'
    at (52,482): A♠ 2♠ 3♠
    at (187,92): K♠ A♦ 2♣'
    at (187,167): 2♥ 3♥ 4♥ 5♥
    at (187,242): A♥ 2♣ 3♦ 4♣
    at (187,317): 2♦
  verb: split_out
  source: K♠ A♦ 2♣'
  ext_card: A♦
  target_before: 2♦
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [K♠ A♦ 2♣'] at (187,92) @0
      - split [A♦ 2♣'] at (228,92) @0
      - move_stack [2♦] at (187,317) -> (220,317)
      - merge_stack [A♦] at (226,88) -> [2♦] at (220,317) /left
scenario mined_019_2♦_step_02
  desc: mined_019_2♦ step 2 (push).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): J♦ Q♦ K♦
    at (52,182): T♣' T♥ T♦
    at (52,257): 5♣' 6♦ 7♣'
    at (52,332): 6♠ 7♥ 8♣'
    at (52,407): A♣ 2♦' 3♠'
    at (52,482): A♠ 2♠ 3♠
    at (187,167): 2♥ 3♥ 4♥ 5♥
    at (187,242): A♥ 2♣ 3♦ 4♣
    at (185,88): K♠
    at (228,392): 2♣'
    at (187,317): A♦ 2♦
  verb: push
  trouble_before: A♦ 2♦
  target_before: J♦ Q♦ K♦
  side: right
  expect:
    primitives:
      - move_stack [J♦ Q♦ K♦] at (52,107) -> (187,467)
      - merge_stack [A♦ 2♦] at (187,317) -> [J♦ Q♦ K♦] at (187,467) /right
scenario mined_019_2♦_step_03
  desc: mined_019_2♦ step 3 (push).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,182): T♣' T♥ T♦
    at (52,257): 5♣' 6♦ 7♣'
    at (52,332): 6♠ 7♥ 8♣'
    at (52,407): A♣ 2♦' 3♠'
    at (52,482): A♠ 2♠ 3♠
    at (187,167): 2♥ 3♥ 4♥ 5♥
    at (187,242): A♥ 2♣ 3♦ 4♣
    at (185,88): K♠
    at (228,392): 2♣'
    at (187,317): J♦ Q♦ K♦ A♦ 2♦
  verb: push
  trouble_before: K♠
  target_before: A♥ 2♣ 3♦ 4♣
  side: left
  expect:
    primitives:
      - move_stack [A♥ 2♣ 3♦ 4♣] at (187,242) -> (220,242)
      - merge_stack [K♠] at (185,88) -> [A♥ 2♣ 3♦ 4♣] at (220,242) /left
scenario mined_019_2♦_step_04
  desc: mined_019_2♦ step 4 (splice).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,182): T♣' T♥ T♦
    at (52,257): 5♣' 6♦ 7♣'
    at (52,332): 6♠ 7♥ 8♣'
    at (52,407): A♣ 2♦' 3♠'
    at (52,482): A♠ 2♠ 3♠
    at (187,167): 2♥ 3♥ 4♥ 5♥
    at (228,392): 2♣'
    at (187,317): J♦ Q♦ K♦ A♦ 2♦
    at (157,92): K♠ A♥ 2♣ 3♦ 4♣
  verb: splice
  loose: 2♣'
  source: K♠ A♥ 2♣ 3♦ 4♣
  k: 2
  side: left
  expect:
    primitives:
      - split [K♠ A♥ 2♣ 3♦ 4♣] at (157,92) @1
      - move_stack [K♠ A♥] at (155,88) -> (52,107)
      - merge_stack [2♣'] at (228,392) -> [K♠ A♥] at (52,107) /right
scenario mined_020_2♦p1_3♣p1_step_01
  desc: mined_020_2♦p1_3♣p1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,257): A♣ A♦ A♥
    at (52,332): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,407): J♦ Q♦ K♦
    at (52,482): T♣ T♥ T♦
    at (187,92): 9♦ 9♣' 9♠'
    at (187,167): 2♦' 3♣'
  verb: steal
  source: A♣ A♦ A♥
  ext_card: A♣
  target_before: 2♦' 3♣'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [A♣ A♦ A♥] at (52,257) @0
      - move_stack [A♦ A♥] at (93,257) -> (112,257)
      - split [A♦ A♥] at (112,257) @0
      - move_stack [2♦' 3♣'] at (187,167) -> (220,167)
      - merge_stack [A♣] at (50,253) -> [2♦' 3♣'] at (220,167) /left
scenario mined_020_2♦p1_3♣p1_step_02
  desc: mined_020_2♦p1_3♣p1 step 2 (push).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,332): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,407): J♦ Q♦ K♦
    at (52,482): T♣ T♥ T♦
    at (187,92): 9♦ 9♣' 9♠'
    at (110,253): A♦
    at (153,257): A♥
    at (187,167): A♣ 2♦' 3♣'
  verb: push
  trouble_before: A♦
  target_before: 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  side: left
  expect:
    primitives:
      - merge_stack [A♦] at (110,253) -> [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] at (52,332) /left
scenario mined_020_2♦p1_3♣p1_step_03
  desc: mined_020_2♦p1_3♣p1 step 3 (push).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 2♥ 3♥ 4♥
    at (52,182): 7♠ 7♦ 7♣
    at (52,407): J♦ Q♦ K♦
    at (52,482): T♣ T♥ T♦
    at (187,92): 9♦ 9♣' 9♠'
    at (153,257): A♥
    at (187,167): A♣ 2♦' 3♣'
    at (19,332): A♦ 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  verb: push
  trouble_before: A♥
  target_before: 2♥ 3♥ 4♥
  side: left
  expect:
    primitives:
      - merge_stack [A♥] at (153,257) -> [2♥ 3♥ 4♥] at (52,107) /left
scenario mined_021_8♦p1_step_01
  desc: mined_021_8♦p1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): J♥' J♦' J♣
    at (187,182): 4♥' 5♣' 6♦'
    at (187,257): 6♠' 7♥' 8♣' 9♥
    at (187,332): 8♦'
  verb: steal
  source: 7♠ 7♦ 7♣
  ext_card: 7♣
  target_before: 8♦'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [7♠ 7♦ 7♣] at (52,257) @2
      - move_stack [7♠ 7♦] at (44,257) -> (187,482)
      - split [7♠ 7♦] at (187,482) @0
      - move_stack [8♦'] at (187,332) -> (220,332)
      - merge_stack [7♣] at (122,253) -> [8♦'] at (220,332) /left
scenario mined_021_8♦p1_step_02
  desc: mined_021_8♦p1 step 2 (shift).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): J♥' J♦' J♣
    at (187,182): 4♥' 5♣' 6♦'
    at (187,257): 6♠' 7♥' 8♣' 9♥
    at (185,478): 7♠
    at (228,482): 7♦
    at (52,257): 7♣ 8♦'
  verb: shift
  source: 4♥' 5♣' 6♦'
  donor: K♠ A♠ 2♠ 3♠
  stolen: 6♦'
  p_card: 3♠
  which_end: right
  target_before: 7♣ 8♦'
  target_bucket: growing
  side: left
  expect:
    primitives:
      - split [K♠ A♠ 2♠ 3♠] at (26,26) @3
      - move_stack [4♥' 5♣' 6♦'] at (187,182) -> (220,182)
      - merge_stack [3♠] at (129,22) -> [4♥' 5♣' 6♦'] at (220,182) /left
      - split [3♠ 4♥' 5♣' 6♦'] at (187,182) @3
      - merge_stack [6♦'] at (290,178) -> [7♣ 8♦'] at (52,257) /left
scenario mined_021_8♦p1_step_03
  desc: mined_021_8♦p1 step 3 (free_pull).
  op: verb_to_primitives
  board:
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): J♥' J♦' J♣
    at (187,257): 6♠' 7♥' 8♣' 9♥
    at (185,478): 7♠
    at (228,482): 7♦
    at (18,26): K♠ A♠ 2♠
    at (179,182): 3♠ 4♥' 5♣'
    at (19,257): 6♦' 7♣ 8♦'
  verb: free_pull
  loose: 7♦
  target_before: 7♠
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - merge_stack [7♦] at (228,482) -> [7♠] at (185,478) /right
scenario mined_021_8♦p1_step_04
  desc: mined_021_8♦p1 step 4 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): J♥' J♦' J♣
    at (187,257): 6♠' 7♥' 8♣' 9♥
    at (18,26): K♠ A♠ 2♠
    at (179,182): 3♠ 4♥' 5♣'
    at (19,257): 6♦' 7♣ 8♦'
    at (185,478): 7♠ 7♦
  verb: peel
  source: 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  ext_card: 7♥
  target_before: 7♠ 7♦
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] at (52,407) @5
      - merge_stack [7♥] at (221,403) -> [7♠ 7♦] at (185,478) /right
scenario mined_022_A♥p1_A♦p1_step_01
  desc: mined_022_A♥p1_A♦p1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 9♣ T♥ J♠
    at (187,182): A♥' A♦'
  verb: steal
  source: A♣ A♦ A♥
  ext_card: A♣
  target_before: A♥' A♦'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [A♣ A♦ A♥] at (52,332) @0
      - move_stack [A♦ A♥] at (93,332) -> (112,332)
      - split [A♦ A♥] at (112,332) @0
      - merge_stack [A♣] at (50,328) -> [A♥' A♦'] at (187,182) /right
scenario mined_022_A♥p1_A♦p1_step_02
  desc: mined_022_A♥p1_A♦p1 step 2 (push).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 9♣ T♥ J♠
    at (110,328): A♦
    at (153,332): A♥
    at (187,182): A♥' A♦' A♣
  verb: push
  trouble_before: A♦
  target_before: T♦ J♦ Q♦ K♦
  side: right
  expect:
    primitives:
      - merge_stack [A♦] at (110,328) -> [T♦ J♦ Q♦ K♦] at (52,107) /right
scenario mined_022_A♥p1_A♦p1_step_03
  desc: mined_022_A♥p1_A♦p1 step 3 (push).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 9♣ T♥ J♠
    at (153,332): A♥
    at (187,182): A♥' A♦' A♣
    at (52,107): T♦ J♦ Q♦ K♦ A♦
  verb: push
  trouble_before: A♥
  target_before: 2♥ 3♥ 4♥
  side: left
  expect:
    primitives:
      - merge_stack [A♥] at (153,332) -> [2♥ 3♥ 4♥] at (52,182) /left
scenario mined_023_3♣_step_01
  desc: mined_023_3♣ step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 9♣ T♥ J♠
    at (52,182): A♥' A♦' A♣
    at (52,257): T♦ J♦ Q♦ K♦ A♦
    at (52,332): A♥ 2♥ 3♥ 4♥
    at (52,407): 7♠ 7♦ 7♣ 7♥'
    at (52,482): 4♣ 5♥ 6♠ 7♥
    at (187,92): 2♣ 3♦ 4♠'
    at (187,167): 3♣
  verb: peel
  source: 4♣ 5♥ 6♠ 7♥
  ext_card: 4♣
  target_before: 3♣
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [4♣ 5♥ 6♠ 7♥] at (52,482) @0
      - merge_stack [4♣] at (50,478) -> [3♣] at (187,167) /right
scenario mined_023_3♣_step_02
  desc: mined_023_3♣ step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 9♣ T♥ J♠
    at (52,182): A♥' A♦' A♣
    at (52,257): T♦ J♦ Q♦ K♦ A♦
    at (52,332): A♥ 2♥ 3♥ 4♥
    at (52,407): 7♠ 7♦ 7♣ 7♥'
    at (187,92): 2♣ 3♦ 4♠'
    at (93,482): 5♥ 6♠ 7♥
    at (187,167): 3♣ 4♣
  verb: steal
  source: 2♣ 3♦ 4♠'
  ext_card: 2♣
  target_before: 3♣ 4♣
  target_bucket: growing
  side: left
  expect:
    primitives:
      - split [2♣ 3♦ 4♠'] at (187,92) @0
      - move_stack [3♣ 4♣] at (187,167) -> (220,167)
      - merge_stack [2♣] at (185,88) -> [3♣ 4♣] at (220,167) /left
scenario mined_023_3♣_step_03
  desc: mined_023_3♣ step 3 (push).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): 9♣ T♥ J♠
    at (52,182): A♥' A♦' A♣
    at (52,257): T♦ J♦ Q♦ K♦ A♦
    at (52,332): A♥ 2♥ 3♥ 4♥
    at (52,407): 7♠ 7♦ 7♣ 7♥'
    at (93,482): 5♥ 6♠ 7♥
    at (228,92): 3♦ 4♠'
    at (187,167): 2♣ 3♣ 4♣
  verb: push
  trouble_before: 3♦ 4♠'
  target_before: 5♥ 6♠ 7♥
  side: left
  expect:
    primitives:
      - merge_stack [3♦ 4♠'] at (228,92) -> [5♥ 6♠ 7♥] at (93,482) /left
scenario mined_024_2♦_step_01
  desc: mined_024_2♦ step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): K♠ A♠ 2♠ 3♠
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 8♥ 9♠ T♥'
    at (187,182): 9♣ T♥ J♣
    at (187,257): 2♦
  verb: peel
  source: K♠ A♠ 2♠ 3♠
  ext_card: 3♠
  target_before: 2♦
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [K♠ A♠ 2♠ 3♠] at (26,26) @3
      - merge_stack [3♠] at (129,22) -> [2♦] at (187,257) /right
scenario mined_024_2♦_step_02
  desc: mined_024_2♦ step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,332): A♣ A♦ A♥
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 8♥ 9♠ T♥'
    at (187,182): 9♣ T♥ J♣
    at (18,26): K♠ A♠ 2♠
    at (187,257): 2♦ 3♠
  verb: steal
  source: A♣ A♦ A♥
  ext_card: A♣
  target_before: 2♦ 3♠
  target_bucket: growing
  side: left
  expect:
    primitives:
      - split [A♣ A♦ A♥] at (52,332) @0
      - move_stack [A♦ A♥] at (93,332) -> (112,332)
      - split [A♦ A♥] at (112,332) @0
      - move_stack [2♦ 3♠] at (187,257) -> (220,257)
      - merge_stack [A♣] at (50,328) -> [2♦ 3♠] at (220,257) /left
scenario mined_024_2♦_step_03
  desc: mined_024_2♦ step 3 (push).
  op: verb_to_primitives
  board:
    at (52,107): T♦ J♦ Q♦ K♦
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 8♥ 9♠ T♥'
    at (187,182): 9♣ T♥ J♣
    at (18,26): K♠ A♠ 2♠
    at (110,328): A♦
    at (153,332): A♥
    at (187,257): A♣ 2♦ 3♠
  verb: push
  trouble_before: A♦
  target_before: T♦ J♦ Q♦ K♦
  side: right
  expect:
    primitives:
      - merge_stack [A♦] at (110,328) -> [T♦ J♦ Q♦ K♦] at (52,107) /right
scenario mined_024_2♦_step_04
  desc: mined_024_2♦ step 4 (push).
  op: verb_to_primitives
  board:
    at (52,182): 2♥ 3♥ 4♥
    at (52,257): 7♠ 7♦ 7♣
    at (52,407): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,482): 8♥ 9♠ T♥'
    at (187,182): 9♣ T♥ J♣
    at (18,26): K♠ A♠ 2♠
    at (153,332): A♥
    at (187,257): A♣ 2♦ 3♠
    at (52,107): T♦ J♦ Q♦ K♦ A♦
  verb: push
  trouble_before: A♥
  target_before: 2♥ 3♥ 4♥
  side: left
  expect:
    primitives:
      - merge_stack [A♥] at (153,332) -> [2♥ 3♥ 4♥] at (52,182) /left
scenario mined_025_T♠p1_step_01
  desc: mined_025_T♠p1 step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,182): 8♥ 9♠ T♥'
    at (52,257): 9♣ T♥ J♣
    at (52,332): K♠ A♠ 2♠
    at (52,407): A♣ 2♦ 3♠
    at (52,482): T♦ J♦ Q♦ K♦ A♦
    at (187,182): A♥ 2♥ 3♥
    at (187,257): 4♦ 4♠' 4♥
    at (187,332): T♠'
  verb: peel
  source: T♦ J♦ Q♦ K♦ A♦
  ext_card: T♦
  target_before: T♠'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [T♦ J♦ Q♦ K♦ A♦] at (52,482) @0
      - merge_stack [T♦] at (50,478) -> [T♠'] at (187,332) /right
scenario mined_025_T♠p1_step_02
  desc: mined_025_T♠p1 step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,182): 8♥ 9♠ T♥'
    at (52,257): 9♣ T♥ J♣
    at (52,332): K♠ A♠ 2♠
    at (52,407): A♣ 2♦ 3♠
    at (187,182): A♥ 2♥ 3♥
    at (187,257): 4♦ 4♠' 4♥
    at (93,482): J♦ Q♦ K♦ A♦
    at (187,332): T♠' T♦
  verb: steal
  source: 8♥ 9♠ T♥'
  ext_card: T♥'
  target_before: T♠' T♦
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [8♥ 9♠ T♥'] at (52,182) @2
      - merge_stack [T♥'] at (122,178) -> [T♠' T♦] at (187,332) /right
scenario mined_025_T♠p1_step_03
  desc: mined_025_T♠p1 step 3 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26,26): 7♠ 7♦ 7♣
    at (52,107): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,257): 9♣ T♥ J♣
    at (52,332): K♠ A♠ 2♠
    at (52,407): A♣ 2♦ 3♠
    at (187,182): A♥ 2♥ 3♥
    at (187,257): 4♦ 4♠' 4♥
    at (93,482): J♦ Q♦ K♦ A♦
    at (44,182): 8♥ 9♠
    at (187,332): T♠' T♦ T♥'
  verb: steal
  source: 7♠ 7♦ 7♣
  ext_card: 7♣
  target_before: 8♥ 9♠
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [7♠ 7♦ 7♣] at (26,26) @2
      - move_stack [7♠ 7♦] at (18,26) -> (187,407)
      - split [7♠ 7♦] at (187,407) @0
      - merge_stack [7♣] at (96,22) -> [8♥ 9♠] at (44,182) /left
scenario mined_025_T♠p1_step_04
  desc: mined_025_T♠p1 step 4 (free_pull).
  op: verb_to_primitives
  board:
    at (52,107): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,257): 9♣ T♥ J♣
    at (52,332): K♠ A♠ 2♠
    at (52,407): A♣ 2♦ 3♠
    at (187,182): A♥ 2♥ 3♥
    at (187,257): 4♦ 4♠' 4♥
    at (93,482): J♦ Q♦ K♦ A♦
    at (187,332): T♠' T♦ T♥'
    at (185,403): 7♠
    at (228,407): 7♦
    at (11,182): 7♣ 8♥ 9♠
  verb: free_pull
  loose: 7♦
  target_before: 7♠
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - merge_stack [7♦] at (228,407) -> [7♠] at (185,403) /right
scenario mined_025_T♠p1_step_05
  desc: mined_025_T♠p1 step 5 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (52,107): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (52,257): 9♣ T♥ J♣
    at (52,332): K♠ A♠ 2♠
    at (52,407): A♣ 2♦ 3♠
    at (187,182): A♥ 2♥ 3♥
    at (187,257): 4♦ 4♠' 4♥
    at (93,482): J♦ Q♦ K♦ A♦
    at (187,332): T♠' T♦ T♥'
    at (11,182): 7♣ 8♥ 9♠
    at (185,403): 7♠ 7♦
  verb: peel
  source: 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  ext_card: 7♥
  target_before: 7♠ 7♦
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] at (52,107) @5
      - merge_stack [7♥] at (221,103) -> [7♠ 7♦] at (185,403) /right