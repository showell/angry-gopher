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
import LynRummy.View as View
import LynRummy.WingOracle as WingOracle exposing (WingId)
import LynRummy.WireAction as WA exposing (WireAction)
import Main.Apply as Apply exposing (applyChange, applyWireAction, findHandCard, refereeBounds)
import Main.Msg exposing (Msg(..))
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


startBoardCardDrag :
    { stackIndex : Int, cardIndex : Int }
    -> Point
    -> Model
    -> ( Model, Cmd Msg )
startBoardCardDrag { stackIndex, cardIndex } clientPoint model =
    case ( model.drag, listAt stackIndex model.board ) of
        ( NotDragging, Just stack ) ->
            let
                wings =
                    WingOracle.wingsForStack stackIndex model.board

                halfWidth =
                    CardStack.stackDisplayWidth stack // 2
            in
            ( { model
                | drag =
                    Dragging
                        { source = FromBoardStack stackIndex
                        , cursor = clientPoint
                        , originalCursor = clientPoint
                        , grabOffset = { x = halfWidth, y = 20 }
                        , wings = wings
                        , hoveredWing = Nothing
                        , boardRect = Nothing
                        , clickIntent = Just cardIndex
                        }
              }
            , fetchBoardRect
            )

        _ ->
            ( model, Cmd.none )


startHandDrag : Int -> Point -> Model -> ( Model, Cmd Msg )
startHandDrag idx clientPoint model =
    case ( model.drag, listAt idx (activeHand model).handCards ) of
        ( NotDragging, Just handCard ) ->
            let
                wings =
                    WingOracle.wingsForHandCard handCard model.board

                halfWidth =
                    CardStack.stackPitch // 2
            in
            ( { model
                | drag =
                    Dragging
                        { source = FromHandCard idx
                        , cursor = clientPoint
                        , originalCursor = clientPoint
                        , grabOffset = { x = halfWidth, y = 20 }
                        , wings = wings
                        , hoveredWing = Nothing
                        , boardRect = Nothing
                        , clickIntent = Nothing
                        }
              }
            , fetchBoardRect
            )

        _ ->
            ( model, Cmd.none )


fetchBoardRect : Cmd Msg
fetchBoardRect =
    Browser.Dom.getElement boardDomId
        |> Task.attempt BoardRectReceived


handleMouseUp : Model -> ( Model, Cmd Msg )
handleMouseUp model =
    case model.drag of
        NotDragging ->
            ( model, Cmd.none )

        Dragging info ->
            let
                maybeAction =
                    resolveGesture info model

                modelAfterDragClear =
                    clearDrag model

                modelAfterAction =
                    case maybeAction of
                        Just action ->
                            applyWireAction action modelAfterDragClear

                        Nothing ->
                            modelAfterDragClear

                ( finalModel, cmd ) =
                    case ( maybeAction, modelAfterAction.sessionId ) of
                        ( Just action, Just sid ) ->
                            ( { modelAfterAction
                                | actionLog = modelAfterAction.actionLog ++ [ action ]
                              }
                            , sendAction sid action
                            )

                        _ ->
                            ( modelAfterAction, Cmd.none )
            in
            ( finalModel, cmd )


{-| Resolve a completed drag gesture into the WireAction (if
any) it produces. Pure extraction — no state mutation. The
actual model update flows through applyWireAction, same path
as replay and (eventually) wire-received actions.

Click precedence over drag mirrors the TS engine's
process_pointerup logic: if clickIntent survived, it's a split;
otherwise dispatch on (hoveredWing, source, cursorOverBoard).
-}
resolveGesture : DragInfo -> Model -> Maybe WireAction
resolveGesture info model =
    case ( info.clickIntent, info.source ) of
        ( Just cardIdx, FromBoardStack stackIdx ) ->
            Just (WA.Split { stackIndex = stackIdx, cardIndex = cardIdx })

        _ ->
            case ( info.hoveredWing, info.source ) of
                ( Just wing, FromBoardStack sourceIdx ) ->
                    Just
                        (WA.MergeStack
                            { sourceStack = sourceIdx
                            , targetStack = wing.stackIndex
                            , side = wing.side
                            }
                        )

                ( Just wing, FromHandCard handIdx ) ->
                    case listAt handIdx (activeHand model).handCards of
                        Just handCard ->
                            Just
                                (WA.MergeHand
                                    { handCard = handCard.card
                                    , targetStack = wing.stackIndex
                                    , side = wing.side
                                    }
                                )

                        Nothing ->
                            Nothing

                ( Nothing, FromHandCard handIdx ) ->
                    if cursorOverBoard info then
                        case ( listAt handIdx (activeHand model).handCards, dropLoc info ) of
                            ( Just handCard, Just loc ) ->
                                Just (WA.PlaceHand { handCard = handCard.card, loc = loc })

                            _ ->
                                Nothing

                    else
                        Nothing

                ( Nothing, FromBoardStack stackIdx ) ->
                    if cursorOverBoard info then
                        case dropLoc info of
                            Just loc ->
                                Just (WA.MoveStack { stackIndex = stackIdx, newLoc = loc })

                            Nothing ->
                                Nothing

                    else
                        Nothing


