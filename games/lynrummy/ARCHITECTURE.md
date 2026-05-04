# Lyn Rummy architecture

**Status:** `STILL_EVOLVING`. The principles are stable;
specifics may lag or lead the code. If you spot a discrepancy
between this doc and the running code, the principles win as
intent; update the doc or the code accordingly.

This is what future-Claude reads when asked to make a change
somewhere in the Lyn Rummy tree and isn't sure how the pieces
fit together. It exists because every day we worked on this
without it, we paid a tax.

**Essay surface:** for any structured or multi-part reply, write to `~/showell_repos/claude-steve/randomNNN.md` and return `http://localhost:9100/steve/randomNNN.md`. Full workflow: `~/showell_repos/claude-collab/agent_collab/ESSAY_SURFACE.md`.

The scope is Lyn Rummy specifically. Angry Gopher — the broader
Go server that hosts it — only shows up as context when a
Lyn Rummy concern crosses into it.

For a snapshot of what concrete entry points exist today (Elm
boots, server handlers, CLI tools) and how mature each one
is, see [`ENTRY_POINTS.md`](ENTRY_POINTS.md). This document
covers principles; that one covers the actual artifacts
running.

## Cold-agent orientation

**If you're arriving with no session context,** read this
paragraph before reading anything else. The principles below
are stable; the implementation landscape settled around
May 2026.

Today's shape:

- **TypeScript is the agent.** `games/lynrummy/ts/` hosts the
  BFS solver (`engine_v2.ts`, A* with kitchen-table heuristic
  + card-tracker liveness pruning), the verb→primitive
  pipeline, and `agent_player.ts` which plays full 2-hand
  games down to deck-low. TS writes JSON transcripts that
  the Elm UI replays.
- **Elm is the autonomous client.** Deals, referees, replays,
  renders. `games/lynrummy/elm/`. The `Game.Agent.*` BFS port
  and `Game.Strategy.*` trick engine are still wired in for
  the live-game hint button — that surface is the only thing
  not yet routed through the TS engine, tracked as
  `TS_ELM_INTEGRATION` in `claude-steve/MINI_PROJECTS.md`.
- **Python is legacy/utility.** Some test code, the dealer,
  some tools. The Python solver retired during the TS
  migration; do not extend Python-side solver work.
- **Go server is dumb file storage.** No referee, no dealer,
  no replay. Sequential session-id allocation is the one
  smart exception. The whole `games/lynrummy/` Go domain
  package retired 2026-04-28.

If you encounter prose describing a Python BFS as the
experimentation surface, or a Go component doing domain
work, treat it as stale and flag rather than acting on it.

For cross-cutting working-style conventions (essay surface,
ops scripts, commit patterns), see the agent-collaboration
docs at `~/showell_repos/claude-collab/agent_collab/`.

## What Lyn Rummy is

A card game with two-player rules — but in this codebase
**a single-human game** as of 2026-04-28: solitaire or
human-vs-agent. Two-human multiplayer is out of scope (product
decision: scheduling friction outweighs the value once Elm has
agent capability built in). The rules are domain-specific;
they're not this document's subject. The mechanics matter here
only insofar as they shape what the code has to do: validate
moves, score turns, render a physical board, let a human drag
cards around, let an agent play convincingly too.

One important piece of context: Steve wrote a working
Lyn Rummy implementation in TypeScript before this codebase
existed. That means he brings both domain knowledge (what a
move means, what "feels right" at the table) and
implementation experience (which problems are fundamental and
which are artifacts of an early shape). A lot of this
document's claims earned their weight during that earlier
implementation and carried over.

## What the game feels like (read this first)

Two primitives define the game's feel, and they're worth
naming before anything else — because every architectural
decision downstream traces back to one or both of them.

**Board reorganization.** The shared board is a mutable
structure of card stacks. A player's turn is largely an act
of rearranging that structure: splitting runs, merging pieces,
sliding things around to make room. The board is spatially
expressive — you're reorganizing structure, not just placing
tiles. This is what makes the game tactile and interesting to
watch.

