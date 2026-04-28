module Game.GameTest exposing (suite)

{-| Tests for Game.Game.applyCompleteTurn — the autonomous
CompleteTurn transition. Covers:

  - Classification of each turn-result branch
    (Success / SuccessButNeedsCards / SuccessAsVictor /
    SuccessWithHandEmpty).
  - Correct card-draw counts (0/3/5).
  - Seat flip and turn-index increment.
  - Deck is drawn from the front, in order, and the remaining
    deck is the tail.
  - Score banking for each branch.
  - victorAwarded flip (once-per-game semantics).
  - cardsPlayedThisTurn resets.
  - turnStartBoardScore updates to the post-turn board score.

Each test builds a minimal GameState, applies the transition,
and asserts the resulting fields. No I/O, no randomness —
everything is deterministic.

-}

import Expect
import Game.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Game.CardStack exposing (HandCard, HandCardState(..))
import Game.Game as Game exposing (GameState)
import Game.Hand as Hand
import Test exposing (Test, describe, test)


{-| Thin wrapper for tests that only care about the post-turn
state. `Game.applyCompleteTurn` returns
`(GameState, CompleteTurnOutcome)`; most tests here only
inspect the state.
-}
applyTurn : GameState a -> GameState a
applyTurn =
    Tuple.first << Game.applyCompleteTurn



-- SHARED FIXTURES


{-| A minimal non-empty hand: one card that won't affect score
or classification (no set/run of interest).
-}
lonelyCard : Card
lonelyCard =
    { value = Seven, suit = Heart, originDeck = DeckTwo }


lonelyHandCard : HandCard
lonelyHandCard =
    { card = lonelyCard, state = HandNormal }


lonelyHand : Hand.Hand
lonelyHand =
    { handCards = [ lonelyHandCard ] }


{-| Build an otherwise-empty state seeded with the required
fields. The board is empty (score 0); outgoing hand can be
overridden via the record accessor.
-}
baseState : GameState {}
baseState =
    { board = []
    , hands = [ lonelyHand, Hand.empty ]
    , scores = [ 0, 0 ]
    , activePlayerIndex = 0
    , turnIndex = 0
    , deck = []
    , cardsPlayedThisTurn = 0
    , victorAwarded = False
    , turnStartBoardScore = 0
    }


deckOfThree : List Card
deckOfThree =
    [ { value = Two, suit = Club, originDeck = DeckOne }
    , { value = Three, suit = Diamond, originDeck = DeckOne }
    , { value = Four, suit = Spade, originDeck = DeckOne }
    ]


deckOfFive : List Card
deckOfFive =
    deckOfThree
        ++ [ { value = Five, suit = Heart, originDeck = DeckOne }
           , { value = Six, suit = Club, originDeck = DeckOne }
           ]



-- TESTS


suite : Test
suite =
    describe "Game.Game.applyCompleteTurn"
        [ seatAndTurn
        , cardsPlayedBranches
        , deckDrawBranches
        , scoringBranches
        , victorAwardedOnce
        , cardsPlayedResets
        , turnStartBoardScoreAdvances
        ]


seatAndTurn : Test
seatAndTurn =
    describe "always flips seat and increments turn"
        [ test "seat flips 0 → 1" <|
            \_ ->
                { baseState | cardsPlayedThisTurn = 0 }
                    |> applyTurn
                    |> .activePlayerIndex
                    |> Expect.equal 1
        , test "seat flips 1 → 0" <|
            \_ ->
                { baseState | activePlayerIndex = 1, cardsPlayedThisTurn = 0 }
                    |> applyTurn
                    |> .activePlayerIndex
                    |> Expect.equal 0
        , test "turnIndex 0 → 1" <|
            \_ ->
                { baseState | cardsPlayedThisTurn = 0 }
                    |> applyTurn
                    |> .turnIndex
                    |> Expect.equal 1
        ]


