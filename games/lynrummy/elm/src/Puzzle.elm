module Puzzle exposing (main)

{-| The action log written to
games/lynrummy/data/puzzle/sessions/<id>/puzzle_<idx>/actions.dsl
has one consumer: the in-repo agent. No external clients, so
the wire format is ours to change whenever the code needs.
-}

import Array exposing (Array)
import Browser
import Browser.Dom
import Browser.Events
import Lib.ActionLog as ActionLog exposing (ActionLogEntry)
import Lib.BoardDrag as BoardDrag
import Lib.PuzzleFlagDsl as PuzzleFlagDsl
import Lib.BoardGesture as BoardGesture
import Lib.BoardView as BoardView
import Lib.Button as Button
import Lib.CardStack as CardStack exposing (CardStack)
import Lib.Colors as Colors
import Lib.Drag as Drag exposing (DragState(..))
import Lib.Execute as Execute
import Lib.GameEvent as GameEvent exposing (GameEvent(..))
import Lib.Physics.GestureArbitration as GA
import Lib.Point exposing (Point)
import Lib.PointerInput as PointerInput
import Lib.Status as Status exposing (StatusKind(..))
import Lib.WingView as WingView
import Html exposing (Html, div, text)
import Html.Attributes as Attr exposing (style)
import Html.Events as Events
import Http
import Json.Decode as Decode
import Puzzle.Animate as Animate
import Task
import Time


{-| Server-baked flags. The Go handler allocates a session and
emits `{session_id, puzzles}` in the page's `Elm.Puzzle.init`
call — `puzzles` is the entire curated catalog. We decode it
once at boot; navigation never refetches.
-}
type alias DecodedFlags =
    { sessionId : Int
    , puzzles : List Puzzle
    }


{-| Catalog entry + the user's in-flight progress on that
puzzle, fused. `name` and `initialBoard` are immutable; `board`,
`actionLog`, and `nextSeq` change as the user plays. A fresh
puzzle (just-decoded, untouched) starts with
`board == initialBoard`, `actionLog == []`, `nextSeq == 1`.
-}
type alias Puzzle =
    { name : String
    , initialBoard : List CardStack
    , board : List CardStack
    , actionLog : List ActionLogEntry
    , nextSeq : Int
    }


type alias Model =
    { puzzles : Array Puzzle
    , currentIndex : Int
    , drag : DragState
    , boardRect : Maybe GA.Rect
    , status : Status.StatusMessage
    , gameId : String
    , sessionId : Int
    , replayState : Maybe Animate.AnimationState
    , congratsVisible : Bool
    }


type Msg
    = MouseDownOnBoardCard { stack : CardStack, cardIndex : Int, point : Point, time : Int }
    | MouseMove Point Int
    | MouseUp Point Int
    | BoardRectReceived (Result Browser.Dom.Error Browser.Dom.Element)
    | ClickPrevPuzzle
    | ClickNextPuzzle
    | ClickUndo
    | ClickReset
    | ClickInstantReplay
    | ClickReplayPauseToggle
    | PuzzleSolved
    | ClickAdvanceFromSolvedPuzzle
    | NextPuzzleButtonFocused
    | ReplayTick Time.Posix
    | ActionSent (Result Http.Error ())


flagsDecoder : Decode.Decoder DecodedFlags
flagsDecoder =
    Decode.string
        |> Decode.andThen
            (\dsl ->
                case PuzzleFlagDsl.parsePuzzleFlag dsl of
                    Ok flag ->
                        case flag.puzzles of
                            [] ->
                                Decode.fail "puzzle flag: catalog is empty"

                            entries ->
                                Decode.succeed
                                    { sessionId = flag.sessionId
                                    , puzzles = List.map freshPuzzle entries
                                    }

                    Err msg ->
                        Decode.fail msg
            )


freshPuzzle : PuzzleFlagDsl.CatalogEntry -> Puzzle
freshPuzzle entry =
    { name = entry.name
    , initialBoard = entry.board
    , board = entry.board
    , actionLog = []
    , nextSeq = 1
    }


