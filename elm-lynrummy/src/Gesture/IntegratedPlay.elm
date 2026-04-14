module Gesture.IntegratedPlay exposing
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

{-| Integrated play prototype: hand cards (5 and 8) meet a board
run (234567) with three coexisting physics contracts:

  - **5 → 6**: nudge / couple. On collision with the 6, the
    target stack splits at that point. The right-half stack
    (6-onward) couples to the cursor and follows it in 2D. On
    release, 30ms pause, then the 5 snaps adjacent to the 6 by
    joining the new sub-stack.
  - **8 → 7**: approach / snap. Collision with the 7 instantly
    appends the 8 to whichever stack contains the 7.
  - **Click any board card**: grab the whole stack and reposition
    it (rigid-unit drag, like MoveStack). Pure relocation, no
    splits, no snap-back.

The model uses explicit stacks (not flat board cards), so splits
and moves are both expressed as stack-list mutations. Multiple
stacks coexist after the first inject; you can tidy them by
dragging.
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
    "integrated_play"



-- CONFIG


type alias Config =
    { initialBoardPlace : Placement
    , initialFivePos : { x : Int, y : Int }
    , initialEightPos : { x : Int, y : Int }
    , mechanism : String -- "hop" or "fill" (long-press feedback style)
    }



-- DOMAIN


type alias Stack =
    { cards : List Card
    , origin : { x : Int, y : Int } -- container-local
    }


type alias HandCard =
    { card : Card
    , origin : { x : Int, y : Int }
    }


type DragKind
    = -- Dragging a card from the hand area. May trigger
      -- inject (5) or extend (8) behavior on collision.
      HandKind { card : Card }
    | -- Dragging an existing board stack as a rigid unit.
      -- No collision behavior; pure spatial relocation.
      StackKind { stackIdx : Int, originAtStart : { x : Int, y : Int } }
    | -- A single card extracted from a stack via long-press.
      -- The card moves independently from its former neighbors.
      -- snapshotStacks holds the pre-extraction stacks list so a
      -- collision-snap-back can restore exactly what was there.
      -- liftedAtMs is the activation timestamp (used for the
      -- "hop" mechanism's brief upward bounce).
      LiftedCardKind
        { card : Card
        , snapshotStacks : List Stack
        , liftedAtMs : Int
        }


{-| For inject: identifies the stack that's coupled to the
dragged 5 and the offset from the dragged 5 to that stack's
origin (captured at the moment of collision). During coupled
drag, the stack's origin = (dragged 5 position) + (dx, dy).
-}
type alias Contact =
    { coupledStackIdx : Int
    , dx : Int
    , dy : Int
    }


type alias DragState =
    { kind : DragKind
    , offsetX : Int
    , offsetY : Int
    , kinematics : Drag.Kinematics
    , contact : Maybe Contact
    }


type alias ReleasedState =
    -- A hand card has been released and is waiting out the
    -- 30ms snap-pause before joining its target stack. We hold
    -- its last container-local position so it stays visible at
    -- the drop point during the pause.
    { atX : Int
    , atY : Int
    , snapAt : Int
    , targetStackIdx : Int
    , card : Card
    }


type alias AwaitingPress =
    -- Player has pressed down on a stack card but hasn't moved
    -- (or moved less than jitterPx). If they hold past
    -- longPressMs, we activate lift-extract; if they move
    -- first, we transition into a normal stack drag.
    { stackIdx : Int
    , cardIdx : Int
    , card : Card
    , downMouse : Drag.MousePos
    , downCardXY : { cardX : Int, cardY : Int }
    , stackOrigin : { x : Int, y : Int }
    , downAtMs : Int
    }


type alias State =
    { config : Config
    , hand : List HandCard
    , stacks : List Stack
    , dragging : Maybe DragState
    , awaiting : Maybe AwaitingPress
    , released : Maybe ReleasedState
    , nowMillis : Int
    }



-- MOVE


type Move
    = MoveInjected
    | MoveExtended
    | MoveStackRelocated
    | MoveHandRelocated
    | MoveCardExtracted
    | MoveSetCompleted
    | MoveSnapBack



-- HARDCODED SCENARIO


fiveCard : Card
fiveCard =
    { value = 5, suit = Hearts, deck = 1 }


eightCard : Card
eightCard =
    { value = 8, suit = Hearts, deck = 1 }


fiveSpades : Card
fiveSpades =
    { value = 5, suit = Spades, deck = 1 }


fiveClubs : Card
fiveClubs =
    { value = 5, suit = Clubs, deck = 1 }


initialBoardRun : List Card
initialBoardRun =
    List.map (\v -> { value = v, suit = Hearts, deck = 1 }) [ 2, 3, 4, 5, 6, 7 ]


initialFiveSet : List Card
initialFiveSet =
    [ fiveSpades, fiveClubs ]


snapPauseMs : Int
snapPauseMs =
    30


{-| Long-press dwell threshold (ms). Press-and-hold for at least
this long without moving to extract the pressed card from its
stack. Tunable.
-}
longPressMs : Int
longPressMs =
    250


{-| Movement tolerance (px) while awaiting long-press. Any
movement larger than this aborts the long-press and transitions
into a normal stack drag.
-}
jitterPx : Int
jitterPx =
    8


{-| Hysteresis depth for the 8 → 7 lock. Shipped 0.25 (half the
0.5 lock ratio), per the "hysteresis must scale together" finding.
-}
unlockRatio : Float
unlockRatio =
    Drag.lockThresholdRatio * 0.5


{-| Velocity-based lookahead horizon (ms). The lock test hits a
*projected* rect — where the player is aiming — not the cursor's
actual rect. Without projection, lock can only fire after you're
already on top of the slot, which means the ghost preview has no
time to appear. Shipped 60ms (per STUDY_RESULTS).
-}
lookaheadMs : Float
lookaheadMs =
    60


{-| Landing slot for the 8: immediately to the right of the
target stack's last card. Used both for lock detection and the
ghost preview.
-}
landingPlaceForEight : Stack -> Placement
landingPlaceForEight ts =
    let
        landPos =
            cardPosInStack ts (List.length ts.cards)
    in
    { x = landPos.x, y = landPos.y, w = cw, h = ch }



-- INIT


init : Config -> State
init cfg =
    { config = cfg
    , hand =
        [ { card = fiveCard, origin = cfg.initialFivePos }
        , { card = eightCard, origin = cfg.initialEightPos }
        ]
    , stacks =
        [ { cards = initialBoardRun
          , origin = { x = cfg.initialBoardPlace.x, y = cfg.initialBoardPlace.y }
          }
        , { cards = initialFiveSet
          , origin =
                { x = cfg.initialBoardPlace.x + 4 * pitch
                , y = cfg.initialBoardPlace.y + ch + 40
                }
          }
        ]
    , dragging = Nothing
    , awaiting = Nothing
    , released = Nothing
    , nowMillis = 0
    }



-- MSG


type Msg
    = HandMouseDown HandCard Drag.MousePos { cardX : Int, cardY : Int }
    | StackCardMouseDown
        { stackIdx : Int
        , cardIdx : Int
        , card : Card
        , stackOrigin : { x : Int, y : Int }
        }
        Drag.MousePos
        { cardX : Int, cardY : Int }
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


find : (a -> Bool) -> List a -> Maybe a
find pred xs =
    List.head (List.filter pred xs)


findIndex : (a -> Bool) -> List a -> Maybe Int
findIndex pred xs =
    let
        go i remaining =
            case remaining of
                [] ->
                    Nothing

                x :: rest ->
                    if pred x then
                        Just i

                    else
                        go (i + 1) rest
    in
    go 0 xs


cardRectAt : { x : Int, y : Int } -> Placement
cardRectAt pos =
    { x = pos.x, y = pos.y, w = cw, h = ch }


stackRect : Stack -> Placement
stackRect s =
    { x = s.origin.x
    , y = s.origin.y
    , w = cw + (max 0 (List.length s.cards - 1)) * pitch
    , h = ch
    }


{-| True if `rect` overlaps any stack other than the ones whose
indices appear in `excluding`. Coordinates are container-local.
-}
overlapsAnyStack : Placement -> List Int -> List Stack -> Bool
overlapsAnyStack rect excluding stacks =
    List.indexedMap Tuple.pair stacks
        |> List.any
            (\( i, s ) ->
                not (List.member i excluding)
                    && Drag.rectsOverlap rect (stackRect s)
            )


{-| Container-local position of card #i in a stack (0-indexed).
-}
cardPosInStack : Stack -> Int -> { x : Int, y : Int }
cardPosInStack stack i =
    { x = stack.origin.x + i * pitch
    , y = stack.origin.y
    }


fivePosFromMouse : DragState -> Drag.MousePos -> { x : Int, y : Int }
fivePosFromMouse d pos =
    { x = pos.x - d.offsetX - containerOriginX
    , y = pos.y - d.offsetY - containerOriginY
    }


{-| Find (stackIdx, cardIdxWithinStack) for the first card in
the stacks list that satisfies the predicate.
-}
findCardLocation : (Card -> Bool) -> List Stack -> Maybe { stackIdx : Int, cardIdx : Int }
findCardLocation pred stacks =
    let
        go si remaining =
            case remaining of
                [] ->
                    Nothing

                stack :: rest ->
                    case findIndex pred stack.cards of
                        Just ci ->
                            Just { stackIdx = si, cardIdx = ci }

                        Nothing ->
                            go (si + 1) rest
    in
    go 0 stacks



-- UPDATE


update : Msg -> State -> ( State, Cmd Msg, GestureOutcome )
update msg state =
    case msg of
        HandMouseDown hc mouse cardXY ->
            ( { state
                | dragging =
                    Just
                        { kind = HandKind { card = hc.card }
                        , offsetX = mouse.x - cardXY.cardX
                        , offsetY = mouse.y - cardXY.cardY
                        , kinematics = Drag.initKinematics mouse state.nowMillis
                        , contact = Nothing
                        }
              }
            , Cmd.none
            , Pending
            )

        StackCardMouseDown info mouse cardXY ->
            -- Defer the decision: are we starting a stack drag,
            -- or a long-press lift-extract? Park as `awaiting`.
            -- The decision resolves on first MouseMoved (jitter
            -- → stack drag) or on Tick reaching longPressMs
            -- (timeout → lift-extract).
            ( { state
                | awaiting =
                    Just
                        { stackIdx = info.stackIdx
                        , cardIdx = info.cardIdx
                        , card = info.card
                        , downMouse = mouse
                        , downCardXY = cardXY
                        , stackOrigin = info.stackOrigin
                        , downAtMs = state.nowMillis
                        }
              }
            , Cmd.none
            , Pending
            )

        MouseMoved pos ->
            case state.dragging of
                Just d ->
                    case d.kind of
                        HandKind { card } ->
                            case card.value of
                                5 ->
                                    handleFiveMove pos d state

                                8 ->
                                    handleEightMove pos d state

                                _ ->
                                    ( state, Cmd.none, Pending )

                        StackKind sk ->
                            handleStackMove pos d sk state

                        LiftedCardKind _ ->
                            handleLiftedMove pos d state

                Nothing ->
                    case state.awaiting of
                        Just ap ->
                            handleAwaitingMove pos ap state

                        Nothing ->
                            ( state, Cmd.none, Pending )

        MouseUp pos ->
            case state.dragging of
                Just d ->
                    case d.kind of
                        HandKind { card } ->
                            case card.value of
                                5 ->
                                    handleFiveUp pos d state

                                8 ->
                                    handleEightUp d state

                                _ ->
                                    handleHandRelocate d state

                        StackKind sk ->
                            handleStackUp d sk state

                        LiftedCardKind lk ->
                            handleLiftedUp d lk state

                Nothing ->
                    -- Mouse-up while still awaiting long-press =
                    -- a tap. No state change beyond clearing it.
                    ( { state | awaiting = Nothing }, Cmd.none, Pending )

        Tick ms ->
            handleTick ms state



-- THE 5: INJECT (collision with 6 → split target stack, couple right half)


handleFiveMove : Drag.MousePos -> DragState -> State -> ( State, Cmd Msg, GestureOutcome )
handleFiveMove pos d state =
    let
        kAfterMove =
            Drag.advanceMouseSample pos state.nowMillis d.kinematics

        fivePos =
            fivePosFromMouse d pos
    in
    case d.contact of
        Just contact ->
            -- Already coupled: update the coupled stack's origin
            -- to (dragged 5 position) + captured offset.
            let
                newCoupledOrigin =
                    { x = fivePos.x + contact.dx
                    , y = fivePos.y + contact.dy
                    }

                newStacks =
                    updateAt contact.coupledStackIdx
                        (\s -> { s | origin = newCoupledOrigin })
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
            -- Pre-contact: look for collision with any 6 on the
            -- board. If found, split that 6's stack at the 6
            -- and couple the right half.
            case findCardLocation (\c -> c.value == 6) state.stacks of
                Just loc ->
                    let
                        targetStack =
                            getAt loc.stackIdx state.stacks

                        sixPos =
                            Maybe.map (\ts -> cardPosInStack ts loc.cardIdx) targetStack

                        collided =
                            case sixPos of
                                Just sp ->
                                    Drag.rectsOverlap (cardRectAt fivePos) (cardRectAt sp)

                                Nothing ->
                                    False
                    in
                    if collided then
                        case ( targetStack, sixPos ) of
                            ( Just ts, Just sp ) ->
                                -- Split ts at cardIdx. Left
                                -- half stays at original origin;
                                -- right half becomes a NEW stack
                                -- at (sp.x, sp.y), then immediately
                                -- couples to the cursor.
                                let
                                    leftCards =
                                        List.take loc.cardIdx ts.cards

                                    rightCards =
                                        List.drop loc.cardIdx ts.cards

                                    leftStack =
                                        { ts | cards = leftCards }

                                    rightStack =
                                        { cards = rightCards
                                        , origin = sp
                                        }

                                    -- Replace target with left,
                                    -- append right at the end.
                                    splitStacks =
                                        updateAt loc.stackIdx (\_ -> leftStack) state.stacks
                                            ++ [ rightStack ]

                                    newCoupledIdx =
                                        List.length splitStacks - 1

                                    contact =
                                        { coupledStackIdx = newCoupledIdx
                                        , dx = sp.x - fivePos.x
                                        , dy = sp.y - fivePos.y
                                        }
                                in
                                ( { state
                                    | stacks = splitStacks
                                    , dragging = Just { d | kinematics = kAfterMove, contact = Just contact }
                                  }
                                , Cmd.none
                                , Pending
                                )

                            _ ->
                                ( { state | dragging = Just { d | kinematics = kAfterMove } }
                                , Cmd.none
                                , Pending
                                )

                    else
                        ( { state | dragging = Just { d | kinematics = kAfterMove } }
                        , Cmd.none
                        , Pending
                        )

                Nothing ->
                    -- No 6 on the board (already injected). Just
                    -- track motion; release will snap-back.
                    ( { state | dragging = Just { d | kinematics = kAfterMove } }
                    , Cmd.none
                    , Pending
                    )


handleFiveUp : Drag.MousePos -> DragState -> State -> ( State, Cmd Msg, GestureOutcome )
handleFiveUp pos d state =
    case d.contact of
        Just contact ->
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
                        , targetStackIdx = contact.coupledStackIdx
                        , card = fiveCard
                        }
              }
            , Cmd.none
            , Pending
            )

        Nothing ->
            handleHandRelocate d state



