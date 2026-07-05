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

# ---- reorders: board manipulation first, the hand card lands last ----
# The projection layer lists "place [X] from hand" first and ignores order.
# A human drops the card only when the board is ready, so board→board moves
# float to the front (in the solver's order) and the hand landing (fused into
# one line) comes last. These are real seed-42 dirty-board fixtures.

scenario reorder_board_cleanup_then_hand
  desc: turn_2 — an unrelated board cleanup (peel) leads; the 4♠ hand play lands last
  input:
    - place [4♠] from hand
    - peel T♦ from HELPER [T♦ J♦ Q♦ K♦], absorb onto [J♦' Q♦'] → [T♦ J♦' Q♦'] [→COMPLETE]
    - push [4♠] onto HELPER [K♠ A♠ 2♠ 3♠] → [K♠ A♠ 2♠ 3♠ 4♠]
  compressed:
    - peel T♦ from T♦ J♦ Q♦ K♦ onto J♦ Q♦
    - play 4♠ from hand onto K♠ A♠ 2♠ 3♠

scenario reorder_dirty_board_with_board_push
  desc: turn_3 — two board moves first (a peel and a push of a LOOSE BOARD 4♠, not from hand), then the 4♣' hand splice lands last
  input:
    - place [4♣'] from hand
    - peel K♦ from HELPER [T♦ J♦ Q♦ K♦], absorb onto [J♦' Q♦'] → [J♦' Q♦' K♦] [→COMPLETE]
    - push [4♠] onto HELPER [K♠ A♠ 2♠ 3♠] → [K♠ A♠ 2♠ 3♠ 4♠]
    - splice [4♣'] into HELPER [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] → [2♣ 3♦ 4♣'] + [4♣ 5♥ 6♠ 7♥]
  compressed:
    - peel K♦ from T♦ J♦ Q♦ K♦ onto J♦ Q♦
    - push 4♠ onto K♠ A♠ 2♠ 3♠
    - splice 4♣ from hand into 2♣ 3♦ 4♣ 5♥ 6♠ 7♥

scenario fuse_in_place_dependent_board_move
  desc: the landing is MID-plan and the later pull's target is the landing's RESULT (the group 9♥ T♠ exists only after the 9♥ lands). Solver order is kept - the hand line fuses at its own position instead of floating last.
  input:
    - place [9♥] from hand
    - pull 9♥ onto [T♠'] → [9♥ T♠']
    - pull 8♠' onto [9♥ T♠'] → [8♠' 9♥ T♠'] [→COMPLETE]
  compressed:
    - play 9♥ from hand onto T♠
    - pull 8♠ onto 9♥ T♠

scenario triple_in_hand_lands_directly
  desc: a triple played straight from hand onto a clean board — no target, no board move
  input:
    - place [7♦ 8♦ 9♦] from hand
  compressed:
    - play 7♦ 8♦ 9♦ from hand

# ---- collapses: a hand card that SEEDS a new group (board cards absorb onto it) ----
# The placed card isn't consumed by any move — it's the anchor a chain of
# extract_absorbs builds on. "place X on board to build <final group>" says
# it all (place, not play: you place a seed, you play a lander). Real seed-42
# game-2 mid-turn state (uid 16), a K→A→2 rb run seeded from hand.

scenario seed_new_group_from_hand
  desc: 2♥ is dropped as a seed; A♣ then K♦ are peeled onto it to build the K♦ A♣ 2♥ rb run — the whole chain is one instruction
  input:
    - place [2♥'] from hand
    - peel A♣ from HELPER [A♣ A♦ A♥ A♠'], absorb onto [2♥'] → [A♣ 2♥']
    - peel K♦ from HELPER [T♦ J♦ Q♦ K♦], absorb onto [A♣ 2♥'] → [K♦ A♣ 2♥'] [→COMPLETE]
  compressed:
    - place 2♥ on board to build K♦ A♣ 2♥

# ---- collapses: a hand PAIR placed as the landing pad for a board loner ----
#
# The placed pair is never consumed by a move — instead the ONE move pulls a
# board loner ONTO it. Three cards, one human thought: "put these two hand
# cards with that board card". Scoped deliberately narrow (exactly two lines,
# a two-card place, a pull whose target IS the placed pair) — real case:
# Stephen2 game 5, a T♠ loner finished by the hand pair 8♠ 9♥.

scenario pair_landing_pad_for_board_loner
  desc: the T♠ sits alone on the board; the plan places the hand pair [8♠' 9♥] and pulls the T♠ onto it. One line - place the two hand cards with the loner.
  input:
    - place [8♠' 9♥] from hand
    - pull T♠' onto [8♠' 9♥] → [8♠' 9♥ T♠'] [→COMPLETE]
  compressed:
    - place 8♠ and 9♥ with the T♠ on the board

# ---- bails: return the plan raw rather than half-transform it ----

scenario passthrough_unhandled_shift
  desc: shift isn't handled yet — a plan touching it is returned entirely raw, never half-humanized
  input:
    - shift 3♠ to pop K♠ [4♥ 5♣' 6♥' -> A♠ 2♠ + 3♠]; absorb onto [J♣' Q♦] → [J♣' Q♦ K♠]
  compressed:
    - shift 3♠ to pop K♠ [4♥ 5♣' 6♥' -> A♠ 2♠ + 3♠]; absorb onto [J♣' Q♦] → [J♣' Q♦ K♠]

scenario passthrough_placed_card_never_consumed
  desc: the placed 8♣ is never landed by any move (only a board 4♠ push) — can't reorder safely, so leave it raw
  input:
    - place [8♣] from hand
    - push [4♠] onto HELPER [K♠ A♠ 2♠ 3♠] → [K♠ A♠ 2♠ 3♠ 4♠]
  compressed:
    - place [8♣] from hand
    - push [4♠] onto HELPER [K♠ A♠ 2♠ 3♠] → [K♠ A♠ 2♠ 3♠ 4♠]
