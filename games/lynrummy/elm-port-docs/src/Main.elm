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
import Json.Decode as Decode exposing (Decoder)
import LynRummy.BoardActions as BoardActions exposing (Side(..))
import LynRummy.CardStack as CardStack exposing (BoardLocation, CardStack, HandCard, stacksEqual)
import LynRummy.Dealer
import LynRummy.Hand as Hand exposing (Hand)
import LynRummy.View as View
import LynRummy.WingOracle as WingOracle exposing (WingId)
import Task



-- MODEL


type alias Model =
    { board : List CardStack
    , hand : Hand
    , drag : DragState
    }


type DragState
    = NotDragging
    | Dragging DragInfo


type alias DragInfo =
    { source : DragSource
    , cursor : Point
    , grabOffset : Point
    , wings : List WingId
    , hoveredWing : Maybe WingId
    , overBoard : Bool
    , boardRect : Maybe Rect
    }


type DragSource
    = FromBoardStack Int
    | FromHandCard Int


type alias Point =
    { x : Int, y : Int }


type alias Rect =
    { x : Int, y : Int, width : Int, height : Int }


boardDomId : String
boardDomId =
    "lynrummy-board"


init : () -> ( Model, Cmd Msg )
init _ =
    ( { board = LynRummy.Dealer.initialBoard
      , hand = LynRummy.Dealer.openingHand
      , drag = NotDragging
      }
    , Cmd.none
    )



-- MSG


type Msg
    = MouseDownOnStack Int Point
    | MouseDownOnHandCard Int Point
    | MouseMove Point
    | MouseUp
    | WingEntered WingId
    | WingLeft WingId
    | BoardEntered
    | BoardLeft
    | BoardRectReceived (Result Browser.Dom.Error Browser.Dom.Element)



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        MouseDownOnStack idx clientPoint ->
            startStackDrag idx clientPoint model

        MouseDownOnHandCard idx clientPoint ->
            startHandDrag idx clientPoint model

        MouseMove pos ->
            case model.drag of
                Dragging info ->
                    ( { model | drag = Dragging { info | cursor = pos } }, Cmd.none )

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

        BoardEntered ->
            case model.drag of
                Dragging info ->
                    ( { model | drag = Dragging { info | overBoard = True } }, Cmd.none )

                NotDragging ->
                    ( model, Cmd.none )

        BoardLeft ->
            case model.drag of
                Dragging info ->
                    ( { model | drag = Dragging { info | overBoard = False } }, Cmd.none )

                NotDragging ->
                    ( model, Cmd.none )

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


startStackDrag : Int -> Point -> Model -> ( Model, Cmd Msg )
startStackDrag idx clientPoint model =
    case ( model.drag, listAt idx model.board ) of
        ( NotDragging, Just stack ) ->
            let
                wings =
                    WingOracle.wingsForStack idx model.board

                halfWidth =
                    CardStack.stackDisplayWidth stack // 2
            in
            ( { model
                | drag =
                    Dragging
                        { source = FromBoardStack idx
                        , cursor = clientPoint
                        , grabOffset = { x = halfWidth, y = 20 }
                        , wings = wings
                        , hoveredWing = Nothing
                        , overBoard = False
                        , boardRect = Nothing
                        }
              }
            , Cmd.none
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
                        , grabOffset = { x = halfWidth, y = 20 }
                        , wings = wings
                        , hoveredWing = Nothing
                        , overBoard = False
                        , boardRect = Nothing
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
            case ( info.hoveredWing, info.source ) of
                ( Just wing, _ ) ->
                    ( commitMerge wing info.source model, Cmd.none )

                ( Nothing, FromHandCard handIdx ) ->
                    if info.overBoard then
                        ( commitPlaceHandCard handIdx info model, Cmd.none )

                    else
                        ( clearDrag model, Cmd.none )

                ( Nothing, FromBoardStack _ ) ->
                    ( clearDrag model, Cmd.none )


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
        [ style "padding" "20px"
        , style "font-family" "system-ui, sans-serif"
        ]
        [ View.viewBoardHeading
        , boardWithWings model
        , View.viewHandHeading
        , View.viewHand { attrsForCard = handCardAttrs model.drag } model.hand
        , draggedOverlay model
        ]


boardWithWings : Model -> Html Msg
boardWithWings model =
    let
        boardAttrs =
            [ id boardDomId
            , Events.onMouseEnter BoardEntered
            , Events.onMouseLeave BoardLeft
            ]
    in
    View.boardShellWith boardAttrs (boardChildren model)


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
viewStackForBoard drag idx stack =
    case drag of
        Dragging info ->
            case info.source of
                FromBoardStack sourceIdx ->
                    if sourceIdx == idx then
                        Html.text ""

                    else
                        View.viewStack stack

                FromHandCard _ ->
                    View.viewStack stack

        NotDragging ->
            View.viewStackWithAttrs [ stackMouseDown idx ] stack


stackMouseDown : Int -> Html.Attribute Msg
stackMouseDown idx =
    Events.on "mousedown" (Decode.map (MouseDownOnStack idx) pointDecoder)


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
