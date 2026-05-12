module Lib.ReducerTest exposing (suite)

{-| Tests for `Main.State.applyEvent`. Each action type
gets a transition test; a longer test sequences several actions
and checks end-state. CompleteTurn / Undo verify they pass
state through (CompleteTurn's full turn-flip is exercised in
GameTest, which is the dedicated CompleteTurn suite).
-}

import Expect
import Lib.BoardActions exposing (Side(..))
import Lib.CardStack exposing (BoardCardState(..), CardStack, HandCardState(..))
import Lib.Dealer
import Lib.Game exposing (GameState)
import Lib.GameEvent exposing (GameEvent(..))
import Lib.Hand as Hand
import Lib.Rules.Card exposing (CardValue(..), OriginDeck(..), Suit(..))
import Main.State as State
import Test exposing (Test, describe, test)


{-| Return the CardStack at index idx of the given state's board. -}
stackAt : Int -> GameState -> CardStack
stackAt idx state =
    state.board
        |> List.drop idx
        |> List.head
        |> Maybe.withDefault
            -- should never happen for indices we use in tests
            { boardCards = [], loc = { top = 0, left = 0 } }


{-| A synthetic ghost CardStack that no real board will match. -}
ghostStack : CardStack
ghostStack =
    { boardCards =
        [ { card = { value = Ten, suit = Club, originDeck = DeckOne }
          , state = FirmlyOnBoard
          }
        ]
    , loc = { top = 9999, left = 9999 }
    }


initialGameState : GameState
initialGameState =
    { board = Lib.Dealer.initialBoard
    , hands = [ Hand.empty, Hand.empty ]
    , activePlayerIndex = 0
    , turnIndex = 0
    , deck = []
    , cardsPlayedThisTurn = 0
    , victorAwarded = False
    }


suite : Test
suite =
    describe "State.applyEvent"
        [ describe "Split"
            [ test "splits stack 0 (KS,AS,2S,3S) at index 2 → two stacks replace one" <|
                \_ ->
                    let
                        before =
                            initialGameState

                        after =
                            State.applyEvent
                                (Split { stack = stackAt 0 before, cardIndex = 2 })
                                before
                    in
                    List.length after.board
                        |> Expect.equal (List.length before.board + 1)
            ]
        , describe "MoveStack"
            [ test "updates loc of target stack" <|
                \_ ->
                    let
                        before =
                            initialGameState

                        newLoc =
                            { top = 300, left = 400 }

                        after =
                            State.applyEvent
                                (MoveStack { stack = stackAt 0 before, newLoc = newLoc, boardPath = [] })
                                before

                        -- Moved stack is appended at the end of
                        -- the board list (applyChange semantics).
                        movedLoc =
                            after.board
                                |> List.reverse
                                |> List.head
                                |> Maybe.map .loc
                    in
                    movedLoc
                        |> Expect.equal (Just newLoc)
            ]
        , describe "PlaceHand"
            [ test "removes 7H from hand and adds a singleton to the board" <|
                \_ ->
                    let
                        card7H =
                            { value = Seven, suit = Heart, originDeck = DeckTwo }

                        beforeHand =
                            Hand.addCards [ card7H ] HandNormal Hand.empty

                        before =
                            { initialGameState | hands = [ beforeHand, Hand.empty ] }

                        after =
                            State.applyEvent
                                (PlaceHand { handCard = card7H, loc = { top = 400, left = 500 } })
                                before
                    in
                    Expect.all
                        [ \a -> Hand.size (Hand.activeHand a) |> Expect.equal (Hand.size beforeHand - 1)
                        , \a -> List.length a.board |> Expect.equal (List.length before.board + 1)
                        ]
                        after
            ]
        , describe "MergeHand"
            [ test "7H onto the 7S,7D,7C set (right side) → set grows by 1, hand shrinks by 1" <|
                \_ ->
                    let
                        card7H =
                            { value = Seven, suit = Heart, originDeck = DeckTwo }

                        beforeHand =
                            Hand.addCards [ card7H ] HandNormal Hand.empty

                        before =
                            { initialGameState | hands = [ beforeHand, Hand.empty ] }

                        -- Stack index 3 in the opening board is "7S,7D,7C".
                        after =
                            State.applyEvent
                                (MergeHand
                                    { handCard = card7H
                                    , target = stackAt 3 before
                                    , side = Right
                                    }
                                )
                                before
                    in
                    Expect.all
                        [ \a -> Hand.size (Hand.activeHand a) |> Expect.equal (Hand.size beforeHand - 1)
                        , \a -> List.length a.board |> Expect.equal (List.length before.board)
                        ]
                        after
            ]
        , describe "Undo passes through; CompleteTurn flips turn semantics"
            [ test "Undo is a pass-through" <|
                \_ ->
                    State.applyEvent Undo initialGameState
                        |> Expect.equal initialGameState
            ]
        , describe "silent pass-through on invalid references"
            [ test "Split on a ghost stack is a no-op" <|
                \_ ->
                    State.applyEvent
                        (Split { stack = ghostStack, cardIndex = 0 })
                        initialGameState
                        |> Expect.equal initialGameState
            , test "MoveStack on a ghost stack is a no-op" <|
                \_ ->
                    State.applyEvent
                        (MoveStack { stack = ghostStack, newLoc = { top = 10, left = 10 }, boardPath = [] })
                        initialGameState
                        |> Expect.equal initialGameState
            , test "MergeHand with a card not in hand is a no-op" <|
                \_ ->
                    let
                        before =
                            initialGameState

                        notInHand =
                            { value = Ace, suit = Spade, originDeck = DeckTwo }
                    in
                    State.applyEvent
                        (MergeHand
                            { handCard = notInHand
                            , target = stackAt 3 before
                            , side = Right
                            }
                        )
                        before
                        |> Expect.equal before
            ]
        , describe "sequenced actions"
            [ test "split then move applies in order" <|
                \_ ->
                    let
                        start =
                            initialGameState

                        step1 =
                            State.applyEvent
                                (Split { stack = stackAt 0 start, cardIndex = 2 })
                                start

                        step2 =
                            State.applyEvent
                                (MoveStack
                                    { stack = stackAt 0 step1
                                    , newLoc = { top = 500, left = 400 }
                                    , boardPath = []
                                    }
                                )
                                step1
                    in
                    List.length step2.board
                        |> Expect.equal (List.length start.board + 1)
            ]
        ]