-- THE 8: APPROACH (collision with 7 → instant snap)


handleEightMove : Drag.MousePos -> DragState -> State -> ( State, Cmd Msg, GestureOutcome )
handleEightMove pos d state =
    let
        kAfterMove =
            Drag.advanceMouseSample pos state.nowMillis d.kinematics

        eightPos =
            fivePosFromMouse d pos

        draggedRect =
            cardRectAt eightPos

        projected =
            Drag.projectedRect draggedRect kAfterMove.vx kAfterMove.vy lookaheadMs

        locked =
            case findCardLocation (\c -> c.value == 7) state.stacks of
                Just loc ->
                    case getAt loc.stackIdx state.stacks of
                        Just ts ->
                            Drag.isLockedWithHysteresis
                                d.kinematics.wasLocked
                                Drag.lockThresholdRatio
                                unlockRatio
                                projected
                                (landingPlaceForEight ts)

                        Nothing ->
                            False

                Nothing ->
                    False

        kFinal =
            Drag.commitLockState locked kAfterMove
    in
    -- During the drag we only track lock state. The meld
    -- itself fires on release (handleEightUp), so the player
    -- gets a frame or two of ghost preview before committing.
    ( { state | dragging = Just { d | kinematics = kFinal } }
    , Cmd.none
    , Pending
    )


