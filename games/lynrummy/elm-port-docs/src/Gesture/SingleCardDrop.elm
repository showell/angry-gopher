module Gesture.SingleCardDrop exposing
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

{-| Gesture plugin: drag a single card from the hand onto a
landing zone at one end of a board run.

This is the first solidified gesture in the LynRummy study
program. Empirical tuning lives in
`elm-lynrummy/STUDY_RESULTS.md`.

The plugin's State and Msg are opaque to the host. The host
provides Config at trial start; the plugin reports an
`GestureOutcome` when the trial completes (success or fail).

Config is the per-trial parameterization the host wants to vary
(e.g. landing side L vs R, ghost opacity, lookahead ms). Defaults
are filled in at module level if the host doesn't override them
in a study.
-}

import Browser.Events
import Card exposing (Card, Stack(..), placeLanded, stackCards, stackWithCards)
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
    "single_card_drop"



-- CONFIG (host-provided)


type alias Config =
    { side : String -- "L" extends the run on the left, "R" on the right
    , opacity : Float -- ghost preview opacity
    , unlockRatio : Float -- hysteresis depth (lower = stickier)
    , lookaheadMs : Float -- momentum projection horizon
    , initialBoard : Stack -- caller-provided starting board state
    , initialHand : List Card -- caller-provided starting hand
    , initialStackPlace : Placement -- where the board run renders
    , initialHandOrigin : { x : Int, y : Int } -- where the hand's first card sits
    }


{-| What the gesture did, reported on Completed for the host to
apply to its persistent model. Studies can ignore this (they
re-init the board on the next trial). Production reads it.
-}
type Move
    = MoveAppendCard
        { side : String
        , card : Card
        , fromHandIdx : Int
        }
    | MoveSnapBack



-- DOMAIN STATE


type alias DragState =
    { card : Card
    , offsetX : Int
    , offsetY : Int
    , kinematics : Drag.Kinematics
    }


type alias State =
    { config : Config
    , hand : List Card
    , boardStack : Stack
    , stackPlace : Placement
    , landingPlace : Placement
    , handOrigin : { x : Int, y : Int }
    , dragging : Maybe DragState
    , nowMillis : Int
    }


{-| Pitch-aligned: zone position equals where the card will
actually render on release, so there's no visual snap. Derived
from the caller-supplied stack placement.
-}
landingPlacementFor : String -> Placement -> Placement
landingPlacementFor side stackPlace =
    case side of
        "L" ->
            { x = stackPlace.x - pitch
            , y = stackPlace.y
            , w = cw
            , h = ch
            }

        _ ->
            { x = stackPlace.x + 3 * pitch
            , y = stackPlace.y
            , w = cw
            , h = ch
            }


-- INIT


init : Config -> State
init cfg =
    { config = cfg
    , hand = cfg.initialHand
    , boardStack = cfg.initialBoard
    , stackPlace = cfg.initialStackPlace
    , landingPlace = landingPlacementFor cfg.side cfg.initialStackPlace
    , handOrigin = cfg.initialHandOrigin
    , dragging = Nothing
    , nowMillis = 0
    }



-- MSG


type Msg
    = HandCardDown Int Drag.MousePos { cardX : Int, cardY : Int }
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



-- UPDATE