**Hand↔board commitment.** Playing a card from your hand onto
the board is a bet: you believe the board will hold it as part
of a valid meld by the time your turn ends. Undo is the escape
valve — while you're still in your turn you can walk back any
primitive, including returning a hand card to your hand. Once
you click End Turn, the commitment is permanent.

Those two things together are the game. Board reorganization
is the primary activity; hand↔board commitment is where the
risk lives. The trickiest undo is the hand-card one, because
it has to reverse both a board change and a hand change
simultaneously.

The most compact way to see both mechanics working is
`conformance/scenarios/undo_walkthrough.dsl` — two short
scenarios that read like game transcripts and cover exactly
these two primitives. Read them before diving into the
implementation.

## The mission

The product is roughly: **a human plays Lyn Rummy through the
Elm UI, against a TypeScript agent, and can watch the agent's
moves unfold through the same UI in a way that reads as
another player playing — not as a machine logging primitives
to a server.**

That sentence has three things in it, each shaping the
architecture:

1. **Human plays through Elm.** A browser-based Elm UI
   renders the board, receives mouse gestures, posts actions
   to the Go server (which just files them).
2. **Against a TypeScript agent.** `games/lynrummy/ts/`
   hosts a headless agent that plays full 2-hand games
   (engine_v2 A* solver, hand-aware physical-execution
   layer, card-tracker liveness pruning). It writes its
   game as a JSON transcript directly to the file system.
3. **Watchable through the UI.** The Elm UI reads a stored
   transcript and replays it primitive-by-primitive — same
   reducer it uses for live play, no "live path" vs "replay
   path" drift. The agent's play renders as drags and
   merges, not as a log dump.

The third constraint does a lot of quiet work. It means we
can't treat "the agent emits wire actions" as the whole
story — the Elm UI has to be able to re-tell that story
visually, at human speed, with motion that looks like a
drag. Everything about replay fidelity traces back to this
constraint, and it shapes the spatial-planning rules in the
TS agent (see "Agents plan, then execute" below).

## Events are the system

Before we list components, the most important framing: a
Lyn Rummy game, whether autonomous or human-played, is a
**manifestation of events**. Each event is a deliberate
choice — a human's drag of a card, an agent's decision to
peel a 5D and merge it — and each event must be represented
**clearly and accurately, both within components and across
component boundaries**.

The wire format is the mechanism by which events cross those
boundaries. The referee is the discipline that decides whether
a proposed event was legal. The action log is how events
persist. The replay walker is how events re-manifest later.
The gesture telemetry is how the physical fidelity of an
event is preserved alongside its logical content.

All of these exist in service of the events. The components
below are organized around roles in the event lifecycle:
who proposes events, who validates them, who persists them,
who re-tells them.

If you're ever trying to decide whether a piece of logic
belongs in component A or component B, ask first: what event
is being handled, and which component is the right place to
handle it without distorting the event's representation. That
question is upstream of language choice, file layout, and
performance.

## Each actor owns its own view

An important refinement before we list components. Earlier
drafts leaned on "the server is the one authority on what
happened" — which is wrong. It makes the server sound central
in a way that doesn't match how the system actually works.

The truer picture: **each actor owns its own view of the
world, including its own event log.** The Elm UI has a log.
The TS agent has a log (the transcript it writes). The Go
server stores the events it observed (Elm POSTs each
action) but doesn't run a referee against them.

Direct consequences:

- **Autonomous play doesn't need the server.** An Elm client
  maintains its own action log in memory, plays moves against
  its own referee, never round-trips for state. Same for the
  TS agent in autonomous mode — `agent_player.ts` plays a
  complete game locally; `transcript.ts` writes the result
  straight to the file system, no HTTP. The Elm client's
  only wire calls during a live session are outbound writes
  (`fetchNewSession` once, `sendAction` per action — all
  fire-and-forget). Zero inbound state reads after bootstrap.
- **Each client is its own gatekeeper.** Elm has its OWN
  referee module; the TS agent uses its own
  `applyLocally` + boundary checks (`findViolation`,
  `assertNoOverlap`) per primitive.
