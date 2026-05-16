port module Game exposing (main, update)

import Browser
import Browser.Dom
import Browser.Events
import Game.Msg exposing (Msg(..))
import Game.State
    exposing
        ( Model
        , baseModel
        , bootstrapFromBundle
        , lastUndoableAction
        )
import Game.View as View
import Game.Wire as Wire exposing (fetchActionLog, fetchNewSession)
import Html exposing (Html, div)
import Html.Attributes exposing (style)
import Json.Encode as Encode
import Lib.ActionLog as ActionLog
import Lib.Animation.Animate as Animate exposing (Phase(..))
import Lib.Animation.HandDragAnimate as HandDragAnimate
import Lib.BoardDrag as BoardDrag
import Lib.BoardGesture as BoardGesture
import Lib.BoardView exposing (boardDomIdFor)
import Lib.Dealer as Dealer
import Lib.Drag exposing (DragState(..))
import Lib.Engine as Engine
import Lib.Game as Game
import Lib.GameEvent as GameEvent
import Lib.Hand exposing (activeHand)
import Lib.HandDrag as HandDrag
import Lib.HandGesture as HandGesture
import Lib.InitialStateDsl as InitialStateDsl
import Lib.Physics.BoardGeometry exposing (refereeBounds)
import Lib.PointerInput as PointerInput
import Lib.Popup as Popup
import Lib.Random as Random
import Lib.Status as Status exposing (StatusKind(..))
import Lib.TurnControl as TurnControl
import Task
import Time



-- FLAGS


type alias Flags =
    { initialSessionId : Maybe Int
    , seedSource : Int
    }



-- PORTS


port setSessionPath : String -> Cmd msg


port engineRequest : Encode.Value -> Cmd msg


port gameHintResponse : (Encode.Value -> msg) -> Sub msg


port agentStepResponse : (Encode.Value -> msg) -> Sub msg



-- INIT


