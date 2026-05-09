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
import Game.BoardDrag as BoardDrag
import Game.BoardGesture as BoardGesture
import Game.CardStack exposing (CardStack)
import Game.Drag exposing (DragState(..))
import Game.Execute as Execute
import Game.Hand exposing (activeHand)
import Game.HandDrag as HandDrag
import Game.HandGesture as HandGesture
import Game.Rules.Card as Card
import Game.Dealer as Dealer
import Game.Game as Game
import Game.PlayerTurn exposing (CompleteTurnResult(..))
import Game.Random as Random
import Game.Replay.Time as ReplayTime
import Game.GameEvent as GameEvent exposing (GameEvent)
import Html exposing (Html)
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Game.Physics.BoardGeometry exposing (refereeBounds)
import Game.Status exposing (StatusKind(..), StatusMessage)
import Main.Gesture
    exposing
        ( pointDecoder
        , startBoardCardDrag
        , startHandDrag
        )
import Main.Msg exposing (Msg(..))
import Game.ActionLog exposing (ActionLogBundle)
import Main.State
    exposing
        ( Model
        , baseModel
        , collapseUndos
        , encodeGameState
        )
import Game.Point exposing (Point)
import Main.View as View exposing (popupForCompleteTurn, statusForCompleteTurn)
import Main.Wire as Wire exposing (fetchActionLog, fetchNewSession)
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
            logAndScold "ActionSent" err actionRejectedStatus model

        SessionReceived (Ok sid) ->
            -- Session id allocated by the server. State was
            -- already dealt locally during NewSession init.
            ( { model | sessionId = Just sid }
            , Cmd.none
            , SessionChanged sid
            )

        SessionReceived (Err err) ->
            logAndScold "SessionReceived" err sessionAllocFailedStatus model

        ClickCompleteTurn ->
            withNoOutput (clickCompleteTurn model)

        ClickUndo ->
            withNoOutput (clickUndo model)

        PopupOk ->
            ( { model | popup = Nothing }, Cmd.none, NoOutput )

        ClickInstantReplay ->
            let
                ( newRS, cmd ) =
                    ReplayTime.clickInstantReplay
                        { gameId = model.gameId
                        , initialGameState = model.initialGameState
                        , actionLog = model.actionLog
                        }
            in
            withNoOutput
                ( { model
                    | replayState = Just newRS
                    , status = { text = "Replaying…", kind = Inform }
                    , drag = NotDragging
                  }
                , cmd
                )

        ReplayFrame nowPosix ->
            case model.replayState of
                Nothing ->
                    withNoOutput ( model, Cmd.none )

                Just rs ->
                    let
                        ( maybeNew, cmd ) =
                            ReplayTime.replayFrame
                                (toFloat (Time.posixToMillis nowPosix))
                                rs
                    in
                    withNoOutput ( { model | replayState = maybeNew }, cmd )

        ClickReplayPauseToggle ->
            case model.replayState of
                Nothing ->
                    withNoOutput ( model, Cmd.none )

                Just rs ->
                    withNoOutput
                        ( { model | replayState = Just (ReplayTime.clickReplayPauseToggle rs) }
                        , Cmd.none
                        )

        HandCardRectReceived result ->
            case model.replayState of
                Nothing ->
                    withNoOutput ( model, Cmd.none )

                Just rs ->
                    let
                        ( newRS, cmd ) =
                            ReplayTime.handCardRectReceived result model.boardRect rs
                    in
                    withNoOutput ( { model | replayState = Just newRS }, cmd )

        BoardAnimationDone event ->
            withNoOutput ( applyReplayEvent event model, Cmd.none )

        HandAnimationDone event ->
            withNoOutput ( applyReplayEvent event model, Cmd.none )

        ActionLogFetched (Ok bundle) ->
            ( bootstrapFromBundle bundle model, Cmd.none, NoOutput )

        ActionLogFetched (Err err) ->
            logAndScold "ActionLogFetched" err actionLogFetchFailedStatus model

        BoardRectReceived result ->
            withNoOutput (boardRectReceived result model)

        ClickHint ->
            clickHint model

        GameHintReceived value ->
            withNoOutput (applyGameHintResponse value model)


withNoOutput : ( Model, Cmd Msg ) -> ( Model, Cmd Msg, Output )
withNoOutput ( m, c ) =
    ( m, c, NoOutput )


