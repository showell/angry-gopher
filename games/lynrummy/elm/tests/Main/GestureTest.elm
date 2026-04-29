module Main.GestureTest exposing (suite)

{-| Tests for `Main.Gesture.resolveGesture` and
`Main.Gesture.floaterOverWing`.

These tests exercise the PURE decision layer of a drag —
given a DragInfo + DragContext + ClickArbiter at mouseup (or
mid-move), which WireAction should we emit, and which wing
(if any) is the floater near? No DOM, no Msg loop.

Updated 2026-04-24 to use `tests/Fixtures.elm` — a neutral
`DragBundle` plus small builders — so tests care only about
the fields that differ from the default. See
`drag_test_strategy.md` in claude-steve for the rationale.

Updated 2026-04-29: DragInfo split into DragInfo + DragContext
+ ClickArbiter. Tests destructure the DragBundle returned by
Fixtures builders and pass components to Gesture functions.
hoveredWing is now computed from geometry (floaterOverWing)
rather than cached; merge tests use withWings + correct floater
positions to drive the computation.

-}

import Expect
import Fixtures
    exposing
        ( at
        , boardStackDragAt
        , defaultBoardRect
        , handCardDragAt
        , stackAt
        , withWings
        )
import Game.BoardActions exposing (Side(..))
import Game.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Game.CardStack as CardStack
import Game.WireAction as WA
import Main.Gesture as Gesture
import Test exposing (Test, describe, test)



-- MODEL HELPER (only thing non-fixture needs)
-- SPLIT


suiteSplit : Test
suiteSplit =
    describe "resolveGesture — click intent produces Split"
        [ test "board-stack source with surviving clickIntent yields Split" <|
            \_ ->
                let
                    stack =
                        stackAt "2C,3D,4C,5H,6S,7H" (at 20 20)

                    bundle =
                        boardStackDragAt stack { x = 20, y = 20 }

                    arb =
                        let
                            a =
                                bundle.arb
                        in
                        { a | clickIntent = Just 3 }
                in
                Gesture.resolveGesture bundle.info bundle.ctx arb
                    |> Expect.equal (Just (WA.Split { stack = stack, cardIndex = 3 }))
        ]



-- MERGE STACK


suiteMergeStack : Test
suiteMergeStack =
    describe "resolveGesture — board-stack + hoveredWing yields MergeStack"
        [ test "234 onto 567's left wing" <|
            \_ ->
                let
                    source234 =
                        stackAt "2C,3D,4C" (at 100 200)

                    target567 =
                        stackAt "5H,6S,7H" (at 300 200)

                    wing =
                        { target = target567, side = Left }

                    -- Floater near left-wing eventual landing:
                    -- target.left - source.width = 300 - 99 = 201
                    -- 207 is within the half-pitch (16px) tolerance.
                    bundle =
                        boardStackDragAt source234 { x = 207, y = 200 }
                            |> withWings [ wing ]
                in
                Gesture.resolveGesture bundle.info bundle.ctx bundle.arb
                    |> Expect.equal
                        (Just
                            (WA.MergeStack
                                { source = source234
                                , target = target567
                                , side = Left
                                }
                            )
                        )
        , test "567 onto 234's right wing" <|
            \_ ->
                let
                    target234 =
                        stackAt "2C,3D,4C" (at 100 200)

                    source567 =
                        stackAt "5H,6S,7H" (at 300 200)

                    wing =
                        { target = target234, side = Right }

                    -- Floater near right-wing eventual landing:
                    -- target.left + target.width = 100 + 99 = 199
                    -- 193 is within the half-pitch (16px) tolerance.
                    bundle =
                        boardStackDragAt source567 { x = 193, y = 200 }
                            |> withWings [ wing ]
                in
                Gesture.resolveGesture bundle.info bundle.ctx bundle.arb
                    |> Expect.equal
                        (Just
                            (WA.MergeStack
                                { source = source567
                                , target = target234
                                , side = Right
                                }
                            )
                        )
        ]



-- MERGE HAND


suiteMergeHand : Test
suiteMergeHand =
    describe "resolveGesture — hand-source + hoveredWing yields MergeHand"
        [ test "hand-card drop onto a board stack's wing" <|
            \_ ->
                let
                    target =
                        stackAt "3C,4D,5C" (at 100 200)

                    card6H : Card
                    card6H =
                        { value = Six, suit = Heart, originDeck = DeckOne }

                    wing =
                        { target = target, side = Right }

                    -- Right-wing eventual board-frame landing:
                    --   target.left + target.width = 100 + 99 = 199
                    -- In viewport frame (boardRect.x = 300, boardRect.y = 100):
                    --   (199 + 300, 200 + 100) = (499, 300)
                    -- Place floater at that viewport position — within tolerance.
                    bundle =
                        handCardDragAt card6H { x = 499, y = 300 }
                            |> withWings [ wing ]
                in
                Gesture.resolveGesture bundle.info bundle.ctx bundle.arb
                    |> Expect.equal
                        (Just
                            (WA.MergeHand
                                { handCard = card6H
                                , target = target
                                , side = Right
                                }
                            )
                        )
        ]



-- MOVE STACK + off-board rejection


