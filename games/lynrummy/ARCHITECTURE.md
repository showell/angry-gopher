# Lyn Rummy architecture

This is what future-Claude reads to orient before making a
change in the Lyn Rummy tree. **The code is the reference;
this doc is for principles and pointers.** When prose here
disagrees with code, trust the code.

For concrete entry points (Elm boots, server handlers, CLI
tools), see [`ENTRY_POINTS.md`](ENTRY_POINTS.md).

## The three actors

- **TypeScript is the agent.** Computes plays. Lives in
  `games/lynrummy/ts/`. Generates full self-played games as
  DSL transcripts (`npm run generate-game`) and serves the
  Elm UI's Hint button and the in-game agent over ports.
  See [`ts/README.md`](./ts/README.md).
- **Elm is the autonomous client.** Renders the game, runs
  its own referee, replays its own action log. Two browser
  entry points: `Game.elm` (full game) and `Puzzle.elm`
  (single-board puzzle). See
  [`elm/README.md`](./elm/README.md).
- **Go server is dumb storage.** Holds session files
  (`meta`, `actions.dsl`) under `games/lynrummy/data/`.
  Doesn't referee, doesn't reason. Sequential session-id
  allocation is the one smart exception.

## The mission

A human plays Lyn Rummy through the Elm UI, against a TS
agent, and watches the agent's moves unfold through the
same UI **in a way that reads as another player playing —
not as a machine logging primitives to a server**.

The third constraint does the most work: the UI has to be
able to re-tell the agent's story visually, at human speed,
with motion that looks like a drag. Replay fidelity and the
TS agent's spatial-planning rules both trace back to it.

## DSL is the lingua franca

One canonical text grammar carries every long-lived
artifact: conformance fixtures, on-disk session files, the
resume wire, agent self-play transcripts. Three runtimes
(Elm, TypeScript, Go) speak it. Most tests parse `.dsl`
files at run time.

The examples are the spec — there's no separate syntax
reference. Read
`conformance/scenarios/undo_walkthrough.dsl` for the most
compact tour, and any other `.dsl` under
`conformance/scenarios/` for the rest. For the conformance
pipeline (entry points: `ops/check` pre-commit, `ops/check_full`
milestone), see [`BUILDING.md`](BUILDING.md).

## Events are the system

A Lyn Rummy game, autonomous or human-played, is a sequence
of events: split, merge_stack, merge_hand, place_hand,
move_stack, complete_turn, undo. The wire format carries
events. The referee decides legality. The action log
persists them. Replay re-manifests them. **All of these
exist to serve the events.**

When deciding whether logic belongs in component A or B,
ask: what event is being handled, and which component
handles it without distorting its representation. That
question is upstream of language choice, file layout, and
performance.

## Each actor owns its own view

Each actor has its own log, its own referee, its own
acceptance policy. No actor is authoritative above the
others.

Consequences:

- The Go server stores what Elm posts but never parses
  primitives. Storage, not coordination.
- After bootstrap, Elm's only outbound traffic is
  fire-and-forget action POSTs (`sendAction`). No inbound
  HTTP gates user input. The only "pending" state is for
  TS engine responses ("Thinking…").
- The TS agent's full-game loop writes straight to the file
  system. No HTTP.

## Two entry points, shared `Lib`

`Game.elm` and `Puzzle.elm` are independent port modules,
each with its own update/view/subscriptions. They share
`Lib.*` modules for the rendering primitives, the DSL
parsers, the animation engine, the dealer, the referee.
The full game additionally pulls in `Game.*` for its
Model/Msg/View slicing.

Choose by domain. If a new surface wants full-game
semantics (turns, hand, agent), extend `Game.elm`. If it's
narrower (board only, no turn cycle), follow `Puzzle.elm`'s
pattern.

## Frames of reference

Two coordinate frames; nobody should confuse them.

- **Board frame.** Origin `(0, 0)` at the board's top-left.
  Stack `loc` and any board-level reasoning live here. The
  TS agent uses board frame natively.
- **Viewport frame.** Origin at the browser window's
  top-left. Mouse coords and the live drag floater live
  here.

Elm translates board → viewport at render time using the
board's measured DOM rect. Hand-to-board drags require
viewport frame for the path (the drag starts in the hand
area, no board-frame coord) but ALWAYS land in board frame.

If you're writing code that speaks coordinates on the wire
and you're not sure which frame you're in, stop.

## Durable facts vs. rich facts

A move-as-recorded has two layers:

- **Durable.** The logical move + the board-frame landing
  coord. Survives any future environment.
- **Rich.** Raw pointer path in viewport pixels, timestamped
  per sample. Faithful at capture; geometric validity
  depends on environment.

At replay: faithful playback when the environment matches,
synthesize from durable when it doesn't. The TS agent emits
durable only — Elm synthesizes drags on replay from board-
frame coords. Replay branches on path presence.

## Design principles

- **Redundancy as asset.** Two independent representations
  + an automated agreement check > a single canonical one.
  See [`../../BRIDGES.md`](../../BRIDGES.md).
- **Each actor owns its own view.** No coordinator above
  the actors.
- **Record facts, decide later.** The wire carries what
  happened, not instructions for how to interpret it.
- **Own the whole system.** The wire is a contract we
  control. If a component needs a fact to behave well, put
  the fact on the wire.
- **Constraints must be real, not artificial.** Verify
  before designing around.
- **Faithful when possible, durable always.**
- **Plan, then execute.** Agents simulate the full move
  mentally before emitting primitives. See
  [`ts/PHYSICAL_PLAN.md`](./ts/PHYSICAL_PLAN.md).
- **Compute answers you own.** Don't round-trip through an
  opaque system to learn what you already know.
- **One representation per concept.** Don't let two models
  for the same thing co-exist.

## Where to find more

- [`./README.md`](./README.md) — repo-level overview.
- [`./ts/README.md`](./ts/README.md) — TS agent subsystem.
- [`./elm/README.md`](./elm/README.md) — Elm client.
- [`ENTRY_POINTS.md`](ENTRY_POINTS.md) — boot points + URLs.
- [`BUILDING.md`](BUILDING.md) — build pipeline.
- [`../../BRIDGES.md`](../../BRIDGES.md) — bridge inventory.
- [`../../GLOSSARY.md`](../../GLOSSARY.md) — vocabulary.
- `conformance/scenarios/*.dsl` — DSL examples = spec.
- `~/.claude/projects/-home-steve-showell-repos-angry-gopher/memory/MEMORY.md`
  — durable doctrines + working-style feedback.

All build, launch, and test ops go through `ops/` scripts
(repo root). `ops/list` for the index. Don't hand-compose
`go run .`, `elm make`, or `go test ./...` — those silently
drop sequencing the scripts encode.
