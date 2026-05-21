module Lib.HandGesture exposing
    ( HandPointerUp(..)
    , handlePointerUp
    , pointerMove
    , resolveHandCardGesture
    , startHandDragInfo
    )

{-| Per-side resolution for hand-card pointerup gestures.
Symmetric to `Lib.BoardGesture`. Hand-origin actions ship
pathless (replay re-synthesizes via DOM).

`handlePointerUp` returns a `HandPointerUp` value that flows up to
`Game.Play.update` for dispatch.

-}

import Lib.BoardActions exposing (Side)
import Lib.CardStack as CardStack exposing (BoardLocation, CardStack, HandCard)
import Lib.HandDragTypes exposing (HandCardDragInfo)
import Lib.Physics.BoardGeometry as BG
import Lib.Physics.GestureArbitration as GA
import Lib.Physics.WingOracle as WingOracle
import Lib.Point exposing (Point)
import Lib.Rules.Card exposing (Card)
import Lib.Status as Status
import Lib.WingView as WingView


{-| Result of resolving a hand-card pointerup. `MergeHand` and
`PlaceHand` carry the same payloads as their `GameEvent`
cousins; update in `Game.Play` translates and feeds them to
`Apply.applyAction`. `HandCardOffBoard` is the scold case.
`HandNothing` covers the rect-not-measured race (the user
released before `BoardRectReceived` arrived) — drop is not
geometrically interpretable yet. Mirror of
`BoardGesture.BoardPointerUp`, minus the path.
-}
type HandPointerUp
    = MergeHand { handCard : Card, target : CardStack, side : Side }
    | PlaceHand { handCard : Card, loc : BoardLocation }
    | HandCardOffBoard
    | HandNothing


{-| Construct a fresh `HandCardDragInfo` from a pointerdown.
Mirror of `BoardGesture.startBoardDragInfo`. The initial
floater seed is "slightly above-and-left of the cursor" —
hand-origin drags don't capture the source rect, so the seed
is a heuristic that gets overwritten on the first PointerMove.
-}
startHandDragInfo :
    { handCard : HandCard
    , cursor : Point
    , board : List CardStack
    }
    -> HandCardDragInfo
startHandDragInfo { handCard, cursor, board } =
    { card = handCard.card
    , cursor = cursor
    , floaterTopLeft =
        { x = cursor.x - CardStack.stackPitch // 2
        , y = cursor.y - 20
        }
    , wings = WingOracle.wingsForHandCard handCard board
    }


{-| Pointerup handler for a hand-card drag. Caller has
pattern-matched out the `HandCardDragInfo` and passes it in
along with the live board rect. Hand drags don't capture a
gesture path, so no `tMs` parameter. Returns a `HandPointerUp`
that the caller dispatches on.
-}
handlePointerUp : Point -> HandCardDragInfo -> Maybe GA.Rect -> HandPointerUp
handlePointerUp releasePoint d maybeRect =
    let
        delta =
            { x = releasePoint.x - d.cursor.x
            , y = releasePoint.y - d.cursor.y
            }

        releaseFloater =
            { x = d.floaterTopLeft.x + delta.x
            , y = d.floaterTopLeft.y + delta.y
            }

        dFull =
            { d
                | cursor = releasePoint
                , floaterTopLeft = releaseFloater
            }
    in
    case resolveHandCardGesture dFull maybeRect of
        Just outcome ->
            outcome

        Nothing ->
            case maybeRect of
                Just rect ->
                    let
                        floaterBoardLoc =
                            { left = dFull.floaterTopLeft.x - rect.x
                            , top = dFull.floaterTopLeft.y - rect.y
                            }
                    in
                    if isDropFootprintInBounds 1 floaterBoardLoc then
                        HandNothing

                    else
                        HandCardOffBoard

                Nothing ->
                    HandNothing


{-| Hand-card resolution requires the live board rect for both
the wing-hover hit-test (lifting board-frame eventual landings
into viewport frame) and the drop-loc translation. With no rect
yet, no honest action is possible — return Nothing.
-}
resolveHandCardGesture : HandCardDragInfo -> Maybe GA.Rect -> Maybe HandPointerUp
resolveHandCardGesture d maybeRect =
    case maybeRect of
        Nothing ->
            Nothing

        Just rect ->
            let
                floaterBoardLoc =
                    { left = d.floaterTopLeft.x - rect.x
                    , top = d.floaterTopLeft.y - rect.y
                    }

                hovered =
                    WingView.hoveredWing floaterBoardLoc CardStack.stackPitch d.wings
            in
            case hovered of
                Just wing ->
                    Just
                        (MergeHand
                            { handCard = d.card
                            , target = wing.target
                            , side = wing.side
                            }
                        )

                Nothing ->
                    if GA.isCursorInRect d.cursor rect then
                        if isDropFootprintInBounds 1 floaterBoardLoc then
                            Just (PlaceHand { handCard = d.card, loc = floaterBoardLoc })

                        else
                            Nothing

                    else
                        Nothing


{-| Pointermove handler for a hand-card drag. Caller wraps the
returned `Info` into `DraggingHandCard`. Hand drags don't
capture a gesture path, so no `tMs`.
-}
pointerMove :
    Point
    -> HandCardDragInfo
    -> Maybe GA.Rect
    -> Status.StatusMessage
    -> ( HandCardDragInfo, Status.StatusMessage )
pointerMove pos d maybeBoardRect currentStatus =
    let
        delta =
            { x = pos.x - d.cursor.x
            , y = pos.y - d.cursor.y
            }

        nextFloater =
            { x = d.floaterTopLeft.x + delta.x
            , y = d.floaterTopLeft.y + delta.y
            }

        nextD =
            { d
                | cursor = pos
                , floaterTopLeft = nextFloater
            }

        hover floaterTopLeft =
            case maybeBoardRect of
                Just rect ->
                    let
                        floaterBoardLoc =
                            { left = floaterTopLeft.x - rect.x
                            , top = floaterTopLeft.y - rect.y
                            }
                    in
                    WingView.hoveredWing floaterBoardLoc CardStack.stackPitch d.wings

                Nothing ->
                    Nothing

        nextStatus =
            hoverStatus
                (hover d.floaterTopLeft)
                (hover nextD.floaterTopLeft)
                currentStatus
    in
    ( nextD, nextStatus )



-- PRIVATE HELPERS (small enough to duplicate from BoardGesture)


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
