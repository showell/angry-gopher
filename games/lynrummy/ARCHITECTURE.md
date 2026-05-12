# Lyn Rummy architecture

This is what future-Claude reads when asked to make a change
somewhere in the Lyn Rummy tree and isn't sure how the pieces
fit together.

For concrete entry points (Elm boots, server handlers, CLI
tools), see [`ENTRY_POINTS.md`](ENTRY_POINTS.md). This document
covers principles; that one covers the artifacts.

## Cold-agent orientation

- **TypeScript is the agent.** `games/lynrummy/ts/` hosts the
  BFS solver (`engine_v2.ts`, A* with kitchen-table heuristic
  + card-tracker liveness pruning), the verb→primitive
  pipeline, and `agent_player.ts` which plays full 2-hand
  games down to deck-low. TS writes DSL transcripts the Elm
  UI replays.
- **Elm is the autonomous client.** Deals, referees, replays,
  renders. `games/lynrummy/elm/`. Two surfaces — the full
  game (`Main.elm`, embedding `Game.Play`) and the
  single-board puzzle (`Puzzle.elm`, a dedicated host that
  composes `Game.*` primitives directly). The full game's
  Hint button routes through the TS engine over Elm ports +
  the JS glue. No Elm code path computes a hint or runs the
  BFS itself.
- **Go server is dumb file storage.** No referee, no dealer,
  no replay. Sequential session-id allocation is the one
  smart exception.

For cross-cutting working-style conventions, see
`~/showell_repos/claude-collab/agent_collab/`.

## DSL is the lingua franca

One canonical text grammar carries every long-lived artifact:
conformance fixtures, on-disk session files, the resume wire,
the puzzle-page boot flag, and agent self-play transcripts.
Three runtimes (Elm, TypeScript, Go) speak it. Most tests
parse `.dsl` files at run time — and there's no separate
syntax-reference manual, because the examples are the spec.

A board on disk:

```
at ( 20,  70): K♠ A♠ 2♠ 3♠
at ( 80, 160): T♦ J♦ Q♦ K♦
at (140, 100): 2♥ 3♥ 4♥
```

`at (top, left): cards` per stack. Loc coords padded to width
three so the `): ` separator lines up across stacks. `♥' / ♦' /
...` (trailing apostrophe) means the deck-2 copy of that card.

One action on the wire (`actions.dsl`):

```
6) move_stack [2♣ 3♦ 4♣ 5♥ 6♠ 7♥] at (62,320) -> (334,320) :: path (62,320@29176)(65,320@29269)(73,320@29285) ... (334,320@30394)
```

Seq number, verb, source-stack ref, destination, then a
captured drag path as `(left,top@tMs)` samples. Other verbs
have the same shape but different operands (`split [...] @N`,
`merge_stack [src] -> [tgt] /side`, `merge_hand <card> -> [tgt]
/side`, `place_hand <card> -> (loc)`, `complete_turn`, `undo`).

A full-game session header (`meta`, the first half of a resume
bundle):

```
created_at: 1778500538
label:

board:
  at ( 20,  70): K♠ A♠ 2♠ 3♠
  ...

Player One Hand:
  8♥ 9♥ T♥' Q♥' K♥'
  3♦' 8♦' Q♦'
  2♣' 5♣ 7♣' 8♣' 9♣ T♣ K♣'

Player Two Hand:
  ...

deck: 4♠' 4♦ 6♠' Q♠ 5♠' T♣' 3♥' A♠' ...

active_player: 0
turn_index: 0
cards_played_this_turn: 0
victor_awarded: false
```

Top-level scalars at the bottom, named sections in between.
Hand rows mirror the UI panel: one indented line per non-empty
suit, in Heart-Spade-Diamond-Club display order, each row
sorted by value. Open the file in your editor and you see what
the player sees on screen.

