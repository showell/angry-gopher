# State-Flow Audit of game.ts

*Written 2026-04-17 (late pm). Explicit deliverable per the porting cheat sheet before tackling the 3,046-line game.ts. Maps where state lives, how events flow, and proposes an Elm decomposition.*

**← Prev:** [The Opening Board](the_opening_board.md)
**→ Next:** [Drag and Wings](drag_and_wings.md)

---

The porting cheat sheet is explicit: before porting anything of
significant size, map the source's state flow. "Closure-captured
mutation is the main red flag... The shape of that map is a
direct predictor of port difficulty." This essay is that map
for `game.ts`.

## What the audit found

`game.ts` is **class-with-singletons, top to bottom.** There
are 14 module-level mutable globals, each pointing at a class
instance. The classes themselves are mutable. The game as a
system is a tangle of "these classes hold refs to each other
and mutate each other's fields via methods."

Not FP-disciplined. Not closure-hell either — it's the classic
idiomatic-TS shape: typed classes, reference semantics, method
mutation. Mechanical translation to Elm will force the port to
get *more explicit*, not more complicated.

The 14 globals split into three layers.

### Domain state (the game)

```
CurrentBoard : Board              { card_stacks: CardStack[] }
TheDeck      : Deck               { cards: Card[] }
ActivePlayer : Player             (ref into PlayerGroup.players)
PlayerGroup  : PlayerGroupSingleton {
                 players: Player[]
                 current_player_index: number
               }
TheGame      : Game               { has_victor_already: boolean }
GameEventTracker : GameEventTrackerSingleton {
                 replay_in_progress
                 json_game_events: JsonGameEvent[]
                 orig_deck, orig_board, orig_hands?
                 webxdc                              ← V2 only
               }
```

Each `Player` is itself a mini-record:

```
Player {
  name: string
  active: boolean
  show: boolean
  hand: Hand                     { hand_cards: HandCard[] }
  num_drawn: number
  total_score: number
  total_score_when_turn_started: number
  player_turn?: PlayerTurn       ← already ported module
}
```

### UI singletons

```
PhysicalBoard, PlayerArea, BoardArea      (rendering state, DOM refs)
EventManager                              (dispatches actions, mutates domain)
DragDropHelper                            (drag session + drop targets)
StatusBar                                 (transient message at top of page)
Popup                                     (modal dialog)
SoundEffects                              (audio playback)
```

### Meta-state

```
CROWDING_MARGIN         (constant; for drag-proximity checks)
TRICK_BAG               (static list of hint tricks; already all ported)
```

## How action flows

The path from user click/drag to board mutation:

```
user drags card
  → DragDropHelper emits a drag-end event
  → build a BoardEvent {stacks_to_remove, stacks_to_add}
  → wrap as PlayerAction {board_event, hand_cards_to_release}
  → EventManager.apply_action(player_action)
      → GameEventTracker.push_event(GameEvent.PlayerAction)
      → TheGame.process_player_action(player_action)
          → CurrentBoard.process_event(board_event)  [mutates CurrentBoard]
          → for each hand_card: ActivePlayer.release_card(hand_card)
              [mutates Hand and PlayerTurn]
      → PlayerArea.populate()    [full re-render]
      → BoardArea.populate()     [full re-render]
```

Undo flows in reverse via `reverse_player_action`. End-of-turn
flows through `TheGame.maybe_complete_turn()` which consults
the referee (already ported), then `ActivePlayer.end_turn()`
which mutates Player state.

Four observations from this flow:

1. **Actions are already diff-shaped.** `BoardEvent` carries a
   `{to_remove, to_add}` diff. That's what `LynRummy.BoardActions`
   produces, and it's what the Elm `update` function will
   consume. The action schema is already FP-clean even in TS.

2. **The "render everything" pattern after every action is
   cheap in Elm.** TS uses `PlayerArea.populate()` + `BoardArea.populate()`
   to do a full re-render after every action. That's literally
   what `view : Model -> Html Msg` does every time Elm updates
   the Model. So the "refresh UI after action" step disappears
   in Elm — it's not separate from the action.

3. **The GameEventTracker history buffer is the replay
   mechanism.** It's a list of JSON-serialized game events that
   can be replayed to reconstruct the game state. In Elm, this
   is a `List JsonGameEvent` in the Model, fed through a
   pure `applyEvent : JsonGameEvent -> Model -> Model`
   function. Replay becomes a scheduled sequence of `Msg`s.

