module Gesture.InjectCard exposing
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

{-| Inject-card gesture prototype with 2D coupling.

Hardcoded scenario: hand has 5♥, board has 234567♥. Player
collides the 5 with the 6 (any overlap, no velocity threshold —
DWIM as soon as you touch).

Phases:

  1. Pre-contact: dragged 5 follows the cursor alone.
  2. On contact with the 6: 6 and 7 become COUPLED to the 5
     with their at-contact relative offsets in 2D. From that
     point until release, all three move synchronously with
     the cursor.
  3. On release: 30ms pause, then the 5 snaps into the slot
     adjacent to the 6 (one pitch to its left, same y).

Original 234,5 stay anchored throughout. After snap, the board
holds 7 cards split into two visually-distinct sub-stacks.

This is a feel prototype; no game-logic validation, no condition
variation.
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
    "inject_card"



-- CONFIG


type alias Config =
    { initialBoardPlace : Placement
    , initialHandOrigin : { x : Int, y : Int }
    }



-- MOVE


type Move
    = MoveInjected
    | MoveSnapBack



-- DOMAIN STATE


{-| One renderable board card with full 2D offset from the board
origin. After the player pushes the 5 into the 6, the 6 and 7
get non-zero offsetY values as they drift with the cursor.
-}
type alias BoardCard =
    { card : Card
    , offsetX : Int
    , offsetY : Int
    }


{-| Captured at the moment the dragged 5 first overlaps the 6.
Records each coupled card's offset from the 5 (in container-
local pixels). During the coupled drag, each card's container
position = (current 5 position) + (its captured offset).
-}
type alias Contact =
    { sixDx : Int
    , sixDy : Int
    , sevenDx : Int
    , sevenDy : Int
    }


type alias DragState =
    { card : Card
    , offsetX : Int
    , offsetY : Int
    , kinematics : Drag.Kinematics
    , contact : Maybe Contact
    }


{-| The 5 has been released but the snap hasn't fired yet — we
hold its last container-local position so the view can render it
frozen at that spot during the 30ms pause before snap.
-}
type alias ReleasedState =
    { atX : Int
    , atY : Int
    , snapAt : Int
    }


type alias State =
    { config : Config
    , hand : Maybe Card
    , boardCards : List BoardCard
    , dragging : Maybe DragState
    , released : Maybe ReleasedState
    , nowMillis : Int
    }



-- HARDCODED SCENARIO


handCard : Card
handCard =
    { value = 5, suit = Hearts, deck = 1 }


initialBoardCards : List BoardCard
initialBoardCards =
    [ { card = { value = 2, suit = Hearts, deck = 1 }, offsetX = 0, offsetY = 0 }
    , { card = { value = 3, suit = Hearts, deck = 1 }, offsetX = pitch, offsetY = 0 }
    , { card = { value = 4, suit = Hearts, deck = 1 }, offsetX = 2 * pitch, offsetY = 0 }
    , { card = { value = 5, suit = Hearts, deck = 1 }, offsetX = 3 * pitch, offsetY = 0 }
    , { card = { value = 6, suit = Hearts, deck = 1 }, offsetX = 4 * pitch, offsetY = 0 }
    , { card = { value = 7, suit = Hearts, deck = 1 }, offsetX = 5 * pitch, offsetY = 0 }
    ]


snapPauseMs : Int
snapPauseMs =
    30



-- INIT


init : Config -> State
init cfg =
    { config = cfg
    , hand = Just handCard
    , boardCards = initialBoardCards
    , dragging = Nothing
    , released = Nothing
    , nowMillis = 0
    }



-- MSG


type Msg
    = HandCardDown Drag.MousePos { cardX : Int, cardY : Int }
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


fivePosFromMouse : DragState -> Drag.MousePos -> { x : Int, y : Int }
fivePosFromMouse d pos =
    -- Container-local position of the dragged 5's top-left.
    { x = pos.x - d.offsetX - containerOriginX
    , y = pos.y - d.offsetY - containerOriginY
    }


cardRectAt : { x : Int, y : Int } -> Placement
cardRectAt pos =
    { x = pos.x, y = pos.y, w = cw, h = ch }


isCardSix : BoardCard -> Bool
isCardSix bc =
    bc.card.value == 6


isCardSeven : BoardCard -> Bool
isCardSeven bc =
    bc.card.value == 7


cardContainerPos : Placement -> BoardCard -> { x : Int, y : Int }
cardContainerPos place bc =
    { x = place.x + bc.offsetX, y = place.y + bc.offsetY }


