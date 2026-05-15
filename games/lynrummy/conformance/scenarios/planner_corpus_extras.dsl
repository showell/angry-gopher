# Additional puzzles beyond planner_corpus.dsl, with
# unsolvable cases extra-weighted (unsolvability is
# extremely load-bearing).



scenario extra_001_J♣_J♦p
  desc: extra_001_J♣_J♦p. asserts BFS proves no plan.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): A♣ A♦ A♥
    at (0,0): 9♠' T♠ J♠
    at (0,0): 7♥' 7♣' 7♦
    at (0,0): 2♣ 3♦ 4♣ 5♥ 6♠
    at (0,0): 7♠ 7♣ 7♥
  trouble:
    at (0,0): J♣ J♦'
  expect: no_plan

scenario extra_002_J♣_J♦p
  desc: extra_002_J♣_J♦p. asserts BFS proves no plan.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): A♣ A♦ A♥
    at (0,0): 9♠' T♠ J♠
    at (0,0): 7♥' 7♣' 7♦
    at (0,0): 2♣ 3♦ 4♣ 5♥ 6♠
    at (0,0): 7♠ 7♣ 7♥
    at (0,0): 3♠' 4♦ 5♣
  trouble:
    at (0,0): J♣ J♦'
  expect: no_plan

scenario extra_003_5♦_6♣
  desc: extra_003_5♦_6♣. asserts BFS proves no plan.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): A♣ A♦ A♥
    at (0,0): 9♠' T♠ J♠
    at (0,0): 7♥' 7♣' 7♦
    at (0,0): 2♣ 3♦ 4♣ 5♥ 6♠
    at (0,0): 7♠ 7♣ 7♥
    at (0,0): 3♠' 4♦ 5♣
    at (0,0): T♦ J♦ Q♦
    at (0,0): J♦' Q♠ K♦
  trouble:
    at (0,0): 5♦ 6♣
  expect: no_plan

scenario extra_004_5♦_6♣
  desc: extra_004_5♦_6♣. asserts BFS proves no plan.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): A♣ A♦ A♥
    at (0,0): 9♠' T♠ J♠
    at (0,0): 7♥' 7♣' 7♦
    at (0,0): 7♠ 7♣ 7♥
    at (0,0): 3♠' 4♦ 5♣
    at (0,0): T♦ J♦ Q♦
    at (0,0): J♦' Q♠ K♦
    at (0,0): A♦' 2♣ 3♦ 4♣ 5♥ 6♠
  trouble:
    at (0,0): 5♦ 6♣
  expect: no_plan

scenario extra_005_J♣
  desc: extra_005_J♣. asserts BFS proves no plan.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): A♣ A♦ A♥
    at (0,0): 9♠' T♠ J♠
    at (0,0): 7♥' 7♣' 7♦
    at (0,0): 7♠ 7♣ 7♥
    at (0,0): 3♠' 4♦ 5♣
    at (0,0): T♦ J♦ Q♦
    at (0,0): J♦' Q♠ K♦
    at (0,0): A♦' 2♣ 3♦
    at (0,0): 4♣ 5♦ 6♠
    at (0,0): 2♥ 3♥ 4♥ 5♥
  trouble:
    at (0,0): J♣
  expect: no_plan

scenario extra_006_J♣
  desc: extra_006_J♣. asserts BFS proves no plan.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): A♣ A♦ A♥
    at (0,0): 9♠' T♠ J♠
    at (0,0): T♦ J♦ Q♦
    at (0,0): J♦' Q♠ K♦
    at (0,0): A♦' 2♣ 3♦
    at (0,0): 3♥ 4♥ 5♥
    at (0,0): 2♥ 3♠' 4♦
    at (0,0): 5♣ 6♣ 7♣'
    at (0,0): 4♣ 5♦ 6♠ 7♥'
    at (0,0): 7♠ 7♣ 7♥ 7♦
  trouble:
    at (0,0): J♣
  expect: no_plan

scenario extra_007_4♠_5♦p
  desc: extra_007_4♠_5♦p. asserts BFS proves no plan.
  op: solve
  helper:
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): A♣ A♦ A♥
    at (0,0): 2♣ 3♦ 4♣ 5♥
    at (0,0): 6♥ 6♦' 6♠
    at (0,0): 7♠ 7♦ 7♣ 7♥
    at (0,0): K♠ A♠ 2♠
    at (0,0): A♠' 2♠' 3♠
    at (0,0): 8♣ 9♦' T♠'
  trouble:
    at (0,0): 4♠ 5♦'
  expect: no_plan