4. **Multiplayer plumbing (WebXDC `sendUpdate` / inbound
   events) is the V2-only layer.** `GameEventTracker` holds a
   `webxdc` reference and calls `sendUpdate` to broadcast. The
   standalone V1 game doesn't need this — we drop the
   broadcast / inbound-listener plumbing and keep only the
   local event buffer.

## Impedance mismatches specific to game.ts

Most are covered by the handbook's "UI-layer patterns"
section, but three are worth naming explicitly for this
module:

**Globals-as-refs → explicit Model field.** TS uses
`CurrentBoard.foo(...)` from anywhere; Elm threads everything
through the single `Model` argument. Every method that reads
`CurrentBoard` becomes a function taking `Board` (or the
whole Model) as an argument. Every method that writes to
`CurrentBoard` returns a new `Board` instead.

**`ActivePlayer` aliasing.** `ActivePlayer` is a *reference
into* `PlayerGroup.players[currentPlayerIndex]`, not a
separate copy. Mutations to `ActivePlayer` also mutate the
player inside `PlayerGroup`. In Elm, `ActivePlayer` is an
*index*, not a separate value — code that updates the active
player updates `PlayerGroup.players` at that index and
returns the new `PlayerGroup`. Concrete snippet:

```elm
updateActivePlayer : (Player -> Player) -> PlayerGroup -> PlayerGroup
updateActivePlayer f group =
    { group
        | players =
            List.indexedMap
                (\i p ->
                    if i == group.currentPlayerIndex then
                        f p
                    else
                        p
                )
                group.players
    }
```

**Methods that reach across state boundaries.** Some TS
methods read from one global and write to another — e.g.,
`Player.release_card` mutates `this.hand`, reads
`TheGame.declares_me_victor()`, and mutates `this.player_turn`.
In Elm, this becomes a function that takes the relevant
subset of Model (Player, plus the `Game` to ask
`declaresMeVictor`), returns a new Player. The top-level
update function plumbs the result back.

## Proposed Elm decomposition

Game.ts becomes roughly these Elm modules. None of them are
themselves huge; the 3,046 lines spread out.

### Domain layer

- **`LynRummy.Board.elm`** — `Board` type + `processEvent`,
  `score`, `isClean`, `ageCards`. ~60 Elm LOC.
- **`LynRummy.Deck.elm`** — `Deck` type + `takeFromTop`,
  `pullCardFromDeck`, `size`. ~40 LOC.
- **`LynRummy.Hand.elm`** — `Hand` type + `addCards`,
  `removeCardFromHand`, `resetState`, `isEmpty`, `size`. ~50 LOC.
- **`LynRummy.Player.elm`** — `Player` type + `startTurn`,
  `endTurn`, `releaseCard`, `takeCardBack`, `takeCardsFromDeck`,
  score queries. ~120 LOC. Depends on `PlayerTurn` (done) +
  `Hand` + `Deck`.
- **`LynRummy.PlayerGroup.elm`** — `PlayerGroup` type +
  `advanceTurn`, `activePlayer`, `updateActivePlayer` helper.
  ~40 LOC.