handleEightUp : DragState -> State -> ( State, Cmd Msg, GestureOutcome )
handleEightUp d state =
    if d.kinematics.wasLocked then
        case findCardLocation (\c -> c.value == 7) state.stacks of
            Just loc ->
                let
                    eightPos =
                        { x = d.kinematics.mouseX - d.offsetX - containerOriginX
                        , y = d.kinematics.mouseY - d.offsetY - containerOriginY
                        }
                in
                ( { state
                    | dragging = Nothing
                    , released =
                        Just
                            { atX = eightPos.x
                            , atY = eightPos.y
                            , snapAt = state.nowMillis + snapPauseMs
                            , targetStackIdx = loc.stackIdx
                            , card = eightCard
                            }
                  }
                , Cmd.none
                , Pending
                )

            Nothing ->
                handleHandRelocate d state

    else
        handleHandRelocate d state



-- STACK MOVE: rigid-unit drag


handleStackMove : Drag.MousePos -> DragState -> { stackIdx : Int, originAtStart : { x : Int, y : Int } } -> State -> ( State, Cmd Msg, GestureOutcome )
handleStackMove pos d sk state =
    let
        kAfterMove =
            Drag.advanceMouseSample pos state.nowMillis d.kinematics

        newOriginX =
            (pos.x - containerOriginX) - d.offsetX

        newOriginY =
            (pos.y - containerOriginY) - d.offsetY

        newStacks =
            updateAt sk.stackIdx
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


