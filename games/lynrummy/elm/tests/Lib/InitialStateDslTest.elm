module Lib.InitialStateDslTest exposing (suite)

import Expect
import Lib.CardStack exposing (BoardCardState(..), HandCardState(..))
import Lib.Dealer as Dealer
import Lib.GameState exposing (GameState)
import Lib.Hand as Hand
import Lib.InitialStateDsl as InitialStateDsl
import Lib.Player exposing (Player(..))
import Lib.Random
import Lib.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "InitialStateDsl"
        [ test "empty state round-trips" <|
            \_ ->
                let
                    empty =
                        { board = []
                        , humanHand = Hand.empty
                        , agentHand = Hand.empty
                        , activePlayer = Human
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
        , test "real Dealer output: format is idempotent" <|
            \_ ->
                -- The Dealer is the production source of new-game
                -- GameStates. The wire round-trip canonicalizes
                -- hand-card order (sorted by suit then value),
                -- so value equality between dealtState and
                -- parse(format(dealtState)) wouldn't hold. What
                -- DOES hold — and what the wire actually needs —
                -- is that re-emitting the parsed state gives
                -- byte-identical DSL.
                let
                    setup =
                        Dealer.dealFullGame (Lib.Random.initSeed 42)

                    dealtState =
                        { board = setup.board
                        , humanHand = setup.humanHand
                        , agentHand = setup.agentHand
                        , activePlayer = Human
                        , turnIndex = 0
                        , deck = setup.deck
                        , cardsPlayedThisTurn = 0
                        , victorAwarded = False
                        }

                    rendered =
                        InitialStateDsl.formatGameState dealtState
                in
                InitialStateDsl.parseGameState rendered
                    |> Result.map InitialStateDsl.formatGameState
                    |> Expect.equal (Ok rendered)
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
    , humanHand =
        { handCards =
            [ handCard Ace Heart
            , handCard Five Heart
            , handCard Jack Heart
            , handCard King Spade
            ]
        }
    , agentHand =
        { handCards = [ handCard Three Heart, handCard Four Heart ] }
    , activePlayer = Agent
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
  at ( 52, 107): 7♠ 7♦ 7♣

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
