module Game.Replay.Snapshot exposing
    ( Snapshot
    , activeHand
    )

{-| The Replay subsystem's input surface.

Replay's pure helpers and animation drivers operate against a
`Snapshot` rather than the parent's `Model`. The snapshot
captures exactly what those helpers need: the live board, the
hands and active-player index (so we can resolve the active
hand for hand-origin drags), and the live DOM-measured board
rect (so board-frame coords can be translated to viewport).

The orchestrator (`Game.Replay.Time`) is the bridge: it reads
the parent Model and constructs a Snapshot at each call into
the inner helpers. The inner helpers — `Space`, the four
`Animate*` modules, and `DragAnimation` — never see the parent
Model. That keeps Replay reusable from non-Model callers (the
real-time-agent flow that's coming, what-if analysis tooling,
or any third surface that wants to drive replay-style
animation against constructed state).

Future expansion: when the layered design (Step-Replay,
Game-Replay, Drag) lands explicitly, this snapshot is the
Step-Replay layer's input. A wider Game-Replay snapshot would
add `deck` and an action-stream, and would compose Step-Replay
across turn boundaries.

-}

import Game.CardStack exposing (CardStack)
import Game.Hand as Hand exposing (Hand)


{-| Everything Replay's helpers need to read from the world.

  - `board` — the current positioned stacks.
  - `hands` — all hands; `activeHand` indexes via
    `activePlayerIndex`.
  - `activePlayerIndex` — which seat is "doing" the action;
    drives hand-card source resolution.
  - `boardRect` — live DOM-measured board top-left in viewport.
    `Nothing` until the rect is fetched at replay start.

-}
type alias Snapshot =
    { board : List CardStack
    , hands : List Hand
    , activePlayerIndex : Int
    , boardRect : Maybe { x : Int, y : Int }
    }


{-| Resolve the active hand from the snapshot. Mirrors
`Main.State.activeHand` but takes a Snapshot. If the index
falls off the end of the hands list, returns `Hand.empty` —
this should never happen in a well-formed game; the parent
already logs loud at the Model boundary, so we don't need to
re-emit the diagnostic here.
-}
activeHand : Snapshot -> Hand
activeHand snapshot =
    case List.drop snapshot.activePlayerIndex snapshot.hands of
        h :: _ ->
            h

        [] ->
            Hand.empty