handleStackUp : DragState -> { stackIdx : Int, originAtStart : { x : Int, y : Int } } -> State -> ( State, Cmd Msg, GestureOutcome )
handleStackUp d sk state =
    let
        durMs =
            max 0 (state.nowMillis - d.kinematics.startedAtMs)

        draggedStack =
            getAt sk.stackIdx state.stacks

        wouldCover =
            case draggedStack of
                Just s ->
                    overlapsAnyStack (stackRect s) [ sk.stackIdx ] state.stacks

                Nothing ->
                    False

        baseExtra =
            [ ( "stackIdx", E.int sk.stackIdx )
            , ( "fromX", E.int sk.originAtStart.x )
            , ( "fromY", E.int sk.originAtStart.y )
            ]
                ++ Drag.kinematicsLogFields d.kinematics
    in
    if wouldCover then
        -- Baseline physics: dropping onto another stack is
        -- rejected. Restore the dragged stack to its origin.
        let
            restoredStacks =
                updateAt sk.stackIdx
                    (\s -> { s | origin = sk.originAtStart })
                    state.stacks
        in
        ( { state | dragging = Nothing, stacks = restoredStacks }
        , Cmd.none
        , Completed
            { ok = False
            , durationMs = durMs
            , move = MoveSnapBack
            , extra = baseExtra
            }
        )

    else
        ( { state | dragging = Nothing }
        , Cmd.none
        , Completed
            { ok = True
            , durationMs = durMs
            , move = MoveStackRelocated
            , extra = baseExtra
            }
        )