updateBoardCardOffset : (BoardCard -> Bool) -> { offsetX : Int, offsetY : Int } -> List BoardCard -> List BoardCard
updateBoardCardOffset pred new cards =
    List.map
        (\bc ->
            if pred bc then
                { bc | offsetX = new.offsetX, offsetY = new.offsetY }

            else
                bc
        )
        cards


containerToBoardOffset : Placement -> { x : Int, y : Int } -> { offsetX : Int, offsetY : Int }
containerToBoardOffset place pos =
    { offsetX = pos.x - place.x, offsetY = pos.y - place.y }


find : (a -> Bool) -> List a -> Maybe a
find pred xs =
    List.head (List.filter pred xs)



-- UPDATE


update : Msg -> State -> ( State, Cmd Msg, GestureOutcome )
update msg state =
    case msg of
        HandCardDown mouse cardXY ->
            case ( state.hand, state.released ) of
                ( Just card, Nothing ) ->
                    ( { state
                        | dragging =
                            Just
                                { card = card
                                , offsetX = mouse.x - cardXY.cardX
                                , offsetY = mouse.y - cardXY.cardY
                                , kinematics = Drag.initKinematics mouse state.nowMillis
                                , contact = Nothing
                                }
                      }
                    , Cmd.none
                    , Pending
                    )

                _ ->
                    ( state, Cmd.none, Pending )

        MouseMoved pos ->
            case state.dragging of
                Just d ->
                    handleMouseMove pos d state

                Nothing ->
                    ( state, Cmd.none, Pending )

        MouseUp pos ->
            case state.dragging of
                Just d ->
                    handleMouseUp pos d state

                Nothing ->
                    ( state, Cmd.none, Pending )

        Tick ms ->
            handleTick ms state


handleMouseMove : Drag.MousePos -> DragState -> State -> ( State, Cmd Msg, GestureOutcome )
handleMouseMove pos d state =
    let
        kAfterMove =
            Drag.advanceMouseSample pos state.nowMillis d.kinematics

        fivePos =
            fivePosFromMouse d pos
    in
    case d.contact of
        Just contact ->
            -- Already coupled: 6 and 7 follow the 5 in 2D
            -- using the at-contact offsets.
            let
                sixContainer =
                    { x = fivePos.x + contact.sixDx, y = fivePos.y + contact.sixDy }

                sevenContainer =
                    { x = fivePos.x + contact.sevenDx, y = fivePos.y + contact.sevenDy }

                sixOffset =
                    containerToBoardOffset state.config.initialBoardPlace sixContainer

                sevenOffset =
                    containerToBoardOffset state.config.initialBoardPlace sevenContainer

                newBoardCards =
                    state.boardCards
                        |> updateBoardCardOffset isCardSix sixOffset
                        |> updateBoardCardOffset isCardSeven sevenOffset
            in
            ( { state
                | boardCards = newBoardCards
                , dragging = Just { d | kinematics = kAfterMove }
              }
            , Cmd.none
            , Pending
            )

        Nothing ->
            -- Pre-contact: check for first overlap with the 6.
            let
                sixBC =
                    find isCardSix state.boardCards

                sevenBC =
                    find isCardSeven state.boardCards

                sixContainer =
                    Maybe.map (cardContainerPos state.config.initialBoardPlace) sixBC

                collided =
                    Maybe.map
                        (\sp -> Drag.rectsOverlap (cardRectAt fivePos) (cardRectAt sp))
                        sixContainer
                        |> Maybe.withDefault False
            in
            if collided then
                let
                    sevenContainer =
                        Maybe.map (cardContainerPos state.config.initialBoardPlace) sevenBC

                    contact =
                        case ( sixContainer, sevenContainer ) of
                            ( Just sp, Just svp ) ->
                                Just
                                    { sixDx = sp.x - fivePos.x
                                    , sixDy = sp.y - fivePos.y
                                    , sevenDx = svp.x - fivePos.x
                                    , sevenDy = svp.y - fivePos.y
                                    }

                            _ ->
                                Nothing
                in
                ( { state
                    | dragging = Just { d | kinematics = kAfterMove, contact = contact }
                  }
                , Cmd.none
                , Pending
                )

            else
                ( { state | dragging = Just { d | kinematics = kAfterMove } }
                , Cmd.none
                , Pending
                )


