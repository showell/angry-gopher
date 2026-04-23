module Main.Play exposing
    ( Config(..)
    , Output(..)
    , init
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
import Game.Game as Game
import Game.GestureArbitration as GA
import Game.Referee as Referee
import Game.Score as Score
import Game.Strategy.Hint as Hint
import Game.WireAction as WA
import Main.Apply as Apply exposing (applyAction, refereeBounds)
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
        , StatusKind(..)
        , activeHand
        , baseModel
        )
import Main.View as View exposing (popupForCompleteTurn, statusForCompleteTurn)
import Main.Wire exposing (fetchActionLog, fetchNewSession, sendCompleteTurn)
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

                nextPath =
                    info.gesturePath
                        ++ [ { tMs = tMs, x = pos.x, y = pos.y } ]

                nextInfo =
                    { info
                        | cursor = pos
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
