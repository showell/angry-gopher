module Main.Gesture exposing
    ( cardMouseDown
    , clearDrag
    , fetchBoardRect
    , handCardAttrs
    , handleMouseUp
    , pointDecoder
    , startBoardCardDrag
    , startHandDrag
    )

{-| The pointer-gesture layer: everything between a physical
mousedown and the WireAction it produces.

Responsibilities:

  - **Start drag** — `startBoardCardDrag`, `startHandDrag`
    set up a `DragInfo` with the right wings oracle called
    (stack vs hand source) and kick off a `fetchBoardRect`
    task to capture the board's viewport rect.
  - **During drag** — the `Browser.Events.onMouseMove` /
    `onMouseUp` subscriptions in `Main.elm` feed `MouseMove`
    and `MouseUp` back into update; the cursor tracking is a
    one-liner inline there. Wing hover updates are also inline.
  - **End drag** — `handleMouseUp` resolves the gesture into
    a `Maybe WireAction` via `resolveGesture`, clears the drag
    state, applies the action through `Main.Apply.applyWireAction`,
    appends to `actionLog`, and fires `Main.Wire.sendAction` for
    persistence.
  - **Styling hooks** — `handCardAttrs` produces the per-hand-card
    `Html.Attribute` list (mousedown handler + drag-dim opacity
    + hint-green background); `cardMouseDown` produces a
    board-card mousedown handler.
  - **Decoder** — `pointDecoder` pulls `{clientX, clientY}` from
    mouse events into the `Point` record.

Extracted 2026-04-19 from the pre-split `Main.elm` monolith.

## Click-vs-drag precedence

`resolveGesture` checks `clickIntent` first. A drag that starts
on a board card AND hasn't moved beyond the click threshold
(tracked elsewhere via `GestureArbitration.clickIntentAfterMove`)
yields a `Split` action. Only if the click intent has been
killed do we dispatch on `(hoveredWing, source, cursorOverBoard)`
for merge / place / move.

## WireAction production — branch table

| clickIntent | source | hoveredWing | cursorOverBoard | Result |
|---|---|---|---|---|
| Just cardIdx | FromBoardStack idx | — | — | `Split { stackIndex, cardIndex }` |
| Nothing | FromBoardStack idx | Just wing | — | `MergeStack { source=idx, target=wing.stackIndex, side }` |
| Nothing | FromHandCard idx | Just wing | — | `MergeHand { handCard, target=wing.stackIndex, side }` |
| Nothing | FromHandCard idx | Nothing | True (loc present) | `PlaceHand { handCard, loc }` |
| Nothing | FromBoardStack idx | Nothing | True (loc present) | `MoveStack { stackIndex, newLoc=loc }` |
| any | any | any | drop too early / no rect | `Nothing` (gesture discarded) |

-}

import Browser.Dom
import Browser.Events
import Html
import Html.Attributes exposing (style)
import Html.Events as Events
import Json.Decode as Decode exposing (Decoder)
import LynRummy.Card exposing (Card)
import LynRummy.CardStack as CardStack exposing (BoardLocation, HandCard)
import LynRummy.GestureArbitration as GA
import LynRummy.Hand exposing (Hand)
import LynRummy.WingOracle as WingOracle
import LynRummy.WireAction as WA exposing (WireAction)
import Main.Apply as Apply
import Main.Msg exposing (Msg(..))
import Main.State as State
    exposing
        ( DragInfo
        , DragSource(..)
        , DragState(..)
        , Model
        , Point
        , activeHand
        , boardDomId
        )
import Main.Wire as Wire
import Task



-- DRAG START


{-| Start a drag from a board card. Captures the half-width of
the stack for grab offset so the drag floater centres correctly
under the cursor. `clickIntent = Just cardIndex` marks this as
a *potential* split click; `GestureArbitration.clickIntentAfterMove`
(called on subsequent MouseMove) kills the intent if the cursor
moves beyond the click threshold.
-}
startBoardCardDrag :
    { stackIndex : Int, cardIndex : Int }
    -> Point
    -> Model
    -> ( Model, Cmd Msg )
