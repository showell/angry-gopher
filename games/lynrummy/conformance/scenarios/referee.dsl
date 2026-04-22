# Referee conformance scenarios (validate_game_move +
# validate_turn_complete). Compiled to native Go + Elm tests.

scenario valid_extend_run_with_8H
  desc: Player extends a 5H-6H-7H run by playing 8H from hand.
  op: validate_game_move
  board_before:
    at (10,10): 5H 6H 7H
  stacks_to_remove:
    at (10,10): 5H 6H 7H
  stacks_to_add:
    at (10,10): 5H 6H 7H 8H*
  hand_cards_played: 8H
  expect: ok

scenario midturn_allows_bogus
  desc: Mid-turn boards may contain incomplete/bogus stacks; ValidateGameMove doesn't check semantics.
  op: validate_game_move
  board_before:
  stacks_to_remove:
  stacks_to_add:
    at (10,10): AH* 5C* KD*
  hand_cards_played: AH 5C KD
  expect: ok

scenario inventory_card_from_nowhere
  desc: Player adds cards to the board that weren't in removed stacks or declared hand.
  op: validate_game_move
  board_before:
  stacks_to_remove:
  stacks_to_add:
    at (10,10): AH* 2H* 3H*
  hand_cards_played: AH 2H
  expect: error
    stage: inventory
    message_contains: no source

scenario turn_complete_clean_board
  desc: Every stack on the board is a valid group (run + set, well-spaced).
  op: validate_turn_complete
  board:
    at (10,10): AH 2H 3H
    at (10,200): KC KD KS
  expect: ok

scenario turn_complete_rejects_incomplete
  desc: Two-card stack fine mid-turn but rejected at turn-complete.
  op: validate_turn_complete
  board:
    at (10,10): AH 2H
  expect: error
    stage: semantics
    message_contains: incomplete

scenario geometry_out_of_bounds
  desc: Stack whose right edge exceeds MaxWidth is rejected.
  op: validate_game_move
  board_before:
  stacks_to_remove:
  stacks_to_add:
    at (10,790): AH*
  hand_cards_played: AH
  expect: error
    stage: geometry
    message_contains: outside

scenario geometry_overlap
  desc: Two stacks at the same coordinates actually overlap.
  op: validate_game_move
  board_before:
  stacks_to_remove:
  stacks_to_add:
    at (10,10): AH*
    at (10,10): 2S*
  hand_cards_played: AH 2S
  expect: error
    stage: geometry
    message_contains: overlap

scenario deck_identity_mismatch_in_remove
  desc: Client's stacks_to_remove has the wrong originDeck; must not match the board stack (fabrication guard).
  op: validate_game_move
  board_before:
    at (10,10): 5H 6H 7H
  stacks_to_remove:
    at (10,10): 5H' 6H' 7H'
  stacks_to_add:
    at (10,10): 5H' 6H' 7H' 8H'*
  hand_cards_played: 8H'
  expect: error
    stage: inventory
    message_contains: not on the board

scenario geometry_crowded
  desc: Two stacks within BoardBounds.margin (5px) but not overlapping.
  op: validate_game_move
  board_before:
  stacks_to_remove:
  stacks_to_add:
    at (10,10): AH*
    at (10,40): 2S*
  hand_cards_played: AH 2S
  expect: error
    stage: geometry
    message_contains: too close

scenario identity_reorder_breaks_match
  desc: A set on the board is referenced in stacks_to_remove with cards in a different order. Stacks are identified by loc + cards-in-order, so the reordered copy is NOT the same stack — referee rejects at inventory stage. Exercises the strict-order rule end-to-end; sets are the natural case since their player-visible form has no canonical order.
  op: validate_game_move
  board_before:
    at (100,100): 5H 5C 5S
  stacks_to_remove:
    at (100,100): 5C 5S 5H
  stacks_to_add:
    at (100,100): 5C 5S 5H 5D*
  hand_cards_played: 5D
  expect: error
    stage: inventory
    message_contains: not on the board
