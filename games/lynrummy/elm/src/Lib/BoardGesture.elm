module Lib.BoardGesture exposing
    ( BoardMouseUp(..)
    , handleMouseUp
    , mouseMove
    , resolveBoardCardGesture
    , startBoardDragInfo
    )

{-| Per-side resolution for board-card mouseup gestures.

`handleMouseUp` returns a `BoardMouseUp` value — a parallel-to-
`GameEvent` outcome shape that flows up to `Game.Play.update`,
which dispatches on the variant. Drag variants carry the
captured `boardPath` inline so `Play` can fire `Wire.sendAction`
without re-deriving the path. The hand-card sibling is
`Lib.HandGesture`.

-}

import Lib.BoardActions exposing (Side)
import Lib.BoardDragTypes exposing (BoardCardDragInfo)
import Lib.CardStack as CardStack exposing (BoardLocation, CardStack)
import Lib.Physics.BoardGeometry as BG
import Lib.Physics.GestureArbitration as GA
import Lib.Physics.WingOracle as WingOracle
import Lib.Point exposing (Point)
import Lib.Status as Status
import Lib.TimeLoc exposing (TimeLoc)
import Lib.WingView as WingView


{-| Result of resolving a board-card mouseup. `MergeStack` and
`MoveStack` carry the captured `boardPath` (in board frame)
so `Game.Play.update` can both apply the event and send the
wire payload without re-deriving anything. `Split` is the
click case (cursor stayed within `clickThreshold` of mousedown),
so it has no meaningful gesture. `BoardCardOffBoard` is the
scold case — the user dropped the cards off the board.
-}
type BoardMouseUp
    = Split { stack : CardStack, cardIndex : Int }
    | MergeStack { source : CardStack, target : CardStack, side : Side, boardPath : List TimeLoc }
    | MoveStack { stack : CardStack, newLoc : BoardLocation, boardPath : List TimeLoc }
    | BoardCardOffBoard


{-| Construct a fresh `BoardCardDragInfo` from a mousedown.
Wings are computed once at start and pinned.
-}
startBoardDragInfo :
    { stack : CardStack
    , cardIndex : Int
    , cursor : Point
    , tMs : Int
    , board : List CardStack
    }
    -> BoardCardDragInfo
startBoardDragInfo { stack, cardIndex, cursor, tMs, board } =
    { stack = stack
    , cardIndex = cardIndex
    , originalCursor = cursor
    , cursor = cursor
    , floaterTopLeft = stack.loc
    , boardPath = [ { tMs = tMs, left = stack.loc.left, top = stack.loc.top } ]
    , wings = WingOracle.wingsForStack stack board
    }


{-| Mouseup handler for a board-card drag. Caller has
pattern-matched out the `BoardCardDragInfo` and passes it in
along with the live board rect. Builds the final info (release
point + closing gesture sample), then resolves into a
`BoardMouseUp` that the caller dispatches on.
-}
handleMouseUp : Point -> Int -> BoardCardDragInfo -> Maybe GA.Rect -> BoardMouseUp
handleMouseUp releasePoint tMs d boardRect =
    let
        delta =
            { x = releasePoint.x - d.cursor.x
            , y = releasePoint.y - d.cursor.y
            }

        releaseFloater =
            { left = d.floaterTopLeft.left + delta.x
            , top = d.floaterTopLeft.top + delta.y
            }

        dFull =
            { d
                | cursor = releasePoint
                , floaterTopLeft = releaseFloater
                , boardPath =
                    d.boardPath
                        ++ [ { tMs = tMs, left = releaseFloater.left, top = releaseFloater.top } ]
            }
    in
    case resolveBoardCardGesture dFull boardRect of
        Just outcome ->
            outcome

        Nothing ->
            BoardCardOffBoard


