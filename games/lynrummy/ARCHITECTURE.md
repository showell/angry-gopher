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
paragraph before reading anything else. The architecture
principles below are stable, but the implementation
landscape changed substantially in late April 2026.

Key anchors for calibrating doc freshness:

- **TS BFS engine v1 landed (2026-05-01):** A TypeScript
  port of the BFS solver lives at `games/lynrummy/ts/`.
  It is the going-forward browser BFS engine. The Elm
  `Game.Agent.*` BFS is on **life-support** — works in
  production, not actively maintained. Don't invest in
  Elm-side BFS catch-up to Python.
- **LEAN_PASS phase 2 (2026-04-28):** The entire
  `games/lynrummy/` Go domain package was retired —
  dealer, referee, replay, scoring, all of it. Any doc
  or comment that refers to a Go referee, Go dealer, or
  Go replay logic is stale. Elm now owns all of that.
  The Go server is dumb file storage only.
- **Sidecar rip (2026-04-28):** The `.claude/` sidecar
  documentation system was retired. Per-module context
  now lives in module top-of-file docstrings. References
  to `.claude/*.md` files are stale.
- **Per-sequence URL contract (2026-04-28):** Session
  data writes one action per file at
  `sessions/<id>/actions/<seq>.json`. Older references
  to bulk or differently shaped write endpoints are
  stale.
- **Go rules retired (2026-04-28):** elm-review's
  `NoUnused` rules now catch orphaned Elm type
  constructors. Always run `ops/check-conformance` (not
  just `elm-test`) before committing any Elm change.

If you encounter prose that seems to describe a Go
component doing domain work, treat it as pre-LEAN_PASS
and flag it rather than acting on it.

For cross-cutting working-style conventions (essay
surface, ops scripts, commit patterns), see the
agent-collaboration docs at
`~/showell_repos/claude-collab/agent_collab/`.

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
Elm UI, against a Python agent, and can watch the agent's
moves unfold through the same UI in a way that reads as
another player playing — not as a machine logging primitives
to a server.**

That sentence has three things in it, and each one shapes
the architecture:

1. **Human plays through Elm.** There's a browser-based UI
   (Elm) rendering the board, receiving mouse gestures,
   posting actions to the server.
2. **Against a Python agent.** There's a headless agent
   (Python) that plays full games. It talks to the same
   server, through the same wire, posting the same actions.
3. **Watchable through the UI.** Whatever the agent did, the
   human can replay it in the Elm UI afterward, or watch it
   live as the agent plays as their opponent. The agent's
   play has to look like play, not like a log.

The third constraint does a lot of quiet work. It means we
can't treat "the agent sends wire actions" as the whole story
— the Elm UI has to be able to re-tell that story visually,
at human speed, with motion that looks like a drag. Everything
about replay fidelity traces back to this constraint.

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
The Python agent has a log. The Go server stores the events
it observed (Elm POSTs each action) but doesn't run a
referee against them.

Direct consequences:

- **Autonomous play doesn't need the server.** An Elm client
  maintains its own action log in memory, plays moves against
  its own referee, never round-trips for state. Same for the
  Python agent in autonomous mode — Python plays a complete
  game locally and only talks to the server if someone else
  needs to see the result. The Elm client's only wire calls
  during a session are outbound writes (`fetchNewSession`
  once, `sendAction` per action — all fire-and-forget). Zero
  inbound state reads after bootstrap.
- **Each client is its own gatekeeper.** Elm has its OWN
  referee module; the Go referee was retired 2026-04-28
  (the entire Go domain package went with it). Python has
  its own referee-equivalent too.
- **The server is observability, not coordination.** When the
  Elm client posts events to the server, those events become
  visible to anyone reading the data tree (a Python tool, a
  human inspecting `games/lynrummy/data/`, a future replay
  viewer). The server is not part of any decision loop.

This flips the default expectation from "server central;
clients are thin UIs" to "each actor is independent; the
server is a passive observer."

## The cast of components

Four components collaborate. Lyn Rummy is a **single-human
game** as of 2026-04-28 — solitaire or human-vs-agent. Two-
human multiplayer is out of scope (product decision: scheduling
friction outweighs the value once Elm has agent capability).

- **Elm UI.** The autonomous player. Deals locally
  (`Game.Dealer.dealFullGame seed` produces the curated
  opening board + random hands), runs its own referee,
  appends to its own action log, can replay at any time.
  Originates events from mouse drags or its own
  hint/agent logic. Posts events to the Go server purely
  for observability + reload-resume; nothing in the live
  loop depends on the server's response.
