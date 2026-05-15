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
      - merge_stack [5♥] at (98,96) -> [4♥] at (400,100) /right :: path (98,96@0)(98,96@44)(101,96@89)(108,96@133)(120,96@177)(138,96@222)(160,96@266)(187,97@310)(217,97@355)(250,97@399)(283,97@443)(316,97@488)(346,97@532)(373,98@576)(395,98@621)(413,98@665)(425,98@709)(432,98@754)(435,98@798)(435,98@843)
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
      - merge_stack [7♥] at (172,96) -> [7♠] at (500,100) /right :: path (172,96@0)(172,96@48)(176,96@96)(183,96@143)(196,96@191)(215,96@239)(239,96@287)(268,97@334)(301,97@382)(336,97@430)(371,97@478)(406,97@525)(439,97@573)(468,98@621)(492,98@669)(511,98@716)(524,98@764)(531,98@812)(535,98@860)(535,98@908)
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
      - merge_stack [K♠] at (300,100) -> [K♣ K♥] at (100,100) /right :: path (300,100@0)(300,100@17)(299,100@35)(296,100@52)(291,100@69)(284,100@87)(276,100@104)(265,99@122)(253,99@139)(241,99@156)(227,99@174)(215,99@191)(203,99@208)(192,98@226)(184,98@243)(177,98@261)(172,98@278)(169,98@295)(168,98@313)(168,98@330)
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
      - merge_stack [5♥ 6♠] at (350,100) -> [2♣ 3♦ 4♣] at (100,100) /right :: path (350,100@0)(350,100@20)(349,100@39)(345,100@59)(340,100@78)(332,100@98)(322,100@118)(311,99@137)(297,99@157)(283,99@176)(268,99@196)(254,99@216)(240,99@235)(229,98@255)(219,98@274)(211,98@294)(206,98@314)(202,98@333)(201,98@353)(201,98@373)
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
      - move_stack [2♣ 3♦ 4♣ 5♥ 6♠] at (100,100) -> (52,92) :: path (100,100@0)(100,100@6)(100,100@13)(99,100@19)(97,99@26)(94,99@32)(91,99@38)(87,98@45)(83,97@51)(78,96@58)(74,96@64)(69,95@70)(65,94@77)(61,93@83)(58,93@90)(55,93@96)(53,92@102)(52,92@109)(52,92@115)(52,92@122)
      - split [2♣ 3♦ 4♣ 5♥ 6♠] at (52,92) @1
      - move_stack [2♣ 3♦] at (50,88) -> (52,167) :: path (50,88@0)(50,88@10)(50,89@21)(50,90@31)(50,93@42)(50,97@52)(50,103@62)(51,109@73)(51,116@83)(51,124@94)(51,131@104)(51,139@114)(51,146@125)(52,152@135)(52,158@146)(52,162@156)(52,165@166)(52,166@177)(52,167@187)(52,167@198)
      - merge_stack [4♠] at (450,100) -> [2♣ 3♦] at (52,167) /right :: path (450,100@0)(450,100@44)(447,101@89)(440,102@133)(428,104@177)(411,108@221)(389,112@266)(363,117@310)(333,123@354)(301,129@398)(269,136@443)(237,142@487)(207,148@531)(181,153@575)(159,157@620)(142,161@664)(130,163@708)(123,164@752)(120,165@797)(120,165@841)
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
      - move_stack [T♣] at (348,96) -> (52,182) :: path (348,96@0)(348,96@41)(345,97@81)(339,99@122)(328,102@162)(313,106@203)(293,112@243)(270,119@284)(243,126@324)(215,135@365)(185,143@406)(157,152@446)(130,159@487)(107,166@527)(87,172@568)(72,176@608)(61,179@649)(55,181@689)(52,182@730)(52,182@771)
      - merge_stack [T♦] at (432,100) -> [T♣] at (52,182) /right :: path (432,100@0)(432,100@47)(429,101@93)(421,102@140)(409,105@186)(391,109@233)(368,115@280)(341,121@326)(310,128@373)(276,136@419)(243,144@466)(209,152@513)(178,159@559)(151,165@606)(128,171@652)(110,175@699)(98,178@746)(90,179@792)(87,180@839)(87,180@885)
      - merge_stack [T♠] at (389,96) -> [J♥ Q♣ K♣] at (100,100) /right :: path (389,96@0)(389,96@25)(387,96@49)(383,96@74)(377,96@99)(367,96@124)(354,96@148)(339,97@173)(322,97@198)(304,97@223)(286,97@247)(268,97@272)(251,97@297)(236,98@322)(223,98@346)(213,98@371)(207,98@396)(203,98@421)(201,98@445)(201,98@470)
      - split [J♥ Q♣ K♣ T♠] at (100,100) @0
      - merge_stack [J♥] at (98,96) -> [9♦] at (600,100) /right :: path (98,96@0)(99,96@71)(103,96@141)(114,96@212)(134,96@283)(161,96@353)(197,96@424)(240,97@495)(288,97@565)(340,97@636)(393,97@707)(445,97@777)(493,97@848)(536,98@919)(572,98@989)(599,98@1060)(619,98@1131)(630,98@1201)(634,98@1272)(635,98@1343)
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
      - merge_stack [A♠] at (98,96) -> [A♣ A♦] at (300,100) /right :: path (98,96@0)(98,96@36)(101,96@71)(106,96@107)(116,96@142)(130,96@178)(148,96@213)(169,97@249)(194,97@284)(220,97@320)(246,97@355)(272,97@391)(297,97@426)(318,98@462)(336,98@497)(350,98@533)(360,98@568)(365,98@604)(368,98@639)(368,98@675)
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