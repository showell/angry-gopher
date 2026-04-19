port module Main exposing (main)

{-| TEA bootstrap for the standalone LynRummy game.

Current scope: opening board + opening hand + stack-to-stack
drag + hand-card-to-board drag (merge via wing OR place as
singleton). No turns, no draw/discard, no scoring.

-}

import Browser
import Browser.Dom
import Browser.Events
import Html exposing (Html, div)
import Html.Attributes exposing (href, id, style)
import Html.Events as Events
import Http
import Json.Decode as Decode exposing (Decoder)
import LynRummy.BoardActions as BoardActions exposing (Side(..))
import LynRummy.BoardGeometry as BoardGeometry
import LynRummy.Card as Card exposing (Card)
import LynRummy.CardStack as CardStack exposing (BoardLocation, CardStack, HandCard, stacksEqual)
import LynRummy.Dealer
import LynRummy.Game as Game
import LynRummy.GestureArbitration as GA
import LynRummy.Hand as Hand exposing (Hand)
import LynRummy.PlayerTurn exposing (CompleteTurnResult(..))
import LynRummy.Referee as Referee
import LynRummy.Score as Score
import LynRummy.Tricks.Hint as Hint
import LynRummy.WingOracle as WingOracle exposing (WingId)
import LynRummy.WireAction as WA exposing (WireAction)
import Main.Apply as Apply exposing (applyChange, applyWireAction, findHandCard, refereeBounds)
import Main.Gesture as Gesture
    exposing
        ( clearDrag
        , fetchBoardRect
        , handleMouseUp
        , pointDecoder
        , startBoardCardDrag
        , startHandDrag
        )
import Main.Msg exposing (Msg(..))
import Main.View as View exposing (popupForCompleteTurn, statusForCompleteTurn, view)
import Main.Wire as Wire exposing (fetchActionLog, fetchNewSession, fetchRemoteState, sendAction, sendCompleteTurn)
import Main.State as State
    exposing
        ( ActionLogBundle
        , CompleteTurnOutcome
        , DragInfo
        , DragSource(..)
        , DragState(..)
        , Flags
        , Model
        , Point
        , PopupContent
        , RemoteState
        , ReplayProgress
        , StatusKind(..)
        , StatusMessage
        , activeHand
        , baseModel
        , boardDomId
        , setActiveHand
        )
import Task
import Time



-- Data types (Model, DragState, StatusMessage, etc.) now live
-- in Main.State. Initial Model is State.baseModel.


{-| Port: updates window.location.hash to match the active
session. Called whenever we learn which session we're on, so a
reload finds the session again via the flags pathway.
-}
port setSessionHash : String -> Cmd msg


init : Flags -> ( Model, Cmd Msg )
init flags =
    case flags.initialSessionId of
        Just sid ->
            -- URL hash said we're resuming a specific game. Pull state
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


-- HTTP calls + decoders now live in Main.Wire.



-- MSG


-- Msg now lives in Main.Msg.


