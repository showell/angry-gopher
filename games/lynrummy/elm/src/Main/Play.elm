module Main.Play exposing
    ( Config(..)
    , Output(..)
    , init
    , subscriptions
    , update
    , view
    )

{-| The live-play component for LynRummy. Contains the
update/view/subscriptions surface for the full-game UI.

`update` returns an `Output` value the host uses to decide
whether to fire its own port (URL-path updates when a new
session id arrives, engine-solve requests). Main.elm is a thin
harness that wraps this module, owns the ports, and routes
Output.

-}

import Browser.Dom
import Browser.Events
import Lib.ActionLog as ActionLog
import Lib.BoardDrag as BoardDrag
import Lib.BoardGesture as BoardGesture
import Lib.BoardView exposing (boardDomIdFor)
import Lib.Drag exposing (DragState(..))
import Lib.Engine as Engine
import Lib.Hand exposing (activeHand)
import Lib.TurnControl as TurnControl
import Lib.HandDrag as HandDrag
import Lib.HandGesture as HandGesture
import Lib.Dealer as Dealer
import Lib.Game as Game
import Lib.Random as Random
import Lib.Animation.Animate as Animate exposing (Phase(..))
import Lib.Animation.HandDragAnimate as HandDragAnimate
import Html exposing (Html)
import Json.Encode as Encode
import Lib.Status as Status exposing (StatusKind(..))
import Lib.PointerInput as PointerInput
import Main.Msg exposing (Msg(..))
import Lib.InitialStateDsl as InitialStateDsl
import Main.State
    exposing
        ( Model
        , baseModel
        , bootstrapFromBundle
        , lastUndoableAction
        )
import Main.View as View
import Main.Wire as Wire exposing (fetchActionLog, fetchNewSession)
import Task
import Time



-- CONFIG


{-| Bootstrap shapes Play can start in.

  - `NewSession seedSource` — no session yet; deal a fresh
    game locally (Elm is the autonomous dealer) using
    `seedSource` as PRNG entropy, then post the dealt
    `initial_state` to the server so reloads can resume.
  - `ResumeSession sid` — URL says we're resuming session
    `sid`; fetch its action log and `initial_state` from
    the server.

-}
type Config
    = NewSession Int
    | ResumeSession Int



-- OUTPUT


{-| Emitted from `update` when the host (Main.elm or the
Puzzles gallery) needs to do something beyond what Play
can do for itself. Today there's one case — fire the host's
port to pin the session id into the URL — plus the default
no-op.
-}
type Output
    = NoOutput
    | SessionChanged Int
    | EngineSolveRequested Encode.Value



-- INIT