startBoardCardDrag { stackIndex, cardIndex } clientPoint model =
    case ( model.drag, listAt stackIndex model.board ) of
        ( NotDragging, Just stack ) ->
            let
                wings =
                    WingOracle.wingsForStack stackIndex model.board

                halfWidth =
                    CardStack.stackDisplayWidth stack // 2
            in
            ( { model
                | drag =
                    Dragging
                        { source = FromBoardStack stackIndex
                        , cursor = clientPoint
                        , originalCursor = clientPoint
                        , grabOffset = { x = halfWidth, y = 20 }
                        , wings = wings
                        , hoveredWing = Nothing
                        , boardRect = Nothing
                        , clickIntent = Just cardIndex
                        , gesturePath = []
                        }
              }
            , fetchBoardRect
            )

        _ ->
            ( model, Cmd.none )


{-| Start a drag from a hand card. No click intent — hand cards
don't have a split semantic.
-}
startHandDrag : Int -> Point -> Model -> ( Model, Cmd Msg )
startHandDrag idx clientPoint model =
    case ( model.drag, listAt idx (activeHand model).handCards ) of
        ( NotDragging, Just handCard ) ->
            let
                wings =
                    WingOracle.wingsForHandCard handCard model.board

                halfWidth =
                    CardStack.stackPitch // 2
            in
            ( { model
                | drag =
                    Dragging
                        { source = FromHandCard idx
                        , cursor = clientPoint
                        , originalCursor = clientPoint
                        , grabOffset = { x = halfWidth, y = 20 }
                        , wings = wings
                        , hoveredWing = Nothing
                        , boardRect = Nothing
                        , clickIntent = Nothing
                        , gesturePath = []
                        }
              }
            , fetchBoardRect
            )

        _ ->
            ( model, Cmd.none )


{-| Fire a `Browser.Dom.getElement` Task to capture the board's
viewport rectangle. The result arrives via `BoardRectReceived`;
until then, `DragInfo.boardRect` is `Nothing` and `dropLoc`
returns `Nothing` — callers that need the loc have to wait.
Race with drag duration is benign in practice (task resolves in
a tick).
-}
fetchBoardRect : Cmd Msg
fetchBoardRect =
    Browser.Dom.getElement boardDomId
        |> Task.attempt BoardRectReceived



-- DRAG END


{-| Handle MouseUp. Extracts the WireAction (if any) from the
current drag, clears the drag state, applies the action through
`Main.Apply.applyWireAction` (the single source-agnostic update
path), appends to actionLog, and fires `sendAction` for
persistence. If no sessionId is set (offline mode) the
persistence step is skipped.
-}
handleMouseUp : Model -> ( Model, Cmd Msg )
handleMouseUp model =
    case model.drag of
        NotDragging ->
            ( model, Cmd.none )

        Dragging info ->
            let
                maybeAction =
                    resolveGesture info model

                modelAfterDragClear =
                    clearDrag model

                modelAfterAction =
                    case maybeAction of
                        Just action ->
                            Apply.applyWireAction action modelAfterDragClear

                        Nothing ->
                            modelAfterDragClear

                gesturePathForLog =
                    case info.gesturePath of
                        [] ->
                            Nothing

                        path ->
                            Just path

                ( finalModel, cmd ) =
                    case ( maybeAction, modelAfterAction.sessionId ) of
                        ( Just action, Just sid ) ->
                            ( { modelAfterAction
                                | actionLog = modelAfterAction.actionLog ++ [ action ]
                                , replayGestures =
                                    modelAfterAction.replayGestures ++ [ gesturePathForLog ]
                              }
                            , Wire.sendAction sid action (Just info.gesturePath)
                            )

                        _ ->
                            ( modelAfterAction, Cmd.none )
            in
            ( finalModel, cmd )


