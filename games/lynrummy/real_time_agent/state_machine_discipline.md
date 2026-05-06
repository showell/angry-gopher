# State-machine discipline — Replay and its drag sub-component

This is a design pass on what the boundaries SHOULD look like
for the Replay subsystem and the Drag sub-component nested
inside it. Written before re-reading the current code so the
discipline stays principle-driven rather than reverse-engineered
from whatever shape exists today.

Scope: just these two components and their boundary. Not the
real-time-agent outer loop, not the recorded-replay parent, not
the broader game flow.

## The fundamental shape

In a synchronous world, a replay is a subroutine: `replay(moves)`
runs, animates, returns when done. In Elm there is no
subroutine. There is no blocking, no implicit call stack, no
"sleep N ms" you can `await`. What looks like one subroutine
becomes a state machine whose Model field IS the program
counter, whose Subs run while it's active, whose Update
transitions on every animation frame and every elapsed timer.

The discipline this forces:

- A "subprocedure" is a Model fragment, not a function.
- "Returns control to the caller" is a Msg the parent reducer
  pattern-matches on.
- "Awaits" is a delayed Msg coming back via `Process.sleep` or
  `Browser.Events.onAnimationFrame`.
- The state machine's lifecycle (start, run, complete) is
  expressed in transitions, not in a call stack.

The two components below are state machines under this
discipline. The outer one composes the inner one the same way
sync code would call a subroutine, just with the call/return
expressed as start/done Msgs instead of a function invocation.

## Replay's contract

The Replay component takes a snapshot of the world it needs to
animate, runs through it, and reports done. The full input
surface:

- The board state at the start of the animation.
- The hand state at the start of the animation.
- The active player.
- The ordered list of moves (the same shape moves take when
  the parent records or generates them).
- Any animation-tuning knobs the parent legitimately wants to
  control (duration overrides, etc.) — added to the snapshot
  type, not pulled from the parent's model.

The full output surface:

- A "ready" View while it's animating (drawing the in-flight
  state — board with one card mid-drag, etc.).
- A completion Msg when the move list is exhausted.

Beyond that, Replay knows nothing. It does not know:

- What previous game state preceded this snapshot.
- Whether these moves came from a JSONL transcript, an
  external agent, the real-time agent, or somewhere else.
- Whether the parent intends to persist anything afterward.
- Whether there's a deck, a turn cycle, a winner, an opponent.
- What session id, what URL path, what user.

If Replay is tempted to read any of that, the snapshot type
needs another field — never a peek up. "Reaching up" through
the Model is the failure mode this discipline exists to
prevent.

Symmetrically, Replay does not reach OUT either: no HTTP, no
ports, no annotations-write, no telemetry. Anything the parent
wants to record around the animation is the parent's concern,
done before Start or after Done.

## Drag's contract (the sub-component)

A click is atomic from the UI's perspective. The model snaps
from pre-click to post-click in one Update; the next View
draws the new state. No interpolation, no per-frame state, no
animation-frame Sub. A drag is fundamentally different: it has
duration, an in-flight visual entity that doesn't match any
"real" board position, possibly a path, and a per-frame View
component that draws "card mid-flight."

That asymmetry is why Drag earns its own state-machine layer
INSIDE Replay. While a drag is animating, the Model holds
transient state nothing else should read — current frame,
start loc, end loc, what's being moved. A Sub fires every
frame. A "drag complete" Msg ends it. To Replay's outer loop,
a drag is "hand off to the drag animator; wait for done; then
the next move." Same shape Replay presents to its parent, one
level down.

Drag's input surface:

- The thing being moved (card or stack).
- Start and end coordinates (or path, if non-linear).
- Animation timing (frames, easing, etc.).

Drag's output surface:

- A View while in-flight that draws the moving entity.
- A completion Msg when the animation lands.

What Drag does NOT know:

- That it's inside a Replay (it could in principle be
  triggered by any caller).
