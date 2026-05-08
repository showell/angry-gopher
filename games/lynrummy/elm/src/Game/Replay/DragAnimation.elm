module Game.Replay.DragAnimation exposing (Step(..), step)

{-| A drag-animation sub-state-machine, factored out of the
broader `Game.Replay.Time` orchestrator.

This is the **physics half** of replay: given the current
clock time and the animation's per-step bundle (path, start
time, eventual `GameEvent`), produce a `Step` describing
what should happen next.

The outer replay state machine in `Game.Replay.Time` calls
`step` on every animation frame and reacts:

  - `InProgress` → patch the returned `floaterTopLeft` into
    `model.drag` (via `Drag.setFloaterTopLeft`) and keep
    waiting for the next frame.
  - `Done` → apply the `pendingAction` and advance to the
    next replay phase (typically `Beating`).

The seam between this module and `Time` is the
**testability boundary**: drag animation is deterministic
(time + path → cursor position; cursor + path-end → done), so
it can be locked down with rigorous property tests. The outer
cadence (PreRolling holds, inter-action beats,
AwaitingHandRect timing) carries volatile UX-tuning values
and stays test-light.

-}

import Game.Replay.Space as Space
import Game.GameEvent exposing (GameEvent)
import Game.TimeLoc exposing (TimeLoc)
import Main.Types exposing (Point)


{-| The result of advancing the animation by one frame.

  - `InProgress { floaterTopLeft }` — animation still running;
    the caller should patch this point into the current
    drag's `floaterTopLeft`.
  - `Done { pendingAction }` — animation is complete; the
    outer machine should apply `pendingAction` and transition.

The empty-path case (a path with no samples) collapses to
`Done` immediately, treating "nothing to interpolate" as
"animation already complete."

-}
type Step
    = InProgress { floaterTopLeft : Point }
    | Done { pendingAction : GameEvent }


{-| Advance the animation one step. Pure function of (clock
time, animation bundle). Returns the next floater position OR
a Done signal when the animation has elapsed.

The contract is intentionally narrow: `step` does NOT mutate
or know about the broader `Model` — and now does not even
know about `DragState`. It speaks only the animation's own
facts (when, where along the path, what to apply at end).
That keeps the function deterministically testable and lets
the outer replay machine evolve its DragState patching
strategy independently.

-}
step :
    Float
    ->
        { a
            | startMs : Float
            , path : List TimeLoc
            , pendingAction : GameEvent
        }
    -> Step
step nowMs anim =
    let
        duration =
            Space.pathDuration anim.path

        elapsed =
            nowMs - anim.startMs
    in
    if elapsed >= duration then
        Done { pendingAction = anim.pendingAction }

    else
        case Space.interpPath anim.path elapsed of
            Just point ->
                InProgress { floaterTopLeft = point }

            Nothing ->
                -- Empty path means nothing to interpolate; treat
                -- as animation complete and move on.
                Done { pendingAction = anim.pendingAction }
