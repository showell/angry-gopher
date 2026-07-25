# Lyn Rummy architecture

Orientation for a human reader: the big-picture shape of the system and the few
ideas worth understanding before reading code. **The code is the reference**; when
prose here disagrees with code, trust the code. (The subsystem is parked — see
[`README.md`](./README.md) — so this is a record of how it was built and why, not
a roadmap.)

## The one design axiom: a single shared board

Both players contribute to the **same** play surface. Everything flows from this —
it's not two private tableaus that occasionally interact. There are two hands but
only one is face-up at a time (the active player's; the other shows as a card
count). And it's **solo + an optional agent opponent** — two-human, pass-the-mouse
multiplayer is deliberately out of scope. Features designed against any of those
assumptions invert the foundational shape.

## The three actors

- **The engine computes plays — zig brain, TypeScript body.** Since 2026-07
  the *thinking* is the zig solver (`games/lynrummy/zig/`, compiled to
  `solver.wasm`): the Hint buttons, futility certificates, and the in-game
  opponent all run its one converged pipeline. TypeScript
  (`games/lynrummy/ts/`) is the mostly-retired original engine that still
  does real work: the DSL parsers/emitters, the verb→gesture pipeline that
  turns the solver's answers into locations and drag paths, and the
  full-game self-play harness. Its own BFS solver no longer serves
  production (design record: `ts/ENGINE_V2.md`).
- **Elm is the autonomous client.** It renders the game, runs its own referee, and
  replays its own action log. Two browser entry points — `Game.elm` (full game)
  and `Puzzle.elm` (single board) — sharing `Lib.*` for rendering, the DSL
  parsers, animation, the dealer, and the referee.
- **The server is dumb storage.** It holds session files (`meta`, `actions.dsl`)
  and never referees or reasons. Sequential session-id allocation is its one smart
  exception.

## The mission

A human plays through the Elm UI, against the engine's agent, and watches the agent's
moves unfold **in a way that reads as another player playing — not a machine
logging primitives to a server.** That third constraint does the most work: the UI
must re-tell the agent's story visually, at human speed, with motion that looks
like a drag. Replay fidelity and the agent's spatial-planning rules both trace
back to it.

A corollary worth stating: **the agent plans as well as the constraints allow.**
"Human-like" is *not* a dumbness axis — humans are genuinely good at spatial
planning at the kitchen table. The human-likeness lives in **pacing** (human
tempo, natural pauses) and **tolerance for imperfection** (the clumsiness a real
person also shows fighting a drag-and-drop UI), never in degrading plan quality.

## DSL is the lingua franca (the idea worth stealing)

One canonical text grammar carries **every** long-lived artifact: the conformance
fixtures, the on-disk session files, the resume wire, the TS↔Elm move wire, and
the agent's self-play transcripts. Two runtimes (Elm, TypeScript) speak it, and
most tests parse `.dsl` files at run time. Cards are Unicode glyphs, coordinates
are `(left, top)` — dramatically more compact and readable than the equivalent
JSON of card objects and points.

Why this mattered so much in practice:

- **One shape, no translators.** Because the same grammar is the wire *and* the
  test corpus *and* the saved game, the fixtures are a literal contract for the
  live system — there's no second representation to drift out of sync. (Sibling
  parsers exist only where the *envelope* differs, e.g. a `N)` sequence prefix on
  log lines; the per-primitive grammar lives in exactly one place.)
- **"Is this a bug or by design?" becomes a lookup.** A disagreement gets settled
  against a DSL scenario instead of a conversation.
- **Steve and Claude could read the wire together.** A game, a hint, a stuck
  state — all of it is human-readable text you can paste into a discussion and
  reason about jointly. This was the single biggest force-multiplier for
  troubleshooting the game, and the favorite part of the architecture.

The examples *are* the spec — there's no separate syntax reference. Read
`conformance/scenarios/undo_walkthrough.dsl` for the most compact tour, and the
rest of `conformance/scenarios/*.dsl` for the full grammar. (The approach is
niche: it pays off precisely because everything here is cards-and-coordinates.
Projects without that shape — like the Driving Game, or Chat — are happier with no
wire format or with plain JSON.)

## Events are the system

A game, autonomous or human-played, is a sequence of events: `split`,
`merge_stack`, `merge_hand`, `place_hand`, `move_stack`, `complete_turn`, `undo`.
The wire carries events; the referee decides legality; the action log persists
them; replay re-manifests them. When deciding whether logic belongs in component A
or B, ask which one handles the event without distorting its representation —
that's upstream of language, file layout, and performance.

## Each actor owns its own view

Each actor has its own log, referee, and acceptance policy; none is authoritative
above the others. Consequences: the server stores what Elm posts but never parses
primitives; after bootstrap Elm's only outbound traffic is fire-and-forget action
POSTs; the TS full-game loop writes straight to the filesystem.

## Frames of reference

Two coordinate frames, never to be confused. **Board frame** — origin at the
board's top-left; stack positions and all board reasoning live here, and the agent
works here natively. **Viewport frame** — origin at the browser window; pointer
coords and the live drag floater live here. Elm translates board → viewport at
render time from the board's measured DOM rect. If you're writing code that speaks
coordinates on the wire and aren't sure which frame you're in, stop.

## Durable facts vs. rich facts

A recorded move has two layers. **Durable** — the logical move plus the
board-frame landing coordinate; survives any environment. **Rich** — the raw,
timestamped pointer path in viewport pixels; faithful at capture, but its
geometric validity depends on the environment. At replay: play the rich path back
faithfully when the environment matches, and synthesize from the durable facts
when it doesn't. The agent emits durable-only; Elm synthesizes the drag on replay.
*Faithful when possible, durable always.*

## Design principles

- **Redundancy as an asset** — two independent representations plus an automated
  agreement check beats a single canonical one.
- **Record facts, decide later** — the wire carries what happened, not how to
  interpret it.
- **Own the whole system** — the wire is a contract we control; if a component
  needs a fact to behave well, put the fact on the wire.
- **Constraints must be real, not artificial** — verify before designing around one.
- **Plan, then execute** — agents simulate the full move before emitting
  primitives (see [`ts/PHYSICAL_PLAN.md`](./ts/PHYSICAL_PLAN.md)).
- **One representation per concept** — don't let two models of the same thing
  coexist.

## A retrospective on Elm

Elm was the UI bet, and as a language it's a pleasure — the referee, the dealer,
and the replay engine are clean because of it. But the honest verdict is that
Steve wouldn't choose it again for an app like this. The ~10% of places where Elm
has to shell out — for **performance** (the solver was always outside: first the
TS BFS, now the zig wasm) and
for **browser reality** (reading DOM geometry for drags) — were more painful than
the purity bought back. The takeaway kept here is about the *ideas* (typed
messages, no runtime exceptions, each actor owning its view), not a recommendation
to reach for Elm next time.

## Where to find more

- [`README.md`](./README.md) — overview, status, build & gates.
- [`RULES.md`](./RULES.md) — the game itself.
- [`zig/README.md`](./zig/README.md) — the production solver (hints,
  certificates, Player Two, the sim).
- [`ts/PHYSICAL_PLAN.md`](./ts/PHYSICAL_PLAN.md) — the gesture layer, still
  live · [`ts/ENGINE_V2.md`](./ts/ENGINE_V2.md) — the retired TS solver's
  design record.
- `conformance/scenarios/*.dsl` — the DSL examples that are the spec.

All build, launch, and test work goes through `ops/` scripts (`ops/list` for the
index) — don't hand-compose `zig build`, `elm make`, or the TS runners.
