# game.ts — remaining scope (compressed)

Source: `angry-cat/src/lyn_rummy/game/game.ts` (3046 lines).
This is the un-ported remainder after deleting:
- Code already in `replay.go` / `hand.go` / `dealer.go` / `score.go` / `hints.go`
- TS-only plumbing: DOM rendering, styles, DragDropHelper, Popup, EditableText,
  StatusBar widget, MainGamePage, SoundEffects, PhysicalBoard/Hand/Card/Player,
  webxdc broadcast machinery.
- Unit-visible things (PhysicalBoardCard click, PhysicalCardStack wing drops, etc.)
  are pure UI wiring — they all funnel into the EventManager methods captured below.

What's kept: turn lifecycle, the referee+player handoff on `maybe_complete_turn`,
the 5 CompleteTurnResult branches, score/hand transitions on release/take-back,
geometry-transition feedback, hint dispatch, undo semantics, victor declaration.

---

## Turn lifecycle (the central scope)

### Game.maybe_complete_turn — the referee gate

```ts
maybe_complete_turn(): CompleteTurnResult {
    const referee_error = validate_turn_complete(
        CurrentBoard.card_stacks, DEFAULT_BOARD_BOUNDS,
    );
    if (referee_error) return CompleteTurnResult.FAILURE;   // dirty board
    return ActivePlayer.end_turn();                          // referee says OK
}
```

- `validate_turn_complete` checks BOTH geometry (`classify_board_geometry` ≠ OVERLAPPING
  and ≠ CROWDED) AND semantics (every stack `!incomplete() && !problematic()`).
- Failure path short-circuits; player never sees end_turn().
- **Missing on the Elm side: this gate.** The Go side currently accepts
  CompleteTurn unconditionally. That's the dirty-board bug.

### Player.end_turn — picks the variant + draws replacements

```ts
end_turn(): CompleteTurnResult {
    this.hand.reset_state();                            // clears FRESHLY_DRAWN
    const turn_result = this.player_turn.turn_result();  // SUCCESS | SUCCESS_BUT_NEEDS_CARDS | ...
    switch (turn_result) {
        case SUCCESS_BUT_NEEDS_CARDS:  this.take_cards_from_deck(3); break;
        case SUCCESS_AS_VICTOR:
        case SUCCESS_WITH_HAND_EMPTIED: this.take_cards_from_deck(5); break;
        // SUCCESS and FAILURE draw nothing.
    }
    this.get_updated_score();   // commits total_score = start + turn_score
    this.active = false;
    return turn_result;
}
```

- The enum values live in `player_turn.ts` (not shown here) — read it for the
  exact turn_result() decision logic. Product: 3 cards when you got stuck, 5 on
  hand-empty or victory.

### Player.take_card_back / release_card — the bonus hinge

```ts
release_card(hand_card) {
    this.hand.remove_card_from_hand(hand_card);
    this.player_turn.update_score_after_move();         // per-card-played bonus
    if (this.hand.is_empty()) {
        this.player_turn.update_score_for_empty_hand(TheGame.declares_me_victor());
    }
}
take_card_back(hand_card) {
    if (this.hand.is_empty()) this.player_turn.revoke_empty_hand_bonuses();
    this.hand.add_cards([hand_card.card], BACK_FROM_BOARD);
    this.player_turn.undo_score_after_move();
}
```

Empty-hand detection fires exactly once per state transition; take_card_back
must revoke the bonus if it emptied before.

### Game.declares_me_victor — first-clean-hand-empty wins

```ts
declares_me_victor(): boolean {
    if (this.has_victor_already) return false;           // only one winner ever
    if (validate_turn_complete(CurrentBoard.card_stacks, ...)) return false;
    this.has_victor_already = true;
    return true;
}
```

Note this runs at mid-turn (on hand-empty during play, not at complete_turn).
So a player can empty their hand on an incomplete/dirty board and NOT be
declared victor, even if they later clean up. Design choice.

### Game.advance_turn_to_next_player

```ts
advance_turn_to_next_player(): void {
    CurrentBoard.age_cards();    // all FRESHLY_PLAYED → FRESHLY_PLAYED_BY_LAST_PLAYER → NORMAL
    PlayerGroup.advance_turn();  // cycles index, calls start_turn on new active
}
```

`age_cards` is per-turn card-state decay — shown to the opponent as lavender.
Already in CardStack model; just need to call it on CompleteTurn success.

---

## The 5 CompleteTurnResult branches (EventManager.maybe_complete_turn)

Each branch: play a sound, show a popup, and on confirm either stay put (FAILURE)
or advance_turn. Compressed to just the driving logic + UI copy intent:

| Result                          | Sound | Popup type | Action on confirm  | UI copy intent                                  |
| ------------------------------- | ----- | ---------- | ------------------ | ----------------------------------------------- |
| FAILURE                         | purr  | warning    | stay on turn       | "board is not clean; use Undo mistakes"         |
| SUCCESS_BUT_NEEDS_CARDS         | purr  | warning    | advance_turn       | "couldn't find a move; dealt N cards next turn" |
| SUCCESS_AS_VICTOR               | bark  | success    | advance_turn       | "first to play all cards; +1500 bonus"          |
| SUCCESS_WITH_HAND_EMPTIED       | —     | success    | advance_turn       | "emptied hand; bonus; dealt N cards next turn"  |
| SUCCESS                         | —     | success    | advance_turn       | "board is growing; you got N points"            |

For the Elm port:
- Sounds: skip for v1 (no audio wired).
- Popup: StatusBar message is enough; no modal dialog shell in Elm yet.
- `advance_turn` call sequence: push ADVANCE_TURN event → age cards → cycle player → reset drag state → re-populate areas → "begin your turn."

