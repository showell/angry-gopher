module Main.Gesture exposing
    ( cardMouseDown
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

-}

import Browser.Dom
import Game.BoardGesture as BoardGesture
import Game.Drag exposing (DragState(..))
import Game.HandGesture as HandGesture
import Game.Physics.WingOracle as WingOracle
import Game.Rules.Card exposing (Card)
import Game.CardStack as CardStack exposing (CardStack, HandCard)
import Html
import Html.Attributes exposing (style)
import Html.Events as Events
import Json.Decode as Decode exposing (Decoder)
import Main.Msg exposing (Msg(..))
import Main.State
    exposing
        ( Model
        , activeHand
        , boardDomIdFor
        )
import Main.Types exposing (Point)
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
            in
            -- Intra-board: the floater starts exactly where
            -- the stack is. `stack.loc` is already a
            -- `BoardLocation` — same shape as `floaterTopLeft`,
            -- no translation.
            ( { model
                | drag =
                    DraggingBoardCard
                        { stack = stack
                        , cardIndex = cardIndex
                        , originalCursor = clientPoint
                        , cursor = clientPoint
                        , floaterTopLeft = stack.loc
                        , gesturePath =
                            [ { tMs = tMs, x = stack.loc.left, y = stack.loc.top } ]
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
            BoardGesture.handleMouseUp releasePoint tMs d model

        DraggingHandCard d ->
            HandGesture.handleMouseUp releasePoint d model




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
