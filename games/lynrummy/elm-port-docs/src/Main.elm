port module Main exposing (main)

{-| TEA bootstrap for the standalone LynRummy game.

The update function dispatches on Msg. Most branches are
trivial or delegate to a helper module:

  - **Pointer gestures** — `Main.Gesture` (startBoardCardDrag,
    startHandDrag, handleMouseUp, fetchBoardRect).
  - **State transitions** — `Main.Apply.applyAction`.
  - **HTTP** — `Main.Wire` (fetch*, sendAction, sendCompleteTurn).
  - **Rendering** — `Main.View`.
  - **Replay FSM + clock** — `Main.Replay.Time`.
  - **Replay spatial synthesis** — `Main.Replay.Space`.
  - **Model types + initial model** — `Main.State`.

What's left here is the wiring: init, update-dispatch, the
MouseMove/Up decoders, subscriptions, and the URL-path port.

-}

import Browser
import Browser.Dom
import Browser.Events
import Json.Decode as Decode exposing (Decoder)
import LynRummy.GestureArbitration as GA
import LynRummy.Referee as Referee
import LynRummy.Score as Score
import LynRummy.Tricks.Hint as Hint
import LynRummy.WireAction as WA
import Main.Apply as Apply exposing (applyAction, refereeBounds)
import Main.Gesture as Gesture
    exposing
        ( handleMouseUp
        , pointDecoder
        , startBoardCardDrag
        , startHandDrag
        )
import Main.Msg exposing (Msg(..))
import Main.Replay.Time as ReplayTime
import Main.State as State
    exposing
        ( DragState(..)
        , Flags
        , Model
        , StatusKind(..)
        , activeHand
        , baseModel
        )
import Main.View as View exposing (popupForCompleteTurn, statusForCompleteTurn, view)
import Main.Wire as Wire exposing (fetchActionLog, fetchNewSession, fetchRemoteState, sendCompleteTurn)
import Task
import Time


{-| Port: updates the URL path to `/gopher/lynrummy-elm/play/<sid>`
to match the active session. Called whenever we learn which
session we're on, so a reload finds the session again via
server-side rendering of `flags.initialSessionId` from the path.
-}
port setSessionPath : String -> Cmd msg