- **The server is observability, not coordination.** When the
  Elm client posts events to the server, those events become
  visible to anyone reading the data tree (a Python tool, a
  human inspecting `games/lynrummy/data/`, a future replay
  viewer). The server is not part of any decision loop.

This flips the default expectation from "server central;
clients are thin UIs" to "each actor is independent; the
server is a passive observer."

## The cast of components

Three components collaborate; a fourth (Python) holds
legacy/utility code. Lyn Rummy is a **single-human game**:
solitaire or human-vs-agent. Two-human multiplayer is out
of scope.

- **Elm UI.** The autonomous client. Deals locally
  (`Game.Dealer.dealFullGame seed` produces the curated
  opening board + random hands), runs its own referee,
  appends to its own action log, can replay at any time.
  Originates events from mouse drags, its own hint engine
  (legacy `Game.Strategy.*` for now — pending TS
  integration), or a stored transcript on replay. Posts
  events to the Go server for observability + reload-
  resume; nothing in the live loop depends on the server's
  response.
- **TypeScript agent.** A complete player without a
  presentation layer, at `games/lynrummy/ts/`. Owns the
  BFS solver (`engine_v2.ts` — A* with admissible
  heuristic + closed-list dedup + card-tracker liveness
  pruning) and the physical-execution layer (`verbs.ts` +
  `physical_plan.ts`) that turns a solver plan into the
  primitive sequence a human at the kitchen table would
  emit. `agent_player.ts` plays full 2-hand games to
  deck-low; `transcript.ts` writes them as Elm-replayable
  JSON. The TS agent has no DOM — so it cannot speak
  pixel-level viewport coords for a live drag — but it
  KNOWS the board frame and reasons about geometry there.
  Discipline: **constraints must be real, not artificial.**
  "TS has no eyes" is not the same as "TS has no geometry."
- **Go server (Angry Gopher).** Dumb URL-keyed file
  storage for LynRummy session data. Sequential session-id
  allocation is the one smart exception. SQLite hosts only
  the seeded `users` table; LynRummy session data lives as
  plain JSON under `games/lynrummy/data/`. The Go server
  does NOT deal, does NOT referee, does NOT replay — that
  Go domain package retired 2026-04-28.
- **Python (legacy/utility).** `games/lynrummy/python/`
  hosts the dealer, some unit tests, and odd tools.
  The Python BFS solver retired during the TS migration;
  do not invest in further Python-side solver work.

## Multiple action logs, one event shape

Because each actor owns its own view, there are **multiple
action logs in play** at any given time — the Elm client's,
the TS agent's transcript, the server's filesystem-backed
log. What holds them together isn't one-log-to-rule-them-
all; it's that **events have the same shape wherever they
live**.

Each entry in any of these logs is one wire action — one
primitive a player could do: split a stack, merge two
stacks, merge a hand card onto a stack, place a hand card
on the board, move a stack, complete a turn, undo. The
shape is identical across Elm, TS, and Go; that's what lets
actors integrate each other's events without translation.

An actor's engagement with the server has three levels:

- **Fully autonomous.** The log never leaves the actor. No
  server round-trip. Elm solitaire. The TS agent running a
  self-play game it'll discard. The log is simply what the
  actor did.
- **Outbound-only.** The actor writes events to where others
  (or a later replay) can see them, but doesn't pull anything
  back. The TS agent operates here when generating
  transcripts — it writes JSON straight to the file system
  (no HTTP), Steve later watches via Elm replay.
- **Two-way coordination (fresh territory).** Both actors
  post events AND integrate events originating from the
  other. Each incoming event passes through the receiving
  actor's own referee before being added to its own log.
  Integration is deliberate. **In practice we've barely
  exercised this** — even when Steve and Claude have shared
  a session, coordination has been out-of-band. The
  architecture supports it; the shape will refine as we
  exercise it for real.

The event shape's consistency across actors isn't a
coincidence. We keep it consistent on purpose, using a
redundancy-as-asset discipline with forced agreement checks —
the shared DSL-driven conformance tests for hints, the
cross-language replay of the same primitive shapes. That
discipline is itself first-class in this codebase; see
[`../../BRIDGES.md`](../../BRIDGES.md) at the repo root for
the paradigm and our standing bridges.

