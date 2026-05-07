module Game.HandGesture exposing
    ( handleMouseUp
    , mouseMove
    , resolveHandCardGesture
    )

{-| Per-side resolution and application for hand-card drags.
Symmetric to `Game.BoardGesture`. Hand-origin actions ship
pathless (replay re-synthesizes via DOM), so `HandAction`
carries no envelope.

The shared small helpers are duplicated per-side rather than
shared via Maybe-flagged helpers.

-}

import Game.CardStack as CardStack exposing (BoardLocation)
import Game.Drag exposing (DragState(..))
import Game.HandDrag exposing (HandCardDragInfo)
import Game.Physics.BoardGeometry as BG
import Game.Physics.GestureArbitration as GA
import Game.WingView as WingView
import Game.WireAction as WA exposing (WireAction)
import Main.Apply as Apply
import Main.Msg exposing (Msg)
import Main.State as State
    exposing
        ( Model
        , StatusKind(..)
        )
import Main.Types exposing (PathFrame(..), Point)
import Main.Wire as Wire


type HandOutcome
    = HandAction WireAction
    | HandOffBoard State.StatusMessage
    | HandNothingHappened


{-| Mouseup handler for a hand-card drag. Caller (the
dispatcher in `Main.Gesture`) has pattern-matched out the
`Info` and passes it in. Hand drags don't capture a gesture
path, so no `tMs`.
-}
handleMouseUp : Point -> HandCardDragInfo -> Model -> ( Model, Cmd Msg )
handleMouseUp releasePoint d model =
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
    applyHandOutcome (resolveHandOutcome dFull model.boardRect) model


resolveHandOutcome : HandCardDragInfo -> Maybe GA.Rect -> HandOutcome
resolveHandOutcome d maybeRect =
    case resolveHandCardGesture d maybeRect of
        Just action ->
            HandAction action

        Nothing ->
            case maybeRect of
                Just rect ->
                    let
                        floaterBoardLoc =
                            { left = d.floaterTopLeft.x - rect.x
                            , top = d.floaterTopLeft.y - rect.y
                            }
                    in
                    case droppedOffBoardScold floaterBoardLoc 1 of
                        Just scold ->
                            HandOffBoard scold

                        Nothing ->
                            HandNothingHappened

                Nothing ->
                    HandNothingHappened


applyHandOutcome : HandOutcome -> Model -> ( Model, Cmd Msg )
applyHandOutcome outcome model =
    let
        cleared =
            clearDrag model
    in
    case outcome of
        HandAction action ->
            let
                modelAfter =
                    Apply.applyAction action cleared
                        |> Apply.commit
            in
            case modelAfter.sessionId of
                Just sid ->
                    let
                        entry =
                            { action = action
                            , gesturePath = Nothing
                            , pathFrame = ViewportFrame
                            }

                        seq =
                            modelAfter.nextSeq
                    in
                    ( { modelAfter
                        | actionLog = modelAfter.actionLog ++ [ entry ]
                        , nextSeq = seq + 1
                      }
                    , Wire.sendAction sid seq action Nothing
                    )

                Nothing ->
                    ( modelAfter, Cmd.none )

        HandOffBoard scold ->
            ( { cleared | status = scold }, Cmd.none )

        HandNothingHappened ->
            ( cleared, Cmd.none )


{-| Hand-card resolution requires the live board rect for both
the wing-hover hit-test (lifting board-frame eventual landings
into viewport frame) and the drop-loc translation. With no rect
yet, no honest action is possible — return Nothing.
-}
resolveHandCardGesture : HandCardDragInfo -> Maybe GA.Rect -> Maybe WireAction
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
                        (WA.MergeHand
                            { handCard = d.card
                            , target = wing.target
                            , side = wing.side
                            }
                        )

                Nothing ->
                    if GA.isCursorInRect d.cursor rect then
                        if isDropFootprintInBounds 1 floaterBoardLoc then
                            Just (WA.PlaceHand { handCard = d.card, loc = floaterBoardLoc })

                        else
                            Nothing

                    else
                        Nothing


{-| Mousemove handler for a hand-card drag. Caller (the
dispatcher in `Main.Play`) has pattern-matched out the `Info`.
Hand drags don't capture a gesture path, so no `tMs`.
-}
mouseMove : Point -> HandCardDragInfo -> Model -> ( Model, Cmd Msg )
mouseMove pos d model =
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
            case model.boardRect of
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
                model.status
    in
    ( { model | drag = DraggingHandCard nextD, status = nextStatus }
    , Cmd.none
    )



-- PRIVATE HELPERS (small enough to duplicate from BoardGesture)


hoverStatus :
    Maybe a
    -> Maybe a
    -> State.StatusMessage
    -> State.StatusMessage
hoverStatus currentHover nextHover currentStatus =
    if nextHover /= currentHover then
        case nextHover of
            Just _ ->
                wingHoverStatus

            Nothing ->
                currentStatus

    else
        currentStatus


wingHoverStatus : State.StatusMessage
wingHoverStatus =
    { text = "Drop stack to complete merge.", kind = Inform }


isDropFootprintInBounds : Int -> BoardLocation -> Bool
isDropFootprintInBounds cardCount loc =
    let
        bounds =
            Apply.refereeBounds
    in
    (loc.left >= 0)
        && (loc.top >= 0)
        && (loc.left + BG.stackWidth cardCount <= bounds.maxWidth)
        && (loc.top + BG.cardHeight <= bounds.maxHeight)


droppedOffBoardScold : BoardLocation -> Int -> Maybe State.StatusMessage
droppedOffBoardScold loc cardCount =
    if not (isDropFootprintInBounds cardCount loc) then
        Just offBoardScold

    else
        Nothing


offBoardScold : State.StatusMessage
offBoardScold =
    { text = "Don't knock cards off the board, please. You're not a cat!"
    , kind = Scold
    }


clearDrag : Model -> Model
clearDrag model =
    { model | drag = NotDragging }
