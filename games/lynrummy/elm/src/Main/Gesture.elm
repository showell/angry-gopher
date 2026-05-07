module Main.Gesture exposing
    ( cardMouseDown
    , floaterOverWing
    , handCardAttrs
    , handleMouseUp
    , pointDecoder
    , resolveBoardCardGesture
    , resolveHandCardGesture
    , startBoardCardDrag
    , startHandDrag
    , wingHoverStatus
    )

{-| The pointer-gesture layer: everything between a physical
mousedown and the WireAction it produces.

Responsibilities:

  - **Start drag** — `startBoardCardDrag`, `startHandDrag`
    construct a `DraggingBoardCard` or `DraggingHandCard` with
    the appropriate wings oracle called and kick off a
    `fetchBoardRect` task to capture the board's viewport rect
    (when not already cached on Model).
  - **During drag** — the `Browser.Events.onMouseMove` /
    `onMouseUp` subscriptions in `Main.Play` feed `MouseMove`
    and `MouseUp` back into update; the cursor tracking is a
    one-liner inline there.
  - **End drag** — `handleMouseUp` resolves the gesture into a
    `Maybe WireAction`, clears the drag state, applies the
    action through `Main.Apply.applyAction`, appends to
    `actionLog`, and fires `Main.Wire.sendAction` for
    persistence.
  - **Styling hooks** — `handCardAttrs` / `cardMouseDown`
    produce per-card event-handler/style attributes.
  - **Decoder** — `pointDecoder` pulls `{clientX, clientY}` from
    mouse events into the `Point` record.


## Click-vs-drag arbitration

For board-card drags the resolver checks at mouseup whether
the cursor is still within `clickThreshold` of `originalCursor`
(squared distance). Within radius → emit `Split` at the captured
`cardIndex`. Outside radius → fall through to the drag dispatch
table. There is no live "click intent" flag — the question is
answered exactly once, at mouseup, as an outcome judgment.

Hand-card drags have no Split semantic; they always dispatch on
`(hoveredWing, isCursorOverBoard)`.

-}

import Browser.Dom
import Game.Drag exposing (BoardCardDragInfo, DragState(..), HandCardDragInfo)
import Game.Physics.BoardGeometry as BG
import Game.Physics.GestureArbitration as GA
import Game.Physics.WingOracle as WingOracle
import Game.Rules.Card exposing (Card)
import Game.CardStack as CardStack exposing (BoardLocation, CardStack, HandCard)
import Game.WireAction as WA exposing (WireAction)
import Html
import Html.Attributes exposing (style)
import Html.Events as Events
import Json.Decode as Decode exposing (Decoder)
import Main.Apply as Apply
import Main.Msg exposing (Msg(..))
import Main.State as State
    exposing
        ( Model
        , StatusKind(..)
        , activeHand
        , boardDomIdFor
        )
import Main.Types exposing (GesturePoint, PathFrame(..), Point)
import Main.Wire as Wire
import Task



-- DRAG START


{-| Start a drag from a board card. The floater's initial
top-left is `stack.loc` (board frame, no translation).
`cardIndex` is captured for the eventual click-vs-drag
arbitration at mouseup.
-}
startBoardCardDrag :
    { stack : CardStack, cardIndex : Int }
    -> Point
    -> Float
    -> Model
    -> ( Model, Cmd Msg )
startBoardCardDrag { stack, cardIndex } clientPoint tMs model =
    case model.drag of
        NotDragging ->
            let
                wings =
                    WingOracle.wingsForStack stack model.board

                -- Intra-board: the floater starts exactly
                -- where the stack is. `stack.loc` is already
                -- in board frame, so no translation needed.
                initialFloater =
                    { x = stack.loc.left, y = stack.loc.top }
            in
            ( { model
                | drag =
                    DraggingBoardCard
                        { stack = stack
                        , cardIndex = cardIndex
                        , originalCursor = clientPoint
                        , cursor = clientPoint
                        , floaterTopLeft = initialFloater
                        , gesturePath =
                            [ { tMs = tMs, x = initialFloater.x, y = initialFloater.y } ]
                        , wings = wings
                        }
              }
            , fetchBoardRect model.gameId
            )

        _ ->
            ( model, Cmd.none )