**Pipeline.** `ops/check-conformance` is the single entry point;
it runs `ops/embed_dsls_for_elm.ts` (the one codegen step —
inlines `.dsl` files into a generated `tests/Lib/DslContent.elm`
so the Elm runner can read them without `fs`), then the TS
suite, then the Elm suite. Most parsing happens at test time
inside each runner via `tests/Lib/ConformanceDsl.elm` and
`ts/test/conformance_dsl.ts`. There are also some traditional
non-DSL unit tests (pure helpers, decoders, hand-sorted UI
rendering) — they continue to pull their weight and aren't
worth converting.

**Bridges.** The DSL is the load-bearing example of the
redundancy-as-asset paradigm: two independent runners parse
the same scenarios and must agree scenario-by-scenario. See
[`../../BRIDGES.md`](../../BRIDGES.md).

## What Lyn Rummy is

A card game with two-player rules — but in this codebase
**a single-human game**: solitaire or human-vs-agent.
Two-human multiplayer is out of scope. The rules are
domain-specific; what matters here is what the code has to
do: validate moves, score turns, render a physical board,
let a human drag cards around, let an agent play
convincingly too.

## What the game feels like (read this first)

Two primitives define the game's feel.

**Board reorganization.** The shared board is a mutable
structure of card stacks. A turn is largely an act of
rearranging that structure: splitting runs, merging pieces,
sliding things around to make room. The board is spatially
expressive — you're reorganizing structure, not just placing
tiles.

**Hand↔board commitment.** Playing a card from your hand onto
the board is a bet: you believe the board will hold it as part
of a valid meld by the time your turn ends. Undo is the escape
valve — while you're still in your turn you can walk back any
primitive, including returning a hand card to your hand. Once
you click End Turn, the commitment is permanent.

The trickiest undo is the hand-card one, because it has to
reverse both a board change and a hand change simultaneously.

The most compact way to see both mechanics working is
`conformance/scenarios/undo_walkthrough.dsl` — two short
scenarios that read like game transcripts and cover exactly
these two primitives.

## The mission

**A human plays Lyn Rummy through the Elm UI, against a
TypeScript agent, and can watch the agent's moves unfold
through the same UI in a way that reads as another player
playing — not as a machine logging primitives to a server.**

The third constraint does the most work: the UI has to be
able to re-tell the agent's story visually, at human speed,
with motion that looks like a drag. Replay fidelity and the
TS agent's spatial-planning rules both trace back to it.

## Events are the system

A Lyn Rummy game, autonomous or human-played, is a
manifestation of events. Each event is a deliberate choice —
a human's drag, an agent's decision to peel a 5D and merge
it — and each event must be represented clearly within
components and across component boundaries.

The wire format carries events across boundaries. The referee
decides whether a proposed event was legal. The action log
persists events. The replay walker re-manifests them. Gesture
telemetry preserves physical fidelity alongside logical
content. All of these exist in service of the events.

If you're deciding whether logic belongs in component A or B,
ask: what event is being handled, and which component handles
it without distorting its representation. That question is
upstream of language choice, file layout, and performance.

## Each actor owns its own view

**Each actor owns its own view of the world, including its
own event log.** The Elm UI has a log. The TS agent has a log
(the transcript). The Go server stores the events Elm POSTed
but doesn't run a referee.

Consequences:

- **Each client is its own gatekeeper.** Elm has its own
  referee module; the TS agent uses `applyLocally` +
  `findViolation` / `assertNoOverlap` per primitive.
- **Bootstrap pulls down the data the client needs to play.**
  The Elm UI does this with at most one follow-up fetch AFTER
  the HTML page loads, depending on the surface mode:
    - `POST /new-session` (full game, fresh start) — Elm
      POSTs the locally-dealt initial state as a DSL string
      (`text/plain` body, parseable by Elm itself on resume);
      server allocates a session id and writes the body
      verbatim to `<session>/meta`.
    - `GET /sessions/<sid>/actions` (full game, deep-link
      resume) — server returns one `text/plain` document:
      the meta DSL, a `---` separator line, then the
      action-log DSL. Elm splits and parses each half.
  The puzzle host is the inverse: its page-render carries the
  entire boot payload (`session_id:` scalar + `board:` block)
  inside the Elm `Browser.element` flag as one DSL string, so
  the puzzle client has zero post-load bootstrap fetches. Once
  bootstrap lands (or, for the puzzle host, once the page
  renders), the Elm UI is fully primed.
