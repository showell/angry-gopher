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
import Game.BoardActions exposing (Side(..))
import Game.BoardDrag exposing (BoardCardDragInfo)
import Game.BoardGesture as BoardGesture
import Game.CardStack exposing (CardStack, encodeBoardLocation, encodeCardStack)
import Game.Drag exposing (DragState(..))
import Game.Execute as Execute
import Game.Hand as Hand exposing (Hand, activeHand, setActiveHand)
import Game.HandDrag exposing (HandCardDragInfo)
import Game.HandGesture as HandGesture
import Game.Rules.Card as Card
import Game.Dealer as Dealer
import Game.Reducer as Reducer
import Game.Game as Game
import Game.PlayerTurn exposing (CompleteTurnResult(..))
import Game.Random as Random
import Game.Replay.Time as ReplayTime
import Game.GameEvent as GameEvent exposing (GameEvent)
import Html exposing (Html)
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Main.Apply as Apply exposing (applyAction, refereeBounds)
import Main.Gesture
    exposing
        ( pointDecoder
        , startBoardCardDrag
        , startHandDrag
        )
import Main.Msg exposing (Msg(..))
import Main.State as State
    exposing
        ( ActionLogBundle
        , ActionLogEntry
        , Model
        , StatusKind(..)
        , StatusMessage
        , baseModel
        , collapseUndos
        , encodeRemoteState
        )
import Main.Types exposing (PathFrame(..), Point)
import Main.View as View exposing (popupForCompleteTurn, statusForCompleteTurn)
import Main.Wire as Wire exposing (encodeGesturePoint, fetchActionLog, fetchNewSession, pathFrameString)
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

                initialRS : State.RemoteState
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
                        | board = setup.board
                        , hands = setup.hands
                        , deck = setup.deck
                        , replayBaseline = Just initialRS
                    }
            in
            ( dealtModel, fetchNewSession (encodeRemoteState initialRS) )

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

        MouseDownOnHandCard { card, point, time } ->
            withNoOutput (startHandDrag card point time model)

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
            withNoOutput (ReplayTime.clickInstantReplay model)

        ReplayFrame nowPosix ->
            withNoOutput (ReplayTime.replayFrame (toFloat (Time.posixToMillis nowPosix)) model)

        ClickReplayPauseToggle ->
            withNoOutput (ReplayTime.clickReplayPauseToggle model)

        HandCardRectReceived result ->
            withNoOutput (ReplayTime.handCardRectReceived result model)

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
                ( outcome, cmd ) =
                    handleMouseUpBoard releasePoint tMs d model
            in
            ( { model
                | drag = NotDragging
                , board = outcome.board
                , status = outcome.status
                , actionLog = outcome.actionLog
                , nextSeq = outcome.nextSeq
              }
            , cmd
            )

        DraggingHandCard d ->
            let
                ( outcome, cmd ) =
                    handleMouseUpHand releasePoint d model
            in
            ( { model
                | drag = NotDragging
                , board = outcome.board
                , hands = outcome.hands
                , cardsPlayedThisTurn = outcome.cardsPlayedThisTurn
                , status = outcome.status
                , actionLog = outcome.actionLog
                , nextSeq = outcome.nextSeq
              }
            , cmd
            )


{-| Narrow return type for `handleMouseUpBoard`: the three
fields that a board-card mouseup actually mutates. The
caller patches these onto its full Model. This is a shim
toward letting Puzzles call `handleMouseUpBoard` without
knowing the full Model shape.
-}
type alias BoardOutcome =
    { board : List CardStack
    , status : StatusMessage
    , actionLog : List ActionLogEntry
    , nextSeq : Int
    }


