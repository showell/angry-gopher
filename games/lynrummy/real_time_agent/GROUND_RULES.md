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

## V1 status

V1 wired end-to-end and Steve has driven it in a browser.
P1's turn-end modal kicks off the agent (`PopupOk` →
`startAgentTurn` in `Game.Play`); each `agent_step` response's
events animate through a sibling `agentMoveAnimationState`
field (same shape as `replayState`, distinct name); on
`Animate.Completed` we apply the animation's final gameState
and fire the next request; empty events apply `CompleteTurn`
and show an "agent done" popup. Lockout:
`humanInputLocked = activeAnimation ≠ Nothing || agentTurnActive`,
consulted by both card handlers and `controlsEnabled`.

### Open

- **Instant Replay is broken.** The path-bearing wire / NonEmpty
  type changes interact with the existing replay flow in some
  way that Steve flagged. Diagnose before further polish.
- **Code cleanup pass owed** (Steve drives).
- **2-second between-step floor not implemented.** V1 inherits
  `Animate`'s 700ms intra-step beats but doesn't enforce the
  spec's `max(actual_compute_ms, 2000)` between-step pause.
- **Action-log integration deferred.** Agent events evolve
  `model.gameState` in memory only — they don't append to
  `model.actionLog` or the on-disk transcript, so reloading
  during/after P2's turn drops the agent's plays. Steve is
  undecided on the right serialization shape.
- **End-of-turn modal copy** is placeholder; Steve owns the
  wording.