{-| Resolve a completed board-card drag into the action variant
(if any) it should produce. Click-vs-drag check: if the cursor
is still within `clickThreshold` of `originalCursor`, emit a
`Split` at the captured `cardIndex`. Returns Nothing only for
the off-board case — caller maps that to `BoardCardOffBoard`.
-}
resolveBoardCardGesture : BoardCardDragInfo -> Maybe GA.Rect -> Maybe BoardMouseUp
resolveBoardCardGesture d boardRect =
    if GA.distSquared d.cursor d.originalCursor <= GA.clickThreshold then
        Just (Split { stack = d.stack, cardIndex = d.cardIndex })

    else
        let
            hovered =
                WingView.hoveredWing d.floaterTopLeft (CardStack.stackDisplayWidth d.stack) d.wings
        in
        case hovered of
            Just wing ->
                Just
                    (MergeStack
                        { source = d.stack
                        , target = wing.target
                        , side = wing.side
                        , boardPath = d.boardPath
                        }
                    )

            Nothing ->
                if isCursorOverBoard d.cursor boardRect then
                    if isDropFootprintInBounds (CardStack.size d.stack) d.floaterTopLeft then
                        Just (MoveStack { stack = d.stack, newLoc = d.floaterTopLeft, boardPath = d.boardPath })

                    else
                        Nothing

                else
                    Nothing


{-| Mousemove handler for a board-card drag. Pure state
transformation — advances cursor + floater + gesture path,
recomputes hover status. Caller (the dispatcher in `Game.Play`)
wraps the returned `Info` into `DraggingBoardCard` and patches
the model.

Returns just the bits that change — there's no `Cmd Msg` slot
because mousemove never emits commands.

-}
mouseMove :
    Point
    -> Int
    -> BoardCardDragInfo
    -> Status.StatusMessage
    -> ( BoardCardDragInfo, Status.StatusMessage )
mouseMove pos tMs d currentStatus =
    let
        delta =
            { x = pos.x - d.cursor.x
            , y = pos.y - d.cursor.y
            }

        nextFloater =
            { left = d.floaterTopLeft.left + delta.x
            , top = d.floaterTopLeft.top + delta.y
            }

        nextPath =
            d.boardPath
                ++ [ { tMs = tMs, left = nextFloater.left, top = nextFloater.top } ]

        nextD =
            { d
                | cursor = pos
                , floaterTopLeft = nextFloater
                , boardPath = nextPath
            }

        hover floaterTopLeft =
            WingView.hoveredWing
                floaterTopLeft
                (CardStack.stackDisplayWidth d.stack)
                d.wings

        nextStatus =
            hoverStatus
                (hover d.floaterTopLeft)
                (hover nextD.floaterTopLeft)
                currentStatus
    in
    ( nextD, nextStatus )



-- PRIVATE HELPERS (small enough to duplicate in HandGesture)


hoverStatus :
    Maybe a
    -> Maybe a
    -> Status.StatusMessage
    -> Status.StatusMessage
hoverStatus currentHover nextHover currentStatus =
    if nextHover /= currentHover then
        case nextHover of
            Just _ ->
                wingHoverStatus

            Nothing ->
                currentStatus

    else
        currentStatus


wingHoverStatus : Status.StatusMessage
wingHoverStatus =
    { text = "Drop stack to complete merge.", kind = Status.Inform }


isCursorOverBoard : Point -> Maybe GA.Rect -> Bool
isCursorOverBoard cursor maybeRect =
    case maybeRect of
        Just rect ->
            GA.isCursorInRect cursor rect

        Nothing ->
            False


isDropFootprintInBounds : Int -> BoardLocation -> Bool
isDropFootprintInBounds cardCount loc =
    let
        bounds =
            BG.refereeBounds
    in
    (loc.left >= 0)
        && (loc.top >= 0)
        && (loc.left + BG.stackWidth cardCount <= bounds.maxWidth)
        && (loc.top + BG.cardHeight <= bounds.maxHeight)
