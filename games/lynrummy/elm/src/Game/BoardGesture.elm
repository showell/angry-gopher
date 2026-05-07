module Game.BoardGesture exposing
    ( BoardOutcome(..)
    , applyBoardOutcome
    , handleMouseUp
    , mouseMove
    , resolveBoardCardGesture
    , resolveBoardOutcome
    )

{-| Per-side resolution and application for board-card drags.

Lifted out of `Main.Gesture` so the board ladder lives in one
file alongside its sibling `Game.HandGesture`. The shared
small helpers (`isDropFootprintInBounds`,
`droppedOffBoardScold`, `offBoardScold`, `clearDrag`) are
duplicated per-side rather than shared via Maybe-flagged
helpers.

-}

import Game.BoardDrag exposing (BoardCardDragInfo)
import Game.CardStack as CardStack exposing (BoardLocation)
import Game.Drag exposing (DragState(..))
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


type BoardOutcome
    = BoardAction WireAction State.EnvelopeForGesture
    | BoardOffBoard State.StatusMessage
    | BoardNothingHappened


{-| Mouseup handler for a board-card drag. Caller (the
dispatcher in `Main.Gesture`) has pattern-matched out the
`Info` and passes it in. Builds the final `Info` (with the
release point folded in), resolves the outcome, applies it.
-}
handleMouseUp : Point -> Float -> BoardCardDragInfo -> Model -> ( Model, Cmd Msg )
handleMouseUp releasePoint tMs d model =
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
                , gesturePath =
                    d.gesturePath
                        ++ [ { tMs = tMs, x = releaseFloater.left, y = releaseFloater.top } ]
            }
    in
    applyBoardOutcome (resolveBoardOutcome dFull model.boardRect) model


resolveBoardOutcome : BoardCardDragInfo -> Maybe GA.Rect -> BoardOutcome
resolveBoardOutcome d boardRect =
    case resolveBoardCardGesture d boardRect of
        Just action ->
            BoardAction action
                { path = d.gesturePath, frame = BoardFrame }

        Nothing ->
            case droppedOffBoardScold d.floaterTopLeft (CardStack.size d.stack) of
                Just scold ->
                    BoardOffBoard scold

                Nothing ->
                    BoardNothingHappened


applyBoardOutcome : BoardOutcome -> Model -> ( Model, Cmd Msg )
applyBoardOutcome outcome model =
    let
        cleared =
            clearDrag model
    in
    case outcome of
        BoardAction action envelope ->
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
                            , gesturePath = Just envelope.path
                            , pathFrame = envelope.frame
                            }

                        seq =
                            modelAfter.nextSeq
                    in
                    ( { modelAfter
                        | actionLog = modelAfter.actionLog ++ [ entry ]
                        , nextSeq = seq + 1
                      }
                    , Wire.sendAction sid seq action (Just envelope)
                    )

                Nothing ->
                    ( modelAfter, Cmd.none )

        BoardOffBoard scold ->
            ( { cleared | status = scold }, Cmd.none )

        BoardNothingHappened ->
            ( cleared, Cmd.none )


{-| Resolve a completed board-card drag into the WireAction (if
any) it should produce. Click-vs-drag check: if the cursor is
still within `clickThreshold` of `originalCursor`, emit a
`Split` at the captured `cardIndex`.
-}
resolveBoardCardGesture : BoardCardDragInfo -> Maybe GA.Rect -> Maybe WireAction
resolveBoardCardGesture d boardRect =
    if GA.distSquared d.cursor d.originalCursor <= GA.clickThreshold then
        Just (WA.Split { stack = d.stack, cardIndex = d.cardIndex })

    else
        let
            hovered =
                WingView.hoveredWing d.floaterTopLeft (CardStack.stackDisplayWidth d.stack) d.wings
        in
        case hovered of
            Just wing ->
                Just
                    (WA.MergeStack
                        { source = d.stack
                        , target = wing.target
                        , side = wing.side
                        }
                    )

            Nothing ->
                if isCursorOverBoard d.cursor boardRect then
                    if isDropFootprintInBounds (CardStack.size d.stack) d.floaterTopLeft then
                        Just (WA.MoveStack { stack = d.stack, newLoc = d.floaterTopLeft })

                    else
                        Nothing

                else
                    Nothing


{-| Mousemove handler for a board-card drag. Caller (the
dispatcher in `Main.Play`) has pattern-matched out the `Info`.
Advances cursor + floater + gesture path, recomputes hover
status, returns the patched Model.
-}
mouseMove : Point -> Float -> BoardCardDragInfo -> Model -> ( Model, Cmd Msg )
mouseMove pos tMs d model =
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
            d.gesturePath
                ++ [ { tMs = tMs, x = nextFloater.left, y = nextFloater.top } ]

        nextD =
            { d
                | cursor = pos
                , floaterTopLeft = nextFloater
                , gesturePath = nextPath
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
                model.status
    in
    ( { model | drag = DraggingBoardCard nextD, status = nextStatus }
    , Cmd.none
    )



-- PRIVATE HELPERS (small enough to duplicate in HandGesture)


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