- **`LynRummy.GameState.elm`** — `GameState` type (renamed
  from `Game` to avoid Elm's module/type-name conflict) +
  `declaresMeVictor`, `processPlayerAction`,
  `reversePlayerAction`, `maybeCompleteTurn`. ~80 LOC. This is
  the top-level orchestrator that reaches into Board /
  PlayerGroup.
- **`LynRummy.Event.elm`** — `BoardEvent`, `PlayerAction`,
  `GameEvent`, `GameEventType` types + encoders/decoders
  (moderate V2 surface; V1 just needs the in-memory shapes).
  ~60 LOC.

### Event-tracker layer

- **`LynRummy.EventTracker.elm`** — the `GameEventTracker`
  equivalent. `EventTracker` record + `pushEvent`,
  `popPlayerAction`, `handleEvent`, `playGameEvent`. `replay`
  becomes a Cmd-producing function scheduling `Msg`s on a
  timer. WebXDC plumbing stripped for V1. ~120 LOC.

### UI layer

- **`LynRummy.View.elm`** — already exists; extend with hand
  view, player area, status bar, button views. Probably
  grows to ~400 LOC total.
- **`LynRummy.DragState.elm`** — the drag state machine as
  a sum type + Msg-driven transitions. `type DragState =
  NoDrag | DraggingHandCard ... | DraggingStack ...` + helpers
  like `overlappingDropTarget`. ~150 LOC.
- **`LynRummy.StatusBar.elm`** — tiny; a record for the
  current status message + its style. ~30 LOC.

### Entry

- **`src/Main.elm`** — grows substantially. Top-level Model,
  Msg, update, view, subscriptions. Probably the largest
  single file at ~400-500 LOC when feature-complete.

### Totals

Rough estimate: **~1,400–1,700 Elm LOC** across these modules,
vs `game.ts`'s 3,046. That's consistent with the ~60%
compression ratio the model-layer port hit.

The surface area is larger than I initially hoped, but each
individual module is small. The biggest risk is Main.elm
growing into a god-module — that's a thing to guard against
actively as we wire.

## Porting order

The plan I'd carry out, smallest-and-safest first:

1. `LynRummy.Deck.elm` (domain-pure, tiny)
2. `LynRummy.Hand.elm` (domain-pure, small, leans on Card)
3. `LynRummy.Board.elm` (leans on CardStack; `processEvent`
   is where the diff application lives)
4. `LynRummy.Event.elm` (types + JSON; V1 needs in-memory
   only, encoders/decoders deferred)
5. `LynRummy.Player.elm` (leans on Hand, PlayerTurn, Deck)
6. `LynRummy.PlayerGroup.elm` (list-of-Players + turn index)
7. `LynRummy.GameState.elm` (top-level orchestrator)
8. `LynRummy.EventTracker.elm` (event history + replay;
   V1 can stub the broadcast/inbound-listener surface)
9. Extend `LynRummy.View.elm` (hand view, player area, etc.)
10. `LynRummy.DragState.elm` + Main.elm drag Msgs
11. Fill out Main.elm (Model, Msg, update, subscriptions)
12. Status bar, buttons, turn flow

Each step ships with tests + sidecar. Estimated 1.5 wall-days
at the pace of the first five modules this afternoon (~1
domain module per 30–45 minutes).

## Risks and open questions

- **Replay scheduling.** TS uses `setTimeout` to pace replay.
  In Elm this becomes a `Time.every` subscription or a
  `Task.perform` chain. Not hard, but needs a choice.

- **Undo semantics.** `reverse_player_action` operates on a
  popped history entry. The Elm equivalent is functional —
  pop the last event off the buffer, apply its inverse to
  Model. Should be straightforward if `BoardEvent` is
  symmetric (it is — `reverse` swaps `stacksToRemove` and
  `stacksToAdd`).

- **`ActivePlayer` as a reference.** The TS code uses
  `ActivePlayer` as both an alias for
  `PlayerGroup.players[index]` AND a standalone variable. I
  need to check every call site to ensure the Elm
  "alias-as-index" translation captures all intended
  semantics. Low risk but worth grepping.

- **What to do with `orig_hands` in EventTracker.** Only
  non-empty for Gopher-backed games. For V1 standalone, this
  field is never populated; we can either include it as
  `Maybe` or drop it entirely. I'd lean toward `Maybe` so V2
  wiring is trivial.

- **`show` vs `active` on Player.** The TS `Player` has
  both `active` (whose turn it is) and `show` (whether to
  display their info). `show` seems tied to the
  "spectator / multiplayer" mode; likely irrelevant for V1.
  Flag for confirmation when porting `Player.elm`.

## What I'd like your ruling on before starting

Three yes/no items:

1. **Module decomposition shape above — yes or propose fewer/more?**
   Specifically, worth checking whether `GameState.elm` is
   too thin (80 LOC) — I could fold it into `Main.elm` but
   the domain/UI separation it provides is worth the extra
   file.

2. **WebXDC / broadcast layer fully dropped for V1?** My read:
   yes, V1 is single-player local. `GameEventTracker` loses
   its `webxdc` field, `broadcast_game_event` becomes a
   no-op or is removed. Confirm.

3. **`show` and spectator mode — dropped for V1?** The TS
   Player has a `show` field and visibility logic for
   multiplayer spectating. Drop from Player for V1; revisit
   with the multiplayer wiring in V2. Confirm.

Everything else I'll judgment-call. Waiting on the three
above, then starting the porting sequence from `Deck.elm`.

— C.