{-| Advance the replay's gameState by one event. Fired when
the animation FSM signals that an animation has completed
(via `BoardAnimationDone` / `HandAnimationDone`). The replay's
phase transition (Animating* → Beating) already happened in
`Game.Replay.Time.replayFrame`; this handler does the
logical apply that the animation was visualizing.

The Nothing case is unreachable by construction — the Msg
was emitted by the replay engine itself, which only runs
when `replayState` is `Just`. Between the Cmd emit and the
Msg dispatch (~one frame), no current code path clears
`replayState`. We log loudly if it ever happens — silent
no-op would mask a real divergence.
-}
applyReplayEvent : GameEvent -> Model -> Model
applyReplayEvent event model =
    case model.replayState of
        Just rs ->
            { model | replayState = Just { rs | gameState = Execute.applyEvent event rs.gameState } }

        Nothing ->
            let
                _ =
                    Debug.log "applyReplayEvent: unexpected — replayState was Nothing when animation-done Msg arrived" event
            in
            model


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
    let
        ( afterTurn, turnOutcome ) =
            Game.applyCompleteTurn refereeBounds model.gameState
    in
    case turnOutcome.result of
        Failure ->
            ( { model
                | status = statusForCompleteTurn (Ok turnOutcome)
                , popup = popupForCompleteTurn (Ok turnOutcome)
              }
            , Cmd.none
            )

        _ ->
            let
                seq =
                    model.nextSeq

                completeTurnEntry =
                    { action = GameEvent.CompleteTurn }

                newModel =
                    { model
                        | gameState = afterTurn
                        , actionLog = model.actionLog ++ [ completeTurnEntry ]
                        , nextSeq = seq + 1
                        , status = statusForCompleteTurn (Ok turnOutcome)
                        , popup = popupForCompleteTurn (Ok turnOutcome)
                    }

                outboundPayloadForAgent =
                    Encode.object
                        [ ( "seq", Encode.int seq )
                        , ( "action"
                          , Encode.object
                                [ ( "action", Encode.string "complete_turn" ) ]
                          )
                        ]
            in
            ( newModel, Wire.sendAction model.sessionId outboundPayloadForAgent )


clickUndo : Model -> ( Model, Cmd Msg )
clickUndo model =
    case lastUndoableAction model of
        Nothing ->
            ( model, Cmd.none )

        Just lastAction ->
            let
                undoEntry =
                    { action = GameEvent.Undo }

                seq =
                    model.nextSeq

                newModel =
                    { model
                        | gameState = Execute.undoEvent lastAction model.gameState
                        , actionLog = model.actionLog ++ [ undoEntry ]
                        , nextSeq = seq + 1
                        , status = { text = "Undone.", kind = Inform }
                        , hintedCards = []
                        , drag = NotDragging
                        , replayState = Nothing
                    }

                outboundPayloadForAgent =
                    Encode.object
                        [ ( "seq", Encode.int seq )
                        , ( "action"
                          , Encode.object
                                [ ( "action", Encode.string "undo" ) ]
                          )
                        ]
            in
            ( newModel, Wire.sendAction model.sessionId outboundPayloadForAgent )


lastUndoableAction : Model -> Maybe GameEvent
lastUndoableAction model =
    case List.reverse (collapseUndos model.actionLog) of
        [] ->
            Nothing

        last :: _ ->
            case last.action of
                GameEvent.CompleteTurn ->
                    Nothing

                _ ->
                    Just last.action


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
    requestGameHint model


{-| Full-game hint payload. Sends the active player's hand AND
the board, expecting a `lines: string[]` response to display
verbatim in the status bar. No `puzzle_name` field — there's
only one Play instance in the full-game host, no routing needed.
The response arrives on the `gameHintResponse` port → dispatches
as a `GameHintReceived` Msg → handled by `applyGameHintResponse`.
-}
requestGameHint : Model -> ( Model, Cmd Msg, Output )
requestGameHint model =
    let
        reqId =
            model.nextEngineRequestId

        hand =
            (activeHand model.gameState).handCards
                |> List.map .card

        payload =
            Encode.object
                [ ( "request_id", Encode.int reqId )
                , ( "op", Encode.string "game_hint" )
                , ( "hand", Encode.list Card.encodeCard hand )
                , ( "board", encodeBoardForEngine model.gameState.board )
                ]
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


{-| Encode the live board into the snake_case shape the TS
engine bundle expects on the JS side: a list of stacks, each a
list of `{value, suit, origin_deck}` card objects. The JS glue
translates these into Card tuples before invoking the engine.
-}
encodeBoardForEngine : List CardStack -> Encode.Value
encodeBoardForEngine board =
    Encode.list
        (\stack ->
            Encode.list Card.encodeCard
                (List.map .card stack.boardCards)
        )
        board


