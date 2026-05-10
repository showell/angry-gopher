# LynRummy — Elm UI subsystem

The Elm LynRummy client. Renders the board + hand, captures
live drag gestures, runs its own referee, keeps its own
action log, replays stored logs. Two surfaces — the full
game (`Main.elm`, embedding `Main.Play`) and the
single-board puzzle (`Puzzle.elm`, a dedicated host that
composes `Game.*` primitives directly).

## Setup

```
npm install
```

Pins `elm` and `elm-test` locally so `./check.sh` and
`ops/start` invoke them directly. `node_modules/` is
gitignored.

## External coupling

Once running, the Elm UI talks to two systems:

- **TS engine** via Elm ports + `engine_glue.js`. One entry
  point: the Hint button on the full-game surface. All other
  gameplay logic — dealing, refereeing, turn transitions,
  replay — lives in Elm.
- **Go server** via HTTP. Bootstrap (one follow-up fetch
  after the HTML page load, depending on the surface mode:
  `POST /new-session` for a fresh full game, `GET
  /sessions/<sid>/actions` for a resumed full game; the
  puzzle host gets its session id + initial board baked into
  Elm flags at HTML-render time, so it has no follow-up
  bootstrap fetch) plus outbound writes during play (action
  POSTs, fire-and-forget). After bootstrap, no Elm code path
  waits on a Go HTTP response.

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

## Two-host design

Two browser entry points share the rendering primitives in
`Game.*` but otherwise own their own `Msg` / `Model` shapes:

- **`Main.elm`** (full game) — owns the embeddable
  `Main.Play` component. `Main.State.Model` carries
  GameState + drag + action log + replay state; `Main.Msg`
  is the unified Msg.
- **`Puzzle.elm`** (single-board puzzle) — dedicated host.
  Composes `Game.*` primitives directly: `Game.BoardView`,
  `Game.BoardGesture`, `Game.BoardDrag`, `Game.Drag`,
  `Game.PointerInput`, `Game.ActionLog`, `Game.Execute`,
  plus its sibling replay engine `Puzzle.Replay`. Doesn't
  import `Main.*`.

The dedicated-host pattern (vs. embedding) was the right
shape once the puzzle's domain (board only, no hand, no
turn cycle) made unified-Msg/Model contortions
Maybe-everywhere. New surfaces with a different domain
should follow `Puzzle.elm`'s pattern; new surfaces that
genuinely want full-game semantics can embed `Main.Play`.