suiteMoveStack : Test
suiteMoveStack =
    describe "resolveGesture — no hoveredWing, cursor over board → MoveStack"
        [ test "valid drop produces MoveStack with board-frame new_loc" <|
            \_ ->
                let
                    stack =
                        stackAt "2C,3D,4C" (at 100 200)

                    bundle =
                        boardStackDragAt stack { x = 400, y = 300 }

                    -- resolveGesture needs isCursorOverBoard = True,
                    -- which requires cursor to be inside boardRect.
                    info =
                        let
                            i =
                                bundle.info
                        in
                        { i | cursor = { x = 700, y = 400 } }

                    ctx =
                        let
                            c =
                                bundle.ctx
                        in
                        { c | boardRect = Just defaultBoardRect }
                in
                case Gesture.resolveGesture info ctx bundle.arb of
                    Just (WA.MoveStack p) ->
                        Expect.all
                            [ \_ -> Expect.equal stack p.stack
                            , \_ -> Expect.equal 400 p.newLoc.left
                            , \_ -> Expect.equal 300 p.newLoc.top
                            ]
                            ()

                    other ->
                        Expect.fail ("expected MoveStack; got " ++ Debug.toString other)
        , test "off-board drop (negative loc) is rejected" <|
            \_ ->
                let
                    stack =
                        stackAt "2C,3D,4C" (at 100 200)

                    -- Floater at negative board-frame coords. The
                    -- drop gets rejected via isDropFootprintInBounds.
                    bundle =
                        boardStackDragAt stack { x = -50, y = -20 }

                    info =
                        let
                            i =
                                bundle.info
                        in
                        { i | cursor = { x = 700, y = 400 } }

                    ctx =
                        let
                            c =
                                bundle.ctx
                        in
                        { c | boardRect = Just defaultBoardRect }
                in
                Gesture.resolveGesture info ctx bundle.arb
                    |> Expect.equal Nothing
        ]



-- PLACE HAND


suitePlaceHand : Test
suitePlaceHand =
    describe "resolveGesture — hand-source, no wing, cursor over board → PlaceHand"
        [ test "drops produce PlaceHand with board-frame loc" <|
            \_ ->
                let
                    card6H : Card
                    card6H =
                        { value = Six, suit = Heart, originDeck = DeckOne }

                    -- Floater at viewport (300+450, 100+350) = (750, 450),
                    -- which translates to board-frame (450, 350) via
                    -- boardRect subtraction in dropLoc.
                    bundle =
                        handCardDragAt card6H { x = 750, y = 450 }

                    info =
                        let
                            i =
                                bundle.info
                        in
                        { i | cursor = { x = 750, y = 450 } }
                in
                case Gesture.resolveGesture info bundle.ctx bundle.arb of
                    Just (WA.PlaceHand p) ->
                        Expect.all
                            [ \_ -> Expect.equal card6H p.handCard
                            , \_ -> Expect.equal 450 p.loc.left
                            , \_ -> Expect.equal 350 p.loc.top
                            ]
                            ()

                    other ->
                        Expect.fail ("expected PlaceHand; got " ++ Debug.toString other)
        ]



-- FLOATER OVER WING


suiteFloaterOverWing : Test
suiteFloaterOverWing =
    describe "floaterOverWing — tolerance around eventual landing"
        [ test "floater exactly on right-wing landing fires" <|
            \_ ->
                let
                    source =
                        stackAt "2C,3D,4C" (at 20 20)

                    target =
                        stackAt "5H,6S,7H" (at 300 20)

                    wing =
                        { target = target, side = Right }

                    -- Eventual landing for right-wing: target's
                    -- right edge, target's top.
                    landing =
                        { x = target.loc.left + CardStack.stackDisplayWidth target
                        , y = target.loc.top
                        }

                    bundle =
                        boardStackDragAt source landing
                            |> withWings [ wing ]
                in
                Gesture.floaterOverWing bundle.ctx bundle.info
                    |> Expect.equal (Just wing)
        , test "floater on left-wing landing fires" <|
            \_ ->
                let
                    source =
                        stackAt "2C,3D,4C" (at 20 20)

                    target =
                        stackAt "5H,6S,7H" (at 300 20)

                    wing =
                        { target = target, side = Left }

                    -- Eventual landing for left-wing: target.left −
                    -- source.width, target.top.
                    landing =
                        { x = target.loc.left - CardStack.stackDisplayWidth source
                        , y = target.loc.top
                        }

                    bundle =
                        boardStackDragAt source landing
                            |> withWings [ wing ]
                in
                Gesture.floaterOverWing bundle.ctx bundle.info
                    |> Expect.equal (Just wing)
        , test "floater past tolerance does NOT fire" <|
            \_ ->
                let
                    source =
                        stackAt "2C,3D,4C" (at 20 20)

                    target =
                        stackAt "5H,6S,7H" (at 300 20)

                    wing =
                        { target = target, side = Right }

                    -- Landing is (target.right, target.top); put
                    -- the floater past one pitch from landing —
                    -- definitely outside the half-pitch tolerance.
                    landing =
                        { x = target.loc.left + CardStack.stackDisplayWidth target
                        , y = target.loc.top
                        }

                    farFloater =
                        { x = landing.x + CardStack.stackPitch + 5
                        , y = landing.y
                        }

                    bundle =
                        boardStackDragAt source farFloater
                            |> withWings [ wing ]
                in
                Gesture.floaterOverWing bundle.ctx bundle.info
                    |> Expect.equal Nothing
        , test "floater way off returns Nothing" <|
            \_ ->
                let
                    source =
                        stackAt "2C,3D,4C" (at 20 20)

                    target =
                        stackAt "5H,6S,7H" (at 300 20)

                    wing =
                        { target = target, side = Right }

                    bundle =
                        boardStackDragAt source { x = 50, y = 400 }
                            |> withWings [ wing ]
                in
                Gesture.floaterOverWing bundle.ctx bundle.info
                    |> Expect.equal Nothing
        ]



-- MAIN SUITE


suite : Test
suite =
    describe "Main.Gesture"
        [ suiteSplit
        , suiteMergeStack
        , suiteMergeHand
        , suiteMoveStack
        , suitePlaceHand
        , suiteFloaterOverWing
        ]
