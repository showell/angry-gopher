# Drag-Execution Study — Research Plan

As of 2026-04-19. Durability: valid until telemetry broadens beyond drags;
at that point this plan forks.

## Pipeline state (what's already built)

- **Capture (Elm)** — `Main/Gesture.elm` buffers a `GesturePoint` list per
  drag; `Main.elm` `MouseMove` decoder pulls `timeStamp`; `Main/Wire.elm`
  flushes the buffer in a POST envelope `{action, gesture_metadata}`.
- **Persist (Go)** — `views/lynrummy_elm.go` parses the envelope; stores
  path JSON in `lynrummy_elm_actions.gesture_metadata` (schema/schema.go).
- **Replay (Elm)** — `Main.elm` `replayFrame` state machine animates drags
  at real-captured speed via `onAnimationFrame`, with a fixed 1-second
  inter-action beat (think-time deliberately discarded).
- **Read** — gesture-metadata analysis reads directly from
  SQLite; HTTP bypassed for analysis data. (The legacy Python
  reader retired with the rest of the python/ subtree on
  2026-05-04; future analysis tooling lives elsewhere.)

Validation gate: Instant Replay at real speed. If a replay doesn't feel
faithful, the bug is in capture — fix before running analyses.

## The question

Only one: how does an expert LynRummy player execute physical moves on a
drag-and-drop surface? Not what they decide. Not why. Only the motor
fragment of play — the shape and timing of each deliberate drag.

## The subject

Steve. Wearing two hats at once:

- **Lab rat** — plays LynRummy; each drag is a trial. Opaque in this role.
  What Steve-the-rat "meant to do" is not data.
- **Co-scientist** — reviews the data, flags anomalies, iterates on this
  plan. Aware of every instrument. Can annotate after the fact.

Keeping the hats separate matters. The co-scientist's introspection is
useful for *study design*, not for *interpreting individual trials*. We
don't back-fill "Steve was probably tired there" into a row of data.

## The stance

Strict behaviorism. We measure observable physical actions. We do NOT
infer attention, intent, hesitation, fluency, or any inner state — the
memory entry `feedback_behaviorist_scientist.md` applies throughout.

Behaviorism isn't a pose; it's what makes findings generalize. The moment
we start annotating "Steve was thinking here," the data stops being data
and becomes a diary.

## What we measure

Each drag-derived WireAction (Split, MergeStack, MergeHand, PlaceHand,
MoveStack) carries `gesture_metadata.path`: a list of `{t, x, y}` samples
from `MouseEvent.timeStamp` (fractional ms, performance.now-style) and
viewport coordinates. One sample per `pointermove` event during the drag.
Persisted verbatim in `lynrummy_elm_actions.gesture_metadata`. Python reads
direct from SQLite.

Per-drag, the path gives us:

- Duration (`last.t - first.t`)
- Start and end positions (first/last point)
- Intermediate trajectory (all samples)
- Sample count (roughly duration × event rate)
- Derived quantities: path length, straight-line distance, their ratio,
  velocity profile, direction-change events.

## What we deliberately do NOT measure

Deliberate omissions are part of the study, not laziness:

- **Hover or dwell.** Environment-noisy (mouse vs. trackpad, second
  monitor, cat in lap). Presence ≠ attention.
- **Inter-drag intervals.** Steve is at a coffee shop; people interrupt
  him. Wall-clock between drags is meaningless noise, so we treat it as
  unmeasurable from day one. Replay enforces this: the inter-action beat
  is a fixed 1s, never the real interval.
- **Click timings, button presses, hint interactions.** These are
  deliberate actions and in-scope for behaviorist telemetry eventually —
  but out of scope for this study. A later plan takes them.
- **Strategy.** Not a strategy study. The data says nothing about whether
  a move was good or a game was well-played.

## In-scope questions

Operational, not interpretive. Each is something the data can answer
without peering into the subject's head:

- Distribution of drag duration by action kind (split / merge stack /
  merge hand / place hand / move stack).
- Path length divided by straight-line distance. 1.0 = ruler-straight;
  >> 1.0 = curvy or hesitant in motor terms.
- End-of-drag coordinate clustering: do drops land near wing hit boxes,
  near board edges, or in open space?
- Mid-drag reversals: how often does the path change heading by > 90°?
  Is reversal rate stable or does it change over a session?
- Duration distributions by outcome class (merge vs. place vs. move):
  are some motor patterns slower on average?

## Out-of-scope questions

- "Did Steve hesitate on this turn?" — not measurable from drag data
  alone. Deferred, possibly forever.
- "Is Steve a better player than a novice?" — no baseline subject, no
  comparison group. Not this study.
- "What was Steve thinking when he chose merge over split?" — inner
  state. Not this study, not any study.

## Protocol

- Steve plays 3–4 moves per session. Small n per session keeps the
  coffee-shop interruption risk low.
- Each session uses a fresh game (games are ephemeral by default).
- Interesting positions get promoted to puzzles (manual curation) and
  archived separately. Puzzles are the only long-lived artifact.
- After each session Steve hits Instant Replay and visually confirms the
  outbound capture: does the re-animation look like what actually
  happened? Yes = capture is faithful. No = data is suspect and the bug
  is in the capture pipe.
- Sessions are read post-hoc directly from SQLite for analysis.

## Replay as validation gate

Instant Replay at real speed is not a nicety — it is the primary
validation instrument. We do NOT trust post-hoc analyses until
Steve has watched at least one replay after every study-design change
and confirmed the felt accuracy. This is the enumerate-and-bridge pattern
applied to research data: the outbound path (capture) and the visual
replay (consumption) must agree, and Steve's eyes are the forcing function.

If the replay ever looks wrong, we stop and fix capture before proceeding
to any analysis.

## Durability

This plan expires when:

- Telemetry broadens beyond drags (click timings, hint interactions,
  undo events) — a new plan takes the broader data.
- A second human subject joins — current plan is strictly n=1. Adding
  comparisons requires a new plan with protocol for keeping environments
  comparable.
- Steve's environment changes enough to alter what counts as noise (e.g.,
  switching from mouse to tablet). Some captured quantities — path
  curvature, sample rate — are input-modality-bound and don't survive
  modality changes.

## Confidence tiers

- **Firm**: what we capture (drag paths), the wire shape, and the
  replay-validation protocol. These are shipped.
- **Working**: the specific in-scope questions. Will evolve as the
  co-scientist hat iterates.
- **Tentative**: the particular analyses Python will run. `telemetry.py`
  today exposes raw reads and a `drag_summary` helper; the analyses above
  (path-length ratio, reversals, clustering) are study-design targets
  that imply small Python helpers we haven't written yet.
