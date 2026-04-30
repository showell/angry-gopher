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

## The integration strategy

Steve's framing: for each hand card, play out the what-if of putting that card onto
the board and see if it can be melded. A hint only fires if the hand card lands on
the board AND the board can be fully clean afterwards. Key constraint: the board
is not assumed to be clean to start — there may be singletons or two-card stacks
already. BFS handles that correctly by including those in the trouble bucket.

Concrete approach:
1. For each hand card, place it as a singleton on the board (location is
   cosmetic for BFS purposes — content is what matters).
2. Run `Bfs.solveBoard` on the resulting hypothetical board (original board +
   hand card as a new singleton stack).
3. If BFS finds a plan, the hand card is a valid hint candidate.
4. Surface the hand card (→ `hintedCards`) + the first BFS move as status text.

This is O(hand_size × board_solves), bounded — hands are small and `solveBoard`
is fast.

## What stays relevant from the old code

1. **`hintedCards` mechanism** — the UI already highlights hand cards; the new
   path must populate this field.
2. **Status text** — `AgentMove.describe` is already wired for BFS moves.
3. **The `clickHint` entry point** — the two-path logic simplifies to one BFS-based
   path once hand cards are integrated.

The `Suggestion` type in `Hint.elm` (`rank`, `trickId`, `description`, `handCards`)
can be retired — it's the legacy output shape, not a hard UI dependency.

## Python first

Before touching Elm, verify the hand-card BFS integration works on the Python side.
Python's `bfs_solver.py` / `auto_player.py` are the reference implementation.
Confirm that the "place hand card as singleton, run BFS" approach produces correct
hints there, then port to Elm.
