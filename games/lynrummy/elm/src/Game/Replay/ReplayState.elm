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


{-| Replay's three durable phases. Transient transitions
(applying an event, signaling completion) happen within
one tick and don't show up here.

  - `Starting` — pre-arm. The clock hasn't been seen yet;
    the first frame to arrive sets the next beat deadline.
    Used at replay click and on resume-from-pause so each
    gives a fresh full beat.
  - `InBeat` — holding between actions. `nextBeatMs` is the
    absolute deadline at which the next entry pops.
  - `Animating` — a board-drag animation is in flight; the
    sub-machine in `Game.Replay.BoardDragAnimate` owns its
    own state and signals completion via its `Outcome` type.

-}
type Phase
    = Starting
    | InBeat { nextBeatMs : Int }
    | Animating BoardDragAnimate.State