{-| Start a drag from a hand card. The `tMs` mousedown timestamp
is unused — hand drags don't capture a gesture path (replay
re-synthesizes via DOM measurement).
-}
startHandDrag : Card -> Point -> Float -> Model -> ( Model, Cmd Msg )
startHandDrag card clientPoint _ model =
    case ( model.drag, findHandCard card (activeHand model).handCards ) of
        ( NotDragging, Just handCard ) ->
            let
                wings =
                    WingOracle.wingsForHandCard handCard model.board

                -- Hand-origin: the floater is rendered as a
                -- viewport overlay. We don't know the hand
                -- card's exact viewport rect without a DOM
                -- measurement, so we approximate the initial
                -- floater as "a bit above-and-left of the
                -- cursor" — clientPoint minus a local
                -- half-pitch / 20-px offset. Not stored
                -- anywhere; used only to seed `floaterTopLeft`.
                initialFloater =
                    { x = clientPoint.x - CardStack.stackPitch // 2
                    , y = clientPoint.y - 20
                    }
            in
            ( { model
                | drag =
                    DraggingHandCard
                        { card = card
                        , cursor = clientPoint
                        , floaterTopLeft = initialFloater
                        , wings = wings
                        }
              }
            , fetchBoardRect model.gameId
            )

        _ ->
            ( model, Cmd.none )


findHandCard : Card -> List HandCard -> Maybe HandCard
findHandCard target cards =
    List.filter (\hc -> hc.card == target) cards |> List.head


{-| Fire a `Browser.Dom.getElement` Task to capture the board's
viewport rectangle. Needed by `isCursorOverBoard` and by hand-
origin drags to translate viewport-frame floaters into board
frame; intra-board drags don't strictly need it, but the fetch
is harmless. The rect arrives via `BoardRectReceived`.
-}
fetchBoardRect : String -> Cmd Msg
fetchBoardRect gameId =
    Browser.Dom.getElement (boardDomIdFor gameId)
        |> Task.attempt BoardRectReceived



-- DRAG END


{-| Handle MouseUp. Resolves the drag into a `Maybe WireAction`,
clears the drag state, applies the action through
`Main.Apply.applyAction`, appends to actionLog, and fires
`sendAction` for persistence. If no sessionId is set (offline
mode) the persistence step is skipped.
-}
handleMouseUp : Point -> Float -> Model -> ( Model, Cmd Msg )
handleMouseUp releasePoint tMs model =
    case model.drag of
        NotDragging ->
            ( model, Cmd.none )

        DraggingBoardCard d ->
            let
                delta =
                    { x = releasePoint.x - d.cursor.x
                    , y = releasePoint.y - d.cursor.y
                    }

                releaseFloater =
                    { x = d.floaterTopLeft.x + delta.x
                    , y = d.floaterTopLeft.y + delta.y
                    }

                fullPath =
                    d.gesturePath
                        ++ [ { tMs = tMs, x = releaseFloater.x, y = releaseFloater.y } ]

                dFull =
                    { d
                        | cursor = releasePoint
                        , floaterTopLeft = releaseFloater
                        , gesturePath = fullPath
                    }

                maybeAction =
                    resolveBoardCardGesture dFull model.boardRect

                envelope =
                    case maybeAction of
                        Just action ->
                            gestureForAction action fullPath BoardFrame

                        Nothing ->
                            Nothing
            in
            finalizeMouseUp
                maybeAction
                envelope
                (droppedOffBoardScold
                    { left = dFull.floaterTopLeft.x, top = dFull.floaterTopLeft.y }
                    (CardStack.size dFull.stack)
                )
                model

        DraggingHandCard d ->
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

                maybeAction =
                    resolveHandCardGesture dFull model.boardRect

                handScold =
                    case model.boardRect of
                        Just rect ->
                            droppedOffBoardScold
                                { left = dFull.floaterTopLeft.x - rect.x
                                , top = dFull.floaterTopLeft.y - rect.y
                                }
                                1

                        Nothing ->
                            Nothing
            in
            -- Hand-origin actions ship pathless (replay
            -- re-synthesizes via DOM), so envelope is always
            -- Nothing here regardless of the action.
            finalizeMouseUp maybeAction Nothing handScold model


finalizeMouseUp :
    Maybe WireAction
    -> Maybe State.EnvelopeForGesture
    -> Maybe State.StatusMessage
    -> Model
    -> ( Model, Cmd Msg )
