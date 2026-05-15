# verb-to-primitives conformance scenarios.
#
# Each scenario specifies (a) a starting board with positions,
# (b) a BFS verb desc (one of extract_absorb / free_pull / push /
# splice / shift / decompose), and (c) the expected primitive
# sequence emitted by `verbs.moveToPrimitives` after the
# `geometry_plan.planActions` post-pass.
#
# Coverage targets:
#   - one scenario per verb category
#   - at least one scenario per geometry-pre-flight branch
#     (interior split, merge that crowds, edge cases)
#   - the steal-from-partial vocab (length-2 source) shipped 2026-05-02
#   - decompose (engine_v2's BFS-only vocab; emits a single split)
#
# Coordinate convention: `at (top, left)` matches the established
# DSL shape (replay_walkthroughs, board_geometry, etc.). Card labels
# use the canonical SUIT♠="CDSH" with trailing apostrophe for deck-1.
#
# Primitive line syntax mirrors `replay_walkthroughs.dsl`:
#   - split [content]@k             — split stack at card_index k
#   - merge_stack [src] -> [tgt] /side
#   - move_stack [content] -> (top,left)
#
# Authored 2026-05-03 alongside the verbs.ts port.


scenario peel_left_edge_then_merge
  desc: Peel 5♥ from [5♥ 6♥ 7♥ 8♥] right-side onto [4♥]; remnant [6♥ 7♥ 8♥] stays a clean run.
  op: verb_to_primitives
  board:
    at (100,100): 5♥ 6♥ 7♥ 8♥
    at (400,100): 4♥
  verb: peel
  source: 5♥ 6♥ 7♥ 8♥
  ext_card: 5♥
  target_before: 4♥
  side: right
  expect:
    primitives:
      - split [5♥ 6♥ 7♥ 8♥] at (100,100) @0
      - merge_stack [5♥] at (98,96) -> [4♥] at (400,100) /right
scenario pluck_interior_premoves_donor
  desc: Plucking 7♥ from a 5-card run forces a pre-flight move on the donor (interior splits get pre-cleared per 2026-04-23). After the first split, [7♥ 8♥ 9♥] sits adjacent to [5♥ 6♥]; a second pre-flight relocates it before the next split.
  op: verb_to_primitives
  board:
    at (100,100): 5♥ 6♥ 7♥ 8♥ 9♥
    at (500,100): 7♠
  verb: pluck
  source: 5♥ 6♥ 7♥ 8♥ 9♥
  ext_card: 7♥
  target_before: 7♠
  side: right
  expect:
    primitives:
      - split [5♥ 6♥ 7♥ 8♥ 9♥] at (100,100) @1
      - split [7♥ 8♥ 9♥] at (174,100) @0
      - merge_stack [7♥] at (172,96) -> [7♠] at (500,100) /right
scenario free_pull_in_place
  desc: Free-pull of trouble singleton onto target — no geometry pre-flight needed.
  op: verb_to_primitives
  board:
    at (100,100): K♣ K♥
    at (300,100): K♠
  verb: free_pull
  loose: K♠
  target_before: K♣ K♥
  side: right
  expect:
    primitives:
      - merge_stack [K♠] at (300,100) -> [K♣ K♥] at (100,100) /right
scenario push_partial_in_place
  desc: Push a 2-partial onto a clean helper run — no pre-flight.
  op: verb_to_primitives
  board:
    at (100,100): 2♣ 3♦ 4♣
    at (350,100): 5♥ 6♠
  verb: push
  trouble_before: 5♥ 6♠
  target_before: 2♣ 3♦ 4♣
  side: right
  expect:
    primitives:
      - merge_stack [5♥ 6♠] at (350,100) -> [2♣ 3♦ 4♣] at (100,100) /right
scenario splice_run
  desc: Splice 4♠ into [2♣ 3♦ 4♣ 5♥ 6♠] at k=2; left half + 4♠ becomes new piece. The 5-card source's split is interior (k=2 of n=5 → leftCount=2, neither end), so it pre-flights; the post-split left half [2♣ 3♦] then needs another pre-flight before the merge.
  op: verb_to_primitives
  board:
    at (100,100): 2♣ 3♦ 4♣ 5♥ 6♠
    at (450,100): 4♠
  verb: splice
  loose: 4♠
  source: 2♣ 3♦ 4♣ 5♥ 6♠
  k: 2
  side: left
  expect:
    primitives:
      - move_stack [2♣ 3♦ 4♣ 5♥ 6♠] at (100,100) -> (52,92)
      - split [2♣ 3♦ 4♣ 5♥ 6♠] at (52,92) @1
      - move_stack [2♣ 3♦] at (50,88) -> (52,167)
      - merge_stack [4♠] at (450,100) -> [2♣ 3♦] at (52,167) /right
scenario shift_right_end
  desc: Shift K (which wraps to A) into source's right end while popping the existing left card off, then merge that card onto target.
  op: verb_to_primitives
  board:
    at (100,100): J♥ Q♣ K♣
    at (350,100): T♣ T♠ T♦
    at (600,100): 9♦
  verb: shift
  source: J♥ Q♣ K♣
  donor: T♣ T♠ T♦
  stolen: J♥
  p_card: T♠
  which_end: 0
  target_before: 9♦
  side: right
  expect:
    primitives:
      - split [T♣ T♠ T♦] at (350,100) @0
      - split [T♠ T♦] at (391,100) @0
      - move_stack [T♣] at (348,96) -> (52,182)
      - merge_stack [T♦] at (432,100) -> [T♣] at (52,182) /right
      - merge_stack [T♠] at (389,96) -> [J♥ Q♣ K♣] at (100,100) /right
      - split [J♥ Q♣ K♣ T♠] at (100,100) @0
      - merge_stack [J♥] at (98,96) -> [9♦] at (600,100) /right
scenario steal_from_partial_left
  desc: Steal A♠ from [A♠ 2♠] (a length-2 partial source). Single split-at-1 separates the two cards; A♠ absorbs onto target.
  op: verb_to_primitives
  board:
    at (100,100): A♠ 2♠
    at (300,100): A♣ A♦
  verb: steal
  source: A♠ 2♠
  ext_card: A♠
  target_before: A♣ A♦
  side: right
  expect:
    primitives:
      - split [A♠ 2♠] at (100,100) @0
      - merge_stack [A♠] at (98,96) -> [A♣ A♦] at (300,100) /right
scenario decompose_pair
  desc: Decompose a TROUBLE pair [3♥ 3♦] into two singletons. Single split-at-1.
  op: verb_to_primitives
  board:
    at (100,100): 3♥ 3♦
  verb: decompose
  pair_before: 3♥ 3♦
  expect:
    primitives:
      - split [3♥ 3♦] at (100,100) @0