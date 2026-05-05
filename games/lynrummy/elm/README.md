# LynRummy — Elm UI subsystem

The Elm LynRummy client. Renders the board + hand, captures
live drag gestures, runs its own referee, keeps its own
action log, replays stored logs. Two surfaces — the full game
(`Main.elm`) and the Puzzles gallery (`Puzzles.elm`) — both
embed `Main.Play`.

## Setup

```
npm install
```

Pins `elm` and `elm-test` locally so `./check.sh` and
`ops/start` invoke them directly. `node_modules/` is
gitignored.

## External coupling

Once running, the Elm UI talks to two systems:

- **TS engine** via Elm ports + `engine_glue.js`. Two entry
  points: the Hint button (full game + puzzles) and the
  Let-Agent-Play button (puzzles only). All other gameplay
  logic — dealing, refereeing, turn transitions, replay —
  lives in Elm.
- **Go server** via HTTP. Bootstrap (one or two follow-up
  fetches after the HTML page load: session creation /
  resume bundle / puzzle catalog) plus outbound writes
  during play (action POSTs + gesture telemetry, all
  fire-and-forget). After bootstrap, no Elm code path waits
  on a Go HTTP response.

For the system-level picture, see
[`../ARCHITECTURE.md`](../ARCHITECTURE.md). For concrete
entry points, see [`../ENTRY_POINTS.md`](../ENTRY_POINTS.md).

## Reading order for the Elm code

Per-module roles live in each file's top-of-file comment.
Starting points, organized by Elm's capture / integration /
execution / render layering:

- **Capture.** `src/Main/Gesture.elm` (pointer events),
  `src/Main/Wire.elm` (wire deliveries + the
  action-log-entry decoder), and `src/Main/Msg.elm` (the
  unified Msg type).
- **Integration.** `src/Game/Rules/Referee.elm` (Elm's own
  referee — Go does not run a referee).
- **Execution.** `src/Main/Apply.elm` (`applyAction`),
  `src/Game/Reducer.elm` (the pure action-log reducer),
  `src/Game/Game.elm` (turn transitions).
- **Render.** `src/Main/View.elm` (top-level composition +
  pinned layout), `src/Game/View.elm` (rendering primitives),
  `src/Game/HandLayout.elm` and
  `src/Game/Physics/BoardGeometry.elm` (frame constants).

Domain types live under `src/Game/`: `CardStack.elm`,
`Hand.elm`, `Dealer.elm`, etc. Each top-of-file comment names
the module's responsibility.

## The locked-down rule layer

`src/Game/Rules/` holds pure game rules and primitives that
are battle-tested and not expected to change. Locked down by
property tests so any regression breaks loudly.

- **`Game.Rules.Card`** — Card type, suit / value enums,
  parsers, encoders, double-deck construction.
- **`Game.Rules.StackType`** — the 6-way classification
  oracle (`Incomplete | Bogus | Dup | Set | PureRun |
  RedBlackRun`), `successor` / `predecessor` on the 13-cycle,
  `valueDistance`, plus the rule predicates `isLegalStack` /
  `isPartialOk` / `neighbors`.
- **`Game.Rules.Referee`** — turn-end validation.

Tests for these live in `tests/Game/CardTest.elm` and
`tests/Game/StackTypeTest.elm` (kept flat, not under a
`tests/Game/Rules/` subtree). The discipline is **exhaustive
enumeration over the finite card domain** rather than
property fuzz — the domain is small enough (every value,
every suit, every deck; every length 3–13) that we cover the
whole state space cell-by-cell. The two files explicitly
note this choice ("`allSuits` rather than fuzz. The domain
is finite…"). See
`memory/feedback_segregate_by_volatility_class.md` for the
broader volatility-class discipline this layer sits in.

The TS agent uses the same rule shapes; see
`../ts/src/rules/card.ts` and
`../ts/src/classified_card_stack.ts`.

## Embeddable-component design goal

The app is structured so `Main.Play` embeds into hosts other
than `Main.elm` — for example the Puzzles gallery, where
each puzzle panel embeds its own `Main.State.Model`. The
split:

- **`Main.Play`** — the embeddable component. Exposes
  `Config` (`NewSession` / `ResumeSession` / `PuzzleSession`),
  `Output`, plus `init / update / view / subscriptions` (and
  `mouseMove`). The component's `Model` lives in
  `Main.State`; the `Msg` type lives in `Main.Msg`. Hosts
  import them directly from there.
- **`Main.elm`** — thin harness. Owns the URL-pinning port,
  the engine port pair, `Browser.element` boot, and the
  viewport-filling outer shell. Routes Play's Output into
  port calls.
- **`Main.State.Model.gameId`** — per-instance id used by
  `State.boardDomIdFor` so multiple Play instances coexist
  on one page without DOM collisions.

When adding a new surface that might embed Play (tutorial
host, side-by-side agent-vs-human viewer, etc.), import
`Main.Play` directly and follow the `Puzzles.elm` pattern.
`Game.Replay` follows the same shape.