-- HAND RELOCATE
--
-- Base physics: a hand card released without colliding with its
-- meld target lands wherever the player dropped it. The card is
-- still in hand (not melded), it just lives at a new position.


handleHandRelocate : DragState -> State -> ( State, Cmd Msg, GestureOutcome )
handleHandRelocate d state =
    let
        durMs =
            max 0 (state.nowMillis - d.kinematics.startedAtMs)

        newPos =
            -- Hand cards live inside playSurface, so origin is in
            -- container-local coordinates.
            { x = d.kinematics.mouseX - d.offsetX - containerOriginX
            , y = d.kinematics.mouseY - d.offsetY - containerOriginY
            }

        wouldCover =
            overlapsAnyStack (cardRectAt newPos) [] state.stacks
    in
    case d.kind of
        HandKind hk ->
            if wouldCover then
                -- Baseline physics: dropping onto a stack is
                -- rejected. The card returns to its prior origin.
                ( { state | dragging = Nothing }
                , Cmd.none
                , Completed
                    { ok = False
                    , durationMs = durMs
                    , move = MoveSnapBack
                    , extra = Drag.kinematicsLogFields d.kinematics
                    }
                )

            else
                let
                    newHand =
                        List.map
                            (\hc ->
                                if hc.card == hk.card then
                                    { hc | origin = newPos }

                                else
                                    hc
                            )
                            state.hand
                in
                ( { state | dragging = Nothing, hand = newHand }
                , Cmd.none
                , Completed
                    { ok = True
                    , durationMs = durMs
                    , move = MoveHandRelocated
                    , extra = Drag.kinematicsLogFields d.kinematics
                    }
                )

        StackKind _ ->
            ( { state | dragging = Nothing }
            , Cmd.none
            , Completed
                { ok = False
                , durationMs = durMs
                , move = MoveSnapBack
                , extra = Drag.kinematicsLogFields d.kinematics
                }
            )

        LiftedCardKind _ ->
            -- Shouldn't reach here (lifted cards have their own
            -- release path), but cover the case for the compiler.
            ( { state | dragging = Nothing }
            , Cmd.none
            , Completed
                { ok = False
                , durationMs = durMs
                , move = MoveSnapBack
                , extra = Drag.kinematicsLogFields d.kinematics
                }
            )



-- LONG-PRESS: extract a card from the middle of a stack
--
-- Layer-2 miracle: cards stick together by default. Long-press
-- is the override signal that says "lift this one card out."


handleAwaitingMove : Drag.MousePos -> AwaitingPress -> State -> ( State, Cmd Msg, GestureOutcome )
handleAwaitingMove pos ap state =
    let
        dx =
            pos.x - ap.downMouse.x

        dy =
            pos.y - ap.downMouse.y

        moved =
            abs dx > jitterPx || abs dy > jitterPx
    in
    if moved then
        -- Player moved before long-press fired. Convert into a
        -- standard stack drag and immediately apply this move.
        let
            mouseContainerX =
                ap.downMouse.x - containerOriginX

            mouseContainerY =
                ap.downMouse.y - containerOriginY

            d =
                { kind =
                    StackKind
                        { stackIdx = ap.stackIdx
                        , originAtStart = ap.stackOrigin
                        }
                , offsetX = mouseContainerX - ap.stackOrigin.x
                , offsetY = mouseContainerY - ap.stackOrigin.y
                , kinematics = Drag.initKinematics ap.downMouse ap.downAtMs
                , contact = Nothing
                }

            sk =
                { stackIdx = ap.stackIdx
                , originAtStart = ap.stackOrigin
                }
        in
        handleStackMove pos
            d
            sk
            { state | awaiting = Nothing, dragging = Just d }

    else
        ( state, Cmd.none, Pending )


