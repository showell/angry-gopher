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
import Game.PuzzleFlagDsl as PuzzleFlagDsl
import Game.BoardGesture as BoardGesture
import Game.BoardView as BoardView
import Game.Button as Button
import Game.CardStack as CardStack exposing (CardStack)
import Game.Drag as Drag exposing (DragState(..))
import Game.Execute as Execute
import Game.GameEvent as GameEvent exposing (GameEvent(..))
import Game.Physics.GestureArbitration as GA
import Game.Point exposing (Point)
import Game.PointerInput as PointerInput
import Game.Status as Status exposing (StatusKind(..))
import Game.WingView as WingView
import Html exposing (Html, div)
import Html.Attributes exposing (style)
import Http
import Json.Decode as Decode
import Puzzle.Animate as Animate
import Task
import Time


{-| Server-baked flags. The Go handler picks the puzzle, allocates
a session, and emits `{session_id, initial_board}` in the page's
`Elm.Puzzle.init` call. We decode it once at boot.
-}
type alias DecodedFlags =
    { sessionId : Int
    , initialBoard : List CardStack
    }


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
    , replayState : Maybe Animate.AnimationState
    }


type Msg
    = MouseDownOnBoardCard { stack : CardStack, cardIndex : Int, point : Point, time : Int }
    | MouseMove Point Int
    | MouseUp Point Int
    | BoardRectReceived (Result Browser.Dom.Error Browser.Dom.Element)
    | ClickUndo
    | ClickInstantReplay
    | ClickReplayPauseToggle
    | ReplayTick Time.Posix
    | ActionSent (Result Http.Error ())


flagsDecoder : Decode.Decoder DecodedFlags
flagsDecoder =
    Decode.string
        |> Decode.andThen
            (\dsl ->
                case PuzzleFlagDsl.parsePuzzleFlag dsl of
                    Ok flag ->
                        Decode.succeed
                            { sessionId = flag.sessionId
                            , initialBoard = flag.board
                            }

                    Err msg ->
                        Decode.fail msg
            )


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
              , replayState = Nothing
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



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        BoardRectReceived (Ok element) ->
            ( { model
                | boardRect =
                    Just
                        { x = round (element.element.x - element.viewport.x)
                        , y = round (element.element.y - element.viewport.y)
                        , width = round element.element.width
                        , height = round element.element.height
                        }
              }
            , Cmd.none
            )

        BoardRectReceived (Err _) ->
            ( model, Cmd.none )

        MouseDownOnBoardCard { stack, cardIndex, point, time } ->
            case model.drag of
                NotDragging ->
                    ( { model
                        | drag =
                            DraggingBoardCard
                                (BoardGesture.startBoardDragInfo
                                    { stack = stack
                                    , cardIndex = cardIndex
                                    , cursor = point
                                    , tMs = time
                                    , board = model.board
                                    }
                                )
                      }
                    , Browser.Dom.getElement (BoardView.boardDomIdFor model.gameId)
                        |> Task.attempt BoardRectReceived
                    )

                _ ->
                    ( model, Cmd.none )

        MouseMove pos tMs ->
            case model.drag of
                DraggingBoardCard d ->
                    let
                        ( nextD, nextStatus ) =
                            BoardGesture.mouseMove pos tMs d model.status
                    in
                    ( { model | drag = DraggingBoardCard nextD, status = nextStatus }
                    , Cmd.none
                    )

                DraggingHandCard _ ->
                    ( model, Cmd.none )

                NotDragging ->
                    ( model, Cmd.none )

        MouseUp releasePoint tMs ->
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
                        , status = outcome.status
                        , nextSeq = outcome.nextSeq
                      }
                    , outcome.outboundPayload
                        |> Maybe.map (sendAction model.sessionId)
                        |> Maybe.withDefault Cmd.none
                    )

        ClickUndo ->
            if canUndo model.actionLog then
                let
                    nextLog =
                        model.actionLog ++ [ { action = GameEvent.Undo } ]

                    effective =
                        ActionLog.collapseUndos nextLog
                in
                ( { model
                    | actionLog = nextLog
                    , board =
                        List.foldl applyForPuzzle
                            model.initialBoard
                            (List.map .action effective)
                    , nextSeq = model.nextSeq + 1
                  }
                , sendAction model.sessionId (GameEvent.undoDsl model.nextSeq)
                )

            else
                ( model, Cmd.none )

        ClickInstantReplay ->
            ( { model
                | replayState =
                    Just
                        (Animate.start
                            (ActionLog.collapseUndos model.actionLog)
                            model.initialBoard
                        )
                , drag = NotDragging
                , status = { text = "Replaying…", kind = Inform }
              }
            , Cmd.none
            )

        ClickReplayPauseToggle ->
            ( { model | replayState = Maybe.map Animate.togglePause model.replayState }
            , Cmd.none
            )

        ReplayTick nowPosix ->
            case model.replayState of
                Nothing ->
                    ( model, Cmd.none )

                Just rs ->
                    case Animate.tick (Time.posixToMillis nowPosix) rs of
                        Animate.StillAnimating nextRs ->
                            ( { model | replayState = Just nextRs }, Cmd.none )

                        Animate.Completed ->
                            ( { model
                                | replayState = Nothing
                                , status = { text = "Replay completed! Continue playing.", kind = Inform }
                              }
                            , Cmd.none
                            )

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