{-| Decode a `game_hint` response and display it. Arrives on its
own port (`gameHintResponse`) — no op-dispatch needed — so the
decoder is just `{ request_id, ok, lines, error? }` plus a
stale-id check. Lines are joined verbatim into the status bar;
all phrasing lives TS-side in `formatHint`.
-}
applyGameHintResponse : Encode.Value -> Model -> ( Model, Cmd Msg )
applyGameHintResponse value model =
    let
        decoder =
            Decode.map3 (\rid ok mLines -> { rid = rid, ok = ok, lines = mLines })
                (Decode.field "request_id" Decode.int)
                (Decode.field "ok" Decode.bool)
                (Decode.maybe (Decode.field "lines" (Decode.list Decode.string)))

        errDecoder =
            Decode.field "error" Decode.string
    in
    case Decode.decodeValue decoder value of
        Ok r ->
            if model.pendingEngineRequest /= Just r.rid then
                ( model, Cmd.none )

            else if not r.ok then
                let
                    detail =
                        Decode.decodeValue errDecoder value
                            |> Result.withDefault "(no detail)"
                in
                ( { model
                    | pendingEngineRequest = Nothing
                    , status = { text = "Engine error: " ++ detail, kind = Scold }
                  }
                , Cmd.none
                )

            else
                let
                    lines =
                        Maybe.withDefault [] r.lines

                    cleared =
                        { model | pendingEngineRequest = Nothing, hintedCards = [] }
                in
                case lines of
                    [] ->
                        ( { cleared
                            | status = { text = "No hint — no obvious play for this hand on this board.", kind = Inform }
                          }
                        , Cmd.none
                        )

                    _ ->
                        ( { cleared
                            | status = { text = String.join "\n" lines, kind = Inform }
                          }
                        , Cmd.none
                        )

        Err err ->
            let
                _ =
                    Debug.log "applyGameHintResponse decode err" err
            in
            ( { model
                | pendingEngineRequest = Nothing
                , status = { text = "Engine game-hint response could not be decoded — see console.", kind = Scold }
              }
            , Cmd.none
            )




-- SUBSCRIPTIONS


mouseMoveDecoder : Decoder Msg
mouseMoveDecoder =
    Decode.map2 MouseMove
        pointDecoder
        (Decode.field "timeStamp" Decode.float)


mouseUpDecoder : Decoder Msg
mouseUpDecoder =
    Decode.map2 MouseUp
        pointDecoder
        (Decode.field "timeStamp" Decode.float)


subscriptions : Model -> Sub Msg
subscriptions model =
    let
        dragSubs =
            case model.drag of
                NotDragging ->
                    []

                _ ->
                    [ Browser.Events.onMouseMove mouseMoveDecoder
                    , Browser.Events.onMouseUp mouseUpDecoder
                    ]

        replaySubs =
            case model.replayState of
                Just rs ->
                    if rs.paused then
                        []

                    else
                        [ Browser.Events.onAnimationFrame ReplayFrame ]

                Nothing ->
                    []
    in
    Sub.batch (dragSubs ++ replaySubs)



-- VIEW


view : Model -> Html Msg
view =
    View.view



-- BOOTSTRAP


bootstrapFromBundle : ActionLogBundle -> Model -> Model
bootstrapFromBundle bundle model =
    let
        atInitial =
            modelAtInitial bundle.initialState
                { model
                    | actionLog = bundle.actions
                    , nextSeq = List.length bundle.actions + 1
                }
    in
    List.foldl
        (\entry m -> { m | gameState = Execute.applyEvent entry.action m.gameState })
        atInitial
        (collapseUndos bundle.actions)


{-| Pin the bundle's initial state as both the live gameState
and the immutable initialGameState (used by Instant Replay's
ReplayState seed). Used by `bootstrapFromBundle` on resume.
-}
modelAtInitial : Game.GameState -> Model -> Model
modelAtInitial initial model =
    { model | gameState = initial, initialGameState = initial }



-- STATUS MESSAGES
--
-- Named StatusMessage values for each failure / interrupt
-- site in this module, mirroring the convention used in
-- Main.Apply (`splitStatus`, `placeHandStatus`, etc.).
-- Lifting them to named values keeps the dispatch in
-- `update` legible and makes "what's the full set of
-- failure messages this module can produce?" a one-screen
-- read.


actionRejectedStatus : StatusMessage
actionRejectedStatus =
    { text = "Server rejected action — check console; state may be out of sync."
    , kind = Scold
    }


sessionAllocFailedStatus : StatusMessage
sessionAllocFailedStatus =
    { text = "Could not allocate a session — check console."
    , kind = Scold
    }


actionLogFetchFailedStatus : StatusMessage
actionLogFetchFailedStatus =
    { text = "Could not load action log — check console."
    , kind = Scold
    }




