# Each scenario is one mined Puzzles puzzle's initial state;
# asserts that BFS solve produces a plan of the expected length.



scenario mined_mined_001_2♥p1
  desc: Mined puzzle mined_001_2♥p1.
  op: solve
  helper:
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): A♣ A♦ A♥
    at (0,0): K♠ A♠ 2♠
    at (0,0): A♠' 2♦ 3♠
    at (0,0): J♥ Q♥' K♥
    at (0,0): 4♠' 5♦' 6♠'
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 8♠' 9♦ T♠
    at (0,0): 4♣ 5♥ 6♠ 7♥
    at (0,0): 2♣ 3♦ 4♠
  trouble:
    at (0,0): 2♥'
  expect:
    plan_lines:
      - "steal A♣ from HELPER [A♣ A♦ A♥], absorb onto [2♥'] → [A♣ 2♥'] ; spawn [A♦], [A♥]"
      - "push [A♦] onto HELPER [2♣ 3♦ 4♠] → [A♦ 2♣ 3♦ 4♠]"
      - "push [A♥] onto HELPER [2♥ 3♥ 4♥] → [A♥ 2♥ 3♥ 4♥]"
      - "shift K♦ to pop 3♠ [T♦ J♦ Q♦ -> K♦ + A♠' 2♦]; absorb onto [A♣ 2♥'] → [A♣ 2♥' 3♠] [→COMPLETE]"

scenario mined_mined_002_5♦_5♣
  desc: Mined puzzle mined_002_5♦_5♣.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): A♣ A♦ A♥
    at (0,0): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (0,0): 3♣' 4♦ 5♣'
    at (0,0): 8♥ 8♣ 8♦'
    at (0,0): 7♥' 8♠ 9♦
  trouble:
    at (0,0): 5♦ 5♣
  expect:
    plan_lines:
      - "yank 5♥ from HELPER [2♣ 3♦ 4♣ 5♥ 6♠ 7♥], absorb onto [5♦ 5♣] → [5♦ 5♣ 5♥] [→COMPLETE] ; spawn [6♠ 7♥]"
      - "split_out 8♠ from HELPER [7♥' 8♠ 9♦], absorb onto [6♠ 7♥] → [6♠ 7♥ 8♠] [→COMPLETE] ; spawn [7♥'], [9♦]"
      - "push [7♥'] onto HELPER [7♠ 7♦ 7♣] → [7♥' 7♠ 7♦ 7♣]"
      - "push [9♦] onto HELPER [T♦ J♦ Q♦ K♦] → [9♦ T♦ J♦ Q♦ K♦]"

scenario mined_mined_003_J♣p1
  desc: Mined puzzle mined_003_J♣p1.
  op: solve
  helper:
    at (0,0): 8♥ 8♣ 8♦'
    at (0,0): 5♦ 5♣ 5♥
    at (0,0): 6♠ 7♥ 8♠
    at (0,0): 7♠ 7♦ 7♣ 7♥'
    at (0,0): 9♦ T♦ J♦ Q♦ K♦
    at (0,0): A♦ 2♠' 3♥
    at (0,0): K♠ A♠ 2♠
    at (0,0): A♣ 2♥ 3♣' 4♦
    at (0,0): A♥ 2♣ 3♦ 4♣
    at (0,0): 3♠ 4♥ 5♣' 6♥'
  trouble:
    at (0,0): J♣'
  expect:
    plan_lines:
      - "yank Q♦ from HELPER [9♦ T♦ J♦ Q♦ K♦], absorb onto [J♣'] → [J♣' Q♦] ; spawn [K♦]"
      - "push [K♦] onto HELPER [A♣ 2♥ 3♣' 4♦] → [K♦ A♣ 2♥ 3♣' 4♦]"
      - "shift 3♠ to pop K♠ [4♥ 5♣' 6♥' -> A♠ 2♠ + 3♠]; absorb onto [J♣' Q♦] → [J♣' Q♦ K♠] [→COMPLETE]"

scenario mined_mined_004_6♥
  desc: Mined puzzle mined_004_6♥.
  op: solve
  helper:
    at (0,0): 8♥ 8♣ 8♦'
    at (0,0): 5♦ 5♣ 5♥
    at (0,0): 6♠ 7♥ 8♠
    at (0,0): 7♠ 7♦ 7♣ 7♥'
    at (0,0): A♦ 2♠' 3♥
    at (0,0): A♥ 2♣ 3♦ 4♣
    at (0,0): 9♦ T♦ J♦
    at (0,0): 4♥ 5♣' 6♥'
    at (0,0): A♠ 2♠ 3♠
    at (0,0): J♣' Q♦ K♠
    at (0,0): K♦ A♣ 2♥ 3♣' 4♦
  trouble:
    at (0,0): 6♥
  expect:
    plan_lines:
      - "steal 5♥ from HELPER [5♦ 5♣ 5♥], absorb onto [6♥] → [5♥ 6♥] ; spawn [5♦], [5♣]"
      - "push [5♦] onto HELPER [6♠ 7♥ 8♠] → [5♦ 6♠ 7♥ 8♠]"
      - "push [5♣] onto HELPER [K♦ A♣ 2♥ 3♣' 4♦] → [K♦ A♣ 2♥ 3♣' 4♦ 5♣]"
      - "peel 7♥' from HELPER [7♠ 7♦ 7♣ 7♥'], absorb onto [5♥ 6♥] → [5♥ 6♥ 7♥'] [→COMPLETE]"

