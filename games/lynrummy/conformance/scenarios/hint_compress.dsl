# hint_compress — DSL-to-DSL pins for compressHint.
#
# Each scenario is a raw hint (the naive one-line-per-plan-step form the
# engine emits today) under `input:`, and the gesture-faithful rewrite
# under `compressed:`. The runner feeds `input` through compressHint and
# asserts string-equality on `compressed`. The DSL IS the contract; no
# parse-back, no struct comparison.
#
# The rule: a hand card placed and then immediately dropped onto/into a
# board stack is ONE drag, so `place [X] from hand` + a consuming move
# (push / pull / splice of exactly X) fuse into one `play X from hand
# <onto|into> <target>` line. push/pull land ONTO an existing group;
# splice lands INTO a run. Scenarios whose `compressed` equals `input`
# pin the boundary — the cases the rule must leave alone.

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

# ---- fuses: splice (lands INTO a run, which splits around the card) ----

scenario splice_into_long_run
  desc: 4♣' splices into the long rb run — keep the verb "splice" (players know it); don't spell out that the run divides into two
  input:
    - place [4♣'] from hand
    - splice [4♣'] into HELPER [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] → [2♣ 3♦ 4♣'] + [4♣ 5♥ 6♠ 7♥]
  compressed:
    - splice 4♣ from hand into 2♣ 3♦ 4♣ 5♥ 6♠ 7♥

# ---- fuses: free_pull (loose card onto a partial — same gesture as push) ----

scenario free_pull_onto_partial
  desc: 8♠' completes the partial [6♠' 7♠'] — free_pull reads ONTO, like push; the "partial vs helper" distinction is invisible to the player
  input:
    - place [8♠'] from hand
    - pull 8♠' onto [6♠' 7♠'] → [6♠' 7♠' 8♠'] [→COMPLETE]
  compressed:
    - play 8♠ from hand onto 6♠ 7♠

# ---- humanizes: standalone extract_absorb board→board moves (1 → 1) ----
# The verb encodes the source-remnant fate (which the player watches); the
# motion is always "move this card from source onto target". Keep the
# recognizable verb, strip HELPER/brackets/→result/COMPLETE/spawn, deck-blind.

scenario peel_end_card
  desc: peel — take an end card off a run onto a partial
  input:
    - peel K♦ from HELPER [T♦ J♦ Q♦ K♦], absorb onto [J♦' Q♦'] → [J♦' Q♦' K♦] [→COMPLETE]
  compressed:
    - peel K♦ from T♦ J♦ Q♦ K♦ onto J♦ Q♦

scenario pluck_from_long_run
  desc: pluck — same motion, longer source run
  input:
    - pluck 7♥' from HELPER [4♥' 5♥' 6♥' 7♥' 8♥' 9♥ T♥], absorb onto [7♠ 7♣] → [7♠ 7♣ 7♥'] [→COMPLETE]
  compressed:
    - pluck 7♥ from 4♥ 5♥ 6♥ 7♥ 8♥ 9♥ T♥ onto 7♠ 7♣

scenario yank_with_spawn
  desc: yank — pull a card leaving a spawned remnant; spawn tail is dropped
  input:
    - yank 6♠ from HELPER [2♣ 3♦ 4♣ 5♥ 6♠ 7♥], absorb onto [5♠] → [5♠ 6♠] ; spawn [7♥]
  compressed:
    - yank 6♠ from 2♣ 3♦ 4♣ 5♥ 6♠ 7♥ onto 5♠

scenario steal_from_set
  desc: steal — take a card from a set, shattering the remnant (spawn dropped)
  input:
    - steal A♣ from HELPER [A♣ A♦ A♥], absorb onto [Q♣ K♦] → [Q♣ K♦ A♣] [→COMPLETE] ; spawn [A♦], [A♥]
  compressed:
    - steal A♣ from A♣ A♦ A♥ onto Q♣ K♦

scenario split_out_reads_as_two_words
  desc: split_out — internal name renders as the natural "split out"
  input:
    - split_out 8♠ from HELPER [7♥' 8♠ 9♦], absorb onto [6♠ 7♥] → [6♠ 7♥ 8♠] [→COMPLETE] ; spawn [7♥'], [9♦]
  compressed:
    - split out 8♠ from 7♥ 8♠ 9♦ onto 6♠ 7♥

scenario set_peel_renders_as_peel
  desc: set_peel — a peel from a set; internal name renders as plain "peel"
  input:
    - set_peel Q♣' from HELPER [Q♥' Q♠' Q♣'], absorb onto [T♣' J♦] → [T♣' J♦ Q♣'] [→COMPLETE] ; spawn [Q♥' Q♠']
  compressed:
    - peel Q♣ from Q♥ Q♠ Q♣ onto T♣ J♦

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

scenario passthrough_board_rearrange_verb
  desc: place then a board-rearrangement verb (peel + absorb) — that verb consumes a HELPER card, not the hand card, so it never fuses even at two lines
  input:
    - place [4♠] from hand
    - peel T♦ from HELPER [T♦ J♦ Q♦ K♦], absorb onto [J♦' Q♦'] → [T♦ J♦' Q♦'] [→COMPLETE]
  compressed:
    - place [4♠] from hand
    - peel T♦ from HELPER [T♦ J♦ Q♦ K♦], absorb onto [J♦' Q♦'] → [T♦ J♦' Q♦'] [→COMPLETE]

scenario passthrough_push_of_board_trouble
  desc: the pushed cards are NOT the placed card — the push consumes board trouble
  input:
    - place [8♣] from hand
    - push [4♠] onto HELPER [K♠ A♠ 2♠ 3♠] → [K♠ A♠ 2♠ 3♠ 4♠]
  compressed:
    - place [8♣] from hand
    - push [4♠] onto HELPER [K♠ A♠ 2♠ 3♠] → [K♠ A♠ 2♠ 3♠ 4♠]
