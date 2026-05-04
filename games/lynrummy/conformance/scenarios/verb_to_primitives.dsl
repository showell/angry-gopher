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
# use the canonical SUITS="CDSH" with trailing apostrophe for deck-1.
#
# Primitive line syntax mirrors `replay_walkthroughs.dsl`:
#   - split [content]@k             — split stack at card_index k
#   - merge_stack [src] -> [tgt] /side
#   - move_stack [content] -> (top,left)
#
# Authored 2026-05-03 alongside the verbs.ts port.


scenario peel_left_edge_then_merge
  desc: Peel 5H from [5H 6H 7H 8H] right-side onto [4H]; remnant [6H 7H 8H] stays a clean run.
  op: verb_to_primitives
  board:
    at (100, 100): 5H 6H 7H 8H
    at (100, 400): 4H
  verb: peel
  source: 5H 6H 7H 8H
  ext_card: 5H
  target_before: 4H
  side: right
  expect:
    primitives:
      - split [5H 6H 7H 8H]@0
      - merge_stack [5H] -> [4H] /right


scenario pluck_interior_premoves_donor
  desc: Plucking 7H from a 5-card run forces a pre-flight move on the donor (interior splits get pre-cleared per 2026-04-23). After the first split, [7H 8H 9H] sits adjacent to [5H 6H]; a second pre-flight relocates it before the next split.
  op: verb_to_primitives
  board:
    at (100, 100): 5H 6H 7H 8H 9H
    at (100, 500): 7S
  verb: pluck
  source: 5H 6H 7H 8H 9H
  ext_card: 7H
  target_before: 7S
  side: right
  expect:
    primitives:
      - move_stack [5H 6H 7H 8H 9H] -> (92,52)
      - split [5H 6H 7H 8H 9H]@1
      - move_stack [7H 8H 9H] -> (167,52)
      - split [7H 8H 9H]@0
      - merge_stack [7H] -> [7S] /right


scenario free_pull_in_place
  desc: Free-pull of trouble singleton onto target — no geometry pre-flight needed.
  op: verb_to_primitives
  board:
    at (100, 100): KC KH
    at (100, 300): KS
  verb: free_pull
  loose: KS
  target_before: KC KH
  side: right
  expect:
    primitives:
      - merge_stack [KS] -> [KC KH] /right


scenario push_partial_in_place
  desc: Push a 2-partial onto a clean helper run — no pre-flight.
  op: verb_to_primitives
  board:
    at (100, 100): 2C 3D 4C
    at (100, 350): 5H 6S
  verb: push
  trouble_before: 5H 6S
  target_before: 2C 3D 4C
  side: right
  expect:
    primitives:
      - merge_stack [5H 6S] -> [2C 3D 4C] /right


scenario splice_run
  desc: Splice 4S into [2C 3D 4C 5H 6S] at k=2; left half + 4S becomes new piece. The 5-card source's split is interior (k=2 of n=5 → leftCount=2, neither end), so it pre-flights; the post-split left half [2C 3D] then needs another pre-flight before the merge.
  op: verb_to_primitives
  board:
    at (100, 100): 2C 3D 4C 5H 6S
    at (100, 450): 4S
  verb: splice
  loose: 4S
  source: 2C 3D 4C 5H 6S
  k: 2
  side: left
  expect:
    primitives:
      - move_stack [2C 3D 4C 5H 6S] -> (92,52)
      - split [2C 3D 4C 5H 6S]@1
      - move_stack [2C 3D] -> (167,52)
      - merge_stack [4S] -> [2C 3D] /right


scenario shift_right_end
  desc: Shift K (which wraps to A) into source's right end while popping the existing left card off, then merge that card onto target.
  op: verb_to_primitives
  board:
    at (100, 100): JH QC KC
    at (100, 350): TC TS TD
    at (100, 600): 9D
  verb: shift
  source: JH QC KC
  donor: TC TS TD
  stolen: JH
  p_card: TS
  which_end: 0
  target_before: 9D
  side: right
  expect:
    primitives:
      - split [TC TS TD]@0
      - move_stack [TS TD] -> (182,52)
      - split [TS TD]@0
      - merge_stack [TD] -> [TC] /right
      - merge_stack [TS] -> [JH QC KC] /right
      - split [JH QC KC TS]@0
      - merge_stack [JH] -> [9D] /right


scenario steal_from_partial_left
  desc: Steal AS from [AS 2S] (a length-2 partial source). Single split-at-1 separates the two cards; AS absorbs onto target.
  op: verb_to_primitives
  board:
    at (100, 100): AS 2S
    at (100, 300): AC AD
  verb: steal
  source: AS 2S
  ext_card: AS
  target_before: AC AD
  side: right
  expect:
    primitives:
      - split [AS 2S]@0
      - merge_stack [AS] -> [AC AD] /right


scenario decompose_pair
  desc: Decompose a TROUBLE pair [3H 3D] into two singletons. Single split-at-1.
  op: verb_to_primitives
  board:
    at (100, 100): 3H 3D
  verb: decompose
  pair_before: 3H 3D
  expect:
    primitives:
      - split [3H 3D]@0