Because the event shape is consistent, three consequences
hold from any actor's perspective:

1. **Game state is a pure function of (deck seed + the
   actor's action log).** No hidden side state, no derived
   caches that could drift.
2. **Replay is mechanically trivial.** Walk the log, feed
   events through the same reducer used live. The mechanism
   works identically inside Elm and inside the TS agent.
3. **Who proposed an event doesn't matter to the replay
   machinery.** Human, agent, or server-coordinated — a log
   is a log. Elm's UI replays any of these the same way.

## Elm is layered around source-aware events

Inside the Elm UI, events arrive from multiple sources — the
human's live mouse drags, Elm's own hint engine, the agent
playing as opponent, and the replay walker re-reading a
stored log. When any of these sources
delivers an event, Elm captures the **full information about
its source** along with the event itself.

Source matters for some downstream decisions. A faithful
locally-captured drag path can replay at its captured pace and
pixel-fidelity; an inbound wire event has no pointer path in
Elm's current frame, so the drag must be synthesized. An event
arriving from a replay walker needs different pacing than one
arriving live. Those decisions are different.

But Elm strives to fold every source-specific input into a
**common event shape that its internal layers can execute
through the SAME mechanisms**, whether the event happens in
real time or three minutes later during replay. No "live path"
vs. "replay path" that drift apart. The same event goes
through the same reducer.

That discipline is why Elm is layered, with responsibilities
at the appropriate level:

- **Capture.** Ingests source-specific inputs (pointer
  events, wire deliveries, replay ticks) and produces events
  in the common shape, enriched with source metadata.
- **Integration.** Decides whether an incoming event joins
  Elm's own action log, using its own referee and whatever
  policy governs acceptance of events from other actors.
- **Execution.** Applies events to the model via one reducer,
  used identically for live play and for replay.
- **Render.** Draws board, hand, and drag overlay from the
  current model. The DOM is the source of truth for where
  things actually show on screen at this moment — a
  render-layer concern, not a game-layer concern.

The faithful-vs-durable capture story below zooms in on one
specific axis of this layering: how drag geometry survives
across capture and execution, so that the played-now version
and the replayed-later version use the same mechanism without
drift.

## Who decides what — the hints-are-client-side rule

A natural question: given that the server owns wire +
storage, does it also tell clients which moves are smart
("hints")? We used to. We don't anymore.

The rule now: **the server owns wire and storage; each
client owns its own hint logic.** Elm has a hint module that
scans the current (hand, board) and proposes plays. The TS
agent has its own (`hand_play.ts` calls `engine_v2`
directly). They don't have to agree — they serve different
players.

Why split? The server's job is "store this action." The
hint logic's job is "would this move be wise." Clients are
better placed to answer the second, and baking it into the
server forced the server to reason about client-side
concerns it had no business in. Today the server is clean:
no hints, no gesture synthesis, no replay synthesis. It
files actions, indexes sessions, serves the data tree.

This is load-bearing for the TS agent. The TS agent IS its
own hint logic plus a transcript writer. Without the server
trying to help, the agent is self-sufficient; it plays the
game using the same primitive vocabulary the Elm UI emits.

**Caveat (2026-05-04):** the live-game hint button in the
Elm UI is still routed through the legacy `Game.Strategy.*`
trick engine + `Game.Agent.*` Elm BFS port — the TS engine
isn't called from the browser yet. Tracked as
`TS_ELM_INTEGRATION` in `claude-steve/MINI_PROJECTS.md`.
Once that lands, the 10-file `Game/Strategy/` directory and
the on-life-support `Game/Agent/` BFS port both retire.

## Durable facts vs. rich-but-environment-bound facts

This section captures an insight from today (2026-04-21) that
has to live in the central architecture because it shapes
everything about how we capture and replay moves.

A move-as-recorded has two layers:

- **Durable layer.** The LOGICAL move (which hand card, which
  target stack, which side) and the BOARD-FRAME landing
  coordinate of anything that ends up on the board. The
  board's top-left is `(0, 0)`; the board-frame is independent
  of viewport, browser, window size, or device. These facts
  survive any future environment.
- **Rich layer.** The raw pointer path the mouse traced
  during the drag, in viewport pixel coordinates, timestamped
  per sample, alongside the environmental context at capture
  time (viewport dimensions, device pixel ratio). These are
  faithful-at-the-moment but their geometric validity depends
  on the environment.

At replay time, the rule is simple: if the captured
environment matches the current environment, play back the
raw path — maximum fidelity, the human's actual drag
faithfully rendered. If the environment has drifted, fall
back to synthesizing a drag from the durable layer — correct
but no longer pixel-faithful.

**Current state:** the TS agent emits primitives only —
no drag paths. Elm synthesizes drags on replay from the
durable board-frame coords. Replay branches on path
**presence**: `Just (p :: rest)` → faithful playback,
`Nothing` → synthesize. Elm-captured paths do not yet carry
an "captured under these environmental conditions" stamp,
so a window-resize between capture and replay currently
produces a faithful-looking playback aimed at stale
viewport coords. **PLANNED:** add the stamp + reader so
replay falls back to synthesis when the environment has
drifted.

This is what resolves the cross-language geometry debate. The
durable layer is what the TS agent can speak to (it knows
the board frame). The rich layer is what only a specific
Elm instance in a specific browser session can produce.
Neither tries to speak for the other. The wire carries both
(where available) and each consumer reads the layer it can
trust.

## Frames of reference

Related to the durable/rich split: LynRummy uses **two
coordinate frames**, and nobody should confuse them.

- **Board frame.** Origin `(0, 0)` at the board's top-left.
  Every stack on the board has a `loc: {top, left}` in
  board frame. The 800×600 play surface has fixed
  dimensions. Any action that talks about WHERE SOMETHING
  IS ON THE BOARD uses this frame. The TS agent uses it
  natively — it has never known about viewports.
- **Viewport frame.** Origin `(0, 0)` at the top-left of the
  user's browser window. Mouse coordinates are captured in
  this frame. The Elm drag floater is positioned in this
  frame.

**Intra-board moves stay in board frame.** A move_stack that
relocates a stack from loc A to loc B records both in board
frame. A split-and-move records the new stack's loc in board
frame. When Elm replays an intra-board move, it translates
board frame → current viewport frame at render time —
subtracting the viewport-x and y of the board's live DOM rect,
which the browser gives it on demand.

**Hand-to-board moves require viewport frame for the drag
path**, because the drag starts in the hand area (which has no
natural board-frame coord) and ends on the board. The
LANDING, however, is always recorded in board frame — the
durable half of the hand-to-board action is the same shape as
an intra-board landing.

If you're writing code that speaks coordinates on the wire
and you're not SURE which frame you're in, stop. That's where
today's layout drift came from.

## Agents plan, then execute

A load-bearing discipline for the TS agent — and any future
agent — worth stating as its own principle: **plan the whole
move in your head before emitting the primitives.**

Humans are good at small-scale spatial planning. Our
lookahead is shallow, but we easily hold two or three
logical board changes in mind, count cards ("the final
stack is 4 wide"), do single-digit arithmetic ("12px of
headroom on the left"), and reason spatially. A trick that
needs 6–7 physical primitives to realize is within
comfortable human planning range.

The TS agent's physical-execution layer (`ts/src/verbs.ts`
+ `ts/src/physical_plan.ts`) mimics this. The pipeline is a
single loop over the solver's plan with **honest state**
throughout: `sim` is the real board (no hand cards on it);
`pendingHand` tracks cards still in the hand. At each verb,
the emission helpers in `verbs.ts` consult both and pick
the right primitive directly. Three rules baked in:

- **R1 (hand-direct):** a hand card whose end-state is
  "absorbed into stack S" is dragged from the hand directly
  to S via `merge_hand` — no transient board singleton.
  The pull/push semantic flip (solver = absorber-active,
  gesture = dragged-piece-active) is hidden inside the
  helper.
- **R2 (small→large):** for board-to-board merges, the
  smaller stack is the one that physically moves. Source ↔
  target swap with a side flip preserves the merged card
  order.
- **R3 (don't move if there's room):** pre-flight fires
  only when the post-action board would crowd the
  `findCrowding` threshold (`PLANNING_MARGIN = 15`, between
  the legal `BOARD_MARGIN = 7` and the human-feel
  `PACK_GAP = 30`). Interior splits still pre-flight
  unconditionally — siblings need a 4-side-clear region.

The full doctrine lives in `ts/PHYSICAL_PLAN.md`; the per-
step overlap-check fixtures in
`conformance/scenarios/physical_plan_corpus.dsl` exercise
each rule. Planning horizon is a single trick — multi-trick
lookahead is a different intelligence layer, out of scope.

## Compute answers you own; don't delegate

A related discipline that lives at the Elm boundary: when
the client RENDERS a piece of state, it should COMPUTE
answers about that state directly, not ask the browser (or
any other opaque system) to tell it back. The 2026-04-22
board-to-board merge bug taught this the hard way — we had
`onMouseEnter` / `onMouseLeave` asking the DOM "is the
cursor over the wing?" when we already knew the floater's
rect and every wing's rect. DOM event delivery was
intermittent; the computation was trivial and owned. The
fix was to replace the delegation with `floaterOverWing`,
pure Elm.

This is a stronger form of "own the whole system": not just
put facts on the wire, but derive answers from state you
already have rather than round-tripping through a different
machine to get them back. Especially important when that
other machine is opaque or unreliable — but the simplicity
and testability wins apply even when delegation would be
reliable. The round-trip has a cost; the self-reliant
compute almost always wins. See
`feedback_compute_dont_delegate.md`.

## One representation per concept

Related: the drag state carried array indices for stacks
(`FromBoardStack Int`) even after the wire moved to
content-based `CardStack` refs. Having two models
simultaneously — positional in memory, content-based on the
wire — was the worst kind of drift: nothing forced them to
agree, and when they disagreed the bug was silent.

The fix was uniform content refs everywhere, integer-exact
coords on `loc`, and strict `stacksEqual` (same loc AND
same cards in same order — no multiset tolerance). Pick
one canonical representation per concept; enforce it end
to end. See `doctrine_make_state_honest.md` (drag-state
strict shape) and `doctrine_eliminate_dont_paper_over.md`
(slices over indices).

## Design principles woven through

Several standing principles show up repeatedly above; stating
them plainly here so they're not only implicit:

- **Redundancy as asset — bridges with forced agreement.**
  Two or more independent representations + an automated
  agreement check > a single canonical one. The DSL
  conformance harness is the active example; see
  [`../../BRIDGES.md`](../../BRIDGES.md) for the paradigm and
  the inventory of actual / half-wired / wanted bridges.
- **Events drive the system.** Everything else — the wire,
  the referee, the action log, the replay — is in service
  of faithfully carrying events across boundaries.
- **Each actor owns its own view.** No actor is authoritative
  above the others; each has its own log, its own referee,
  its own acceptance policy for incoming events.
- **Record facts, decide later.** The wire carries what
  happened, not instructions for how to interpret it.
  Decisions belong at the point of use.
- **Own the whole system.** The wire format is a contract we
  control. If a component needs a fact to behave well, put
  the fact on the wire.
- **Constraints must be real, not artificial.** "TS has
  no DOM" ≠ "TS has no geometry." Before designing
  around a constraint, verify it's actually binding.
- **Hints are client-side.** Go owns wire + storage; each
  client owns its own hint logic. Neither client has to
  agree with the other on proposals.
- **Faithful when possible, durable always.** Raw pointer
  paths replay pixel-faithfully when the environment
  matches; board-frame logical facts survive any
  environment.
- **Plan, then execute.** Agents simulate a full move
  mentally before emitting its primitive sequence, and
  pre-plan geometry corrections upstream rather than
  appending them downstream. See the dedicated section
  above.
- **Compute answers you own.** If a piece of state is
  yours to render or generate, derive answers about it
  directly. Don't ask an opaque system (DOM, server,
  external store) to tell you back what you already know.
