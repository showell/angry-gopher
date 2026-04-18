module Main exposing (main)

{-| TEA bootstrap for the standalone LynRummy game.

Current scope: opening board + opening hand + stack-to-stack
drag + hand-card-to-board drag (merge via wing OR place as
singleton). No turns, no draw/discard, no scoring.

-}

import Browser
import Browser.Dom
import Browser.Events
import Html exposing (Html, div)
import Html.Attributes exposing (id, style)
import Html.Events as Events
import Http
import Json.Decode as Decode exposing (Decoder)
import LynRummy.BoardActions as BoardActions exposing (Side(..))
import LynRummy.CardStack as CardStack exposing (BoardLocation, CardStack, HandCard, stacksEqual)
import LynRummy.Dealer
import LynRummy.GestureArbitration as GA
import LynRummy.Hand as Hand exposing (Hand)
import LynRummy.Score as Score
import LynRummy.View as View
import LynRummy.WingOracle as WingOracle exposing (WingId)
import LynRummy.WireAction as WA exposing (WireAction)
import Task



-- MODEL


type alias Model =
    { phase : Phase
    , board : List CardStack
    , hand : Hand
    , drag : DragState
    , sessionId : Maybe Int
    , status : StatusMessage
    , score : Int
    , turnIndex : Int
    , sessions : SessionsLoad
    }


type Phase
    = Lobby
    | Playing


type SessionsLoad
    = SessionsLoading
    | SessionsLoaded (List SessionSummary)
    | SessionsError


type alias SessionSummary =
    { id : Int
    , createdAt : Int
    , label : String
    , actionCount : Int
    }


type alias StatusMessage =
    { text : String, kind : StatusKind }


type StatusKind
    = Inform
    | Celebrate
    | Scold


type DragState
    = NotDragging
    | Dragging DragInfo


type alias DragInfo =
    { source : DragSource
    , cursor : Point
    , originalCursor : Point
    , grabOffset : Point
    , wings : List WingId
    , hoveredWing : Maybe WingId
    , boardRect : Maybe GA.Rect
    , clickIntent : Maybe Int
    }


type DragSource
    = FromBoardStack Int
    | FromHandCard Int


type alias Point =
    { x : Int, y : Int }


boardDomId : String
boardDomId =
    "lynrummy-board"


init : () -> ( Model, Cmd Msg )
init _ =
    ( { phase = Lobby
      , board = LynRummy.Dealer.initialBoard
      , hand = LynRummy.Dealer.openingHand
      , drag = NotDragging
      , sessionId = Nothing
      , status = { text = "Pick a session or start a new game.", kind = Inform }
      , score = 0
      , turnIndex = 0
      , sessions = SessionsLoading
      }
    , fetchSessionsList
    )


fetchSessionsList : Cmd Msg
fetchSessionsList =
    Http.get
        { url = "/gopher/lynrummy-elm/api/sessions"
        , expect = Http.expectJson SessionsListReceived sessionsDecoder
        }


sessionsDecoder : Decoder (List SessionSummary)
sessionsDecoder =
    Decode.field "sessions"
        (Decode.list
            (Decode.map4 SessionSummary
                (Decode.field "id" Decode.int)
                (Decode.field "created_at" Decode.int)
                (Decode.field "label" Decode.string)
                (Decode.field "action_count" Decode.int)
            )
        )


fetchNewSession : Cmd Msg
fetchNewSession =
    Http.post
        { url = "/gopher/lynrummy-elm/new-session"
        , body = Http.emptyBody
        , expect = Http.expectJson SessionReceived sessionIdDecoder
        }


sessionIdDecoder : Decoder Int
sessionIdDecoder =
    Decode.field "session_id" Decode.int


{-| Authoritative state as the server computes it. Elm pulls this
after special actions (CompleteTurn, Undo) where the local
optimistic-apply shape isn't straightforward.
-}
type alias RemoteState =
    { board : List CardStack
    , hand : Hand
    , turnIndex : Int
    }


remoteStateDecoder : Decoder RemoteState
remoteStateDecoder =
    Decode.field "state"
        (Decode.map3 RemoteState
            (Decode.field "board" (Decode.list CardStack.cardStackDecoder))
            (Decode.field "hand"
                (Decode.field "hand_cards" (Decode.list CardStack.handCardDecoder)
                    |> Decode.map (\cards -> { handCards = cards })
                )
            )
            (Decode.field "turn_index" Decode.int)
        )


fetchRemoteState : Int -> Cmd Msg
fetchRemoteState sid =
    Http.get
        { url = "/gopher/lynrummy-elm/sessions/" ++ String.fromInt sid ++ "/state"
        , expect = Http.expectJson StateRefreshed remoteStateDecoder
        }