handleMouseUp : Drag.MousePos -> DragState -> State -> ( State, Cmd Msg, GestureOutcome )
handleMouseUp pos d state =
    case d.contact of
        Just _ ->
            -- Couple released: enter the 30ms pause before snap.
            -- The 5 visually freezes at its last position; tick
            -- handler will fire the snap when the deadline hits.
            let
                fivePos =
                    fivePosFromMouse d pos
            in
            ( { state
                | dragging = Nothing
                , released =
                    Just
                        { atX = fivePos.x
                        , atY = fivePos.y
                        , snapAt = state.nowMillis + snapPauseMs
                        }
              }
            , Cmd.none
            , Pending
            )

        Nothing ->
            -- No contact ever happened: snap the 5 back to hand.
            -- (Hand stays Just; trial reports as a fail.)
            let
                durMs =
                    max 0 (state.nowMillis - d.kinematics.startedAtMs)
            in
            ( { state | dragging = Nothing }
            , Cmd.none
            , Completed
                { ok = False
                , durationMs = durMs
                , move = MoveSnapBack
                , extra = Drag.kinematicsLogFields d.kinematics
                }
            )


handleTick : Int -> State -> ( State, Cmd Msg, GestureOutcome )
handleTick ms state =
    let
        baseUpdated =
            { state | nowMillis = ms }
    in
    case state.released of
        Just released ->
            if ms >= released.snapAt then
                -- Time to snap: place new 5 adjacent to the 6's
                -- current position.
                case find isCardSix state.boardCards of
                    Just six ->
                        let
                            newFive =
                                { card = handCard
                                , offsetX = six.offsetX - pitch
                                , offsetY = six.offsetY
                                }

                            -- Insert before the 6 so the visual
                            -- order matches the values 5,6,7.
                            newBoardCards =
                                insertBefore isCardSix newFive state.boardCards
                        in
                        ( { baseUpdated
                            | hand = Nothing
                            , boardCards = newBoardCards
                            , released = Nothing
                          }
                        , Cmd.none
                        , Completed
                            { ok = True
                            , durationMs = max 0 (ms - released.snapAt) + snapPauseMs
                            , move = MoveInjected
                            , extra = []
                            }
                        )

                    Nothing ->
                        -- 6 missing — shouldn't happen.
                        ( baseUpdated, Cmd.none, Pending )

            else
                ( baseUpdated, Cmd.none, Pending )

        Nothing ->
            ( baseUpdated, Cmd.none, Pending )


insertBefore : (a -> Bool) -> a -> List a -> List a
insertBefore pred new xs =
    case xs of
        [] ->
            [ new ]

        x :: rest ->
            if pred x then
                new :: x :: rest

            else
                x :: insertBefore pred new rest



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
    let
        dragOverlay =
            case state.dragging of
                Just d ->
                    Style.draggedCardOverlay
                        { atViewport = ( d.kinematics.mouseX - d.offsetX, d.kinematics.mouseY - d.offsetY )
                        , card = d.card
                        }

                Nothing ->
                    case state.released of
                        Just released ->
                            -- Frozen at last position during the
                            -- 30ms pause. Render at viewport coords.
                            Style.draggedCardOverlay
                                { atViewport =
                                    ( released.atX + containerOriginX
                                    , released.atY + containerOriginY
                                    )
                                , card = handCard
                                }

                        Nothing ->
                            Html.text ""
    in
    Html.div []
        [ Style.playSurface
            [ viewBoard state.config.initialBoardPlace state.boardCards
            , viewHand state.config.initialHandOrigin state.hand (state.dragging /= Nothing)
            ]
        , dragOverlay
        ]


viewBoard : Placement -> List BoardCard -> Html Msg
viewBoard place cards =
    Html.div []
        (List.map
            (\bc ->
                Html.div
                    (Style.posAbsolute (place.x + bc.offsetX) (place.y + bc.offsetY))
                    [ Style.cardCanvas bc.card ]
            )
            cards
        )


viewHand : { x : Int, y : Int } -> Maybe Card -> Bool -> Html Msg
viewHand origin hand isDragging =
    case hand of
        Nothing ->
            Html.text ""

        Just card ->
            Html.div
                (Style.posAbsolute origin.x origin.y
                    ++ [ HA.style "cursor" "grab"
                       , HA.style "opacity"
                            (if isDragging then
                                "0.35"

                             else
                                "1"
                            )
                       , Html.Events.on "mousedown" handDownDecoder
                       ]
                )
                [ Style.cardCanvas card ]


handDownDecoder : D.Decoder Msg
handDownDecoder =
    D.map3
        (\mx my ( ox, oy ) ->
            HandCardDown
                { x = mx, y = my }
                { cardX = mx - ox, cardY = my - oy }
        )
        (D.field "clientX" D.int)
        (D.field "clientY" D.int)
        (D.map2 Tuple.pair (D.field "offsetX" D.int) (D.field "offsetY" D.int))
