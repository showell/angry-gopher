module Puzzle exposing (main)

{-| Puzzle V2 — drag-aware single-puzzle surface.

Dedicated host: own Msg, own Model, no `Main.*` imports.
Composes `Game.*` building blocks directly (BoardView,
BoardGesture, BoardDrag, Drag, Button). Supports board-card
drag (move + merge + click=split) and Undo.

Wire: at boot we POST `/gopher/puzzle/sessions` with the
initial board; the server allocates an id, writes meta.json,
and returns `{session_id}`. Each subsequent action (board
drag outcome or Undo) is shipped to
`/gopher/puzzle/sessions/<id>/actions` as a `{seq, action}`
envelope — same wire shape as the full game's. The agent
reads these on disk to study Steve's solutions.

Undo follows the full-game model: clicking Undo appends a
`GameEvent.Undo` token to `actionLog`; `collapseUndos` derives
the effective sequence; the board is recomputed by folding
`applyForPuzzle` over that sequence from `initialBoard`. The
local Model stays correct even before the session id arrives;
the wire layer goes silent until it does.

-}

import Browser
import Browser.Dom
import Browser.Events
import Game.ActionLog as ActionLog exposing (ActionLogEntry)
import Game.BoardDrag as BoardDrag
import Game.BoardGesture as BoardGesture
import Game.BoardView as BoardView
import Game.Button as Button
import Game.CardStack as CardStack exposing (BoardCardState(..), CardStack)
import Game.Drag exposing (DragState(..))
import Game.Execute as Execute
import Game.GameEvent as GameEvent exposing (GameEvent(..))
import Game.Physics.GestureArbitration as GA
import Game.Point exposing (Point)
import Game.PointerInput as PointerInput
import Game.Rules.Card exposing (CardValue(..), OriginDeck(..), Suit(..))
import Game.Status as Status exposing (StatusKind(..))
import Html exposing (Html, div)
import Html.Attributes exposing (style)
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
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
    , sessionId : Maybe Int
    , nextSeq : Int
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
    , sessionId = Nothing
    , nextSeq = 1
    }


init : () -> ( Model, Cmd Msg )
init () =
    ( initialModel, fetchNewPuzzleSession initialModel.initialBoard )



-- MSG


type Msg
    = MouseDownOnBoardCard { stack : CardStack, cardIndex : Int, point : Point, time : Float }
    | MouseMove Point Float
    | MouseUp Point Float
    | BoardRectReceived (Result Browser.Dom.Error Browser.Dom.Element)
    | ClickUndo
    | SessionReceived (Result Http.Error Int)
    | ActionSent (Result Http.Error ())



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        MouseDownOnBoardCard { stack, cardIndex, point, time } ->
            startBoardCardDrag stack cardIndex point time model

        MouseMove pos tMs ->
            ( mouseMove pos tMs model, Cmd.none )

        MouseUp pos tMs ->
            handleMouseUp pos tMs model

        BoardRectReceived result ->
            ( boardRectReceived result model, Cmd.none )

        ClickUndo ->
            clickUndo model

        SessionReceived result ->
            ( sessionReceived result model, Cmd.none )

        ActionSent (Ok _) ->
            ( model, Cmd.none )

        ActionSent (Err err) ->
            let
                _ =
                    Debug.log "puzzle.ActionSent err" err
            in
            ( { model
                | status = { text = "Couldn't save action — see console.", kind = Scold }
              }
            , Cmd.none
            )


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


handleMouseUp : Point -> Float -> Model -> ( Model, Cmd Msg )
handleMouseUp releasePoint tMs model =
    case model.drag of
        NotDragging ->
            ( model, Cmd.none )

        DraggingHandCard _ ->
            ( { model | drag = NotDragging }, Cmd.none )

        DraggingBoardCard d ->
            let
                outcome =
                    BoardDrag.handleMouseUp releasePoint
                        tMs
                        d
                        { board = model.board
                        , boardRect = model.boardRect
                        , actionLog = model.actionLog
                        , nextSeq = model.nextSeq
                        }
            in
            ( { model
                | drag = NotDragging
                , board = outcome.board
                , actionLog = outcome.actionLog
                , status = outcome.status |> Maybe.withDefault model.status
                , nextSeq = outcome.nextSeq
              }
            , outcome.outboundPayload
                |> Maybe.map (sendAction model.sessionId)
                |> Maybe.withDefault Cmd.none
            )


{-| Append a `Undo` token to the action log, rebuild the board
by folding effective (post-collapse) events from `initialBoard`,
and ship the Undo envelope to the wire. No-op when nothing is
left to undo.
-}
clickUndo : Model -> ( Model, Cmd Msg )
clickUndo model =
    if canUndo model then
        let
            nextLog =
                model.actionLog ++ [ { action = GameEvent.Undo } ]

            effective =
                ActionLog.collapseUndos nextLog

            payload =
                Encode.object
                    [ ( "seq", Encode.int model.nextSeq )
                    , ( "action"
                      , Encode.object [ ( "action", Encode.string "undo" ) ]
                      )
                    ]
        in
        ( { model
            | actionLog = nextLog
            , board =
                List.foldl applyForPuzzle
                    model.initialBoard
                    (List.map .action effective)
            , nextSeq = model.nextSeq + 1
          }
        , sendAction model.sessionId payload
        )

    else
        ( model, Cmd.none )


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