- The list of moves coming after this one.
- The board's broader state (it knows where the card came
  FROM and where it's going TO; the rest of the board is
  the caller's responsibility to render around it).
- Whose turn it is. Why this drag is happening.

The same "no reaching up, no reaching out" rule that applies
to Replay applies to Drag, just one level deeper. Drag's
caller is Replay (today); a future caller could be anything
that needs to animate "this card moving from here to there"
with the same grammar.

## Mechanical enforcement

The discipline is convention until the build catches drift.
Make it mechanical:

- **File layout.** Replay and Drag each live in their own
  subdirectory. Imports out of those directories are
  restricted to genuinely shared primitives (rules, card,
  stack, geometry, basic types). Imports of `Main.*`,
  `Game.Strategy.*`, session machinery, agent machinery,
  anything with whole-game context — forbidden.
- **Snapshot types as the input surface.** The Replay snapshot
  type and the Drag snapshot type are the WHOLE input surface.
  Neither component takes a parent Model fragment, a Maybe
  String session id, a list of recent annotations, or any
  other backdoor. The type signature is the contract.
- **Completion Msgs as the output surface.** The Msg types
  the components emit upward should not have variants that
  encode parent-specific intent. "ReplayCompleted" is fine;
  "ReplayCompletedAndPersistAnnotations" is the parent's job.
- **`elm-review` (or grep-equivalent) rules.** A linter rule
  that forbids forbidden imports inside the Replay / Drag
  subdirectories is cheap to add and turns the rule into a
  build property.

The directionality matters. Replay imports primitives; Main
imports Replay; Replay never imports Main. Drag imports
primitives; Replay imports Drag; Drag never imports Replay.
The dependency graph is a DAG and easy to enforce.

## DSL alignment

The conformance fixtures that exercise Replay should respect
the same shape. A replay scenario's input should be exactly
the snapshot the runtime takes — board + hand + active player
+ moves — and its expected output should be exactly the
animation grammar the runtime produces — frames, completions,
end state. If a fixture currently encodes "what session is
this" or "what came before", that fixture is wrong, not the
component.

This is worth checking deliberately during the warm-up. The
existing replay fixtures may already be clean; if any encode
broader-game context, they get re-pinned against the cleaner
shape. That's fine. We accept some fixture churn as the cost
of getting the boundary right.

## Composing around it

Both planned consumers (recorded replay of past sessions,
real-time agent animating its current step list) compose the
same way:

1. Parent constructs the snapshot.
2. Parent fires "start replay" Msg.
3. Parent disables its own input handling for the duration.
4. Replay runs. Its Subs fire while active; its View renders
   the in-flight state.
5. Replay fires "completed."
6. Parent's reducer matches on that and decides what next —
   start the next replay snapshot, run a thinking-pause timer,
   show a modal, hand the baton back, whatever.

The parent state machine knows about the bigger picture; the
replay state machine doesn't. That's the asymmetry the whole
discipline is built around.

## What we're explicitly NOT designing here

- The real-time-agent outer loop. That's the parent state
  machine that calls into Replay. Separate document.
- The exact field names of the snapshot types or completion
  Msgs. Those are implementation details to settle when we
  read the code.
- The animation grammar itself (drag durations, click
  instantness, inter-move pauses). Those are pacing decisions
  governed by `GROUND_RULES.md` in this directory.

## What to look for during implementation review

When we read the current code:

- Where does Replay live in the directory tree? Are its
  imports already constrained, or does it reach up?
- Does Replay take a snapshot, or does it take "the parent
  model"?
- Does Drag exist as its own component, or is its state
  inlined into Replay?
- Is there an `elm-review` rule about imports today, or is
  the boundary convention-only?
- Do the DSL fixtures encode replay-only context, or do they
  pull in broader-game state?

Answers to these will tell us how much the warm-up phase
needs to do — anything from "tighten what's already correct"
to "lift the snapshot type out and rewire imports."
