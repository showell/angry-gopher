module Main.Play exposing
    ( Config(..)
    , Output(..)
    , init
    , mouseMove
    , subscriptions
    , update
    , view
    )

{-| The live-play component for LynRummy. Contains what was
formerly the whole of `Main.elm`'s update/view/subscriptions
surface, now factored out so Puzzles (and future
multi-game-per-page hosts) can embed a single Play instance
per puzzle without inheriting the main app's top-level
port + wrapper shape.

Phase I of REFACTOR\_EMBEDDABLE\_PLAY — a literal relocation
with one small interface widening: `update` returns an
`Output` value the host uses to decide whether to fire its
own port (e.g. the URL-path update when a new session id
arrives). Nothing else has changed. Main.elm becomes a thin
harness that wraps this module, owns the port, and routes
Output.

Future phases add `Config` (for NewSession / ResumeSession /
PuzzleSession bootstraps), opaque Model/Msg, and per-instance
DOM ids for multi-embedding.

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
import Game.Replay.Space as ReplaySpace
import Game.Replay.Time as ReplayTime
import Game.Score as Score
import Game.WireAction as WA exposing (WireAction)
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
        , PathFrame(..)
        , StatusKind(..)
        , StatusMessage
        , activeHand
        , baseModel
        , collapseUndos
        , encodeRemoteState
        , setActiveHand
        )
import Main.View as View exposing (popupForCompleteTurn, statusForCompleteTurn)
import Main.Wire as Wire exposing (fetchActionLog, fetchNewSession)
import Task
import Time



-- CONFIG


{-| Bootstrap shapes Play can start in. Each one maps to a
different init path, but the resulting Model shape is the
same.

  - `NewSession seedSource` — no session yet; deal a fresh
    game locally (Elm is the autonomous dealer) using
    `seedSource` as PRNG entropy, then post the dealt
    `initial_state` to the server so reloads can resume.
  - `ResumeSession sid` — URL says we're resuming session
    `sid`; fetch its action log and `initial_state` from
    the server.
  - `PuzzleSession sid` — a puzzle session whose hand-crafted
    initial state ships inline from the catalog.

-}
type Config
    = NewSession Int
    | ResumeSession Int
      -- Puzzles puzzle. Carries the initial state inline (the
      -- catalog already has it), so init can bootstrap
      -- synchronously without an HTTP round-trip. No session id
      -- at boot — sessions for puzzles are born from intent to
      -- persist (first wire-emitting action), not from page
      -- render. See `project_sessions_born_from_intent.md`.
    | PuzzleSession
        { sessionId : Int
        , puzzleName : String
        , initialState : Encode.Value
        }



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
                , gameId = String.fromInt sid
                , status =
                    { text =
                        "Resuming session " ++ String.fromInt sid ++ "…"
                    , kind = Inform
                    }
              }
            , fetchActionLog sid
            )

        PuzzleSession { sessionId, puzzleName, initialState } ->
            let
                framed =
                    { baseModel
                        | sessionId = Just sessionId
                        , puzzleName = Just puzzleName
                        , gameId = puzzleName
                        , hideTurnControls = True
                    }
            in
            case Decode.decodeValue Wire.initialStateDecoder initialState of
                Ok decoded ->
                    ( bootstrapPuzzle decoded puzzleName framed, Cmd.none )

                Err err ->
                    ( { framed
                        | status =
                            { text =
                                "Puzzle "
                                    ++ puzzleName
                                    ++ " failed to decode: "
                                    ++ Decode.errorToString err
                            , kind = Scold
                            }
                      }
                    , Cmd.none
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

        ClickReset ->
            withNoOutput (clickReset model)

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

        ClickAgentPlay ->
            clickAgentPlay model

        EngineSolveResult value ->
            withNoOutput (handleEngineSolveResult value model)

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


mouseMove : State.Point -> Float -> Model -> ( Model, Cmd Msg )
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
                    , pathFrame = State.ViewportFrame
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
                            Wire.sendAction sid seq model.puzzleName WA.CompleteTurn Nothing

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
                    , pathFrame = State.ViewportFrame
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
                            , agentProgram = Nothing
                            , drag = NotDragging
                            , replay = Nothing
                            , replayAnim = State.NotAnimating
                        }

                persistCmd =
                    case model.sessionId of
                        Just sid ->
                            Wire.sendAction sid seq model.puzzleName WA.Undo Nothing

                        Nothing ->
                            Cmd.none
            in
            ( newModel, persistCmd )