init : Decode.Value -> ( Model, Cmd Msg )
init flagsValue =
    case Decode.decodeValue flagsDecoder flagsValue of
        Ok flags ->
            ( { puzzles = Array.fromList flags.puzzles
              , currentIndex = 0
              , drag = NotDragging
              , boardRect = Nothing
              , status = { text = "Drag stacks to merge or move them.", kind = Inform }
              , gameId = "puzzle"
              , sessionId = flags.sessionId
              , replayState = Nothing
              , congratsVisible = False
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



-- CURRENT-PUZZLE HELPERS


currentPuzzle : Model -> Puzzle
currentPuzzle model =
    case Array.get model.currentIndex model.puzzles of
        Just p ->
            p

        Nothing ->
            Debug.todo
                ("Puzzle.currentPuzzle: currentIndex "
                    ++ String.fromInt model.currentIndex
                    ++ " out of bounds (init refuses empty catalogs; stepIndex uses modBy)"
                )


withCurrentPuzzle : (Puzzle -> Puzzle) -> Model -> Model
withCurrentPuzzle f model =
    { model
        | puzzles =
            Array.set model.currentIndex (f (currentPuzzle model)) model.puzzles
    }


{-| Wrap-around step. `+1` → next, `-1` → prev, modulo catalog
size. Always returns a valid index because init guards on an
empty catalog.
-}
stepIndex : Int -> Model -> Int
stepIndex delta model =
    let
        n =
            Array.length model.puzzles
    in
    if n == 0 then
        0

    else
        modBy n (model.currentIndex + delta)


{-| Switch to a different puzzle. Drops in-flight UI state
(drag, replay) since they belong to the puzzle you're leaving;
per-puzzle game state (board, log, seq) is preserved in the
dict. The status bar resets to the play prompt.
-}
navigateTo : Int -> Model -> Model
navigateTo idx model =
    { model
        | currentIndex = idx
        , drag = NotDragging
        , replayState = Nothing
        , status = { text = "Drag stacks to merge or move them.", kind = Inform }
        , congratsVisible = False
    }



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
                                    , board = (currentPuzzle model).board
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
                        puzzle =
                            currentPuzzle model

                        outcome =
                            BoardDrag.handleMouseUp releasePoint
                                tMs
                                d
                                { board = puzzle.board
                                , boardRect = model.boardRect
                                , actionLog = puzzle.actionLog
                                , nextSeq = puzzle.nextSeq
                                }

                        modelAfterDrag =
                            { model | drag = NotDragging, status = outcome.status }
                                |> withCurrentPuzzle
                                    (\p ->
                                        { p
                                            | board = outcome.board
                                            , actionLog = outcome.actionLog
                                            , nextSeq = outcome.nextSeq
                                        }
                                    )
                    in
                    case outcome.outboundPayload of
                        Nothing ->
                            -- Drag rejected (off-board). The scold
                            -- status in modelAfterDrag is the only
                            -- visible response.
                            ( modelAfterDrag, Cmd.none )

                        Just payload ->
                            let
                                httpPostForAction =
                                    Http.post
                                        { url =
                                            "/gopher/puzzle/sessions/"
                                                ++ String.fromInt model.sessionId
                                                ++ "/puzzles/"
                                                ++ String.fromInt model.currentIndex
                                                ++ "/actions"
                                        , body = Http.stringBody "text/plain" payload
                                        , expect = Http.expectWhatever ActionSent
                                        }
                            in
                            case Status.isCleanBoard outcome.board of
                                False ->
                                    ( modelAfterDrag, httpPostForAction )

                                True ->
                                    ( modelAfterDrag
                                    , Cmd.batch
                                        [ httpPostForAction
                                        , Task.succeed () |> Task.perform (always PuzzleSolved)
                                        ]
                                    )

        ClickPrevPuzzle ->
            ( navigateTo (stepIndex -1 model) model, Cmd.none )

        ClickNextPuzzle ->
            ( navigateTo (stepIndex 1 model) model, Cmd.none )

        PuzzleSolved ->
            ( { model | congratsVisible = True }
            , Browser.Dom.focus congratsNextButtonId
                |> Task.attempt (always NextPuzzleButtonFocused)
            )

        ClickAdvanceFromSolvedPuzzle ->
            ( navigateTo (stepIndex 1 model) model, Cmd.none )

        NextPuzzleButtonFocused ->
            ( model, Cmd.none )

        ClickUndo ->
            let
                puzzle =
                    currentPuzzle model

                actionLog =
                    puzzle.actionLog

                liveActions =
                    ActionLog.collapseUndos actionLog
            in
            case List.reverse liveActions of
                [] ->
                    ( model, Cmd.none )

                lastLive :: _ ->
                    let
                        nextLog =
                            actionLog ++ [ { action = GameEvent.Undo } ]

                        nextBoard =
                            undoForPuzzle lastLive.action puzzle.board

                        nextModel =
                            { model | congratsVisible = False }
                                |> withCurrentPuzzle
                                    (\p ->
                                        { p
                                            | actionLog = nextLog
                                            , board = nextBoard
                                            , nextSeq = p.nextSeq + 1
                                        }
                                    )

                        httpPostForAction =
                            Http.post
                                { url =
                                    "/gopher/puzzle/sessions/"
                                        ++ String.fromInt model.sessionId
                                        ++ "/puzzles/"
                                        ++ String.fromInt model.currentIndex
                                        ++ "/actions"
                                , body = Http.stringBody "text/plain" (GameEvent.undoDsl puzzle.nextSeq)
                                , expect = Http.expectWhatever ActionSent
                                }
                    in
                    ( nextModel, httpPostForAction )

        ClickReset ->
            let
                puzzle =
                    currentPuzzle model

                nextModel =
                    { model
                        | congratsVisible = False
                        , drag = NotDragging
                        , replayState = Nothing
                        , status = { text = "Reset.", kind = Inform }
                    }
                        |> withCurrentPuzzle
                            (\p ->
                                { p
                                    | board = p.initialBoard
                                    , actionLog = []
                                    , nextSeq = p.nextSeq + 1
                                }
                            )

                httpPostForAction =
                    Http.post
                        { url =
                            "/gopher/puzzle/sessions/"
                                ++ String.fromInt model.sessionId
                                ++ "/puzzles/"
                                ++ String.fromInt model.currentIndex
                                ++ "/actions"
                        , body = Http.stringBody "text/plain" (String.fromInt puzzle.nextSeq ++ ") reset")
                        , expect = Http.expectWhatever ActionSent
                        }
            in
            ( nextModel, httpPostForAction )

        ClickInstantReplay ->
            let
                puzzle =
                    currentPuzzle model
            in
            ( { model
                | replayState =
                    Just
                        (Animate.start
                            (ActionLog.collapseUndos puzzle.actionLog)
                            puzzle.initialBoard
                        )
                , drag = NotDragging
                , status = { text = "Replaying…", kind = Inform }
                , congratsVisible = False
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


{-| Reverse one board verb against the puzzle's board. Only
the three board verbs ever land here — Undo tokens get
stripped by `ActionLog.collapseUndos` upstream, and the puzzle
pipeline never appends the hand verbs (MergeHand / PlaceHand)
or CompleteTurn.
-}
undoForPuzzle : GameEvent -> List CardStack -> List CardStack
undoForPuzzle event board =
    case event of
        Split p ->
            Execute.undoSplit p.stack p.cardIndex board

        MergeStack p ->
            Execute.undoMergeStack p.source p.target p.side board

        MoveStack p ->
            Execute.undoMoveStack p.stack p.newLoc board

        _ ->
            Debug.todo
                ("Puzzle.undoForPuzzle: non-board-verb event reached undo (collapseUndos should have stripped Undo); got "
                    ++ Debug.toString event
                )


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
                    ( (currentPuzzle model).board, model.drag )

        boardFloaters =
            case drag of
                DraggingBoardCard d ->
                    [ Drag.renderBoardFloater d [ style "position" "absolute" ] ]

                _ ->
                    []

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
        [ style "font-family" "system-ui, sans-serif"
        , style "position" "relative"
        ]
        [ Status.viewStatusBar model.status
        , div
            [ style "padding" "3px 20px 20px 20px"
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
                [ puzzleTitle model
                , undoButton model
                , replayButton model
                , resetButton model
                , prevButton model
                , nextButton model
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
        , congratsPopup model
        ]


{-| Focused on every transition to congratsVisible=True so
keyboard users can hit Enter to advance.
-}
congratsNextButtonId : String
congratsNextButtonId =
    "puzzle-congrats-next"


{-| Non-modal: nav header and board stay clickable behind it.
Enter activates the focused Next button (browser default for a
focused HTML button), firing ClickAdvanceFromSolvedPuzzle.
-}
congratsPopup : Model -> Html Msg
congratsPopup model =
    if not model.congratsVisible then
        text ""

    else
        div
            [ style "position" "fixed"
            , style "top" "70px"
            , style "left" "50%"
            , style "transform" "translateX(-50%)"
            , style "background" "white"
            , style "color" "black"
            , style "border" ("2px solid " ++ Colors.navy)
            , style "border-radius" "4px"
            , style "padding" "14px 20px"
            , style "box-shadow" "0 4px 12px rgba(0,0,0,0.15)"
            , style "z-index" "1000"
            , style "text-align" "center"
            , style "min-width" "320px"
            ]
            [ div
                [ style "font-size" "15px"
                , style "margin-bottom" "12px"
                ]
                [ text "You solved it!" ]
            , div
                [ style "display" "flex"
                , style "gap" "12px"
                , style "justify-content" "center"
                ]
                [ replayCongratsButton
                , nextPuzzleButton
                ]
            ]


replayCongratsButton : Html Msg
replayCongratsButton =
    Html.button
        [ Attr.type_ "button"
        , Events.onClick ClickInstantReplay
        , style "padding" "6px 14px"
        , style "font-size" "14px"
        , style "border" ("1px solid " ++ Colors.navy)
        , style "background" "white"
        , style "color" Colors.navy
        , style "border-radius" "3px"
        , style "cursor" "pointer"
        ]
        [ text "Replay" ]


nextPuzzleButton : Html Msg
nextPuzzleButton =
    Html.button
        [ Attr.type_ "button"
        , Attr.id congratsNextButtonId
        , Attr.autofocus True
        , Events.onClick ClickAdvanceFromSolvedPuzzle
        , style "padding" "6px 14px"
        , style "font-size" "14px"
        , style "font-weight" "600"
        , style "border" "2px solid #1b5e20"
        , style "background" "#2e7d32"
        , style "color" "white"
        , style "border-radius" "3px"
        , style "cursor" "pointer"

        -- Clear focus ring so the default-selected button is
        -- obvious to keyboard users at a glance.
        , style "outline" "3px solid #a5d6a7"
        , style "outline-offset" "1px"
        ]
        [ text "Next" ]


puzzleTitle : Model -> Html Msg
puzzleTitle model =
    div
        [ style "font-size" "17px"
        , style "color" Colors.navy
        , style "font-weight" "600"
        , style "padding-bottom" "4px"
        ]
        [ text ("Puzzle " ++ String.fromInt (model.currentIndex + 1)) ]


prevButton : Model -> Html Msg
prevButton model =
    if Array.length model.puzzles > 1 then
        Button.button "‹ Prev" ClickPrevPuzzle

    else
        Button.disabledButton "‹ Prev"


nextButton : Model -> Html Msg
nextButton model =
    if Array.length model.puzzles > 1 then
        Button.button "Next ›" ClickNextPuzzle

    else
        Button.disabledButton "Next ›"


replayDrag : Animate.AnimationState -> Drag.DragState
replayDrag rs =
    case rs.phase of
        Animate.AnimatingBoardAction state ->
            Drag.DraggingBoardCard state.dragInfo

        _ ->
            Drag.NotDragging


undoButton : Model -> Html Msg
undoButton model =
    if model.replayState == Nothing && canUndo (currentPuzzle model).actionLog then
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
            if List.isEmpty (ActionLog.collapseUndos (currentPuzzle model).actionLog) then
                Button.disabledButton "Replay"

            else
                Button.button "Replay" ClickInstantReplay


resetButton : Model -> Html Msg
resetButton model =
    if model.replayState == Nothing && not (List.isEmpty (currentPuzzle model).actionLog) then
        Button.button "Reset" ClickReset

    else
        Button.disabledButton "Reset"


main : Program Decode.Value Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
