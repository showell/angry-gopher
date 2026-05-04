# physical_plan_corpus — physicalPlan integration scenarios.
#
# Each scenario specifies (initial board, hand cards for THIS play,
# plan-desc list) and pins the resulting primitive sequence. The
# runner asserts findViolation == null after each primitive applies,
# catching any geometry violation the moment it appears.
#
# These scenarios cover the integration layer (verb-to-verb
# composition + hand awareness + R3 probe). Per-verb expansion
# fixtures live in verb_to_primitives_corpus.dsl.

scenario r1a_free_pull_hand_loose
  desc: hand card 6H free-pulled onto helper run [3H 4H 5H]; direct merge_hand, no transient singleton.
  op: physical_plan
  board:
    at (100, 100): 3H 4H 5H
    at (200, 100): QC QD QH
  hand: 6H
  plan:
    - verb: free_pull
      loose: 6H
      target_before: 3H 4H 5H
      side: right
  expect:
    primitives:
      - merge_hand 6H -> [3H 4H 5H] /right

scenario r1a_free_pull_hand_loose_left
  desc: hand card 2H free-pulled onto [3H 4H 5H] on the LEFT side; direct merge_hand /left.
  op: physical_plan
  board:
    at (100, 100): 3H 4H 5H
    at (300, 200): QC QD QH
  hand: 2H
  plan:
    - verb: free_pull
      loose: 2H
      target_before: 3H 4H 5H
      side: left
  expect:
    primitives:
      - merge_hand 2H -> [3H 4H 5H] /left

scenario r1b_peel_hand_card_as_target
  desc: peel 3H from [3H 4H 5H] absorbing into hand-card-singleton 2H. R1b flip: gesture is merge_hand 2H -> [3H] /left (the side flips because P swaps from target to incoming).
  op: physical_plan
  board:
    at (100, 100): 3H 4H 5H
    at (300, 200): QC QD QH
  hand: 2H
  plan:
    - verb: peel
      source: 3H 4H 5H
      ext_card: 3H
      target_before: 2H
      target_bucket: trouble
      side: right
  expect:
    primitives:
      - split [3H 4H 5H]@0
      - merge_hand 2H -> [3H] /left

scenario r3_no_move_when_legal_room
  desc: target [KS AS 2S 3S] at (20,70) sits 20px above [TD JD QD KD] at (80,160); merge_hand QS /left grows leftward and doesn't change vertical, so legal-threshold is fine. No move_stack — Steve's bug case.
  op: physical_plan
  board:
    at (20, 70): KS AS 2S 3S
    at (80, 160): TD JD QD KD
    at (140, 100): 2H 3H 4H
    at (200, 40): 7S 7D 7C
    at (260, 130): AC AD AH
    at (320, 70): 2C 3D 4C 5H 6S 7H
  hand: QS
  plan:
    - verb: free_pull
      loose: QS
      target_before: KS AS 2S 3S
      side: left
  expect:
    primitives:
      - merge_hand QS -> [KS AS 2S 3S] /left

scenario multi_placement_graduate_set
  desc: hand cards [6H 6D 6C] form a complete 3-of-a-kind set; the solver returns these as placements with NO further verbs (the graduate is the whole play). Seeded as place_hand + merge_hand chain at a clean loc.
  op: physical_plan
  board:
    at (100, 100): 3H 4H 5H
    at (300, 100): JC QC KC
  hand: 6H 6D 6C
  plan:
  expect:
    primitives:
      - place_hand 6H -> (182,52)
      - merge_hand 6D -> [6H] /right
      - merge_hand 6C -> [6H 6D] /right