---

## EventManager action sites (all call `process_and_push_player_action`)

All of these already exist on Go side as WireAction handlers. What's missing
is the **per-action StatusBar call** + geometry-transition check:

```ts
process_and_push_player_action(action) {
    const geo_before = classify_board_geometry(...);
    GameEventTracker.push_event(new GameEvent(PLAYER_ACTION, action));
    TheGame.process_player_action(action);
    const geo_after = classify_board_geometry(...);

    if (geo_before === CROWDED && geo_after === CLEANLY_SPACED) {
        StatusBar.celebrate("Nice and tidy!");                   // ding sound
    } else if (geo_after === CROWDED) {
        StatusBar.scold("Board is getting tight — try spacing stacks out!");
    }
}
```

Action-specific post-messages (run AFTER the above):

- `split_stack` → scold: "Be careful with splitting! Splits only pay off when you get more cards on the board or make prettier piles."
- `place_hand_card_on_board` → inform: "On the board!"   *(pre-action)*
- `move_stack` → inform: "Moved!"                        *(pre-action)*
- `process_merge` (covers stack↔stack AND hand↔stack):
    - merged stack size ≥ 3 + board clean → "Combined! Clean board!" (celebrate + ding)
    - merged stack size ≥ 3 + dirty → "Combined!" (celebrate + ding)
    - merged stack size < 3 → "Nice, but where's the third card?" (scold)

---

## Hints (EventManager.show_hints)

```ts
show_hints(): void {
    const bag_play = TRICK_BAG.first_play(ActivePlayer.hand.hand_cards, CurrentBoard.card_stacks);
    if (bag_play) {
        StatusBar.inform(bag_play.trick.description);
        PlayerArea.show_hints(new Set(bag_play.hand_cards));   // highlights hand cards
    } else {
        StatusBar.scold("No hint available from the current tricks.");
    }
}
```

- Go side already has `LegalHandMerges` + `LegalStackMerges` but not `TrickBag.first_play`.
- The `TRICK_BAG` constant at top of game.ts enumerates which tricks are visible:
  `[hand_stacks, direct_play, rb_swap, pair_peel, split_for_set, peel_for_run, loose_card_play]`.
  Omitting a trick from this list keeps it invisible to the UI.
- For Elm v1: we only need to surface SOME hint; parity with `first_play`'s exact
  ordering is not a success criterion.

---

## Undo (EventManager.undo_mistakes)

```ts
undo_mistakes(): void {
    GameEventTracker.broadcast_undo_event();          // webxdc cross-peer
    GameEventTracker.undo_last_player_action();       // pops last PLAYER_ACTION
    PlayerArea.populate(); BoardArea.populate();
    if (CurrentBoard.is_clean()) {
        StatusBar.celebrate(clean_board_message("Back to a clean board!"));  // + delta
    } else {
        StatusBar.scold("You still are in a bad state!");
    }
}
```

- Go side already handles undo via `EffectiveActions` preprocessing. Different
  mechanism (log-based vs stack-pop) but semantically equivalent.
- Missing in Elm: the status message after undo.

`clean_board_message(prefix)` appends "Your board delta for this turn is {N}."
where delta = `CurrentBoard.score() - player_turn.starting_board_score`.

---

## Puzzle / multi-peer setup (not on port critical path)

Deleted: `PuzzleSetup`, `GameSetup`, `start_game_from_setup`, webxdc listener
wiring, `orig_hands` stashing for replay. The Go side's session+seed model
subsumes this. Ports get the dealer state via `GET /sessions/<id>/state`.

---

## Critical dependencies to read on the TS side before porting

- `player_turn.ts` — `CompleteTurnResult` enum + `turn_result()` decision tree
  + `update_score_after_move`, `update_score_for_empty_hand`, revoke paths.
- `referee.ts` — `validate_turn_complete` (geometry + semantics).
- `board_geometry.ts` — `classify_board_geometry` thresholds.
- `tricks/bag.ts` — `TrickBag.first_play` dispatch.

---

## Priority order for the Elm UI catch-up

1. **CompleteTurn referee gate** (fixes the dirty-board bug — server side).
   Wire `validate_turn_complete` into `CompleteTurnAction` handler in `views/lynrummy_elm.go`
   before calling `applyCompleteTurn`.
2. **Five result branches** → StatusBar messages (no popups, no sounds in v1).
3. **Per-action StatusBar messages** (split/place/move/merge) + geometry transition.
4. **Hint button** → call a `/hints` consumer that surfaces the first legal merge.
5. **Undo status message** after undo action.
6. `advance_turn` — already the natural follow-up to CompleteTurn success.

Not blocking:
- Sounds, popup modals, avatars, Admin enum, puzzle_setup, replay-in-progress banner,
  card-color aging visuals (opponent lavender), hint card highlighting.

## Approximate original LOC vs kept

- Original: 3046 lines.
- Directly ported or redundant (deletable): ~2200 lines (PhysicalBoard/Hand/Card, DragDropHelper, Popup, SoundEffects, MainGamePage, StatusBar widget, Board/Deck/Hand/Dealer classes, BoardEvent/PlayerAction/GameEvent JSON classes, renderers).
- Product-decision one-liners (this doc): ~280 lines of prose describing what was there.
- Actual load-bearing logic still to port: `maybe_complete_turn` gate, `end_turn` draw-based-on-result, 5 popup branches → StatusBar messages, `process_and_push_player_action` geometry check + action-site scolds, `show_hints` trick dispatch, empty-hand bonus/revoke in release/take_back.

Rough estimate: ~120 lines of new Elm/Go across the items above, plus ~40 lines
wiring `validate_turn_complete` into the CompleteTurn handler.
