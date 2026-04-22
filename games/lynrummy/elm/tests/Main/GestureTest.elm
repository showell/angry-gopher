module Main.GestureTest exposing (suite)

{-| Tests for `Main.Gesture.resolveGesture`. The pure function
that decides which `WireAction` (if any) a completed drag
should emit — given the DragInfo at mouseup and the current
Model.

These are the "step 4" tests from the wing-hit walkthrough
(`users/steve/general/wing_hit_walkthrough.md`). They do NOT
cover the DOM-delegated hit-test that sets `hoveredWing` in
the first place — that's the part we can't reach without a
real browser. These tests assume `hoveredWing` has its value
and check that the action the resolver produces is the right
shape.

Added 2026-04-22 in response to the silent-merge-failure bug.

-}

import Expect
import Game.BoardActions exposing (Side(..))
import Game.Card exposing (OriginDeck(..))
import Game.CardStack as CardStack exposing (BoardLocation, CardStack, HandCard, HandCardState(..))
import Game.Dealer
import Game.Hand as Hand
import Game.Score as Score
import Game.WireAction as WA
import Main.Gesture as Gesture
import Main.State as State
    exposing
        ( DragInfo
        , DragSource(..)
        , DragState(..)
        , Model
        , PathFrame(..)
        )
import Test exposing (Test, describe, test)



-- HELPERS


at : Int -> Int -> BoardLocation
at left top =
    { left = left, top = top }


stackAt : String -> BoardLocation -> CardStack
stackAt shorthand loc =
    case CardStack.fromShorthand shorthand DeckOne loc of
        Just s ->
            s

        Nothing ->
            Debug.todo ("bad shorthand in test: " ++ shorthand)


boardRect : { x : Int, y : Int, width : Int, height : Int }
boardRect =
    { x = 300, y = 100, width = 800, height = 600 }


{-| A Model with a two-stack board and an active hand for hand-
origin tests. The board's viewport rect lives on `DragInfo`,
not the Model itself — `dropLoc` computes from there.
-}
modelWith : List CardStack -> List HandCard -> Model
modelWith board hand =
    let
        base =
            State.baseModel
    in
    State.setActiveHand { handCards = hand }
        { base | board = board }


{-| Construct a DragInfo that's "ready to release" — cursor
placed at a board-frame spot (converted to viewport via the
standard rect offset), boardRect set, no surviving clickIntent.
Caller supplies source + hoveredWing + any extras.
-}
dragInfo :
    { source : DragSource
    , hoveredWing : Maybe { stackIndex : Int, side : Side }
    , cursorBoard : { x : Int, y : Int }
    }
    -> DragInfo
dragInfo { source, hoveredWing, cursorBoard } =
    let
        viewportCursor =
            { x = cursorBoard.x + boardRect.x
            , y = cursorBoard.y + boardRect.y
            }
    in
    { source = source
    , cursor = viewportCursor
    , originalCursor = viewportCursor
    , grabOffset = { x = 0, y = 0 }
    , wings = []
    , hoveredWing = hoveredWing
    , boardRect = Just boardRect
    , clickIntent = Nothing
    , gesturePath = []
    , pathFrame = ViewportFrame
    }



-- SPLIT


suiteSplit : Test
suiteSplit =
    describe "resolveGesture — click intent produces Split"
        [ test "board-stack source with surviving clickIntent yields Split" <|
            \_ ->
                let
                    stack =
                        stackAt "2C,3D,4C,5H,6S,7H" (at 20 20)

                    model =
                        modelWith [ stack ] []

                    info =
                        dragInfo
                            { source = FromBoardStack 0
                            , hoveredWing = Nothing
                            , cursorBoard = { x = 25, y = 25 }
                            }
                            |> (\i -> { i | clickIntent = Just 3 })
                in
                Gesture.resolveGesture info model
                    |> Expect.equal (Just (WA.Split { stack = stack, cardIndex = 3 }))
        ]



-- MERGE STACK