- **Python agent.** A complete player without a
  presentation layer. Owns the four-bucket BFS planner —
  the experimentation surface where solver work happens.
  It has no DOM — so it cannot speak pixel-level viewport
  coords for a hand drag — but it KNOWS the board frame and
  reasons about geometry there. Discipline:
  **constraints must be real, not artificial.** "Python
  has no eyes" is not the same as "Python has no geometry."
- **TypeScript BFS engine.** Sibling to Python's solver,
  living at `games/lynrummy/ts/`. Mirrors Python plan-line-
  for-plan-line via the DSL conformance contract; will
  replace the Elm BFS in the browser via Elm ports. Browser
  integration pending. The Elm `Game.Agent.*` BFS is on
  life-support until then.
- **Go server (Angry Gopher).** Dumb URL-keyed file
  storage for LynRummy session data (LEAN_PASS phase 2,
  2026-04-28). Sequential session-id allocation is the one
  smart exception. The Go server does NOT deal, does NOT
  referee, does NOT replay — all of that ran in Go until
  2026-04-28 when the entire `games/lynrummy/` Go domain
  package retired. SQLite hosts only the seeded `users`
  table now; LynRummy session data lives as plain JSON
  under `games/lynrummy/data/`.

## Multiple action logs, one event shape

Because each actor owns its own view, there are **multiple
action logs in play** at any given time — the Elm client's,
the Python agent's, the server's filesystem-backed log.
What holds them together isn't one-log-to-rule-them-all;
it's that **events have the same shape wherever they live**.

Each entry in any of these logs is one wire action — one
primitive a player could do: split a stack, merge two stacks,
merge a hand card onto a stack, place a hand card on the
board, move a stack, complete a turn, undo. The shape is
identical across Elm, Python, and Go; that's what lets actors
integrate each other's events without translation.

An actor's engagement with the server has three levels:

- **Fully autonomous.** The log never leaves the actor. No
  server round-trip. Elm solitaire. Python running a self-
  play game it'll discard. The log is simply what the actor
  did.
- **Outbound-only.** The actor posts events to the server so
  others (or a later replay) can see them, but doesn't pull
  anything back. Python agents often operate here — play a
  game, persist it, Steve later watches via Elm replay.
