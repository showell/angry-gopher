module Main.Gesture exposing
    ( cardMouseDown
    , clearDrag
    , fetchBoardRect
    , floaterOverWing
    , handCardAttrs
    , handleMouseUp
    , pointDecoder
    , resolveGesture
    , startBoardCardDrag
    , startHandDrag
    , wingHoverStatus
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
    state, applies the action through `Main.Apply.applyAction`,
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
import Game.BoardGeometry as BG
import Game.Card exposing (Card)
import Game.CardStack as CardStack exposing (BoardLocation, CardStack, HandCard)
import Game.GestureArbitration as GA
import Game.Hand exposing (Hand)
import Game.WingOracle as WingOracle
import Game.WireAction as WA exposing (WireAction)
import Main.Apply as Apply
import Main.Msg exposing (Msg(..))
import Main.State as State
    exposing
        ( DragInfo
        , DragSource(..)
        , DragState(..)
        , Model
        , PathFrame(..)
        , Point
        , StatusKind(..)
        , activeHand
        , boardDomIdFor
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

                halfWidth =
                    CardStack.stackDisplayWidth stack // 2
            in
            ( { model
                | drag =
                    Dragging
                        { source = FromBoardStack stack
                        , cursor = clientPoint
                        , originalCursor = clientPoint
                        , grabOffset = { x = halfWidth, y = 20 }
                        , wings = wings
                        , hoveredWing = Nothing
                        , boardRect = Nothing
                        , clickIntent = Just cardIndex
                        , gesturePath =
                            [ { tMs = tMs, x = clientPoint.x, y = clientPoint.y } ]
                        , pathFrame = ViewportFrame
                        }
              }
            , fetchBoardRect model.gameId
            )

        Dragging _ ->
            ( model, Cmd.none )


{-| Start a drag from a hand card. No click intent — hand cards
don't have a split semantic.
-}
startHandDrag : Card -> Point -> Float -> Model -> ( Model, Cmd Msg )
startHandDrag card clientPoint tMs model =
    case ( model.drag, findHandCard card (activeHand model).handCards ) of
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
                        { source = FromHandCard card
                        , cursor = clientPoint
                        , originalCursor = clientPoint
                        , grabOffset = { x = halfWidth, y = 20 }
                        , wings = wings
                        , hoveredWing = Nothing
                        , boardRect = Nothing
                        , clickIntent = Nothing
                        , gesturePath =
                            [ { tMs = tMs, x = clientPoint.x, y = clientPoint.y } ]
                        , pathFrame = ViewportFrame
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
viewport rectangle. The result arrives via `BoardRectReceived`;
until then, `DragInfo.boardRect` is `Nothing` and `dropLoc`
returns `Nothing` — callers that need the loc have to wait.
Race with drag duration is benign in practice (task resolves in
a tick).
-}
fetchBoardRect : String -> Cmd Msg
fetchBoardRect gameId =
    Browser.Dom.getElement (boardDomIdFor gameId)
        |> Task.attempt BoardRectReceived



-- DRAG END


{-| Handle MouseUp. Extracts the WireAction (if any) from the
current drag, clears the drag state, applies the action through
`Main.Apply.applyAction` (the single source-agnostic update
path), appends to actionLog, and fires `sendAction` for
persistence. If no sessionId is set (offline mode) the
persistence step is skipped.
-}
handleMouseUp : Point -> Float -> Model -> ( Model, Cmd Msg )
handleMouseUp releasePoint tMs model =
    case model.drag of
        NotDragging ->
            ( model, Cmd.none )

        Dragging info ->
            let
                _ =
                    Debug.log "[mouseup]"
                        { source = info.source
                        , hoveredWing = info.hoveredWing
                        , clickIntent = info.clickIntent
                        , cursor = info.cursor
                        }
            in
            let
                -- Append the mouseup point so the gesture path
                -- captures the full gesture including the release.
                -- For a pure click (no MouseMove), this is the
                -- second sample after the mousedown seed — so
                -- even clicks carry two-point telemetry.
                fullPath =
                    info.gesturePath
                        ++ [ { tMs = tMs, x = releasePoint.x, y = releasePoint.y } ]

                infoFull =
                    { info | gesturePath = fullPath }

                maybeAction =
                    resolveGesture infoFull model

                modelAfterDragClear =
                    clearDrag model

                modelAfterAction =
                    case maybeAction of
                        Just action ->
                            Apply.applyAction action modelAfterDragClear
                                |> Apply.commit

                        Nothing ->
                            case droppedOffBoardScold infoFull of
                                Just status ->
                                    { modelAfterDragClear | status = status }

                                Nothing ->
                                    modelAfterDragClear

                maybeGesture =
                    case maybeAction of
                        Just action ->
                            gestureForAction action info.boardRect fullPath

                        Nothing ->
                            Nothing

                ( finalModel, cmd ) =
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
                            in
                            ( { modelAfterAction | actionLog = modelAfterAction.actionLog ++ [ entry ] }
                            , Wire.sendAction sid action maybeGesture
                            )

                        _ ->
                            ( modelAfterAction, Cmd.none )
            in
            ( finalModel, cmd )


{-| Decide what gesture (if any) ships alongside this action,
and in what frame.

Hand-origin actions (`MergeHand`, `PlaceHand`) ALWAYS ship
pathless — Elm's replay resolves hand origins via live DOM
measurement regardless of sender, so a captured viewport-frame
path would be dead weight (and stale after any window resize
anyway). This matches Python's behavior.

Intra-board actions (`Split`, `MergeStack`, `MoveStack`) ship a
board-frame path: subtract the live board rect's viewport
offset from each viewport-captured sample, producing coords
that are invariant under any future viewport/DPR/monitor
change. The board's internal geometry is fixed (800×600); only
its position in the viewport can drift, and that's exactly what
the rect subtraction absorbs.

If the board rect hasn't arrived yet (a `fetchBoardRect` race
that effectively can't happen in practice — the Task resolves
in one frame and real drags span many), fall back to viewport
frame untranslated. Server still accepts; replay will read the
frame tag and render accordingly.
-}
gestureForAction :
    WireAction
    -> Maybe GA.Rect
    -> List State.GesturePoint
    -> Maybe { path : List State.GesturePoint, frame : PathFrame }
gestureForAction action maybeBoardRect path =
    case action of
        WA.MergeHand _ ->
            Nothing

        WA.PlaceHand _ ->
            Nothing

        WA.Split _ ->
            Just (intraBoardGesture maybeBoardRect path)

        WA.MergeStack _ ->
            Just (intraBoardGesture maybeBoardRect path)

        WA.MoveStack _ ->
            Just (intraBoardGesture maybeBoardRect path)

        WA.CompleteTurn ->
            Nothing

        WA.Undo ->
            Nothing


intraBoardGesture :
    Maybe GA.Rect
    -> List State.GesturePoint
    -> { path : List State.GesturePoint, frame : PathFrame }
intraBoardGesture maybeBoardRect path =
    case maybeBoardRect of
        Just rect ->
            { path = List.map (translateToBoard rect) path, frame = BoardFrame }

        Nothing ->
            { path = path, frame = ViewportFrame }


translateToBoard : GA.Rect -> State.GesturePoint -> State.GesturePoint
translateToBoard rect p =
    { tMs = p.tMs
    , x = p.x - rect.x
    , y = p.y - rect.y
    }


{-| Resolve a completed drag gesture into the WireAction (if
any) it produces. Pure — no state mutation. The actual model
update flows through `Main.Apply.applyAction`, same path as
replay and (eventually) wire-received actions.

Click precedence over drag mirrors the TS engine's
`process_pointerup` logic: if `clickIntent` survived, it's a
split; otherwise dispatch on `(hoveredWing, source,
cursorOverBoard)`.
-}
resolveGesture : DragInfo -> Model -> Maybe WireAction
resolveGesture info _ =
    case ( info.clickIntent, info.source ) of
        ( Just cardIdx, FromBoardStack stack ) ->
            Just (WA.Split { stack = stack, cardIndex = cardIdx })

        _ ->
            case ( info.hoveredWing, info.source ) of
                ( Just wing, FromBoardStack source ) ->
                    Just
                        (WA.MergeStack
                            { source = source
                            , target = wing.target
                            , side = wing.side
                            }
                        )

                ( Just wing, FromHandCard card ) ->
                    Just
                        (WA.MergeHand
                            { handCard = card
                            , target = wing.target
                            , side = wing.side
                            }
                        )

                ( Nothing, FromHandCard card ) ->
                    if cursorOverBoard info then
                        case dropLoc info of
                            Just loc ->
                                if dropFootprintInBounds 1 loc then
                                    Just (WA.PlaceHand { handCard = card, loc = loc })

                                else
                                    Nothing

                            Nothing ->
                                Nothing

                    else
                        Nothing

                ( Nothing, FromBoardStack stack ) ->
                    if cursorOverBoard info then
                        case dropLoc info of
                            Just loc ->
                                if dropFootprintInBounds (CardStack.size stack) loc then
                                    Just (WA.MoveStack { stack = stack, newLoc = loc })

                                else
                                    Nothing

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


{-| Purely geometric "which wing does the dragged floater
overlap?" The drop decision is about **what the player sees** —
the floater's visible rect — not where a naked cursor happens
to be. So the hit-test is floater-rect vs wing-rect overlap,
not cursor-in-wing.

Independent of the browser's DOM hit-test. Called from every
MouseMove so the wing highlight + status message track the
floater in real time; also the authoritative check at drop
time via `resolveGesture`.
-}
floaterOverWing : DragInfo -> Maybe WingOracle.WingId
floaterOverWing info =
    case info.boardRect of
        Nothing ->
            Nothing

        Just rect ->
            let
                floater =
                    floaterBoardRect info rect
            in
            info.wings
                |> List.filter (\wing -> overlaps floater (WingOracle.wingBoardRect wing))
                |> List.head


{-| The floater's footprint in board-frame coords. The
floater's top-left sits at `cursor - grabOffset` in viewport
coords; subtracting the board rect puts it in board frame.
Width depends on the dragged source (a 3-card stack is wider
than a hand card).
-}
floaterBoardRect :
    DragInfo
    -> { x : Int, y : Int, width : Int, height : Int }
    -> { left : Int, top : Int, width : Int, height : Int }
floaterBoardRect info rect =
    let
        width =
            case info.source of
                FromBoardStack stack ->
                    CardStack.stackDisplayWidth stack

                FromHandCard _ ->
                    CardStack.stackPitch
    in
    { left = info.cursor.x - info.grabOffset.x - rect.x
    , top = info.cursor.y - info.grabOffset.y - rect.y
    , width = width
    , height = BG.cardHeight
    }


overlaps :
    { left : Int, top : Int, width : Int, height : Int }
    -> { left : Int, top : Int, width : Int, height : Int }
    -> Bool
overlaps a b =
    let
        aRight =
            a.left + a.width

        aBottom =
            a.top + a.height

        bRight =
            b.left + b.width

        bBottom =
            b.top + b.height
    in
    (a.left < bRight)
        && (aRight > b.left)
        && (a.top < bBottom)
        && (aBottom > b.top)


{-| Status message to show while hovering a wing (a drop here
would fire a merge). Distinct from the primary action messages
in `Main.Apply` — that machinery fires on mouseup; this fires
mid-drag.
-}
wingHoverStatus : State.StatusMessage
wingHoverStatus =
    { text = "Drop stack to complete merge.", kind = Inform }


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


{-| True iff a stack of `cardCount` cards placed at `loc` fits
entirely within the board's bounds. Used to gate MoveStack and
PlaceHand wire-emission so drops that would put a stack off the
board (e.g. dragged past the top-left corner) snap back instead
of shipping negative or overflowing coords to the server.

Follows the "invalid drops snap back" rule — the gesture is
discarded, and the source card returns to where it was picked
up. No silent clamping.
-}
dropFootprintInBounds : Int -> BoardLocation -> Bool
dropFootprintInBounds cardCount loc =
    let
        bounds =
            Apply.refereeBounds
    in
    (loc.left >= 0)
        && (loc.top >= 0)
        && (loc.left + BG.stackWidth cardCount <= bounds.maxWidth)
        && (loc.top + BG.cardHeight <= bounds.maxHeight)


{-| If the drag resolved to a drop-loc whose stack footprint
would spill off the board, return a scold `StatusMessage`. The
check doesn't require the cursor to still be over the board
at mouseup — a slip past the corner typically ends with the
cursor technically just outside the widget, and we still want
to explain why the stack snapped back.
-}
droppedOffBoardScold : DragInfo -> Maybe State.StatusMessage
droppedOffBoardScold info =
    let
        footprintCheck cardCount =
            case dropLoc info of
                Just loc ->
                    if not (dropFootprintInBounds cardCount loc) then
                        Just
                            { text =
                                "Don't knock cards off the board, please. You're not a cat!"
                            , kind = Scold
                            }

                    else
                        Nothing

                Nothing ->
                    Nothing
    in
    case info.source of
        FromBoardStack stack ->
            footprintCheck (CardStack.size stack)

        FromHandCard _ ->
            footprintCheck 1


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
`MouseEvent.timeStamp`. Same semantics as mouseMoveDecoder's
timestamp (performance.now()-style, document-lifetime relative).
Attached to every pointer-start event so splits — which involve
no intervening MouseMove — still carry telemetry.
-}
pointAndTimeDecoder : Decoder ( Point, Float )
pointAndTimeDecoder =
    Decode.map2 Tuple.pair
        pointDecoder
        (Decode.field "timeStamp" Decode.float)