activateLift : AwaitingPress -> State -> ( State, Cmd Msg, GestureOutcome )
activateLift ap state =
    let
        newStacks =
            extractCardFromStack ap.stackIdx ap.cardIdx state.stacks

        offsetX =
            ap.downMouse.x - ap.downCardXY.cardX

        offsetY =
            ap.downMouse.y - ap.downCardXY.cardY
    in
    ( { state
        | awaiting = Nothing
        , stacks = newStacks
        , dragging =
            Just
                { kind =
                    LiftedCardKind
                        { card = ap.card
                        , snapshotStacks = state.stacks
                        , liftedAtMs = state.nowMillis
                        }
                , offsetX = offsetX
                , offsetY = offsetY
                , kinematics = Drag.initKinematics ap.downMouse state.nowMillis
                , contact = Nothing
                }
      }
    , Cmd.none
    , Pending
    )


extractCardFromStack : Int -> Int -> List Stack -> List Stack
extractCardFromStack stackIdx cardIdx stacks =
    case getAt stackIdx stacks of
        Nothing ->
            stacks

        Just s ->
            let
                left =
                    List.take cardIdx s.cards

                right =
                    List.drop (cardIdx + 1) s.cards

                leftStack =
                    { cards = left, origin = s.origin }

                rightStack =
                    { cards = right
                    , origin =
                        { x = s.origin.x + (cardIdx + 1) * pitch
                        , y = s.origin.y
                        }
                    }

                removeStackAt i xs =
                    List.indexedMap Tuple.pair xs
                        |> List.filter (\( j, _ ) -> j /= i)
                        |> List.map Tuple.second
            in
            if List.isEmpty left && List.isEmpty right then
                removeStackAt stackIdx stacks

            else if List.isEmpty left then
                updateAt stackIdx (\_ -> rightStack) stacks

            else if List.isEmpty right then
                updateAt stackIdx (\_ -> leftStack) stacks

            else
                updateAt stackIdx (\_ -> leftStack) stacks ++ [ rightStack ]


handleLiftedMove : Drag.MousePos -> DragState -> State -> ( State, Cmd Msg, GestureOutcome )
handleLiftedMove pos d state =
    let
        kAfterMove =
            Drag.advanceMouseSample pos state.nowMillis d.kinematics
    in
    ( { state | dragging = Just { d | kinematics = kAfterMove } }
    , Cmd.none
    , Pending
    )


handleLiftedUp : DragState -> { card : Card, snapshotStacks : List Stack, liftedAtMs : Int } -> State -> ( State, Cmd Msg, GestureOutcome )
handleLiftedUp d lk state =
    let
        durMs =
            max 0 (state.nowMillis - d.kinematics.startedAtMs)

        dropPos =
            { x = d.kinematics.mouseX - d.offsetX - containerOriginX
            , y = d.kinematics.mouseY - d.offsetY - containerOriginY
            }

        dropRect =
            cardRectAt dropPos

        meldTarget =
            findSetMeldTarget dropRect lk.card state.stacks
    in
    case meldTarget of
        Just targetIdx ->
            -- Layer-2 miracle: the lifted card lands on a set
            -- of matching values. Side is determined by the
            -- drop's center vs the target stack's midline:
            -- left half → prepend (and shift origin left so
            -- existing cards stay put); right half → append.
            let
                target =
                    getAt targetIdx state.stacks
                        |> Maybe.withDefault
                            { cards = [], origin = { x = 0, y = 0 } }

                targetRect =
                    stackRect target

                dropCenterX =
                    dropPos.x + cw // 2

                targetCenterX =
                    targetRect.x + targetRect.w // 2

                onLeft =
                    dropCenterX < targetCenterX

                newStacks =
                    if onLeft then
                        updateAt targetIdx
                            (\s ->
                                { cards = lk.card :: s.cards
                                , origin = { x = s.origin.x - pitch, y = s.origin.y }
                                }
                            )
                            state.stacks

                    else
                        updateAt targetIdx
                            (\s -> { s | cards = s.cards ++ [ lk.card ] })
                            state.stacks
            in
            ( { state | dragging = Nothing, stacks = newStacks }
            , Cmd.none
            , Completed
                { ok = True
                , durationMs = durMs
                , move = MoveSetCompleted
                , extra =
                    Drag.kinematicsLogFields d.kinematics
                        ++ [ ( "side"
                             , E.string
                                (if onLeft then
                                    "L"

                                 else
                                    "R"
                                )
                             )
                           ]
                }
            )

        Nothing ->
            if overlapsAnyStack dropRect [] state.stacks then
                -- Layer-1 collision on a non-matching stack.
                -- Restore the pre-extraction snapshot. Trial
                -- continues — Steve hasn't earned cheese yet.
                ( { state | dragging = Nothing, stacks = lk.snapshotStacks }
                , Cmd.none
                , Pending
                )

            else
                -- Land as a new single-card stack at drop pos.
                -- Trial continues until set is completed.
                let
                    newStack =
                        { cards = [ lk.card ], origin = dropPos }
                in
                ( { state
                    | dragging = Nothing
                    , stacks = state.stacks ++ [ newStack ]
                  }
                , Cmd.none
                , Pending
                )


