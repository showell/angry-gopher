module Main.Gesture exposing
    ( handCardAttrs
    , startBoardCardDrag
    , startHandDrag
    )

{-| The pointer-gesture layer: everything between a physical
mousedown and the GameEvent it produces.

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
  - **End drag** — handled by `Main.Play.update` directly: it
    pattern matches on `model.drag` and calls
    `Game.BoardGesture.handleMouseUp` /
    `Game.HandGesture.handleMouseUp` for the per-side
    resolution, then dispatches on the returned variant to
    apply / scold / no-op.
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
import Game.BoardView exposing (boardDomIdFor)
import Game.Drag exposing (DragState(..))
import Game.HandGesture as HandGesture
import Game.PointerInput as PointerInput
import Game.Rules.Card exposing (Card)
import Game.CardStack exposing (CardStack, HandCard)
import Html
import Html.Attributes exposing (style)
import Html.Events as Events
import Game.Hand exposing (activeHand)
import Json.Decode as Decode
import Main.Msg exposing (Msg(..))
import Main.State exposing (Model)
import Game.Point exposing (Point)
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
            ( { model
                | drag =
                    DraggingBoardCard
                        (BoardGesture.startBoardDragInfo
                            { stack = stack
                            , cardIndex = cardIndex
                            , cursor = clientPoint
                            , tMs = tMs
                            , board = model.gameState.board
                            }
                        )
              }
            , fetchBoardRect model.gameId
            )

        _ ->
            ( model, Cmd.none )


{-| Start a drag from a hand card. -}
startHandDrag : Card -> Point -> Model -> ( Model, Cmd Msg )
startHandDrag card clientPoint model =
    case ( model.drag, findHandCard card (activeHand model.gameState).handCards ) of
        ( NotDragging, Just handCard ) ->
            ( { model
                | drag =
                    DraggingHandCard
                        (HandGesture.startHandDragInfo
                            { handCard = handCard
                            , cursor = clientPoint
                            , board = model.gameState.board
                            }
                        )
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



-- VIEW-SIDE STYLING HOOKS


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
                            PointerInput.pointAndTimeDecoder
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
