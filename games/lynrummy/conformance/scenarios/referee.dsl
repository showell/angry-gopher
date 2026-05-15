# Referee conformance scenarios (validate_turn_complete only).
# Compiled to native Go + Elm tests.

scenario turn_complete_clean_board
  desc: Every stack on the board is a valid group (run + set, well-spaced).
  op: validate_turn_complete
  board:
    at (10,10): A♥ 2♥ 3♥
    at (200,10): K♣ K♦ K♠
  expect: ok

scenario turn_complete_rejects_incomplete
  desc: Two-card stack fine mid-turn but rejected at turn-complete.
  op: validate_turn_complete
  board:
    at (10,10): A♥ 2♥
  expect:
    kind: error
    stage: semantics
    message_contains: incomplete