clickReset : Model -> ( Model, Cmd Msg )
clickReset model =
    case model.puzzleInitialState of
        Nothing ->
            ( model, Cmd.none )

        Just initial ->
            ( modelAtInitial initial
                { model
                    | actionLog = []
                    , agentProgram = Nothing
                    , drag = NotDragging
                    , replay = Nothing
                    , replayAnim = State.NotAnimating
                    , status = { text = "Puzzle reset.", kind = Inform }
                }
            , Cmd.none
            )


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
    -- Both surfaces route through the TS engine via the host's
    -- ports, but the request shapes differ:
    --   - Puzzle hint: board-only solve. The puzzle has no hand
    --     and the hint is the BFS plan that clears the board.
    --   - Full-game hint: hand-aware. The TS engine projects
    --     hand-card candidates onto the board and returns a
    --     play (placements + plan) rendered as step strings.
    -- Each goes to its own JS-glue op (solve_board / game_hint)
    -- and its own response port (engineResponse / gameHintResponse).
    if model.puzzleName /= Nothing then
        requestEngineHint model

    else
        requestGameHint model


{-| Compose the engine port request payload and ship it through
the `EngineSolveRequested` Output channel. The host (Puzzles)
forwards it to JS via the `engineRequest` port. Status flips to
"Thinking…" immediately so the user sees feedback while the
engine works.

The request id is monotonic per-Play-instance; the matching
response carries the same id and we discard mismatches as
stale (e.g. the user clicked hint twice in quick succession).
-}
requestEngineHint : Model -> ( Model, Cmd Msg, Output )
requestEngineHint model =
    let
        reqId =
            model.nextEngineRequestId

        puzzleName =
            Maybe.withDefault "" model.puzzleName

        payload =
            Encode.object
                [ ( "request_id", Encode.int reqId )
                , ( "op", Encode.string "solve_board" )
                , ( "puzzle_name", Encode.string puzzleName )
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


{-| Decode an `engineResponse` port payload and apply it to the
model. Carries `request_id`, `op`, `ok`, and op-specific result
fields. Stale responses (request id ≠ pendingEngineRequest)
are dropped on the floor.

The decoder branches on `op`: "solve_board" for hint, where
`plan` is a list of plan-line strings; "agent_play" for the
agent walk, where `plan` is a list of `{line, wire_actions}`
batches.
-}
handleEngineSolveResult : Encode.Value -> Model -> ( Model, Cmd Msg )
handleEngineSolveResult value model =
    case Decode.decodeValue engineResponseHeadDecoder value of
        Ok head ->
            if model.pendingEngineRequest /= Just head.requestId then
                ( model, Cmd.none )

            else if not head.ok then
                ( { model
                    | pendingEngineRequest = Nothing
                    , status =
                        { text =
                            "Engine error: "
                                ++ Maybe.withDefault "(no detail)" head.error
                        , kind = Scold
                        }
                  }
                , Cmd.none
                )

            else
                case head.op of
                    "solve_board" ->
                        applyHintResponse value model

                    "agent_play" ->
                        applyAgentPlayResponse value model

                    other ->
                        let
                            _ =
                                Debug.log "engineResponse: unknown op" other
                        in
                        ( { model
                            | pendingEngineRequest = Nothing
                            , status =
                                { text = "Engine sent unknown op: " ++ other
                                , kind = Scold
                                }
                          }
                        , Cmd.none
                        )

        Err err ->
            let
                _ =
                    Debug.log "engineResponse decode err" err
            in
            ( { model
                | status =
                    { text = "Engine response could not be decoded — see console."
                    , kind = Scold
                    }
              }
            , Cmd.none
            )


{-| Just the discriminator + outcome fields. Op-specific decode
happens after the dispatch.
-}
type alias EngineResponseHead =
    { requestId : Int
    , op : String
    , ok : Bool
    , error : Maybe String
    }


engineResponseHeadDecoder : Decoder EngineResponseHead
engineResponseHeadDecoder =
    Decode.map4 EngineResponseHead
        (Decode.field "request_id" Decode.int)
        (Decode.field "op" Decode.string)
        (Decode.field "ok" Decode.bool)
        (Decode.maybe (Decode.field "error" Decode.string))


applyHintResponse : Encode.Value -> Model -> ( Model, Cmd Msg )
applyHintResponse value model =
    let
        cleared =
            { model | pendingEngineRequest = Nothing, hintedCards = [] }

        planDecoder =
            Decode.field "plan"
                (Decode.nullable
                    (Decode.list (Decode.field "line" Decode.string))
                )
    in
    case Decode.decodeValue planDecoder value of
        Ok Nothing ->
            ( { cleared
                | status = { text = "Engine found no plan within budget.", kind = Inform }
              }
            , Cmd.none
            )

        Ok (Just []) ->
            ( { cleared
                | status = { text = "Board is already clean — nothing to do.", kind = Inform }
              }
            , Cmd.none
            )

        Ok (Just (firstLine :: _)) ->
            ( { cleared
                | status = { text = "Hint: " ++ firstLine, kind = Inform }
              }
            , Cmd.none
            )

        Err err ->
            let
                _ =
                    Debug.log "applyHintResponse decode err" err
            in
            ( { cleared
                | status = { text = "Engine hint response could not be decoded — see console.", kind = Scold }
              }
            , Cmd.none
            )


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


{-| Decode an agent_play response (list of `{line, wire_actions}`
batches), cache the rest in `agentProgram`, and run the head
batch immediately. Mirrors what the cached-cache path does on
subsequent clicks: one batch per click, the rest queued.
-}
applyAgentPlayResponse : Encode.Value -> Model -> ( Model, Cmd Msg )
applyAgentPlayResponse value model =
    let
        cleared =
            { model | pendingEngineRequest = Nothing, hintedCards = [] }

        planDecoder =
            Decode.field "plan" (Decode.nullable (Decode.list agentBatchDecoder))
    in
    case Decode.decodeValue planDecoder value of
        Ok Nothing ->
            ( { cleared
                | status = { text = "Agent could not find a plan within budget.", kind = Inform }
              }
            , Cmd.none
            )

        Ok (Just []) ->
            ( { cleared
                | status = { text = "Board is already clean — nothing to do.", kind = Inform }
              }
            , Cmd.none
            )

        Ok (Just (batch :: rest)) ->
            runAgentBatch batch rest cleared

        Err err ->
            let
                _ =
                    Debug.log "applyAgentPlayResponse decode err" err
            in
            ( { cleared
                | status = { text = "Engine agent_play response could not be decoded — see console.", kind = Scold }
              }
            , Cmd.none
            )


agentBatchDecoder : Decoder State.AgentMoveBatch
agentBatchDecoder =
    Decode.map2 State.AgentMoveBatch
        (Decode.field "line" Decode.string)
        (Decode.field "wire_actions" (Decode.list WA.decoder))


{-| Each click plays exactly the next plan move — i.e. the
primitive batch for one logical move from the canonical TS
engine. Then it stops, so the user can keep clicking to walk
through the program one line at a time.

The plan is computed ONCE on the first click (via the engine
port — async; status flips to "Thinking…" while the bundle
solves) and cached in `model.agentProgram`. Subsequent clicks
consume the head of that cache — no re-solve. If the user
makes their own gesture in between, the gesture path clears
`agentProgram` back to Nothing, which forces the next click
to re-fire the engine port from the new live board.

The animation itself is owned by the Replay engine. The TS
engine produces primitive batches in `Game.WireAction` shape;
this module appends them to the action log with synthesized
gesture paths, fires each on the wire for persistence, then
kicks Replay forward. Replay walks each entry, calls
`Space.synthesizeBoardPath` because no captured path is
present, and animates with the same FSM that animates Steve's
captured drags. The agent is a clean producer of WireActions;
all rendering work lives behind the Replay seam.

-}
clickAgentPlay : Model -> ( Model, Cmd Msg, Output )
clickAgentPlay model =
    -- Don't stack agent moves on top of an already-running
    -- replay or animation — wait for the current step to land
    -- before the user can advance.
    if model.replay /= Nothing then
        ( { model | status = animationInProgressStatus }
        , Cmd.none
        , NoOutput
        )

    else
        case model.agentProgram of
            Just (batch :: rest) ->
                -- Cache live: consume head, no port call.
                let
                    ( newModel, cmd ) =
                        runAgentBatch batch rest model
                in
                ( newModel, cmd, NoOutput )

            Just [] ->
                -- Walked to the end of the program last click; tell
                -- the user, then drop the cache so the next click
                -- starts a fresh solve.
                ( { model
                    | agentProgram = Nothing
                    , status = { text = "Agent finished its program.", kind = Inform }
                  }
                , Cmd.none
                , NoOutput
                )

            Nothing ->
                -- Cache empty: fire the engine port and wait for the
                -- response to land via EngineSolveResult.
                requestAgentPlan model


{-| Compose the agent_play engine port request payload.
Differs from the hint payload in two ways:
  - op = "agent_play" (the JS glue branches on this)
  - board entries carry geometry (loc) so the engine can do
    geometry-aware verb expansion
-}
requestAgentPlan : Model -> ( Model, Cmd Msg, Output )
requestAgentPlan model =
    let
        reqId =
            model.nextEngineRequestId

        puzzleName =
            Maybe.withDefault "" model.puzzleName

        payload =
            Encode.object
                [ ( "request_id", Encode.int reqId )
                , ( "op", Encode.string "agent_play" )
                , ( "puzzle_name", Encode.string puzzleName )
                , ( "board", encodeBoardForAgentPlay model.board )
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


{-| Encode the board for agent_play: each stack carries cards
AND loc (the engine needs geometry to plan splits, pushes, and
move_stacks correctly).
-}
encodeBoardForAgentPlay : List CardStack -> Encode.Value
encodeBoardForAgentPlay board =
    Encode.list
        (\stack ->
            Encode.object
                [ ( "cards"
                  , Encode.list Card.encodeCard
                        (List.map .card stack.boardCards)
                  )
                , ( "loc"
                  , Encode.object
                        [ ( "top", Encode.int stack.loc.top )
                        , ( "left", Encode.int stack.loc.left )
                        ]
                  )
                ]
        )
        board


{-| Apply one engine-produced batch: synthesize gestures,
build action log entries, kick Replay, fire wire writes.
-}
runAgentBatch : State.AgentMoveBatch -> List State.AgentMoveBatch -> Model -> ( Model, Cmd Msg )
runAgentBatch batch remaining model =
    if List.isEmpty batch.primitives then
        -- Engine produced an empty primitive list — that should be
        -- impossible (a "do nothing" plan line). Surface it loudly
        -- rather than silently consuming the batch.
        let
            _ =
                Debug.log "agent: engine produced empty primitive batch" batch.line
        in
        ( { model
            | status = agentStalledStatus batch.line
            , agentProgram = Nothing
          }
        , Cmd.none
        )

    else
        let
            primGestures =
                synthesizeAgentGestures model batch.primitives

            entries =
                List.map agentLogEntryWith primGestures

            startSeq =
                model.nextSeq

            appended =
                { model
                    | actionLog = model.actionLog ++ entries
                    , nextSeq = startSeq + List.length entries
                    , agentProgram = Just remaining
                    , status =
                        { text = "Agent: " ++ batch.line
                        , kind = Inform
                        }
                    , replay = Just { pending = entries, paused = False }
                    , replayAnim = State.NotAnimating
                    , drag = NotDragging
                }

            wireCmds =
                case model.sessionId of
                    Just sid ->
                        List.indexedMap
                            (\i ( prim, gesture ) ->
                                Wire.sendAction sid (startSeq + i) model.puzzleName prim gesture
                            )
                            primGestures

                    Nothing ->
                        []

            boardRectCmd =
                Task.attempt BoardRectReceived
                    (Browser.Dom.getElement (State.boardDomIdFor model.gameId))
        in
        ( appended, Cmd.batch (boardRectCmd :: wireCmds) )


{-| Walk a primitive sequence against an evolving sim board,
synthesizing a gesture for each Merge/Move primitive against
the sim AT THAT POINT. Apply each primitive locally to advance
the sim before the next synthesis. Returns
`[(prim, maybeGesture)]` in the original order.
-}
synthesizeAgentGestures :
    Model
    -> List WireAction
    -> List ( WireAction, Maybe State.EnvelopeForGesture )
synthesizeAgentGestures initialModel prims =
    let
        loop simModel acc remaining =
            case remaining of
                [] ->
                    List.reverse acc

                p :: rest ->
                    let
                        synth =
                            ReplaySpace.synthesizeBoardPath p simModel 0
                                |> Maybe.map (\( path, frame ) -> { path = path, frame = frame })

                        nextSim =
                            (applyAction p simModel).model
                    in
                    loop nextSim (( p, synth ) :: acc) rest
    in
    loop initialModel [] prims


{-| Build an actionLog entry for a primitive plus its
synthesized gesture (if any). Replaces the older
`agentLogEntry` which always shipped `gesturePath = Nothing`
and forced replay to JIT-synthesize. Carrying the gesture
here means Instant Replay finds a captured path and
animates immediately.
-}
agentLogEntryWith : ( WireAction, Maybe State.EnvelopeForGesture ) -> State.ActionLogEntry
agentLogEntryWith ( action, gesture ) =
    { action = action
    , gesturePath = Maybe.map .path gesture
    , pathFrame =
        case gesture of
            Just g ->
                g.frame

            Nothing ->
                BoardFrame
    }



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


{-| Synchronous bootstrap for Puzzles. The catalog
delivered the initial state inline; no fetch, no actions to
fold. Puzzles are session-scoped to one page-load — a
reload terminates the attempt by design — so the in-memory
action log is empty at boot.
-}
bootstrapPuzzle : State.RemoteState -> String -> Model -> Model
bootstrapPuzzle initial puzzleName model =
    modelAtInitial initial
        { model
            | actionLog = []
            , puzzleInitialState = Just initial
            , status =
                { text = "Puzzle " ++ puzzleName ++ " loaded."
                , kind = Inform
                }
        }


{-| Common shape — drop the initial-state record's fields onto
the model and pin it as the replay baseline. Used by both
bootstraps.
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


animationInProgressStatus : StatusMessage
animationInProgressStatus =
    { text = "Animation in progress — wait for it to finish before clicking again."
    , kind = Scold
    }


agentStalledStatus : String -> StatusMessage
agentStalledStatus describedMove =
    { text =
        "Agent stalled: couldn't emit primitives for "
            ++ describedMove
            ++ " — see console."
    , kind = Scold
    }
