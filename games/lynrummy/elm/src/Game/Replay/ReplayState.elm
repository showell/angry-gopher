module Game.Replay.ReplayState exposing (Phase(..), ReplayState)

{-| Instant Replay's working state.

Owned by `Game.Replay.Animate`. Lives on `Main.State.Model`
as `Maybe ReplayState`: `Just _` while a replay is in flight,
`Nothing` otherwise.

The View reads `gameState` (to render the replay's evolving
board + sidebar), `paused` (to pick the Pause/Resume button
label), and inspects `phase` to source the drag floater
during board-drag and hand-drag animations. All other fields
are private to `Animate`.

-}

import Game.ActionLog exposing (ActionLogEntry)
import Game.Game exposing (GameState)
import Game.Replay.BoardDragAnimate as BoardDragAnimate
import Game.Replay.HandDragAnimate as HandDragAnimate


{-| Replay's five phases. Each tick reads `phase`, does its
phase-appropriate work, and transitions accordingly.

  - `Starting` — pre-arm. The clock hasn't been seen yet;
    the first frame to arrive sets the next beat deadline.
    Used at replay click and on resume-from-pause so each
    gives a fresh full beat.
  - `InBeat` — holding between actions. `nextBeatMs` is the
    absolute deadline at which the next entry pops.
  - `ActionCompleted` — transient (one tick): an action has
    just been applied (either inline by `startNextAction`
    for instant-apply events, or by a sub-machine's `Done`
    outcome for animated events). The next tick schedules
    the inter-action beat and transitions to `InBeat`.
  - `AnimatingBoardAction` — a board-drag animation is in
    flight. The sub-machine applies its event and signals
    `Done` when the path completes.
  - `AnimatingHandAction` — a hand-drag animation is in
    flight. Same shape as the board side; the sub-state
    owns the NotYetMeasured / AwaitingMeasurement / InFlight
    distinctions internally.

-}
type Phase
    = Starting
    | InBeat { nextBeatMs : Int }
    | ActionCompleted
    | AnimatingBoardAction BoardDragAnimate.State
    | AnimatingHandAction HandDragAnimate.State


type alias ReplayState =
    { queue : List ActionLogEntry
    , gameState : GameState
    , paused : Bool
    , phase : Phase
    }
