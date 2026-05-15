# Real-time agent — ground rules

What the human should expect from the UI when the agent plays
as Player Two against Steve's Player One. Captured during a
requirements pass on 2026-05-06, ahead of any code or design
decisions. Lives in this directory because the directory is
expected to retire once the feature ships.

## Player One's turn (already implemented; named for completeness)

Steve plays Player One:

- Moves cards on the board, merges stacks, plays hand cards
  to the board or directly to a stack.
- Keeps going until the hand is empty or he gives up.
- May Undo along the way.
- The board must be clean when the turn completes; hasty
  CompleteTurn attempts get admonished.
- On a clean CompleteTurn, the existing modal appears —
  congratulating Steve on the turn or chiding him for not
  playing any cards.

This is all already in the game.

## The handoff

Inside the same congratulations/chiding modal, additional text
reads roughly *"The agent will play next."* When Steve hits
Ok, the baton passes to Player Two.

Sequencing is **strictly sequential** — no overlap with the
modal. The TS engine isn't engaged until Ok is clicked. The
brief "Thinking…" delay that follows is feature, not bug: it
gives Steve time to orient to the new hand he's about to
watch the agent play.

## Player Two's turn (the new behavior)

Once Ok is clicked:

- The player panel switches to Player Two **immediately**.
- The agent's hand is **visible**. (We're not faithful to
  kitchen-table opacity here — watching the agent's reasoning
  is part of the experience.)
- The status bar briefly shows **"Thinking…"** while the TS
  engine computes the first step. Target: ≤ 2-3 seconds.
- The agent's first step animates in the UI.

For each agent step:

- Drags happen at **human pace** (same animation grammar as
  instant replays of Steve's own moves and as instant replays
  of external agent games).
- Clicks happen **"instantly"**.
- Within a step, there's a roughly 1-second pause between
  drags and clicks so Steve can digest each move. (Exact
  interval lives in the existing instant-replay code; we
  inherit it.)

Between steps:

- **Floor: 2 seconds.** Even if the agent's actual
  computation finished faster, the UI waits at least 2s
  before starting the next step's animation. Lyn Rummy is
  not a fast game; it's a relaxing pace.
- If the agent's computation took longer than 2s, the UI
  waits for the actual computation. "Thinking…" reappears in
  the status bar during these waits.

The loop continues — animate step, pause max(actual_ms,
2000), animate next — until the agent yields an
end-of-turn signal (`nextStep` returns `kind: "end"`).

## End of agent turn

When the agent has played the whole hand or run out of
plays:

- A modal appears: *"The agent is done."* (rough wording.)
- Steve hits Ok; baton returns to Player One.

## Lockout during the agent's turn

The human must not be able to play cards or move stacks
while the agent is playing. The board is the agent's
during P2's turn.

Implementation lever: the same code path that runs
instant-replay animations is reused for real-time agent
animation. So we tighten the lockout in the instant-replay
path; the real-time agent inherits the same protection
without a separate code path. Replays of recorded games
should already disable human input — if they currently
don't, that's a bug to fix as the first step of this
project.

## Out of scope (explicit)

- Modal-overlap kickoff (computing while the modal is up).
  Discussed and rejected: sequential is simpler, and the
  pause helps the human orient.
- Hiding the agent's hand for kitchen-table fidelity.
  Discussed and rejected: visibility is part of the value.
- Speeding up the pacing for "expert" players. Lyn Rummy
  is a relaxing-pace game; the 2-second inter-step floor
  is a feature.

## Errors are reflected faithfully

If the agent throws — BFS bug, asserted invariant fires,
unexpected exception — we surface it loud, no paper-over,
no "agent gave up" fallback that would confuse the human
about whether their game state is real. The board stops in
whatever state the failure left it; the human reports the
bug to Steve; while it's being fixed, the human starts a
new game. Nobody dies in Lyn Rummy. Faithful failure beats
fake recovery every time.

## Open questions

These are not blockers — flagging them so they don't get
lost when we move to design:

- The exact wording of the "agent will play next" addition
  to the existing modal.
- The exact wording of the "agent is done" modal.
- Whether "Thinking…" appears in the status bar or somewhere
  else (banner? spinner over the agent's panel? specific
  layout TBD).

## Status (2026-05-15)

### Landed

- **Replay-time input lockout extended.** `Complete-Turn` and
  `Hint` buttons are now gated on a `controlsEnabled` flag.
  During Instant Replay both are disabled; the same flag will
  fire during agent turns. Drag/click input on cards was
  already gated via the view-layer `cardMouseDown` /
  `handIsInteractive` pattern.

- **Canonical DSL convergence.** ONE shape across conformance
  fixtures, the live TS↔Elm wire, action-log replay, and
  transcripts. `(left, top)` coords; Unicode suit glyphs; stack
  refs decorated with `at (left, top)`. Both runtimes share the
  same per-primitive parser (TS-side `dsl/parse.ts`, Elm-side
  `Lib.WireAction.parseEvent`). 528 + 459 + 81 test scenarios
  green after the migration.

- **`agent_step` wire plumbed end-to-end.** TS-side
  `elmAgentStep(boardDsl, handDsl)` → engine_glue `agent_step`
  op → Elm `agentStepResponse` port → `Lib.Engine.decodeAgentStepResponse`
  → `Game.State.agentPendingEvents`. Decoder runs each response
  line through `Lib.WireAction.parseEvent` so the same code
  path serves agent-step + action-log replay. Unit-tested in
  `tests/Lib/EngineTest.elm` (encoder round-trip, decoder
  happy path, stale-id, and engine-error paths).

### Remaining

5. **UI trigger.** Hook the existing turn-end modal: when the
   modal closes and P1's turn was just completed, fire the
   first agent_step request. The modal's Ok button is the
   sequential boundary the spec calls out.

6. **Agent loop.** On `AgentStepReceived` with a non-empty
   event list, push the events through the existing instant-
   replay animation machinery (`Animate.AnimationState` /
   `ReplayTick`). When the animation completes, wait for
   `max(actual_compute_ms, 2000)` and fire the next request.
   When the response is `AgentStepEvents []`, drop the agent
   state and show the end-of-turn modal.

7. **End-of-turn modal + baton return.** Mirror the existing
   turn-end modal shape; close → P1 turn begins.

8. **Lockout extension.** Replace the bare `replayState`
   check at the view layer with a derived "agent or replay
   active" predicate so the `Thinking…` gaps between steps
   also lock human input. The lockout extension should
   probably ride on a new `agentSession : Maybe AgentSession`
   field, since "agent is playing" is semantically distinct
   from "user clicked Instant Replay."

### Design choices to nail down on resumption

- **Action-log integration.** The agent's emitted primitives
  are real game events. Each should be appended to
  `model.actionLog` with a fresh seq so the session record
  stays honest and replays work uniformly — same shape
  human-driven plays use today.
- **Animation reuse vs sibling.** The replay machinery is
  exactly the right shape for agent animation, but
  semantically conflating "replay" and "agent" risks
  surprises later. Likely answer: keep replayState as the
  animation primitive, add a sibling `agentSession` that
  drives the loop and SETS replayState for each step's
  animation.
- **Stale TS-side state.** `Game.State.agentPendingEvents`
  was added as a model field for the wire smoke-test, but
  once the agent loop lands the events flow straight into
  the animation queue. The field may be redundant; revisit
  during step 6.