update : Msg -> State -> ( State, Cmd Msg, GestureOutcome )
update msg state =
    case msg of
        HandCardDown i mouse cardXY ->
            case getAt i state.hand of
                Just card ->
                    ( { state
                        | dragging =
                            Just
                                { card = card
                                , offsetX = mouse.x - cardXY.cardX
                                , offsetY = mouse.y - cardXY.cardY
                                , kinematics = Drag.initKinematics mouse state.nowMillis
                                }
                      }
                    , Cmd.none
                    , Pending
                    )

                Nothing ->
                    ( state, Cmd.none, Pending )

        MouseMoved pos ->
            case state.dragging of
                Just d ->
                    let
                        kAfterMove =
                            Drag.advanceMouseSample pos state.nowMillis d.kinematics

                        dragRect =
                            { x = pos.x - d.offsetX - containerOriginX
                            , y = pos.y - d.offsetY - containerOriginY
                            , w = cw
                            , h = ch
                            }

                        projected =
                            Drag.projectedRect dragRect kAfterMove.vx kAfterMove.vy state.config.lookaheadMs

                        locked =
                            Drag.isLockedWithHysteresis d.kinematics.wasLocked Drag.lockThresholdRatio state.config.unlockRatio projected state.landingPlace

                        kFinal =
                            Drag.commitLockState locked kAfterMove
                    in
                    ( { state | dragging = Just { d | kinematics = kFinal } }
                    , Cmd.none
                    , Pending
                    )

                Nothing ->
                    ( state, Cmd.none, Pending )

        MouseUp pos ->
            case state.dragging of
                Just d ->
                    let
                        draggedRect =
                            { x = pos.x - d.offsetX - containerOriginX
                            , y = pos.y - d.offsetY - containerOriginY
                            , w = cw
                            , h = ch
                            }

                        projectedAtRelease =
                            Drag.projectedRect draggedRect d.kinematics.vx d.kinematics.vy state.config.lookaheadMs

                        locked =
                            Drag.isLockedWithHysteresis d.kinematics.wasLocked Drag.lockThresholdRatio state.config.unlockRatio projectedAtRelease state.landingPlace

                        zoneCx =
                            toFloat state.landingPlace.x + toFloat state.landingPlace.w / 2

                        zoneCy =
                            toFloat state.landingPlace.y + toFloat state.landingPlace.h / 2

                        releaseCx =
                            toFloat draggedRect.x + toFloat draggedRect.w / 2

                        releaseCy =
                            toFloat draggedRect.y + toFloat draggedRect.h / 2

                        distToZone =
                            sqrt ((releaseCx - zoneCx) ^ 2 + (releaseCy - zoneCy) ^ 2)

                        durMs =
                            max 0 (state.nowMillis - d.kinematics.startedAtMs)

                        gestureFields =
                            [ ( "side", E.string state.config.side )
                            , ( "opacity", E.float state.config.opacity )
                            , ( "unlockRatio", E.float state.config.unlockRatio )
                            , ( "lookaheadMs", E.float state.config.lookaheadMs )
                            , ( "releaseX", E.int pos.x )
                            , ( "releaseY", E.int pos.y )
                            , ( "distFromZone", E.float distToZone )
                            ]

                        extra =
                            gestureFields ++ Drag.kinematicsLogFields d.kinematics

                        landedBoard =
                            stackWithCards state.boardStack
                                (placeLanded state.config.side d.card (stackCards state.boardStack))

                        landedHand =
                            removeAt 0 state.hand

                        landedStackPlace =
                            if state.config.side == "L" then
                                let
                                    sp =
                                        state.stackPlace
                                in
                                { sp | x = sp.x - pitch }

                            else
                                state.stackPlace
                    in
                    if locked then
                        let
                            move =
                                MoveAppendCard
                                    { side = state.config.side
                                    , card = d.card
                                    , fromHandIdx = 0
                                    }
                        in
                        ( { state
                            | boardStack = landedBoard
                            , hand = landedHand
                            , stackPlace = landedStackPlace
                            , dragging = Nothing
                          }
                        , Cmd.none
                        , Completed { ok = True, durationMs = durMs, move = move, extra = extra }
                        )

                    else
                        -- Snap-back is the settled rule.
                        ( { state | dragging = Nothing }
                        , Cmd.none
                        , Completed { ok = False, durationMs = durMs, move = MoveSnapBack, extra = extra }
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
    let
        landingSignal =
            case state.dragging of
                Just d ->
                    let
                        dragRect =
                            { x = d.kinematics.mouseX - d.offsetX - containerOriginX
                            , y = d.kinematics.mouseY - d.offsetY - containerOriginY
                            , w = cw
                            , h = ch
                            }

                        projected =
                            Drag.projectedRect dragRect d.kinematics.vx d.kinematics.vy state.config.lookaheadMs

                        dragCX =
                            projected.x + cw // 2

                        dragCY =
                            projected.y + ch // 2

                        landCX =
                            state.landingPlace.x + state.landingPlace.w // 2

                        landCY =
                            state.landingPlace.y + state.landingPlace.h // 2

                        dist =
                            sqrt (toFloat ((dragCX - landCX) ^ 2 + (dragCY - landCY) ^ 2))

                        proximity =
                            clamp 0.0 1.0 (1.0 - dist / 220.0)

                        locked =
                            Drag.isLockedWithHysteresis d.kinematics.wasLocked Drag.lockThresholdRatio state.config.unlockRatio projected state.landingPlace
                    in
                    Just { proximity = proximity, locked = locked }

                Nothing ->
                    Nothing

        dragOverlay =
            case state.dragging of
                Just d ->
                    Style.draggedCardOverlay
                        { atViewport = ( d.kinematics.mouseX - d.offsetX, d.kinematics.mouseY - d.offsetY )
                        , card = d.card
                        }

                Nothing ->
                    Html.text ""
    in
    Html.div []
        [ Style.playSurface
            [ Style.cardRow { at = state.stackPlace, cards = stackCards state.boardStack }
            , viewLandingZone state.landingPlace landingSignal
            , viewLockPreview state landingSignal
            , viewHand state.handOrigin state.hand (state.dragging /= Nothing)
            ]
        , dragOverlay
        ]


viewLandingZone : Placement -> Maybe { proximity : Float, locked : Bool } -> Html Msg
viewLandingZone place signal =
    case signal of
        Nothing ->
            Html.text ""

        Just { proximity } ->
            Style.landingZone
                { at = place
                , fillAlpha = proximity * 0.45
                , outlineAlpha = 0.2 + proximity * 0.8
                }


viewLockPreview : State -> Maybe { proximity : Float, locked : Bool } -> Html Msg
viewLockPreview state signal =
    case ( signal, state.dragging ) of
        ( Just { locked }, Just d ) ->
            if locked then
                Style.cardGhost
                    { at = state.landingPlace
                    , opacity = state.config.opacity
                    , card = d.card
                    }

            else
                Html.text ""

        _ ->
            Html.text ""


viewHand : { x : Int, y : Int } -> List Card -> Bool -> Html Msg
viewHand origin hand isDragging =
    Html.div
        (Style.posAbsolute origin.x origin.y)
        (List.indexedMap (viewHandCard isDragging) hand)


viewHandCard : Bool -> Int -> Card -> Html Msg
viewHandCard isDragging i card =
    -- Hand cards stay slightly more bespoke than other widgets:
    -- they carry the per-card mousedown decoder + a "dimmed when
    -- dragging" opacity. Worth keeping inline rather than
    -- inventing a Style helper for a one-off shape.
    Html.div
        (Style.posAbsolute (i * pitch) 0
            ++ [ HA.style "cursor" "grab"
               , HA.style "opacity"
                    (if isDragging then
                        "0.35"

                     else
                        "1"
                    )
               , Html.Events.on "mousedown" (handDownDecoder i)
               ]
        )
        [ Style.cardCanvas card ]


handDownDecoder : Int -> D.Decoder Msg
handDownDecoder i =
    D.map3
        (\mx my ( ox, oy ) ->
            HandCardDown i
                { x = mx, y = my }
                { cardX = mx - ox, cardY = my - oy }
        )
        (D.field "clientX" D.int)
        (D.field "clientY" D.int)
        (D.map2 Tuple.pair (D.field "offsetX" D.int) (D.field "offsetY" D.int))



-- HELPERS (small enough to live here vs. a util module)


getAt : Int -> List a -> Maybe a
getAt i xs =
    List.head (List.drop i xs)


removeAt : Int -> List a -> List a
removeAt i xs =
    List.take i xs ++ List.drop (i + 1) xs
