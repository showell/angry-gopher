module Game.Replay.ReplayState exposing (Phase(..), ReplayState)

{-| Instant Replay's working state.

Owned by `Game.Replay.Animate`. Lives on `Main.State.Model`
as `Maybe ReplayState`: `Just _` while a replay is in flight,
`Nothing` otherwise.

The View reads `gameState` (to render the replay's evolving
board + sidebar), `paused` (to pick the Pause/Resume button
label), and inspects `phase` to source the drag floater
during board-drag animations. All other fields are private
to `Animate`.

-}

import Game.ActionLog exposing (ActionLogEntry)
import Game.Game exposing (GameState)
import Game.Replay.BoardDragAnimate as BoardDragAnimate


type alias ReplayState =
    { queue : List ActionLogEntry
    , gameState : GameState
    , paused : Bool
    , phase : Phase
    }


{-| Replay's four phases. Each tick reads `phase`, does its
phase-appropriate work, and transitions accordingly.

  - `Starting` — pre-arm. The clock hasn't been seen yet;
    the first frame to arrive sets the next beat deadline.
    Used at replay click and on resume-from-pause so each
    gives a fresh full beat.
  - `InBeat` — holding between actions. `nextBeatMs` is the
    absolute deadline at which the next entry pops.
  - `ExecutingAction` — transient (one tick): a non-animated
    action has been popped and the next tick will fold it
    into `gameState` via `Execute.applyEvent`.
  - `AnimatingAction` — a board-drag animation is in flight;
    the sub-machine in `Game.Replay.BoardDragAnimate` owns
    its own state.

The `*Action` suffix marks the two phases that represent a
popped action being processed; `Starting` and `InBeat` are
in-between idle phases.

-}
type Phase
    = Starting
    | InBeat { nextBeatMs : Int }
    | ExecutingAction ActionLogEntry
    | AnimatingAction BoardDragAnimate.State