cursorOverBoard : DragInfo -> Bool
cursorOverBoard info =
    case info.boardRect of
        Just rect ->
            GA.cursorInRect info.cursor rect

        Nothing ->
            False


{-| Board-relative drop location derived from cursor + grab
offset + board rect. `Nothing` if the board rect hasn't
arrived yet (race between drag-start and the Browser.Dom.getElement
task completing).
-}
dropLoc : DragInfo -> Maybe BoardLocation
dropLoc info =
    info.boardRect
        |> Maybe.map
            (\rect ->
                { left = info.cursor.x - info.grabOffset.x - rect.x
                , top = info.cursor.y - info.grabOffset.y - rect.y
                }
            )


-- sendAction / sendCompleteTurn + decoders live in Main.Wire.


statusForCompleteTurn : Result Http.Error CompleteTurnOutcome -> StatusMessage
statusForCompleteTurn outcome =
    case outcome of
        Ok o ->
            case o.result of
                Success ->
                    { text = "Turn complete. Board is growing!", kind = Celebrate }

                SuccessButNeedsCards ->
                    { text = "Turn complete, but you didn't play any cards.", kind = Inform }

                SuccessAsVictor ->
                    { text = "Hand emptied — victor!", kind = Celebrate }

                SuccessWithHandEmptied ->
                    { text = "Hand emptied — nice.", kind = Celebrate }

                Failure ->
                    { text = "Board isn't clean — tidy up before ending the turn.", kind = Scold }

        Err _ ->
            { text = "Couldn't reach the server to complete the turn.", kind = Scold }


{-| Picks the right character (Angry Cat / Oliver / Steve) and
writes the per-branch narration. Matches the casting in
angry-cat's game.ts: Angry Cat scolds dirty boards, Oliver
sympathizes when no cards played, Steve celebrates everything
else. The "will receive" framing keeps the UI on the pre-flip
view until the user dismisses.
-}
popupForCompleteTurn : Result Http.Error CompleteTurnOutcome -> Maybe PopupContent
popupForCompleteTurn result =
    case result of
        Ok outcome ->
            Just (popupFromOutcome outcome)

        Err _ ->
            Just
                { admin = "Angry Cat"
                , body = "Couldn't reach the server to complete your turn."
                }


popupFromOutcome : CompleteTurnOutcome -> PopupContent
popupFromOutcome { result, turnScore, cardsDrawn } =
    case result of
        Failure ->
            { admin = "Angry Cat"
            , body =
                "The board is not clean!\n\n(nor is my litter box)\n\n"
                    ++ "Drag stacks back where they belong."
            }

        SuccessButNeedsCards ->
            { admin = "Oliver"
            , body =
                "Sorry you couldn't find a move.\n\n"
                    ++ "I'm going back to my nap!\n\n"
                    ++ "You scored "
                    ++ String.fromInt turnScore
                    ++ " points for your turn.\n\n"
                    ++ "We have dealt you "
                    ++ pluralize cardsDrawn "more card"
                    ++ " for your next turn."
            }

        SuccessAsVictor ->
            { admin = "Steve"
            , body =
                "You are the first person to play all their cards!\n\n"
                    ++ "That earns you a 1500 point bonus.\n\n"
                    ++ "You got "
                    ++ String.fromInt turnScore
                    ++ " points for this turn.\n\n"
                    ++ "We have dealt you "
                    ++ pluralize cardsDrawn "more card"
                    ++ " for your next turn.\n\n"
                    ++ "Keep winning!"
            }

        SuccessWithHandEmptied ->
            { admin = "Steve"
            , body =
                "Good job!\n\n"
                    ++ "You scored "
                    ++ String.fromInt turnScore
                    ++ " for this turn!\n\n"
                    ++ "We gave you a bonus for emptying your hand.\n\n"
                    ++ "We have dealt you "
                    ++ pluralize cardsDrawn "more card"
                    ++ " for your next turn."
            }

        Success ->
            { admin = "Steve"
            , body =
                "The board is growing!\n\n"
                    ++ "You receive "
                    ++ String.fromInt turnScore
                    ++ " points for this turn!"
            }