finalizeMouseUp maybeAction maybeGesture maybeOffBoardScold model =
    let
        modelAfterDragClear =
            clearDrag model

        modelAfterAction =
            case maybeAction of
                Just action ->
                    Apply.applyAction action modelAfterDragClear
                        |> Apply.commit

                Nothing ->
                    case maybeOffBoardScold of
                        Just status ->
                            { modelAfterDragClear | status = status }

                        Nothing ->
                            modelAfterDragClear
    in
    case ( maybeAction, modelAfterAction.sessionId ) of
        ( Just action, Just sid ) ->
            let
                entry =
                    { action = action
                    , gesturePath = Maybe.map .path maybeGesture
                    , pathFrame =
                        Maybe.map .frame maybeGesture
                            |> Maybe.withDefault ViewportFrame
                    }

                seq =
                    modelAfterAction.nextSeq
            in
            ( { modelAfterAction
                | actionLog = modelAfterAction.actionLog ++ [ entry ]
                , nextSeq = seq + 1
              }
            , Wire.sendAction sid seq action maybeGesture
            )

        _ ->
            ( modelAfterAction, Cmd.none )


{-| Decide what gesture (if any) ships with this action.

Intra-board drags (`Split`, `MergeStack`, `MoveStack`) ship
the captured path as-is with its native frame tag — the
capture layer already stores it in the right frame.
Hand-origin drags (`MergeHand`, `PlaceHand`) ship pathless;
the receiver re-synthesizes at replay time via live DOM
measurement. `CompleteTurn` and `Undo` aren't drags.

-}
gestureForAction :
    WireAction
    -> List GesturePoint
    -> PathFrame
    -> Maybe State.EnvelopeForGesture
gestureForAction action path pathFrame =
    case action of
        WA.MergeHand _ ->
            Nothing

        WA.PlaceHand _ ->
            Nothing

        WA.Split _ ->
            Just { path = path, frame = pathFrame }

        WA.MergeStack _ ->
            Just { path = path, frame = pathFrame }

        WA.MoveStack _ ->
            Just { path = path, frame = pathFrame }

        WA.CompleteTurn ->
            Nothing

        WA.Undo ->
            Nothing


{-| Resolve a completed board-card drag into the WireAction (if
any) it should produce. Click-vs-drag check: if the cursor is
still within `clickThreshold` of `originalCursor`, emit a
`Split` at the captured `cardIndex`. Otherwise dispatch on
`(hoveredWing, isCursorOverBoard)`.

Board-card floaters live in board frame, so `boardOrigin` is the
zero point — the floater coordinates need no lift.
-}
resolveBoardCardGesture : BoardCardDragInfo -> Maybe GA.Rect -> Maybe WireAction
resolveBoardCardGesture d boardRect =
    if GA.distSquared d.cursor d.originalCursor <= GA.clickThreshold then
        Just (WA.Split { stack = d.stack, cardIndex = d.cardIndex })

    else
        let
            hovered =
                floaterOverWing d.floaterTopLeft (CardStack.stackDisplayWidth d.stack) d.wings
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
                    let
                        loc =
                            { left = d.floaterTopLeft.x, top = d.floaterTopLeft.y }
                    in
                    if isDropFootprintInBounds (CardStack.size d.stack) loc then
                        Just (WA.MoveStack { stack = d.stack, newLoc = loc })

                    else
                        Nothing

                else
                    Nothing


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
                floaterInBoard =
                    { x = d.floaterTopLeft.x - rect.x
                    , y = d.floaterTopLeft.y - rect.y
                    }

                hovered =
                    floaterOverWing floaterInBoard CardStack.stackPitch d.wings
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
                        let
                            loc =
                                { left = floaterInBoard.x, top = floaterInBoard.y }
                        in
                        if isDropFootprintInBounds 1 loc then
                            Just (WA.PlaceHand { handCard = d.card, loc = loc })

                        else
                            Nothing

                    else
                        Nothing


isCursorOverBoard : Point -> Maybe GA.Rect -> Bool
isCursorOverBoard cursor maybeRect =
    case maybeRect of
        Just rect ->
            GA.isCursorInRect cursor rect

        Nothing ->
            False