init : Flags -> ( Model, Cmd Msg )
init flags =
    case flags.initialSessionId of
        Just sid ->
            ( { baseModel
                | sessionId = Just sid
                , status =
                    { text = "Resuming session " ++ String.fromInt sid ++ "…"
                    , kind = Inform
                    }
              }
            , fetchActionLog sid
            )

        Nothing ->
            let
                setup =
                    Dealer.dealFullGame (Random.initSeed flags.seedSource)

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



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ReadyForAgentTurn ->
            let
                reqId =
                    model.nextEngineRequestId

                hand =
                    (activeHand model.gameState).handCards
                        |> List.map .card

                payload =
                    Engine.buildAgentStepRequest reqId model.gameState.board hand
            in
            ( { model
                | popup = Nothing
                , agentTurnActive = True
                , pendingEngineRequest = Just reqId
                , nextEngineRequestId = reqId + 1
                , status = { text = "Thinking…", kind = Inform }
              }
            , engineRequest payload
            )

        ReadyForHumanTurn ->
            ( { model | popup = Nothing, agentTurnActive = False }
            , Cmd.none
            )

        ContinueHumanTurn ->
            ( { model | popup = Nothing }
            , Cmd.none
            )

        ActionSent (Ok ()) ->
            ( model, Cmd.none )

        ActionSent (Err err) ->
            let
                _ =
                    Debug.log "ActionSent err" err
            in
            ( { model | status = Status.actionRejectedStatus }, Cmd.none )

        SessionReceived (Ok sid) ->
            -- Session id allocated by the server. State was
            -- already dealt locally during NewSession init.
            ( { model | sessionId = Just sid }
            , setSessionPath (String.fromInt sid)
            )

        SessionReceived (Err err) ->
            let
                _ =
                    Debug.log "SessionReceived err" err
            in
            ( { model | status = Status.sessionAllocFailedStatus }, Cmd.none )

        ActionLogFetched (Ok ( initialState, actions )) ->
            ( bootstrapFromBundle initialState actions model, Cmd.none )

        ActionLogFetched (Err err) ->
            let
                _ =
                    Debug.log "ActionLogFetched err" err
            in
            ( { model | status = Status.actionLogFetchFailedStatus }, Cmd.none )

        ClickInstantReplay ->
            if model.agentTurnActive then
                -- No-op during agent's turn — replay and the
                -- agent's move share the single animationState
                -- slot. View hides the button via
                -- `controlsEnabled` so this is double-protection.
                ( model, Cmd.none )

            else
                ( { model
                    | animationState =
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
                )

        ClickReplayPauseToggle ->
            ( { model | animationState = Maybe.map Animate.togglePause model.animationState }
            , Cmd.none
            )

        HandCardRectReceived (Ok ( handElement, boardElement, posix )) ->
            let
                tMs =
                    Time.posixToMillis posix

                applyMeasurement rs =
                    case rs.phase of
                        AnimatingHandAction handState ->
                            { rs
                                | phase =
                                    AnimatingHandAction
                                        (HandDragAnimate.measurementReceived
                                            tMs
                                            handElement
                                            boardElement
                                            handState
                                        )
                            }

                        _ ->
                            rs
            in
            ( { model | animationState = Maybe.map applyMeasurement model.animationState }
            , Cmd.none
            )

        HandCardRectReceived (Err err) ->
            let
                _ =
                    Debug.log "HandCardRectReceived err" err
            in
            ( model, Cmd.none )

        BoardRectReceived (Ok element) ->
            let
                rect =
                    { x = round (element.element.x - element.viewport.x)
                    , y = round (element.element.y - element.viewport.y)
                    , width = round element.element.width
                    , height = round element.element.height
                    }
            in
            ( { model | boardRect = Just rect }, Cmd.none )

        BoardRectReceived (Err err) ->
            let
                _ =
                    Debug.log "BoardRectReceived err" err
            in
            ( model, Cmd.none )

        ClickHint ->
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
            , engineRequest payload
            )

        AnimationTick nowPosix ->
            case model.animationState of
                Nothing ->
                    ( model, Cmd.none )

                Just rs ->
                    let
                        config =
                            { measureMsg = HandCardRectReceived
                            , gameId = model.gameId
                            }
                    in
                    case Animate.tick config (Time.posixToMillis nowPosix) rs of
                        Animate.StillReplaying nextRs cmd ->
                            ( { model | animationState = Just nextRs }, cmd )

                        Animate.Completed ->
                            if model.agentTurnActive then
                                let
                                    reqId =
                                        model.nextEngineRequestId

                                    hand =
                                        (activeHand rs.gameState).handCards
                                            |> List.map .card

                                    payload =
                                        Engine.buildAgentStepRequest reqId rs.gameState.board hand
                                in
                                ( { model
                                    | animationState = Nothing
                                    , gameState = rs.gameState
                                    , actionLog = model.actionLog ++ rs.entries
                                    , nextSeq = model.nextSeq + List.length rs.entries
                                    , pendingEngineRequest = Just reqId
                                    , nextEngineRequestId = reqId + 1
                                    , status = { text = "Thinking…", kind = Inform }
                                  }
                                , engineRequest payload
                                )

                            else
                                ( { model
                                    | animationState = Nothing
                                    , status = { text = "Replay completed! Continue playing.", kind = Inform }
                                  }
                                , Cmd.none
                                )

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
                    )

                _ ->
                    ( model, Cmd.none )

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

                DraggingHandCard d ->
                    let
                        ( nextD, nextStatus ) =
                            HandGesture.mouseMove pos d model.boardRect model.status
                    in
                    ( { model | drag = DraggingHandCard nextD, status = nextStatus }
                    , Cmd.none
                    )

                NotDragging ->
                    ( model, Cmd.none )

        MouseUp pos tMs ->
            case model.drag of
                NotDragging ->
                    ( model, Cmd.none )

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
                    )

        ClickCompleteTurn ->
            case TurnControl.attemptCompleteTurn { gameState = model.gameState, nextSeq = model.nextSeq } of
                TurnControl.TurnRejected r ->
                    ( { model
                        | status = r.status
                        , popup = Just { content = r.popup, dismissMsg = ContinueHumanTurn }
                      }
                    , Cmd.none
                    )

                TurnControl.TurnCompleted r ->
                    ( { model
                        | gameState = r.newGameState
                        , actionLog = model.actionLog ++ [ r.appendedEntry ]
                        , nextSeq = model.nextSeq + 1
                        , status = r.status
                        , popup = Just { content = r.popup, dismissMsg = ReadyForAgentTurn }
                      }
                    , Wire.sendAction model.sessionId r.outboundPayload
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
                    ( model, Cmd.none )

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
                    )

        HintLinesReceived [] ->
            ( { model
                | pendingEngineRequest = Nothing
                , hintedCards = []
                , status = { text = "No hint — no obvious play for this hand on this board.", kind = Inform }
              }
            , Cmd.none
            )

        HintLinesReceived lines ->
            ( { model
                | pendingEngineRequest = Nothing
                , hintedCards = []
                , status = { text = String.join "\n" lines, kind = Inform }
              }
            , Cmd.none
            )

        AgentMovesReceived [] ->
            let
                ( afterTurn, _ ) =
                    Game.applyCompleteTurn refereeBounds model.gameState

                agentDonePopup : Popup.PopupContent
                agentDonePopup =
                    { admin = "Oliver"
                    , body = "The agent has completed its turn.\n\nYour move!"
                    }
            in
            ( { model
                | pendingEngineRequest = Nothing
                , gameState = afterTurn
                , actionLog = model.actionLog ++ [ { action = GameEvent.CompleteTurn } ]
                , nextSeq = model.nextSeq + 1
                , popup = Just { content = agentDonePopup, dismissMsg = ReadyForHumanTurn }
                , status = { text = "The agent has completed its turn.", kind = Inform }
              }
            , Cmd.none
            )

        AgentMovesReceived events ->
            let
                entries =
                    List.map (\e -> { action = e }) events

                anim =
                    Animate.start entries model.gameState
            in
            ( { model
                | pendingEngineRequest = Nothing
                , animationState = Just anim
              }
            , Cmd.none
            )

        EngineResponseFailed detail ->
            ( { model
                | pendingEngineRequest = Nothing
                , status = { text = detail, kind = Scold }
              }
            , Cmd.none
            )

        EngineResponseStale ->
            ( model, Cmd.none )