- **Ongoing play is fully local.** After bootstrap completes,
  no inbound HTTP gates user input. The only "pending" state
  the Elm UI tracks is for TS engine responses (Hint shows
  "Thinking…"); there is no Go-side analogue. Elm POSTs
  actions and gesture telemetry as fire-and-forget writes
  (`sendAction`, `sendAnnotation`); the `ActionSent` handler
  takes no action on success and never blocks further play.
- **The server is observability, not coordination.** Once
  bootstrap is done, Elm's only remaining traffic to Go is
  outbound writes that exist so anyone reading the data tree
  (a future replay viewer, a human inspecting
  `games/lynrummy/data/`) can see what happened. The server
  is not part of any decision loop.
- **Autonomous TS-agent play doesn't touch the server at all.**
  `agent_player.ts` plays a complete game locally;
  `transcript.ts` writes the result straight to the file
  system, no HTTP.

## The cast of components

- **Elm UI.** The autonomous client. Two surfaces — full
  game (`Main.elm`, embedding `Game.Play`) and the
  single-board puzzle (`Puzzle.elm`, dedicated host).
  Deals locally (`Lib.Dealer.dealFullGame seed`), runs its
  own referee, appends to its own action log, can replay at
  any time. Originates events from drags, from the **TS
  engine** (Hint button on the full-game surface) over Elm
  ports + the JS glue, or from a stored transcript. Once
  bootstrap is done, the Elm UI's only Go-bound traffic is
  outbound action POSTs.
- **TypeScript agent.** A complete player without a
  presentation layer, at `games/lynrummy/ts/`. Owns the
  solver (`engine_v2.ts`) and the physical-execution layer
  (`verbs.ts` + `physical_plan.ts`) that turns a solver plan
  into the primitive sequence a human at the kitchen table
  would emit. `agent_player.ts` plays full 2-hand games to
  deck-low; `transcript.ts` writes them as Elm-replayable DSL
  (`meta` + `actions.dsl`) and `validate_session.ts` reads the
  emitted files back through the same `applyLocally` the
  conformance walkthroughs use. The TS agent has no DOM — so
  it cannot speak pixel-level viewport coords for a live drag — but it
  KNOWS the board frame and reasons about geometry there.
  Discipline: **constraints must be real, not artificial.**
  "TS has no eyes" is not the same as "TS has no geometry."
- **Go server (Angry Gopher).** Dumb URL-keyed file storage
  for LynRummy session data. SQLite hosts only the seeded
  `users` table; LynRummy session files (`meta`, `actions.dsl`)
  live as DSL under `games/lynrummy/data/`. The server never
  parses what it stores beyond prepending its own scalars to
  the meta header.

## Multiple action logs, one event shape

Each entry in any of these logs is one wire action — split,
merge_stack, merge_hand, place_hand, move_stack,
complete_turn, undo. The shape is identical across Elm, TS,
and Go; that's what lets actors integrate each other's events
without translation.

Engagement levels:

- **Fully autonomous.** Log never leaves the actor. The TS
  agent in self-play operates here, writing DSL straight to
  the file system without any HTTP.
- **Outbound-only after bootstrap.** Actor pulls down what it
  needs at startup, then writes events for others (or later
  replay) without pulling anything back. The Elm UI operates
  here: at most one bootstrap fetch (session creation OR
  resume bundle for the full game; the puzzle host gets its
  bootstrap data baked into Elm flags at HTML-render time
  instead), then fire-and-forget action POSTs for the rest
  of play. The TS agent operates here too when generating
  transcripts; Steve watches the result via Elm replay.
- **Two-way coordination.** Both actors post events AND
  integrate events from the other during ongoing play. Each
  incoming event passes through the receiving actor's referee
  before being added to its log. (Not currently exercised by
  any production surface; the architecture supports it.)