cardsPlayedBranches : Test
cardsPlayedBranches =
    describe "classification via cardsPlayed + empty-hand state"
        -- Note: we can't directly read the classification; we infer
        -- it via draw count (cardsDrawn is deterministic per branch).
        [ test "0 cards played → SuccessButNeedsCards (draws 3)" <|
            \_ ->
                { baseState | deck = deckOfThree, cardsPlayedThisTurn = 0 }
                    |> applyTurn
                    |> (\s -> s.hands |> List.head |> Maybe.map Hand.size)
                    |> Expect.equal (Just (1 + 3))
        , test "played cards, hand non-empty → Success (draws 0)" <|
            \_ ->
                { baseState | deck = deckOfThree, cardsPlayedThisTurn = 2 }
                    |> applyTurn
                    |> (\s -> s.hands |> List.head |> Maybe.map Hand.size)
                    |> Expect.equal (Just 1)
        , test "played cards, hand empty, no prior victor → SuccessAsVictor (draws 5)" <|
            \_ ->
                { baseState
                    | hands = [ Hand.empty, Hand.empty ]
                    , deck = deckOfFive
                    , cardsPlayedThisTurn = 3
                    , victorAwarded = False
                }
                    |> applyTurn
                    |> (\s -> s.hands |> List.head |> Maybe.map Hand.size)
                    |> Expect.equal (Just 5)
        , test "played cards, hand empty, prior victor → SuccessWithHandEmptied (draws 5)" <|
            \_ ->
                { baseState
                    | hands = [ Hand.empty, Hand.empty ]
                    , deck = deckOfFive
                    , cardsPlayedThisTurn = 3
                    , victorAwarded = True
                }
                    |> applyTurn
                    |> (\s -> s.hands |> List.head |> Maybe.map Hand.size)
                    |> Expect.equal (Just 5)
        ]


deckDrawBranches : Test
deckDrawBranches =
    describe "deck is drawn from the front, leftover is the tail"
        [ test "Success: deck untouched" <|
            \_ ->
                { baseState | deck = deckOfThree, cardsPlayedThisTurn = 2 }
                    |> applyTurn
                    |> .deck
                    |> Expect.equal deckOfThree
        , test "SuccessButNeedsCards: top 3 drawn" <|
            \_ ->
                { baseState | deck = deckOfFive, cardsPlayedThisTurn = 0 }
                    |> applyTurn
                    |> .deck
                    |> Expect.equal (List.drop 3 deckOfFive)
        ]


scoringBranches : Test
scoringBranches =
    describe "banked turn score"
        [ test "Success: banks cards-played bonus only (0 board score)" <|
            \_ ->
                { baseState | cardsPlayedThisTurn = 2 }
                    |> applyTurn
                    |> .scores
                    -- forCardsPlayed 2 = 200 + 100*4 = 600
                    |> Expect.equal [ 600, 0 ]
        , test "SuccessButNeedsCards: banks nothing (cardsPlayed = 0)" <|
            \_ ->
                { baseState | deck = deckOfThree, cardsPlayedThisTurn = 0 }
                    |> applyTurn
                    |> .scores
                    |> Expect.equal [ 0, 0 ]
        , test "SuccessAsVictor: banks cards-played + 1000 empty-hand + 500 victor" <|
            \_ ->
                { baseState
                    | hands = [ Hand.empty, Hand.empty ]
                    , deck = deckOfFive
                    , cardsPlayedThisTurn = 3
                    , victorAwarded = False
                }
                    |> applyTurn
                    |> .scores
                    -- forCardsPlayed 3 = 200 + 900 = 1100; +1000 empty; +500 victor
                    |> Expect.equal [ 2600, 0 ]
        , test "SuccessWithHandEmptied: banks cards-played + 1000 empty-hand (no victor)" <|
            \_ ->
                { baseState
                    | hands = [ Hand.empty, Hand.empty ]
                    , deck = deckOfFive
                    , cardsPlayedThisTurn = 3
                    , victorAwarded = True
                }
                    |> applyTurn
                    |> .scores
                    |> Expect.equal [ 2100, 0 ]
        ]


victorAwardedOnce : Test
victorAwardedOnce =
    describe "victorAwarded flips once, then sticks"
        [ test "flips to True on SuccessAsVictor" <|
            \_ ->
                { baseState
                    | hands = [ Hand.empty, Hand.empty ]
                    , deck = deckOfFive
                    , cardsPlayedThisTurn = 3
                    , victorAwarded = False
                }
                    |> applyTurn
                    |> .victorAwarded
                    |> Expect.equal True
        , test "stays True once set" <|
            \_ ->
                { baseState | cardsPlayedThisTurn = 2, victorAwarded = True }
                    |> applyTurn
                    |> .victorAwarded
                    |> Expect.equal True
        , test "stays False on non-victor branches" <|
            \_ ->
                { baseState | cardsPlayedThisTurn = 2, victorAwarded = False }
                    |> applyTurn
                    |> .victorAwarded
                    |> Expect.equal False
        ]


cardsPlayedResets : Test
cardsPlayedResets =
    test "cardsPlayedThisTurn resets to 0" <|
        \_ ->
            { baseState | cardsPlayedThisTurn = 5 }
                |> applyTurn
                |> .cardsPlayedThisTurn
                |> Expect.equal 0


turnStartBoardScoreAdvances : Test
turnStartBoardScoreAdvances =
    test "turnStartBoardScore advances to post-turn board score (still 0 in these fixtures)" <|
        \_ ->
            { baseState | cardsPlayedThisTurn = 2, turnStartBoardScore = 0 }
                |> applyTurn
                |> .turnStartBoardScore
                |> Expect.equal 0
