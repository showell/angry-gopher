# Lyn Rummy: puzzles

Open [lynrummy.com/puzzles](https://lynrummy.com/puzzles) for frozen
mid-game boards. Each takes a single trick's worth of moves: drag stacks to
**merge** or **split** your way to a clean meld layout. You play solo, at
your own pace. **Undo** is free, **Replay** walks back through your moves
and **Hint** gives the next move.

`Puzzle/` holds the puzzle's Elm modules beside its entry point,
`../Puzzle.elm`. Read [`../Game/README.md`](../Game/README.md) first: the
three actors, the DSL and the storage-only server all apply here.

## How it differs from the game

A puzzle is a game reduced to the board: one player, one board, and drags
that stay on the board. So `Puzzle.elm` is its own small entry point:

- **`Puzzle.elm`** bootstraps each board, handles board gestures and posts
  an action log per puzzle. That `actions.dsl` has one consumer, the
  in-repo agent, so its format is ours to change.
- [`Animate.elm`](Animate.elm) is a simpler sibling of the game's animator.
  Replays run straight over a `List CardStack`, and it accepts `MergeStack`,
  `MoveStack`, `Split` and `Isolate` alone; any other action is a contract
  violation, on purpose.

The referee, the DSL parsers and the card and stack rendering are shared
from [`../Lib/`](../Lib/). Build, run and gate as the game does
(`ops/start`, then `/puzzles`; `ops/check_lynrummy` while working).

**Hint** is the puzzle's one call outside Elm: the `puzzle_hint` port op,
wired by [`../../engine_glue.js`](../../engine_glue.js). The Zig
board-bridge solver answers it (`/puzzles/solver.wasm`, built from
`games/lynrummy/zig/` by `ops/build_lynrummy_wasm`, fetched on the first
click). The glue lowers the board to an arrangement line; the solver finds
the cover that keeps the most of the player's own stacks; the reply is the
move plan, as peel, steal, push, split and merge lines. The status bar
shows the first line and the console logs the plan. The full game's
`game_hint` and `agent_step` use the same wasm.