{-| Resolve a board-card mouseup. Each action variant produces
a `newModel` (engine-applied + log-appended) and an
`outboundPayloadForAgent` (the JSON body that goes to the
server's action log). The per-action `outboundPayloadForAgent`
is built inline — the `Wire.sendAction` body shape lives at
the one site that authors it.
-}
handleMouseUpBoard : Point -> Float -> BoardCardDragInfo -> Model -> ( BoardOutcome, Cmd Msg )
handleMouseUpBoard releasePoint tMs d model =
    case BoardGesture.handleMouseUp releasePoint tMs d model.boardRect of
        BoardGesture.Split p ->
            let
                newBoard =
                    Execute.split p.stack p.cardIndex model.board

                splitStatus =
                    { text = "Be careful with splitting! Splits only pay off when you get more cards on the board or make prettier piles."
                    , kind = Scold
                    }

                entry =
                    { action = GameEvent.Split p
                    , gesturePath = Nothing
                    , pathFrame = ViewportFrame
                    }

                outcome =
                    { board = newBoard
                    , status = Apply.geometryFeedback model.board newBoard |> Maybe.withDefault splitStatus
                    , actionLog = model.actionLog ++ [ entry ]
                    , nextSeq = model.nextSeq + 1
                    }

                outboundPayloadForAgent =
                    Encode.object
                        [ ( "seq", Encode.int model.nextSeq )
                        , ( "action"
                          , Encode.object
                                [ ( "action", Encode.string "split" )
                                , ( "stack", encodeCardStack p.stack )
                                , ( "card_index", Encode.int p.cardIndex )
                                ]
                          )
                        ]
            in
            ( outcome, Wire.sendAction model.sessionId outboundPayloadForAgent )

        BoardGesture.MergeStack p ->
            let
                newBoard =
                    Execute.mergeStack p.source p.target p.side model.board

                entry =
                    { action = GameEvent.MergeStack { source = p.source, target = p.target, side = p.side }
                    , gesturePath = Just p.envelope.path
                    , pathFrame = p.envelope.frame
                    }

                outcome =
                    { board = newBoard
                    , status = Apply.geometryFeedback model.board newBoard |> Maybe.withDefault (Apply.mergeStatus newBoard)
                    , actionLog = model.actionLog ++ [ entry ]
                    , nextSeq = model.nextSeq + 1
                    }

                outboundPayloadForAgent =
                    Encode.object
                        [ ( "seq", Encode.int model.nextSeq )
                        , ( "action"
                          , Encode.object
                                [ ( "action", Encode.string "merge_stack" )
                                , ( "source", encodeCardStack p.source )
                                , ( "target", encodeCardStack p.target )
                                , ( "side"
                                  , Encode.string
                                        (case p.side of
                                            Left ->
                                                "left"

                                            Right ->
                                                "right"
                                        )
                                  )
                                ]
                          )
                        , ( "gesture_metadata"
                          , Encode.object
                                [ ( "path", Encode.list encodeGesturePoint p.envelope.path )
                                , ( "path_frame", Encode.string (pathFrameString p.envelope.frame) )
                                , ( "pointer_type", Encode.string "mouse" )
                                ]
                          )
                        ]
            in
            ( outcome, Wire.sendAction model.sessionId outboundPayloadForAgent )

        BoardGesture.MoveStack p ->
            let
                newBoard =
                    Execute.moveStack p.stack p.newLoc model.board

                moveStackStatus =
                    { text = "Moved!", kind = Inform }

                entry =
                    { action = GameEvent.MoveStack { stack = p.stack, newLoc = p.newLoc }
                    , gesturePath = Just p.envelope.path
                    , pathFrame = p.envelope.frame
                    }

                outcome =
                    { board = newBoard
                    , status = Apply.geometryFeedback model.board newBoard |> Maybe.withDefault moveStackStatus
                    , actionLog = model.actionLog ++ [ entry ]
                    , nextSeq = model.nextSeq + 1
                    }

                outboundPayloadForAgent =
                    Encode.object
                        [ ( "seq", Encode.int model.nextSeq )
                        , ( "action"
                          , Encode.object
                                [ ( "action", Encode.string "move_stack" )
                                , ( "stack", encodeCardStack p.stack )
                                , ( "new_loc", encodeBoardLocation p.newLoc )
                                ]
                          )
                        , ( "gesture_metadata"
                          , Encode.object
                                [ ( "path", Encode.list encodeGesturePoint p.envelope.path )
                                , ( "path_frame", Encode.string (pathFrameString p.envelope.frame) )
                                , ( "pointer_type", Encode.string "mouse" )
                                ]
                          )
                        ]
            in
            ( outcome, Wire.sendAction model.sessionId outboundPayloadForAgent )

        BoardGesture.BoardCardOffBoard ->
            let
                outcome =
                    { board = model.board
                    , status = offBoardScold
                    , actionLog = model.actionLog
                    , nextSeq = model.nextSeq
                    }
            in
            ( outcome, Cmd.none )


{-| Narrow return type for `handleMouseUpHand`, parallel to
`BoardOutcome` but with the additional fields a hand action
can mutate (`hands` for the active-hand write-back,
`cardsPlayedThisTurn` for the per-turn counter).
-}
type alias HandOutcome =
    { board : List CardStack
    , hands : List Hand
    , cardsPlayedThisTurn : Int
    , status : StatusMessage
    , actionLog : List ActionLogEntry
    , nextSeq : Int
    }


{-| Resolve a hand-card mouseup. Mirrors `handleMouseUpBoard`
but for the hand-origin variants. Hand actions ship pathless
(no `gesture_metadata`); replay re-synthesizes via DOM
measurement on the resume path.
-}
handleMouseUpHand : Point -> HandCardDragInfo -> Model -> ( HandOutcome, Cmd Msg )
handleMouseUpHand releasePoint d model =
    case HandGesture.handleMouseUp releasePoint d model.boardRect of
        HandGesture.MergeHand p ->
            let
                next =
                    Execute.mergeHand p.handCard p.target p.side model.board (activeHand model)

                modelWithHand =
                    setActiveHand next.hand model

                outcome =
                    { board = next.board
                    , hands = modelWithHand.hands
                    , cardsPlayedThisTurn = model.cardsPlayedThisTurn + 1
                    , status = Apply.geometryFeedback model.board next.board |> Maybe.withDefault (Apply.mergeStatus next.board)
                    , actionLog =
                        model.actionLog
                            ++ [ { action = GameEvent.MergeHand p
                                 , gesturePath = Nothing
                                 , pathFrame = ViewportFrame
                                 }
                               ]
                    , nextSeq = model.nextSeq + 1
                    }

                outboundPayloadForAgent =
                    Encode.object
                        [ ( "seq", Encode.int model.nextSeq )
                        , ( "action"
                          , Encode.object
                                [ ( "action", Encode.string "merge_hand" )
                                , ( "hand_card", Card.encodeCard p.handCard )
                                , ( "target", encodeCardStack p.target )
                                , ( "side"
                                  , Encode.string
                                        (case p.side of
                                            Left ->
                                                "left"

                                            Right ->
                                                "right"
                                        )
                                  )
                                ]
                          )
                        ]
            in
            ( outcome, Wire.sendAction model.sessionId outboundPayloadForAgent )

        HandGesture.PlaceHand p ->
            let
                next =
                    Execute.placeHand p.handCard p.loc model.board (activeHand model)

                modelWithHand =
                    setActiveHand next.hand model

                placeHandStatus =
                    { text = "On the board!", kind = Inform }

                outcome =
                    { board = next.board
                    , hands = modelWithHand.hands
                    , cardsPlayedThisTurn = model.cardsPlayedThisTurn + 1
                    , status = Apply.geometryFeedback model.board next.board |> Maybe.withDefault placeHandStatus
                    , actionLog =
                        model.actionLog
                            ++ [ { action = GameEvent.PlaceHand p
                                 , gesturePath = Nothing
                                 , pathFrame = ViewportFrame
                                 }
                               ]
                    , nextSeq = model.nextSeq + 1
                    }

                outboundPayloadForAgent =
                    Encode.object
                        [ ( "seq", Encode.int model.nextSeq )
                        , ( "action"
                          , Encode.object
                                [ ( "action", Encode.string "place_hand" )
                                , ( "hand_card", Card.encodeCard p.handCard )
                                , ( "loc", encodeBoardLocation p.loc )
                                ]
                          )
                        ]
            in
            ( outcome, Wire.sendAction model.sessionId outboundPayloadForAgent )

        HandGesture.HandCardOffBoard ->
            let
                outcome =
                    { board = model.board
                    , hands = model.hands
                    , cardsPlayedThisTurn = model.cardsPlayedThisTurn
                    , status = offBoardScold
                    , actionLog = model.actionLog
                    , nextSeq = model.nextSeq
                    }
            in
            ( outcome, Cmd.none )

        HandGesture.HandNothing ->
            let
                outcome =
                    { board = model.board
                    , hands = model.hands
                    , cardsPlayedThisTurn = model.cardsPlayedThisTurn
                    , status = model.status
                    , actionLog = model.actionLog
                    , nextSeq = model.nextSeq
                    }
            in
            ( outcome, Cmd.none )


offBoardScold : StatusMessage
offBoardScold =
    { text = "Don't knock cards off the board, please. You're not a cat!"
    , kind = Scold
    }


clickCompleteTurn : Model -> ( Model, Cmd Msg )
clickCompleteTurn model =
    let
        ( afterTurn, turnOutcome ) =
            Game.applyCompleteTurn refereeBounds model
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
                    { action = GameEvent.CompleteTurn
                    , gesturePath = Nothing
                    , pathFrame = ViewportFrame
                    }

                newModel =
                    { afterTurn
                        | actionLog = model.actionLog ++ [ completeTurnEntry ]
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
                pre =
                    { board = model.board, hand = activeHand model }

                post =
                    Reducer.undoAction lastAction pre

                undoEntry =
                    { action = GameEvent.Undo
                    , gesturePath = Nothing
                    , pathFrame = ViewportFrame
                    }

                seq =
                    model.nextSeq

                cardsAdjust =
                    case lastAction of
                        GameEvent.MergeHand _ ->
                            -1

                        GameEvent.PlaceHand _ ->
                            -1

                        _ ->
                            0

                newModel =
                    setActiveHand post.hand
                        { model
                            | board = post.board
                            , cardsPlayedThisTurn = model.cardsPlayedThisTurn + cardsAdjust
                            , actionLog = model.actionLog ++ [ undoEntry ]
                            , nextSeq = seq + 1
                            , status = { text = "Undone.", kind = Inform }
                            , hintedCards = []
                            , drag = NotDragging
                            , replay = Nothing
                            , replayAnim = State.NotAnimating
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
            (activeHand model).handCards
                |> List.map .card

        payload =
            Encode.object
                [ ( "request_id", Encode.int reqId )
                , ( "op", Encode.string "game_hint" )
                , ( "hand", Encode.list Card.encodeCard hand )
                , ( "board", encodeBoardForEngine model.board )
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
            case model.replay of
                Just progress ->
                    if progress.paused then
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
        (\entry m -> .model (applyAction entry.action m))
        atInitial
        (collapseUndos bundle.actions)


{-| Drop the initial-state record's fields onto the model and
pin it as the replay baseline. Used by `bootstrapFromBundle`
on the resume path.
-}
modelAtInitial : State.RemoteState -> Model -> Model
modelAtInitial initial model =
    { model
        | board = initial.board
        , hands = initial.hands
        , activePlayerIndex = initial.activePlayerIndex
        , turnIndex = initial.turnIndex
        , deck = initial.deck
        , cardsPlayedThisTurn = initial.cardsPlayedThisTurn
        , victorAwarded = initial.victorAwarded
        , replayBaseline = Just initial
    }



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




