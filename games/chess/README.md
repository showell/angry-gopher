# Chess Toys

Little backtracking searches you can watch think — and scrub, in both
directions. Live at [lynrummy.com/chess](https://lynrummy.com/chess):
the **Knight's Tour** (visit all 64 squares exactly once) and **Eight
Queens** (none attacking another).

**The code is part of the product**: the live site serves these exact
sources at [/chess/code](https://lynrummy.com/chess/code), with the
architecture intro. Short version:

- **`core/tape.zig`** — the shared engine. A search emits an **event tape**
  (place piece / remove piece, one byte per event); the display walks a
  cursor over the tape, applying events forward or inverting them backward.
  Scrubbing isn't a feature bolted onto the search — it falls out of the
  data structure. The tape also owns the red overlay (a piece was placed
  here, found doomed, and retracted) and emits the shared wasm ABI from one
  authoritative list (`exportAbi`).
- **`knight.zig` / `queens.zig`** — the machines. Each provides
  `target_count`, `genOne` (one search transition, one event),
  `resetMachine`, and its own indigo "impossible right now" overlay
  (unreachable-from-the-head for the knight, attacked for the queens).
  Each compiles to its own freestanding wasm module of a few KB —
  no allocator, no imports (`ops/build_chess_wasm`).
- **`board.js`** — the one dumb JS host. Draws the 64 move numbers and two
  overlay masks the wasm exposes, forwards clicks; the page shells differ
  only in an inline `window.CHESS_TOY` wording config.

Gate: `ops/check_chess` (`zig test` on each toy root — inside `ops/check`).
The tests pin empirically-measured event counts (knight from g6:
2,520,884 events; queens pinned at g8: 306), so a change to move ordering
— which changes how the toys *animate* — can't land silently.
