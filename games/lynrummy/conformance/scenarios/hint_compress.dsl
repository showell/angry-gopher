# hint_compress — DSL-to-DSL pins for compressHint.
#
# Each scenario is a raw hint (the naive one-line-per-plan-step form the
# engine emits today) under `input:`, and the gesture-faithful rewrite
# under `compressed:`. The runner feeds `input` through compressHint and
# asserts string-equality on `compressed`. The DSL IS the contract; no
# parse-back, no struct comparison.
#
# Today's single rule: a hand card placed and then immediately pushed
# onto a helper is ONE drag, so `place [X] from hand` + `push [X] onto
# HELPER ...` fuse into `play [X] from hand onto HELPER ...`. Scenarios
# whose `compressed` equals `input` pin the boundary — the cases the
# rule must leave alone.

# ---- fuses: the pure single-push play ----

scenario push_run_end
  desc: 4♠ extends the end of the spade run — one gesture
  input:
    - place [4♠] from hand
    - push [4♠] onto HELPER [K♠ A♠ 2♠ 3♠] → [K♠ A♠ 2♠ 3♠ 4♠]
  compressed:
    - play 4♠ from hand onto K♠ A♠ 2♠ 3♠

scenario push_run_front
  desc: Q♠ extends the front of the spade run
  input:
    - place [Q♠] from hand
    - push [Q♠] onto HELPER [K♠ A♠ 2♠ 3♠] → [Q♠ K♠ A♠ 2♠ 3♠]
  compressed:
    - play Q♠ from hand onto K♠ A♠ 2♠ 3♠

scenario push_set_fourth
  desc: 7♥ completes the sevens set — set extension is a push too
  input:
    - place [7♥] from hand
    - push [7♥] onto HELPER [7♠ 7♦ 7♣] → [7♠ 7♦ 7♣ 7♥]
  compressed:
    - play 7♥ from hand onto 7♠ 7♦ 7♣

scenario push_deck_two_card
  desc: deck-2 apostrophe is dropped for the player — A♠' reads as A♠ (decks are identical to the eye; deck still matters for the identity match)
  input:
    - place [A♠'] from hand
    - push [A♠'] onto HELPER [A♣ A♦ A♥] → [A♣ A♦ A♥ A♠']
  compressed:
    - play A♠ from hand onto A♣ A♦ A♥

scenario push_target_has_deck_two
  desc: deck-2 markers are dropped from the target cards too, not only the played card
  input:
    - place [9♠'] from hand
    - push [9♠'] onto HELPER [9♦' 9♥ 9♣] → [9♦' 9♥ 9♣ 9♠']
  compressed:
    - play 9♠ from hand onto 9♦ 9♥ 9♣

# ---- passes through unchanged: the boundary ----

scenario passthrough_multistep
  desc: a board cleanup sits between place and push — not a single gesture
  input:
    - place [4♠] from hand
    - peel T♦ from HELPER [T♦ J♦ Q♦ K♦], absorb onto [J♦' Q♦'] → [T♦ J♦' Q♦'] [→COMPLETE]
    - push [4♠] onto HELPER [K♠ A♠ 2♠ 3♠] → [K♠ A♠ 2♠ 3♠ 4♠]
  compressed:
    - place [4♠] from hand
    - peel T♦ from HELPER [T♦ J♦ Q♦ K♦], absorb onto [J♦' Q♦'] → [T♦ J♦' Q♦'] [→COMPLETE]
    - push [4♠] onto HELPER [K♠ A♠ 2♠ 3♠] → [K♠ A♠ 2♠ 3♠ 4♠]

scenario passthrough_splice
  desc: splice bisects a helper — a different, non-push move, left alone for now
  input:
    - place [4♣'] from hand
    - splice [4♣'] into HELPER [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] → [2♣ 3♦ 4♣'] + [4♣ 5♥ 6♠ 7♥]
  compressed:
    - place [4♣'] from hand
    - splice [4♣'] into HELPER [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] → [2♣ 3♦ 4♣'] + [4♣ 5♥ 6♠ 7♥]

scenario passthrough_push_of_board_trouble
  desc: the pushed cards are NOT the placed card — the push consumes board trouble
  input:
    - place [8♣] from hand
    - push [4♠] onto HELPER [K♠ A♠ 2♠ 3♠] → [K♠ A♠ 2♠ 3♠ 4♠]
  compressed:
    - place [8♣] from hand
    - push [4♠] onto HELPER [K♠ A♠ 2♠ 3♠] → [K♠ A♠ 2♠ 3♠ 4♠]