The shape's consistency across actors is enforced by the
DSL-driven conformance bridge. See
[`../../BRIDGES.md`](../../BRIDGES.md).

Three consequences:

1. **Game state is a pure function of (deck seed + the
   actor's action log).** No hidden side state.
2. **Replay is mechanically trivial.** Walk the log, feed
   events through the same reducer used live.
3. **Who proposed an event doesn't matter to replay.**
   Human, agent, server-coordinated — a log is a log.

## Elm is layered around source-aware events

Events arrive from multiple sources — human drags, Elm's hint
engine, the agent as opponent, the replay walker. Elm captures
**full source information** along with the event.

But Elm folds every source-specific input into a **common
event shape that its internal layers execute through the SAME
mechanisms** — live or three minutes later during replay. No
"live path" vs "replay path" that drift apart. Same event,
same reducer.

The layers:

- **Capture.** Ingests source-specific inputs and produces
  events in the common shape, enriched with source metadata.
- **Integration.** Decides whether an incoming event joins
  Elm's action log, using its referee.
- **Execution.** Applies events to the model via one reducer.
- **Render.** Draws board, hand, drag overlay from the
  current model. The DOM is the source of truth for where
  things actually show on screen — render-layer concern,
  not game-layer.

## Hints are client-side

**Server owns wire and storage; clients own hint logic.** Hint
generation is a client concern; the Go server is not asked to
reason about gameplay. In practice both surfaces share the
same TS hint engine (`hand_play.ts:findPlay` rendered via
`formatHint`), reached over Elm ports + the JS glue. Nothing
about that arrangement is forced — a future client could
ship its own hint logic and not contradict the architecture.

This is load-bearing for the TS agent. The TS agent IS its
own hint logic plus a transcript writer. Without the server
trying to help, the agent is self-sufficient.

## Durable facts vs. environment-bound facts

A move-as-recorded has two layers:

- **Durable.** The LOGICAL move (which hand card, which
  target stack, which side) and the BOARD-FRAME landing
  coord. The board's top-left is `(0, 0)`. These facts
  survive any future environment.
- **Rich.** Raw pointer path in viewport pixels, timestamped
  per sample, plus the environmental context at capture
  (viewport dimensions, device pixel ratio). Faithful at
  capture time; geometric validity depends on environment.

At replay: if the captured environment matches the current
environment, play back the raw path — pixel-faithful. If the
environment has drifted, fall back to synthesizing from the
durable layer.

The TS agent emits primitives only — no drag paths. Elm
synthesizes drags on replay from the durable board-frame
coords. Replay branches on path presence: `Just (p :: rest)`
→ faithful playback, `Nothing` → synthesize.

## Frames of reference

Two coordinate frames; nobody should confuse them.

- **Board frame.** Origin `(0, 0)` at the board's top-left.
  Stack `loc: {top, left}` is in this frame. The 800×600
  play surface is fixed. The TS agent uses board frame
  natively.
- **Viewport frame.** Origin at the browser window's top-left.
  Mouse coords and the Elm drag floater live here.

**Intra-board moves stay in board frame.** Elm translates
board → viewport at render time using the board's live DOM
rect.

**Hand-to-board moves require viewport frame for the drag
path** (the drag starts in the hand area, which has no
board-frame coord). The LANDING is always in board frame.

If you're writing code that speaks coordinates on the wire
and you're not SURE which frame you're in, stop.

## Agents plan, then execute

**Plan the whole move in your head before emitting the
primitives.** Humans hold two or three logical board changes
in mind, count cards, do single-digit arithmetic, and reason
spatially. A trick that needs 6–7 physical primitives is
within comfortable human planning range.

The TS agent's physical-execution layer (`ts/src/verbs.ts` +
`ts/src/physical_plan.ts`) mimics this. Single loop over the
solver's plan with **honest state**: `sim` is the real board
(no hand cards on it); `pendingHand` tracks cards still in
the hand. Three rules:

- **R1 (hand-direct):** a hand card whose end-state is
  "absorbed into stack S" is dragged from the hand directly
  to S via `merge_hand` — no transient board singleton.