scenario mined_mined_005_7♣p1_7♥p1
  desc: Mined puzzle mined_005_7♣p1_7♥p1.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): 7♠ 7♦ 7♣
    at (0,0): A♣ A♦ A♥
    at (0,0): 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    at (0,0): K♥' K♦' K♣'
  trouble:
    at (0,0): 7♣' 7♥'
  expect:
    plan_lines:
      - "set_peel 7♦ from HELPER [7♠ 7♦ 7♣], absorb onto [7♣' 7♥'] → [7♣' 7♥' 7♦] [→COMPLETE] ; spawn [7♠ 7♣]"
      - "peel 7♥ from HELPER [2♣ 3♦ 4♣ 5♥ 6♠ 7♥], absorb onto [7♠ 7♣] → [7♥ 7♠ 7♣] [→COMPLETE]"

scenario mined_mined_006_2♣p1
  desc: Mined puzzle mined_006_2♣p1.
  op: solve
  helper:
    at (0,0): K♠ A♠ 2♠ 3♠
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 2♥ 3♥ 4♥
    at (0,0): A♣ A♦ A♥
    at (0,0): 4♠ 5♦ 6♣
    at (0,0): 2♣ 3♦ 4♣ 5♥
    at (0,0): 6♦ 6♣' 6♠
    at (0,0): 7♠ 7♦ 7♣ 7♥
  trouble:
    at (0,0): 2♣'
  expect:
    plan_lines:
      - "split_out 3♥ from HELPER [2♥ 3♥ 4♥], absorb onto [2♣'] → [2♣' 3♥] ; spawn [2♥], [4♥]"
      - "peel 3♠ from HELPER [K♠ A♠ 2♠ 3♠], absorb onto [2♥] → [2♥ 3♠]"
      - "pull 4♥ onto [2♥ 3♠] → [2♥ 3♠ 4♥] [→COMPLETE]"
      - "shift 7♦ to pop 4♠ [7♠ 7♣ 7♥ -> 5♦ 6♣ + 7♦]; absorb onto [2♣' 3♥] → [2♣' 3♥ 4♠] [→COMPLETE]"

scenario mined_mined_007_4♦
  desc: Mined puzzle mined_007_4♦.
  op: solve
  helper:
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): A♣ A♦ A♥
    at (0,0): 2♣ 3♦ 4♣ 5♥
    at (0,0): 6♦ 6♣' 6♠
    at (0,0): 7♠ 7♣ 7♥
    at (0,0): 5♦ 6♣ 7♦
    at (0,0): 2♣' 3♥ 4♠
    at (0,0): K♠ A♠ 2♠
    at (0,0): 2♥ 3♠ 4♥
  trouble:
    at (0,0): 4♦
  expect:
    plan_lines:
      - "steal 4♥ from HELPER [2♥ 3♠ 4♥], absorb onto [4♦] → [4♦ 4♥] ; spawn [2♥ 3♠]"
      - "steal A♣ from HELPER [A♣ A♦ A♥], absorb onto [2♥ 3♠] → [A♣ 2♥ 3♠] [→COMPLETE] ; spawn [A♦], [A♥]"
      - "steal 4♠ from HELPER [2♣' 3♥ 4♠], absorb onto [4♦ 4♥] → [4♠ 4♦ 4♥] [→COMPLETE] ; spawn [2♣' 3♥]"
      - "pull A♦ onto [2♣' 3♥] → [A♦ 2♣' 3♥] [→COMPLETE]"
      - "push [A♥] onto HELPER [2♣ 3♦ 4♣ 5♥] → [A♥ 2♣ 3♦ 4♣ 5♥]"

scenario mined_mined_008_Q♦p1
  desc: Mined puzzle mined_008_Q♦p1.
  op: solve
  helper:
    at (0,0): T♦ J♦ Q♦ K♦
    at (0,0): 6♦ 6♣' 6♠
    at (0,0): 7♠ 7♣ 7♥
    at (0,0): 5♦ 6♣ 7♦
    at (0,0): K♠ A♠ 2♠
    at (0,0): 4♦ 4♠ 4♥
    at (0,0): A♦ 2♣' 3♥
    at (0,0): A♥ 2♣ 3♦ 4♣ 5♥
    at (0,0): K♥' A♣ 2♥ 3♠ 4♦'
  trouble:
    at (0,0): Q♦'
  expect:
    plan_lines:
      - "peel K♦ from HELPER [T♦ J♦ Q♦ K♦], absorb onto [Q♦'] → [Q♦' K♦]"
      - "steal A♦ from HELPER [A♦ 2♣' 3♥], absorb onto [Q♦' K♦] → [Q♦' K♦ A♦] [→COMPLETE] ; spawn [2♣' 3♥]"
      - "peel A♥ from HELPER [A♥ 2♣ 3♦ 4♣ 5♥], absorb onto [2♣' 3♥] → [A♥ 2♣' 3♥] [→COMPLETE]"