-- VIEW-SIDE STYLING HOOKS


{-| Mousedown handler for a board card. Emits
`MouseDownOnBoardCard` carrying the CardStack the card lives in
and the card's position within that stack (needed for Split),
which flows into update → `startBoardCardDrag`.
-}
cardMouseDown : CardStack -> Int -> List (Html.Attribute Msg)
cardMouseDown stack cardIdx =
    [ Events.on "mousedown"
        (Decode.map
            (\( p, t ) ->
                MouseDownOnBoardCard { stack = stack, cardIndex = cardIdx } p t
            )
            pointAndTimeDecoder
        )
    ]


{-| Per-hand-card attribute list. Three responsibilities:

1.  **Hint highlight** — if this card's identity is in
    `hintedCards`, paint it light green (nudges the player
    toward the top Hint suggestion).
2.  **Mousedown hook** — when not dragging, attach the
    `MouseDownOnHandCard` event with the Card value.
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
                            (\( p, t ) -> MouseDownOnHandCard hc.card p t)
                            pointAndTimeDecoder
                        )
                    ]

                Dragging info ->
                    case info.source of
                        FromHandCard sourceCard ->
                            if sourceCard == hc.card then
                                [ style "opacity" "0.35", style "pointer-events" "none" ]

                            else
                                [ style "pointer-events" "none" ]

                        FromBoardStack _ ->
                            [ style "pointer-events" "none" ]
           )
