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
  games down to deck-low. TS writes JSON transcripts the Elm
  UI replays.
- **Elm is the autonomous client.** Deals, referees, replays,
  renders. `games/lynrummy/elm/`. The `Game.Agent.*` BFS port
  and `Game.Strategy.*` trick engine are still wired in for
  the live-game hint button — the only surface not yet routed
  through the TS engine, tracked as `TS_ELM_INTEGRATION` in
  `claude-steve/MINI_PROJECTS.md`.
- **Go server is dumb file storage.** No referee, no dealer,
  no replay. Sequential session-id allocation is the one
  smart exception.

For cross-cutting working-style conventions, see
`~/showell_repos/claude-collab/agent_collab/`.

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

- **Autonomous play doesn't need the server.** Elm runs its
  own log + referee in memory. The TS agent's `agent_player.ts`
  plays a complete game locally; `transcript.ts` writes the
  result straight to the file system, no HTTP.
- **Each client is its own gatekeeper.** Elm has its own
  referee module; the TS agent uses `applyLocally` +
  `findViolation` / `assertNoOverlap` per primitive.
- **The server is observability, not coordination.** Elm
  POSTs events for storage / reload-resume; nothing in the
  live loop depends on the response.

## The cast of components

- **Elm UI.** The autonomous client. Deals locally
  (`Game.Dealer.dealFullGame seed`), runs its own referee,
  appends to its own action log, can replay at any time.
  Originates events from drags, its own hint engine, or a
  stored transcript.
- **TypeScript agent.** A complete player without a
  presentation layer, at `games/lynrummy/ts/`. Owns the
  solver (`engine_v2.ts`) and the physical-execution layer
  (`verbs.ts` + `physical_plan.ts`) that turns a solver plan
  into the primitive sequence a human at the kitchen table
  would emit. `agent_player.ts` plays full 2-hand games to
  deck-low; `transcript.ts` writes them as Elm-replayable
  JSON. The TS agent has no DOM — so it cannot speak
  pixel-level viewport coords for a live drag — but it
  KNOWS the board frame and reasons about geometry there.
  Discipline: **constraints must be real, not artificial.**
  "TS has no eyes" is not the same as "TS has no geometry."
- **Go server (Angry Gopher).** Dumb URL-keyed file storage
  for LynRummy session data. SQLite hosts only the seeded
  `users` table; LynRummy session data lives as plain JSON
  under `games/lynrummy/data/`.

## Multiple action logs, one event shape

Each entry in any of these logs is one wire action — split,
merge_stack, merge_hand, place_hand, move_stack,
complete_turn, undo. The shape is identical across Elm, TS,
and Go; that's what lets actors integrate each other's events
without translation.

Engagement levels:

- **Fully autonomous.** Log never leaves the actor.
- **Outbound-only.** Actor writes events for others (or
  later replay) but pulls nothing back. The TS agent operates
  here — writes JSON straight to the file system; Steve
  watches via Elm replay.
- **Two-way coordination.** Both actors post events AND
  integrate events from the other. Each incoming event passes
  through the receiving actor's referee before being added to
  its log.

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

**Server owns wire and storage; each client owns its own hint
logic.** Elm has its hint module; the TS agent has
`hand_play.ts`. They serve different players and don't have
to agree.

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
- `ops/build_elm` — compile Main.elm + Puzzles.elm bundles.
- `ops/check-conformance` — **the commit gate for Elm
  work.** Runs fixturegen + TS conformance + elm-test +
  elm-review. Do not commit Elm without a passing run.
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
- [`./elm/README.md`](./elm/README.md) — Elm UI. The
  `Game.Agent.*` BFS port and `Game.Strategy.*` trick engine
  retire when `TS_ELM_INTEGRATION` lands.

### Cross-cutting

- [`../../BRIDGES.md`](../../BRIDGES.md) — redundancy-as-asset
  paradigm and bridge inventory.
- [`../../GLOSSARY.md`](../../GLOSSARY.md) — vocabulary.

### Conformance & testing

- `../../cmd/fixturegen/main.go` — DSL → Elm + JSON
  generator. The cross-language parity bridge between Elm
  and TS. Don't run ad-hoc; use `ops/check-conformance`.
- `games/lynrummy/conformance/scenarios/*.dsl` — canonical
  scenarios. **New agents: read `undo_walkthrough.dsl`
  early.** It's the most compact readable summary of how
  the game's interaction model actually works.
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

## Elm components should be easy to embed

When a feature earns a second surface (the main play
surface AND a gallery of curated puzzle panels each with
their own play instance), the architecture should make that
cheap:

- **Extract the whole-app logic into a component module**
  (`Main.Play`, `Game.Replay`) with init/update/view/
  subscriptions + a typed `Output` union for the few things
  the host legitimately needs.
- **Shrink `Main.elm` to a thin harness** — ports,
  `Browser.element` boot, routing Output into host
  concerns.
- **Per-instance DOM ids.** `gameId : String` so multiple
  instances coexist without DOM collisions.
- **`position: relative` + fixed size on the component's
  outer div.** Host decides where it lives in the page.
- **Fixed-position overlays are fine.** Drag floaters,
  popups, modals stay viewport-level.

For new Elm features: if it could plausibly show up in more
than one host context, design it as a component from the
start.

## Puzzles as study instrument

The Puzzles gallery (`/gopher/puzzles/`) observes play on
curated mid-game situations and feeds divergences back into
the agent.

- Catalog: `games/lynrummy/puzzles/puzzles.json` is the
  committed gallery served at `/gopher/puzzles/catalog`.
  Currently frozen; refresh by writing a TS generator from
  scratch when needed. The catalog response carries a
  freshly-allocated `session_id` that all panels share —
  there is no sign-on / login gate (Lyn Rummy is solo).
- Elm gallery: one Play instance per puzzle, sharing a single
  page-load session id. Human plays inline; drags capture via
  the normal telemetry pipeline.
- Per-attempt session data: a single page-load session under
  `data/lynrummy-elm/sessions/<id>/` hosts every puzzle on the
  page. Actions and annotations land at
  `actions/<puzzle_name>/<seq>.json` and
  `annotations/<puzzle_name>/<seq>.json` so each puzzle's
  per-Play seq counter (which restarts at 1) doesn't clobber
  its siblings.

## Algorithm benchmarks

Solver bench gold lives in `games/lynrummy/ts/bench/`
(`baseline_board_81_gold.txt`, `bench_outer_shell_gold.txt`).
Run via `npm run bench:check-baseline` from
`games/lynrummy/ts/` to regression-check; regenerate with
`npm run bench:gen-baseline` after a deliberate solver
change. Corpus inputs are language-neutral DSL at
`conformance/scenarios/planner_corpus.dsl` and
`baseline_board_81.dsl`.
