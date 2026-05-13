module Lib.Physics.GestureArbitration exposing
    ( Point
    , Rect
    , clickThreshold
    , distSquared
    , isCursorInRect
    )

{-| Pure helpers for click-vs-drag arbitration during a board
interaction. Event flow lives in the update loop; what can be
made pure has been pulled here so elm-test can reach it.

The rule:

  - A board-card mousedown captures a "click intent" naming the
    card index within the stack.
  - Pointer movement past `clickThreshold` (squared distance)
    kills the intent. Once dead, it stays dead for the gesture.
  - At pointer-up, a surviving intent means a click — split the
    stack at the captured card. A dead intent means a drag —
    normal drop / place / snap-back logic applies.

-}


type alias Point =
    { x : Int, y : Int }


type alias Rect =
    { x : Int, y : Int, width : Int, height : Int }


{-| Half-open AABB containment check: `x >= rect.x && x < rect.x + rect.width`,
same for y. A point on the top/left edge is inside; a point on the
bottom/right edge is outside. Used at drop time to decide whether
a snap-back should apply — the decision is a drop-time predicate,
not a flag tracked during the drag.
-}
isCursorInRect : Point -> Rect -> Bool
isCursorInRect p r =
    (p.x >= r.x)
        && (p.x < r.x + r.width)
        && (p.y >= r.y)
        && (p.y < r.y + r.height)


{-| Squared-distance threshold above which click intent dies.
`9` = up to 3 pixels of axis movement (or ~2 diagonal) still
reads as a click. Measured: accidental clicks bother players
more than accidental drags, so err tight.
-}
clickThreshold : Int
clickThreshold =
    9


distSquared : Point -> Point -> Int
distSquared a b =
    let
        dx =
            a.x - b.x

        dy =
            a.y - b.y
    in
    dx * dx + dy * dy