sessionReceived : Result Http.Error Int -> Model -> Model
sessionReceived result model =
    case result of
        Ok sid ->
            { model | sessionId = Just sid }

        Err err ->
            let
                _ =
                    Debug.log "puzzle.SessionReceived err" err
            in
            { model
                | status =
                    { text = "Couldn't allocate puzzle session — see console."
                    , kind = Scold
                    }
            }



-- WIRE


fetchNewPuzzleSession : List CardStack -> Cmd Msg
fetchNewPuzzleSession initialBoard =
    Http.post
        { url = "/gopher/puzzle/sessions"
        , body =
            Http.jsonBody
                (Encode.object
                    [ ( "initial_board", Encode.list CardStack.encodeCardStack initialBoard ) ]
                )
        , expect = Http.expectJson SessionReceived sessionIdDecoder
        }


sendAction : Maybe Int -> Value -> Cmd Msg
sendAction maybeSessionId body =
    case maybeSessionId of
        Just sid ->
            Http.post
                { url = "/gopher/puzzle/sessions/" ++ String.fromInt sid ++ "/actions"
                , body = Http.jsonBody body
                , expect = Http.expectWhatever ActionSent
                }

        Nothing ->
            Cmd.none


sessionIdDecoder : Decoder Int
sessionIdDecoder =
    Decode.field "session_id" Decode.int



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
    -- Left sidebar (controls) + board on the right. Laptop has
    -- more horizontal than vertical room — the sidebar layout
    -- claws back the vertical space the old top-stacked Undo
    -- button consumed.
    div
        [ style "padding" "20px"
        , style "font-family" "system-ui, sans-serif"
        , style "display" "flex"
        , style "gap" "20px"
        , style "align-items" "flex-start"
        ]
        [ div
            [ style "min-width" "120px" ]
            [ undoButton model ]
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
--
-- Conformance scenario `puzzle_a3_004_seed4` from
-- games/lynrummy/puzzles/puzzles.json. Three-line solution
-- (peel + yank + push). The trouble is the singleton 7D' and
-- the rainbow stack [2C 3D 4C 5H 6S 7H 8C]; the canonical
-- solver pulls 8C and 6S off the rainbow to form [6S 7D' 8C],
-- then pushes the leftover 7H onto the 7-set.
--
-- This is a placeholder for server-down puzzle data. When we
-- ship the server-side payload (per the puzzle wire commit),
-- this hardcoded board goes away.


puzzleStacks : List CardStack
puzzleStacks =
    [ stackAt 80 160
        [ ( Ten, Diamond, DeckOne )
        , ( Jack, Diamond, DeckOne )
        , ( Queen, Diamond, DeckOne )
        , ( King, Diamond, DeckOne )
        ]
    , stackAt 200 40
        [ ( Seven, Spade, DeckOne )
        , ( Seven, Diamond, DeckOne )
        , ( Seven, Club, DeckOne )
        ]
    , stackAt 260 130
        [ ( Ace, Club, DeckOne )
        , ( Ace, Diamond, DeckOne )
        , ( Ace, Heart, DeckOne )
        ]
    , stackAt 392 52
        [ ( Three, Spade, DeckTwo )
        , ( Four, Spade, DeckOne )
        , ( Five, Spade, DeckTwo )
        ]
    , stackAt 467 52
        [ ( Six, Diamond, DeckOne )
        , ( Seven, Club, DeckTwo )
        , ( Eight, Heart, DeckOne )
        ]
    , stackAt 542 52
        [ ( Jack, Heart, DeckOne )
        , ( Queen, Spade, DeckOne )
        , ( King, Diamond, DeckTwo )
        ]
    , stackAt 320 70
        [ ( Two, Club, DeckOne )
        , ( Three, Diamond, DeckOne )
        , ( Four, Club, DeckOne )
        , ( Five, Heart, DeckOne )
        , ( Six, Spade, DeckOne )
        , ( Seven, Heart, DeckOne )
        , ( Eight, Club, DeckOne )
        ]
    , stackAt 20 62
        [ ( King, Spade, DeckOne )
        , ( Ace, Spade, DeckOne )
        , ( Two, Spade, DeckOne )
        ]
    , stackAt 140 59
        [ ( Ace, Heart, DeckTwo )
        , ( Two, Heart, DeckOne )
        , ( Three, Heart, DeckOne )
        ]
    , stackAt 392 187
        [ ( Two, Heart, DeckTwo )
        , ( Three, Spade, DeckOne )
        , ( Four, Heart, DeckOne )
        ]
    , stackAt 152 187
        [ ( Seven, Diamond, DeckTwo )
        ]
    ]


stackAt : Int -> Int -> List ( CardValue, Suit, OriginDeck ) -> CardStack
stackAt top left cards =
    { boardCards =
        List.map
            (\( v, s, d ) ->
                { card = { value = v, suit = s, originDeck = d }
                , state = FirmlyOnBoard
                }
            )
            cards
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
