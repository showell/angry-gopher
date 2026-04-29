module Main.Gesture exposing
    ( cardMouseDown
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
      - hint-green background); `cardMouseDown` produces a
        board-card mousedown handler.
  - **Decoder** — `pointDecoder` pulls `{clientX, clientY}` from
    mouse events into the `Point` record.

Extracted 2026-04-19 from the pre-split `Main.elm` monolith.


## Click-vs-drag precedence

`resolveGesture` checks `clickIntent` first. A drag that starts
on a board card AND hasn't moved beyond the click threshold
(tracked elsewhere via `GestureArbitration.clickIntentAfterMove`)
yields a `Split` action. Only if the click intent has been
killed do we dispatch on `(hoveredWing, source, isCursorOverBoard)`
for merge / place / move.


## WireAction production — branch table

| clickIntent | source | hoveredWing | isCursorOverBoard | Result |
|---|---|---|---|---|
| Just cardIdx | FromBoardStack stack | — | — | `Split { stack, cardIndex }` |
| Nothing | FromBoardStack stack | Just wing | — | `MergeStack { source=stack, target=wing.target, side }` |
| Nothing | FromHandCard card | Just wing | — | `MergeHand { handCard=card, target=wing.target, side }` |
| Nothing | FromHandCard card | Nothing | True (loc present) | `PlaceHand { handCard=card, loc }` |
| Nothing | FromBoardStack stack | Nothing | True (loc present) | `MoveStack { stack, newLoc=loc }` |
| any | any | any | drop too early / no rect | `Nothing` (gesture discarded) |

-}

import Browser.Dom
import Game.BoardGeometry as BG
import Game.Rules.Card exposing (Card)
import Game.CardStack as CardStack exposing (BoardLocation, CardStack, HandCard)
import Game.GestureArbitration as GA
import Game.WingOracle as WingOracle
import Game.WireAction as WA exposing (WireAction)
import Html
import Html.Attributes exposing (style)
import Html.Events as Events
import Json.Decode as Decode exposing (Decoder)
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