scenario extra_008_4♠_5♦p
  desc: extra_008_4♠_5♦p. asserts BFS proves no plan.
  op: solve
  helper:
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): A♣ A♦ A♥
    at (0,0): 6♥ 6♦' 6♠
    at (0,0): K♠ A♠ 2♠
    at (0,0): A♠' 2♠' 3♠
    at (0,0): 8♣ 9♦' T♠'
    at (0,0): 2♣ 3♦ 4♣
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): 5♥ 6♥' 7♥
  trouble:
    at (0,0): 4♠ 5♦'
  expect: no_plan

scenario extra_009_K♥p
  desc: extra_009_K♥p. asserts BFS proves no plan.
  op: solve
  helper:
    at (0,0): A♣ A♦ A♥
    at (0,0): 6♥ 6♦' 6♠
    at (0,0): K♠ A♠ 2♠
    at (0,0): 2♣ 3♦ 4♣
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): T♦ J♣ Q♦
    at (0,0): 8♣ 9♦' T♠' J♦
    at (0,0): 2♠' 3♠ 4♠
    at (0,0): K♦ A♠' 2♥
    at (0,0): 3♥ 4♥ 5♥ 6♥' 7♥
  trouble:
    at (0,0): K♥'
  expect: no_plan

scenario extra_010_K♥p
  desc: extra_010_K♥p. asserts BFS proves no plan.
  op: solve
  helper:
    at (0,0): A♣ A♦ A♥
    at (0,0): 6♥ 6♦' 6♠
    at (0,0): K♠ A♠ 2♠
    at (0,0): 2♣ 3♦ 4♣
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): T♦ J♣ Q♦
    at (0,0): 2♠' 3♠ 4♠
    at (0,0): K♦ A♠' 2♥
    at (0,0): 9♦' T♠' J♦
    at (0,0): 3♥ 4♥ 5♥ 6♥'
    at (0,0): 7♥ 8♣ 9♦
  trouble:
    at (0,0): K♥'
  expect: no_plan

scenario extra_011_T♥p
  desc: extra_011_T♥p. asserts BFS proves no plan.
  op: solve
  helper:
    at (0,0): 6♥ 6♦' 6♠
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): T♦ J♣ Q♦
    at (0,0): 9♦' T♠' J♦
    at (0,0): 7♥ 8♣ 9♦
    at (0,0): K♦ A♠' 2♦
    at (0,0): K♥' A♣ 2♥
    at (0,0): A♦ 2♣ 3♦ 4♣
    at (0,0): 4♥ 5♥ 6♥'
    at (0,0): A♥ 2♠ 3♥
    at (0,0): K♠ A♠ 2♠' 3♠ 4♠
  trouble:
    at (0,0): T♥'
  expect: no_plan

scenario extra_012_T♥p
  desc: extra_012_T♥p. asserts BFS proves no plan.
  op: solve
  helper:
    at (0,0): 6♥ 6♦' 6♠
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): T♦ J♣ Q♦
    at (0,0): 9♦' T♠' J♦
    at (0,0): 7♥ 8♣ 9♦
    at (0,0): K♦ A♠' 2♦
    at (0,0): K♥' A♣ 2♥
    at (0,0): 4♥ 5♥ 6♥'
    at (0,0): A♥ 2♠ 3♥
    at (0,0): K♠ A♠ 2♠' 3♠ 4♠
    at (0,0): A♦ 2♣ 3♦ 4♣ 5♦'
  trouble:
    at (0,0): T♥'
  expect: no_plan

scenario extra_013_8♦_8♣
  desc: extra_013_8♦_8♣. asserts BFS proves no plan.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (0,0): Q♣' K♣' A♣
    at (0,0): T♦ J♦ Q♦ K♦ A♦
    at (0,0): A♥ 2♥ 3♥ 4♥
  trouble:
    at (0,0): 8♦ 8♣
  expect: no_plan

scenario extra_014_8♦_8♣
  desc: extra_014_8♦_8♣. asserts BFS proves no plan.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): Q♣' K♣' A♣
    at (0,0): T♦ J♦ Q♦ K♦ A♦
    at (0,0): A♥ 2♥ 3♥ 4♥
    at (0,0): 2♣ 3♦ 4♣ 5♥ 6♠
    at (0,0): 5♦' 6♣' 7♥
  trouble:
    at (0,0): 8♦ 8♣
  expect: no_plan

scenario extra_015_8♦_8♣
  desc: extra_015_8♦_8♣. asserts BFS proves no plan.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): Q♣' K♣' A♣
    at (0,0): A♥ 2♥ 3♥ 4♥
    at (0,0): 2♣ 3♦ 4♣ 5♥ 6♠
    at (0,0): 5♦' 6♣' 7♥
    at (0,0): J♦ Q♦ K♦ A♦
    at (0,0): T♠' T♣ T♦
  trouble:
    at (0,0): 8♦ 8♣
  expect: no_plan

