module Game.CardStackTest exposing (suite)

{-| Tests for `Game.CardStack`. Ported from
`angry-cat/src/lyn_rummy/core/card_stack_test.ts`.

Deferred from the source tests:

  - `clone` — N/A in Elm (immutable values).
  - JSON round-trip — boundary plumbing, ported later.
  - `pullFromDeck` — requires a pure deck model; the TS test
    uses a mock `DeckRef` that's mutable by design.

Added (current-Claude filling in past-Claude's thin spots):

  - Explicit tests for `agedFromPriorTurn` state transitions.
  - Size and stackCards sanity checks.

-}

import Expect
import Game.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..), cardFromLabel)
import Game.CardStack
    exposing
        ( BoardCardState(..)
        , BoardLocation
        , CardStack
        , HandCardState(..)
        , agedFromPriorTurn
        , boardCardAgedState
        , isBoardCardSameCard
        , fromHandCard
        , fromShorthand
        , isHandCardSameCard
        , isIncomplete
        , maybeMerge
        , isProblematic
        , size
        , stackStr
        , stackType
        , isStacksEqual
        )
import Game.Rules.StackType exposing (CardStackType(..))
import Test exposing (Test, describe, test)



-- HELPERS


origin : BoardLocation
origin =
    { top = 0, left = 0 }


fallback : Card
fallback =
    { value = Ace, suit = Club, originDeck = DeckOne }


card : String -> OriginDeck -> Card
card label deck =
    cardFromLabel label deck |> Maybe.withDefault fallback


{-| Make a stack of firmly-on-board cards from labels, all from
DeckOne, at (0,0).
-}
stackOf : List String -> CardStack
stackOf labels =
    { boardCards =
        List.map
            (\l -> { card = card l DeckOne, state = FirmlyOnBoard })
            labels
    , loc = origin
    }



-- SUITE


suite : Test
suite =
    describe "Game.CardStack"
        [ stackTypeTests
        , incompleteProblematicTests
        , strAndEqualsTests
        , sameCardEqualityTests
        , fromHandCardTests
        , fromShorthandTests
        , agedFromPriorTurnTests
        , maybeMergeTests
        , derivedQueryTests
        ]


stackTypeTests : Test
stackTypeTests =
    describe "stackType (derived, not stored)"
        [ test "single card -> Incomplete" <|
            \_ -> Expect.equal Incomplete (stackType (stackOf [ "AH" ]))
        , test "two cards -> Incomplete" <|
            \_ -> Expect.equal Incomplete (stackType (stackOf [ "AH", "2H" ]))
        , test "AH 2H 3H -> PureRun" <|
            \_ -> Expect.equal PureRun (stackType (stackOf [ "AH", "2H", "3H" ]))
        , test "AH 2S 3H -> RedBlackRun" <|
            \_ -> Expect.equal RedBlackRun (stackType (stackOf [ "AH", "2S", "3H" ]))
        , test "7S 7D 7C -> Set" <|
            \_ -> Expect.equal Set (stackType (stackOf [ "7S", "7D", "7C" ]))
        ]


incompleteProblematicTests : Test
incompleteProblematicTests =
    describe "incomplete / problematic"
        [ test "one card is incomplete" <|
            \_ -> Expect.equal True (isIncomplete (stackOf [ "AH" ]))
        , test "a valid run is NOT incomplete" <|
            \_ -> Expect.equal False (isIncomplete (stackOf [ "AH", "2H", "3H" ]))
        , test "a dup stack is problematic" <|
            \_ ->
                let
                    dupStack =
                        { boardCards =
                            [ { card = card "AH" DeckOne, state = FirmlyOnBoard }
                            , { card = card "AH" DeckTwo, state = FirmlyOnBoard }
                            ]
                        , loc = origin
                        }
                in
                Expect.equal True (isProblematic dupStack)
        , test "a valid run is NOT problematic" <|
            \_ -> Expect.equal False (isProblematic (stackOf [ "AH", "2H", "3H" ]))
        ]