init : Flags -> ( Model, Cmd Msg )
init flags =
    case flags.initialSessionId of
        Just sid ->
            -- URL said we're resuming a specific game. Pull state
            -- AND the action log so Instant Replay has something to walk.
            ( { baseModel
                | sessionId = Just sid
                , status = { text = "Resuming session " ++ String.fromInt sid ++ "…", kind = Inform }
              }
            , Cmd.batch [ fetchRemoteState sid, fetchActionLog sid ]
            )

        Nothing ->
            -- Bare /gopher/lynrummy-elm/ URL — auto-create a new game.
            -- The lobby role is served by /gopher/game-lobby upstream.
            ( baseModel, fetchNewSession )



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        MouseDownOnBoardCard ref clientPoint tMs ->
            startBoardCardDrag ref clientPoint tMs model

        MouseDownOnHandCard idx clientPoint tMs ->
            startHandDrag idx clientPoint tMs model

        MouseMove pos tMs ->
            case model.drag of
                Dragging info ->
                    let
                        nextIntent =
                            GA.clickIntentAfterMove info.originalCursor pos info.clickIntent

                        nextPath =
                            info.gesturePath
                                ++ [ { tMs = tMs, x = pos.x, y = pos.y } ]
                    in
                    ( { model
                        | drag =
                            Dragging
                                { info
                                    | cursor = pos
                                    , clickIntent = nextIntent
                                    , gesturePath = nextPath
                                }
                      }
                    , Cmd.none
                    )

                NotDragging ->
                    ( model, Cmd.none )

        MouseUp pos tMs ->
            handleMouseUp pos tMs model

        WingEntered wing ->
            case model.drag of
                Dragging info ->
                    ( { model | drag = Dragging { info | hoveredWing = Just wing } }, Cmd.none )

                NotDragging ->
                    ( model, Cmd.none )

        WingLeft wing ->
            case model.drag of
                Dragging info ->
                    if info.hoveredWing == Just wing then
                        ( { model | drag = Dragging { info | hoveredWing = Nothing } }, Cmd.none )

                    else
                        ( model, Cmd.none )

                NotDragging ->
                    ( model, Cmd.none )

        ActionSent _ ->
            -- V1: fire-and-forget. Errors are ignored; server-side
            -- validation + broadcast arrive with multiplayer.
            ( model, Cmd.none )

        SessionReceived (Ok sid) ->
            -- Trust-server mode: after session creation, pull the
            -- authoritative state so both hands are populated from
            -- the server's dealer rather than the client's guess.
            -- Also pin the session into the URL so a reload
            -- resumes the same game instead of dropping to the lobby.
            ( { model | sessionId = Just sid }
            , Cmd.batch [ fetchRemoteState sid, setSessionPath (String.fromInt sid) ]
            )

        SessionReceived (Err _) ->
            -- If the server can't hand us a session, actions stay
            -- unpersisted. UI keeps working locally.
            ( model, Cmd.none )

        ClickCompleteTurn ->
            -- Client-side referee: validate the board locally
            -- first. If dirty, reject without a server round-trip
            -- and show the error inline. If clean, log + send to
            -- server for persistence. The server double-checks
            -- (as a diagnostic), but the client doesn't need
            -- permission — it owns the decision.
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
                    case model.sessionId of
                        Just sid ->
                            ( { model | actionLog = model.actionLog ++ [ WA.CompleteTurn ] }
                            , sendCompleteTurn sid
                            )

                        Nothing ->
                            -- Offline mode: no persistence, just commit the transition.
                            ( { model | actionLog = model.actionLog ++ [ WA.CompleteTurn ] }
                                |> applyAction WA.CompleteTurn
                            , Cmd.none
                            )

        CompleteTurnResponded result ->
            -- The server is the referee; its OK is a green light
            -- saying "the board is clean, the turn is valid." On
            -- OK we apply the FULL transition autonomously via
            -- applyAction → Game.applyCompleteTurn, using the
            -- client's own deck + score logic. On Err the
            -- transition is skipped and the player fixes the
            -- board. The popup is cosmetic and doesn't gate any
            -- state.
            --
            -- Diagnostic: after the client draws from its own
            -- deck, compare the cards it pulled against the
            -- server's `dealt_cards`. A mismatch means client and
            -- server have diverged — log so we can catch it
            -- early. Under true autonomy the server's role on
            -- CompleteTurn reduces to "sanity check that I am
            -- not confused."
            let
                statusMsg =
                    statusForCompleteTurn result

                popupBody =
                    popupForCompleteTurn result
            in
            case result of
                Ok outcome ->
                    let
                        preDeckSize =
                            List.length model.deck

                        newModel =
                            { model | status = statusMsg, popup = popupBody }
                                |> applyAction WA.CompleteTurn

                        postDeckSize =
                            List.length newModel.deck

                        clientDrewCount =
                            preDeckSize - postDeckSize

                        clientDrewCards =
                            List.take clientDrewCount model.deck

                        _ =
                            if clientDrewCards == outcome.dealtCards then
                                ()

                            else
                                let
                                    _ =
                                        Debug.log "CompleteTurn dealt-cards mismatch (client vs server)"
                                            { client = clientDrewCards
                                            , server = outcome.dealtCards
                                            }
                                in
                                ()
                    in
                    ( newModel, Cmd.none )

                Err _ ->
                    ( { model | status = statusMsg, popup = popupBody }
                    , Cmd.none
                    )

        PopupOk ->
            -- Pure cosmetic dismiss. The turn transition already
            -- committed in CompleteTurnResponded.
            ( { model | popup = Nothing }, Cmd.none )

        ClickInstantReplay ->
            ReplayTime.clickInstantReplay model

        ReplayFrame nowPosix ->
            ReplayTime.replayFrame (toFloat (Time.posixToMillis nowPosix)) model

        ClickReplayPauseToggle ->
            ReplayTime.clickReplayPauseToggle model

        HandCardRectReceived result ->
            ReplayTime.handCardRectReceived result model

        ActionLogFetched (Ok bundle) ->
            ( { model
                | actionLog = List.map .action bundle.actions
                , replayGestures = List.map .gesturePath bundle.actions
                , replayBaseline = Just bundle.initialState
              }
            , Cmd.none
            )

        ActionLogFetched (Err _) ->
            ( model, Cmd.none )

        StateRefreshed (Ok rs) ->
            ( { model
                | board = rs.board
                , hands = rs.hands
                , scores = rs.scores
                , activePlayerIndex = rs.activePlayerIndex
                , turnIndex = rs.turnIndex
                , deck = rs.deck
                , cardsPlayedThisTurn = rs.cardsPlayedThisTurn
                , victorAwarded = rs.victorAwarded
                , turnStartBoardScore = rs.turnStartBoardScore
                , score = Score.forStacks rs.board
              }
            , Cmd.none
            )

        StateRefreshed (Err _) ->
            ( model, Cmd.none )

        BoardRectReceived result ->
            case result of
                Ok element ->
                    let
                        -- Convert document coords (what Browser.Dom returns)
                        -- to viewport coords (what mouse clientX/Y uses), so
                        -- the cursor/rect subtraction stays correct even when
                        -- the page is scrolled.
                        rect =
                            { x = round (element.element.x - element.viewport.x)
                            , y = round (element.element.y - element.viewport.y)
                            , width = round element.element.width
                            , height = round element.element.height
                            }

                        -- Two consumers of the board rect live in the same
                        -- Msg: an active live-drag (for drop-target math),
                        -- and an active replay (for board-frame → viewport
                        -- translation in synthesized paths). Update both.
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
                    -- Dev console: log the failure so future-Claude
                    -- sees it. Replay synthesis will fall back to
                    -- the documentary board-viewport constants.
                    let
                        _ =
                            Debug.log "BoardRectReceived err" err
                    in
                    ( model, Cmd.none )

        ClickHint ->
            -- Client-autonomous hint: ask the local Hint.buildSuggestions
            -- composer for a ranked list of plays. Highlight the hand
            -- cards that the top suggestion would consume. No server
            -- call — the 7 trick detectors and the priority-order
            -- orchestration are all ported.
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


{-| MouseMove decoder that captures both the cursor point and
the `MouseEvent.timeStamp`. Used only during an active drag.
The timestamp is performance.now()-style (ms since the document's
time origin, fractional) and is recorded into the drag's
gesturePath for behaviorist telemetry.
-}
mouseMoveDecoder : Decoder Msg
mouseMoveDecoder =
    Decode.map2 MouseMove
        pointDecoder
        (Decode.field "timeStamp" Decode.float)


{-| MouseUp decoder parallel to mouseMoveDecoder. Captures the
release point + timeStamp so a pure click (mousedown → mouseup
with no intervening move) still produces a two-sample gesture
path: [down-point, up-point]. Keeps the wire model lossless
for splits.
-}
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
                        -- onAnimationFrame (~60fps) drives both the
                        -- drag-path interpolation and the 1s beat
                        -- between actions. One subscription, all
                        -- phases.
                        [ Browser.Events.onAnimationFrame ReplayFrame ]

                Nothing ->
                    []
    in
    Sub.batch (dragSubs ++ replaySubs)



-- MAIN


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
