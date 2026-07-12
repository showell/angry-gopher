# Chess Toys

Little backtracking searches you can watch think — and scrub, in both
directions. Live at [lynrummy.com/chess](https://lynrummy.com/chess):
the **Knight's Tour** (visit all 64 squares exactly once) and **Eight
Queens** (none attacking another; clicking a square PINS the first
queen there — every square is on some solution, test-proven).

Built on the safari pattern: freestanding zig→WASM cores
`@embedFile`'d into the server, a dumb plain-JS canvas host, public
and ungated. **The code is part of the product**: the live site serves
these exact sources at [/chess/code](https://lynrummy.com/chess/code)
— embedded from the same files the wasm modules are built from, so the
exhibit can't drift from what runs. The home-page row's `essay:` link
points there. The companion blog essay is **"Watching the Textbook
Think"** (`blog/posts/2026-07-12-1338-watching-the-textbook-think.md`).

## The event tape

The design everything else hangs off: the search never draws — it
narrates. Every transition appends **one byte** to an event tape
(bit 7 = place/remove, low 6 bits = square). The search machine only
ever appends at the tape's end; the display is a cursor walking the
tape, applying events forward or inverting them backward. Events are
self-inverting because a remove always pulls the deepest piece. So
pause, step-forward, step-back, rewind, and scrub aren't features
bolted onto the search — they fall out of the data structure.

## Overlays

Both are pure functions of the display board, so they're scrub-exact
at any cursor position:

- **Red = dead end (substrate-owned).** A square goes red when a piece
  was placed there, found doomed, and **pulled off** — marked at
  retraction time only, never predictively. Reds accumulate as a
  doomed branch unwinds and clear only when the search re-enters the
  square. Implementation: since a square's events strictly alternate
  place/remove, "empty ∧ ever-touched" *is* "the last event here was a
  retraction" — one per-square counter, O(1) in both scrub directions.
- **Indigo = provably impossible right now (toy-owned).** The knight
  computes BFS-unreachable-from-the-head through empties; the queens
  compute attacked squares. Indigo is the stronger fact and wins where
  both hold.

## Layout

- **`core/tape.zig`** — the shared engine: `Substrate(Toy)`, a comptime
  generic holding the tape (4M-event cap), the scrub display, the red
  overlay, and the full wasm ABI. `exportAbi(S)` emits the shared
  exports from one authoritative list, so two wasm modules can't
  drift. (It's a generic the toy instantiates with `@This()` rather
  than an `@import("root")` peek because under `zig test` the root
  module is the test runner.)
- **`knight.zig` / `queens.zig`** — the machines. A toy answers four
  questions: how many pieces mean solved (`target_count`), what's the
  next transition (`genOne` — one call, one event), how do you reset
  (`resetMachine`), and what's impossible right now
  (`computeImpossible`), plus its own adjacency/overlay exports. Each
  root compiles to its own freestanding wasm module of a few KB — no
  allocator, no imports.
- **`board.js`** — the one dumb JS host: canvas draw, transport
  buttons, speed slider, hover hints. Page shells differ only in an
  inline `window.CHESS_TOY` wording config (no fallback — a missing
  config crashes loud).

**Adding a toy** = one machine module answering the four questions +
a page-shell config in `zig-server/src/chess.zig` + a card on the
`/chess` index.

## Empirics (pinned in the tests)

`ops/check_chess` runs `zig test` on every toy root; the tests pin
empirically measured event counts, which freezes the move orderings —
a change that would make the toys *animate differently* can't land
silently.

- **Knight:** a naive geometric move order fails to finish from 54 of
  the 64 starting squares within 200M events. Degree-ascending order
  (frozen Warnsdorff) completes **all** starts: b2/d3/b6/a7 are
  backtrack-free (64 events); g6 is the worst at **2,520,884** — fits
  the 4M tape and crosses the JS boundary in ~170ms.
- **Queens:** d4 pin glides (20 events), a1 takes 218, g8 is the worst
  (306). All 64 pin squares solve.

## Build & wiring

`ops/build_chess_wasm` builds every toy root to `games/chess/*.wasm`
(gitignored) and is wired into `ops/start` and `ops/deploy`.
`ops/check_chess` is part of `ops/check`. The server route is
`zig-server/src/chess.zig` (index + both shells + `/chess/code`); the
`/chess` index wears the generic site top bar (Home · Chat · Blog +
viewer chip, per the `blog.zig` pattern — viewer resolved, never
gated). Home-page row lives in `pages/home.txt`; its gallery emblem is
`gallery/chess.svg`, a hand-authored mid-search board in the toys' own
visual grammar (red retracted branch, green onward hops, knight and
queen both solid because both toys shipped).
