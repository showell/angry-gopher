module Game.Replay.DragAnimation exposing (Step(..), step)

{-| A drag-animation sub-state-machine, factored out of the
broader `Game.Replay.Time` orchestrator.

This is the **physics half** of replay: given the current
clock time and an `AnimationInfo` (which carries a path,
start time, and the eventual `WireAction` to apply when the
animation completes), produce a `Step` describing what
should happen next.

The outer replay state machine in `Game.Replay.Time` calls
`step` on every animation frame and reacts:

  - `InProgress` → set the drag overlay to the returned
    `DragState` and keep waiting for the next frame.
  - `Done` → apply the `pendingAction` and advance to the
    next replay phase (typically `Beating`).

The seam between this module and `Time` is the
**testability boundary**: drag animation is deterministic
(time, path, source → cursor position; cursor + path-end →
done), so it can be locked down with rigorous property
tests. The outer cadence (PreRolling holds, inter-action
beats, AwaitingHandRect timing) carries volatile UX-tuning
values and stays test-light.

-}

import Game.Replay.Space as Space
import Game.WireAction exposing (WireAction)
import Main.State exposing (DragState)


{-| The result of advancing the animation by one frame.

  - `InProgress drag` — animation still running; `drag` is
    the `DragState` the View layer should render this frame.
  - `Done pendingAction` — animation is complete; the outer
    machine should apply `pendingAction` and transition.

The empty-path case (a path with no samples) collapses to
`Done` immediately, treating "nothing to interpolate" as
"animation already complete."

-}
type Step
    = InProgress { drag : DragState }
    | Done { pendingAction : WireAction }


{-| Advance the animation one step. Pure function of (clock
time, animation info). Returns the rendering payload for
this frame OR a Done signal when the animation has elapsed.

The contract is intentionally narrow: `step` does NOT mutate
or know about the broader `Model`. It speaks only the
animation's own facts. That makes it deterministically
testable AND keeps the outer replay machine free to change
its pacing rules without disturbing the physics.

-}
step : Float -> Space.AnimationInfo -> Step
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
            Just cursor ->
                InProgress { drag = Space.animatedDragState anim cursor }

            Nothing ->
                -- Empty path means nothing to interpolate; treat
                -- as animation complete and move on.
                Done { pendingAction = anim.pendingAction }
