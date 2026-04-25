module Main.DragInvariantTest exposing (suite)

{-| Tests for the invariants of the drag-capture layer:

  - `floaterTopLeft` shifts by exactly the cursor delta on
    any mousemove, regardless of where on the card the user
    grabbed. This is the invariant that lets us get rid of
    `grabOffset` entirely from the update path.
  - mousedown sets the correct `pathFrame` for each drag type
    (BoardFrame for intra-board, ViewportFrame for hand-origin).

If a future refactor accidentally reintroduces grabOffset
math into mousemove, or flips pathFrame semantics, these
tests fail loudly.

-}

import Expect
import Fixtures exposing (at, stackAt)
import Game.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Game.CardStack as CardStack exposing (CardStack, HandCard, HandCardState(..))
import Main.Gesture as Gesture
import Main.Play as Play
import Main.State as State exposing (DragSource(..), PathFrame(..))
import Test exposing (Test, describe, test)



-- CAPTURE INVARIANT


suiteCaptureInvariant : Test
suiteCaptureInvariant =
    describe "floaterTopLeft shifts by cursor delta, grab point irrelevant"
        [ test "mousedown-to-mousemove shifts floater by exactly the delta" <|
            \_ ->
                let
                    stack =
                        stackAt "2C,3D,4C" (at 100 200)

                    -- Grab somewhere OFF-center: user clicked card
                    -- index 2 (rightmost) of a 3-card stack. The
                    -- grab point doesn't matter for the invariant;
                    -- we just need to pick one.
                    mousedownClient =
                        { x = 540, y = 310 }

                    ( afterDown, _ ) =
                        Gesture.startBoardCardDrag
                            { stack = stack, cardIndex = 2 }
                            mousedownClient
                            0
                            (modelWithStack stack)

                    mousemoveClient =
                        { x = 560, y = 305 }

                    delta =
                        { x = mousemoveClient.x - mousedownClient.x
                        , y = mousemoveClient.y - mousedownClient.y
                        }

                    ( afterMove, _ ) =
                        Play.mouseMove mousemoveClient 100 afterDown
                in
                case ( afterDown.drag, afterMove.drag ) of
                    ( State.Dragging before, State.Dragging after ) ->
                        Expect.equal
                            { x = before.floaterTopLeft.x + delta.x
                            , y = before.floaterTopLeft.y + delta.y
                            }
                            after.floaterTopLeft

                    _ ->
                        Expect.fail "expected both states to be Dragging"
        , test "grab point doesn't matter: two different grabs, same delta, same shift" <|
            \_ ->
                let
                    stack =
                        stackAt "2C,3D,4C" (at 100 200)

                    delta =
                        { x = 15, y = 8 }

                    -- Two distinct mousedown points on the same stack.
                    downA =
                        { x = 410, y = 310 }

                    downB =
                        { x = 500, y = 320 }

                    shiftFor down =
                        let
                            ( afterDown, _ ) =
                                Gesture.startBoardCardDrag
                                    { stack = stack, cardIndex = 0 }
                                    down
                                    0
                                    (modelWithStack stack)

                            ( afterMove, _ ) =
                                Play.mouseMove
                                    { x = down.x + delta.x
                                    , y = down.y + delta.y
                                    }
                                    100
                                    afterDown
                        in
                        case ( afterDown.drag, afterMove.drag ) of
                            ( State.Dragging before, State.Dragging after ) ->
                                Just
                                    { x = after.floaterTopLeft.x - before.floaterTopLeft.x
                                    , y = after.floaterTopLeft.y - before.floaterTopLeft.y
                                    }

                            _ ->
                                Nothing
                in
                Expect.equal (shiftFor downA) (shiftFor downB)
        ]



-- PATHFRAME CORRECTNESS


suitePathFrame : Test
suitePathFrame =
    describe "mousedown sets correct pathFrame per drag type"
        [ test "intra-board drag: pathFrame = BoardFrame" <|
            \_ ->
                let
                    stack =
                        stackAt "2C,3D,4C" (at 100 200)

                    ( afterDown, _ ) =
                        Gesture.startBoardCardDrag
                            { stack = stack, cardIndex = 0 }
                            { x = 410, y = 310 }
                            0
                            (modelWithStack stack)
                in
                case afterDown.drag of
                    State.Dragging info ->
                        Expect.equal BoardFrame info.pathFrame

                    _ ->
                        Expect.fail "expected Dragging state"
        , test "hand-origin drag: pathFrame = ViewportFrame" <|
            \_ ->
                let
                    card6H : Card
                    card6H =
                        { value = Six, suit = Heart, originDeck = DeckOne }

                    handCard =
                        { card = card6H, state = HandNormal }

                    ( afterDown, _ ) =
                        Gesture.startHandDrag
                            card6H
                            { x = 50, y = 120 }
                            0
                            (modelWithHand handCard)
                in
                case afterDown.drag of
                    State.Dragging info ->
                        Expect.equal ViewportFrame info.pathFrame

                    _ ->
                        Expect.fail "expected Dragging state"
        , test "intra-board drag: initial floaterTopLeft = stack.loc (board frame)" <|
            \_ ->
                let
                    stack =
                        stackAt "2C,3D,4C" (at 100 200)

                    ( afterDown, _ ) =
                        Gesture.startBoardCardDrag
                            { stack = stack, cardIndex = 0 }
                            { x = 410, y = 310 }
                            0
                            (modelWithStack stack)
                in
                case afterDown.drag of
                    State.Dragging info ->
                        Expect.equal { x = 100, y = 200 } info.floaterTopLeft

                    _ ->
                        Expect.fail "expected Dragging state"
        ]



-- HELPERS


modelWithStack : CardStack -> State.Model
modelWithStack stack =
    let
        base =
            State.baseModel
    in
    { base | board = [ stack ] }


modelWithHand : HandCard -> State.Model
modelWithHand handCard =
    let
        base =
            State.baseModel
    in
    State.setActiveHand { handCards = [ handCard ] } base



-- MAIN SUITE


suite : Test
suite =
    describe "Main drag invariants"
        [ suiteCaptureInvariant
        , suitePathFrame
        ]
