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
surface, now factored out so BOARD_LAB (and future
multi-game-per-page hosts) can embed a single Play instance
per puzzle without inheriting the main app's top-level
port + wrapper shape.

Phase I of REFACTOR_EMBEDDABLE_PLAY — a literal relocation
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
import Json.Decode as Decode exposing (Decoder)
import Game.Agent.Bfs as Bfs
import Game.Agent.GeometryPlan as AgentGeometry
import Game.Agent.Move as AgentMove exposing (Move)
import Game.Agent.Verbs as AgentVerbs
import Game.Game as Game
import Game.GestureArbitration as GA
import Game.Referee as Referee
import Game.Score as Score
import Game.Strategy.Hint as Hint
import Game.WireAction as WA exposing (WireAction)
import Main.Apply exposing (applyAction, refereeBounds)
import Main.Gesture as Gesture
    exposing
        ( handleMouseUp
        , pointDecoder
        , startBoardCardDrag
        , startHandDrag
        )
import Main.Msg exposing (Msg(..))
import Game.Replay.Time as ReplayTime
import Main.State as State
    exposing
        ( ActionLogBundle
        , DragState(..)
        , Flags
        , Model
        , PathFrame(..)
        , StatusKind(..)
        , activeHand
        , baseModel
        )
import Main.View as View exposing (popupForCompleteTurn, statusForCompleteTurn)
import Main.Wire as Wire exposing (fetchActionLog, fetchNewSession, sendCompleteTurn)
import Task
import Time
import Html exposing (Html)



-- CONFIG


{-| Bootstrap shapes Play can start in. Each one maps to a
different init Cmd, but the resulting Model shape is the
same.

  - `NewSession` — no session yet; fire `fetchNewSession` and
    wait for the server to allocate one. Used by the main
    app's default landing page.
  - `ResumeSession sid` — URL says we're resuming session
    `sid`; fetch its action log and reconstruct state.
  - `PuzzleSession sid` — BOARD_LAB created a puzzle session
    (hand-crafted initial state stored in
    `lynrummy_puzzle_seeds`). Same bootstrap as resume; the
    distinct variant exists so the status message and
    eventually-different UI can reflect "this is a puzzle,
    not a saved game" without inspecting stored data.

-}
type Config
    = NewSession
    | ResumeSession Int
    | PuzzleSession Int



-- OUTPUT


{-| Emitted from `update` when the host (Main.elm or the
BOARD_LAB gallery) needs to do something beyond what Play
can do for itself. Today there's one case — fire the host's
port to pin the session id into the URL — plus the default
no-op.
-}
type Output
    = NoOutput
    | SessionChanged Int



-- INIT


{-| Boot state from a Config. Each variant fires its own Cmd;
the resulting Model shape is the same (an empty baseModel
that the bundle fetch will hydrate once it arrives).
-}
init : Config -> ( Model, Cmd Msg )
init config =
    case config of
        NewSession ->
            ( baseModel, fetchNewSession )

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

        PuzzleSession sid ->
            ( { baseModel
                | sessionId = Just sid
                , gameId = String.fromInt sid
                , hideTurnControls = True
                , status =
                    { text = "Puzzle " ++ String.fromInt sid ++ " loaded."
                    , kind = Inform
                    }
              }
            , fetchActionLog sid
            )



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg, Output )
update msg model =
    case msg of
        MouseDownOnBoardCard ref clientPoint tMs ->
            withNoOutput (startBoardCardDrag ref clientPoint tMs model)

        MouseDownOnHandCard idx clientPoint tMs ->
            withNoOutput (startHandDrag idx clientPoint tMs model)

        MouseMove pos tMs ->
            withNoOutput (mouseMove pos tMs model)

        MouseUp pos tMs ->
            withNoOutput (handleMouseUp pos tMs model)

        ActionSent _ ->
            ( model, Cmd.none, NoOutput )

        SessionReceived (Ok sid) ->
            -- Session created server-side. Fetch the bundle for
            -- local bootstrap; emit SessionChanged so the host
            -- pins the URL.
            ( { model | sessionId = Just sid }
            , fetchActionLog sid
            , SessionChanged sid
            )

        SessionReceived (Err _) ->
            ( model, Cmd.none, NoOutput )

        ClickCompleteTurn ->
            withNoOutput (clickCompleteTurn model)

        CompleteTurnResponded result ->
            let
                _ =
                    Debug.log "[CompleteTurn server response]" result
            in
            ( model, Cmd.none, NoOutput )

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

        ActionLogFetched (Err _) ->
            ( model, Cmd.none, NoOutput )

        BoardRectReceived result ->
            withNoOutput (boardRectReceived result model)

        ClickHint ->
            withNoOutput (clickHint model)

        ClickAgentPlay ->
            withNoOutput (clickAgentPlay model)