pluralize : Int -> String -> String
pluralize n word =
    String.fromInt n
        ++ " "
        ++ word
        ++ (if n == 1 then
                ""

            else
                "s"
           )


clearDrag : Model -> Model
clearDrag model =
    { model | drag = NotDragging }


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


pointDecoder : Decoder Point
pointDecoder =
    Decode.map2 (\x y -> { x = round x, y = round y })
        (Decode.field "clientX" Decode.float)
        (Decode.field "clientY" Decode.float)



-- VIEW


view : Model -> Html Msg
view model =
    div
        [ style "font-family" "system-ui, sans-serif" ]
        [ viewTopBar
        , viewStatusBar model.status
        , div
            [ style "padding" "20px"
            , style "display" "flex"
            , style "gap" "24px"
            , style "align-items" "flex-start"
            ]
            [ handColumn model
            , boardColumn model
            ]
        , draggedOverlay model
        , viewPopup
            (case model.replay of
                Just _ ->
                    Nothing

                Nothing ->
                    model.popup
            )
        ]


{-| Cheapest-possible popup rendering: fixed-position backdrop
covering the viewport, centered white card with the admin's
name, the body text (pre-wrapped to preserve newlines), and a
single OK button. No focus trap, no ESC handler, no click-outside
dismiss — just the OK button. Good enough for ceremony.
-}
viewPopup : Maybe PopupContent -> Html Msg
viewPopup maybePopup =
    case maybePopup of
        Nothing ->
            Html.text ""

        Just { admin, body } ->
            div
                [ style "position" "fixed"
                , style "inset" "0"
                , style "background-color" "rgba(0, 0, 0, 0.45)"
                , style "display" "flex"
                , style "align-items" "center"
                , style "justify-content" "center"
                , style "z-index" "2000"
                ]
                [ div
                    [ style "background" "white"
                    , style "border" ("1px solid " ++ View.navy)
                    , style "border-radius" "12px"
                    , style "padding" "24px 28px"
                    , style "max-width" "420px"
                    , style "box-shadow" "0 10px 30px rgba(0, 0, 0, 0.25)"
                    ]
                    [ div
                        [ style "font-weight" "bold"
                        , style "color" View.navy
                        , style "font-size" "15px"
                        , style "margin-bottom" "10px"
                        ]
                        [ Html.text admin ]
                    , Html.pre
                        [ style "font-family" "inherit"
                        , style "white-space" "pre-wrap"
                        , style "margin" "0 0 18px 0"
                        , style "font-size" "14px"
                        , style "line-height" "1.45"
                        ]
                        [ Html.text body ]
                    , Html.button
                        [ Events.onClick PopupOk
                        , style "background" View.navy
                        , style "color" "white"
                        , style "border" "none"
                        , style "padding" "8px 20px"
                        , style "border-radius" "4px"
                        , style "cursor" "pointer"
                        , style "font-size" "14px"
                        ]
                        [ Html.text "OK" ]
                    ]
                ]


viewTopBar : Html Msg
viewTopBar =
    div
        [ style "background-color" View.navy
        , style "color" "white"
        , style "text-align" "center"
        , style "padding" "6px"
        , style "font-size" "18px"
        ]
        [ Html.text "Welcome to Lyn Rummy! Have fun!" ]


