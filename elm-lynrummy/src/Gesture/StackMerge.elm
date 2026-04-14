module Gesture.StackMerge exposing
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

{-| Gesture plugin: drag a small stack (e.g. 3 cards) onto a
larger stack (e.g. 5 cards) on the board to merge them. Per the
plan we agreed on:

  - Target is fixed in place, never moves, always 100% opacity.
  - Source is the only thing that drags. Rigid: the whole multi-
    card unit translates together at the same offset.
  - On invalid drop, source snaps back to its origin (settled
    rule, not a study variable).
  - Ghost preview shows the source at its final snap position
    when the merge would land (the 5 target cards stay put — no
    auto-rearrangement, no 6/8-card preview).

Same plugin shape as `Gesture.SingleCardDrop`. See ARCHITECTURE.md.
-}

import Browser.Events
import Card exposing (Card, Stack(..), stackCards, stackWithCards)
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
    "stack_merge"



-- CONFIG (host-provided)


type alias Config =
    { wing : String -- "W1" (1-card wing) or "W3" (3-card wing)
    , lookaheadMs : Float -- 60ms or 0ms
    , unlockRatio : Float -- shipped 0.25
    , projectionCapPx : Float -- 0 = uncapped; otherwise max projection magnitude in px
    , opacity : Float -- ghost opacity, shipped 0.7
    , initialSource : List Card -- 3-card draggable
    , initialTarget : List Card -- 5-card fixed
    , validSide : String -- "L" or "R" — which side of target the merge lands on
    , initialSourcePlace : Placement
    , initialTargetPlace : Placement
    }



-- MOVE (reported on Completed)


type Move
    = MoveMergeStacks
        { side : String
        , sourceCards : List Card
        , targetCards : List Card
        }
    | MoveSnapBack



-- DOMAIN STATE


type alias DragState =
    { offsetX : Int -- mouse-to-source-origin offset (container-local)
    , offsetY : Int
    , kinematics : Drag.Kinematics
    }


type alias State =
    { config : Config
    , source : List Card
    , target : List Card
    , sourcePlace : Placement -- moves during drag
    , sourceOriginPlace : Placement -- where it started; snap-back target
    , targetPlace : Placement
    , landingPlace : Placement -- the merge zone, geometry depends on wing width
    , dragging : Maybe DragState
    , nowMillis : Int
    }



-- LANDING ZONE GEOMETRY


{-| Snap position for source.x on a successful merge. This is
where the source's leftmost card ends up (the whole 3-stack
shifts so its leading card ends up adjacent to the target).
-}
snapSourceXFor : String -> Placement -> Int -> Int
snapSourceXFor side targetPlace targetCount =
    case side of
        "L" ->
            -- Source's leftmost lands 3*pitch left of target's
            -- leftmost, so source's rightmost abuts target's
            -- leftmost with the standard 2px inter-card gap.
            targetPlace.x - 3 * pitch

        _ ->
            -- Source's leftmost lands one pitch past target's
            -- rightmost card.
            targetPlace.x + targetCount * pitch


{-| Wing width in card-widths. W1 = 1 card; W3 = 3 cards.
Production always uses 1 card; W3 is the artificial study
condition for testing tolerance impact.
-}
wingWidthCards : String -> Int
wingWidthCards wing =
    case wing of
        "W3" ->
            3

        _ ->
            1


{-| The wing is the visible landing-zone flap, **adjacent to
the target stack on the merge side**. Width depends on the W1/W3
condition; for W3 the extra card-widths extend outward (away
from target), so the wing always touches target and grows away
from it — never floats free in the gap between source and target.
-}
wingFor : String -> String -> Placement -> Int -> Placement
wingFor side wing targetPlace targetCount =
    let
        widthCards =
            wingWidthCards wing

        zoneW =
            widthCards * cw

        zoneX =
            case side of
                "L" ->
                    -- Wing's right edge sits at target.x - 2
                    -- (one pitch's worth of inter-card gap).
                    targetPlace.x - 2 - zoneW

                _ ->
                    -- Wing's left edge sits one pitch past
                    -- target's rightmost card.
                    targetPlace.x + targetCount * pitch
    in
    { x = zoneX, y = targetPlace.y, w = zoneW, h = ch }


{-| The source has 3 cards in a row; on a merge the card that
abuts the target is the one closest to the target side:
- L merge: source's RIGHTMOST card abuts target's leftmost
- R merge: source's LEFTMOST card abuts target's rightmost
This helper gives the rect of that "adjacent" card given the
current source position and merge direction.
-}
leadingCardRectIn : String -> Placement -> Placement
leadingCardRectIn side sourcePlace =
    let
        leadX =
            case side of
                "L" ->
                    -- Rightmost of 3-card source = source.x + 2*pitch.
                    sourcePlace.x + 2 * pitch

                _ ->
                    -- Leftmost.
                    sourcePlace.x
    in
    { x = leadX, y = sourcePlace.y, w = cw, h = ch }


{-| Lock threshold scales inversely with wing width so the
ABSOLUTE card-area-overlap requirement stays constant across
widths. W1 requires 50% of (1-card) zone area; W3 requires 50%/3
≈ 0.167 of (3-card) zone area. Both come out to the same minimum
card-area overlap (~½ card). Wider wing lets the player be in
more positions, but the overlap demand is the same.
-}
lockRatioFor : String -> Float
lockRatioFor wing =
    0.5 / toFloat (wingWidthCards wing)


{-| Unlock threshold = HALF the lock threshold, matching the
shipped 0.50 → 0.25 ratio from experiment 3. Has to scale with
the lock threshold per wing width — otherwise W3's unlock (fixed
0.25) exceeds its lock (0.167) and hysteresis inverts, causing
massive flicker. Lesson learned the hard way.
-}
unlockRatioFor : String -> Float
unlockRatioFor wing =
    lockRatioFor wing * 0.5


