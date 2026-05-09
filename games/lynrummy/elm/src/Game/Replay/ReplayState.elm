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


{-| Replay always sits in one of two modes:

  - `Beat` — between actions, including the pre-roll before
    the first apply. `nextBeatMs = 0` means "arm on next
    frame"; nonzero is the absolute deadline at which the
    next action pops off the queue.
  - `Animating` — a board-drag animation is in flight. The
    sub-state-machine in `Game.Replay.BoardDragAnimate` owns
    its own state and signals completion via its `Outcome`
    type; `Animate.tick` translates that back into a `Beat`
    transition (after applying the pending action).

-}
type Phase
    = Beat { nextBeatMs : Int }
    | Animating BoardDragAnimate.State