scenario extra_016_7♥p_7♣p
  desc: extra_016_7♥p_7♣p.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): A♣ A♦ A♥
    at (0,0): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (0,0): 9♠' T♠ J♠
  trouble:
    at (0,0): 7♥' 7♣'
  expect:
    plan_lines:
      - "set_peel 7♦ from HELPER [7♠ 7♦ 7♣], absorb onto [7♥' 7♣'] → [7♥' 7♣' 7♦] [→COMPLETE] ; spawn [7♠ 7♣]"
      - "peel 7♥ from HELPER [2♣ 3♦ 4♣ 5♥ 6♠ 7♥], absorb onto [7♠ 7♣] → [7♥ 7♠ 7♣] [→COMPLETE]"

scenario extra_017_6♥_6♦p
  desc: extra_017_6♥_6♦p.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): A♣ A♦ A♥
    at (0,0): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  trouble:
    at (0,0): 6♥ 6♦'
  expect:
    plan_lines:
      - "yank 6♠ from HELPER [2♣ 3♦ 4♣ 5♥ 6♠ 7♥], absorb onto [6♥ 6♦'] → [6♥ 6♦' 6♠] [→COMPLETE] ; spawn [7♥]"
      - "push [7♥] onto HELPER [7♠ 7♦ 7♣] → [7♠ 7♦ 7♣ 7♥]"

scenario extra_018_A♠p_2♠p
  desc: extra_018_A♠p_2♠p.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): A♣ A♦ A♥
    at (0,0): 2♣ 3♦ 4♣ 5♥
    at (0,0): 6♥ 6♦' 6♠
    at (0,0): 7♠ 7♦ 7♣ 7♥
  trouble:
    at (0,0): A♠' 2♠'
  expect:
    plan_lines:
      - "peel 3♠ from HELPER [K♠ A♠ 2♠ 3♠], absorb onto [A♠' 2♠'] → [A♠' 2♠' 3♠] [→COMPLETE]"

scenario extra_019_J♣
  desc: extra_019_J♣.
  op: solve
  helper:
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): A♣ A♦ A♥
    at (0,0): 6♥ 6♦' 6♠
    at (0,0): K♠ A♠ 2♠
    at (0,0): 8♣ 9♦' T♠'
    at (0,0): 2♣ 3♦ 4♣
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): 5♥ 6♥' 7♥
    at (0,0): A♠' 2♠' 3♠ 4♠
  trouble:
    at (0,0): J♣
  expect: no_plan

scenario extra_020_K♥p
  desc: extra_020_K♥p.
  op: solve
  helper:
    at (0,0): A♣ A♦ A♥
    at (0,0): 6♥ 6♦' 6♠
    at (0,0): K♠ A♠ 2♠
    at (0,0): 2♣ 3♦ 4♣
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): T♦ J♣ Q♦
    at (0,0): 2♠' 3♠ 4♠
    at (0,0): 9♦' T♠' J♦
    at (0,0): 7♥ 8♣ 9♦
    at (0,0): K♦ A♠' 2♦
    at (0,0): 2♥ 3♥ 4♥ 5♥ 6♥'
  trouble:
    at (0,0): K♥'
  expect: no_plan

scenario extra_021_2♦
  desc: extra_021_2♦.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): A♥ 2♥ 3♥ 4♥
    at (0,0): 5♦' 6♣' 7♥
    at (0,0): J♦ Q♦ K♦ A♦
    at (0,0): T♠' T♣ T♦
    at (0,0): 3♦ 4♣ 5♥ 6♠
    at (0,0): K♣' A♣ 2♣
    at (0,0): Q♥' Q♠' Q♣'
  trouble:
    at (0,0): 2♦
  expect:
    plan_lines:
      - "push [2♦] onto HELPER [J♦ Q♦ K♦ A♦] → [J♦ Q♦ K♦ A♦ 2♦]"

scenario extra_022_3♥p
  desc: extra_022_3♥p.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): A♥ 2♥ 3♥ 4♥
    at (0,0): 5♦' 6♣' 7♥
    at (0,0): T♠' T♣ T♦
    at (0,0): 3♦ 4♣ 5♥ 6♠
    at (0,0): K♣' A♣ 2♣
    at (0,0): Q♥' Q♠' Q♣'
    at (0,0): J♦ Q♦ K♦ A♦ 2♦
  trouble:
    at (0,0): 3♥'
  expect:
    plan_lines:
      - "peel 3♦ from HELPER [3♦ 4♣ 5♥ 6♠], absorb onto [3♥'] → [3♥' 3♦]"
      - "peel 3♠ from HELPER [K♠ A♠ 2♠ 3♠], absorb onto [3♥' 3♦] → [3♠ 3♥' 3♦] [→COMPLETE]"

