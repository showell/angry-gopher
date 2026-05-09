module Puzzle exposing (main)

{-| Puzzle V2 — drag-aware single-puzzle surface.

Dedicated host: own Msg, own Model, no `Main.*` imports.
Composes `Game.*` building blocks directly (BoardView,
BoardGesture, BoardDrag, Drag, Button). Supports board-card
drag (move + merge + click=split) and Undo. No hint, no
replay, no agent, no wire — actions mutate local Model only.

Undo follows the full-game model: clicking Undo appends a
`GameEvent.Undo` token to `actionLog`; `collapseUndos` derives
the effective sequence; the board is recomputed by folding
`applyForPuzzle` over that sequence from `initialBoard`. This
records state faithfully — every user action (including
undos) is in the log.

A puzzle wire is not yet implemented, so `BoardDrag`'s
`outboundPayload` is ignored and `nextSeq = 0`. When the wire
arrives we'll switch to the full-game seq + payload pattern.

-}

import Browser
import Browser.Dom
import Browser.Events
import Game.ActionLog as ActionLog exposing (ActionLogEntry)
import Game.BoardDrag as BoardDrag
import Game.BoardGesture as BoardGesture
import Game.BoardView as BoardView
import Game.Button as Button
import Game.CardStack exposing (BoardCardState(..), CardStack)
import Game.Drag exposing (DragState(..))
import Game.Execute as Execute
import Game.GameEvent as GameEvent exposing (GameEvent(..))
import Game.Physics.GestureArbitration as GA
import Game.Point exposing (Point)
import Game.PointerInput as PointerInput
import Game.Rules.Card exposing (CardValue(..), OriginDeck(..), Suit(..))
import Game.Status as Status
import Html exposing (Html, div)
import Html.Attributes exposing (style)
import Task



-- MODEL


type alias Model =
    { initialBoard : List CardStack
    , board : List CardStack
    , actionLog : List ActionLogEntry
    , drag : DragState
    , boardRect : Maybe GA.Rect
    , status : Status.StatusMessage
    , gameId : String
    }


initialModel : Model
initialModel =
    { initialBoard = puzzleStacks
    , board = puzzleStacks
    , actionLog = []
    , drag = NotDragging
    , boardRect = Nothing
    , status = { text = "Drag stacks to merge or move them.", kind = Status.Inform }
    , gameId = "puzzle"
    }


init : () -> ( Model, Cmd Msg )
init () =
    ( initialModel, Cmd.none )



-- MSG


type Msg
    = MouseDownOnBoardCard { stack : CardStack, cardIndex : Int, point : Point, time : Float }
    | MouseMove Point Float
    | MouseUp Point Float
    | BoardRectReceived (Result Browser.Dom.Error Browser.Dom.Element)
    | ClickUndo



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        MouseDownOnBoardCard { stack, cardIndex, point, time } ->
            startBoardCardDrag stack cardIndex point time model

        MouseMove pos tMs ->
            ( mouseMove pos tMs model, Cmd.none )

        MouseUp pos tMs ->
            ( handleMouseUp pos tMs model, Cmd.none )

        BoardRectReceived result ->
            ( boardRectReceived result model, Cmd.none )

        ClickUndo ->
            ( clickUndo model, Cmd.none )


startBoardCardDrag :
    CardStack
    -> Int
    -> Point
    -> Float
    -> Model
    -> ( Model, Cmd Msg )
startBoardCardDrag stack cardIndex clientPoint tMs model =
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
                            , board = model.board
                            }
                        )
              }
            , fetchBoardRect model.gameId
            )

        _ ->
            ( model, Cmd.none )


mouseMove : Point -> Float -> Model -> Model
mouseMove pos tMs model =
    case model.drag of
        DraggingBoardCard d ->
            let
                ( nextD, nextStatus ) =
                    BoardGesture.mouseMove pos tMs d model.status
            in
            { model | drag = DraggingBoardCard nextD, status = nextStatus }

        DraggingHandCard _ ->
            model

        NotDragging ->
            model