-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        MouseDownOnBoardCard ref clientPoint ->
            startBoardCardDrag ref clientPoint model

        MouseDownOnHandCard idx clientPoint ->
            startHandDrag idx clientPoint model

        MouseMove pos ->
            case model.drag of
                Dragging info ->
                    let
                        nextIntent =
                            GA.clickIntentAfterMove info.originalCursor pos info.clickIntent
                    in
                    ( { model
                        | drag =
                            Dragging
                                { info | cursor = pos, clickIntent = nextIntent }
                      }
                    , Cmd.none
                    )

                NotDragging ->
                    ( model, Cmd.none )

        MouseUp ->
            handleMouseUp model

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
            -- Also pin the session into the URL hash so a reload
            -- resumes the same game instead of dropping to the lobby.
            ( { model | sessionId = Just sid }
            , Cmd.batch [ fetchRemoteState sid, setSessionHash (String.fromInt sid) ]
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
                                |> applyWireAction WA.CompleteTurn
                            , Cmd.none
                            )

        CompleteTurnResponded result ->
            -- The server is the referee; its OK is a green light
            -- saying "the board is clean, the turn is valid." On
            -- OK we apply the FULL transition autonomously via
            -- applyWireAction → Game.applyCompleteTurn, using the
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
                                |> applyWireAction WA.CompleteTurn

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
            -- Rewind to the session's true pre-first-action state
            -- (fetched from /actions on bootstrap). Falls back to
            -- hardcoded Dealer fixtures only if the baseline never
            -- arrived — e.g., a session that hasn't loaded yet.
            let
                rewound =
                    case model.replayBaseline of
                        Just baseline ->
                            { model
                                | board = baseline.board
                                , hands = baseline.hands
                                , scores = baseline.scores
                                , activePlayerIndex = baseline.activePlayerIndex
                                , turnIndex = baseline.turnIndex
                                , deck = baseline.deck
                                , cardsPlayedThisTurn = baseline.cardsPlayedThisTurn
                                , victorAwarded = baseline.victorAwarded
                                , turnStartBoardScore = baseline.turnStartBoardScore
                                , score = Score.forStacks baseline.board
                            }

                        Nothing ->
                            { model
                                | board = LynRummy.Dealer.initialBoard
                                , hands = [ LynRummy.Dealer.openingHand, Hand.empty ]
                                , scores = [ 0, 0 ]
                                , activePlayerIndex = 0
                                , turnIndex = 0
                                , deck = []
                                , cardsPlayedThisTurn = 0
                                , victorAwarded = False
                                , turnStartBoardScore = Score.forStacks LynRummy.Dealer.initialBoard
                                , score = Score.forStacks LynRummy.Dealer.initialBoard
                            }
            in
            ( { rewound
                | status = { text = "Replaying…", kind = Inform }
                , replay = Just { step = 0, paused = False }
              }
            , Cmd.none
            )

        ReplayTick _ ->
            case model.replay of
                Nothing ->
                    ( model, Cmd.none )

                Just progress ->
                    case listAt progress.step model.actionLog of
                        Nothing ->
                            -- Walked off the end: the final model state IS the
                            -- authoritative state. Client owns its data — no
                            -- server fetch needed.
                            ( { model
                                | replay = Nothing
                                , status = { text = "Replay complete.", kind = Celebrate }
                              }
                            , Cmd.none
                            )

                        Just action ->
                            -- Same update path a local gesture would take —
                            -- the only thing replay mode changes is where the
                            -- next action comes from.
                            ( { model | replay = Just { progress | step = progress.step + 1 } }
                                |> applyWireAction action
                            , Cmd.none
                            )

        ClickReplayPauseToggle ->
            case model.replay of
                Just progress ->
                    ( { model
                        | replay =
                            Just
                                { progress | paused = not progress.paused }
                      }
                    , Cmd.none
                    )

                Nothing ->
                    ( model, Cmd.none )

        ActionLogFetched (Ok bundle) ->
            ( { model
                | actionLog = bundle.actions
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
            case ( model.drag, result ) of
                ( Dragging info, Ok element ) ->
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
                    in
                    ( { model | drag = Dragging { info | boardRect = Just rect } }, Cmd.none )

                _ ->
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


-- Drag machinery (startBoardCardDrag, startHandDrag,
-- fetchBoardRect, handleMouseUp, resolveGesture, cursorOverBoard,
-- dropLoc) now lives in Main.Gesture.


-- sendAction / sendCompleteTurn + decoders live in Main.Wire.


-- Ceremony helpers (statusForCompleteTurn, popupForCompleteTurn,
-- popupFromOutcome, pluralize) now live in Main.View.


-- clearDrag is in Main.Gesture.


-- applyWireAction and helpers now live in Main.Apply.


-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    let
        dragSubs =
            case model.drag of
                Dragging _ ->
                    [ Browser.Events.onMouseMove (Decode.map MouseMove pointDecoder)
                    , Browser.Events.onMouseUp (Decode.succeed MouseUp)
                    ]

                NotDragging ->
                    []

        replaySubs =
            case model.replay of
                Just progress ->
                    if progress.paused then
                        []

                    else
                        [ Time.every 500 ReplayTick ]

                Nothing ->
                    []
    in
    Sub.batch (dragSubs ++ replaySubs)


-- pointDecoder is in Main.Gesture.



-- View (incl. top bar, status bar, hand column, board column,
-- drag overlay, popup) lives in Main.View.



-- HELPERS


listAt : Int -> List a -> Maybe a
listAt i xs =
    List.head (List.drop i xs)


-- MAIN


main : Program Flags Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