{-| Start a drag from a board card. The floater's initial
top-left is `stack.loc` (board frame, no translation).
`clickIntent = Just cardIndex` marks this as a _potential_
split click; `GestureArbitration.clickIntentAfterMove` (on
subsequent MouseMove) kills the intent once the cursor
drifts past the click threshold.
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
                -- where the stack is. `stack.loc` is
                -- already in board frame, so no translation
                -- needed. `pathFrame = BoardFrame` tells
                -- the View layer to render the floater as
                -- a board-div child, which matches this
                -- frame by CSS construction.
                initialFloater =
                    { x = stack.loc.left, y = stack.loc.top }
            in
            ( { model
                | drag =
                    Dragging
                        { source = FromBoardStack stack
                        , cursor = clientPoint
                        , originalCursor = clientPoint
                        , floaterTopLeft = initialFloater
                        , wings = wings
                        , hoveredWing = Nothing
                        , boardRect = Nothing
                        , clickIntent = Just cardIndex
                        , gesturePath =
                            [ { tMs = tMs, x = initialFloater.x, y = initialFloater.y } ]
                        , pathFrame = BoardFrame
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

                -- Hand-origin: the floater is rendered as a
                -- viewport overlay (pathFrame = ViewportFrame).
                -- We don't know the hand card's exact viewport
                -- rect without a DOM measurement, so we
                -- approximate the initial floater as "a bit
                -- above-and-left of the cursor" — clientPoint
                -- minus a local half-pitch / 20-px offset.
                -- Not stored anywhere; used only to seed
                -- `floaterTopLeft`. From there forward the
                -- cursor-delta invariant in `mouseMove` does
                -- the work.
                initialFloater =
                    { x = clientPoint.x - CardStack.stackPitch // 2
                    , y = clientPoint.y - 20
                    }
            in
            ( { model
                | drag =
                    Dragging
                        { source = FromHandCard card
                        , cursor = clientPoint
                        , originalCursor = clientPoint
                        , floaterTopLeft = initialFloater
                        , wings = wings
                        , hoveredWing = Nothing
                        , boardRect = Nothing
                        , clickIntent = Nothing
                        , gesturePath =
                            [ { tMs = tMs, x = initialFloater.x, y = initialFloater.y } ]
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
viewport rectangle. Needed by `isCursorOverBoard` and by hand-
origin `dropLoc` to translate a viewport-frame floater into
board frame; intra-board drags don't need it. The rect
arrives via `BoardRectReceived` — usually within a frame, so
the race with drag duration is benign.
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
                -- Apply the mouseup cursor delta to the floater
                -- (same invariant as mousemove). Append the
                -- resulting position to the gesture path so even
                -- pure clicks — which skip mousemove entirely —
                -- carry two samples (mousedown seed + release).
                delta =
                    { x = releasePoint.x - info.cursor.x
                    , y = releasePoint.y - info.cursor.y
                    }

                releaseFloater =
                    { x = info.floaterTopLeft.x + delta.x
                    , y = info.floaterTopLeft.y + delta.y
                    }

                fullPath =
                    info.gesturePath
                        ++ [ { tMs = tMs, x = releaseFloater.x, y = releaseFloater.y } ]

                infoFull =
                    { info
                        | cursor = releasePoint
                        , floaterTopLeft = releaseFloater
                        , gesturePath = fullPath
                    }

                maybeAction =
                    resolveGesture infoFull

                modelAfterDragClear =
                    clearDrag model

                modelAfterAction =
                    case maybeAction of
                        Just action ->
                            -- A successful user gesture invalidates any
                            -- cached agent program — the board has
                            -- diverged from the plan, so the next "Let
                            -- agent play" click must re-solve.
                            (Apply.applyAction action modelAfterDragClear
                                |> Apply.commit
                            )
                                |> (\m -> { m | agentProgram = Nothing })

                        Nothing ->
                            case droppedOffBoardScold infoFull of
                                Just status ->
                                    { modelAfterDragClear | status = status }

                                Nothing ->
                                    modelAfterDragClear

                maybeGesture =
                    case maybeAction of
                        Just action ->
                            gestureForAction action fullPath info.pathFrame

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

                                seq =
                                    modelAfterAction.nextSeq

                                writeCmd =
                                    Wire.sendAction sid
                                        seq
                                        modelAfterAction.puzzleName
                                        action
                                        maybeGesture
                            in
                            ( { modelAfterAction
                                | actionLog = modelAfterAction.actionLog ++ [ entry ]
                                , nextSeq = seq + 1
                              }
                            , writeCmd
                            )

                        _ ->
                            ( modelAfterAction, Cmd.none )
            in
            ( finalModel, cmd )


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
    -> List State.GesturePoint
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


{-| Resolve a completed drag into the WireAction (if any)
it should produce. Pure. Click precedence: if `clickIntent`
survived, it's a `Split`; otherwise dispatch on
`(hoveredWing, source, isCursorOverBoard)` per the branch
table in the module header.
-}
resolveGesture : DragInfo -> Maybe WireAction
resolveGesture info =
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
                    if isCursorOverBoard info then
                        case dropLoc info of
                            Just loc ->
                                if isDropFootprintInBounds 1 loc then
                                    Just (WA.PlaceHand { handCard = card, loc = loc })

                                else
                                    Nothing

                            Nothing ->
                                Nothing

                    else
                        Nothing

                ( Nothing, FromBoardStack stack ) ->
                    if isCursorOverBoard info then
                        case dropLoc info of
                            Just loc ->
                                if isDropFootprintInBounds (CardStack.size stack) loc then
                                    Just (WA.MoveStack { stack = stack, newLoc = loc })

                                else
                                    Nothing

                            Nothing ->
                                Nothing

                    else
                        Nothing


isCursorOverBoard : DragInfo -> Bool
isCursorOverBoard info =
    case info.boardRect of
        Just rect ->
            GA.isCursorInRect info.cursor rect

        Nothing ->
            False


{-| Which wing (if any) is the floater about to land on?
Fires when the floater's top-left is within
`wingSnapTolerance` of its eventual landing. Independent of
the browser's DOM hit-test; called from every MouseMove to
drive the wing-highlight and from `resolveGesture` as the
authoritative drop-time check.
-}
floaterOverWing : DragInfo -> Maybe WingOracle.WingId
floaterOverWing info =
    info.wings
        |> List.filter (isNearEventualLanding info)
        |> List.head


{-| Half a card-pitch of slop in each axis around the
eventual landing. Tight enough that the floater must be
visually adjacent to the target; loose enough to tolerate
normal mouse wiggle.
-}
wingSnapTolerance : Int
wingSnapTolerance =
    CardStack.stackPitch // 2


{-| The one localized spot where a board↔container frame
translation happens for the hit-test. `eventualFloaterTopLeft`
is naturally board-frame; lift it into the floater's frame
(no-op for intra-board drags; add `boardRect` origin for
hand-origin drags) and compare directly. Hand-origin drags
with no board rect yet return False rather than guess.
-}
isNearEventualLanding : DragInfo -> WingOracle.WingId -> Bool
isNearEventualLanding info wing =
    let
        floaterWidth =
            case info.source of
                FromBoardStack stack ->
                    CardStack.stackDisplayWidth stack

                FromHandCard _ ->
                    CardStack.stackPitch

        eventualBoard =
            WingOracle.eventualFloaterTopLeft wing floaterWidth

        eventualInFloaterFrame =
            case info.pathFrame of
                BoardFrame ->
                    Just { x = eventualBoard.left, y = eventualBoard.top }

                ViewportFrame ->
                    info.boardRect
                        |> Maybe.map
                            (\rect ->
                                { x = eventualBoard.left + rect.x
                                , y = eventualBoard.top + rect.y
                                }
                            )
    in
    case eventualInFloaterFrame of
        Nothing ->
            False

        Just eventual ->
            let
                dx =
                    abs (info.floaterTopLeft.x - eventual.x)

                dy =
                    abs (info.floaterTopLeft.y - eventual.y)
            in
            dx < wingSnapTolerance && dy < wingSnapTolerance


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
    case info.pathFrame of
        BoardFrame ->
            -- Intra-board: floaterTopLeft IS the drop loc.
            Just { left = info.floaterTopLeft.x, top = info.floaterTopLeft.y }

        ViewportFrame ->
            -- Hand-origin: translate viewport → board by
            -- subtracting the board div's viewport origin.
            info.boardRect
                |> Maybe.map
                    (\rect ->
                        { left = info.floaterTopLeft.x - rect.x
                        , top = info.floaterTopLeft.y - rect.y
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
                    if not (isDropFootprintInBounds cardCount loc) then
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
                MouseDownOnBoardCard { stack = stack, cardIndex = cardIdx, point = p, time = t }
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
                            (\( p, t ) -> MouseDownOnHandCard { card = hc.card, point = p, time = t })
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