strAndEqualsTests : Test
strAndEqualsTests =
    describe "stackStr and isStacksEqual"
        [ test "stackStr uses value + suit-emoji, comma-joined" <|
            \_ ->
                Expect.equal "A♥,2♥,3♥"
                    (stackStr (stackOf [ "AH", "2H", "3H" ]))
        , test "two stacks with the same cards + loc are equal" <|
            \_ ->
                Expect.equal True
                    (isStacksEqual
                        (stackOf [ "AH", "2H", "3H" ])
                        (stackOf [ "AH", "2H", "3H" ])
                    )
        , test "different cards -> not equal" <|
            \_ ->
                Expect.equal False
                    (isStacksEqual
                        (stackOf [ "AH", "2H", "3H" ])
                        (stackOf [ "AH", "2H", "3D" ])
                    )
        , test "same cards, different loc -> not equal" <|
            \_ ->
                let
                    s1 =
                        stackOf [ "AH", "2H", "3H" ]

                    s2 =
                        { s1 | loc = { top = 10, left = 20 } }
                in
                Expect.equal False (isStacksEqual s1 s2)
        , test "deck-aware: same value+suit from different decks -> NOT equal (mirrors TS; inventory accounting must distinguish decks)" <|
            \_ ->
                let
                    d1 =
                        { boardCards = [ { card = card "AH" DeckOne, state = FirmlyOnBoard } ]
                        , loc = origin
                        }

                    d2 =
                        { boardCards = [ { card = card "AH" DeckTwo, state = FirmlyOnBoard } ]
                        , loc = origin
                        }
                in
                Expect.equal False (isStacksEqual d1 d2)
        ]


sameCardEqualityTests : Test
sameCardEqualityTests =
    describe "isBoardCardSameCard / isHandCardSameCard ignore state"
        [ test "isBoardCardSameCard: same card, different states → True" <|
            \_ ->
                let
                    a =
                        { card = card "AH" DeckOne, state = FirmlyOnBoard }

                    b =
                        { card = card "AH" DeckOne, state = FreshlyPlayed }
                in
                Expect.equal True (isBoardCardSameCard a b)
        , test "isBoardCardSameCard: different cards (same state) → False" <|
            \_ ->
                let
                    a =
                        { card = card "AH" DeckOne, state = FirmlyOnBoard }

                    b =
                        { card = card "2H" DeckOne, state = FirmlyOnBoard }
                in
                Expect.equal False (isBoardCardSameCard a b)
        , test "isBoardCardSameCard: same value+suit, different deck → False (Card == is deck-aware)" <|
            \_ ->
                let
                    a =
                        { card = card "AH" DeckOne, state = FirmlyOnBoard }

                    b =
                        { card = card "AH" DeckTwo, state = FirmlyOnBoard }
                in
                Expect.equal False (isBoardCardSameCard a b)
        , test "isHandCardSameCard: same card, different states → True" <|
            \_ ->
                let
                    a =
                        { card = card "KD" DeckOne, state = HandNormal }

                    b =
                        { card = card "KD" DeckOne, state = FreshlyDrawn }
                in
                Expect.equal True (isHandCardSameCard a b)
        , test "isHandCardSameCard: different cards → False" <|
            \_ ->
                let
                    a =
                        { card = card "KD" DeckOne, state = HandNormal }

                    b =
                        { card = card "QD" DeckOne, state = HandNormal }
                in
                Expect.equal False (isHandCardSameCard a b)
        ]


fromHandCardTests : Test
fromHandCardTests =
    describe "fromHandCard"
        [ test "creates a single-card stack with FreshlyPlayed state" <|
            \_ ->
                let
                    hc =
                        { card = card "KD" DeckOne, state = HandNormal }

                    stack =
                        fromHandCard hc origin
                in
                Expect.all
                    [ size >> Expect.equal 1
                    , .boardCards
                        >> List.head
                        >> Maybe.map .state
                        >> Expect.equal (Just FreshlyPlayed)
                    ]
                    stack
        ]


