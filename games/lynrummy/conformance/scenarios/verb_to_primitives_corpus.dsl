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
# Card label convention: `4D'` = deck-1 4D (mirrors the existing
# replay_walkthroughs.dsl). The TS runner converts `'` → `:1` at
# the parse boundary.
#
# Coordinate convention: `at (top, left)` per established DSL shape.

scenario mined_001_4S_4Cp1_step_01
  desc: mined_001_4S_4Cp1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): 2H 3H 4H
    at (107, 52): 7S 7D 7C
    at (182, 52): AC AD AH
    at (257, 52): 2C 3D 4C 5H 6S 7H
    at (332, 52): 2D' 3S' 4D'
    at (407, 52): AS 2S 3S
    at (482, 52): KD' KH' KS
    at (92, 187): JD QD KD
    at (167, 187): TS TC' TD
    at (332, 187): 4S 4C'
  verb: steal
  source: 2D' 3S' 4D'
  ext_card: 4D'
  target_before: 4S 4C'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [2D' 3S' 4D']@2
      - merge_stack [4D'] -> [4S 4C'] /right

scenario mined_001_4S_4Cp1_step_02
  desc: mined_001_4S_4Cp1 step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): 2H 3H 4H
    at (107, 52): 7S 7D 7C
    at (182, 52): AC AD AH
    at (257, 52): 2C 3D 4C 5H 6S 7H
    at (407, 52): AS 2S 3S
    at (482, 52): KD' KH' KS
    at (92, 187): JD QD KD
    at (167, 187): TS TC' TD
    at (332, 44): 2D' 3S'
    at (332, 187): 4S 4C' 4D'
  verb: steal
  source: AC AD AH
  ext_card: AC
  target_before: 2D' 3S'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [AC AD AH]@0
      - move_stack [AD AH] -> (407,187)
      - split [AD AH]@0
      - merge_stack [AC] -> [2D' 3S'] /left

scenario mined_001_4S_4Cp1_step_03
  desc: mined_001_4S_4Cp1 step 3 (push).
  op: verb_to_primitives
  board:
    at (26, 26): 2H 3H 4H
    at (107, 52): 7S 7D 7C
    at (257, 52): 2C 3D 4C 5H 6S 7H
    at (407, 52): AS 2S 3S
    at (482, 52): KD' KH' KS
    at (92, 187): JD QD KD
    at (167, 187): TS TC' TD
    at (332, 187): 4S 4C' 4D'
    at (403, 185): AD
    at (407, 228): AH
    at (332, 11): AC 2D' 3S'
  verb: push
  trouble_before: AD
  target_before: 2C 3D 4C 5H 6S 7H
  side: left
  expect:
    primitives:
      - merge_stack [AD] -> [2C 3D 4C 5H 6S 7H] /left

scenario mined_001_4S_4Cp1_step_04
  desc: mined_001_4S_4Cp1 step 4 (push).
  op: verb_to_primitives
  board:
    at (26, 26): 2H 3H 4H
    at (107, 52): 7S 7D 7C
    at (407, 52): AS 2S 3S
    at (482, 52): KD' KH' KS
    at (92, 187): JD QD KD
    at (167, 187): TS TC' TD
    at (332, 187): 4S 4C' 4D'
    at (407, 228): AH
    at (332, 11): AC 2D' 3S'
    at (257, 19): AD 2C 3D 4C 5H 6S 7H
  verb: push
  trouble_before: AH
  target_before: 2H 3H 4H
  side: left
  expect:
    primitives:
      - move_stack [2H 3H 4H] -> (407,220)
      - merge_stack [AH] -> [2H 3H 4H] /left