- **R2 (small→large):** for board-to-board merges, the
  smaller stack physically moves. Source ↔ target swap with
  side flip preserves merged card order.
- **R3 (don't move if there's room):** pre-flight fires only
  when the post-action board would crowd `findCrowding`
  (`PLANNING_MARGIN = 15`, between legal `BOARD_MARGIN = 7`
  and human-feel `PACK_GAP = 30`). Interior splits still
  pre-flight unconditionally.

Full doctrine in `ts/PHYSICAL_PLAN.md`. Per-step overlap
checks in `conformance/scenarios/physical_plan_corpus.dsl`.
Planning horizon is a single trick — multi-trick lookahead
is out of scope.

## Design principles

- **Redundancy as asset — bridges with forced agreement.**
  Two or more independent representations + an automated
  agreement check > a single canonical one. See
  [`../../BRIDGES.md`](../../BRIDGES.md).
- **Events drive the system.** Wire, referee, action log,
  replay all serve faithful event-carrying.
- **Each actor owns its own view.** No actor is authoritative
  above the others; each has its own log, referee, acceptance
  policy.
- **Record facts, decide later.** The wire carries what
  happened, not instructions for how to interpret it.
- **Own the whole system.** The wire format is a contract we
  control. If a component needs a fact to behave well, put
  the fact on the wire.
- **Constraints must be real, not artificial.** Verify
  before designing around.
- **Hints are client-side.** Each client owns its hint logic.
- **Faithful when possible, durable always.** Pixel-faithful
  replay when environment matches; board-frame logical facts
  survive any environment.
- **Plan, then execute.** Agents simulate the full move
  mentally before emitting primitives.
- **Compute answers you own.** If state is yours to render
  or generate, derive answers about it directly. Don't
  round-trip through an opaque system to learn what you
  already know. See `feedback_compute_dont_delegate.md`.
- **One representation per concept.** Don't let two models
  for the same thing co-exist. See `doctrine_make_state_honest.md`
  and `doctrine_eliminate_dont_paper_over.md`.

## Where to find more

### Build and run

All build, launch, and test ops go through `ops/` scripts
(repo root). `ops/list` for the index. The short version:

- `ops/start` — kill stale processes, rebuild Go, recompile
  Elm, start both servers, wait for ready.
- `ops/build_elm` — bundle the TS engine to `engine.js` (via
  `ops/build_engine_js`), then compile Main.elm + Puzzle.elm.
  Full build steps documented in
  [`BUILDING.md`](./BUILDING.md).
- `ops/check-conformance` — **the commit gate for Elm
  work.** Embeds .dsl files into Elm, runs TS conformance +
  elm-test + elm-review. Do not commit Elm without a passing run.
- `ops/check` — full preflight (conformance + Go build).

Don't hand-compose `go run .`, `elm make`, or `go test ./...`
— those silently drop sequencing the scripts encode.

### Subsystem landing pages

- [`./README.md`](./README.md) — repo-level overview.
- [`./ts/README.md`](./ts/README.md) — TypeScript agent
  subsystem (BFS solver + physical-execution layer +
  transcript writer). See also
  [`./ts/PHYSICAL_PLAN.md`](./ts/PHYSICAL_PLAN.md) and
  [`./ts/ENGINE_V2.md`](./ts/ENGINE_V2.md).
- [`./elm/README.md`](./elm/README.md) — Elm UI. Two
  surfaces: the full game (`Main.elm`, embedding
  `Game.Play`) and the single-board puzzle (`Puzzle.elm`,
  dedicated host). Hints route through the TS engine.

### Cross-cutting

- [`../../BRIDGES.md`](../../BRIDGES.md) — redundancy-as-asset
  paradigm and bridge inventory.
- [`../../GLOSSARY.md`](../../GLOSSARY.md) — vocabulary.

### Conformance & testing