-- MSG


type Msg
    = MouseDownOnBoardCard { stackIndex : Int, cardIndex : Int } Point
    | MouseDownOnHandCard Int Point
    | MouseMove Point
    | MouseUp
    | WingEntered WingId
    | WingLeft WingId
    | BoardRectReceived (Result Browser.Dom.Error Browser.Dom.Element)
    | ActionSent (Result Http.Error ())
    | SessionReceived (Result Http.Error Int)
    | ClickCompleteTurn
    | ClickUndo
    | StateRefreshed (Result Http.Error RemoteState)
    | SessionsListReceived (Result Http.Error (List SessionSummary))
    | ClickNewGame
    | ClickResumeSession Int
    | ClickBackToLobby



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
            ( { model | sessionId = Just sid }, Cmd.none )

        SessionReceived (Err _) ->
            -- If the server can't hand us a session, actions stay
            -- unpersisted. UI keeps working locally.
            ( model, Cmd.none )

        ClickCompleteTurn ->
            case model.sessionId of
                Just sid ->
                    ( { model
                        | status =
                            { text = "Turn " ++ String.fromInt (model.turnIndex + 1) ++ " complete."
                            , kind = Inform
                            }
                      }
                    , Cmd.batch [ sendAction sid WA.CompleteTurn, fetchRemoteState sid ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        ClickUndo ->
            case model.sessionId of
                Just sid ->
                    ( { model | status = { text = "Undone.", kind = Inform } }
                    , Cmd.batch [ sendAction sid WA.Undo, fetchRemoteState sid ]
                    )

                Nothing ->
                    ( model, Cmd.none )

        StateRefreshed (Ok rs) ->
            ( { model
                | phase = Playing
                , board = rs.board
                , hand = rs.hand
                , turnIndex = rs.turnIndex
                , score = Score.forStacks rs.board
              }
            , Cmd.none
            )

        StateRefreshed (Err _) ->
            ( model, Cmd.none )

        SessionsListReceived (Ok list) ->
            ( { model | sessions = SessionsLoaded list }, Cmd.none )

        SessionsListReceived (Err _) ->
            ( { model | sessions = SessionsError }, Cmd.none )

        ClickNewGame ->
            ( { model
                | phase = Playing
                , board = LynRummy.Dealer.initialBoard
                , hand = LynRummy.Dealer.openingHand
                , sessionId = Nothing
                , turnIndex = 0
                , score = Score.forStacks LynRummy.Dealer.initialBoard
                , status =
                    { text = "Begin game. Drag hand cards or board stacks onto the board."
                    , kind = Inform
                    }
              }
            , fetchNewSession
            )

        ClickResumeSession sid ->
            ( { model
                | phase = Playing
                , sessionId = Just sid
                , status = { text = "Resuming session " ++ String.fromInt sid ++ "…", kind = Inform }
              }
            , fetchRemoteState sid
            )

        ClickBackToLobby ->
            ( { model
                | phase = Lobby
                , sessionId = Nothing
                , sessions = SessionsLoading
                , status = { text = "Pick a session or start a new game.", kind = Inform }
              }
            , fetchSessionsList
            )

        BoardRectReceived result ->
            case ( model.drag, result ) of
                ( Dragging info, Ok element ) ->
                    let
                        rect =
                            { x = round element.element.x
                            , y = round element.element.y
                            , width = round element.element.width
                            , height = round element.element.height
                            }
                    in
                    ( { model | drag = Dragging { info | boardRect = Just rect } }, Cmd.none )

                _ ->
                    ( model, Cmd.none )


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
    case ( model.drag, listAt idx model.hand.handCards ) of
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
                ( afterResolve, maybeAction ) =
                    resolveGesture info model

                newModel =
                    { afterResolve | score = Score.forStacks afterResolve.board }

                cmd =
                    case ( maybeAction, newModel.sessionId ) of
                        ( Just action, Just sid ) ->
                            sendAction sid action

                        _ ->
                            Cmd.none
            in
            ( newModel, cmd )


{-| Resolve a completed drag gesture into a (new model,
optional WireAction to emit). Click precedence over drag
mirrors the TS engine's process_pointerup logic: if
clickIntent survived, it's a split; otherwise dispatch on
(hoveredWing, source, cursorOverBoard).
-}
resolveGesture : DragInfo -> Model -> ( Model, Maybe WireAction )
resolveGesture info model =
    case ( info.clickIntent, info.source ) of
        ( Just cardIdx, FromBoardStack stackIdx ) ->
            ( commitSplit stackIdx cardIdx model
            , Just (WA.Split { stackIndex = stackIdx, cardIndex = cardIdx })
            )

        _ ->
            case ( info.hoveredWing, info.source ) of
                ( Just wing, FromBoardStack sourceIdx ) ->
                    ( commitMerge wing info.source model
                    , Just
                        (WA.MergeStack
                            { sourceStack = sourceIdx
                            , targetStack = wing.stackIndex
                            , side = wing.side
                            }
                        )
                    )

                ( Just wing, FromHandCard handIdx ) ->
                    case listAt handIdx model.hand.handCards of
                        Just handCard ->
                            ( commitMerge wing info.source model
                            , Just
                                (WA.MergeHand
                                    { handCard = handCard.card
                                    , targetStack = wing.stackIndex
                                    , side = wing.side
                                    }
                                )
                            )

                        Nothing ->
                            ( clearDrag model, Nothing )

                ( Nothing, FromHandCard handIdx ) ->
                    if cursorOverBoard info then
                        case ( listAt handIdx model.hand.handCards, dropLoc info ) of
                            ( Just handCard, Just loc ) ->
                                ( commitPlaceHandCard handIdx info model
                                , Just (WA.PlaceHand { handCard = handCard.card, loc = loc })
                                )

                            _ ->
                                ( clearDrag model, Nothing )

                    else
                        ( clearDrag model, Nothing )

                ( Nothing, FromBoardStack stackIdx ) ->
                    if cursorOverBoard info then
                        case dropLoc info of
                            Just loc ->
                                ( commitMoveStack stackIdx info model
                                , Just (WA.MoveStack { stackIndex = stackIdx, newLoc = loc })
                                )

                            Nothing ->
                                ( clearDrag model, Nothing )

                    else
                        ( clearDrag model, Nothing )


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


sendAction : Int -> WireAction -> Cmd Msg
sendAction sessionId action =
    Http.post
        { url = "/gopher/lynrummy-elm/actions?session=" ++ String.fromInt sessionId
        , body = Http.jsonBody (WA.encode action)
        , expect = Http.expectWhatever ActionSent
        }


commitSplit : Int -> Int -> Model -> Model
commitSplit stackIdx cardIdx model =
    { model
        | board = GA.applySplit stackIdx cardIdx model.board
        , drag = NotDragging
    }


commitMoveStack : Int -> DragInfo -> Model -> Model
commitMoveStack stackIdx info model =
    case ( listAt stackIdx model.board, info.boardRect ) of
        ( Just stack, Just rect ) ->
            let
                newLoc =
                    { left = info.cursor.x - info.grabOffset.x - rect.x
                    , top = info.cursor.y - info.grabOffset.y - rect.y
                    }

                change =
                    BoardActions.moveStack stack newLoc
            in
            { model
                | board = applyChange change model.board
                , drag = NotDragging
            }

        _ ->
            clearDrag model


clearDrag : Model -> Model
clearDrag model =
    { model | drag = NotDragging }


commitMerge : WingId -> DragSource -> Model -> Model
commitMerge wing source model =
    case listAt wing.stackIndex model.board of
        Nothing ->
            clearDrag model

        Just target ->
            case source of
                FromBoardStack sourceIdx ->
                    case listAt sourceIdx model.board of
                        Just sourceStack ->
                            case BoardActions.tryStackMerge target sourceStack wing.side of
                                Just change ->
                                    { model
                                        | board = applyChange change model.board
                                        , drag = NotDragging
                                    }

                                Nothing ->
                                    clearDrag model

                        Nothing ->
                            clearDrag model

                FromHandCard handIdx ->
                    case listAt handIdx model.hand.handCards of
                        Just handCard ->
                            case BoardActions.tryHandMerge target handCard wing.side of
                                Just change ->
                                    { model
                                        | board = applyChange change model.board
                                        , hand = Hand.removeHandCard handCard model.hand
                                        , drag = NotDragging
                                    }

                                Nothing ->
                                    clearDrag model

                        Nothing ->
                            clearDrag model


commitPlaceHandCard : Int -> DragInfo -> Model -> Model
commitPlaceHandCard handIdx info model =
    case ( listAt handIdx model.hand.handCards, info.boardRect ) of
        ( Just handCard, Just rect ) ->
            let
                loc =
                    { left = info.cursor.x - info.grabOffset.x - rect.x
                    , top = info.cursor.y - info.grabOffset.y - rect.y
                    }

                change =
                    BoardActions.placeHandCard handCard loc
            in
            { model
                | board = applyChange change model.board
                , hand = Hand.removeHandCard handCard model.hand
                , drag = NotDragging
            }

        _ ->
            clearDrag model


applyChange : BoardActions.BoardChange -> List CardStack -> List CardStack
applyChange change board =
    List.filter (\s -> not (List.any (stacksEqual s) change.stacksToRemove)) board
        ++ change.stacksToAdd



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    case model.drag of
        Dragging _ ->
            Sub.batch
                [ Browser.Events.onMouseMove (Decode.map MouseMove pointDecoder)
                , Browser.Events.onMouseUp (Decode.succeed MouseUp)
                ]

        NotDragging ->
            Sub.none


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
        (case model.phase of
            Lobby ->
                [ viewTopBar
                , viewStatusBar model.status
                , viewLobby model
                ]

            Playing ->
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
                ]
        )


viewLobby : Model -> Html Msg
viewLobby model =
    div
        [ style "padding" "20px 40px"
        , style "max-width" "720px"
        ]
        [ div
            [ style "margin-bottom" "16px" ]
            [ gameButton "Start new game" ClickNewGame ]
        , Html.h2
            [ style "color" View.navy
            , style "margin-top" "24px"
            ]
            [ Html.text "Your sessions" ]
        , viewSessionsList model.sessions
        ]


viewSessionsList : SessionsLoad -> Html Msg
viewSessionsList loaded =
    case loaded of
        SessionsLoading ->
            div [ style "color" "#888" ] [ Html.text "Loading…" ]

        SessionsError ->
            div [ style "color" "red" ]
                [ Html.text "Couldn't load sessions." ]

        SessionsLoaded [] ->
            div [ style "color" "#888" ]
                [ Html.text "No sessions yet. Start a new game to get going." ]

        SessionsLoaded sessions ->
            Html.table
                [ style "border-collapse" "collapse"
                , style "width" "100%"
                ]
                (Html.tr
                    [ style "text-align" "left"
                    , style "border-bottom" "1px solid #ddd"
                    ]
                    [ Html.th [ style "padding" "6px 10px" ] [ Html.text "id" ]
                    , Html.th [ style "padding" "6px 10px" ] [ Html.text "label" ]
                    , Html.th [ style "padding" "6px 10px", style "text-align" "right" ]
                        [ Html.text "actions" ]
                    , Html.th [ style "padding" "6px 10px" ] []
                    ]
                    :: List.map viewSessionRow sessions
                )


viewSessionRow : SessionSummary -> Html Msg
viewSessionRow s =
    Html.tr
        [ style "border-bottom" "1px solid #eee" ]
        [ Html.td
            [ style "padding" "6px 10px"
            , style "color" View.navy
            , style "font-variant-numeric" "tabular-nums"
            ]
            [ Html.text ("#" ++ String.fromInt s.id) ]
        , Html.td
            [ style "padding" "6px 10px"
            , style "color" "#666"
            ]
            [ Html.text
                (if String.isEmpty s.label then
                    "—"

                 else
                    s.label
                )
            ]
        , Html.td
            [ style "padding" "6px 10px"
            , style "text-align" "right"
            , style "font-variant-numeric" "tabular-nums"
            , style "color" "#888"
            ]
            [ Html.text (String.fromInt s.actionCount) ]
        , Html.td
            [ style "padding" "6px 10px"
            , style "text-align" "right"
            ]
            [ gameButton "Resume" (ClickResumeSession s.id) ]
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
        [ viewPlayerHeader model
        , View.viewHandHeading
        , View.viewHand { attrsForCard = handCardAttrs model.drag } model.hand
        , viewTurnControls
        ]


viewPlayerHeader : Model -> Html Msg
viewPlayerHeader model =
    div []
        [ div
            [ style "font-weight" "bold"
            , style "font-size" "16px"
            , style "color" View.navy
            , style "margin-top" "12px"
            ]
            [ Html.text "You" ]
        , div
            [ style "color" "maroon"
            , style "margin-bottom" "4px"
            , style "margin-top" "4px"
            ]
            [ Html.text ("Score: " ++ String.fromInt model.score) ]
        , div
            [ style "color" "#666"
            , style "font-size" "13px"
            , style "margin-bottom" "4px"
            ]
            [ Html.text ("Turn " ++ String.fromInt (model.turnIndex + 1)) ]
        ]


viewTurnControls : Html Msg
viewTurnControls =
    div
        [ style "margin-top" "12px"
        , style "display" "flex"
        , style "gap" "8px"
        , style "flex-wrap" "wrap"
        ]
        [ gameButton "Complete turn" ClickCompleteTurn
        , gameButton "Undo" ClickUndo
        , gameButton "← Lobby" ClickBackToLobby
        ]


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
        [ style "min-width" "560px" ]
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


handCardAttrs : DragState -> Int -> HandCard -> List (Html.Attribute Msg)
handCardAttrs drag idx _ =
    case drag of
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
                    case listAt idx model.hand.handCards of
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


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