{-| Find a stack that the dropped card could meld with as a
"set" (all cards in the stack share the dropped card's value)
and whose meld zone the drop rect overlaps. The meld zone is
the set itself plus one card-width slot on either side, where
a prepended or appended card would land — gives the player a
generous landing target instead of pixel-precision over the
existing pair.
-}
findSetMeldTarget : Placement -> Card -> List Stack -> Maybe Int
findSetMeldTarget dropRect card stacks =
    List.indexedMap Tuple.pair stacks
        |> List.filter
            (\( _, s ) ->
                not (List.isEmpty s.cards)
                    && List.all (\c -> c.value == card.value) s.cards
                    && (Drag.rectsOverlap dropRect (stackRect s)
                            || Drag.rectsOverlap dropRect (leftMeldSlot s)
                            || Drag.rectsOverlap dropRect (rightMeldSlot s)
                       )
            )
        |> List.head
        |> Maybe.map Tuple.first


leftMeldSlot : Stack -> Placement
leftMeldSlot s =
    { x = s.origin.x - pitch
    , y = s.origin.y
    , w = cw
    , h = ch
    }


rightMeldSlot : Stack -> Placement
rightMeldSlot s =
    { x = s.origin.x + List.length s.cards * pitch
    , y = s.origin.y
    , w = cw
    , h = ch
    }



-- TICK: handle the 5's post-release snap


handleTick : Int -> State -> ( State, Cmd Msg, GestureOutcome )
handleTick ms state =
    let
        baseUpdated =
            { state | nowMillis = ms }
    in
    case state.awaiting of
        Just ap ->
            if ms - ap.downAtMs >= longPressMs then
                activateLift ap baseUpdated

            else
                ( baseUpdated, Cmd.none, Pending )

        Nothing ->
            handleTickReleased ms baseUpdated


handleTickReleased : Int -> State -> ( State, Cmd Msg, GestureOutcome )
handleTickReleased ms state =
    let
        baseUpdated =
            { state | nowMillis = ms }
    in
    case state.released of
        Just released ->
            if ms >= released.snapAt then
                let
                    snappedStacks =
                        case released.card.value of
                            5 ->
                                -- Prepend the 5 and shift origin
                                -- left by pitch so the new 5 sits
                                -- where the old leftmost (the 6) was.
                                updateAt released.targetStackIdx
                                    (\s ->
                                        { cards = released.card :: s.cards
                                        , origin = { x = s.origin.x - pitch, y = s.origin.y }
                                        }
                                    )
                                    state.stacks

                            _ ->
                                -- Append (the 8 lands at the right end).
                                updateAt released.targetStackIdx
                                    (\s -> { s | cards = s.cards ++ [ released.card ] })
                                    state.stacks

                    move =
                        if released.card.value == 5 then
                            MoveInjected

                        else
                            MoveExtended
                in
                ( { baseUpdated
                    | hand = List.filter (\hc -> hc.card /= released.card) state.hand
                    , stacks = snappedStacks
                    , released = Nothing
                  }
                , Cmd.none
                , Completed
                    { ok = True
                    , durationMs = max 0 (ms - released.snapAt) + snapPauseMs
                    , move = move
                    , extra = []
                    }
                )

            else
                ( baseUpdated, Cmd.none, Pending )

        Nothing ->
            ( baseUpdated, Cmd.none, Pending )



-- SUBSCRIPTIONS


subscriptions : State -> Sub Msg
subscriptions state =
    let
        clock =
            Browser.Events.onAnimationFrame
                (\posix -> Tick (Time.posixToMillis posix))
    in
    case ( state.dragging, state.awaiting ) of
        ( Nothing, Nothing ) ->
            clock

        _ ->
            Sub.batch
                [ Browser.Events.onMouseMove (D.map MouseMoved Drag.mouseDecoder)
                , Browser.Events.onMouseUp (D.map MouseUp Drag.mouseDecoder)
                , clock
                ]



-- VIEW


view : State -> Html Msg
view state =
    let
        dragOverlay =
            case state.dragging of
                Just d ->
                    case d.kind of
                        HandKind { card } ->
                            Style.draggedCardOverlay
                                { atViewport = ( d.kinematics.mouseX - d.offsetX, d.kinematics.mouseY - d.offsetY )
                                , card = card
                                }

                        StackKind _ ->
                            -- Stack drags don't render an overlay;
                            -- the stack itself moves in place.
                            Html.text ""

                        LiftedCardKind { card } ->
                            Style.draggedCardOverlay
                                { atViewport =
                                    ( d.kinematics.mouseX - d.offsetX
                                    , d.kinematics.mouseY - d.offsetY
                                    )
                                , card = card
                                }

                Nothing ->
                    case state.released of
                        Just released ->
                            Style.draggedCardOverlay
                                { atViewport =
                                    ( released.atX + containerOriginX
                                    , released.atY + containerOriginY
                                    )
                                , card = released.card
                                }

                        Nothing ->
                            Html.text ""
    in
    Html.div []
        [ Style.playSurface
            (List.indexedMap viewStack state.stacks
                ++ List.map (viewHandCard (state.dragging /= Nothing)) state.hand
                ++ [ viewLandingGhost state, viewDwellFeedback state ]
            )
        , dragOverlay
        ]


{-| Placeholder while we pick a non-on-card dwell-feedback
mechanism (per UI_DESIGN.md "A held card never moves on its
own"). Both prior mechanisms (hop, fill) were vetoed.
-}
viewDwellFeedback : State -> Html Msg
viewDwellFeedback _ =
    Html.text ""


{-| Backchannel: when the dragged 8 is in the snap zone over a 7,
render a faint preview of where the 8 would land if released. Tells
the player "release here → commit," which is the universal
imminent-commit signal the channel needs.
-}
viewLandingGhost : State -> Html Msg
viewLandingGhost state =
    case state.dragging of
        Just d ->
            case d.kind of
                HandKind { card } ->
                    if card.value == 8 then
                        eightLandingGhost d state card

                    else
                        Html.text ""

                StackKind _ ->
                    Html.text ""

                LiftedCardKind _ ->
                    Html.text ""

        Nothing ->
            Html.text ""


eightLandingGhost : DragState -> State -> Card -> Html Msg
eightLandingGhost d state card =
    case findCardLocation (\c -> c.value == 7) state.stacks of
        Just loc ->
            case getAt loc.stackIdx state.stacks of
                Just ts ->
                    let
                        eightPos =
                            fivePosFromMouse d
                                { x = d.kinematics.mouseX, y = d.kinematics.mouseY }

                        projected =
                            Drag.projectedRect
                                (cardRectAt eightPos)
                                d.kinematics.vx
                                d.kinematics.vy
                                lookaheadMs

                        landingPlace =
                            landingPlaceForEight ts

                        locked =
                            Drag.isLockedWithHysteresis
                                d.kinematics.wasLocked
                                Drag.lockThresholdRatio
                                unlockRatio
                                projected
                                landingPlace
                    in
                    if locked then
                        Style.cardGhost
                            { at = landingPlace
                            , opacity = 0.55
                            , card = card
                            }

                    else
                        Html.text ""

                Nothing ->
                    Html.text ""

        Nothing ->
            Html.text ""


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
               , Html.Events.on "mousedown" (stackCardDownDecoder stackIdx cardIdx card stackOrigin)
               ]
        )
        [ Style.cardCanvas card ]