{-| Boot state from a Config. Each variant fires its own Cmd;
the resulting Model shape is the same (an empty baseModel
that the bundle fetch will hydrate once it arrives).
-}
init : Config -> ( Model, Cmd Msg )
init config =
    case config of
        NewSession seedSource ->
            let
                setup =
                    Dealer.dealFullGame (Random.initSeed seedSource)

                initialRS : Game.GameState
                initialRS =
                    { board = setup.board
                    , hands = setup.hands
                    , activePlayerIndex = 0
                    , turnIndex = 0
                    , deck = setup.deck
                    , cardsPlayedThisTurn = 0
                    , victorAwarded = False
                    }

                dealtModel =
                    { baseModel
                        | gameState = initialRS
                        , initialGameState = initialRS
                    }
            in
            ( dealtModel, fetchNewSession (InitialStateDsl.formatGameState initialRS) )

        ResumeSession sid ->
            ( { baseModel
                | sessionId = Just sid
                , status =
                    { text =
                        "Resuming session " ++ String.fromInt sid ++ "…"
                    , kind = Inform
                    }
              }
            , fetchActionLog sid
            )



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg, Output )
update msg model =
    case msg of
        PopupOk ->
            ( { model | popup = Nothing }, Cmd.none, NoOutput )

        ActionSent (Ok ()) ->
            ( model, Cmd.none, NoOutput )

        ActionSent (Err err) ->
            let
                _ =
                    Debug.log "ActionSent err" err
            in
            ( { model | status = Status.actionRejectedStatus }, Cmd.none, NoOutput )

        SessionReceived (Ok sid) ->
            -- Session id allocated by the server. State was
            -- already dealt locally during NewSession init.
            ( { model | sessionId = Just sid }
            , Cmd.none
            , SessionChanged sid
            )

        SessionReceived (Err err) ->
            let
                _ =
                    Debug.log "SessionReceived err" err
            in
            ( { model | status = Status.sessionAllocFailedStatus }, Cmd.none, NoOutput )

        ActionLogFetched (Ok ( initialState, actions )) ->
            ( bootstrapFromBundle initialState actions model, Cmd.none, NoOutput )

        ActionLogFetched (Err err) ->
            let
                _ =
                    Debug.log "ActionLogFetched err" err
            in
            ( { model | status = Status.actionLogFetchFailedStatus }, Cmd.none, NoOutput )

        ClickInstantReplay ->
            ( { model
                | replayState =
                    Just
                        (Animate.start
                            (ActionLog.collapseUndos model.actionLog)
                            model.initialGameState
                        )
                , drag = NotDragging
                , status = { text = "Replaying…", kind = Inform }
              }
            , -- Hand animations measure the board fresh per
              -- action (bundled with the hand card rect) so
              -- a scroll between actions doesn't desync the
              -- two endpoints. Nothing to fetch at click time.
              Cmd.none
            , NoOutput
            )

        ClickReplayPauseToggle ->
            ( { model | replayState = Maybe.map Animate.togglePause model.replayState }
            , Cmd.none
            , NoOutput
            )

        ReplayTick nowPosix ->
            case model.replayState of
                Nothing ->
                    ( model, Cmd.none, NoOutput )

                Just rs ->
                    let
                        config =
                            { measureMsg = HandCardRectReceived
                            , gameId = model.gameId
                            }
                    in
                    case Animate.tick config (Time.posixToMillis nowPosix) rs of
                        Animate.StillReplaying nextRs cmd ->
                            ( { model | replayState = Just nextRs }, cmd, NoOutput )

                        Animate.Completed ->
                            ( { model
                                | replayState = Nothing
                                , status = { text = "Replay completed! Continue playing.", kind = Inform }
                              }
                            , Cmd.none
                            , NoOutput
                            )

        HandCardRectReceived (Ok ( handElement, boardElement, posix )) ->
            case model.replayState of
                Just rs ->
                    case rs.phase of
                        AnimatingHandAction handState ->
                            let
                                nextPhase =
                                    AnimatingHandAction
                                        (HandDragAnimate.measurementReceived
                                            (Time.posixToMillis posix)
                                            handElement
                                            boardElement
                                            handState
                                        )
                            in
                            ( { model | replayState = Just { rs | phase = nextPhase } }
                            , Cmd.none
                            , NoOutput
                            )

                        _ ->
                            -- Late measurement: replay either completed or
                            -- pause-toggled past AwaitingMeasurement. Drop.
                            ( model, Cmd.none, NoOutput )

                Nothing ->
                    ( model, Cmd.none, NoOutput )

        HandCardRectReceived (Err err) ->
            let
                _ =
                    Debug.log "HandCardRectReceived err" err
            in
            ( model, Cmd.none, NoOutput )

        BoardRectReceived (Ok element) ->
            let
                rect =
                    { x = round (element.element.x - element.viewport.x)
                    , y = round (element.element.y - element.viewport.y)
                    , width = round element.element.width
                    , height = round element.element.height
                    }
            in
            ( { model | boardRect = Just rect }, Cmd.none, NoOutput )

        BoardRectReceived (Err err) ->
            let
                _ =
                    Debug.log "BoardRectReceived err" err
            in
            ( model, Cmd.none, NoOutput )

        ClickHint ->
            clickHint model

        GameHintReceived value ->
            ( handleHintResponse value model, Cmd.none, NoOutput )

        -- Pointer-gesture + wire-action cluster. MouseDown starts a
        -- drag and kicks off board-rect measurement; MouseMove
        -- advances the dragInfo's floater; MouseUp resolves into a
        -- wire action via BoardDrag / HandDrag.
        MouseDownOnBoardCard { stack, cardIndex, point, time } ->
            case model.drag of
                NotDragging ->
                    let
                        dragInfo =
                            BoardGesture.startBoardDragInfo
                                { stack = stack
                                , cardIndex = cardIndex
                                , cursor = point
                                , tMs = time
                                , board = model.gameState.board
                                }
                    in
                    ( { model | drag = DraggingBoardCard dragInfo }
                    , Browser.Dom.getElement (boardDomIdFor model.gameId)
                        |> Task.attempt BoardRectReceived
                    , NoOutput
                    )

                _ ->
                    ( model, Cmd.none, NoOutput )

        MouseDownOnHandCard { handCard, point } ->
            case model.drag of
                NotDragging ->
                    let
                        dragInfo =
                            HandGesture.startHandDragInfo
                                { handCard = handCard
                                , cursor = point
                                , board = model.gameState.board
                                }
                    in
                    ( { model | drag = DraggingHandCard dragInfo }
                    , Browser.Dom.getElement (boardDomIdFor model.gameId)
                        |> Task.attempt BoardRectReceived
                    , NoOutput
                    )

                _ ->
                    ( model, Cmd.none, NoOutput )

        MouseMove pos tMs ->
            case model.drag of
                DraggingBoardCard d ->
                    let
                        ( nextD, nextStatus ) =
                            BoardGesture.mouseMove pos tMs d model.status
                    in
                    ( { model | drag = DraggingBoardCard nextD, status = nextStatus }
                    , Cmd.none
                    , NoOutput
                    )

                DraggingHandCard d ->
                    let
                        ( nextD, nextStatus ) =
                            HandGesture.mouseMove pos d model.boardRect model.status
                    in
                    ( { model | drag = DraggingHandCard nextD, status = nextStatus }
                    , Cmd.none
                    , NoOutput
                    )

                NotDragging ->
                    ( model, Cmd.none, NoOutput )

        MouseUp pos tMs ->
            case model.drag of
                NotDragging ->
                    ( model, Cmd.none, NoOutput )

                DraggingBoardCard d ->
                    let
                        outcome =
                            BoardDrag.handleMouseUp pos
                                tMs
                                d
                                { board = model.gameState.board
                                , boardRect = model.boardRect
                                , actionLog = model.actionLog
                                , nextSeq = model.nextSeq
                                }

                        gs0 =
                            model.gameState
                    in
                    ( { model
                        | drag = NotDragging
                        , gameState = { gs0 | board = outcome.board }
                        , status = outcome.status
                        , actionLog = outcome.actionLog
                        , nextSeq = outcome.nextSeq
                      }
                    , outcome.outboundPayload
                        |> Maybe.map (Wire.sendAction model.sessionId)
                        |> Maybe.withDefault Cmd.none
                    , NoOutput
                    )

                DraggingHandCard d ->
                    let
                        outcome =
                            HandDrag.handleMouseUp pos
                                d
                                { gameState = model.gameState
                                , boardRect = model.boardRect
                                , actionLog = model.actionLog
                                , nextSeq = model.nextSeq
                                }

                        gs0 =
                            model.gameState
                    in
                    ( { model
                        | drag = NotDragging
                        , gameState =
                            { gs0
                                | board = outcome.board
                                , hands = outcome.hands
                                , cardsPlayedThisTurn = outcome.cardsPlayedThisTurn
                            }
                        , status = outcome.status
                        , actionLog = outcome.actionLog
                        , nextSeq = outcome.nextSeq
                      }
                    , outcome.outboundPayload
                        |> Maybe.map (Wire.sendAction model.sessionId)
                        |> Maybe.withDefault Cmd.none
                    , NoOutput
                    )

        ClickCompleteTurn ->
            case TurnControl.attemptCompleteTurn { gameState = model.gameState, nextSeq = model.nextSeq } of
                TurnControl.TurnRejected r ->
                    ( { model | status = r.status, popup = Just r.popup }, Cmd.none, NoOutput )

                TurnControl.TurnCompleted r ->
                    ( { model
                        | gameState = r.newGameState
                        , actionLog = model.actionLog ++ [ r.appendedEntry ]
                        , nextSeq = model.nextSeq + 1
                        , status = r.status
                        , popup = Just r.popup
                      }
                    , Wire.sendAction model.sessionId r.outboundPayload
                    , NoOutput
                    )

        ClickUndo ->
            case
                TurnControl.attemptUndo
                    { gameState = model.gameState
                    , lastUndoableAction = lastUndoableAction model.actionLog
                    , nextSeq = model.nextSeq
                    }
            of
                TurnControl.NothingToUndo ->
                    ( model, Cmd.none, NoOutput )

                TurnControl.DidUndo r ->
                    ( { model
                        | gameState = r.newGameState
                        , actionLog = model.actionLog ++ [ r.appendedEntry ]
                        , nextSeq = model.nextSeq + 1
                        , status = { text = "Undone.", kind = Inform }
                        , hintedCards = []
                        , drag = NotDragging
                      }
                    , Wire.sendAction model.sessionId r.outboundPayload
                    , NoOutput
                    )