- **One representation per concept.** Don't let two models
  for the same thing co-exist — positional and content-based
  refs for the same stacks, float and int for the same
  location, multiset and ordered equality for the same
  stack. Pick one canonical form; enforce it end to end.

## Where to find more

### Build and run

All build, launch, and test operations go through `ops/` scripts
(repo root). Run `ops/list` for the current index with descriptions.
The short version:

- `ops/start` — kill stale processes, rebuild Go binary, recompile
  Elm, regenerate Puzzles catalog, start both servers, wait for ready.
- `ops/build_elm` — compile Main.elm + Puzzles.elm bundles.
- `ops/check-conformance` — **the commit gate for Elm work.**
  Runs fixturegen + TS conformance + elm-test + elm-review
  (including `NoUnused.CustomTypeConstructors`). Do not
  commit an Elm change without a passing run. `elm-test`
  alone is not sufficient — elm-review catches orphaned
  constructors and other classes of drift that elm-test
  misses.
- `ops/check` — full preflight (conformance + Go build +
  remaining Python unit tests).

Do not hand-compose `go run .`, `elm make`, or `go test ./...` as
your build/test step — those commands silently drop sequencing and
cross-language consistency checks the scripts encode.

### Subsystem landing pages

- [`./README.md`](./README.md) — repo-level overview.
- [`./ts/README.md`](./ts/README.md) — TypeScript agent
  subsystem. The canonical BFS solver + physical-execution
  layer + transcript writer.
  See also [`./ts/PHYSICAL_PLAN.md`](./ts/PHYSICAL_PLAN.md)
  for the gesture-layer rules and
  [`./ts/ENGINE_V2.md`](./ts/ENGINE_V2.md) for the solver.
