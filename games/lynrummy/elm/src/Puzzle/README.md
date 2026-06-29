# Lyn Rummy — puzzles

**Welcome to the puzzle gallery!** Open [lynrummy.com/puzzles](https://lynrummy.com/puzzles)
and you get a wall of frozen mid-game boards. Each one is a single trick's worth
of moves: drag stacks to **merge** or **split** your way to a clean meld layout.
It's solo — no opponent, no clock — **undo** is free, and **Replay** walks back
through your moves.

This directory (`Puzzle/`) is the Elm entry point for that gallery. It's the
smaller cousin of the full game, so this README stays short — **read
[`../Game/README.md`](../Game/README.md) first** for the architecture (the
three-actor hybrid, the DSL-over-the-wire idea, the server-is-dumb-storage
principle). All of it applies here too.

## What's different from the game

A puzzle is a game with the hard parts removed: no hand, no turn cycle, no
opponent, no DOM-geometry drags to synthesize. That's why `Puzzle.elm` is its own
small entry point rather than a mode of `Game.elm`:

- **`Puzzle.elm`** — the gallery: bootstraps each board, handles board-only
  gestures, posts an action log per puzzle. Its `actions.dsl` has exactly one
  consumer (the in-repo agent), so the wire format here is ours to change freely.
- [`Animate.elm`](Animate.elm) — a deliberately simpler sibling of the game's
  animator. Replays run straight over a `List CardStack` (no hand, no DOM
  measurement); only `MergeStack`, `MoveStack`, `Split`, and `Isolate` are
  expected — anything else is a contract violation, on purpose.

Everything else — the referee, the DSL parsers, the card and stack rendering — is
shared from [`../Lib/`](../Lib/), the same code the game runs on. Build, run, and
gate exactly as described in the game README (`ops/start`, then `/puzzles`;
`ops/check_lynrummy` while working).
