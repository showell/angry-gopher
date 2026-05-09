module Puzzle exposing (main)

{-| Puzzle V2 — drag-aware single-puzzle surface.

Dedicated host: own Msg, own Model, no `Main.*` imports.
Composes `Game.*` building blocks directly (BoardView,
BoardGesture, BoardDrag, Drag). V2 supports board-card drag
(move + merge + click=split). No hint, no undo, no replay,
no agent, no wire — drags mutate local Model only.

The status field is held but not rendered in V1; the gesture
machinery produces a status on each interaction and we keep
the latest. A status bar can be added later without changing
the update path.

-}

import Browser
import Browser.Dom
import Browser.Events
import Game.BoardDrag as BoardDrag
import Game.BoardGesture as BoardGesture
import Game.BoardView as BoardView
import Game.CardStack exposing (BoardCardState(..), CardStack)
import Game.Drag exposing (DragState(..))
import Game.Physics.GestureArbitration as GA
import Game.Point exposing (Point)
import Game.Rules.Card exposing (CardValue(..), OriginDeck(..), Suit(..))
import Game.Status as Status
import Html exposing (Html, div)
import Html.Attributes exposing (style)
import Html.Events as Events
import Json.Decode as Decode exposing (Decoder)
import Task



-- MODEL


type alias Model =
    { board : List CardStack
    , drag : DragState
    , boardRect : Maybe GA.Rect
    , status : Status.StatusMessage
    , gameId : String
    }


initialModel : Model
initialModel =
    { board = puzzleStacks
    , drag = NotDragging
    , boardRect = Nothing
    , status = { text = "Drag stacks to merge or move them.", kind = Status.Inform }
    , gameId = "puzzle"
    }


init : () -> ( Model, Cmd Msg )
init () =
    ( initialModel, Cmd.none )



-- MSG


type Msg
    = MouseDownOnBoardCard { stack : CardStack, cardIndex : Int, point : Point, time : Float }
    | MouseMove Point Float
    | MouseUp Point Float
    | BoardRectReceived (Result Browser.Dom.Error Browser.Dom.Element)



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        MouseDownOnBoardCard { stack, cardIndex, point, time } ->
            startBoardCardDrag stack cardIndex point time model

        MouseMove pos tMs ->
            ( mouseMove pos tMs model, Cmd.none )

        MouseUp pos tMs ->
            ( handleMouseUp pos tMs model, Cmd.none )

        BoardRectReceived result ->
            ( boardRectReceived result model, Cmd.none )


startBoardCardDrag :
    CardStack
    -> Int
    -> Point
    -> Float
    -> Model
    -> ( Model, Cmd Msg )
startBoardCardDrag stack cardIndex clientPoint tMs model =
    case model.drag of
        NotDragging ->
            ( { model
                | drag =
                    DraggingBoardCard
                        (BoardGesture.startBoardDragInfo
                            { stack = stack
                            , cardIndex = cardIndex
                            , cursor = clientPoint
                            , tMs = tMs
                            , board = model.board
                            }
                        )
              }
            , fetchBoardRect model.gameId
            )

        _ ->
            ( model, Cmd.none )


mouseMove : Point -> Float -> Model -> Model
mouseMove pos tMs model =
    case model.drag of
        DraggingBoardCard d ->
            let
                ( nextD, nextStatus ) =
                    BoardGesture.mouseMove pos tMs d model.status
            in
            { model | drag = DraggingBoardCard nextD, status = nextStatus }

        DraggingHandCard _ ->
            model

        NotDragging ->
            model


handleMouseUp : Point -> Float -> Model -> Model
handleMouseUp releasePoint tMs model =
    case model.drag of
        NotDragging ->
            model

        DraggingHandCard _ ->
            { model | drag = NotDragging }

        DraggingBoardCard d ->
            let
                outcome =
                    BoardDrag.handleMouseUp releasePoint
                        tMs
                        d
                        { board = model.board
                        , boardRect = model.boardRect

                        -- Puzzle has no log / no wire; pass empty
                        -- inputs and ignore the matching outcome
                        -- fields. The pure board patch is what we
                        -- want.
                        , actionLog = []
                        , nextSeq = 0
                        }
            in
            { model
                | drag = NotDragging
                , board = outcome.board
                , status = outcome.status |> Maybe.withDefault model.status
            }


boardRectReceived : Result Browser.Dom.Error Browser.Dom.Element -> Model -> Model
boardRectReceived result model =
    case result of
        Ok element ->
            { model
                | boardRect =
                    Just
                        { x = round (element.element.x - element.viewport.x)
                        , y = round (element.element.y - element.viewport.y)
                        , width = round element.element.width
                        , height = round element.element.height
                        }
            }

        Err _ ->
            model


fetchBoardRect : String -> Cmd Msg
fetchBoardRect gameId =
    Browser.Dom.getElement (BoardView.boardDomIdFor gameId)
        |> Task.attempt BoardRectReceived



-- DECODERS / EVENT HOOKS


pointDecoder : Decoder Point
pointDecoder =
    Decode.map2 (\x y -> { x = round x, y = round y })
        (Decode.field "clientX" Decode.float)
        (Decode.field "clientY" Decode.float)


pointAndTimeDecoder : Decoder ( Point, Float )
pointAndTimeDecoder =
    Decode.map2 Tuple.pair
        pointDecoder
        (Decode.field "timeStamp" Decode.float)


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


cardMouseDown : CardStack -> Int -> List (Html.Attribute Msg)
cardMouseDown stack cardIdx =
    [ Events.on "mousedown"
        (Decode.map
            (\( p, t ) ->
                MouseDownOnBoardCard { stack = stack, cardIndex = cardIdx, point = p, time = t }
            )
            pointAndTimeDecoder
        )
    ]



-- SUBSCRIPTIONS


subscriptions : Model -> Sub Msg
subscriptions model =
    case model.drag of
        NotDragging ->
            Sub.none

        _ ->
            Sub.batch
                [ Browser.Events.onMouseMove mouseMoveDecoder
                , Browser.Events.onMouseUp mouseUpDecoder
                ]



-- VIEW


view : Model -> Html Msg
view model =
    div
        [ style "padding" "20px"
        , style "font-family" "system-ui, sans-serif"
        ]
        [ BoardView.boardColumn
            { board = model.board
            , boardRect = model.boardRect
            , drag = model.drag
            , gameId = model.gameId
            , cardMouseDown = cardMouseDown
            }
        ]



-- THE PUZZLE


puzzleStacks : List CardStack
puzzleStacks =
    [ stackAt 100 100
        [ ( Seven, Heart )
        , ( Eight, Heart )
        , ( Nine, Heart )
        ]
    , stackAt 220 100
        [ ( King, Club )
        , ( Ace, Club )
        , ( Two, Club )
        ]
    , stackAt 340 100
        [ ( Queen, Club )
        ]
    ]


stackAt : Int -> Int -> List ( CardValue, Suit ) -> CardStack
stackAt top left valuesAndSuits =
    { boardCards =
        List.map
            (\( v, s ) ->
                { card = { value = v, suit = s, originDeck = DeckOne }
                , state = FirmlyOnBoard
                }
            )
            valuesAndSuits
    , loc = { top = top, left = left }
    }


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