withNoOutput : ( Model, Cmd Msg ) -> ( Model, Cmd Msg, Output )
withNoOutput ( m, c ) =
    ( m, c, NoOutput )



-- UPDATE HELPERS


mouseMove : State.Point -> Float -> Model -> ( Model, Cmd Msg )
mouseMove pos tMs model =
    case model.drag of
        Dragging info ->
            let
                nextIntent =
                    GA.clickIntentAfterMove info.originalCursor pos info.clickIntent

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
                        , clickIntent = nextIntent
                        , gesturePath = nextPath
                    }

                hoveredWing =
                    Gesture.floaterOverWing nextInfo

                withHover =
                    { nextInfo | hoveredWing = hoveredWing }

                statusAfterMove =
                    if hoveredWing /= info.hoveredWing then
                        case hoveredWing of
                            Just _ ->
                                Gesture.wingHoverStatus

                            Nothing ->
                                model.status

                    else
                        model.status
            in
            ( { model | drag = Dragging withHover, status = statusAfterMove }
            , Cmd.none
            )

        NotDragging ->
            ( model, Cmd.none )


clickCompleteTurn : Model -> ( Model, Cmd Msg )
clickCompleteTurn model =
    case Referee.validateTurnComplete model.board refereeBounds of
        Err refErr ->
            ( { model
                | status =
                    { text = "Board isn't clean: " ++ refErr.message
                    , kind = Scold
                    }
              }
            , Cmd.none
            )

        Ok () ->
            let
                completeTurnEntry =
                    { action = WA.CompleteTurn
                    , gesturePath = Nothing
                    , pathFrame = State.ViewportFrame
                    }

                withEntry =
                    { model | actionLog = model.actionLog ++ [ completeTurnEntry ] }

                ( afterTurn, turnOutcome ) =
                    Game.applyCompleteTurn withEntry

                newModel =
                    { afterTurn
                        | score = Score.forStacks afterTurn.board
                        , status = statusForCompleteTurn (Ok turnOutcome)
                        , popup = popupForCompleteTurn (Ok turnOutcome)
                    }

                persistCmd =
                    case model.sessionId of
                        Just sid ->
                            sendCompleteTurn sid

                        Nothing ->
                            Cmd.none
            in
            ( newModel, persistCmd )


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
                        Dragging info ->
                            Dragging { info | boardRect = Just rect }

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


clickHint : Model -> ( Model, Cmd Msg )
clickHint model =
    -- In puzzle context the active hand is always empty, so the
    -- hand-driven Hint.buildSuggestions has nothing to say. Fall
    -- back to BFS: solve the current board, surface the first
    -- planned move as a status nudge.
    if model.hideTurnControls then
        bfsHint model

    else
        handHint model


handHint : Model -> ( Model, Cmd Msg )
handHint model =
    let
        suggestions =
            Hint.buildSuggestions (activeHand model) model.board
    in
    case suggestions of
        first :: _ ->
            ( { model
                | hintedCards = first.handCards
                , status =
                    { text = first.description
                    , kind = Inform
                    }
              }
            , Cmd.none
            )

        [] ->
            ( { model
                | hintedCards = []
                , status =
                    { text = "No hint — no obvious play for this hand on this board."
                    , kind = Inform
                    }
              }
            , Cmd.none
            )


bfsHint : Model -> ( Model, Cmd Msg )
bfsHint model =
    case Bfs.solveBoard model.board of
        Just (firstMove :: _) ->
            ( { model
                | hintedCards = []
                , status =
                    { text = "Hint: " ++ AgentMove.describe firstMove
                    , kind = Inform
                    }
              }
            , Cmd.none
            )

        Just [] ->
            ( { model
                | hintedCards = []
                , status =
                    { text = "Board is already clean — nothing to do."
                    , kind = Inform
                    }
              }
            , Cmd.none
            )

        Nothing ->
            ( { model
                | hintedCards = []
                , status =
                    { text = "BFS found no plan within budget."
                    , kind = Inform
                    }
              }
            , Cmd.none
            )


