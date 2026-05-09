module Puzzle exposing (main)

{-| Puzzle V3 — drag-aware single-puzzle surface.

Dedicated host: own Msg, own Model, no `Main.*` imports.
Composes `Game.*` building blocks directly. Supports
board-card drag (move + merge + click=split) and Undo.

The HTML page (served by `views/puzzle.go`) bakes both
`session_id` and `initial_board` into the Elm flags — the
client starts ready-to-play with no follow-up round trip
before the first action can ship.

Each subsequent action (board drag outcome or Undo) is shipped
to `/gopher/puzzle/sessions/<id>/actions` as a `{seq, action}`
envelope — same wire shape as the full game's. The agent reads
these on disk to study Steve's solutions.

Undo follows the full-game model: clicking Undo appends a
`GameEvent.Undo` token to `actionLog`; `collapseUndos` derives
the effective sequence; the board is recomputed by folding
`applyForPuzzle` over that sequence from `initialBoard`.

-}

import Browser
import Browser.Dom
import Browser.Events
import Game.ActionLog as ActionLog exposing (ActionLogEntry)
import Game.BoardDrag as BoardDrag
import Game.BoardGesture as BoardGesture
import Game.BoardView as BoardView
import Game.Button as Button
import Game.CardStack as CardStack exposing (CardStack)
import Game.Drag exposing (DragState(..))
import Game.Execute as Execute
import Game.GameEvent as GameEvent exposing (GameEvent(..))
import Game.Physics.GestureArbitration as GA
import Game.Point exposing (Point)
import Game.PointerInput as PointerInput
import Game.Status as Status exposing (StatusKind(..))
import Html exposing (Html, div)
import Html.Attributes exposing (style)
import Http
import Json.Decode as Decode
import Json.Encode as Encode exposing (Value)
import Task



-- FLAGS


{-| Server-baked flags. The Go handler picks the puzzle, allocates
a session, and emits `{session_id, initial_board}` in the page's
`Elm.Puzzle.init` call. We decode it once at boot.
-}
type alias DecodedFlags =
    { sessionId : Int
    , initialBoard : List CardStack
    }


flagsDecoder : Decode.Decoder DecodedFlags
flagsDecoder =
    Decode.map2 DecodedFlags
        (Decode.field "session_id" Decode.int)
        (Decode.field "initial_board" (Decode.list CardStack.cardStackDecoder))



-- MODEL


type alias Model =
    { initialBoard : List CardStack
    , board : List CardStack
    , actionLog : List ActionLogEntry
    , drag : DragState
    , boardRect : Maybe GA.Rect
    , status : Status.StatusMessage
    , gameId : String
    , sessionId : Int
    , nextSeq : Int
    }


init : Decode.Value -> ( Model, Cmd Msg )
init flagsValue =
    case Decode.decodeValue flagsDecoder flagsValue of
        Ok flags ->
            ( { initialBoard = flags.initialBoard
              , board = flags.initialBoard
              , actionLog = []
              , drag = NotDragging
              , boardRect = Nothing
              , status = { text = "Drag stacks to merge or move them.", kind = Inform }
              , gameId = "puzzle"
              , sessionId = flags.sessionId
              , nextSeq = 1
              }
            , Cmd.none
            )

        Err err ->
            -- Server contract violated: flags didn't carry the
            -- shape the client requires. Crash loud — this is a
            -- developer-time problem, not a user-time one.
            Debug.todo
                ("Puzzle flags failed to decode: "
                    ++ Decode.errorToString err
                )



-- MSG


type Msg
    = MouseDownOnBoardCard { stack : CardStack, cardIndex : Int, point : Point, time : Float }
    | MouseMove Point Float
    | MouseUp Point Float
    | BoardRectReceived (Result Browser.Dom.Error Browser.Dom.Element)
    | ClickUndo
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



-- WIRE


sendAction : Int -> Value -> Cmd Msg
sendAction sessionId body =
    Http.post
        { url = "/gopher/puzzle/sessions/" ++ String.fromInt sessionId ++ "/actions"
        , body = Http.jsonBody body
        , expect = Http.expectWhatever ActionSent
        }



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


main : Program Decode.Value Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