canUndo : List ActionLogEntry -> Bool
canUndo log =
    not (List.isEmpty (ActionLog.collapseUndos log))


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


-- WIRE


sendAction : Int -> String -> Cmd Msg
sendAction sessionId line =
    Http.post
        { url = "/gopher/puzzle/sessions/" ++ String.fromInt sessionId ++ "/actions"
        , body = Http.stringBody "text/plain" line
        , expect = Http.expectWhatever ActionSent
        }



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ dragSubscriptions model
        , replaySubscriptions model
        ]


dragSubscriptions : Model -> Sub Msg
dragSubscriptions model =
    case model.drag of
        NotDragging ->
            Sub.none

        _ ->
            Sub.batch
                [ Browser.Events.onMouseMove (PointerInput.mouseMoveDecoder MouseMove)
                , Browser.Events.onMouseUp (PointerInput.mouseUpDecoder MouseUp)
                ]


replaySubscriptions : Model -> Sub Msg
replaySubscriptions model =
    case model.replayState of
        Just rs ->
            if rs.paused then
                Sub.none

            else
                Browser.Events.onAnimationFrame ReplayTick

        Nothing ->
            Sub.none



-- VIEW


view : Model -> Html Msg
view model =
    let
        ( board, drag ) =
            case model.replayState of
                Just rs ->
                    ( rs.board, replayDrag rs )

                Nothing ->
                    ( model.board, model.drag )

        boardFloaters =
            case drag of
                DraggingBoardCard d ->
                    [ Drag.renderBoardFloater d [ style "position" "absolute" ] ]

                _ ->
                    []

        -- Puzzles never have hand drags; dispatches are just the
        -- board-card branch + empty fallback.
        wings =
            case drag of
                DraggingBoardCard d ->
                    d.wings

                _ ->
                    []

        hoveredWing =
            case drag of
                DraggingBoardCard d ->
                    WingView.hoveredWing
                        d.floaterTopLeft
                        (CardStack.stackDisplayWidth d.stack)
                        d.wings

                _ ->
                    Nothing

        sourceStack =
            case drag of
                DraggingBoardCard d ->
                    Just d.stack

                _ ->
                    Nothing

        cardMouseDown =
            case drag of
                NotDragging ->
                    Just (PointerInput.cardMouseDown MouseDownOnBoardCard)

                _ ->
                    Nothing

        wingsWithHover =
            List.map (\w -> ( w, hoveredWing == Just w )) wings
    in
    div
        [ style "font-family" "system-ui, sans-serif" ]
        [ Status.viewStatusBar model.status
        , div
            [ style "padding" "20px"
            , style "display" "flex"
            , style "gap" "20px"
            , style "align-items" "flex-start"
            ]
            [ div
                [ style "min-width" "120px"
                , style "display" "flex"
                , style "flex-direction" "column"
                , style "gap" "8px"
                ]
                [ undoButton model
                , replayButton model
                ]
            , BoardView.boardShell
                { board = board
                , gameId = model.gameId
                , sourceStack = sourceStack
                , cardMouseDown = cardMouseDown
                , wingsWithHover = wingsWithHover
                , boardFloaters = boardFloaters
                }
            ]
        ]


{-| Drag the View should render during a replay. Animating
phases surface the sub-machine's dragInfo; idle phases show
no floater.
-}
replayDrag : Animate.AnimationState -> Drag.DragState
replayDrag rs =
    case rs.phase of
        Animate.AnimatingBoardAction state ->
            Drag.DraggingBoardCard state.dragInfo

        _ ->
            Drag.NotDragging


undoButton : Model -> Html Msg
undoButton model =
    if model.replayState == Nothing && canUndo model.actionLog then
        Button.button "Undo" ClickUndo

    else
        Button.disabledButton "Undo"


replayButton : Model -> Html Msg
replayButton model =
    case model.replayState of
        Just rs ->
            if rs.paused then
                Button.button "Resume" ClickReplayPauseToggle

            else
                Button.button "Pause" ClickReplayPauseToggle

        Nothing ->
            -- Compare against the post-collapse log so a fully
            -- undone session reports "nothing to replay" rather
            -- than firing an immediate Completed.
            if List.isEmpty (ActionLog.collapseUndos model.actionLog) then
                Button.disabledButton "Replay"

            else
                Button.button "Replay" ClickInstantReplay


main : Program Decode.Value Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