- [`./elm/README.md`](./elm/README.md) — Elm UI subsystem.
  The `Game.Agent.*` BFS port and `Game.Strategy.*` trick
  engine are still wired in for the live-game hint button;
  both retire when `TS_ELM_INTEGRATION` lands.
- [`./python/README.md`](./python/README.md) — Python
  legacy/utility code (dealer, some tests). The Python
  solver retired during the TS migration.

Each subsystem README lists the load-bearing modules in
"read-this-first" order. Read the architecture doc first
(you're in it); then the relevant subsystem README; then
the module top-of-file docstrings.

### First-class cross-cutting docs

- [`../../BRIDGES.md`](../../BRIDGES.md) — redundancy-as-asset
  paradigm; bridge inventory. Load-bearing for why our
  cross-language layer looks the way it does.
- [`../../GLOSSARY.md`](../../GLOSSARY.md) — vocabulary.
  If the architecture doc reaches for a term you don't know,
  check the glossary.

### Conformance & testing

- `../../cmd/fixturegen/main.go` — the DSL → Elm + JSON
  test generator. The cross-language parity bridge between
  Elm and TS. Don't run ad-hoc; use `ops/check-conformance`.
- `games/lynrummy/conformance/scenarios/*.dsl` — the
  canonical scenarios. **New agents: read
  `undo_walkthrough.dsl` early.** Its two scenarios —
  board-only split/move/undo and the trickier hand-card
  merge/undo — are the most compact readable summary of how
  the game's interaction model actually works. The DSL
  reads like a game transcript; that's intentional.
- TS-specific gesture-layer fixtures live in
  `physical_plan_corpus.dsl` (integration: hand cards +
  multi-verb plans + R1/R3 cases) and
  `verb_to_primitives_corpus.dsl` (per-verb expansion).
  Both runners assert `findViolation == null` after every
  emitted primitive — overlap drift fails at the moment it
  appears, not just at end-of-play.
- `games/lynrummy/DSL_CONVERSION_GUIDE.md` — how to extend
  DSL coverage.

### Memory pointers

For finer-grained architectural atoms, the memory index at
`~/.claude/projects/-home-steve-showell-repos-angry-gopher/memory/MEMORY.md`
indexes durable doctrines and feedback. Two load-bearing
ones worth naming inline:

- **`doctrine_make_state_honest.md`** — record facts,
  decide later; shape matches reality.
- **`doctrine_eliminate_dont_paper_over.md`** — change the
  shape, not the adapter.

The memory system is comprehensive; use it for specifics
this doc can't carry without becoming a reference manual.

## Elm components should be easy to embed

Design goal surfaced 2026-04-23 while building the Puzzles
gallery (formerly BOARD_LAB).
When a feature earns a second surface (e.g. the main play
surface AND a gallery of curated puzzle panels each with
their own play instance), the Elm app's architecture
should make that cheap:

- **Extract the whole-app logic into a component module**
  (`Main.Play`, `Game.Replay`) with init/update/view/
  subscriptions + a typed `Output` union for the few things
  the host legitimately needs.
- **Shrink the top-level `Main.elm` to a thin harness** —
  ports, `Browser.element` boot, routing Output into host
  concerns (URL pinning, navigation), and whatever outer
  wrapper matches the host's layout.
- **Per-instance DOM ids.** The component carries a
  `gameId : String` (or similar) so multiple instances
  can coexist without DOM collisions.
- **`position: relative` + fixed size on the component's
  outer div.** The host decides where the component lives
  in the page.
- **Fixed-position overlays are fine.** Drag floaters,
  popups, modals stay viewport-level — consistent across
  hosts.

Two successful applications of this pattern within a week
(REFACTOR_ELM_REPLAY for Game.Replay, REFACTOR_EMBEDDABLE_PLAY
for Main.Play) validate it as a principle. The Puzzles
gallery embeds Main.Play without forking code.

For new Elm features: if it could plausibly show up in more
than one host context, design it as a component from the
start. The "is this a component or the whole app?" question
should bias toward component.

## Puzzles as study instrument

The Puzzles gallery (`/gopher/puzzles/`) is the apparatus
the Lyn Rummy project uses to observe play on curated
mid-game situations and feed divergences back into the
agent:

- Catalog: `games/lynrummy/python/puzzle_catalog.py` reads
  `games/lynrummy/conformance/mined_seeds.json` and writes
  the JSON the Elm gallery loads. Go serves it at
  `/gopher/puzzles/catalog`. (Per the no-DB policy: mined
  seeds live in the repo as JSON, not in SQLite.)
- Elm gallery: a panel per puzzle, auto-creating its
  puzzle session on page load. Human plays inline; drags
  capture via the normal telemetry pipeline.
- Per-attempt session data: each puzzle play creates a
  session under `data/lynrummy-elm/sessions/<id>/` with the
  puzzle's name in the meta. Annotations land at
  `annotations/<seq>.json` alongside the action log.

The apparatus lets us name concrete divergences between
human and agent play and feed them back into the agent's
spatial strategy.

## Algorithm benchmarks

Solver bench gold lives in `games/lynrummy/ts/bench/`
(`baseline_board_81_gold.txt`, `bench_outer_shell_gold.txt`).
Run via `npm run bench:check-baseline` from
`games/lynrummy/ts/` to regression-check; regenerate with
`npm run bench:gen-baseline` after a deliberate solver
change. The corpus inputs are language-neutral DSL at
`conformance/scenarios/planner_corpus.dsl` and
`baseline_board_81.dsl`.

## Parking status

Last swept 2026-05-04 after the spatial-planning v2 work
landed (one-loop honest-state architecture; R1/R2/R3
inline; per-step overlap checks across DSL fixtures). The
TS agent now plays full 2-hand games to deck-low with
human-quality gesture choices; the only remaining
integration gap is the live-game hint button in the Elm UI
(`TS_ELM_INTEGRATION` in MINI_PROJECTS.md).

The principles are stable. Update this document whenever a
conversation produces a durable architectural insight.
Redundancy with module docstrings and memories is
deliberate — this doc carries the over-arching principles;
the per-module docstrings carry specifics; commit history
carries the historical record.
