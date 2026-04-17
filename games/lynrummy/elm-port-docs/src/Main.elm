module Main exposing (main)

{-| TEA bootstrap for the standalone LynRummy game.

Current scope: opening board + stack-to-stack drag + wings on
mergeable targets. No hand, no turns, no tricks.

-}

import Browser
import Browser.Events
import Html exposing (Html, div)
import Html.Attributes exposing (style)
import Html.Events as Events
import Json.Decode as Decode exposing (Decoder)
import LynRummy.BoardActions as BoardActions exposing (Side(..))
import LynRummy.CardStack as CardStack exposing (BoardLocation, CardStack, stacksEqual)
import LynRummy.Dealer
import LynRummy.View as View
import LynRummy.WingOracle as WingOracle exposing (WingId)



-- MODEL


type alias Model =
    { board : List CardStack
    , drag : DragState
    }


type DragState
    = NotDragging
    | Dragging DragInfo


type alias DragInfo =
    { sourceIndex : Int
    , cursor : Point
    , grabOffset : Point
    , wings : List WingId
    , hoveredWing : Maybe WingId
    }


type alias Point =
    { x : Int, y : Int }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { board = LynRummy.Dealer.initialBoard
      , drag = NotDragging
      }
    , Cmd.none
    )



-- MSG


type Msg
    = MouseDownOnStack Int Point
    | MouseMove Point
    | MouseUp
    | WingEntered WingId
    | WingLeft WingId



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        MouseDownOnStack idx clientPoint ->
            case model.drag of
                NotDragging ->
                    case listAt idx model.board of
                        Just stack ->
                            let
                                wings =
                                    WingOracle.wingsFor idx model.board

                                halfWidth =
                                    CardStack.stackDisplayWidth stack // 2

                                halfHeight =
                                    20
                            in
                            ( { model
                                | drag =
                                    Dragging
                                        { sourceIndex = idx
                                        , cursor = clientPoint
                                        , grabOffset = { x = halfWidth, y = halfHeight }
                                        , wings = wings
                                        , hoveredWing = Nothing
                                        }
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            ( model, Cmd.none )

                _ ->
                    ( model, Cmd.none )

        MouseMove pos ->
            case model.drag of
                Dragging info ->
                    ( { model | drag = Dragging { info | cursor = pos } }, Cmd.none )

                NotDragging ->
                    ( model, Cmd.none )

        MouseUp ->
            case model.drag of
                Dragging info ->
                    case info.hoveredWing of
                        Just wing ->
                            ( commitMerge wing info.sourceIndex model, Cmd.none )

                        Nothing ->
                            ( { model | drag = NotDragging }, Cmd.none )

                NotDragging ->
                    ( model, Cmd.none )

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


commitMerge : WingId -> Int -> Model -> Model
commitMerge wing sourceIndex model =
    case ( listAt sourceIndex model.board, listAt wing.stackIndex model.board ) of
        ( Just source, Just _ ) ->
            let
                target =
                    listAt wing.stackIndex model.board
            in
            case target of
                Just t ->
                    case BoardActions.tryStackMerge source t wing.side of
                        Just change ->
                            { model
                                | board = applyChange change model.board
                                , drag = NotDragging
                            }

                        Nothing ->
                            { model | drag = NotDragging }

                Nothing ->
                    { model | drag = NotDragging }

        _ ->
            { model | drag = NotDragging }


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
        , View.boardShell (boardChildren model)
        , draggedOverlay model
        ]


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
            if info.sourceIndex == idx then
                Html.text ""

            else
                View.viewStack stack

        NotDragging ->
            View.viewStackWithAttrs [ mouseDownHandler idx ] stack


mouseDownHandler : Int -> Html.Attribute Msg
mouseDownHandler idx =
    Events.on "mousedown" (Decode.map (MouseDownOnStack idx) pointDecoder)


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
            case listAt info.sourceIndex model.board of
                Just source ->
                    let
                        x =
                            info.cursor.x - info.grabOffset.x

                        y =
                            info.cursor.y - info.grabOffset.y
                    in
                    View.viewStackWithAttrs
                        [ style "position" "fixed"
                        , style "top" (String.fromInt y ++ "px")
                        , style "left" (String.fromInt x ++ "px")
                        , style "pointer-events" "none"
                        , style "z-index" "1000"
                        ]
                        source

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
