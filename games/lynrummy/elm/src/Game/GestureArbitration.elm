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
interaction. The actual event flow lives in `Main.elm` (it
talks to `Browser.Events` and the view's mousedown handlers);
everything that *can* be made pure has been pulled out here so
elm-test can reach it.

The disambiguation rule mirrors the TS engine
(`DragDropHelper` in `angry-cat/src/lyn_rummy/game/game.ts`):

- A board-card mousedown captures a "click intent" naming the
  card index within the stack.
- Subsequent pointer movement past `clickThreshold` (squared
  distance) kills the intent. Once dead, it stays dead for
  the gesture.
- At pointer-up, if the intent survived, the gesture is a
  click — split the stack at the captured card index. If the
  intent died, the gesture is a drag — usual drop / place /
  snap-back logic applies.

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
Direct port of the TS literal (`dist_squared(e) > 1`). Tight
enough that any deliberate drag kills it; loose enough that
slight pointer jitter doesn't.

NOTE: Steve knows as a developer and player that the click UI
this threshold powers is sub-optimal — a hand that jitters
more than one pixel between mousedown and mouseup will turn
its intended click into a drag. Preserved verbatim from TS for
faithful-port reasons; tuning waits for after-port iteration.
See `showell/claude_writings/the_bar_for_done.md`.

-}
clickThreshold : Int
clickThreshold =
    1


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
