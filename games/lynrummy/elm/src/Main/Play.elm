module Main.Play exposing
    ( Config(..)
    , Output(..)
    , init
    , mouseMove
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
import Game.ActionLog as ActionLog
import Game.BoardDrag as BoardDrag
import Game.BoardGesture as BoardGesture
import Game.Drag exposing (DragState(..))
import Game.Engine as Engine
import Game.Hand exposing (activeHand)
import Game.TurnControl as TurnControl
import Game.HandDrag as HandDrag
import Game.HandGesture as HandGesture
import Game.Dealer as Dealer
import Game.Game as Game
import Game.Random as Random
import Game.Replay.Animate as Animate
import Html exposing (Html)
import Http
import Json.Encode as Encode
import Game.Status as Status exposing (StatusKind(..), StatusMessage)
import Game.PointerInput as PointerInput
import Main.Gesture
    exposing
        ( startBoardCardDrag
        , startHandDrag
        )
import Main.Msg exposing (Msg(..))
import Main.State
    exposing
        ( Model
        , baseModel
        , bootstrapFromBundle
        , encodeGameState
        , lastUndoableAction
        )
import Game.Point exposing (Point)
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
            ( dealtModel, fetchNewSession (encodeGameState initialRS) )

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
        MouseDownOnBoardCard { stack, cardIndex, point, time } ->
            withNoOutput
                (startBoardCardDrag
                    { stack = stack, cardIndex = cardIndex }
                    point
                    time
                    model
                )

        MouseDownOnHandCard { card, point } ->
            withNoOutput (startHandDrag card point model)

        MouseMove pos tMs ->
            ( mouseMove pos tMs model, Cmd.none, NoOutput )

        MouseUp pos tMs ->
            withNoOutput (handleMouseUp pos tMs model)

        ActionSent (Ok ()) ->
            ( model, Cmd.none, NoOutput )

        ActionSent (Err err) ->
            logAndScold "ActionSent" err Status.actionRejectedStatus model

        SessionReceived (Ok sid) ->
            -- Session id allocated by the server. State was
            -- already dealt locally during NewSession init.
            ( { model | sessionId = Just sid }
            , Cmd.none
            , SessionChanged sid
            )

        SessionReceived (Err err) ->
            logAndScold "SessionReceived" err Status.sessionAllocFailedStatus model

        ClickCompleteTurn ->
            withNoOutput (clickCompleteTurn model)

        ClickUndo ->
            withNoOutput (clickUndo model)

        PopupOk ->
            ( { model | popup = Nothing }, Cmd.none, NoOutput )

        ClickInstantReplay ->
            withNoOutput
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
                , Cmd.none
                )

        ClickReplayPauseToggle ->
            withNoOutput
                ( { model | replayState = Maybe.map Animate.togglePause model.replayState }
                , Cmd.none
                )

        ReplayTick nowPosix ->
            case model.replayState of
                Nothing ->
                    withNoOutput ( model, Cmd.none )

                Just rs ->
                    case Animate.tick (Time.posixToMillis nowPosix) rs of
                        Animate.StillReplaying nextRs ->
                            withNoOutput
                                ( { model | replayState = Just nextRs }, Cmd.none )

                        Animate.Completed ->
                            withNoOutput ( model, dispatchSelf ReplayCompleted )

        ReplayCompleted ->
            withNoOutput
                ( { model
                    | replayState = Nothing
                    , status = { text = "Replay completed! Continue playing.", kind = Inform }
                  }
                , Cmd.none
                )

        ActionLogFetched (Ok bundle) ->
            ( bootstrapFromBundle bundle model, Cmd.none, NoOutput )

        ActionLogFetched (Err err) ->
            logAndScold "ActionLogFetched" err Status.actionLogFetchFailedStatus model

        BoardRectReceived result ->
            withNoOutput (boardRectReceived result model)

        ClickHint ->
            clickHint model

        GameHintReceived value ->
            withNoOutput (handleHintResponse value model)


withNoOutput : ( Model, Cmd Msg ) -> ( Model, Cmd Msg, Output )
withNoOutput ( m, c ) =
    ( m, c, NoOutput )


{-| Fire a Msg into our own update on the next runtime cycle.
Used by `ReplayTick`'s `Completed` branch so Main's update
loop is the one that clears `replayState` — the engine
itself never names a Msg.
-}
dispatchSelf : Msg -> Cmd Msg
dispatchSelf msg =
    Task.succeed () |> Task.perform (\_ -> msg)