-- LEAF HELPERS — narrow inputs, frame-agnostic.
--
-- The board / hand split lives at the resolver level, not down
-- here. These helpers take coordinates and the per-frame
-- `boardOrigin` knob: `{ x = 0, y = 0 }` for board-frame floaters,
-- the live board rect's `{ x, y }` for viewport-frame floaters.


{-| Half a card-pitch of slop in each axis around the eventual
landing. Tight enough that the floater must be visually
adjacent to the target; loose enough to tolerate normal mouse
wiggle.
-}
wingSnapTolerance : Int
wingSnapTolerance =
    CardStack.stackPitch // 2


{-| True iff `floaterTopLeft` is within `wingSnapTolerance` of
`wing`'s eventual landing. Both points must already be in
board frame — callers in viewport frame translate before
calling.
-}
isNearLanding : Point -> Int -> WingOracle.WingId -> Bool
isNearLanding floaterTopLeft floaterWidth wing =
    let
        ev =
            WingOracle.eventualFloaterTopLeft wing floaterWidth

        dx =
            abs (floaterTopLeft.x - ev.left)

        dy =
            abs (floaterTopLeft.y - ev.top)
    in
    dx < wingSnapTolerance && dy < wingSnapTolerance


{-| Which wing (if any) the floater is about to land on.
`floaterTopLeft` must be in board frame.
-}
floaterOverWing :
    Point
    -> Int
    -> List WingOracle.WingId
    -> Maybe WingOracle.WingId
floaterOverWing floaterTopLeft floaterWidth wings =
    wings
        |> List.filter (isNearLanding floaterTopLeft floaterWidth)
        |> List.head


{-| True iff a stack of `cardCount` cards placed at `loc` fits
entirely within the board's bounds.
-}
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


{-| Status message to show while hovering a wing (a drop here
would fire a merge).
-}
wingHoverStatus : State.StatusMessage
wingHoverStatus =
    { text = "Drop stack to complete merge.", kind = Inform }


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



-- DECODERS


pointDecoder : Decoder Point
pointDecoder =
    Decode.map2 (\x y -> { x = round x, y = round y })
        (Decode.field "clientX" Decode.float)
        (Decode.field "clientY" Decode.float)


{-| Decoder for mousedown / mouseup events that also captures the
`MouseEvent.timeStamp`.
-}
pointAndTimeDecoder : Decoder ( Point, Float )
pointAndTimeDecoder =
    Decode.map2 Tuple.pair
        pointDecoder
        (Decode.field "timeStamp" Decode.float)



-- VIEW-SIDE STYLING HOOKS


{-| Mousedown handler for a board card. Emits
`MouseDownOnBoardCard` carrying the CardStack the card lives in
and the card's position within that stack.
-}
cardMouseDown : CardStack -> Int -> List (Html.Attribute Msg)
cardMouseDown stack cardIdx =
    [ Events.on "mousedown"
        (Decode.map
            (\( p, t ) ->
                MouseDownOnBoardCard { stack = stack, cardIndex = cardIdx, point = p, time = t }
            )
            pointAndTimeDecoder
        )
    ]


{-| Per-hand-card attribute list. Three responsibilities:

1.  **Hint highlight** — if this card's identity is in
    `hintedCards`, paint it light green.
2.  **Mousedown hook** — when not dragging, attach
    `MouseDownOnHandCard`.
3.  **Drag dim** — while dragging, dim the source card and
    disable pointer events everywhere (so the floater is the
    only visible / interactive piece).

-}
handCardAttrs : DragState -> List Card -> HandCard -> List (Html.Attribute Msg)
handCardAttrs drag hintedCards hc =
    let
        hintAttrs =
            if List.any (\c -> c == hc.card) hintedCards then
                [ style "background-color" "lightgreen" ]

            else
                []
    in
    hintAttrs
        ++ (case drag of
                NotDragging ->
                    [ Events.on "mousedown"
                        (Decode.map
                            (\( p, t ) -> MouseDownOnHandCard { card = hc.card, point = p, time = t })
                            pointAndTimeDecoder
                        )
                    ]

                DraggingHandCard d ->
                    if d.card == hc.card then
                        [ style "opacity" "0.35", style "pointer-events" "none" ]

                    else
                        [ style "pointer-events" "none" ]

                DraggingBoardCard _ ->
                    [ style "pointer-events" "none" ]
           )
