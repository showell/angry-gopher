module Game.Replay.DragAnimationTest exposing (suite)

{-| Property + boundary tests for `Game.Replay.DragAnimation`.

The drag-animation sub-state-machine is deterministic
physics — given (clock time, AnimationInfo) → Step. These
tests lock down the laws so the broader replay state
machine in `Game.Replay.Time` can change its UX cadence
(beat durations, PreRolling holds) without disturbing the
animation contract.

What's locked down here:

  - Step at startMs returns InProgress (animation hasn't
    elapsed yet).
  - Step at startMs + duration returns Done with the
    correct pendingAction.
  - Step beyond duration also returns Done.
  - Empty path collapses to Done immediately.
  - Mid-animation cursor advances along the path
    (monotonic by frame).
  - Step is a pure function: same inputs → same output.

What's NOT in scope here:

  - Outer replay cadence (Beating, PreRolling) — that's
    `Game.Replay.Time`'s concern and explicitly volatile.
  - Path SHAPE (linear vs eased) — `Game.Replay.Space`
    owns that; this module trusts the path it gets.

-}

import Expect
import Game.BoardActions as BoardActions
import Game.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Game.CardStack exposing (BoardCard, BoardCardState(..), CardStack)
import Game.Replay.DragAnimation as DA
import Game.Replay.Space as Space
import Game.WireAction as WA exposing (WireAction)
import Main.State exposing (DragState(..), DragSource(..), GesturePoint, PathFrame(..))
import Test exposing (Test, describe, test)


-- FIXTURES


fixtureCard : Card
fixtureCard =
    { value = Five, suit = Heart, originDeck = DeckOne }


fixtureBoardCard : BoardCard
fixtureBoardCard =
    { card = fixtureCard, state = FirmlyOnBoard }


fixtureStack : CardStack
fixtureStack =
    { boardCards = [ fixtureBoardCard ], loc = { left = 100, top = 100 } }


-- A simple 3-point path from (0,0) at t=1000 to (100,0) at
-- t=2000. Straight line, 1-second duration, 1ms-per-pixel
-- equivalent for arithmetic clarity.
fixturePath : List GesturePoint
fixturePath =
    [ { tMs = 1000, x = 0, y = 0 }
    , { tMs = 1500, x = 50, y = 0 }
    , { tMs = 2000, x = 100, y = 0 }
    ]


fixtureAction : WireAction
fixtureAction =
    WA.MergeStack
        { source = fixtureStack
        , target = fixtureStack
        , side = BoardActions.Right
        }


fixtureAnim : Space.AnimationInfo
fixtureAnim =
    { startMs = 1000
    , path = fixturePath
    , source = FromBoardStack fixtureStack
    , pathFrame = ViewportFrame
    , pendingAction = fixtureAction
    }


-- HELPERS


cursorOf : DA.Step -> Maybe { x : Int, y : Int }
cursorOf result =
    case result of
        DA.InProgress { drag } ->
            case drag of
                Dragging d ->
                    Just d.floaterTopLeft

                NotDragging ->
                    Nothing

        DA.Done _ ->
            Nothing


isDone : DA.Step -> Bool
isDone result =
    case result of
        DA.Done _ ->
            True

        DA.InProgress _ ->
            False


-- TESTS


suite : Test
suite =
    describe "Game.Replay.DragAnimation"
        [ describe "step at boundaries"
            [ test "at startMs returns InProgress at path[0]" <|
                \_ ->
                    DA.step 1000 fixtureAnim
                        |> cursorOf
                        |> Expect.equal (Just { x = 0, y = 0 })
            , test "at startMs + duration returns Done" <|
                \_ ->
                    DA.step 2000 fixtureAnim
                        |> isDone
                        |> Expect.equal True
            , test "beyond duration returns Done" <|
                \_ ->
                    DA.step 5000 fixtureAnim
                        |> isDone
                        |> Expect.equal True
            ]
        , describe "step mid-animation"
            [ test "halfway returns InProgress at path midpoint" <|
                \_ ->
                    DA.step 1500 fixtureAnim
                        |> cursorOf
                        |> Expect.equal (Just { x = 50, y = 0 })
            , test "quarter through returns InProgress at quarter" <|
                \_ ->
                    DA.step 1250 fixtureAnim
                        |> cursorOf
                        |> Expect.equal (Just { x = 25, y = 0 })
            , test "cursor advances monotonically over time" <|
                \_ ->
                    let
                        xs =
                            List.map
                                (\nowMs ->
                                    DA.step (toFloat nowMs) fixtureAnim
                                        |> cursorOf
                                        |> Maybe.map .x
                                        |> Maybe.withDefault -1
                                )
                                [ 1000, 1100, 1300, 1500, 1700, 1900 ]

                        sorted =
                            List.sort xs
                    in
                    xs |> Expect.equal sorted
            ]
        , describe "edge cases"
            [ test "empty path returns Done immediately" <|
                \_ ->
                    let
                        emptyAnim =
                            { fixtureAnim | path = [] }
                    in
                    DA.step 1000 emptyAnim
                        |> isDone
                        |> Expect.equal True
            , test "single-point path returns Done at startMs" <|
                \_ ->
                    let
                        singleAnim =
                            { fixtureAnim
                                | path =
                                    [ { tMs = 1000, x = 50, y = 50 } ]
                            }
                    in
                    DA.step 1000 singleAnim
                        |> isDone
                        |> Expect.equal True
            ]
        , describe "purity"
            [ test "step is deterministic for the same inputs" <|
                \_ ->
                    let
                        a =
                            DA.step 1500 fixtureAnim
                                |> cursorOf

                        b =
                            DA.step 1500 fixtureAnim
                                |> cursorOf
                    in
                    a |> Expect.equal b
            ]
        , describe "Done payload"
            [ test "Done carries the pendingAction unchanged" <|
                \_ ->
                    case DA.step 2000 fixtureAnim of
                        DA.Done { pendingAction } ->
                            pendingAction |> Expect.equal fixtureAction

                        DA.InProgress _ ->
                            Expect.fail "expected Done"
            ]
        ]
