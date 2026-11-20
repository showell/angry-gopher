# Chess Toys

Backtracking searches you can watch think, and scrub in both directions.
Live at [lynrummy.com/chess](https://lynrummy.com/chess): the **Knight's
Tour** (visit all 64 squares exactly once) and **Eight Queens** (eight
queens, each safe from the others). Clicking a square pins the first queen
there, and the tests prove every square is on some solution.

It follows Safari's pattern: freestanding zig→WASM cores embedded in the
server, a small plain-JS canvas host, public and open to all. **The code is
part of the product:** [/chess/code](https://lynrummy.com/chess/code)
serves these exact sources, embedded from the files the wasm is built from,
so the exhibit always matches what runs.

## The event tape

The search narrates; the display draws. Every transition appends **one
byte** to an event tape (bit 7 is place or remove, the low six bits the
square). The search only appends; the display is a cursor walking the tape,
applying events forward or inverting them backward. A remove always pulls
the deepest piece, so each event is its own inverse. Pause, step, rewind and
scrub fall out of the data structure.

## Overlays

Both are pure functions of the display board, so they are exact at any
cursor position:

- **Red is a dead end** (the shared engine's). A square turns red when a
  piece placed there is pulled off, at the moment of retraction. Reds build
  up as a doomed branch unwinds and clear when the search re-enters the
  square. A square's events alternate place and remove, so "empty and once
  touched" means "the last event was a retraction": one counter a square,
  O(1) in both directions.
- **Indigo is impossible right now** (the toy's). The knight marks squares
  unreachable from its head through empty squares; the queens mark attacked
  squares. Indigo wins where both hold.

## Layout

- **`core/tape.zig`** is the shared engine: `Substrate(Toy)`, a comptime
  generic holding the tape, the scrub display, the red overlay and the wasm
  ABI. `exportAbi(S)` emits the shared exports from one list, so the two
  modules agree.
- **`knight.zig` and `queens.zig`** are the machines. A toy answers four
  questions: how many pieces mean solved (`target_count`), the next
  transition (`genOne`, one call per event), how to reset (`resetMachine`)
  and what is impossible now (`computeImpossible`). Each compiles to its own
  freestanding wasm module of a few KB, import-free and with a fixed
  tape.
- **`board.js`** is the JS host: canvas, transport buttons, speed slider,
  hover hints. Each page shell sets an inline `window.CHESS_TOY` config for
  its wording; a missing config is a loud crash.

**Adding a toy** takes a machine module answering the four questions, a
page-shell config in `zig-server/src/chess.zig` and a card on the `/chess`
index.

## Tests

`ops/check_chess` (part of `ops/check`) runs `zig test` on each toy. The
tests pin measured event counts, which freezes the move orderings: a change
that makes a toy animate differently fails them. The knight uses
degree-ascending order (frozen Warnsdorff) and completes from all 64 starts;
the tests hold each count.

## Build and wiring

`ops/build_chess_wasm` builds each toy to `games/chess/*.wasm` (gitignored);
`ops/start` runs it through `ops/build_embedded`. `zig-server/src/chess.zig`
serves the index, both shells and `/chess/code`. The home-page card is in
`pages/home.txt`, with `gallery/chess.svg` as its image.
