module Gesture.MoveStack exposing
    ( Config
    , GestureOutcome(..)
    , Move(..)
    , Msg
    , State
    , init
    , name
    , subscriptions
    , update
    , view
    )

{-| Move-stack gesture: pick up any stack on the board (by
clicking any of its cards) and drag the whole rigid unit to a new
location. Release leaves the stack where you dropped it.

This is the foundational layout gesture. Players need to do it
constantly to keep the board tidy. No game-logic validation, no
merging, no snap — pure spatial repositioning.

This is also a 1-card-stack-friendly gesture: a stack of one card
is just a draggable card. Stacks of any size work the same way.
-}

import Browser.Events
import Card exposing (Card, Suit(..))
import Drag
import Html exposing (Html)
import Html.Attributes as HA
import Html.Events
import Json.Decode as D
import Json.Encode as E
import Layout exposing (Placement, ch, containerOriginX, containerOriginY, cw, pitch)
import Style
import Time



-- IDENTITY


name : String
name =
    "move_stack"



-- DOMAIN


{-| A pile of cards anchored at a 2D position. Cards within the
pile are pitch-aligned starting from `origin`. Production code's
"stack" type would carry more (Stack vs Set vs Run, validation
state); for this prototype, raw cards are enough.
-}
type alias Stack =
    { cards : List Card
    , origin : { x : Int, y : Int }
    }



-- CONFIG


type alias Config =
    { initialStacks : List Stack
    }



-- MOVE


type Move
    = MoveStackTo
        { stackIdx : Int
        , from : { x : Int, y : Int }
        , to : { x : Int, y : Int }
        }
    | MoveSnapBack



-- DRAG STATE


type alias DragState =
    { stackIdx : Int
    , offsetX : Int -- mouse-to-stack-origin offset (container-local)
    , offsetY : Int
    , originAtStart : { x : Int, y : Int }
    , kinematics : Drag.Kinematics
    }


type alias State =
    { config : Config
    , stacks : List Stack
    , dragging : Maybe DragState
    , nowMillis : Int
    }



-- INIT


init : Config -> State
init cfg =
    { config = cfg
    , stacks = cfg.initialStacks
    , dragging = Nothing
    , nowMillis = 0
    }



-- MSG


type Msg
    = CardMouseDown Int Drag.MousePos { stackOriginX : Int, stackOriginY : Int }
    | MouseMoved Drag.MousePos
    | MouseUp Drag.MousePos
    | Tick Int



-- OUTCOME


type GestureOutcome
    = Pending
    | Completed
        { ok : Bool
        , durationMs : Int
        , move : Move
        , extra : List ( String, E.Value )
        }



-- HELPERS


getAt : Int -> List a -> Maybe a
getAt i xs =
    List.head (List.drop i xs)


updateAt : Int -> (a -> a) -> List a -> List a
updateAt i f xs =
    List.indexedMap
        (\j x ->
            if j == i then
                f x

            else
                x
        )
        xs



-- UPDATE


update : Msg -> State -> ( State, Cmd Msg, GestureOutcome )
update msg state =
    case msg of
        CardMouseDown stackIdx mouse stackOrigin ->
            let
                -- Mouse-to-stack-origin offset, in container-local pixels.
                offsetX =
                    (mouse.x - containerOriginX) - stackOrigin.stackOriginX

                offsetY =
                    (mouse.y - containerOriginY) - stackOrigin.stackOriginY
            in
            ( { state
                | dragging =
                    Just
                        { stackIdx = stackIdx
                        , offsetX = offsetX
                        , offsetY = offsetY
                        , originAtStart = { x = stackOrigin.stackOriginX, y = stackOrigin.stackOriginY }
                        , kinematics = Drag.initKinematics mouse state.nowMillis
                        }
              }
            , Cmd.none
            , Pending
            )

        MouseMoved pos ->
            case state.dragging of
                Just d ->
                    let
                        kAfterMove =
                            Drag.advanceMouseSample pos state.nowMillis d.kinematics

                        newOriginX =
                            (pos.x - containerOriginX) - d.offsetX

                        newOriginY =
                            (pos.y - containerOriginY) - d.offsetY

                        newStacks =
                            updateAt d.stackIdx
                                (\s -> { s | origin = { x = newOriginX, y = newOriginY } })
                                state.stacks
                    in
                    ( { state
                        | stacks = newStacks
                        , dragging = Just { d | kinematics = kAfterMove }
                      }
                    , Cmd.none
                    , Pending
                    )

                Nothing ->
                    ( state, Cmd.none, Pending )

        MouseUp _ ->
            case state.dragging of
                Just d ->
                    let
                        durMs =
                            max 0 (state.nowMillis - d.kinematics.startedAtMs)

                        finalOrigin =
                            getAt d.stackIdx state.stacks
                                |> Maybe.map .origin
                                |> Maybe.withDefault d.originAtStart

                        move =
                            MoveStackTo
                                { stackIdx = d.stackIdx
                                , from = d.originAtStart
                                , to = finalOrigin
                                }

                        extra =
                            [ ( "stackIdx", E.int d.stackIdx )
                            , ( "fromX", E.int d.originAtStart.x )
                            , ( "fromY", E.int d.originAtStart.y )
                            , ( "toX", E.int finalOrigin.x )
                            , ( "toY", E.int finalOrigin.y )
                            ]
                                ++ Drag.kinematicsLogFields d.kinematics
                    in
                    ( { state | dragging = Nothing }
                    , Cmd.none
                    , Completed { ok = True, durationMs = durMs, move = move, extra = extra }
                    )

                Nothing ->
                    ( state, Cmd.none, Pending )

        Tick ms ->
            ( { state | nowMillis = ms }, Cmd.none, Pending )



-- SUBSCRIPTIONS


subscriptions : State -> Sub Msg
subscriptions state =
    let
        clock =
            Browser.Events.onAnimationFrame
                (\posix -> Tick (Time.posixToMillis posix))
    in
    case state.dragging of
        Just _ ->
            Sub.batch
                [ Browser.Events.onMouseMove (D.map MouseMoved Drag.mouseDecoder)
                , Browser.Events.onMouseUp (D.map MouseUp Drag.mouseDecoder)
                , clock
                ]

        Nothing ->
            clock



-- VIEW


view : State -> Html Msg
view state =
    Style.playSurface
        (List.indexedMap viewStack state.stacks)


viewStack : Int -> Stack -> Html Msg
viewStack stackIdx stack =
    Html.div
        (Style.posAbsolute stack.origin.x stack.origin.y)
        (List.indexedMap (viewStackCard stackIdx stack.origin) stack.cards)


viewStackCard : Int -> { x : Int, y : Int } -> Int -> Card -> Html Msg
viewStackCard stackIdx stackOrigin cardIdx card =
    Html.div
        (Style.posAbsolute (cardIdx * pitch) 0
            ++ [ HA.style "cursor" "grab"
               , Html.Events.on "mousedown" (cardDownDecoder stackIdx stackOrigin)
               ]
        )
        [ Style.cardCanvas card ]


cardDownDecoder : Int -> { x : Int, y : Int } -> D.Decoder Msg
cardDownDecoder stackIdx origin =
    D.map2
        (\mx my ->
            CardMouseDown stackIdx
                { x = mx, y = my }
                { stackOriginX = origin.x, stackOriginY = origin.y }
        )
        (D.field "clientX" D.int)
        (D.field "clientY" D.int)
