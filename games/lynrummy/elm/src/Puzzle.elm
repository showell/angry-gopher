module Puzzle exposing (main)

{-| Puzzle V3 — drag-aware single-puzzle surface.

Dedicated host: own Msg, own Model, no `Game.*` imports.
Composes `Lib.*` building blocks directly. Supports
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

import Array exposing (Array)
import Browser
import Browser.Dom
import Browser.Events
import Dict exposing (Dict)
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


{-| One catalog entry. `initialBoard` is the dirty board the
user starts each attempt from. The name is shown in the header.
-}
type alias Puzzle =
    { name : String
    , initialBoard : List CardStack
    }


{-| Per-puzzle working state. When the user navigates away and
back, this dict-lookup preserves their progress on every puzzle
they've touched. Fresh puzzles synthesize a default state
(initial board, empty log, seq=1) on first read.
-}
type alias PuzzleState =
    { board : List CardStack
    , actionLog : List ActionLogEntry
    , nextSeq : Int
    }


type alias Model =
    { puzzles : Array Puzzle
    , currentIndex : Int
    , puzzleState : Dict Int PuzzleState
    , lastPostedIndex : Maybe Int
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
    | ClickInstantReplay
    | ClickReplayPauseToggle
    | PuzzleSolved
    | ClickStayOnSolvedPuzzle
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

                            puzzles ->
                                Decode.succeed
                                    { sessionId = flag.sessionId
                                    , puzzles =
                                        List.map
                                            (\p -> { name = p.name, initialBoard = p.board })
                                            puzzles
                                    }

                    Err msg ->
                        Decode.fail msg
            )


init : Decode.Value -> ( Model, Cmd Msg )
init flagsValue =
    case Decode.decodeValue flagsDecoder flagsValue of
        Ok flags ->
            ( { puzzles = Array.fromList flags.puzzles
              , currentIndex = 0
              , puzzleState = Dict.empty
              , lastPostedIndex = Nothing
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
--
-- All per-puzzle reads/writes route through these. `currentPuzzle`
-- returns the catalog entry at `currentIndex`; `currentState` returns
-- the user's working state for that puzzle, synthesizing a fresh
-- state on first read. `withCurrentState` writes back to the dict.


currentPuzzle : Model -> Puzzle
currentPuzzle model =
    Array.get model.currentIndex model.puzzles
        |> Maybe.withDefault emptyPuzzle


emptyPuzzle : Puzzle
emptyPuzzle =
    -- Init guards on an empty catalog, so this is the
    -- unreachable branch of the Array.get above. Kept harmless
    -- rather than Debug.todo so the type-check stays clean.
    { name = "(empty)"
    , initialBoard = []
    }


currentState : Model -> PuzzleState
currentState model =
    Dict.get model.currentIndex model.puzzleState
        |> Maybe.withDefault (freshState (currentPuzzle model))


freshState : Puzzle -> PuzzleState
freshState puzzle =
    { board = puzzle.initialBoard
    , actionLog = []
    , nextSeq = 1
    }


withCurrentState : (PuzzleState -> PuzzleState) -> Model -> Model
withCurrentState f model =
    { model
        | puzzleState =
            Dict.insert model.currentIndex (f (currentState model)) model.puzzleState
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
                                    , board = (currentState model).board
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
                        state =
                            currentState model

                        outcome =
                            BoardDrag.handleMouseUp releasePoint
                                tMs
                                d
                                { board = state.board
                                , boardRect = model.boardRect
                                , actionLog = state.actionLog
                                , nextSeq = state.nextSeq
                                }

                        modelAfterDrag =
                            { model | drag = NotDragging, status = outcome.status }
                                |> withCurrentState
                                    (\s ->
                                        { s
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
                                        { url = "/gopher/puzzle/sessions/" ++ String.fromInt model.sessionId ++ "/actions"
                                        , body = Http.stringBody "text/plain" (puzzleBlockBody model payload)
                                        , expect = Http.expectWhatever ActionSent
                                        }

                                postedModel =
                                    { modelAfterDrag | lastPostedIndex = Just model.currentIndex }
                            in
                            case Status.isCleanBoard outcome.board of
                                False ->
                                    ( postedModel, httpPostForAction )

                                True ->
                                    ( postedModel
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

        ClickStayOnSolvedPuzzle ->
            ( { model | congratsVisible = False }, Cmd.none )

        ClickAdvanceFromSolvedPuzzle ->
            ( navigateTo (stepIndex 1 model) model, Cmd.none )

        NextPuzzleButtonFocused ->
            ( model, Cmd.none )

        ClickUndo ->
            let
                state =
                    currentState model
            in
            if not (canUndo state.actionLog) then
                ( model, Cmd.none )

            else
                let
                    nextLog =
                        state.actionLog ++ [ { action = GameEvent.Undo } ]

                    effective =
                        ActionLog.collapseUndos nextLog

                    initialBoard =
                        (currentPuzzle model).initialBoard

                    nextModel =
                        { model
                            | congratsVisible = False
                            , lastPostedIndex = Just model.currentIndex
                        }
                            |> withCurrentState
                                (\s ->
                                    { s
                                        | actionLog = nextLog
                                        , board =
                                            List.foldl applyForPuzzle
                                                initialBoard
                                                (List.map .action effective)
                                        , nextSeq = s.nextSeq + 1
                                    }
                                )

                    httpPostForAction =
                        Http.post
                            { url = "/gopher/puzzle/sessions/" ++ String.fromInt model.sessionId ++ "/actions"
                            , body = Http.stringBody "text/plain" (puzzleBlockBody model (GameEvent.undoDsl state.nextSeq))
                            , expect = Http.expectWhatever ActionSent
                            }
                in
                ( nextModel, httpPostForAction )

        ClickInstantReplay ->
            let
                state =
                    currentState model
            in
            ( { model
                | replayState =
                    Just
                        (Animate.start
                            (ActionLog.collapseUndos state.actionLog)
                            (currentPuzzle model).initialBoard
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


{-| Apply one event to the puzzle's board. The puzzle's
universe of actions is just the three board verbs; any other
variant in the log signals a real bug, so we log loudly (the
existing convention in `Lib.Execute`).
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


{-| Format one action line for the session's actions.dsl POST.
When the active puzzle matches the one we last posted under,
the body is just the indented action; when it shifted (or this
is the first post of the session), a `puzzle <idx>` header
opens a fresh block:

    puzzle 0
      1) split [A♣ A♦ A♥] at (130,260) @2
      2) merge_stack [A♥] at ...
    puzzle 3
      1) push [...] at ...
    puzzle 0
      3) split [...] at ...

Per-puzzle seq is monotonic across re-entry (puzzle 0's third
action stays `3)`, not `1)`), so each block is replayable just
by re-walking it in order.

Callers are responsible for updating `lastPostedIndex` after
firing the POST.
-}
puzzleBlockBody : Model -> String -> String
puzzleBlockBody model line =
    if model.lastPostedIndex == Just model.currentIndex then
        "  " ++ line

    else
        "puzzle "
            ++ String.fromInt model.currentIndex
            ++ "\n  "
            ++ line



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
                    ( (currentState model).board, model.drag )

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
        [ style "font-family" "system-ui, sans-serif"
        , style "position" "relative"
        ]
        [ puzzleNavHeader model
        , Status.viewStatusBar model.status
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
        , congratsPopup model
        ]


{-| DOM id for the popup's default-action button. We focus
this on every transition to congratsVisible=True so keyboard
users can hit Enter to advance.
-}
congratsNextButtonId : String
congratsNextButtonId =
    "puzzle-congrats-next"


{-| Floating celebration card. Compact, near the top of the
viewport, conservative styling (navy border, white background,
black text). The Next-puzzle button is focused on every
transition to congratsVisible=True (see PuzzleSolved handler),
so the keyboard default action — Enter activates the focused
button — fires ClickAdvanceFromSolvedPuzzle. Non-modal: the
nav header and board stay clickable.
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
                [ text "You solved it! Hit Prev or Next for the next puzzle." ]
            , div
                [ style "display" "flex"
                , style "gap" "12px"
                , style "justify-content" "center"
                ]
                [ stayHereButton
                , nextPuzzleButton
                ]
            ]


stayHereButton : Html Msg
stayHereButton =
    Html.button
        [ Attr.type_ "button"
        , Events.onClick ClickStayOnSolvedPuzzle
        , style "padding" "6px 14px"
        , style "font-size" "14px"
        , style "border" ("1px solid " ++ Colors.navy)
        , style "background" "white"
        , style "color" Colors.navy
        , style "border-radius" "3px"
        , style "cursor" "pointer"
        ]
        [ text "Stay here" ]


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
        [ text "Next puzzle" ]


{-| Header strip above the board: Prev — counter + name — Next.
Counter is 1-indexed for humans ("3 / 21" reads cleaner than "2
/ 21"). Buttons are disabled when the catalog has 0 or 1
entries (nothing to navigate to).
-}
puzzleNavHeader : Model -> Html Msg
puzzleNavHeader model =
    let
        n =
            Array.length model.puzzles

        navigable =
            n > 1

        prev =
            if navigable then
                Button.button "‹ Prev" ClickPrevPuzzle

            else
                Button.disabledButton "‹ Prev"

        next =
            if navigable then
                Button.button "Next ›" ClickNextPuzzle

            else
                Button.disabledButton "Next ›"

        label =
            "puzzle "
                ++ String.fromInt (model.currentIndex + 1)
                ++ " / "
                ++ String.fromInt n
                ++ " — "
                ++ (currentPuzzle model).name
    in
    div
        [ style "padding" "12px 20px"
        , style "display" "flex"
        , style "align-items" "center"
        , style "gap" "16px"
        , style "border-bottom" "1px solid #ddd"
        , style "background" "#fafaf5"
        ]
        [ prev
        , div
            [ style "flex" "1"
            , style "text-align" "center"
            , style "font-family" "monospace"
            , style "font-size" "14px"
            , style "color" "#333"
            ]
            [ text label ]
        , next
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
    if model.replayState == Nothing && canUndo (currentState model).actionLog then
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
            if List.isEmpty (ActionLog.collapseUndos (currentState model).actionLog) then
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