-- UPDATE HELPERS


clickHint : Model -> ( Model, Cmd Msg, Output )
clickHint model =
    let
        reqId =
            model.nextEngineRequestId

        hand =
            (activeHand model.gameState).handCards
                |> List.map .card

        payload =
            Engine.buildGameHintRequest reqId hand model.gameState.board
    in
    ( { model
        | hintedCards = []
        , pendingEngineRequest = Just reqId
        , nextEngineRequestId = reqId + 1
        , status = { text = "Thinking…", kind = Inform }
      }
    , Cmd.none
    , EngineSolveRequested payload
    )


handleHintResponse : Encode.Value -> Model -> Model
handleHintResponse value model =
    case Engine.decodeHintResponse model.pendingEngineRequest value of
        Engine.HintStaleId ->
            model

        Engine.HintError detail ->
            { model
                | pendingEngineRequest = Nothing
                , status = { text = "Engine error: " ++ detail, kind = Scold }
            }

        Engine.HintLines [] ->
            { model
                | pendingEngineRequest = Nothing
                , hintedCards = []
                , status = { text = "No hint — no obvious play for this hand on this board.", kind = Inform }
            }

        Engine.HintLines lines ->
            { model
                | pendingEngineRequest = Nothing
                , hintedCards = []
                , status = { text = String.join "\n" lines, kind = Inform }
            }

        Engine.HintDecodeError err ->
            let
                _ =
                    Debug.log "handleHintResponse decode err" err
            in
            { model
                | pendingEngineRequest = Nothing
                , status = { text = "Engine game-hint response could not be decoded — see console.", kind = Scold }
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


{-| Subscribe to per-frame ticks while a replay is in flight
and not paused. The handler in `update` extracts `nowMs` and
delegates to `Animate.tick`.
-}
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
view =
    View.view










