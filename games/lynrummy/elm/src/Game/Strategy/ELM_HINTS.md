# ELM_HINTS orientation

This document lives here intentionally — it will expire naturally when
`Game/Strategy/` is deleted as part of the ELM_HINTS project.

## What the legacy code does today

`clickHint` in `Main/Play.elm` already splits into two paths:

- **Puzzle context** (hand is empty): calls `bfsHint` — uses `Bfs.solveBoard`, works now.
- **Full game** (hand has cards): calls `handHint` — uses the legacy `Game.Strategy.Hint.buildSuggestions`.

So the BFS hint is already live for puzzles. ELM_HINTS is about closing the gap for the full game.

`handHint` drives two things on the model:

1. `model.hintedCards` — a `List Card` of hand cards to highlight in the UI. This is the
   primary UX value: the player sees their relevant cards light up.
2. `model.status.text` — the trick's human-readable description, e.g.
   `"Play a hand card onto the end of a stack."`

`bfsHint` only drives `model.status.text` — it never sets `hintedCards`. That's the main
functional gap.

## How the seven tricks work

`Hint.buildSuggestions` walks a priority-ordered list of seven `Trick` records and
takes the first firing play from each:

```
DirectPlay    — hand card merges directly onto an existing board stack end
HandStacks    — hand cards form a new group among themselves
PairPeel      — peel one card from a set to make room for a hand card
SplitForSet   — split a run to extract a card enabling a hand-card set
PeelForRun    — peel to extend a run with a hand card
RbSwap        — swap a card at the run boundary to fix color alternation
LooseCardPlay — place a singleton hand card as a standalone stack
```

Each trick's `findPlays : List HandCard -> List CardStack -> List Play` returns
`Play` records carrying:
- `handCards` — which hand cards the play consumes (→ `hintedCards`)
- `apply` — a board simulator (can preview the resulting board state)
- `trickId` / description — string identity

The `Trick` and `Play` type aliases live in `Game.Strategy.Trick`; the
`Helpers` module provides shared utilities like `replaceAt` and `dummyLoc`.

## The BFS gap: no hand cards

`Bfs.solveBoard` partitions board stacks into `helper`/`trouble` buckets and
runs BFS on pure board rearrangement. The `Buckets` type has no hand-card field.
BFS moves (`ExtractAbsorb`, `FreePull`, `Push`, etc.) operate entirely on
board-resident cards.

This is fine for puzzles — the hand is empty. For the full game, the hint needs to
answer "which hand card should I play and roughly where?" The legacy tricks answer
this by brute-force: try each hand card against each board stack.

## The integration strategy (confirmed on Python side)

For each hand card, play out the what-if of putting that card onto the board and
see if it can be melded. A hint only fires if the hand card lands on the board AND
the board can be fully clean afterwards. Key constraint: the board is not assumed
to be clean to start — there may be singletons or two-card stacks already. BFS
handles that correctly by including those in the trouble bucket.

Concrete approach (singleton-only MVP):
1. For each hand card, build a projected board: original board + hand card as a
   new singleton `CardStack`.
2. Run `Bfs.solveBoard` on the projected board. Classification (`StackType.getStackType`)
   runs on every stack — helper stacks stay helper, everything else (including the
   new singleton and any pre-existing partial stacks) goes into trouble.
3. If BFS finds a plan, the hand card is a valid hint candidate.
4. Return the first hand card that has a plan, plus the plan's step descriptions.

This is O(hand_size × board_solves), bounded — hands are small and `solveBoard` is fast.

The hint output is a `List String` of steps:
- Step 0: `"place [JD:1 QD:1] from hand"` — explicit placement step
- Steps 1..n: BFS plan line descriptions (from `AgentMove.describe`)

The board is not assumed clean: projecting a singleton onto a board that already
has 2 trouble stacks means BFS must clean all 3 in one plan.

## Python side: done ✓

`agent_prelude.find_play` implements this strategy exactly. `format_hint(result)`
produces the step-list with the explicit "place from hand" step 0.

See `python/HINT_PROJECTION.md` for a full transcript (3 turns, seed 42).
See `python/HINT_INFRASTRUCTURE.md` for the build-out record.

The conformance pipeline is live: `hint_game_seed42.dsl` has 3 `hint_for_hand`
scenarios that verify Python `find_play` + `format_hint` end-to-end.

## Elm port: status

### 1. `Game.Agent.HintPlay` — DONE ✓

`HintPlay.elm` exists and ships two levels of search:

- **(a) Triple-in-hand** — `findTripleInHand` scans all hand triples using
  `StackType.isPartialOk` + `StackType.isLegalStack`. Zero BFS calls; returns
  immediately when found. With 15-card hands this fires ~100% of the time.
- **(b) Singleton BFS** — `findBestSingleton` falls through when no triple exists;
  projects each hand card as a singleton and returns the shortest BFS plan.

**Pair-via-BFS (step b in Python's `agent_prelude.find_play`)** is not yet ported.
It matters for late-game hands (6–10 cards) where no triple remains but a pair
projection may yield a cleaner plan than any singleton.

**Game arc insight**: early in the game large hands → triple fires every time and
pair/singleton BFS is never reached. Late game the hand shrinks and the inherently
tricky cards accumulate on the board — that's when singleton/pair BFS matters.

`formatHint : Maybe HintResult -> List String` emits:
- Step 0: `"place [JD:1 QD:1] from hand"` (explicit placement)
- Steps 1..n: `Move.describe` applied to each BFS plan step.

### 2. Wire into `Main/Play.elm`

Replace `handHint` with the new BFS path:

```elm
handHint : Model -> Model
handHint model =
    case HintPlay.findPlay (handCards model) model.board of
        Nothing ->
            { model | status = { text = "No hint available." } }

        Just result ->
            { model
                | hintedCards = result.placements
                , status = { text = List.head (HintPlay.formatHint (Just result))
                               |> Maybe.withDefault "" }
            }
```

The two-path `clickHint` logic (puzzle vs. full game) simplifies to one BFS-based
path: the board-only puzzle path is just `findPlay [] board` with an empty hand.

### 3. Conformance — pending wiring

`HintPlay.findPlay` and `HintPlay.formatHint` exist. The 3 seed-42 `hint_for_hand`
scenarios in `conformance_fixtures.json` currently have `Expect.pass` stubs in the
Elm suite. To harden:
- Set `Elm: true` on the `hint_for_hand` fixturegen op
- Add an `EmitElm` emitter
- Replace the `Expect.pass` stubs with real assertions against `HintPlay.findPlay`

### 4. Delete `Game/Strategy/`

Once Elm BFS hints are live and conformance passes, delete all 10 files under
`Game/Strategy/`. This document expires at that point.

## What stays relevant from the old code

1. **`hintedCards` mechanism** — the UI already highlights hand cards; the new
   path must populate this field.
2. **`AgentMove.describe`** — already wired for BFS moves; reuse for step descriptions.
3. **The `clickHint` entry point** — the two-path logic simplifies to one BFS-based
   path once hand cards are integrated.

The `Suggestion` type in `Hint.elm` (`rank`, `trickId`, `description`, `handCards`)
can be retired — it's the legacy output shape, not something the UI has a hard
dependency on.