{-| Shared shape for the four `Result.Err` branches in `update`
that handle wire failures: log the underlying `Http.Error` to
the console (so devtools has the gory details), set the
model's status to a named Scold message, and return with
`Cmd.none + NoOutput`. The `_ = Debug.log ...` binding pattern
preserves the side-effect across the helper boundary —
without the `_ =` binding Elm would optimize the call away.
-}
logAndScold : String -> Http.Error -> StatusMessage -> Model -> ( Model, Cmd Msg, Output )
logAndScold label err status model =
    let
        _ =
            Debug.log (label ++ " err") err
    in
    ( { model | status = status }, Cmd.none, NoOutput )



-- UPDATE HELPERS


mouseMove : Point -> Float -> Model -> Model
mouseMove pos tMs model =
    case model.drag of
        DraggingBoardCard d ->
            let
                ( nextD, nextStatus ) =
                    BoardGesture.mouseMove pos tMs d model.status
            in
            { model | drag = DraggingBoardCard nextD, status = nextStatus }

        DraggingHandCard d ->
            let
                ( nextD, nextStatus ) =
                    HandGesture.mouseMove pos d model.boardRect model.status
            in
            { model | drag = DraggingHandCard nextD, status = nextStatus }

        NotDragging ->
            model


{-| Thin dispatcher: pattern match on `model.drag` and delegate
to the per-side handler. The board/hand split is load-bearing
indirection — Puzzles can import `handleMouseUpBoard` without
pulling in any of the hand-card complexity.
-}
handleMouseUp : Point -> Float -> Model -> ( Model, Cmd Msg )
handleMouseUp releasePoint tMs model =
    case model.drag of
        NotDragging ->
            ( model, Cmd.none )

        DraggingBoardCard d ->
            let
                outcome =
                    BoardDrag.handleMouseUp releasePoint
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
                , status = outcome.status |> Maybe.withDefault model.status
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
                    HandDrag.handleMouseUp releasePoint
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
                , status = outcome.status |> Maybe.withDefault model.status
                , actionLog = outcome.actionLog
                , nextSeq = outcome.nextSeq
              }
            , outcome.outboundPayload
                |> Maybe.map (Wire.sendAction model.sessionId)
                |> Maybe.withDefault Cmd.none
            )



clickCompleteTurn : Model -> ( Model, Cmd Msg )
clickCompleteTurn model =
    case TurnControl.attemptCompleteTurn { gameState = model.gameState, nextSeq = model.nextSeq } of
        TurnControl.TurnRejected r ->
            ( { model | status = r.status, popup = r.popup }, Cmd.none )

        TurnControl.TurnCompleted r ->
            ( { model
                | gameState = r.newGameState
                , actionLog = model.actionLog ++ [ r.appendedEntry ]
                , nextSeq = model.nextSeq + 1
                , status = r.status
                , popup = r.popup
              }
            , Wire.sendAction model.sessionId r.outboundPayload
            )


clickUndo : Model -> ( Model, Cmd Msg )
clickUndo model =
    case
        TurnControl.attemptUndo
            { gameState = model.gameState
            , lastUndoableAction = lastUndoableAction model
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


boardRectReceived :
    Result Browser.Dom.Error Browser.Dom.Element
    -> Model
    -> ( Model, Cmd Msg )
boardRectReceived result model =
    case result of
        Ok element ->
            let
                rect =
                    { x = round (element.element.x - element.viewport.x)
                    , y = round (element.element.y - element.viewport.y)
                    , width = round element.element.width
                    , height = round element.element.height
                    }
            in
            ( { model | boardRect = Just rect }, Cmd.none )

        Err err ->
            let
                _ =
                    Debug.log "BoardRectReceived err" err
            in
            ( model, Cmd.none )


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


handleHintResponse : Encode.Value -> Model -> ( Model, Cmd Msg )
handleHintResponse value model =
    case Engine.decodeHintResponse model.pendingEngineRequest value of
        Engine.HintStaleId ->
            ( model, Cmd.none )

        Engine.HintError detail ->
            ( { model
                | pendingEngineRequest = Nothing
                , status = { text = "Engine error: " ++ detail, kind = Scold }
              }
            , Cmd.none
            )

        Engine.HintLines [] ->
            ( { model
                | pendingEngineRequest = Nothing
                , hintedCards = []
                , status = { text = "No hint — no obvious play for this hand on this board.", kind = Inform }
              }
            , Cmd.none
            )

        Engine.HintLines lines ->
            ( { model
                | pendingEngineRequest = Nothing
                , hintedCards = []
                , status = { text = String.join "\n" lines, kind = Inform }
              }
            , Cmd.none
            )

        Engine.HintDecodeError err ->
            let
                _ =
                    Debug.log "handleHintResponse decode err" err
            in
            ( { model
                | pendingEngineRequest = Nothing
                , status = { text = "Engine game-hint response could not be decoded — see console.", kind = Scold }
              }
            , Cmd.none
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