scenario extra_023_T♣p
  desc: extra_023_T♣p.
  op: solve
  helper:
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): A♥ 2♥ 3♥ 4♥
    at (0,0): 5♦' 6♣' 7♥
    at (0,0): T♠' T♣ T♦
    at (0,0): K♣' A♣ 2♣
    at (0,0): Q♥' Q♠' Q♣'
    at (0,0): J♦ Q♦ K♦ A♦ 2♦
    at (0,0): 4♣ 5♥ 6♠
    at (0,0): K♠ A♠ 2♠
    at (0,0): 3♥' 3♦ 3♠
  trouble:
    at (0,0): T♣'
  expect:
    plan_lines:
      - "peel J♦ from HELPER [J♦ Q♦ K♦ A♦ 2♦], absorb onto [T♣'] → [T♣' J♦]"
      - "set_peel Q♣' from HELPER [Q♥' Q♠' Q♣'], absorb onto [T♣' J♦] → [T♣' J♦ Q♣'] [→COMPLETE] ; spawn [Q♥' Q♠']"
      - "peel Q♦ from HELPER [Q♦ K♦ A♦ 2♦], absorb onto [Q♥' Q♠'] → [Q♦ Q♥' Q♠'] [→COMPLETE]"

scenario extra_024_2♣p
  desc: extra_024_2♣p.
  op: solve
  helper:
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): A♥ 2♥ 3♥ 4♥
    at (0,0): 5♦' 6♣' 7♥
    at (0,0): T♠' T♣ T♦
    at (0,0): K♣' A♣ 2♣
    at (0,0): 4♣ 5♥ 6♠
    at (0,0): K♠ A♠ 2♠
    at (0,0): 3♥' 3♦ 3♠
    at (0,0): T♣' J♦ Q♣'
    at (0,0): K♦ A♦ 2♦
    at (0,0): Q♥' Q♠' Q♦
  trouble:
    at (0,0): 2♣'
  expect:
    plan_lines:
      - "peel A♥ from HELPER [A♥ 2♥ 3♥ 4♥], absorb onto [2♣'] → [A♥ 2♣']"
      - "steal 3♥' from HELPER [3♥' 3♦ 3♠], absorb onto [A♥ 2♣'] → [A♥ 2♣' 3♥'] [→COMPLETE] ; spawn [3♦], [3♠]"
      - "push [3♦] onto HELPER [4♣ 5♥ 6♠] → [3♦ 4♣ 5♥ 6♠]"
      - "push [3♠] onto HELPER [K♠ A♠ 2♠] → [K♠ A♠ 2♠ 3♠]"

scenario extra_025_8♣
  desc: extra_025_8♣.
  op: solve
  helper:
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): 5♦' 6♣' 7♥
    at (0,0): T♠' T♣ T♦
    at (0,0): K♣' A♣ 2♣
    at (0,0): T♣' J♦ Q♣'
    at (0,0): K♦ A♦ 2♦
    at (0,0): Q♥' Q♠' Q♦
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): A♥ 2♣' 3♦
    at (0,0): 3♥' 4♣ 5♥ 6♠
    at (0,0): K♠ A♠ 2♠ 3♠
  trouble:
    at (0,0): 8♣
  expect:
    plan_lines:
      - "push [8♣] onto HELPER [5♦' 6♣' 7♥] → [5♦' 6♣' 7♥ 8♣]"

# Hand-added 2026-04-30: game 17 initial board, singleton projections.
# Benchmarks the "live-but-hard" slow class for SOLVER_SPEED work.
# Board is the standard opening deal (6 helpers, all clean).
# All three cards are theoretically live (valid group exists in pool)
# but no plan exists on this specific board \u2014 BFS exhausts all caps.

scenario extra_026_2♠p
  desc: Game 17 board, trouble 2♠'. Live singleton, no plan. SOLVER_SPEED benchmark.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): A♣ A♦ A♥
    at (0,0): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  trouble:
    at (0,0): 2♠'
  expect: no_plan

scenario extra_027_3♥p
  desc: Game 17 board, trouble 3♥'. Live singleton, no plan. SOLVER_SPEED benchmark.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): A♣ A♦ A♥
    at (0,0): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  trouble:
    at (0,0): 3♥'
  expect: no_plan

scenario extra_028_K♦p
  desc: Game 17 board, trouble K♦'. Live singleton, no plan. SOLVER_SPEED benchmark.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): A♣ A♦ A♥
    at (0,0): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  trouble:
    at (0,0): K♦'
  expect: no_plan