- `games/lynrummy/conformance/scenarios/*.dsl` — canonical
  scenarios. Parsed natively at test time by both runners:
  Elm via `tests/Lib/ConformanceDsl.elm` →
  `tests/Lib/ConformanceTests.elm` (per-op verifiers); TS
  via `ts/test/conformance_dsl.ts` and per-test consumers.
  **New agents: read `undo_walkthrough.dsl` early.** It's
  the most compact readable summary of how the game's
  interaction model actually works.
- TS-specific gesture-layer fixtures live in
  `physical_plan_corpus.dsl` (integration: hand cards +
  multi-verb plans + R1/R3 cases) and
  `verb_to_primitives_corpus.dsl` (per-verb expansion).
  Both runners assert `findViolation == null` after every
  emitted primitive.
- `games/lynrummy/DSL_CONVERSION_GUIDE.md` — how to extend
  DSL coverage.

### Memory

The memory index at
`~/.claude/projects/-home-steve-showell-repos-angry-gopher/memory/MEMORY.md`
indexes durable doctrines and feedback. Two load-bearing
ones worth naming inline:

- **`doctrine_make_state_honest.md`** — record facts, decide
  later; shape matches reality.
- **`doctrine_eliminate_dont_paper_over.md`** — change the
  shape, not the adapter.

## Two host shapes for two domains

The repo has two browser entry points, each with the host
shape its domain wants:

- **Embedding (full game).** `Main.elm` is a thin harness;
  `Game.Play` is the embeddable component. Exposes
  `init / update / view / subscriptions` + a typed `Output`
  union for the few things the host legitimately needs.
  Extracted so a future host (tutorial, side-by-side
  agent-vs-human viewer) can host it without rebuilding.
- **Dedicated host (puzzle).** `Puzzle.elm` composes
  `Game.*` primitives directly without going through
  `Game.Play`. Carries its own `Msg` / `Model` / replay
  engine. The puzzle's domain (board only, no hand, no turn
  cycle) made unified-Msg/Model contortions Maybe-everywhere;
  going dedicated dropped that complexity.

Choose by domain. If a new surface plausibly wants
full-game semantics, embed `Game.Play`; if its domain is
materially narrower, follow `Puzzle.elm`'s pattern.

## The puzzle host

The puzzle host (`/gopher/puzzle/`) renders a single
mid-game position seeded from
`conformance/mined_seeds.dsl`. Solo, no opponent — drag,
undo, replay; no agent-play, no scoring.

- Featured board: hardcoded `featuredPuzzleName` in
  `views/puzzle.go`. To rotate, edit the string and restart.
- Server-baked flag: at HTML-render time `views/puzzle.go`
  picks the puzzle, allocates a session id, writes the
  session's `meta` DSL file, and emits a single DSL string
  (containing both the `session_id:` scalar and the `board:`
  block) into the Elm `Browser.element` flag. The client has
  zero follow-up bootstrap fetches.
- Wire: `POST /gopher/puzzle/sessions/<id>/actions` for
  every drag outcome and Undo, fire-and-forget. Files land at
  `games/lynrummy/data/puzzle/sessions/<id>/{meta,actions.dsl}`.
- Replay: the puzzle has its own engine in
  `Puzzle/Replay.elm` — a simpler sibling of
  `Lib.Animation.Animate` that operates on `List CardStack`
  (no GameState, no hand-card logic). Reuses
  `Lib.Animation.BoardDragAnimate` directly for the path-driven
  floater.
- Puzzle sessions live in their own top-level namespace
  (`data/puzzle/sessions/`) separate from full-game sessions
  (`data/lynrummy-elm/sessions/`) and allocate ids from a
  separate counter (`next-puzzle-id.txt`). They are not
  resumable: a page reload starts a fresh session.

## Algorithm benchmarks

Solver bench gold lives in `games/lynrummy/ts/bench/`
(`baseline_board_81_gold.txt`, `bench_outer_shell_gold.txt`).
Run via `npm run bench:check-baseline` from
`games/lynrummy/ts/` to regression-check; regenerate with
`npm run bench:gen-baseline` after a deliberate solver
change. Corpus inputs are language-neutral DSL at
`conformance/scenarios/planner_corpus.dsl` and
`baseline_board_81.dsl`.