viewStatusBar : StatusMessage -> Html Msg
viewStatusBar status =
    let
        color =
            case status.kind of
                Inform ->
                    "#31708f"

                Celebrate ->
                    "green"

                Scold ->
                    "red"
    in
    div
        [ style "padding" "6px 20px"
        , style "font-size" "15px"
        , style "color" color
        , style "border-bottom" "1px solid #eee"
        ]
        [ Html.text status.text ]


handColumn : Model -> Html Msg
handColumn model =
    div
        [ style "min-width" "240px"
        , style "padding-right" "20px"
        , style "border-right" "1px gray solid"
        ]
        (div
            [ style "color" "#666"
            , style "font-size" "13px"
            , style "margin-top" "12px"
            ]
            [ Html.text ("Turn " ++ String.fromInt (model.turnIndex + 1)) ]
            :: List.indexedMap (viewPlayerRow model) model.hands
        )


{-| One player's row — name + score + either full interactive
hand + turn controls (if active) or a card-count line (if not).
Mirrors angry-cat's PhysicalPlayer.populate two-row layout: both
players are always visible, but only the active one's hand faces
are revealed.
-}
viewPlayerRow : Model -> Int -> Hand -> Html Msg
viewPlayerRow model idx hand =
    let
        isActive =
            idx == model.activePlayerIndex

        playerName =
            "Player " ++ String.fromInt (idx + 1)

        nameSuffix =
            if isActive then
                " (your turn)"

            else
                ""

        nameColor =
            if isActive then
                View.navy

            else
                "#666"
    in
    let
        playerTotal =
            case listAt idx model.scores of
                Just n ->
                    n

                Nothing ->
                    0
    in
    div
        [ style "padding-bottom" "15px"
        , style "margin-bottom" "12px"
        , style "border-bottom" "1px #000080 solid"
        ]
        (div
            [ style "font-weight" "bold"
            , style "font-size" "16px"
            , style "color" nameColor
            , style "margin-top" "8px"
            ]
            [ Html.text (playerName ++ nameSuffix) ]
            :: div
                [ style "color" "maroon"
                , style "margin-bottom" "4px"
                , style "margin-top" "4px"
                ]
                [ Html.text ("Score: " ++ String.fromInt playerTotal) ]
            :: (if isActive then
                    [ View.viewHandHeading
                    , View.viewHand { attrsForCard = handCardAttrs model.drag model.hintedCards } hand
                    , viewTurnControls model
                    ]

                else
                    [ div
                        [ style "color" "#888"
                        , style "font-size" "13px"
                        ]
                        [ Html.text (String.fromInt (List.length hand.handCards) ++ " cards") ]
                    ]
               )
        )


viewTurnControls : Model -> Html Msg
viewTurnControls model =
    let
        replayControl =
            case model.replay of
                Just progress ->
                    if progress.paused then
                        gameButton "Resume" ClickReplayPauseToggle

                    else
                        gameButton "Pause" ClickReplayPauseToggle

                Nothing ->
                    gameButton "Instant replay" ClickInstantReplay
    in
    div
        [ style "margin-top" "12px"
        , style "display" "flex"
        , style "gap" "8px"
        , style "flex-wrap" "wrap"
        ]
        [ gameButton "Complete turn" ClickCompleteTurn
        , gameButton "Hint" ClickHint
        , replayControl
        , gameLink "← Lobby" "/gopher/game-lobby"
        ]


{-| Plain link styled like gameButton. Used for nav that exits
the Elm app entirely (back to the Go-served lobby).
-}
gameLink : String -> String -> Html Msg
gameLink label url =
    Html.a
        [ href url
        , style "padding" "6px 12px"
        , style "font-size" "14px"
        , style "border" ("1px solid " ++ View.navy)
        , style "background" "white"
        , style "color" View.navy
        , style "border-radius" "3px"
        , style "cursor" "pointer"
        , style "text-decoration" "none"
        ]
        [ Html.text label ]


gameButton : String -> Msg -> Html Msg
gameButton label msg =
    Html.button
        [ Events.onClick msg
        , style "padding" "6px 12px"
        , style "font-size" "14px"
        , style "border" ("1px solid " ++ View.navy)
        , style "background" "white"
        , style "color" View.navy
        , style "border-radius" "3px"
        , style "cursor" "pointer"
        ]
        [ Html.text label ]


boardColumn : Model -> Html Msg
boardColumn model =
    div
        [ style "min-width" "800px" ]
        [ View.viewBoardHeading
        , boardWithWings model
        ]