-- projectedWithCap moved to Drag.elm — call Drag.projectedWithCap directly.



-- INIT


init : Config -> State
init cfg =
    { config = cfg
    , source = cfg.initialSource
    , target = cfg.initialTarget
    , sourcePlace = cfg.initialSourcePlace
    , sourceOriginPlace = cfg.initialSourcePlace
    , targetPlace = cfg.initialTargetPlace
    , landingPlace = wingFor cfg.validSide cfg.wing cfg.initialTargetPlace (List.length cfg.initialTarget)
    , dragging = Nothing
    , nowMillis = 0
    }



-- MSG


type Msg
    = SourceMouseDown Drag.MousePos
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
        SourceMouseDown mouse ->
            let
                -- Convert mouse viewport coords to container, then
                -- compute offset from source's leftmost card.
                mouseContainerX =
                    mouse.x - containerOriginX

                mouseContainerY =
                    mouse.y - containerOriginY
            in
            ( { state
                | dragging =
                    Just
                        { offsetX = mouseContainerX - state.sourcePlace.x
                        , offsetY = mouseContainerY - state.sourcePlace.y
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
                        -- Step 1: fold the new mouse sample into
                        -- kinematics (advances velocity, peak speed,
                        -- numMoves, mouse position, lastMs).
                        kAfterMove =
                            Drag.advanceMouseSample pos state.nowMillis d.kinematics

                        newSourceX =
                            (pos.x - containerOriginX) - d.offsetX

                        newSourceY =
                            (pos.y - containerOriginY) - d.offsetY

                        newSourcePlace =
                            { x = newSourceX, y = newSourceY, w = state.sourcePlace.w, h = state.sourcePlace.h }

                        leadingCardRect =
                            leadingCardRectIn state.config.validSide newSourcePlace

                        projected =
                            Drag.projectedWithCap leadingCardRect kAfterMove.vx kAfterMove.vy state.config.lookaheadMs state.config.projectionCapPx

                        locked =
                            Drag.isLockedWithHysteresis
                                d.kinematics.wasLocked
                                (lockRatioFor state.config.wing)
                                (unlockRatioFor state.config.wing)
                                projected
                                state.landingPlace

                        -- Step 2: write the new lock state into
                        -- kinematics, bumping lockTransitions if it
                        -- flipped.
                        kFinal =
                            Drag.commitLockState locked kAfterMove
                    in
                    ( { state
                        | sourcePlace = newSourcePlace
                        , dragging = Just { d | kinematics = kFinal }
                      }
                    , Cmd.none
                    , Pending
                    )

                Nothing ->
                    ( state, Cmd.none, Pending )

        MouseUp pos ->
            case state.dragging of
                Just d ->
                    let
                        releaseSourcePlace =
                            { x = (pos.x - containerOriginX) - d.offsetX
                            , y = (pos.y - containerOriginY) - d.offsetY
                            , w = state.sourcePlace.w
                            , h = state.sourcePlace.h
                            }

                        leadingCardRect =
                            leadingCardRectIn state.config.validSide releaseSourcePlace

                        projectedAtRelease =
                            Drag.projectedWithCap leadingCardRect d.kinematics.vx d.kinematics.vy state.config.lookaheadMs state.config.projectionCapPx

                        locked =
                            Drag.isLockedWithHysteresis
                                d.kinematics.wasLocked
                                (lockRatioFor state.config.wing)
                                (unlockRatioFor state.config.wing)
                                projectedAtRelease
                                state.landingPlace

                        zoneCx =
                            toFloat state.landingPlace.x + toFloat state.landingPlace.w / 2

                        zoneCy =
                            toFloat state.landingPlace.y + toFloat state.landingPlace.h / 2

                        releaseCx =
                            toFloat leadingCardRect.x + toFloat leadingCardRect.w / 2

                        releaseCy =
                            toFloat leadingCardRect.y + toFloat leadingCardRect.h / 2

                        distToZone =
                            sqrt ((releaseCx - zoneCx) ^ 2 + (releaseCy - zoneCy) ^ 2)

                        durMs =
                            max 0 (state.nowMillis - d.kinematics.startedAtMs)

                        gestureFields =
                            [ ( "wing", E.string state.config.wing )
                            , ( "validSide", E.string state.config.validSide )
                            , ( "opacity", E.float state.config.opacity )
                            , ( "unlockRatio", E.float (unlockRatioFor state.config.wing) )
                            , ( "lookaheadMs", E.float state.config.lookaheadMs )
                            , ( "projectionCapPx", E.float state.config.projectionCapPx )
                            , ( "releaseX", E.int pos.x )
                            , ( "releaseY", E.int pos.y )
                            , ( "distFromZone", E.float distToZone )
                            ]

                        extra =
                            gestureFields ++ Drag.kinematicsLogFields d.kinematics

                        landedSourcePlace =
                            -- Snap source to its production-canonical
                            -- adjacent position, regardless of where
                            -- in the wing the player released.
                            { x = snapSourceXFor state.config.validSide state.targetPlace (List.length state.target)
                            , y = state.targetPlace.y
                            , w = state.sourcePlace.w
                            , h = state.sourcePlace.h
                            }
                    in
                    if locked then
                        let
                            move =
                                MoveMergeStacks
                                    { side = state.config.validSide
                                    , sourceCards = state.source
                                    , targetCards = state.target
                                    }
                        in
                        ( { state | sourcePlace = landedSourcePlace, dragging = Nothing }
                        , Cmd.none
                        , Completed { ok = True, durationMs = durMs, move = move, extra = extra }
                        )

                    else
                        -- Snap-back to origin.
                        ( { state | sourcePlace = state.sourceOriginPlace, dragging = Nothing }
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
                        currentSourcePlace =
                            { x = (d.kinematics.mouseX - containerOriginX) - d.offsetX
                            , y = (d.kinematics.mouseY - containerOriginY) - d.offsetY
                            , w = state.sourcePlace.w
                            , h = state.sourcePlace.h
                            }

                        leadingCardRect =
                            leadingCardRectIn state.config.validSide currentSourcePlace

                        projected =
                            Drag.projectedWithCap leadingCardRect d.kinematics.vx d.kinematics.vy state.config.lookaheadMs state.config.projectionCapPx

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
                            Drag.isLockedWithHysteresis
                                d.kinematics.wasLocked
                                (lockRatioFor state.config.wing)
                                (unlockRatioFor state.config.wing)
                                projected
                                state.landingPlace
                    in
                    Just { proximity = proximity, locked = locked }

                Nothing ->
                    Nothing
    in
    Style.playSurface
        [ Style.cardRow { at = state.targetPlace, cards = state.target }
        , viewLandingZone state.landingPlace landingSignal
        , viewGhostSource state landingSignal
        , viewSource state
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


viewGhostSource : State -> Maybe { proximity : Float, locked : Bool } -> Html Msg
viewGhostSource state signal =
    case signal of
        Just { locked } ->
            if locked then
                let
                    -- Ghost is the source's three cards arranged
                    -- at the canonical snap position.
                    ghostX =
                        snapSourceXFor state.config.validSide state.targetPlace (List.length state.target)

                    ghostPlace =
                        { x = ghostX
                        , y = state.targetPlace.y
                        , w = state.sourcePlace.w
                        , h = ch
                        }
                in
                Html.div
                    (Style.posAbsolute ghostPlace.x ghostPlace.y
                        ++ [ HA.style "opacity" (String.fromFloat state.config.opacity)
                           , Style.noPointer
                           ]
                    )
                    [ -- Reuse cardRow's layout machinery without
                      -- wrapping in another absolute div: we render
                      -- the row at (0,0) inside the ghost wrapper.
                      Style.cardRow
                        { at = { x = 0, y = 0, w = state.sourcePlace.w, h = ch }
                        , cards = state.source
                        }
                    ]

            else
                Html.text ""

        Nothing ->
            Html.text ""


{-| The draggable source stack. Renders all 3 cards as a rigid
unit at sourcePlace, with a mousedown handler on each card so
clicking any of them grabs the whole stack.
-}
viewSource : State -> Html Msg
viewSource state =
    let
        n =
            List.length state.source

        opacity =
            -- Production rule: dragged stack stays at 100%
            -- opacity. So even mid-drag we render full.
            "1.0"
    in
    Html.div
        (Style.posAbsolute state.sourcePlace.x state.sourcePlace.y
            ++ [ HA.style "cursor" "grab"
               , HA.style "opacity" opacity
               , Html.Events.on "mousedown" sourceDownDecoder
               ]
        )
        [ -- Inline SVG with all source cards. We can't use
          -- Style.cardRow directly here because that would wrap
          -- the row in another absolutely positioned div, and we
          -- need this one to carry the mousedown handler.
          Style.cardRow
            { at = { x = 0, y = 0, w = cw + (n - 1) * pitch, h = ch }
            , cards = state.source
            }
        ]


sourceDownDecoder : D.Decoder Msg
sourceDownDecoder =
    D.map2
        (\mx my -> SourceMouseDown { x = mx, y = my })
        (D.field "clientX" D.int)
        (D.field "clientY" D.int)
