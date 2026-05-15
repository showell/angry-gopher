# Seed 42, 7-card hands.

scenario turn_1_hint
  op: hint_for_hand
  hand: 3♠' 4♠ 8♦' J♦' 4♣' 6♦ Q♦'
  board:
    - K♠ A♠ 2♠ 3♠
    - T♦ J♦ Q♦ K♦
    - 2♥ 3♥ 4♥
    - 7♠ 7♦ 7♣
    - A♣ A♦ A♥
    - 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
  expect_steps:
    - place [J♦' Q♦'] from hand
    - peel T♦ from HELPER [T♦ J♦ Q♦ K♦], absorb onto [J♦' Q♦'] → [T♦ J♦' Q♦'] [→COMPLETE]

scenario turn_2_hint
  op: hint_for_hand
  hand: 3♠' 4♠ 8♦' 4♣' 6♦ 8♥ J♠'
  board:
    - K♠ A♠ 2♠ 3♠
    - T♦ J♦ Q♦ K♦
    - 2♥ 3♥ 4♥
    - 7♠ 7♦ 7♣
    - A♣ A♦ A♥
    - 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    - J♦' Q♦'
  expect_steps:
    - place [4♠] from hand
    - peel T♦ from HELPER [T♦ J♦ Q♦ K♦], absorb onto [J♦' Q♦'] → [T♦ J♦' Q♦'] [→COMPLETE]
    - push [4♠] onto HELPER [K♠ A♠ 2♠ 3♠] → [K♠ A♠ 2♠ 3♠ 4♠]

scenario turn_3_hint
  op: hint_for_hand
  hand: 3♠' 8♦' 4♣' 6♦ 8♥ J♠' 2♠' 2♦'
  board:
    - K♠ A♠ 2♠ 3♠
    - T♦ J♦ Q♦ K♦
    - 2♥ 3♥ 4♥
    - 7♠ 7♦ 7♣
    - A♣ A♦ A♥
    - 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
    - J♦' Q♦'
    - 4♠
  expect_steps:
    - place [2♠' 3♠'] from hand
    - peel T♦ from HELPER [T♦ J♦ Q♦ K♦], absorb onto [J♦' Q♦'] → [T♦ J♦' Q♦'] [→COMPLETE]
    - pull 4♠ onto [2♠' 3♠'] → [2♠' 3♠' 4♠] [→COMPLETE]
