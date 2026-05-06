# Replay subsystem — audit + layered redesign sketch

Companion to `state_machine_discipline.md`. That doc was
principle-only; this one reads the current code and proposes
the changes the principles imply. Two new ingredients vs. the
earlier doc:

1. **Replay does need to know about turn structure** — and
   therefore about the deck (draws fire on turn end). That
   widens the snapshot surface vs. the original framing.
2. **Multiple layers are on the table.** The natural
   decomposition is three of them, each with its own snapshot
   and its own boundary. The recorded-game-replay caller hits
   the outer layer; the real-time-agent caller hits the middle
   layer; the drag animator is the innermost.

## Proposed layering

**Game-Replay** (outer). Animates a recorded full game from a
starting state through one or more complete turns. Knows
about turn cycling: detects `complete_turn` in the action
stream, applies the outcome-appropriate draw from the deck,
advances active-player. Used by the Replay button in the UI
when Steve clicks "play back this whole session."

Snapshot:
- Starting board.
- Starting hands (one per seat).
- Starting deck.
- Action stream: an ordered sequence of `WireAction`
  including `complete_turn` boundaries.
- Optional pacing knobs.

What Game-Replay does NOT know:
- Sessions, URLs, persistence, annotations.
- Whether actions came from a human, an agent, or a synthetic
  transcript.
- Score, win conditions, anything beyond "advance the model
  through the action stream."
- What the parent intends to do after.

**Step-Replay** (middle). Animates a *bounded* list of
`WireAction`s — typically the primitives produced by one agent
step (one play or one groom). No turn cycling, no deck, no
hands beyond the active one. Used by:
- The real-time agent loop (one `nextStep` worth of primitives
  at a time).
- Game-Replay internally, to animate one turn's worth of
  primitives between `complete_turn` boundaries.

Snapshot:
- Board.
- Active hand.
- Active player index (cosmetic — for the panel highlight).
- Bounded move list (no `complete_turn`).
- Optional pacing knobs.

Step-Replay's contract is the simple, narrow one the original
doc described.

**Drag** (innermost). Already extracted, already clean
philosophically. Animates one card or stack moving from
start to end coordinates over a path. Pure function of
(time, AnimationInfo). Used by Step-Replay for any
`WireAction` that decomposes into a drag.

Snapshot:
- The thing being moved.
- Start and end coords (or path).
- Animation timing.

## What the current code actually looks like

I read `Game/Replay/*.elm` and the `Main/State.elm` fields it
shares. The good news: directorially, the work has already
started — `Game/Replay/` exists, `DragAnimation.elm` is
already factored out as its own module with a pure `step`
function. The bad news: the boundary the discipline doc
demands isn't enforced in the imports. Specific leaks:

- **Every file in `Game/Replay/` imports `Main.State.Model`
  directly.** The replay subsystem reads and threads the
  parent's full Model — `boardEndpoints : WireAction -> Model
  -> Maybe (Point, Point)`, `prepare : ... -> Model ->
  Maybe PrepareResult`, etc. Functions accept Model where
  they should accept a snapshot.
- **`ReplayAnimationState` lives in `Main.State.elm`,** not
  in `Game.Replay.*`. The state-machine type that defines the
  replay's program counter sits in the parent module rather
  than the subsystem that owns it.
- **`Game.Replay.Time` imports `Main.Apply` and
  `Main.Msg`.** The replay subsystem fires parent Msgs
  directly and reaches into the parent's apply layer to
  advance state. Inversion of the right direction.
- **Shared types live in `Main.State`** (`DragState`,
  `PathFrame`, `GesturePoint`, `Point`) and are imported by
  Replay. Those primitives belong in a Replay-owned (or at
  least neutral) module.
- **`actionLog` and `replayBaseline` live in the parent
  Model** rather than being inputs threaded into a snapshot.
  Replay reads them out of the parent's Model when it runs.

These all stem from the same shape: there's no snapshot
type. The Replay subsystem wasn't built around "receive
inputs, emit outputs"; it was built as "a phase the parent's
Model can be in, expressed via helpers that read the parent
Model." Tightening the boundary means lifting the inputs
into types and inverting the dependency.

## What's already aligned

Worth noting before we critique too hard:

- `Game.Replay.DragAnimation`'s `step` function is pure and
  knows only its `AnimationInfo`. The one Main.State import
  there (`DragState`) is a type leak, not a behavior leak —
  the function doesn't consume Model. Easy to fix by moving
  `DragState` into a Replay-owned module.
- `Game.Replay.Space` is documented as "pure functions only —
  no Msg, no I/O, no subscriptions." Modulo the Model
  imports, that's true.
- `ReplayProgress` is already a clean ADT — pending list +
  paused flag — and lives at the right level conceptually,
  even if it's typed in the wrong file.
- The doc-comments throughout `Game/Replay/*` already
  emphasize the seam (`This module depends on Space; Space
  has no dependency here.` `The seam between this module and
  Time is the testability boundary.`). The intent is clear
  in the prose; the imports just don't yet reflect it.

So this is "lift the snapshot type out and rewire imports,"
not "rebuild from scratch."

## Concrete changes the layering implies

Roughly in dependency order:

1. **Create a Replay-owned types module.** Move
   `DragState`, `PathFrame`, `GesturePoint`, `Point` into
   `Game/Replay/Types.elm` (or similar). Anything in the
   replay subsystem stops importing `Main.State` for these.
2. **Define snapshot types.** `Game.Replay.StepSnapshot` for
   the middle layer; `Game.Replay.GameSnapshot` for the
   outer layer. Each is a record with exactly the inputs
   listed above.
3. **Migrate `ReplayAnimationState` into the Replay
   subsystem.** It's the state machine's program counter; it
   belongs there. The parent Model holds a `Maybe
   ReplayAnimationState` (or whatever the right wrapper is)
   without naming the variants.
4. **Refactor function signatures.** `boardEndpoints :
   WireAction -> Model -> Maybe (Point, Point)` becomes
   `boardEndpoints : WireAction -> StepSnapshot -> Maybe
   (Point, Point)`. Same all the way down. The Model never
   appears below `Game/Replay/`'s entrypoint.
5. **Replay emits its own Msg type.** `Game.Replay.Msg`,
   internal-only, plus a `Completion` variant the parent
   handles. The parent's `Msg` gets one variant
   `ReplayCompleted Replay.Completion` (or similar), and
   nothing else flows.
6. **Untangle from `Main.Apply`.** `Game.Replay.Time`
   currently calls into `Apply.applyValidTurn` to thread the
   model forward when an action lands. The right direction
   is for Replay to return what it animated; the parent's
   reducer applies it. Game-Replay can have its own
   apply-WireAction-to-snapshot helper that operates on the
   snapshot type, not the Model.
7. **Add an `elm-review` rule** that forbids `import Main.*`
   inside `Game/Replay/`. Cheap, makes the rule a build
   property.
8. **Audit the conformance fixtures.** `replay_walkthroughs.dsl`
   and friends should match the snapshot shape. If any
   fixture encodes broader-game context, re-pin against the
   cleaner shape. Some fixture churn is acceptable.

## The deck/turn complication

Game-Replay needs the deck because `complete_turn` triggers a
draw whose count depends on the turn's outcome (0/3/5 per
canonical Lyn Rummy). Step-Replay does NOT need the deck —
it animates moves up to but not including the next
`complete_turn`. So the deck dependency lives at the outer
layer, not the inner one.

This is exactly why the layering helps: the real-time-agent
caller hits Step-Replay only and is unaffected by the deck
dependency. Game-Replay's wider snapshot is a cost paid only
by the recorded-replay caller.

## Open questions for design phase

- **Where do shared geometry types live?** `Point`,
  `BoardLocation`, etc. These could go in `Game/Geometry/` or
  similar — neutral ground that both Main and Replay can
  import. Worth deciding before file moves start.
- **Does Game-Replay drive Step-Replay in-process, or via
  the same start/done Msg pattern?** The composability story
  is cleaner with explicit Msg lifecycle, but it adds a
  hop. Probably worth a small spike.
- **Pacing knobs as snapshot fields, or a separate config
  type?** Either works; mostly a naming question.
- **DSL fixture organization.** Existing
  `replay_walkthroughs.dsl` — does it need to split into
  step-only fixtures (Step-Replay) and game-level fixtures
  (Game-Replay)?

## What this means for the warm-up

If the audit's right, the warm-up isn't tiny — it's a
focused refactor with a few hundred lines of import
rewriting, file moves, and signature changes. But it sets
up exactly the boundary that lets the real-time-agent flow
plug into Step-Replay cleanly without the parent leaking
into the replay's view of the world. The downstream win is
big enough to justify the effort.

If you'd rather scope it tighter (e.g., "just lift
snapshot types out and leave the file structure alone for
now"), that's also a valid pass — we'd get most of the
type-system enforcement without the import-graph guarantees.
