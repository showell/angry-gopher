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
#   - decompose (engine_v2's BFS-only vocab; emits a single isolate)
#
# Coordinate convention: `at (top, left)` matches the established
# DSL shape (replay_walkthroughs, board_geometry, etc.). Card labels
# use the canonical SUIT♠="CDSH" with trailing apostrophe for deck-1.
#
# Primitive line syntax mirrors `replay_walkthroughs.dsl`:
#   - split <left-cards> / <right-cards> at (left,top)
#   - isolate <before-cards> ( <held-card> ) <after-cards> at (left,top)
#   - merge_stack [src] at (l,t) -> [tgt] at (l,t) /side
#   - move_stack [content] at (l,t) -> (left,top)
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
      - isolate ( 5♥ ) 6♥ 7♥ 8♥ at (100,100)
      - merge_stack [5♥] at (100,100) -> [4♥] at (400,100) /right :: path (100,100@0)(100,100@44)(103,100@88)(110,100@132)(122,100@176)(139,100@220)(162,100@264)(189,99@309)(219,99@353)(251,99@397)(284,99@441)(316,99@485)(346,99@529)(373,98@573)(396,98@617)(413,98@661)(425,98@705)(432,98@749)(435,98@793)(435,98@838)
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
      - isolate 5♥ 6♥ ( 7♥ ) 8♥ 9♥ at (100,100)
      - merge_stack [7♥] at (166,100) -> [7♠] at (500,100) /right :: path (166,100@0)(166,100@49)(170,100@97)(177,100@146)(190,100@194)(209,100@243)(234,100@291)(264,99@340)(297,99@388)(332,99@437)(369,99@486)(404,99@534)(437,99@583)(467,98@631)(492,98@680)(511,98@728)(524,98@777)(531,98@825)(535,98@874)(535,98@923)
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
      - split 2♣ 3♦ / 4♣ 5♥ 6♠ at (52,92)
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
      - isolate T♣ ( T♠ ) T♦ at (350,100)
      - move_stack [T♣] at (348,100) -> (52,182) :: path (348,100@0)(348,100@40)(345,101@81)(339,103@121)(328,105@162)(313,110@202)(293,115@242)(270,122@283)(243,129@323)(215,137@364)(185,145@404)(157,153@445)(130,160@485)(107,167@525)(87,172@566)(72,177@606)(61,179@647)(55,181@687)(52,182@727)(52,182@768)
      - merge_stack [T♦] at (418,100) -> [T♣] at (52,182) /right :: path (418,100@0)(418,100@45)(415,101@90)(408,102@134)(396,105@179)(379,109@224)(357,115@269)(330,121@314)(301,128@358)(269,136@403)(236,144@448)(204,152@493)(175,159@538)(148,165@582)(126,171@627)(109,175@672)(97,178@717)(90,179@762)(87,180@807)(87,180@851)
      - merge_stack [T♠] at (383,100) -> [J♥ Q♣ K♣] at (100,100) /right :: path (383,100@0)(383,100@24)(381,100@48)(377,100@72)(371,100@96)(362,100@120)(349,100@144)(335,99@168)(318,99@192)(301,99@216)(283,99@239)(266,99@263)(249,99@287)(235,98@311)(222,98@335)(213,98@359)(207,98@383)(203,98@407)(201,98@431)(201,98@455)
      - isolate ( J♥ ) Q♣ K♣ T♠ at (100,100)
      - merge_stack [J♥] at (100,100) -> [9♦] at (600,100) /right :: path (100,100@0)(101,100@70)(105,100@141)(116,100@211)(135,100@282)(163,100@352)(199,100@422)(241,99@493)(290,99@563)(341,99@634)(394,99@704)(445,99@774)(494,99@845)(536,98@915)(572,98@986)(600,98@1056)(619,98@1126)(630,98@1197)(634,98@1267)(635,98@1338)
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
      - isolate ( A♠ ) 2♠ at (100,100)
      - merge_stack [A♠] at (100,100) -> [A♣ A♦] at (300,100) /right :: path (100,100@0)(100,100@35)(103,100@71)(108,100@106)(118,100@141)(132,100@176)(149,100@212)(171,99@247)(195,99@282)(221,99@317)(247,99@353)(273,99@388)(297,99@423)(319,98@458)(336,98@494)(350,98@529)(360,98@564)(365,98@599)(368,98@635)(368,98@670)
scenario decompose_pair
  desc: Decompose a TROUBLE pair [3♥ 3♦] into two singletons. Single split-at-1.
  op: verb_to_primitives
  board:
    at (100,100): 3♥ 3♦
  verb: decompose
  pair_before: 3♥ 3♦
  expect:
    primitives:
      - isolate ( 3♥ ) 3♦ at (100,100)