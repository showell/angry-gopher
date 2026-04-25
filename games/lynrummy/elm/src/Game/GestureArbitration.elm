module Game.GestureArbitration exposing
    ( Point
    , Rect
    , applySplit
    , clickIntentAfterMove
    , clickThreshold
    , cursorInRect
    , distSquared
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

import Game.CardStack as CardStack exposing (CardStack, stacksEqual)


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
cursorInRect : Point -> Rect -> Bool
cursorInRect p r =
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


{-| Compute the click intent after a pointer-move event.

  - If the intent was already `Nothing`, it stays `Nothing`
    (death is permanent within a gesture).
  - If the intent was `Just _`, it survives iff the cursor's
    squared distance from its original position is `<=
    clickThreshold`. Strictly greater kills it.

-}
clickIntentAfterMove : Point -> Point -> Maybe Int -> Maybe Int
clickIntentAfterMove originalCursor currentCursor intent =
    case intent of
        Nothing ->
            Nothing

        Just _ ->
            if distSquared originalCursor currentCursor > clickThreshold then
                Nothing

            else
                intent


{-| Apply a split: replace the stack at `stackIndex` on the
board with the two stacks produced by `CardStack.split
cardIndex`. Splitting a 1-card stack is a no-op (CardStack.split
returns the stack unchanged); other invalid inputs leave the
board untouched.
-}
applySplit : Int -> Int -> List CardStack -> List CardStack
applySplit stackIndex cardIndex board =
    case listAt stackIndex board of
        Nothing ->
            board

        Just stack ->
            let
                newStacks =
                    CardStack.split cardIndex stack
            in
            List.filter (\s -> not (stacksEqual s stack)) board
                ++ newStacks


listAt : Int -> List a -> Maybe a
listAt i xs =
    List.head (List.drop i xs)