fromShorthandTests : Test
fromShorthandTests =
    describe "fromShorthand"
        [ test "valid shorthand builds a stack of FirmlyOnBoard cards" <|
            \_ ->
                case fromShorthand "AH,2H,3H" DeckOne origin of
                    Just stack ->
                        Expect.all
                            [ size >> Expect.equal 3
                            , stackType >> Expect.equal PureRun
                            , .boardCards
                                >> List.all (\bc -> bc.state == FirmlyOnBoard)
                                >> Expect.equal True
                            ]
                            stack

                    Nothing ->
                        Expect.fail "expected a valid stack, got Nothing"
        , test "uses the supplied origin deck for every card" <|
            \_ ->
                case fromShorthand "TS,JS,QS" DeckTwo origin of
                    Just stack ->
                        stack.boardCards
                            |> List.all (\bc -> bc.card.originDeck == DeckTwo)
                            |> Expect.equal True

                    Nothing ->
                        Expect.fail "expected a valid stack, got Nothing"
        , test "stack lands at the supplied loc" <|
            \_ ->
                let
                    here =
                        { top = 42, left = 17 }
                in
                fromShorthand "5C,5D,5H" DeckOne here
                    |> Maybe.map .loc
                    |> Expect.equal (Just here)
        , test "malformed label returns Nothing" <|
            \_ ->
                Expect.equal Nothing
                    (fromShorthand "AH,XX,3H" DeckOne origin)
        , test "empty shorthand returns Nothing (zero-card stack is invalid)" <|
            \_ ->
                -- Splitting "" on "," yields [""] which fails to parse.
                Expect.equal Nothing
                    (fromShorthand "" DeckOne origin)
        ]


agedFromPriorTurnTests : Test
agedFromPriorTurnTests =
    describe "agedFromPriorTurn"
        [ test "FreshlyPlayed ages to FreshlyPlayedByLastPlayer" <|
            \_ ->
                let
                    fresh =
                        { boardCards = [ { card = card "AH" DeckOne, state = FreshlyPlayed } ]
                        , loc = origin
                        }
                in
                agedFromPriorTurn fresh
                    |> .boardCards
                    |> List.head
                    |> Maybe.map .state
                    |> Expect.equal (Just FreshlyPlayedByLastPlayer)
        , test "FreshlyPlayedByLastPlayer ages to FirmlyOnBoard" <|
            \_ ->
                Expect.equal FirmlyOnBoard
                    (boardCardAgedState FreshlyPlayedByLastPlayer)
        , test "FirmlyOnBoard ages to itself (terminal)" <|
            \_ ->
                Expect.equal FirmlyOnBoard
                    (boardCardAgedState FirmlyOnBoard)
        ]


maybeMergeTests : Test
maybeMergeTests =
    describe "maybeMerge"
        [ test "(AH,2H) + (3H,4H) merges to a PureRun of 4" <|
            \_ ->
                case maybeMerge (stackOf [ "AH", "2H" ]) (stackOf [ "3H", "4H" ]) origin of
                    Just merged ->
                        Expect.all
                            [ stackType >> Expect.equal PureRun
                            , size >> Expect.equal 4
                            ]
                            merged

                    Nothing ->
                        Expect.fail "expected a valid merge, got Nothing"
        , test "merging a stack with itself fails" <|
            \_ ->
                let
                    s =
                        stackOf [ "AH", "2H" ]
                in
                Expect.equal Nothing (maybeMerge s s origin)
        , test "merging into a bogus result fails" <|
            \_ ->
                Expect.equal Nothing
                    (maybeMerge
                        (stackOf [ "AH", "2H" ])
                        (stackOf [ "KS" ])
                        origin
                    )
        ]


derivedQueryTests : Test
derivedQueryTests =
    describe "derived queries"
        [ test "size counts board cards" <|
            \_ -> Expect.equal 3 (size (stackOf [ "AH", "2H", "3H" ]))
        , test "empty stack has size 0" <|
            \_ ->
                Expect.equal 0
                    (size { boardCards = [], loc = origin })
        ]
