module Game.InitialStateDslTest exposing (suite)

import Expect
import Game.CardStack exposing (BoardCardState(..), HandCardState(..))
import Game.Game exposing (GameState)
import Game.Hand as Hand
import Game.InitialStateDsl as InitialStateDsl
import Game.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "InitialStateDsl"
        [ test "empty state round-trips" <|
            \_ ->
                let
                    empty =
                        { board = []
                        , hands = [ Hand.empty, Hand.empty ]
                        , activePlayerIndex = 0
                        , turnIndex = 0
                        , deck = []
                        , cardsPlayedThisTurn = 0
                        , victorAwarded = False
                        }
                in
                roundTripState empty
        , test "rich state round-trips" <|
            \_ ->
                roundTripState sampleState
        , test "formatted output looks human-readable" <|
            \_ ->
                let
                    rendered =
                        InitialStateDsl.formatGameState sampleState
                in
                rendered
                    |> Expect.equal expectedSampleRendering
        , test "rejects unknown scalar key" <|
            \_ ->
                "active_player: 0\nbogus_key: 1"
                    |> InitialStateDsl.parseGameState
                    |> Result.map (always ())
                    |> Expect.equal (Err "unknown scalar key: bogus_key")
        ]


roundTripState : GameState -> Expect.Expectation
roundTripState gs =
    let
        rendered =
            InitialStateDsl.formatGameState gs
    in
    InitialStateDsl.parseGameState rendered
        |> Expect.equal (Ok gs)


sampleState : GameState
sampleState =
    { board =
        [ { boardCards = boardCards [ card Two Heart, card Three Heart, card Four Heart ]
          , loc = { top = 26, left = 26 }
          }
        , { boardCards = boardCards [ card Seven Spade, card Seven Diamond, card Seven Club ]
          , loc = { top = 107, left = 52 }
          }
        ]
    , hands =
        [ { handCards =
                [ handCard Ace Heart
                , handCard Five Heart
                , handCard Jack Heart
                , handCard King Spade
                ]
          }
        , { handCards = [ handCard Three Heart, handCard Four Heart ] }
        ]
    , activePlayerIndex = 1
    , turnIndex = 5
    , deck =
        [ card King Club, card Queen Club, card Jack Club, card Two Diamond ]
    , cardsPlayedThisTurn = 2
    , victorAwarded = False
    }


expectedSampleRendering : String
expectedSampleRendering =
    """board:
  at ( 26,  26): 2♥ 3♥ 4♥
  at (107,  52): 7♠ 7♦ 7♣

Player One Hand:
  A♥ 5♥ J♥
  K♠

Player Two Hand:
  3♥ 4♥

deck: K♣ Q♣ J♣ 2♦

active_player: 1
turn_index: 5
cards_played_this_turn: 2
victor_awarded: false"""


boardCards : List Card -> List { card : Card, state : BoardCardState }
boardCards cs =
    List.map (\c -> { card = c, state = FirmlyOnBoard }) cs


card : CardValue -> Suit -> Card
card v s =
    { value = v, suit = s, originDeck = DeckOne }


handCard : CardValue -> Suit -> { card : Card, state : HandCardState }
handCard v s =
    { card = card v s, state = HandNormal }