- **Two-way coordination (fresh territory).** Both actors
  post events AND integrate events originating from the other
  actor. Each incoming event passes through the receiving
  actor's own referee before being added to its own log.
  Integration is deliberate. **In practice we've barely
  exercised this** — even when Steve and Claude have shared
  a session, coordination has been out-of-band (talking in
  chat, eyeballing each other's moves). The architecture
  supports it; the shape will refine as we exercise it for
  real.

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
   works identically inside Elm, inside Python, inside the Go
   server.
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

A natural question: given that the server owns the referee,
does the server also tell clients which moves are smart
("hints")? We used to. We don't anymore.

The rule now: **the server owns wire and referee; each client
owns its own hint logic.** Elm has a hint module that scans
the current (hand, board) and proposes plays. Python has an
independent hint module that does the same job, independently.
The two don't have to produce the same proposals — they serve
different players with different goals.

Why split? Because the server doesn't need to know. The
referee's job is "is this move legal." The hint logic's job
is "would this move be wise." Clients are better placed to
answer the second, and baking it into the server forced the
server to reason about client-side concerns it had no business
in. Today the server is clean: no hints, no gesture
synthesis, no replay synthesis. It records actions, validates
turns, serves back the log.

This is load-bearing for the Python agent. The Python agent
literally IS its own hint logic plus a posting loop. Without
the server trying to help, the agent is self-sufficient; it
plays the game using the same surface a human's Elm UI uses.

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

**Current state (2026-04-21):** replay branches purely on
path **presence**: `Just (p :: rest)` → faithful playback,
`Nothing` → synthesize. Python's synthesizer does emit a
partial stamp (`pointer_type: "synthetic"`, viewport,
device_pixel_ratio) alongside its paths, and Elm-captured
paths do not yet carry an analogous "captured under these
environmental conditions" stamp. **PLANNED:** both sides
emit a stamp, and replay reads it to decide faithful vs.
fallback when the environment has drifted. Without the
stamp-reader, a window-resize before replay currently
produces a faithful-looking playback aimed at stale viewport
coords.

This is what resolves the cross-language geometry debate. The
durable layer is what the Python agent can speak to (it knows
the board frame). The rich layer is what only a specific Elm
instance in a specific browser session can produce. Neither
tries to speak for the other. The wire carries both (where
available) and each consumer reads the layer it can trust.

## Frames of reference

Related to the durable/rich split: LynRummy uses **two
coordinate frames**, and nobody should confuse them.

- **Board frame.** Origin `(0, 0)` at the board's top-left.
  Every stack on the board has a `loc: {top, left}` in board
  frame. The 800×600 play surface has fixed dimensions. Any
  action that talks about WHERE SOMETHING IS ON THE BOARD
  uses this frame. Both Go and Python use it natively —
  they've never known about viewports.
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

A load-bearing discipline for the Python agent — and any
future agent — worth stating as its own principle: **plan
the whole move in your head before emitting the primitives.**

Humans are good at small-scale spatial planning. Our
lookahead is shallow, but we easily hold two or three
logical board changes in mind, count cards ("the final
stack is 4 wide"), do single-digit arithmetic ("12px of
headroom on the left"), and reason spatially. A trick that
needs 6–7 physical primitives to realize is within
comfortable human planning range.

The agent mimics this. Before emitting the primitive
sequence for a trick, it **simulates the final board
state**, checks that every intermediate state (not just the
last one) is geometrically clean, and only then emits. If a
simulated merge would spill over a board boundary, the
emitter plans a `move_stack` *upstream* of the merge — not
a corrective move appended at the end. The replay shows a
coherent sequence of human-plausible moves, not "ugly in
the middle, fine at the end."

The concrete mechanism is in `python/strategy.py`'s
`_plan_merge_hand` helper: it simulates a merge_hand, and if
in-place would violate bounds, finds a hole sized for the
EVENTUAL stack (accounting for side-specific offset: a
left-merge shifts the top-left by −CARD_PITCH) and emits
`move_stack` before `merge_hand`. Every `merge_hand`
emission in every trick routes through it. `_fix_geometry`
remains as a last-ditch safety net; it should rarely fire.

Planning horizon is a single trick. Multi-trick lookahead
— "if I peel X now, a hand card plays later" — is a
different intelligence layer, not within this rule's scope.

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
- **Constraints must be real, not artificial.** "Python has
  no DOM" ≠ "Python has no geometry." Before designing
  around a constraint, verify it's actually binding.
- **Hints are client-side.** Go owns wire + referee; each
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
  Runs fixturegen + Python conformance + elm-test + elm-review
  (including `NoUnused.CustomTypeConstructors`). Do not commit an
  Elm change without a passing run. `elm-test` alone is not
  sufficient — elm-review catches orphaned constructors and other
  classes of drift that elm-test misses.
- `ops/check` — full preflight (conformance + Go build + Python unit
  tests).

Do not hand-compose `go run .`, `elm make`, or `go test ./...` as
your build/test step — those commands silently drop sequencing and
cross-language consistency checks the scripts encode.

### Subsystem landing pages

- [`./README.md`](./README.md) — repo-level overview (the Go
  domain package was retired 2026-04-28; the Go server is now
  dumb file storage).
- [`./elm/README.md`](./elm/README.md) —
  Elm UI subsystem. (The `Game.Agent.*` BFS port here is on
  life-support; new BFS work goes to `./ts/`.)
- [`./python/README.md`](./python/README.md)
  — Python agent subsystem. **If you're about to edit Python,
  read § "Agent orientation" first** — it's a 6-step checklist
  (baseline green → plan state → layering → corpus → ergonomics →
  validation). There's also a self-test quiz:
  [`QUIZ_AGENT_ORIENTATION.md`](./python/QUIZ_AGENT_ORIENTATION.md).
  For solver-specific work, see also [`./python/SOLVER.md`](./python/SOLVER.md).
- [`./ts/README.md`](./ts/README.md) — TypeScript BFS engine
  subsystem. Sibling to Python's solver; the going-forward
  browser BFS engine.

Each subsystem README lists the load-bearing modules in
"read-this-first" order. Read the architecture doc first
(you're in it); then the relevant subsystem README; then the
module top-of-file docstrings. (The legacy `.claude` sidecar
system was retired 2026-04-28; commit messages now carry the
historical record.)

### First-class cross-cutting docs

- [`../../BRIDGES.md`](../../BRIDGES.md) — redundancy-as-asset
  paradigm; bridge inventory. Load-bearing for why our
  cross-language layer looks the way it does.
- [`../../GLOSSARY.md`](../../GLOSSARY.md) — vocabulary.
  If the architecture doc reaches for a term you don't know,
  check the glossary.
- [`./elm/USER_FLOWS.md`](./elm/USER_FLOWS.md)
  — enumerated Elm-client user flows. Read this when planning
  a UX change.

### Conformance & testing

- `../../cmd/fixturegen/main.go` — the DSL → Elm + JSON
  test generator. The mechanism behind our cross-language
  parity bridge between Elm and Python (the Go target
  retired 2026-04-28 with the Go domain package). Don't run
  ad-hoc; use `ops/check-conformance`.
- `games/lynrummy/conformance/scenarios/*.dsl` — the
  canonical scenarios both sides test against. **New agents:
  read `undo_walkthrough.dsl` early.** Its two scenarios —
  board-only split/move/undo and the trickier hand-card
  merge/undo — are the most compact readable summary of how
  the game's interaction model actually works: what an action
  does to board and hand, what undo reverses, and what the
  button-enable predicate tracks. The DSL reads like a game
  transcript; that's intentional.
- `games/lynrummy/DSL_CONVERSION_GUIDE.md` — how to extend
  the DSL scenario coverage: why (dispute resolution),
  selection criteria for what's worth porting, step-by-step
  process, current coverage inventory, and prioritized
  remaining work.

### Memory pointers

For finer-grained architectural atoms, the memory system
carries standalone notes. A few load-bearing ones:

- `project_hints_are_client_side.md`
- `project_durable_vs_ephemeral_state.md`
- `project_one_action_log.md`
- `project_enumerate_and_bridge.md`
- `project_ui_engine_elm.md`
- `project_agent_tools_python.md`
- `doctrine_make_state_honest.md` (record facts decide later;
  shape matches reality)
- `doctrine_eliminate_dont_paper_over.md` (I own the whole
  system; change the shape, not the adapter)
- `feedback_compute_dont_delegate.md`

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

The Puzzles gallery (`/gopher/puzzles/`, added 2026-04-23)
is the apparatus the Lyn Rummy project uses to observe
play on curated mid-game situations and feed divergences
back into the agent:

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
spatial strategy. Surfaced weaknesses: the original
`find_open_loc → (7,7)` corner-dump was fixed by
shifting `HUMAN_PREFERRED_ORIGIN` to (50, 90). Current
known gap is the row-major scan bias — on a packed top
row the scan can land the agent far-right on that row
before trying a lower open row; fix queued as
`FIND_OPEN_LOC_COLUMN_MAJOR`.

Note: the original agent-vs-human comparison harness
(`agent_board_lab.py`, `board_lab_puzzles.py`, `study.py`)
and the pre-DSL corpus tooling (`corpus_report.py`,
`corpus_lab_catalog.py`) are gone (purged 2026-04-27);
the role they played is now covered by the DSL conformance
pipeline plus replay walkthroughs.

## Algorithm benchmarks

Algorithm-side benchmark numbers (BFS solver depths + wall
times across the 21-puzzle corpus) live as plain-text gold
files in `games/lynrummy/python/corpus/`. The current gold
is `baseline_post_focus.txt`; older milestones
(`baseline_post_engulf.txt`, `baseline_pre_engulf.txt`,
`baseline_bfs.txt`, `baseline.txt`) are preserved as
historical reference. The corpus inputs themselves live in
`games/lynrummy/conformance/scenarios/planner_corpus.dsl`
(versioned, in repo) — not in the DB, per the policy that
no valuable asset relies on the DB.

For the validation methodology around regenerating and
diffing baselines, see `python/README.md` § Validation
methodology.

## Parking status

Parked `STILL_EVOLVING`, last swept 2026-04-27
(TOP_DOWN_SWEEP after the Lab → Puzzles rename — verified
file paths, URLs, and table names align with the post-rename
code). Prior sweep was 2026-04-23
evening, after a full day of Puzzles-gallery refinement
(margin 5→7, 25-puzzle v2 catalog, session-scoped
annotations, agent mid-stack-split pre-move rule, Replay
hygiene pass). The principles are stable; new surfaces
(Puzzles gallery, embeddable-components design goal) are
documented above.

Two-player mechanics are still immature (coordinated
sessions have been exercised out-of-band at best); expect
that surface to move as real two-way play gets shaken out.

Update this document whenever a conversation produces a
durable architectural insight. Redundancy with module
docstrings and memories is deliberate and fine — this doc's
job is the over-arching principles; the per-module
docstrings and memory entries carry the specifics and the
examples.
