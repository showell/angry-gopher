# Open questions — elm-lynrummy model port

Unresolved questions about the durable Elm port (`src/LynRummy/`).
Each entry has the question itself, why it matters, current
state, and where it lives in the code. Resolved questions get
deleted — git log + code comments carry the rationale.

---

## 1. Wire format is gesture-lossy

**Observation (2026-04-14):** The current wire format (diff
shape: `stacks_to_remove` / `stacks_to_add` plus
`hand_cards_to_release`) records the *result* of each move,
not the *gesture* the player used.

**Concrete example from a live game:** Steve dropped QC into
an empty slot adjacent to a previously-placed KC. The wire
recorded:

  - remove `[KC]` at (484, 63)
  - add `[QC KC]` at (451, 63)
  - hand released: QC

To Steve, that was one atomic drop. To the wire, a stack
disappeared and a different stack appeared 33 px to the left.
The system inferred the merge; the wire only sees the result.

**Why it matters:**

  - **Replay loses gesture intent.** A replay can show board
    states correctly but can't faithfully animate the player's
    actual move (was it a drop-merge, a pick-and-rebuild, or
    something else?).
  - **Trick analysis becomes inference.** Recognizing "this
    was a peel" or "this was an extend-with-hand-card"
    requires reverse-engineering from before/after diffs. The
    `lynrummy_plays` table does some of this post-hoc, but it
    can't always recover what was lost.
  - **Hint-system feedback loses connection.** If the bot
    suggests a specific gesture and the player follows it, the
    event log doesn't say so; it just shows the board change.

**Connection to a previously-resolved question:** OPEN
QUESTIONS originally had item #3 ("Diff-based state-transition
protocols in LynRummy") and we resolved it as "diff shape is
right." This new question is the explicit *cost* of that
choice. Both true: diff is right for validation/interop AND
gesture-lossiness is a real downside to manage.

**Possible mitigations** (not picking one yet):

  1. Add an explicit `gesture` field on the wire event
     alongside the diff: `{ kind: "drop_into_slot",
     source_card, target_loc }`. Server still validates the
     diff; replay/analysis gets the gesture.
  2. Derive gestures post-hoc from diff analysis. Cheap; less
     precise; sometimes ambiguous.
  3. Capture pre-resolution events (raw drops) and let the
     server resolve. Bigger refactor.

**Location:** wire format lives in `angry-cat` (sender) and
`angry-gopher/lynrummy/wire.go` (receiver). The Elm port's
encoders/decoders mirror the same shape.
