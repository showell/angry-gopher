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
    - play 4♠ from hand onto K♠ A♠ 2♠ 3♠

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
    - peel T♦ from T♦ J♦ Q♦ K♦ onto J♦ Q♦
    - play 4♠ from hand onto K♠ A♠ 2♠ 3♠

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
    - peel K♦ from T♦ J♦ Q♦ K♦ onto J♦ Q♦
    - push 4♠ onto K♠ A♠ 2♠ 3♠
    - splice 4♣ from hand into 2♣ 3♦ 4♣ 5♥ 6♠ 7♥