{-| Resolve a completed drag gesture into the WireAction (if
any) it produces. Pure — no state mutation. The actual model
update flows through `Main.Apply.applyWireAction`, same path as
replay and (eventually) wire-received actions.

Click precedence over drag mirrors the TS engine's
`process_pointerup` logic: if `clickIntent` survived, it's a
split; otherwise dispatch on `(hoveredWing, source,
cursorOverBoard)`.
-}
resolveGesture : DragInfo -> Model -> Maybe WireAction
resolveGesture info model =
    case ( info.clickIntent, info.source ) of
        ( Just cardIdx, FromBoardStack stackIdx ) ->
            Just (WA.Split { stackIndex = stackIdx, cardIndex = cardIdx })

        _ ->
            case ( info.hoveredWing, info.source ) of
                ( Just wing, FromBoardStack sourceIdx ) ->
                    Just
                        (WA.MergeStack
                            { sourceStack = sourceIdx
                            , targetStack = wing.stackIndex
                            , side = wing.side
                            }
                        )

                ( Just wing, FromHandCard handIdx ) ->
                    case listAt handIdx (activeHand model).handCards of
                        Just handCard ->
                            Just
                                (WA.MergeHand
                                    { handCard = handCard.card
                                    , targetStack = wing.stackIndex
                                    , side = wing.side
                                    }
                                )

                        Nothing ->
                            Nothing

                ( Nothing, FromHandCard handIdx ) ->
                    if cursorOverBoard info then
                        case ( listAt handIdx (activeHand model).handCards, dropLoc info ) of
                            ( Just handCard, Just loc ) ->
                                Just (WA.PlaceHand { handCard = handCard.card, loc = loc })

                            _ ->
                                Nothing

                    else
                        Nothing

                ( Nothing, FromBoardStack stackIdx ) ->
                    if cursorOverBoard info then
                        case dropLoc info of
                            Just loc ->
                                Just (WA.MoveStack { stackIndex = stackIdx, newLoc = loc })

                            Nothing ->
                                Nothing

                    else
                        Nothing


cursorOverBoard : DragInfo -> Bool
cursorOverBoard info =
    case info.boardRect of
        Just rect ->
            GA.cursorInRect info.cursor rect

        Nothing ->
            False


{-| Board-relative drop location derived from cursor + grab
offset + board rect. `Nothing` if the board rect hasn't
arrived yet (race between drag-start and
`Browser.Dom.getElement` completing).
-}
dropLoc : DragInfo -> Maybe BoardLocation
dropLoc info =
    info.boardRect
        |> Maybe.map
            (\rect ->
                { left = info.cursor.x - info.grabOffset.x - rect.x
                , top = info.cursor.y - info.grabOffset.y - rect.y
                }
            )


clearDrag : Model -> Model
clearDrag model =
    { model | drag = NotDragging }



-- DECODERS


pointDecoder : Decoder Point
pointDecoder =
    Decode.map2 (\x y -> { x = round x, y = round y })
        (Decode.field "clientX" Decode.float)
        (Decode.field "clientY" Decode.float)



-- VIEW-SIDE STYLING HOOKS


{-| Mousedown handler for a board card. Emits
`MouseDownOnBoardCard` with the clicked stack + card index,
which flows into update → `startBoardCardDrag`.
-}
cardMouseDown : Int -> Int -> List (Html.Attribute Msg)
cardMouseDown stackIdx cardIdx =
    [ Events.on "mousedown"
        (Decode.map
            (MouseDownOnBoardCard { stackIndex = stackIdx, cardIndex = cardIdx })
            pointDecoder
        )
    ]


{-| Per-hand-card attribute list. Three responsibilities:

1.  **Hint highlight** — if this card's identity is in
    `hintedCards`, paint it light green (nudges the player
    toward the top Hint suggestion).
2.  **Mousedown hook** — when not dragging, attach the
    `MouseDownOnHandCard idx` event.
3.  **Drag dim** — while dragging, dim the source card and
    disable pointer events everywhere (so the floater is the
    only visible / interactive piece).

-}
handCardAttrs : DragState -> List Card -> Int -> HandCard -> List (Html.Attribute Msg)
handCardAttrs drag hintedCards idx hc =
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
                    [ Events.on "mousedown" (Decode.map (MouseDownOnHandCard idx) pointDecoder) ]

                Dragging info ->
                    case info.source of
                        FromHandCard sourceIdx ->
                            if sourceIdx == idx then
                                -- Dim the source card while dragging its floating copy.
                                [ style "opacity" "0.35", style "pointer-events" "none" ]

                            else
                                [ style "pointer-events" "none" ]

                        FromBoardStack _ ->
                            [ style "pointer-events" "none" ]
           )



-- INTERNAL


listAt : Int -> List a -> Maybe a
listAt i xs =
    List.head (List.drop i xs)