-- VIEW


view : Model -> Html Msg
view model =
    -- Viewport-filling shell. View.view is embeddable (a
    -- 1100x700 `position: relative` box); we center and scroll
    -- it inside the full browser viewport.
    div
        [ style "position" "fixed"
        , style "top" "0"
        , style "left" "0"
        , style "right" "0"
        , style "bottom" "0"
        , style "overflow" "auto"
        , style "background" "#f4f4ec"
        ]
        [ View.view model ]



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    let
        dragSubscriptions =
            case model.drag of
                NotDragging ->
                    Sub.none

                _ ->
                    Sub.batch
                        [ Browser.Events.onMouseMove (PointerInput.mouseMoveDecoder MouseMove)
                        , Browser.Events.onMouseUp (PointerInput.mouseUpDecoder MouseUp)
                        ]

        animationSubscription =
            case model.animationState of
                Nothing ->
                    Sub.none

                Just rs ->
                    if rs.paused then
                        Sub.none

                    else
                        Browser.Events.onAnimationFrame AnimationTick
    in
    Sub.batch
        [ dragSubscriptions
        , animationSubscription
        , gameHintResponse (hintMsgFor << Engine.decodeHintResponse model.pendingEngineRequest)
        , agentStepResponse (agentStepMsgFor << Engine.decodeAgentStepResponse model.pendingEngineRequest)
        ]


hintMsgFor : Engine.HintResponse -> Msg
hintMsgFor response =
    case response of
        Engine.HintLines lines ->
            HintLinesReceived lines

        Engine.HintError detail ->
            EngineResponseFailed ("Engine error: " ++ detail)

        Engine.HintDecodeError err ->
            EngineResponseFailed ("Engine game-hint response could not be decoded: " ++ err)

        Engine.HintStaleId ->
            EngineResponseStale


agentStepMsgFor : Engine.AgentStepResponse -> Msg
agentStepMsgFor response =
    case response of
        Engine.AgentStepEvents events ->
            AgentMovesReceived events

        Engine.AgentStepError detail ->
            EngineResponseFailed ("Agent error: " ++ detail)

        Engine.AgentStepDecodeError err ->
            EngineResponseFailed ("Agent response could not be decoded: " ++ err)

        Engine.AgentStepStaleId ->
            EngineResponseStale


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
