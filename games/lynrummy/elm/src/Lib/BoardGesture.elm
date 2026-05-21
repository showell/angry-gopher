module Lib.BoardGesture exposing
    ( BoardPointerUp(..)
    , handlePointerUp
    , pointerMove
    , pressPendingEscaped
    , resolveBoardCardGesture
    , startBoardDragInfo
    , startPressPending
    , upgradePressToBoardDrag
    )

{-| Per-side resolution for board-card pointerup gestures.

`handlePointerUp` returns a `BoardPointerUp` value — a parallel-to-
`GameEvent` outcome shape that flows up to `Game.Play.update`,
which dispatches on the variant. Drag variants carry the
captured `boardPath` inline so `Play` can fire `Wire.sendAction`
without re-deriving the path. The hand-card sibling is
`Lib.HandGesture`.

-}

import Lib.BoardActions exposing (Side)
import Lib.BoardDragTypes exposing (BoardCardDragInfo, PressPendingInfo)
import Lib.CardStack as CardStack exposing (BoardLocation, CardStack)
import Lib.NonEmpty as NonEmpty exposing (NonEmpty)
import Lib.Physics.BoardGeometry as BG
import Lib.Physics.GestureArbitration as GA
import Lib.Physics.WingOracle as WingOracle
import Lib.Point exposing (Point)
import Lib.Status as Status
import Lib.TimeLoc exposing (TimeLoc)
import Lib.WingView as WingView


{-| Result of resolving a board-card pointerup. `MergeStack` and
`MoveStack` carry the captured `boardPath` (in board frame)
so `Game.Play.update` can both apply the event and send the
wire payload without re-deriving anything. `Split` carries the
already-decided `leftCount` (logical split — clicked card joins
the smaller chunk); downstream sees a single unambiguous
number, no rule to re-apply. `BoardCardOffBoard` is the scold
case — the user dropped the cards off the board.
-}
type BoardPointerUp
    = Split { stack : CardStack, leftCount : Int }
    | MergeStack { source : CardStack, target : CardStack, side : Side, boardPath : NonEmpty TimeLoc }
    | MoveStack { stack : CardStack, newLoc : BoardLocation, boardPath : NonEmpty TimeLoc }
    | BoardCardOffBoard


{-| Construct a `PressPendingInfo` from a pointerdown — the
quiet phase before either (a) cursor escapes clickThreshold
and upgrades to a whole-stack drag, or (b) the long-press
timer fires and triggers an isolate.
-}
startPressPending :
    { stack : CardStack
    , cardIndex : Int
    , cursor : Point
    , tMs : Int
    , board : List CardStack
    }
    -> PressPendingInfo
startPressPending { stack, cardIndex, cursor, tMs, board } =
    { stack = stack
    , cardIndex = cardIndex
    , originalCursor = cursor
    , startTimeMs = tMs
    , board = board
    }


{-| True iff the cursor has moved enough from the original
pointerdown position to escape the long-press quiet phase. Same
threshold the click-vs-drag arbiter uses at pointerup.
-}
pressPendingEscaped : Point -> PressPendingInfo -> Bool
pressPendingEscaped cursor p =
    GA.distSquared cursor p.originalCursor > GA.clickThreshold


{-| Upgrade a `PressPendingInfo` to a whole-stack
`BoardCardDragInfo` once the cursor has escaped the quiet
threshold. Equivalent to having entered `DraggingBoardCard`
on pointerdown directly, with the recorded pointerdown timestamp
seeding the gesture path.
-}
upgradePressToBoardDrag : PressPendingInfo -> BoardCardDragInfo
upgradePressToBoardDrag p =
    startBoardDragInfo
        { stack = p.stack
        , cardIndex = p.cardIndex
        , cursor = p.originalCursor
        , tMs = p.startTimeMs
        , board = p.board
        }


{-| Construct a fresh `BoardCardDragInfo` from a pointerdown.
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
    , boardPath = NonEmpty.singleton { tMs = tMs, left = stack.loc.left, top = stack.loc.top }
    , wings = WingOracle.wingsForStack stack board
    }


{-| Pointerup handler for a board-card drag. Caller has
pattern-matched out the `BoardCardDragInfo` and passes it in
along with the live board rect. Builds the final info (release
point + closing gesture sample), then resolves into a
`BoardPointerUp` that the caller dispatches on.
-}
handlePointerUp : Point -> Int -> BoardCardDragInfo -> Maybe GA.Rect -> BoardPointerUp
handlePointerUp releasePoint tMs d boardRect =
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
                    NonEmpty.append
                        { tMs = tMs, left = releaseFloater.left, top = releaseFloater.top }
                        d.boardPath
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
`Split` with the gesture-time logical leftCount (the clicked
card joins whichever chunk is smaller). Returns Nothing only
for the off-board case — caller maps that to `BoardCardOffBoard`.
-}
resolveBoardCardGesture : BoardCardDragInfo -> Maybe GA.Rect -> Maybe BoardPointerUp
resolveBoardCardGesture d boardRect =
    if GA.distSquared d.cursor d.originalCursor <= GA.clickThreshold then
        Just
            (Split
                { stack = d.stack
                , leftCount = clickToLeftCount d.cardIndex (CardStack.size d.stack)
                }
            )

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


{-| Pointermove handler for a board-card drag. Pure state
transformation — advances cursor + floater + gesture path,
recomputes hover status. Caller (the dispatcher in `Game.Play`)
wraps the returned `Info` into `DraggingBoardCard` and patches
the model.

Returns just the bits that change — there's no `Cmd Msg` slot
because pointermove never emits commands.

-}
pointerMove :
    Point
    -> Int
    -> BoardCardDragInfo
    -> Status.StatusMessage
    -> ( BoardCardDragInfo, Status.StatusMessage )
pointerMove pos tMs d currentStatus =
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
            NonEmpty.append
                { tMs = tMs, left = nextFloater.left, top = nextFloater.top }
                d.boardPath

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


{-| Translate "user clicked card at index `cardIndex`" into the
logical `leftCount` of the resulting split. The clicked card
joins whichever chunk is smaller — first-half click → clicked
card ends the left chunk (leftCount = cardIndex + 1);
second-half click → clicked card starts the right chunk
(leftCount = cardIndex). This is the one gesture-time decision
about which side the user meant; downstream physics
(`Lib.CardStack.split`) only sees `leftCount`.
-}
clickToLeftCount : Int -> Int -> Int
clickToLeftCount cardIndex stackSize =
    if cardIndex + 1 <= stackSize // 2 then
        cardIndex + 1

    else
        cardIndex
