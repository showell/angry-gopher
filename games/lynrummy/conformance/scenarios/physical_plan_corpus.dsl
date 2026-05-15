# physical_plan_corpus — physicalPlan integration scenarios.
#
# Each scenario specifies (initial board, hand cards for T♥IS play,
# plan-desc list) and pins the resulting primitive sequence. The
# runner asserts findViolation == null after each primitive applies,
# catching any geometry violation the moment it appears.
#
# These scenarios cover the integration layer (verb-to-verb
# composition + hand awareness + R3 probe). Per-verb expansion
# fixtures live in verb_to_primitives_corpus.dsl.

scenario r1a_free_pull_hand_loose
  desc: hand card 6♥ free-pulled onto helper run [3♥ 4♥ 5♥]; direct merge_hand, no transient singleton.
  op: physical_plan
  board:
    at (100,100): 3♥ 4♥ 5♥
    at (100,200): Q♣ Q♦ Q♥
  hand: 6♥
  plan:
    - verb: free_pull
      loose: 6♥
      target_before: 3♥ 4♥ 5♥
      side: right
  expect:
    primitives:
      - merge_hand 6♥ -> [3♥ 4♥ 5♥] at (100,100) /right
scenario r1a_free_pull_hand_loose_left
  desc: hand card 2♥ free-pulled onto [3♥ 4♥ 5♥] on the LEFT side; direct merge_hand /left.
  op: physical_plan
  board:
    at (100,100): 3♥ 4♥ 5♥
    at (200,300): Q♣ Q♦ Q♥
  hand: 2♥
  plan:
    - verb: free_pull
      loose: 2♥
      target_before: 3♥ 4♥ 5♥
      side: left
  expect:
    primitives:
      - merge_hand 2♥ -> [3♥ 4♥ 5♥] at (100,100) /left
scenario r1b_peel_hand_card_as_target
  desc: peel 3♥ from [3♥ 4♥ 5♥] absorbing into hand-card-singleton 2♥. R1b flip: gesture is merge_hand 2♥ -> [3♥] /left (the side flips because P swaps from target to incoming).
  op: physical_plan
  board:
    at (100,100): 3♥ 4♥ 5♥
    at (200,300): Q♣ Q♦ Q♥
  hand: 2♥
  plan:
    - verb: peel
      source: 3♥ 4♥ 5♥
      ext_card: 3♥
      target_before: 2♥
      target_bucket: trouble
      side: right
  expect:
    primitives:
      - split [3♥ 4♥ 5♥] at (100,100) @0
      - merge_hand 2♥ -> [3♥] at (98,96) /left
scenario r3_no_move_when_legal_room
  desc: target [K♠ A♠ 2♠ 3♠] at (70,20) sits 20px above [T♦ J♦ Q♦ K♦] at (160,80); merge_hand Q♠ /left grows leftward and doesn't change vertical, so legal-threshold is fine. No move_stack — Steve's bug case.
  op: physical_plan
  board:
    at (70,20): K♠ A♠ 2♠ 3♠
    at (160,80): T♦ J♦ Q♦ K♦
    at (100,140): 2♥ 3♥ 4♥
    at (40,200): 7♠ 7♦ 7♣
    at (130,260): A♣ A♦ A♥
    at (70,320): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  hand: Q♠
  plan:
    - verb: free_pull
      loose: Q♠
      target_before: K♠ A♠ 2♠ 3♠
      side: left
  expect:
    primitives:
      - merge_hand Q♠ -> [K♠ A♠ 2♠ 3♠] at (70,20) /left
scenario multi_placement_graduate_set
  desc: hand cards [6♥ 6♦ 6♣] form a complete 3-of-a-kind set; the solver returns these as placements with NO further verbs (the graduate is the whole play). Seeded as place_hand + merge_hand chain at a clean loc.
  op: physical_plan
  board:
    at (100,100): 3♥ 4♥ 5♥
    at (100,300): J♣ Q♣ K♣
  hand: 6♥ 6♦ 6♣
  plan:
  expect:
    primitives:
      - place_hand 6♥ -> (52,182)
      - merge_hand 6♦ -> [6♥] at (52,182) /right
      - merge_hand 6♣ -> [6♥ 6♦] at (52,182) /right