boardWithWings : Model -> Html Msg
boardWithWings model =
    View.boardShellWith [ id boardDomId ] (boardChildren model)


boardChildren : Model -> List (Html Msg)
boardChildren model =
    let
        stackNodes =
            List.indexedMap (viewStackForBoard model.drag) model.board

        wingNodes =
            case model.drag of
                Dragging info ->
                    List.filterMap (viewWingAt model info) info.wings

                NotDragging ->
                    []
    in
    stackNodes ++ wingNodes


viewStackForBoard : DragState -> Int -> CardStack -> Html Msg
viewStackForBoard drag stackIdx stack =
    case drag of
        Dragging info ->
            case info.source of
                FromBoardStack sourceIdx ->
                    if sourceIdx == stackIdx then
                        Html.text ""

                    else
                        View.viewStack stack

                FromHandCard _ ->
                    View.viewStack stack

        NotDragging ->
            View.viewStackWithCardAttrs (cardMouseDown stackIdx) stack


cardMouseDown : Int -> Int -> List (Html.Attribute Msg)
cardMouseDown stackIdx cardIdx =
    [ Events.on "mousedown"
        (Decode.map
            (MouseDownOnBoardCard { stackIndex = stackIdx, cardIndex = cardIdx })
            pointDecoder
        )
    ]


handCardAttrs : DragState -> List Card -> Int -> HandCard -> List (Html.Attribute Msg)
handCardAttrs drag hintedCards idx hc =
    let
        hintAttrs =
            if List.any (\c -> c == hc.card) hintedCards then
                [ style "background-color" "lightgreen" ]

            else
                []
    in
    hintAttrs
        ++ (case drag of
                NotDragging ->
                    [ Events.on "mousedown" (Decode.map (MouseDownOnHandCard idx) pointDecoder) ]

                Dragging info ->
                    case info.source of
                        FromHandCard sourceIdx ->
                            if sourceIdx == idx then
                                -- Dim the source card while dragging its floating copy.
                                [ style "opacity" "0.35", style "pointer-events" "none" ]

                            else
                                [ style "pointer-events" "none" ]

                        FromBoardStack _ ->
                            [ style "pointer-events" "none" ]
           )


viewWingAt : Model -> DragInfo -> WingId -> Maybe (Html Msg)
viewWingAt model info wing =
    case listAt wing.stackIndex model.board of
        Just target ->
            let
                pitch =
                    CardStack.stackPitch

                stackW =
                    CardStack.stackDisplayWidth target

                wingLeft =
                    case wing.side of
                        Left ->
                            target.loc.left - pitch

                        Right ->
                            target.loc.left + stackW

                hovering =
                    info.hoveredWing == Just wing

                bgColor =
                    if hovering then
                        View.mergeableHover

                    else
                        View.mergeableGreen
            in
            Just <|
                View.viewWing
                    { top = target.loc.top
                    , left = wingLeft
                    , width = pitch
                    , bgColor = bgColor
                    , extraAttrs =
                        [ Events.onMouseEnter (WingEntered wing)
                        , Events.onMouseLeave (WingLeft wing)
                        ]
                    }

        Nothing ->
            Nothing


draggedOverlay : Model -> Html Msg
draggedOverlay model =
    case model.drag of
        Dragging info ->
            let
                x =
                    info.cursor.x - info.grabOffset.x

                y =
                    info.cursor.y - info.grabOffset.y

                floatingAttrs =
                    [ style "position" "fixed"
                    , style "top" (String.fromInt y ++ "px")
                    , style "left" (String.fromInt x ++ "px")
                    , style "pointer-events" "none"
                    , style "z-index" "1000"
                    ]
            in
            case info.source of
                FromBoardStack idx ->
                    case listAt idx model.board of
                        Just source ->
                            View.viewStackWithAttrs floatingAttrs source

                        Nothing ->
                            Html.text ""

                FromHandCard idx ->
                    case listAt idx (activeHand model).handCards of
                        Just handCard ->
                            View.viewCardWithAttrs
                                (floatingAttrs ++ [ style "background-color" "white" ])
                                handCard.card

                        Nothing ->
                            Html.text ""

        NotDragging ->
            Html.text ""



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