viewHandCard : Bool -> HandCard -> Html Msg
viewHandCard isDragging hc =
    Html.div
        (Style.posAbsolute hc.origin.x hc.origin.y
            ++ [ HA.style "cursor" "grab"
               , HA.style "opacity"
                    (if isDragging then
                        "0.35"

                     else
                        "1"
                    )
               , Html.Events.on "mousedown" (handDownDecoder hc)
               ]
        )
        [ Style.cardCanvas hc.card ]


handDownDecoder : HandCard -> D.Decoder Msg
handDownDecoder hc =
    D.map3
        (\mx my ( ox, oy ) ->
            HandMouseDown hc
                { x = mx, y = my }
                { cardX = mx - ox, cardY = my - oy }
        )
        (D.field "clientX" D.int)
        (D.field "clientY" D.int)
        (D.map2 Tuple.pair (D.field "offsetX" D.int) (D.field "offsetY" D.int))


stackCardDownDecoder : Int -> Int -> Card -> { x : Int, y : Int } -> D.Decoder Msg
stackCardDownDecoder stackIdx cardIdx card stackOrigin =
    D.map3
        (\mx my ( ox, oy ) ->
            StackCardMouseDown
                { stackIdx = stackIdx
                , cardIdx = cardIdx
                , card = card
                , stackOrigin = stackOrigin
                }
                { x = mx, y = my }
                { cardX = mx - ox, cardY = my - oy }
        )
        (D.field "clientX" D.int)
        (D.field "clientY" D.int)
        (D.map2 Tuple.pair (D.field "offsetX" D.int) (D.field "offsetY" D.int))
