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
import Game.CardStack exposing (CardStack)
import Game.Rules.Card as Card
import Game.Dealer as Dealer
import Game.Reducer as Reducer
import Game.Game as Game
import Game.PlayerTurn exposing (CompleteTurnResult(..))
import Game.Physics.GestureArbitration as GA
import Game.Random as Random
import Game.Replay.Time as ReplayTime
import Game.Score as Score
import Game.WireAction as WA
import Html exposing (Html)
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode
import Main.Apply exposing (applyAction, refereeBounds)
import Main.Gesture as Gesture
    exposing
        ( handleMouseUp
        , pointDecoder
        , startBoardCardDrag
        , startHandDrag
        )
import Main.Msg exposing (Msg(..))
import Main.State as State
    exposing
        ( ActionLogBundle
        , DragState(..)
        , Model
        , StatusKind(..)
        , StatusMessage
        , activeHand
        , baseModel
        , collapseUndos
        , encodeRemoteState
        , setActiveHand
        )
import Main.Types as Types
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

                turnScore =
                    Score.forStacks setup.board

                initialRS : State.RemoteState
                initialRS =
                    { board = setup.board
                    , hands = setup.hands
                    , scores = [ 0, 0 ]
                    , activePlayerIndex = 0
                    , turnIndex = 0
                    , deck = setup.deck
                    , cardsPlayedThisTurn = 0
                    , victorAwarded = False
                    , turnStartBoardScore = turnScore
                    }

                dealtModel =
                    { baseModel
                        | board = setup.board
                        , hands = setup.hands
                        , deck = setup.deck
                        , turnStartBoardScore = turnScore
                        , score = turnScore
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
            withNoOutput (mouseMove pos tMs model)

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


mouseMove : Types.Point -> Float -> Model -> ( Model, Cmd Msg )
mouseMove pos tMs model =
    case model.drag of
        Dragging info ctx arb ->
            let
                nextIntent =
                    GA.clickIntentAfterMove arb.originalCursor pos arb.clickIntent

                -- Apply the cursor delta to the floater. Pure
                -- vector, frame-agnostic — floaterTopLeft stays
                -- in whatever frame it started (board for
                -- intra-board drags, viewport for hand drags).
                delta =
                    { x = pos.x - info.cursor.x
                    , y = pos.y - info.cursor.y
                    }

                nextFloater =
                    { x = info.floaterTopLeft.x + delta.x
                    , y = info.floaterTopLeft.y + delta.y
                    }

                nextPath =
                    info.gesturePath
                        ++ [ { tMs = tMs, x = nextFloater.x, y = nextFloater.y } ]

                nextInfo =
                    { info
                        | cursor = pos
                        , floaterTopLeft = nextFloater
                        , gesturePath = nextPath
                    }

                nextArb =
                    { arb | clickIntent = nextIntent }

                currentHover =
                    Gesture.floaterOverWing ctx info

                nextHover =
                    Gesture.floaterOverWing ctx nextInfo

                statusAfterMove =
                    if nextHover /= currentHover then
                        case nextHover of
                            Just _ ->
                                Gesture.wingHoverStatus

                            Nothing ->
                                model.status

                    else
                        model.status
            in
            ( { model | drag = Dragging nextInfo ctx nextArb, status = statusAfterMove }
            , Cmd.none
            )

        NotDragging ->
            ( model, Cmd.none )


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
                    { action = WA.CompleteTurn
                    , gesturePath = Nothing
                    , pathFrame = Types.ViewportFrame
                    }

                newModel =
                    { afterTurn
                        | actionLog = model.actionLog ++ [ completeTurnEntry ]
                        , nextSeq = seq + 1
                        , score = Score.forStacks afterTurn.board
                        , status = statusForCompleteTurn (Ok turnOutcome)
                        , popup = popupForCompleteTurn (Ok turnOutcome)
                    }

                persistCmd =
                    case model.sessionId of
                        Just sid ->
                            Wire.sendAction sid seq WA.CompleteTurn Nothing

                        Nothing ->
                            Cmd.none
            in
            ( newModel, persistCmd )


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
                    { action = WA.Undo
                    , gesturePath = Nothing
                    , pathFrame = Types.ViewportFrame
                    }

                seq =
                    model.nextSeq

                cardsAdjust =
                    case lastAction of
                        WA.MergeHand _ ->
                            -1

                        WA.PlaceHand _ ->
                            -1

                        _ ->
                            0

                newModel =
                    setActiveHand post.hand
                        { model
                            | board = post.board
                            , score = Score.forStacks post.board
                            , cardsPlayedThisTurn = model.cardsPlayedThisTurn + cardsAdjust
                            , actionLog = model.actionLog ++ [ undoEntry ]
                            , nextSeq = seq + 1
                            , status = { text = "Undone.", kind = Inform }
                            , hintedCards = []
                            , drag = NotDragging
                            , replay = Nothing
                            , replayAnim = State.NotAnimating
                        }

                persistCmd =
                    case model.sessionId of
                        Just sid ->
                            Wire.sendAction sid seq WA.Undo Nothing

                        Nothing ->
                            Cmd.none
            in
            ( newModel, persistCmd )


lastUndoableAction : Model -> Maybe WA.WireAction
lastUndoableAction model =
    case List.reverse (collapseUndos model.actionLog) of
        [] ->
            Nothing

        last :: _ ->
            case last.action of
                WA.CompleteTurn ->
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

                updatedDrag =
                    case model.drag of
                        Dragging info ctx arb ->
                            Dragging info { ctx | boardRect = Just rect } arb

                        other ->
                            other

                replayOffset =
                    case model.replay of
                        Just _ ->
                            Just { x = rect.x, y = rect.y }

                        Nothing ->
                            model.replayBoardRect
            in
            ( { model
                | drag = updatedDrag
                , replayBoardRect = replayOffset
              }
            , Cmd.none
            )

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
                Dragging _ _ _ ->
                    [ Browser.Events.onMouseMove mouseMoveDecoder
                    , Browser.Events.onMouseUp mouseUpDecoder
                    ]

                NotDragging ->
                    []

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
        , scores = initial.scores
        , activePlayerIndex = initial.activePlayerIndex
        , turnIndex = initial.turnIndex
        , deck = initial.deck
        , cardsPlayedThisTurn = initial.cardsPlayedThisTurn
        , victorAwarded = initial.victorAwarded
        , turnStartBoardScore = initial.turnStartBoardScore
        , score = Score.forStacks initial.board
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




