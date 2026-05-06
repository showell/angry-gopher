module Main.Types exposing
    ( GesturePoint
    , PathFrame(..)
    , Point
    )

{-| Small shared data types — extracted from `Main.State` so
the downstream knot loosens.

These are leaf types: they reference nothing else in the app.
Anything in the codebase can import them without inheriting
the game's `Model` or any other state-shape baggage. As we
keep splitting `Main.State` down, more types may land here.

-}


type alias Point =
    { x : Int, y : Int }


{-| Coordinate frame for a captured gesture path. The board
is a self-contained widget positioned anywhere in the app via
CSS; drag floaters rendered as children of the board take
board-frame coords directly. Hand-origin drags cross the board
widget boundary and must be viewport-positioned.

  - **ViewportFrame** — origin at the browser viewport top-left.
    Used for live mouse-captured paths and for hand-origin
    drags that cross widget boundaries.
  - **BoardFrame** — origin at the board element's top-left.
    Used for intra-board drags (Python-synthesized and,
    eventually, board-to-board live-captured after a
    capture-time translation).

-}
type PathFrame
    = ViewportFrame
    | BoardFrame


{-| Behaviorist telemetry sample captured during a drag. The
`tMs` is the `MouseEvent.timeStamp` (performance.now-style,
document-lifetime relative). The `x`/`y` pair is in whichever
frame the containing path is tagged with (see `PathFrame`).
-}
type alias GesturePoint =
    { tMs : Float, x : Int, y : Int }