suiteMergeStack : Test
suiteMergeStack =
    describe "resolveGesture — board-stack + hoveredWing yields MergeStack"
        [ test "234 + 567 right-wing merge (Steve's repro scenario)" <|
            \_ ->
                let
                    source234 =
                        stackAt "2C,3D,4C" (at 100 200)

                    target567 =
                        stackAt "5H,6S,7H" (at 300 200)

                    model =
                        modelWith [ source234, target567 ] []

                    info =
                        dragInfo
                            { source = FromBoardStack 0
                            , hoveredWing = Just { stackIndex = 1, side = Left }
                            , cursorBoard = { x = 290, y = 220 }
                            }
                in
                Gesture.resolveGesture info model
                    |> Expect.equal
                        (Just
                            (WA.MergeStack
                                { source = source234
                                , target = target567
                                , side = Left
                                }
                            )
                        )
        , test "dropping 567 onto 234's right wing produces MergeStack" <|
            \_ ->
                let
                    target234 =
                        stackAt "2C,3D,4C" (at 100 200)

                    source567 =
                        stackAt "5H,6S,7H" (at 300 200)

                    model =
                        modelWith [ target234, source567 ] []

                    info =
                        dragInfo
                            { source = FromBoardStack 1
                            , hoveredWing = Just { stackIndex = 0, side = Right }
                            , cursorBoard = { x = 200, y = 220 }
                            }
                in
                Gesture.resolveGesture info model
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
        [ test "hand-card drop onto a board stack's wing yields MergeHand" <|
            \_ ->
                let
                    target =
                        stackAt "3C,4D,5C" (at 100 200)

                    card6H =
                        { value = Game.Card.Six, suit = Game.Card.Heart, originDeck = DeckOne }

                    handCard =
                        { card = card6H, state = HandNormal }

                    model =
                        modelWith [ target ] [ handCard ]

                    info =
                        dragInfo
                            { source = FromHandCard 0
                            , hoveredWing = Just { stackIndex = 0, side = Right }
                            , cursorBoard = { x = 200, y = 220 }
                            }
                in
                Gesture.resolveGesture info model
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



-- MOVE STACK


suiteMoveStack : Test
suiteMoveStack =
    describe "resolveGesture — no hoveredWing, cursor over board → MoveStack"
        [ test "drops produce MoveStack with board-frame new_loc" <|
            \_ ->
                let
                    stack =
                        stackAt "2C,3D,4C" (at 100 200)

                    model =
                        modelWith [ stack ] []

                    info =
                        dragInfo
                            { source = FromBoardStack 0
                            , hoveredWing = Nothing
                            , cursorBoard = { x = 400, y = 300 }
                            }
                in
                case Gesture.resolveGesture info model of
                    Just (WA.MoveStack p) ->
                        Expect.all
                            [ \_ -> p.stack |> Expect.equal stack
                            , \_ -> p.newLoc.left |> Expect.equal 400
                            , \_ -> p.newLoc.top |> Expect.equal 300
                            ]
                            ()

                    other ->
                        Expect.fail ("expected MoveStack; got " ++ Debug.toString other)
        , test "off-board drops (negative loc) are rejected" <|
            \_ ->
                let
                    stack =
                        stackAt "2C,3D,4C" (at 100 200)

                    model =
                        modelWith [ stack ] []

                    -- cursorBoard = (0, 0) means loc = (0, 0) with grabOffset=0,
                    -- which fits — so push it NEGATIVE by using a grab offset.
                    info =
                        dragInfo
                            { source = FromBoardStack 0
                            , hoveredWing = Nothing
                            , cursorBoard = { x = 5, y = 5 }
                            }
                            |> (\i -> { i | grabOffset = { x = 10, y = 10 } })
                in
                Gesture.resolveGesture info model
                    |> Expect.equal Nothing
        ]



-- PLACE HAND


suitePlaceHand : Test
suitePlaceHand =
    describe "resolveGesture — hand-source, no wing, cursor over board → PlaceHand"
        [ test "drops produce PlaceHand with board-frame loc" <|
            \_ ->
                let
                    card6H =
                        { value = Game.Card.Six, suit = Game.Card.Heart, originDeck = DeckOne }

                    handCard =
                        { card = card6H, state = HandNormal }

                    model =
                        modelWith [] [ handCard ]

                    info =
                        dragInfo
                            { source = FromHandCard 0
                            , hoveredWing = Nothing
                            , cursorBoard = { x = 450, y = 350 }
                            }
                in
                case Gesture.resolveGesture info model of
                    Just (WA.PlaceHand p) ->
                        Expect.all
                            [ \_ -> p.handCard |> Expect.equal card6H
                            , \_ -> p.loc.left |> Expect.equal 450
                            , \_ -> p.loc.top |> Expect.equal 350
                            ]
                            ()

                    other ->
                        Expect.fail ("expected PlaceHand; got " ++ Debug.toString other)
        ]



-- MAIN SUITE


suite : Test
suite =
    describe "Main.Gesture.resolveGesture"
        [ suiteSplit
        , suiteMergeStack
        , suiteMergeHand
        , suiteMoveStack
        , suitePlaceHand
        ]