{-| Each click plays exactly the next BFS plan line — i.e. the
primitives for one logical move. Then it stops, so the user
can keep clicking to walk through the program one line at a
time.

The plan is computed ONCE on the first click and cached in
`model.agentProgram` (a "program counter" of remaining
moves). Subsequent clicks consume the head of that cache —
no re-solve. If the user makes their own gesture in between,
the gesture path clears `agentProgram` back to Nothing,
which forces the next click to re-solve from the new live
board.

The animation itself is owned by the Replay engine. We expand
the move into a sequence of WireActions, append each to the
action log with no captured gesture path, fire each on the
wire for persistence, then kick Replay forward from the new
tail with `stopAtStep` set to the post-tail index so it stops
when the move's primitives are exhausted (instead of running
to end-of-log). Replay walks each entry, calls
`Space.synthesizeBoardPath` because no captured path is
present, and animates with the same FSM that animates Steve's
captured drags. The agent is a clean producer of WireActions;
all rendering work lives behind the Replay seam. -}
clickAgentPlay : Model -> ( Model, Cmd Msg )
clickAgentPlay model =
    -- Don't stack agent moves on top of an already-running
    -- replay or animation — wait for the current step to land
    -- before the user can advance.
    if model.replay /= Nothing then
        ( model, Cmd.none )

    else
        case nextAgentMove model of
            Just ( move, remaining ) ->
                runAgentMove move remaining model

            Nothing ->
                -- nextAgentMove already filled in the right
                -- status; just hand the model back unchanged.
                ( noteAgentStatus model, Cmd.none )


{-| Resolve the next move to play, using the cached program
counter when one's live and re-solving from the live board
otherwise. Returns Nothing when there's nothing left to do
AND writes a status message describing why. -}
nextAgentMove : Model -> Maybe ( Move, List Move )
nextAgentMove model =
    case model.agentProgram of
        Just (move :: rest) ->
            Just ( move, rest )

        Just [] ->
            Nothing

        Nothing ->
            case Bfs.solveBoard model.board of
                Just (move :: rest) ->
                    Just ( move, rest )

                _ ->
                    Nothing


noteAgentStatus : Model -> Model
noteAgentStatus model =
    let
        text =
            case model.agentProgram of
                Just [] ->
                    "Agent finished its program."

                _ ->
                    case Bfs.solveBoard model.board of
                        Just [] ->
                            "Board is already clean — nothing to do."

                        _ ->
                            "Agent could not find a plan within budget."
    in
    { model
        | agentProgram = Nothing
        , status = { text = text, kind = Inform }
    }


runAgentMove : Move -> List Move -> Model -> ( Model, Cmd Msg )
runAgentMove move remaining model =
    let
        -- Verbs decompose the logical move; GeometryPlan injects
        -- pre-flight MoveStacks before any merge whose in-place
        -- result would overflow the board. Without the wrapper,
        -- the referee rejects the merge and the agent stalls.
        primitives =
            AgentVerbs.moveToPrimitives model.board move
                |> AgentGeometry.planActions model.board

        newEntries =
            List.map agentLogEntry primitives

        appended =
            { model
                | actionLog = model.actionLog ++ newEntries
                , agentProgram = Just remaining
                , status =
                    { text = "Agent: " ++ AgentMove.describe move
                    , kind = Inform
                    }
                , replay = Just { pending = newEntries, paused = False }
                , replayAnim = State.NotAnimating
                , drag = NotDragging
            }

        wireCmds =
            case model.sessionId of
                Just sid ->
                    List.map (\p -> Wire.sendAction sid p Nothing) primitives

                Nothing ->
                    []

        boardRectCmd =
            -- Replay synthesizes paths in board frame; the live
            -- board rect is needed downstream by translation
            -- helpers. Refresh it now so it's fresh for the
            -- about-to-run animation.
            Task.attempt BoardRectReceived
                (Browser.Dom.getElement (State.boardDomIdFor model.gameId))
    in
    ( appended, Cmd.batch (boardRectCmd :: wireCmds) )


agentLogEntry : WireAction -> State.ActionLogEntry
agentLogEntry action =
    { action = action
    , gesturePath = Nothing
    , pathFrame = BoardFrame
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
                Dragging _ ->
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
        initial =
            bundle.initialState

        atInitial =
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
                , actionLog = bundle.actions
                , replayBaseline = Just initial
            }
    in
    List.foldl
        (\entry m -> .model (applyAction entry.action m))
        atInitial
        bundle.actions