scenario mined_002_QDp1_step_01
  desc: mined_002_QDp1 step 1 (shift).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): AS 2S 3S
    at (182, 52): KD' KH' KS
    at (257, 52): JD QD KD
    at (332, 52): TS TC' TD
    at (407, 52): 4S 4C' 4D'
    at (482, 52): AC 2D' 3S'
    at (92, 187): AH 2H 3H 4H
    at (167, 187): AD 2C 3D 4C
    at (242, 187): 6S 7H 8S
    at (317, 187): 5C 5D 5H
    at (392, 187): QD'
  verb: shift
  source: JD QD KD
  donor: AD 2C 3D 4C
  stolen: JD
  p_card: AD
  which_end: left
  target_before: QD'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [AD 2C 3D 4C]@0
      - move_stack [JD QD KD] -> (467,187)
      - merge_stack [AD] -> [JD QD KD] /right
      - split [JD QD KD AD]@0
      - move_stack [QD'] -> (257,85)
      - merge_stack [JD] -> [QD'] /left

scenario mined_002_QDp1_step_02
  desc: mined_002_QDp1 step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): AS 2S 3S
    at (182, 52): KD' KH' KS
    at (332, 52): TS TC' TD
    at (407, 52): 4S 4C' 4D'
    at (482, 52): AC 2D' 3S'
    at (92, 187): AH 2H 3H 4H
    at (242, 187): 6S 7H 8S
    at (317, 187): 5C 5D 5H
    at (167, 228): 2C 3D 4C
    at (467, 228): QD KD AD
    at (257, 52): JD QD'
  verb: steal
  source: KD' KH' KS
  ext_card: KD'
  target_before: JD QD'
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [KD' KH' KS]@0
      - move_stack [KH' KS] -> (392,187)
      - split [KH' KS]@0
      - merge_stack [KD'] -> [JD QD'] /right

scenario mined_002_QDp1_step_03
  desc: mined_002_QDp1 step 3 (push).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): AS 2S 3S
    at (332, 52): TS TC' TD
    at (407, 52): 4S 4C' 4D'
    at (482, 52): AC 2D' 3S'
    at (92, 187): AH 2H 3H 4H
    at (242, 187): 6S 7H 8S
    at (317, 187): 5C 5D 5H
    at (167, 228): 2C 3D 4C
    at (467, 228): QD KD AD
    at (388, 185): KH'
    at (392, 228): KS
    at (257, 52): JD QD' KD'
  verb: push
  trouble_before: KH'
  target_before: AC 2D' 3S'
  side: left
  expect:
    primitives:
      - merge_stack [KH'] -> [AC 2D' 3S'] /left

scenario mined_002_QDp1_step_04
  desc: mined_002_QDp1 step 4 (push).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): AS 2S 3S
    at (332, 52): TS TC' TD
    at (407, 52): 4S 4C' 4D'
    at (92, 187): AH 2H 3H 4H
    at (242, 187): 6S 7H 8S
    at (317, 187): 5C 5D 5H
    at (167, 228): 2C 3D 4C
    at (467, 228): QD KD AD
    at (392, 228): KS
    at (257, 52): JD QD' KD'
    at (482, 19): KH' AC 2D' 3S'
  verb: push
  trouble_before: KS
  target_before: AS 2S 3S
  side: left
  expect:
    primitives:
      - merge_stack [KS] -> [AS 2S 3S] /left

scenario mined_003_6D_step_01
  desc: mined_003_6D step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): 2H 3H 4H
    at (107, 52): 7S 7D 7C
    at (182, 52): AC AD AH
    at (257, 52): 3D 4C 5H 6S 7H
    at (332, 52): 2D' 2H' 2C
    at (407, 52): JD QD KD
    at (482, 52): 8D' 9C TD
    at (92, 187): 7H' 8S 9H'
    at (167, 187): QS' QC' QH
    at (332, 187): AS 2S 3S
    at (407, 187): KD' KC' KS
    at (482, 187): 6D
  verb: steal
  source: 7S 7D 7C
  ext_card: 7C
  target_before: 6D
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [7S 7D 7C]@2
      - move_stack [7S 7D] -> (242,247)
      - split [7S 7D]@0
      - merge_stack [7C] -> [6D] /right

scenario mined_003_6D_step_02
  desc: mined_003_6D step 2 (push).
  op: verb_to_primitives
  board:
    at (26, 26): 2H 3H 4H
    at (182, 52): AC AD AH
    at (257, 52): 3D 4C 5H 6S 7H
    at (332, 52): 2D' 2H' 2C
    at (407, 52): JD QD KD
    at (482, 52): 8D' 9C TD
    at (92, 187): 7H' 8S 9H'
    at (167, 187): QS' QC' QH
    at (332, 187): AS 2S 3S
    at (407, 187): KD' KC' KS
    at (238, 245): 7S
    at (242, 288): 7D
    at (482, 187): 6D 7C
  verb: push
  trouble_before: 6D 7C
  target_before: 8D' 9C TD
  side: left
  expect:
    primitives:
      - move_stack [8D' 9C TD] -> (482,118)
      - merge_stack [6D 7C] -> [8D' 9C TD] /left

scenario mined_003_6D_step_03
  desc: mined_003_6D step 3 (free_pull).
  op: verb_to_primitives
  board:
    at (26, 26): 2H 3H 4H
    at (182, 52): AC AD AH
    at (257, 52): 3D 4C 5H 6S 7H
    at (332, 52): 2D' 2H' 2C
    at (407, 52): JD QD KD
    at (92, 187): 7H' 8S 9H'
    at (167, 187): QS' QC' QH
    at (332, 187): AS 2S 3S
    at (407, 187): KD' KC' KS
    at (238, 245): 7S
    at (242, 288): 7D
    at (482, 52): 6D 7C 8D' 9C TD
  verb: free_pull
  loose: 7D
  target_before: 7S
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - merge_stack [7D] -> [7S] /right

scenario mined_003_6D_step_04
  desc: mined_003_6D step 4 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): 2H 3H 4H
    at (182, 52): AC AD AH
    at (257, 52): 3D 4C 5H 6S 7H
    at (332, 52): 2D' 2H' 2C
    at (407, 52): JD QD KD
    at (92, 187): 7H' 8S 9H'
    at (167, 187): QS' QC' QH
    at (332, 187): AS 2S 3S
    at (407, 187): KD' KC' KS
    at (482, 52): 6D 7C 8D' 9C TD
    at (238, 245): 7S 7D
  verb: peel
  source: 3D 4C 5H 6S 7H
  ext_card: 7H
  target_before: 7S 7D
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [3D 4C 5H 6S 7H]@4
      - merge_stack [7H] -> [7S 7D] /right

scenario mined_004_5C_6Dp1_step_01
  desc: mined_004_5C_6Dp1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (257, 52): 7S 7D 7C
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 4S' 5D' 6C
    at (182, 187): 5C 6D'
  verb: steal
  source: 7S 7D 7C
  ext_card: 7C
  target_before: 5C 6D'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [7S 7D 7C]@2
      - move_stack [7S 7D] -> (257,187)
      - split [7S 7D]@0
      - merge_stack [7C] -> [5C 6D'] /right

scenario mined_004_5C_6Dp1_step_02
  desc: mined_004_5C_6Dp1 step 2 (free_pull).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 4S' 5D' 6C
    at (253, 185): 7S
    at (257, 228): 7D
    at (182, 187): 5C 6D' 7C
  verb: free_pull
  loose: 7D
  target_before: 7S
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - merge_stack [7D] -> [7S] /right

scenario mined_004_5C_6Dp1_step_03
  desc: mined_004_5C_6Dp1 step 3 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 4S' 5D' 6C
    at (182, 187): 5C 6D' 7C
    at (253, 185): 7S 7D
  verb: peel
  source: 2C 3D 4C 5H 6S 7H
  ext_card: 7H
  target_before: 7S 7D
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [2C 3D 4C 5H 6S 7H]@5
      - merge_stack [7H] -> [7S 7D] /right

scenario mined_005_2Hp1_step_01
  desc: mined_005_2Hp1 step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (257, 52): AC AD AH
    at (332, 52): 4S' 5D' 6C
    at (407, 52): 5C 6D' 7C
    at (482, 52): 2C 3D 4C 5H 6S
    at (182, 187): 7S 7D 7H
    at (257, 187): 2H'
  verb: peel
  source: KS AS 2S 3S
  ext_card: 3S
  target_before: 2H'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [KS AS 2S 3S]@3
      - merge_stack [3S] -> [2H'] /right

scenario mined_005_2Hp1_step_02
  desc: mined_005_2Hp1 step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (257, 52): AC AD AH
    at (332, 52): 4S' 5D' 6C
    at (407, 52): 5C 6D' 7C
    at (482, 52): 2C 3D 4C 5H 6S
    at (182, 187): 7S 7D 7H
    at (26, 18): KS AS 2S
    at (257, 187): 2H' 3S
  verb: steal
  source: AC AD AH
  ext_card: AC
  target_before: 2H' 3S
  target_bucket: growing
  side: left
  expect:
    primitives:
      - split [AC AD AH]@0
      - move_stack [AD AH] -> (332,187)
      - split [AD AH]@0
      - merge_stack [AC] -> [2H' 3S] /left

scenario mined_005_2Hp1_step_03
  desc: mined_005_2Hp1 step 3 (push).
  op: verb_to_primitives
  board:
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (332, 52): 4S' 5D' 6C
    at (407, 52): 5C 6D' 7C
    at (482, 52): 2C 3D 4C 5H 6S
    at (182, 187): 7S 7D 7H
    at (26, 18): KS AS 2S
    at (328, 185): AD
    at (332, 228): AH
    at (257, 154): AC 2H' 3S
  verb: push
  trouble_before: AD
  target_before: TD JD QD KD
  side: right
  expect:
    primitives:
      - merge_stack [AD] -> [TD JD QD KD] /right

scenario mined_005_2Hp1_step_04
  desc: mined_005_2Hp1 step 4 (push).
  op: verb_to_primitives
  board:
    at (182, 52): 2H 3H 4H
    at (332, 52): 4S' 5D' 6C
    at (407, 52): 5C 6D' 7C
    at (482, 52): 2C 3D 4C 5H 6S
    at (182, 187): 7S 7D 7H
    at (26, 18): KS AS 2S
    at (332, 228): AH
    at (257, 154): AC 2H' 3S
    at (107, 52): TD JD QD KD AD
  verb: push
  trouble_before: AH
  target_before: 2H 3H 4H
  side: left
  expect:
    primitives:
      - merge_stack [AH] -> [2H 3H 4H] /left

scenario mined_006_6Cp1_step_01
  desc: mined_006_6Cp1 step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): 4S' 5D' 6C
    at (107, 52): 5C 6D' 7C
    at (182, 52): 7S 7D 7H
    at (257, 52): KS AS 2S
    at (332, 52): 3D 4C 5H 6S
    at (407, 52): KS' AD 2C
    at (482, 52): TD JD QD
    at (92, 187): AH 2H 3H
    at (167, 187): QC KD AC
    at (242, 187): AC' 2H' 3S 4H
    at (407, 187): 6C'
  verb: peel
  source: 3D 4C 5H 6S
  ext_card: 6S
  target_before: 6C'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [3D 4C 5H 6S]@3
      - merge_stack [6S] -> [6C'] /right

scenario mined_006_6Cp1_step_02
  desc: mined_006_6Cp1 step 2 (extract_absorb/split_out).
  op: verb_to_primitives
  board:
    at (26, 26): 4S' 5D' 6C
    at (107, 52): 5C 6D' 7C
    at (182, 52): 7S 7D 7H
    at (257, 52): KS AS 2S
    at (407, 52): KS' AD 2C
    at (482, 52): TD JD QD
    at (92, 187): AH 2H 3H
    at (167, 187): QC KD AC
    at (242, 187): AC' 2H' 3S 4H
    at (332, 44): 3D 4C 5H
    at (407, 187): 6C' 6S
  verb: split_out
  source: 5C 6D' 7C
  ext_card: 6D'
  target_before: 6C' 6S
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [5C 6D' 7C]@0
      - move_stack [6D' 7C] -> (332,172)
      - split [6D' 7C]@0
      - merge_stack [6D'] -> [6C' 6S] /right

scenario mined_006_6Cp1_step_03
  desc: mined_006_6Cp1 step 3 (push).
  op: verb_to_primitives
  board:
    at (26, 26): 4S' 5D' 6C
    at (182, 52): 7S 7D 7H
    at (257, 52): KS AS 2S
    at (407, 52): KS' AD 2C
    at (482, 52): TD JD QD
    at (92, 187): AH 2H 3H
    at (167, 187): QC KD AC
    at (242, 187): AC' 2H' 3S 4H
    at (332, 44): 3D 4C 5H
    at (103, 50): 5C
    at (332, 213): 7C
    at (407, 187): 6C' 6S 6D'
  verb: push
  trouble_before: 5C
  target_before: AC' 2H' 3S 4H
  side: right
  expect:
    primitives:
      - merge_stack [5C] -> [AC' 2H' 3S 4H] /right

scenario mined_006_6Cp1_step_04
  desc: mined_006_6Cp1 step 4 (push).
  op: verb_to_primitives
  board:
    at (26, 26): 4S' 5D' 6C
    at (182, 52): 7S 7D 7H
    at (257, 52): KS AS 2S
    at (407, 52): KS' AD 2C
    at (482, 52): TD JD QD
    at (92, 187): AH 2H 3H
    at (167, 187): QC KD AC
    at (332, 44): 3D 4C 5H
    at (332, 213): 7C
    at (407, 187): 6C' 6S 6D'
    at (242, 187): AC' 2H' 3S 4H 5C
  verb: push
  trouble_before: 7C
  target_before: 7S 7D 7H
  side: right
  expect:
    primitives:
      - move_stack [7S 7D 7H] -> (332,172)
      - merge_stack [7C] -> [7S 7D 7H] /right

scenario mined_007_5Cp1_6C_step_01
  desc: mined_007_5Cp1_6C step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (257, 52): 7S 7D 7C
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 9H' TC' JH
    at (182, 187): 5C' 6C
  verb: steal
  source: 7S 7D 7C
  ext_card: 7C
  target_before: 5C' 6C
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [7S 7D 7C]@2
      - move_stack [7S 7D] -> (257,187)
      - split [7S 7D]@0
      - merge_stack [7C] -> [5C' 6C] /right

scenario mined_007_5Cp1_6C_step_02
  desc: mined_007_5Cp1_6C step 2 (free_pull).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 9H' TC' JH
    at (253, 185): 7S
    at (257, 228): 7D
    at (182, 187): 5C' 6C 7C
  verb: free_pull
  loose: 7D
  target_before: 7S
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - merge_stack [7D] -> [7S] /right

scenario mined_007_5Cp1_6C_step_03
  desc: mined_007_5Cp1_6C step 3 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 9H' TC' JH
    at (182, 187): 5C' 6C 7C
    at (253, 185): 7S 7D
  verb: peel
  source: 2C 3D 4C 5H 6S 7H
  ext_card: 7H
  target_before: 7S 7D
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [2C 3D 4C 5H 6S 7H]@5
      - merge_stack [7H] -> [7S 7D] /right

scenario mined_008_QHp1_step_01
  desc: mined_008_QHp1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): TD JD QD KD
    at (107, 52): 2H 3H 4H
    at (182, 52): AC AD AH
    at (257, 52): 9H' TC' JH
    at (332, 52): 5C' 6C 7C
    at (407, 52): 2C 3D 4C 5H 6S
    at (482, 52): 7S 7D 7H
    at (92, 187): AS 2S 3S
    at (167, 187): JS' QS' KS
    at (242, 187): QH'
  verb: steal
  source: JS' QS' KS
  ext_card: JS'
  target_before: QH'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [JS' QS' KS]@0
      - move_stack [QH'] -> (242,220)
      - merge_stack [JS'] -> [QH'] /left

scenario mined_008_QHp1_step_02
  desc: mined_008_QHp1 step 2 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): TD JD QD KD
    at (107, 52): 2H 3H 4H
    at (182, 52): AC AD AH
    at (257, 52): 9H' TC' JH
    at (332, 52): 5C' 6C 7C
    at (407, 52): 2C 3D 4C 5H 6S
    at (482, 52): 7S 7D 7H
    at (92, 187): AS 2S 3S
    at (167, 228): QS' KS
    at (242, 187): JS' QH'
  verb: peel
  source: TD JD QD KD
  ext_card: TD
  target_before: JS' QH'
  target_bucket: growing
  side: left
  expect:
    primitives:
      - move_stack [TD JD QD KD] -> (317,187)
      - split [TD JD QD KD]@0
      - move_stack [JS' QH'] -> (242,220)
      - merge_stack [TD] -> [JS' QH'] /left

scenario mined_008_QHp1_step_03
  desc: mined_008_QHp1 step 3 (push).
  op: verb_to_primitives
  board:
    at (107, 52): 2H 3H 4H
    at (182, 52): AC AD AH
    at (257, 52): 9H' TC' JH
    at (332, 52): 5C' 6C 7C
    at (407, 52): 2C 3D 4C 5H 6S
    at (482, 52): 7S 7D 7H
    at (92, 187): AS 2S 3S
    at (167, 228): QS' KS
    at (317, 228): JD QD KD
    at (242, 187): TD JS' QH'
  verb: push
  trouble_before: QS' KS
  target_before: AS 2S 3S
  side: left
  expect:
    primitives:
      - move_stack [AS 2S 3S] -> (92,253)
      - merge_stack [QS' KS] -> [AS 2S 3S] /left

scenario mined_009_JC_step_01
  desc: mined_009_JC step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): AC AD AH
    at (107, 52): 9H' TC' JH
    at (182, 52): 5C' 6C 7C
    at (257, 52): 2C 3D 4C 5H 6S
    at (332, 52): 7S 7D 7H
    at (407, 52): JD QD KD
    at (482, 52): QS' KS AS 2S 3S
    at (92, 187): 9S TD JS' QH'
    at (167, 187): 2H 3H 4H 5H'
    at (332, 187): JC
  verb: peel
  source: 9S TD JS' QH'
  ext_card: QH'
  target_before: JC
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [9S TD JS' QH']@3
      - merge_stack [QH'] -> [JC] /right

scenario mined_009_JC_step_02
  desc: mined_009_JC step 2 (extract_absorb/yank).
  op: verb_to_primitives
  board:
    at (26, 26): AC AD AH
    at (107, 52): 9H' TC' JH
    at (182, 52): 5C' 6C 7C
    at (257, 52): 2C 3D 4C 5H 6S
    at (332, 52): 7S 7D 7H
    at (407, 52): JD QD KD
    at (482, 52): QS' KS AS 2S 3S
    at (167, 187): 2H 3H 4H 5H'
    at (92, 179): 9S TD JS'
    at (332, 187): JC QH'
  verb: yank
  source: QS' KS AS 2S 3S
  ext_card: KS
  target_before: JC QH'
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [QS' KS AS 2S 3S]@0
      - move_stack [KS AS 2S 3S] -> (482,112)
      - split [KS AS 2S 3S]@0
      - merge_stack [KS] -> [JC QH'] /right

scenario mined_009_JC_step_03
  desc: mined_009_JC step 3 (push).
  op: verb_to_primitives
  board:
    at (26, 26): AC AD AH
    at (107, 52): 9H' TC' JH
    at (182, 52): 5C' 6C 7C
    at (257, 52): 2C 3D 4C 5H 6S
    at (332, 52): 7S 7D 7H
    at (407, 52): JD QD KD
    at (167, 187): 2H 3H 4H 5H'
    at (92, 179): 9S TD JS'
    at (478, 50): QS'
    at (482, 153): AS 2S 3S
    at (332, 187): JC QH' KS
  verb: push
  trouble_before: QS'
  target_before: 9H' TC' JH
  side: right
  expect:
    primitives:
      - move_stack [9H' TC' JH] -> (407,187)
      - merge_stack [QS'] -> [9H' TC' JH] /right

scenario mined_010_3Hp1_step_01
  desc: mined_010_3Hp1 step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): TD JD QD KD
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (257, 52): AC AD AH
    at (332, 52): 9H' 9C 9D
    at (407, 52): 2C 3D 4C 5H 6S
    at (482, 52): 5D' 6C' 7H
    at (92, 187): AS 2S 3S
    at (167, 187): KC' KD' KS
    at (242, 187): TC' JD' QS
    at (317, 187): 3H'
  verb: peel
  source: 2C 3D 4C 5H 6S
  ext_card: 2C
  target_before: 3H'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [2C 3D 4C 5H 6S]@0
      - move_stack [3H'] -> (317,220)
      - merge_stack [2C] -> [3H'] /left

scenario mined_010_3Hp1_step_02
  desc: mined_010_3Hp1 step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): TD JD QD KD
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (257, 52): AC AD AH
    at (332, 52): 9H' 9C 9D
    at (482, 52): 5D' 6C' 7H
    at (92, 187): AS 2S 3S
    at (167, 187): KC' KD' KS
    at (242, 187): TC' JD' QS
    at (407, 93): 3D 4C 5H 6S
    at (317, 187): 2C 3H'
  verb: steal
  source: AC AD AH
  ext_card: AD
  target_before: 2C 3H'
  target_bucket: growing
  side: left
  expect:
    primitives:
      - split [AC AD AH]@0
      - move_stack [AD AH] -> (482,187)
      - split [AD AH]@0
      - move_stack [2C 3H'] -> (317,220)
      - merge_stack [AD] -> [2C 3H'] /left

scenario mined_010_3Hp1_step_03
  desc: mined_010_3Hp1 step 3 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): TD JD QD KD
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (332, 52): 9H' 9C 9D
    at (482, 52): 5D' 6C' 7H
    at (92, 187): AS 2S 3S
    at (167, 187): KC' KD' KS
    at (242, 187): TC' JD' QS
    at (407, 93): 3D 4C 5H 6S
    at (253, 50): AC
    at (482, 228): AH
    at (317, 187): AD 2C 3H'
  verb: peel
  source: TD JD QD KD
  ext_card: KD
  target_before: AC
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [TD JD QD KD]@3
      - merge_stack [KD] -> [AC] /left

scenario mined_010_3Hp1_step_04
  desc: mined_010_3Hp1 step 4 (push).
  op: verb_to_primitives
  board:
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (332, 52): 9H' 9C 9D
    at (482, 52): 5D' 6C' 7H
    at (92, 187): AS 2S 3S
    at (167, 187): KC' KD' KS
    at (242, 187): TC' JD' QS
    at (407, 93): 3D 4C 5H 6S
    at (482, 228): AH
    at (317, 187): AD 2C 3H'
    at (26, 18): TD JD QD
    at (253, 17): KD AC
  verb: push
  trouble_before: KD AC
  target_before: TC' JD' QS
  side: right
  expect:
    primitives:
      - merge_stack [KD AC] -> [TC' JD' QS] /right

scenario mined_010_3Hp1_step_05
  desc: mined_010_3Hp1 step 5 (push).
  op: verb_to_primitives
  board:
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (332, 52): 9H' 9C 9D
    at (482, 52): 5D' 6C' 7H
    at (92, 187): AS 2S 3S
    at (167, 187): KC' KD' KS
    at (407, 93): 3D 4C 5H 6S
    at (482, 228): AH
    at (317, 187): AD 2C 3H'
    at (26, 18): TD JD QD
    at (242, 187): TC' JD' QS KD AC
  verb: push
  trouble_before: AH
  target_before: 2H 3H 4H
  side: left
  expect:
    primitives:
      - merge_stack [AH] -> [2H 3H 4H] /left

scenario mined_011_JC_step_01
  desc: mined_011_JC step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): 9H' 9C 9D
    at (182, 52): AS 2S 3S
    at (257, 52): KC' KD' KS
    at (332, 52): AD 2C 3H'
    at (407, 52): TD JD QD
    at (482, 52): TC' JD' QS KD AC
    at (92, 187): AH 2H 3H 4H
    at (167, 187): 4C 5H 6S
    at (242, 187): 6C' 7H 8S
    at (317, 187): 3D 4D 5D'
    at (392, 187): JC
  verb: peel
  source: TC' JD' QS KD AC
  ext_card: TC'
  target_before: JC
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [TC' JD' QS KD AC]@0
      - move_stack [JC] -> (392,220)
      - merge_stack [TC'] -> [JC] /left

scenario mined_011_JC_step_02
  desc: mined_011_JC step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): 9H' 9C 9D
    at (182, 52): AS 2S 3S
    at (257, 52): KC' KD' KS
    at (332, 52): AD 2C 3H'
    at (407, 52): TD JD QD
    at (92, 187): AH 2H 3H 4H
    at (167, 187): 4C 5H 6S
    at (242, 187): 6C' 7H 8S
    at (317, 187): 3D 4D 5D'
    at (482, 93): JD' QS KD AC
    at (392, 187): TC' JC
  verb: steal
  source: 9H' 9C 9D
  ext_card: 9C
  target_before: TC' JC
  target_bucket: growing
  side: left
  expect:
    primitives:
      - split [9H' 9C 9D]@0
      - move_stack [9C 9D] -> (467,262)
      - split [9C 9D]@0
      - move_stack [TC' JC] -> (392,220)
      - merge_stack [9C] -> [TC' JC] /left

scenario mined_011_JC_step_03
  desc: mined_011_JC step 3 (push).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (182, 52): AS 2S 3S
    at (257, 52): KC' KD' KS
    at (332, 52): AD 2C 3H'
    at (407, 52): TD JD QD
    at (92, 187): AH 2H 3H 4H
    at (167, 187): 4C 5H 6S
    at (242, 187): 6C' 7H 8S
    at (317, 187): 3D 4D 5D'
    at (482, 93): JD' QS KD AC
    at (103, 50): 9H'
    at (467, 303): 9D
    at (392, 187): 9C TC' JC
  verb: push
  trouble_before: 9H'
  target_before: 6C' 7H 8S
  side: right
  expect:
    primitives:
      - merge_stack [9H'] -> [6C' 7H 8S] /right

scenario mined_011_JC_step_04
  desc: mined_011_JC step 4 (push).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (182, 52): AS 2S 3S
    at (257, 52): KC' KD' KS
    at (332, 52): AD 2C 3H'
    at (407, 52): TD JD QD
    at (92, 187): AH 2H 3H 4H
    at (167, 187): 4C 5H 6S
    at (317, 187): 3D 4D 5D'
    at (482, 93): JD' QS KD AC
    at (467, 303): 9D
    at (392, 187): 9C TC' JC
    at (242, 187): 6C' 7H 8S 9H'
  verb: push
  trouble_before: 9D
  target_before: TD JD QD
  side: left
  expect:
    primitives:
      - merge_stack [9D] -> [TD JD QD] /left

scenario mined_012_QC_KC_step_01
  desc: mined_012_QC_KC step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (257, 52): 7S 7D 7C
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 4D' 5S 6D'
    at (182, 187): QC KC
  verb: steal
  source: AC AD AH
  ext_card: AC
  target_before: QC KC
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [AC AD AH]@0
      - move_stack [AD AH] -> (332,112)
      - split [AD AH]@0
      - merge_stack [AC] -> [QC KC] /right

scenario mined_012_QC_KC_step_02
  desc: mined_012_QC_KC step 2 (push).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (257, 52): 7S 7D 7C
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 4D' 5S 6D'
    at (328, 110): AD
    at (332, 153): AH
    at (182, 187): QC KC AC
  verb: push
  trouble_before: AD
  target_before: TD JD QD KD
  side: right
  expect:
    primitives:
      - merge_stack [AD] -> [TD JD QD KD] /right

scenario mined_012_QC_KC_step_03
  desc: mined_012_QC_KC step 3 (push).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (182, 52): 2H 3H 4H
    at (257, 52): 7S 7D 7C
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 4D' 5S 6D'
    at (332, 153): AH
    at (182, 187): QC KC AC
    at (107, 52): TD JD QD KD AD
  verb: push
  trouble_before: AH
  target_before: 2H 3H 4H
  side: left
  expect:
    primitives:
      - merge_stack [AH] -> [2H 3H 4H] /left

scenario mined_013_AHp1_step_01
  desc: mined_013_AHp1 step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): 7S 7D 7C
    at (182, 52): TD JD QD KD AD
    at (257, 52): AH 2H 3H
    at (332, 52): 4S' 4D 4H
    at (407, 52): 2D 3C' 4D' 5S 6D'
    at (482, 52): 3D 4C 5H 6S 7H
    at (92, 187): KC AC 2C
    at (257, 187): TC' JH QC
    at (332, 187): AH'
  verb: peel
  source: KS AS 2S 3S
  ext_card: KS
  target_before: AH'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - move_stack [KS AS 2S 3S] -> (167,247)
      - split [KS AS 2S 3S]@0
      - move_stack [AH'] -> (332,220)
      - merge_stack [KS] -> [AH'] /left

scenario mined_013_AHp1_step_02
  desc: mined_013_AHp1 step 2 (extract_absorb/split_out).
  op: verb_to_primitives
  board:
    at (107, 52): 7S 7D 7C
    at (182, 52): TD JD QD KD AD
    at (257, 52): AH 2H 3H
    at (332, 52): 4S' 4D 4H
    at (407, 52): 2D 3C' 4D' 5S 6D'
    at (482, 52): 3D 4C 5H 6S 7H
    at (92, 187): KC AC 2C
    at (257, 187): TC' JH QC
    at (167, 288): AS 2S 3S
    at (332, 187): KS AH'
  verb: split_out
  source: AS 2S 3S
  ext_card: 2S
  target_before: KS AH'
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [AS 2S 3S]@0
      - move_stack [2S 3S] -> (407,247)
      - split [2S 3S]@0
      - merge_stack [2S] -> [KS AH'] /right

scenario mined_013_AHp1_step_03
  desc: mined_013_AHp1 step 3 (push).
  op: verb_to_primitives
  board:
    at (107, 52): 7S 7D 7C
    at (182, 52): TD JD QD KD AD
    at (257, 52): AH 2H 3H
    at (332, 52): 4S' 4D 4H
    at (407, 52): 2D 3C' 4D' 5S 6D'
    at (482, 52): 3D 4C 5H 6S 7H
    at (92, 187): KC AC 2C
    at (257, 187): TC' JH QC
    at (163, 286): AS
    at (407, 288): 3S
    at (332, 187): KS AH' 2S
  verb: push
  trouble_before: AS
  target_before: 2D 3C' 4D' 5S 6D'
  side: left
  expect:
    primitives:
      - merge_stack [AS] -> [2D 3C' 4D' 5S 6D'] /left

scenario mined_013_AHp1_step_04
  desc: mined_013_AHp1 step 4 (splice).
  op: verb_to_primitives
  board:
    at (107, 52): 7S 7D 7C
    at (182, 52): TD JD QD KD AD
    at (257, 52): AH 2H 3H
    at (332, 52): 4S' 4D 4H
    at (482, 52): 3D 4C 5H 6S 7H
    at (92, 187): KC AC 2C
    at (257, 187): TC' JH QC
    at (407, 288): 3S
    at (332, 187): KS AH' 2S
    at (407, 19): AS 2D 3C' 4D' 5S 6D'
  verb: splice
  loose: 3S
  source: AS 2D 3C' 4D' 5S 6D'
  k: 2
  side: left
  expect:
    primitives:
      - move_stack [AS 2D 3C' 4D' 5S 6D'] -> (407,52)
      - split [AS 2D 3C' 4D' 5S 6D']@1
      - move_stack [AS 2D] -> (167,247)
      - merge_stack [3S] -> [AS 2D] /right

scenario mined_014_5C_step_01
  desc: mined_014_5C step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): TD JD QD KD AD
    at (182, 52): AH 2H 3H
    at (257, 52): 4S' 4D 4H
    at (332, 52): 3D 4C 5H 6S 7H
    at (407, 52): KC AC 2C
    at (482, 52): TC' JH QC
    at (182, 187): KS AH' 2S
    at (257, 187): 3C' 4D' 5S 6D'
    at (407, 187): AS 2D 3S
    at (482, 187): 5C
  verb: peel
  source: 3C' 4D' 5S 6D'
  ext_card: 6D'
  target_before: 5C
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [3C' 4D' 5S 6D']@3
      - merge_stack [6D'] -> [5C] /right

scenario mined_014_5C_step_02
  desc: mined_014_5C step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): TD JD QD KD AD
    at (182, 52): AH 2H 3H
    at (257, 52): 4S' 4D 4H
    at (332, 52): 3D 4C 5H 6S 7H
    at (407, 52): KC AC 2C
    at (482, 52): TC' JH QC
    at (182, 187): KS AH' 2S
    at (407, 187): AS 2D 3S
    at (257, 179): 3C' 4D' 5S
    at (482, 187): 5C 6D'
  verb: steal
  source: 7S 7D 7C
  ext_card: 7C
  target_before: 5C 6D'
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [7S 7D 7C]@2
      - move_stack [7S 7D] -> (92,247)
      - split [7S 7D]@0
      - merge_stack [7C] -> [5C 6D'] /right

scenario mined_014_5C_step_03
  desc: mined_014_5C step 3 (free_pull).
  op: verb_to_primitives
  board:
    at (107, 52): TD JD QD KD AD
    at (182, 52): AH 2H 3H
    at (257, 52): 4S' 4D 4H
    at (332, 52): 3D 4C 5H 6S 7H
    at (407, 52): KC AC 2C
    at (482, 52): TC' JH QC
    at (182, 187): KS AH' 2S
    at (407, 187): AS 2D 3S
    at (257, 179): 3C' 4D' 5S
    at (88, 245): 7S
    at (92, 288): 7D
    at (482, 187): 5C 6D' 7C
  verb: free_pull
  loose: 7D
  target_before: 7S
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - merge_stack [7D] -> [7S] /right

scenario mined_014_5C_step_04
  desc: mined_014_5C step 4 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (107, 52): TD JD QD KD AD
    at (182, 52): AH 2H 3H
    at (257, 52): 4S' 4D 4H
    at (332, 52): 3D 4C 5H 6S 7H
    at (407, 52): KC AC 2C
    at (482, 52): TC' JH QC
    at (182, 187): KS AH' 2S
    at (407, 187): AS 2D 3S
    at (257, 179): 3C' 4D' 5S
    at (482, 187): 5C 6D' 7C
    at (88, 245): 7S 7D
  verb: peel
  source: 3D 4C 5H 6S 7H
  ext_card: 7H
  target_before: 7S 7D
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [3D 4C 5H 6S 7H]@4
      - merge_stack [7H] -> [7S 7D] /right

scenario mined_015_3Cp1_step_01
  desc: mined_015_3Cp1 step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (257, 52): AC AD AH
    at (332, 52): 2C 3D 4C 5H 6S 7H
    at (407, 52): 9S TS' JS
    at (482, 52): JD QD KD
    at (92, 187): 8D 9D TD
    at (167, 187): 2H' 2C' 2D
    at (242, 187): 3C'
  verb: peel
  source: 2C 3D 4C 5H 6S 7H
  ext_card: 2C
  target_before: 3C'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [2C 3D 4C 5H 6S 7H]@0
      - move_stack [3C'] -> (242,220)
      - merge_stack [2C] -> [3C'] /left

scenario mined_015_3Cp1_step_02
  desc: mined_015_3Cp1 step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (257, 52): AC AD AH
    at (407, 52): 9S TS' JS
    at (482, 52): JD QD KD
    at (92, 187): 8D 9D TD
    at (167, 187): 2H' 2C' 2D
    at (332, 93): 3D 4C 5H 6S 7H
    at (242, 187): 2C 3C'
  verb: steal
  source: AC AD AH
  ext_card: AC
  target_before: 2C 3C'
  target_bucket: growing
  side: left
  expect:
    primitives:
      - split [AC AD AH]@0
      - move_stack [AD AH] -> (407,187)
      - split [AD AH]@0
      - move_stack [2C 3C'] -> (257,85)
      - merge_stack [AC] -> [2C 3C'] /left

scenario mined_015_3Cp1_step_03
  desc: mined_015_3Cp1 step 3 (push).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (407, 52): 9S TS' JS
    at (482, 52): JD QD KD
    at (92, 187): 8D 9D TD
    at (167, 187): 2H' 2C' 2D
    at (332, 93): 3D 4C 5H 6S 7H
    at (403, 185): AD
    at (407, 228): AH
    at (257, 52): AC 2C 3C'
  verb: push
  trouble_before: AD
  target_before: JD QD KD
  side: right
  expect:
    primitives:
      - merge_stack [AD] -> [JD QD KD] /right

scenario mined_015_3Cp1_step_04
  desc: mined_015_3Cp1 step 4 (push).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (407, 52): 9S TS' JS
    at (92, 187): 8D 9D TD
    at (167, 187): 2H' 2C' 2D
    at (332, 93): 3D 4C 5H 6S 7H
    at (407, 228): AH
    at (257, 52): AC 2C 3C'
    at (482, 52): JD QD KD AD
  verb: push
  trouble_before: AH
  target_before: 2H 3H 4H
  side: left
  expect:
    primitives:
      - merge_stack [AH] -> [2H 3H 4H] /left

scenario mined_016_TCp1_step_01
  desc: mined_016_TCp1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): 8D 9D TD
    at (182, 52): 2H' 2C' 2D
    at (257, 52): 3D 4C 5H 6S 7H
    at (332, 52): AC 2C 3C'
    at (407, 52): AH 2H 3H 4H
    at (482, 52): AS 2S 3S
    at (92, 187): JD QD KD
    at (167, 187): QH KS AD
    at (332, 187): 9S TS' JS QS
    at (482, 187): TC'
  verb: steal
  source: JD QD KD
  ext_card: JD
  target_before: TC'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [JD QD KD]@0
      - merge_stack [JD] -> [TC'] /right

scenario mined_016_TCp1_step_02
  desc: mined_016_TCp1 step 2 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): 8D 9D TD
    at (182, 52): 2H' 2C' 2D
    at (257, 52): 3D 4C 5H 6S 7H
    at (332, 52): AC 2C 3C'
    at (407, 52): AH 2H 3H 4H
    at (482, 52): AS 2S 3S
    at (167, 187): QH KS AD
    at (332, 187): 9S TS' JS QS
    at (92, 228): QD KD
    at (482, 187): TC' JD
  verb: peel
  source: 9S TS' JS QS
  ext_card: QS
  target_before: TC' JD
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [9S TS' JS QS]@3
      - merge_stack [QS] -> [TC' JD] /right

scenario mined_016_TCp1_step_03
  desc: mined_016_TCp1 step 3 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): 8D 9D TD
    at (182, 52): 2H' 2C' 2D
    at (257, 52): 3D 4C 5H 6S 7H
    at (332, 52): AC 2C 3C'
    at (407, 52): AH 2H 3H 4H
    at (482, 52): AS 2S 3S
    at (167, 187): QH KS AD
    at (92, 228): QD KD
    at (332, 179): 9S TS' JS
    at (482, 187): TC' JD QS
  verb: steal
  source: QH KS AD
  ext_card: AD
  target_before: QD KD
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [QH KS AD]@2
      - merge_stack [AD] -> [QD KD] /right

scenario mined_016_TCp1_step_04
  desc: mined_016_TCp1 step 4 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): 8D 9D TD
    at (182, 52): 2H' 2C' 2D
    at (257, 52): 3D 4C 5H 6S 7H
    at (332, 52): AC 2C 3C'
    at (407, 52): AH 2H 3H 4H
    at (482, 52): AS 2S 3S
    at (332, 179): 9S TS' JS
    at (482, 187): TC' JD QS
    at (167, 179): QH KS
    at (92, 228): QD KD AD
  verb: peel
  source: AH 2H 3H 4H
  ext_card: AH
  target_before: QH KS
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [AH 2H 3H 4H]@0
      - merge_stack [AH] -> [QH KS] /right

scenario mined_017_5Dp1_6Dp1_step_01
  desc: mined_017_5Dp1_6Dp1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (257, 52): 7S 7D 7C
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 5D' 6D'
  verb: steal
  source: 7S 7D 7C
  ext_card: 7D
  target_before: 5D' 6D'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [7S 7D 7C]@0
      - move_stack [7D 7C] -> (257,112)
      - split [7D 7C]@0
      - merge_stack [7D] -> [5D' 6D'] /right

scenario mined_017_5Dp1_6Dp1_step_02
  desc: mined_017_5Dp1_6Dp1 step 2 (free_pull).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (253, 50): 7S
    at (257, 153): 7C
    at (482, 52): 5D' 6D' 7D
  verb: free_pull
  loose: 7C
  target_before: 7S
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - merge_stack [7C] -> [7S] /right

scenario mined_017_5Dp1_6Dp1_step_03
  desc: mined_017_5Dp1_6Dp1 step 3 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 5D' 6D' 7D
    at (253, 50): 7S 7C
  verb: peel
  source: 2C 3D 4C 5H 6S 7H
  ext_card: 7H
  target_before: 7S 7C
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [2C 3D 4C 5H 6S 7H]@5
      - merge_stack [7H] -> [7S 7C] /right

scenario mined_018_2Sp1_3Hp1_step_01
  desc: mined_018_2Sp1_3Hp1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (257, 52): AC AD AH
    at (332, 52): 2C 3D 4C 5H 6S 7H
    at (407, 52): 7S' 8D' 9C'
    at (482, 52): 3C' 4H' 5S'
    at (92, 187): JD QD KD
    at (167, 187): TS TC TD
    at (242, 187): 2S' 3H'
  verb: steal
  source: AC AD AH
  ext_card: AD
  target_before: 2S' 3H'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [AC AD AH]@0
      - move_stack [AD AH] -> (407,187)
      - split [AD AH]@0
      - move_stack [2S' 3H'] -> (257,145)
      - merge_stack [AD] -> [2S' 3H'] /left

scenario mined_018_2Sp1_3Hp1_step_02
  desc: mined_018_2Sp1_3Hp1 step 2 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (332, 52): 2C 3D 4C 5H 6S 7H
    at (407, 52): 7S' 8D' 9C'
    at (482, 52): 3C' 4H' 5S'
    at (92, 187): JD QD KD
    at (167, 187): TS TC TD
    at (253, 50): AC
    at (407, 228): AH
    at (257, 112): AD 2S' 3H'
  verb: peel
  source: 2C 3D 4C 5H 6S 7H
  ext_card: 2C
  target_before: AC
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [2C 3D 4C 5H 6S 7H]@0
      - move_stack [AC] -> (482,187)
      - merge_stack [2C] -> [AC] /right

scenario mined_018_2Sp1_3Hp1_step_03
  desc: mined_018_2Sp1_3Hp1 step 3 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (407, 52): 7S' 8D' 9C'
    at (482, 52): 3C' 4H' 5S'
    at (92, 187): JD QD KD
    at (167, 187): TS TC TD
    at (407, 228): AH
    at (257, 112): AD 2S' 3H'
    at (332, 93): 3D 4C 5H 6S 7H
    at (482, 187): AC 2C
  verb: steal
  source: 3C' 4H' 5S'
  ext_card: 3C'
  target_before: AC 2C
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [3C' 4H' 5S']@0
      - merge_stack [3C'] -> [AC 2C] /right

scenario mined_018_2Sp1_3Hp1_step_04
  desc: mined_018_2Sp1_3Hp1 step 4 (push).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (407, 52): 7S' 8D' 9C'
    at (92, 187): JD QD KD
    at (167, 187): TS TC TD
    at (407, 228): AH
    at (257, 112): AD 2S' 3H'
    at (332, 93): 3D 4C 5H 6S 7H
    at (482, 93): 4H' 5S'
    at (482, 187): AC 2C 3C'
  verb: push
  trouble_before: AH
  target_before: 2H 3H 4H
  side: left
  expect:
    primitives:
      - merge_stack [AH] -> [2H 3H 4H] /left

scenario mined_018_2Sp1_3Hp1_step_05
  desc: mined_018_2Sp1_3Hp1 step 5 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (182, 52): 7S 7D 7C
    at (407, 52): 7S' 8D' 9C'
    at (92, 187): JD QD KD
    at (167, 187): TS TC TD
    at (257, 112): AD 2S' 3H'
    at (332, 93): 3D 4C 5H 6S 7H
    at (482, 93): 4H' 5S'
    at (482, 187): AC 2C 3C'
    at (107, 19): AH 2H 3H 4H
  verb: peel
  source: KS AS 2S 3S
  ext_card: 3S
  target_before: 4H' 5S'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [KS AS 2S 3S]@3
      - merge_stack [3S] -> [4H' 5S'] /left

scenario mined_019_2D_step_01
  desc: mined_019_2D step 1 (extract_absorb/split_out).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): JD QD KD
    at (182, 52): TC' TH TD
    at (257, 52): 5C' 6D 7C'
    at (332, 52): 6S 7H 8C'
    at (407, 52): AC 2D' 3S'
    at (482, 52): AS 2S 3S
    at (92, 187): KS AD 2C'
    at (167, 187): 2H 3H 4H 5H
    at (242, 187): AH 2C 3D 4C
    at (317, 187): 2D
  verb: split_out
  source: KS AD 2C'
  ext_card: AD
  target_before: 2D
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [KS AD 2C']@0
      - move_stack [AD 2C'] -> (392,187)
      - split [AD 2C']@0
      - move_stack [2D] -> (317,220)
      - merge_stack [AD] -> [2D] /left

scenario mined_019_2D_step_02
  desc: mined_019_2D step 2 (push).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): JD QD KD
    at (182, 52): TC' TH TD
    at (257, 52): 5C' 6D 7C'
    at (332, 52): 6S 7H 8C'
    at (407, 52): AC 2D' 3S'
    at (482, 52): AS 2S 3S
    at (167, 187): 2H 3H 4H 5H
    at (242, 187): AH 2C 3D 4C
    at (88, 185): KS
    at (392, 228): 2C'
    at (317, 187): AD 2D
  verb: push
  trouble_before: AD 2D
  target_before: JD QD KD
  side: right
  expect:
    primitives:
      - move_stack [JD QD KD] -> (317,187)
      - merge_stack [AD 2D] -> [JD QD KD] /right

scenario mined_019_2D_step_03
  desc: mined_019_2D step 3 (push).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (182, 52): TC' TH TD
    at (257, 52): 5C' 6D 7C'
    at (332, 52): 6S 7H 8C'
    at (407, 52): AC 2D' 3S'
    at (482, 52): AS 2S 3S
    at (167, 187): 2H 3H 4H 5H
    at (242, 187): AH 2C 3D 4C
    at (88, 185): KS
    at (392, 228): 2C'
    at (317, 187): JD QD KD AD 2D
  verb: push
  trouble_before: KS
  target_before: AH 2C 3D 4C
  side: left
  expect:
    primitives:
      - move_stack [AH 2C 3D 4C] -> (92,190)
      - merge_stack [KS] -> [AH 2C 3D 4C] /left

scenario mined_019_2D_step_04
  desc: mined_019_2D step 4 (splice).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (182, 52): TC' TH TD
    at (257, 52): 5C' 6D 7C'
    at (332, 52): 6S 7H 8C'
    at (407, 52): AC 2D' 3S'
    at (482, 52): AS 2S 3S
    at (167, 187): 2H 3H 4H 5H
    at (392, 228): 2C'
    at (317, 187): JD QD KD AD 2D
    at (92, 157): KS AH 2C 3D 4C
  verb: splice
  loose: 2C'
  source: KS AH 2C 3D 4C
  k: 2
  side: left
  expect:
    primitives:
      - split [KS AH 2C 3D 4C]@1
      - move_stack [KS AH] -> (107,52)
      - merge_stack [2C'] -> [KS AH] /right

scenario mined_020_2Dp1_3Cp1_step_01
  desc: mined_020_2Dp1_3Cp1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (257, 52): AC AD AH
    at (332, 52): 2C 3D 4C 5H 6S 7H
    at (407, 52): JD QD KD
    at (482, 52): TC TH TD
    at (92, 187): 9D 9C' 9S'
    at (167, 187): 2D' 3C'
  verb: steal
  source: AC AD AH
  ext_card: AC
  target_before: 2D' 3C'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [AC AD AH]@0
      - move_stack [AD AH] -> (257,112)
      - split [AD AH]@0
      - move_stack [2D' 3C'] -> (167,220)
      - merge_stack [AC] -> [2D' 3C'] /left

scenario mined_020_2Dp1_3Cp1_step_02
  desc: mined_020_2Dp1_3Cp1 step 2 (push).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (332, 52): 2C 3D 4C 5H 6S 7H
    at (407, 52): JD QD KD
    at (482, 52): TC TH TD
    at (92, 187): 9D 9C' 9S'
    at (253, 110): AD
    at (257, 153): AH
    at (167, 187): AC 2D' 3C'
  verb: push
  trouble_before: AD
  target_before: 2C 3D 4C 5H 6S 7H
  side: left
  expect:
    primitives:
      - merge_stack [AD] -> [2C 3D 4C 5H 6S 7H] /left

scenario mined_020_2Dp1_3Cp1_step_03
  desc: mined_020_2Dp1_3Cp1 step 3 (push).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): 2H 3H 4H
    at (182, 52): 7S 7D 7C
    at (407, 52): JD QD KD
    at (482, 52): TC TH TD
    at (92, 187): 9D 9C' 9S'
    at (257, 153): AH
    at (167, 187): AC 2D' 3C'
    at (332, 19): AD 2C 3D 4C 5H 6S 7H
  verb: push
  trouble_before: AH
  target_before: 2H 3H 4H
  side: left
  expect:
    primitives:
      - merge_stack [AH] -> [2H 3H 4H] /left

scenario mined_021_8Dp1_step_01
  desc: mined_021_8Dp1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (257, 52): 7S 7D 7C
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): JH' JD' JC
    at (182, 187): 4H' 5C' 6D'
    at (257, 187): 6S' 7H' 8C' 9H
    at (332, 187): 8D'
  verb: steal
  source: 7S 7D 7C
  ext_card: 7C
  target_before: 8D'
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [7S 7D 7C]@2
      - move_stack [7S 7D] -> (482,187)
      - split [7S 7D]@0
      - move_stack [8D'] -> (257,85)
      - merge_stack [7C] -> [8D'] /left

scenario mined_021_8Dp1_step_02
  desc: mined_021_8Dp1 step 2 (shift).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): JH' JD' JC
    at (182, 187): 4H' 5C' 6D'
    at (257, 187): 6S' 7H' 8C' 9H
    at (478, 185): 7S
    at (482, 228): 7D
    at (257, 52): 7C 8D'
  verb: shift
  source: 4H' 5C' 6D'
  donor: KS AS 2S 3S
  stolen: 6D'
  p_card: 3S
  which_end: right
  target_before: 7C 8D'
  target_bucket: growing
  side: left
  expect:
    primitives:
      - split [KS AS 2S 3S]@3
      - move_stack [4H' 5C' 6D'] -> (182,220)
      - merge_stack [3S] -> [4H' 5C' 6D'] /left
      - split [3S 4H' 5C' 6D']@3
      - merge_stack [6D'] -> [7C 8D'] /left

scenario mined_021_8Dp1_step_03
  desc: mined_021_8Dp1 step 3 (free_pull).
  op: verb_to_primitives
  board:
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): JH' JD' JC
    at (257, 187): 6S' 7H' 8C' 9H
    at (478, 185): 7S
    at (482, 228): 7D
    at (26, 18): KS AS 2S
    at (182, 179): 3S 4H' 5C'
    at (257, 19): 6D' 7C 8D'
  verb: free_pull
  loose: 7D
  target_before: 7S
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - merge_stack [7D] -> [7S] /right

scenario mined_021_8Dp1_step_04
  desc: mined_021_8Dp1 step 4 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): JH' JD' JC
    at (257, 187): 6S' 7H' 8C' 9H
    at (26, 18): KS AS 2S
    at (182, 179): 3S 4H' 5C'
    at (257, 19): 6D' 7C 8D'
    at (478, 185): 7S 7D
  verb: peel
  source: 2C 3D 4C 5H 6S 7H
  ext_card: 7H
  target_before: 7S 7D
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [2C 3D 4C 5H 6S 7H]@5
      - merge_stack [7H] -> [7S 7D] /right

scenario mined_022_AHp1_ADp1_step_01
  desc: mined_022_AHp1_ADp1 step 1 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (257, 52): 7S 7D 7C
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 9C TH JS
    at (182, 187): AH' AD'
  verb: steal
  source: AC AD AH
  ext_card: AC
  target_before: AH' AD'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [AC AD AH]@0
      - move_stack [AD AH] -> (332,112)
      - split [AD AH]@0
      - merge_stack [AC] -> [AH' AD'] /right

scenario mined_022_AHp1_ADp1_step_02
  desc: mined_022_AHp1_ADp1 step 2 (push).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (257, 52): 7S 7D 7C
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 9C TH JS
    at (328, 110): AD
    at (332, 153): AH
    at (182, 187): AH' AD' AC
  verb: push
  trouble_before: AD
  target_before: TD JD QD KD
  side: right
  expect:
    primitives:
      - merge_stack [AD] -> [TD JD QD KD] /right

scenario mined_022_AHp1_ADp1_step_03
  desc: mined_022_AHp1_ADp1 step 3 (push).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (182, 52): 2H 3H 4H
    at (257, 52): 7S 7D 7C
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 9C TH JS
    at (332, 153): AH
    at (182, 187): AH' AD' AC
    at (107, 52): TD JD QD KD AD
  verb: push
  trouble_before: AH
  target_before: 2H 3H 4H
  side: left
  expect:
    primitives:
      - merge_stack [AH] -> [2H 3H 4H] /left

scenario mined_023_3C_step_01
  desc: mined_023_3C step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): 9C TH JS
    at (182, 52): AH' AD' AC
    at (257, 52): TD JD QD KD AD
    at (332, 52): AH 2H 3H 4H
    at (407, 52): 7S 7D 7C 7H'
    at (482, 52): 4C 5H 6S 7H
    at (92, 187): 2C 3D 4S'
    at (167, 187): 3C
  verb: peel
  source: 4C 5H 6S 7H
  ext_card: 4C
  target_before: 3C
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [4C 5H 6S 7H]@0
      - merge_stack [4C] -> [3C] /right

scenario mined_023_3C_step_02
  desc: mined_023_3C step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): 9C TH JS
    at (182, 52): AH' AD' AC
    at (257, 52): TD JD QD KD AD
    at (332, 52): AH 2H 3H 4H
    at (407, 52): 7S 7D 7C 7H'
    at (92, 187): 2C 3D 4S'
    at (482, 93): 5H 6S 7H
    at (167, 187): 3C 4C
  verb: steal
  source: 2C 3D 4S'
  ext_card: 2C
  target_before: 3C 4C
  target_bucket: growing
  side: left
  expect:
    primitives:
      - split [2C 3D 4S']@0
      - move_stack [3C 4C] -> (167,220)
      - merge_stack [2C] -> [3C 4C] /left

scenario mined_023_3C_step_03
  desc: mined_023_3C step 3 (push).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): 9C TH JS
    at (182, 52): AH' AD' AC
    at (257, 52): TD JD QD KD AD
    at (332, 52): AH 2H 3H 4H
    at (407, 52): 7S 7D 7C 7H'
    at (482, 93): 5H 6S 7H
    at (92, 228): 3D 4S'
    at (167, 187): 2C 3C 4C
  verb: push
  trouble_before: 3D 4S'
  target_before: 5H 6S 7H
  side: left
  expect:
    primitives:
      - merge_stack [3D 4S'] -> [5H 6S 7H] /left

scenario mined_024_2D_step_01
  desc: mined_024_2D step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): KS AS 2S 3S
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (257, 52): 7S 7D 7C
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 8H 9S TH'
    at (182, 187): 9C TH JC
    at (257, 187): 2D
  verb: peel
  source: KS AS 2S 3S
  ext_card: 3S
  target_before: 2D
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [KS AS 2S 3S]@3
      - merge_stack [3S] -> [2D] /right

scenario mined_024_2D_step_02
  desc: mined_024_2D step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (257, 52): 7S 7D 7C
    at (332, 52): AC AD AH
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 8H 9S TH'
    at (182, 187): 9C TH JC
    at (26, 18): KS AS 2S
    at (257, 187): 2D 3S
  verb: steal
  source: AC AD AH
  ext_card: AC
  target_before: 2D 3S
  target_bucket: growing
  side: left
  expect:
    primitives:
      - split [AC AD AH]@0
      - move_stack [AD AH] -> (332,112)
      - split [AD AH]@0
      - move_stack [2D 3S] -> (257,220)
      - merge_stack [AC] -> [2D 3S] /left

scenario mined_024_2D_step_03
  desc: mined_024_2D step 3 (push).
  op: verb_to_primitives
  board:
    at (107, 52): TD JD QD KD
    at (182, 52): 2H 3H 4H
    at (257, 52): 7S 7D 7C
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 8H 9S TH'
    at (182, 187): 9C TH JC
    at (26, 18): KS AS 2S
    at (328, 110): AD
    at (332, 153): AH
    at (257, 187): AC 2D 3S
  verb: push
  trouble_before: AD
  target_before: TD JD QD KD
  side: right
  expect:
    primitives:
      - merge_stack [AD] -> [TD JD QD KD] /right

scenario mined_024_2D_step_04
  desc: mined_024_2D step 4 (push).
  op: verb_to_primitives
  board:
    at (182, 52): 2H 3H 4H
    at (257, 52): 7S 7D 7C
    at (407, 52): 2C 3D 4C 5H 6S 7H
    at (482, 52): 8H 9S TH'
    at (182, 187): 9C TH JC
    at (26, 18): KS AS 2S
    at (332, 153): AH
    at (257, 187): AC 2D 3S
    at (107, 52): TD JD QD KD AD
  verb: push
  trouble_before: AH
  target_before: 2H 3H 4H
  side: left
  expect:
    primitives:
      - merge_stack [AH] -> [2H 3H 4H] /left

scenario mined_025_TSp1_step_01
  desc: mined_025_TSp1 step 1 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): 2C 3D 4C 5H 6S 7H
    at (182, 52): 8H 9S TH'
    at (257, 52): 9C TH JC
    at (332, 52): KS AS 2S
    at (407, 52): AC 2D 3S
    at (482, 52): TD JD QD KD AD
    at (182, 187): AH 2H 3H
    at (257, 187): 4D 4S' 4H
    at (332, 187): TS'
  verb: peel
  source: TD JD QD KD AD
  ext_card: TD
  target_before: TS'
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - split [TD JD QD KD AD]@0
      - merge_stack [TD] -> [TS'] /right

scenario mined_025_TSp1_step_02
  desc: mined_025_TSp1 step 2 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): 2C 3D 4C 5H 6S 7H
    at (182, 52): 8H 9S TH'
    at (257, 52): 9C TH JC
    at (332, 52): KS AS 2S
    at (407, 52): AC 2D 3S
    at (182, 187): AH 2H 3H
    at (257, 187): 4D 4S' 4H
    at (482, 93): JD QD KD AD
    at (332, 187): TS' TD
  verb: steal
  source: 8H 9S TH'
  ext_card: TH'
  target_before: TS' TD
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [8H 9S TH']@2
      - merge_stack [TH'] -> [TS' TD] /right

scenario mined_025_TSp1_step_03
  desc: mined_025_TSp1 step 3 (extract_absorb/steal).
  op: verb_to_primitives
  board:
    at (26, 26): 7S 7D 7C
    at (107, 52): 2C 3D 4C 5H 6S 7H
    at (257, 52): 9C TH JC
    at (332, 52): KS AS 2S
    at (407, 52): AC 2D 3S
    at (182, 187): AH 2H 3H
    at (257, 187): 4D 4S' 4H
    at (482, 93): JD QD KD AD
    at (182, 44): 8H 9S
    at (332, 187): TS' TD TH'
  verb: steal
  source: 7S 7D 7C
  ext_card: 7C
  target_before: 8H 9S
  target_bucket: trouble
  side: left
  expect:
    primitives:
      - split [7S 7D 7C]@2
      - move_stack [7S 7D] -> (407,187)
      - split [7S 7D]@0
      - merge_stack [7C] -> [8H 9S] /left

scenario mined_025_TSp1_step_04
  desc: mined_025_TSp1 step 4 (free_pull).
  op: verb_to_primitives
  board:
    at (107, 52): 2C 3D 4C 5H 6S 7H
    at (257, 52): 9C TH JC
    at (332, 52): KS AS 2S
    at (407, 52): AC 2D 3S
    at (182, 187): AH 2H 3H
    at (257, 187): 4D 4S' 4H
    at (482, 93): JD QD KD AD
    at (332, 187): TS' TD TH'
    at (403, 185): 7S
    at (407, 228): 7D
    at (182, 11): 7C 8H 9S
  verb: free_pull
  loose: 7D
  target_before: 7S
  target_bucket: trouble
  side: right
  expect:
    primitives:
      - merge_stack [7D] -> [7S] /right

scenario mined_025_TSp1_step_05
  desc: mined_025_TSp1 step 5 (extract_absorb/peel).
  op: verb_to_primitives
  board:
    at (107, 52): 2C 3D 4C 5H 6S 7H
    at (257, 52): 9C TH JC
    at (332, 52): KS AS 2S
    at (407, 52): AC 2D 3S
    at (182, 187): AH 2H 3H
    at (257, 187): 4D 4S' 4H
    at (482, 93): JD QD KD AD
    at (332, 187): TS' TD TH'
    at (182, 11): 7C 8H 9S
    at (403, 185): 7S 7D
  verb: peel
  source: 2C 3D 4C 5H 6S 7H
  ext_card: 7H
  target_before: 7S 7D
  target_bucket: growing
  side: right
  expect:
    primitives:
      - split [2C 3D 4C 5H 6S 7H]@5
      - merge_stack [7H] -> [7S 7D] /right