handleMouseUp : Point -> Float -> Model -> Model
handleMouseUp releasePoint tMs model =
    case model.drag of
        NotDragging ->
            model

        DraggingHandCard _ ->
            { model | drag = NotDragging }

        DraggingBoardCard d ->
            let
                outcome =
                    BoardDrag.handleMouseUp releasePoint
                        tMs
                        d
                        { board = model.board
                        , boardRect = model.boardRect
                        , actionLog = model.actionLog

                        -- No puzzle wire yet; the seq + outboundPayload
                        -- BoardDrag would build are unused. Stub
                        -- nextSeq, ignore outcome.outboundPayload.
                        , nextSeq = 0
                        }
            in
            { model
                | drag = NotDragging
                , board = outcome.board
                , actionLog = outcome.actionLog
                , status = outcome.status |> Maybe.withDefault model.status
            }


{-| Append a `Undo` token to the action log and rebuild the
board by folding effective (post-collapse) events from
`initialBoard`. No-op when nothing is left to undo.
-}
clickUndo : Model -> Model
clickUndo model =
    if canUndo model then
        let
            nextLog =
                model.actionLog ++ [ { action = GameEvent.Undo } ]

            effective =
                ActionLog.collapseUndos nextLog
        in
        { model
            | actionLog = nextLog
            , board =
                List.foldl applyForPuzzle
                    model.initialBoard
                    (List.map .action effective)
        }

    else
        model


canUndo : Model -> Bool
canUndo model =
    not (List.isEmpty (ActionLog.collapseUndos model.actionLog))


{-| Apply one event to the puzzle's board. The puzzle's
universe of actions is just the three board verbs; any other
variant in the log signals a real bug, so we log loudly (the
existing convention in `Game.Execute`).
-}
applyForPuzzle : GameEvent -> List CardStack -> List CardStack
applyForPuzzle event board =
    case event of
        Split p ->
            Execute.split p.stack p.cardIndex board

        MergeStack p ->
            Execute.mergeStack p.source p.target p.side board

        MoveStack p ->
            Execute.moveStack p.stack p.newLoc board

        _ ->
            let
                _ =
                    Debug.log "puzzle.applyForPuzzle: unexpected event in log" event
            in
            board


boardRectReceived : Result Browser.Dom.Error Browser.Dom.Element -> Model -> Model
boardRectReceived result model =
    case result of
        Ok element ->
            { model
                | boardRect =
                    Just
                        { x = round (element.element.x - element.viewport.x)
                        , y = round (element.element.y - element.viewport.y)
                        , width = round element.element.width
                        , height = round element.element.height
                        }
            }

        Err _ ->
            model


fetchBoardRect : String -> Cmd Msg
fetchBoardRect gameId =
    Browser.Dom.getElement (BoardView.boardDomIdFor gameId)
        |> Task.attempt BoardRectReceived



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    case model.drag of
        NotDragging ->
            Sub.none

        _ ->
            Sub.batch
                [ Browser.Events.onMouseMove (PointerInput.mouseMoveDecoder MouseMove)
                , Browser.Events.onMouseUp (PointerInput.mouseUpDecoder MouseUp)
                ]



-- VIEW


view : Model -> Html Msg
view model =
    div
        [ style "padding" "20px"
        , style "font-family" "system-ui, sans-serif"
        ]
        [ div [ style "margin-bottom" "10px" ] [ undoButton model ]
        , BoardView.boardColumn
            { board = model.board
            , boardRect = model.boardRect
            , drag = model.drag
            , gameId = model.gameId
            , cardMouseDown = PointerInput.cardMouseDown MouseDownOnBoardCard
            }
        ]


undoButton : Model -> Html Msg
undoButton model =
    if canUndo model then
        Button.button "Undo" ClickUndo

    else
        Button.disabledButton "Undo"



-- THE PUZZLE


puzzleStacks : List CardStack
puzzleStacks =
    [ stackAt 100 100
        [ ( Seven, Heart )
        , ( Eight, Heart )
        , ( Nine, Heart )
        ]
    , stackAt 220 100
        [ ( King, Club )
        , ( Ace, Club )
        , ( Two, Club )
        ]
    , stackAt 340 100
        [ ( Queen, Club )
        ]
    ]


stackAt : Int -> Int -> List ( CardValue, Suit ) -> CardStack
stackAt top left valuesAndSuits =
    { boardCards =
        List.map
            (\( v, s ) ->
                { card = { value = v, suit = s, originDeck = DeckOne }
                , state = FirmlyOnBoard
                }
            )
            valuesAndSuits
    , loc = { top = top, left = left }
    }


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
