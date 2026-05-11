module Game.BoardDslTest exposing (suite)

import Expect
import Game.BoardDsl as BoardDsl
import Game.CardStack exposing (BoardCardState(..))
import Game.Rules.Card exposing (CardValue(..), OriginDeck(..), Suit(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "BoardDsl"
        [ describe "parseBoard"
            [ test "empty input → empty board" <|
                \_ ->
                    BoardDsl.parseBoard "" |> Expect.equal (Ok [])
            , test "single stack" <|
                \_ ->
                    BoardDsl.parseBoard "at (26, 26): 2H 3H 4H"
                        |> Expect.equal
                            (Ok
                                [ { boardCards =
                                        [ { card = card Two Heart DeckOne, state = FirmlyOnBoard }
                                        , { card = card Three Heart DeckOne, state = FirmlyOnBoard }
                                        , { card = card Four Heart DeckOne, state = FirmlyOnBoard }
                                        ]
                                  , loc = { top = 26, left = 26 }
                                  }
                                ]
                            )
            , test "accepts unicode suit glyphs" <|
                \_ ->
                    BoardDsl.parseBoard "at (0, 0): A♥ 2♥"
                        |> Result.map (List.concatMap .boardCards >> List.map (.card >> .suit))
                        |> Expect.equal (Ok [ Heart, Heart ])
            , test "honors deck suffix" <|
                \_ ->
                    BoardDsl.parseBoard "at (0, 0): KD KD'"
                        |> Result.map (List.concatMap .boardCards >> List.map (.card >> .originDeck))
                        |> Expect.equal (Ok [ DeckOne, DeckTwo ])
            , test "skips blank lines and comments" <|
                \_ ->
                    BoardDsl.parseBoard "# header\n\nat (10, 10): 2H 3H 4H\n\n# trailing"
                        |> Result.map List.length
                        |> Expect.equal (Ok 1)
            , test "bad card label reports line number" <|
                \_ ->
                    BoardDsl.parseBoard "at (0, 0): 2H\nat (0, 0): XX"
                        |> Expect.equal (Err "line 2: invalid card label: XX")
            , test "missing colon after location reports an error" <|
                \_ ->
                    BoardDsl.parseBoard "at (0, 0) 2H 3H"
                        |> Expect.equal (Err "line 1: expected ':' after location")
            ]
        , describe "format ∘ parse round-trip"
            [ test "single stack" <|
                \_ ->
                    roundTrip "at (26, 26): 2♥ 3♥ 4♥"
            , test "multiple stacks" <|
                \_ ->
                    roundTrip
                        ("at (26, 26): 2♥ 3♥ 4♥\n"
                            ++ "at (107, 52): 7♠ 7♦ 7♣\n"
                            ++ "at (182, 52): A♣ A♦ A♥"
                        )
            , test "dual-deck cards survive" <|
                \_ ->
                    roundTrip "at (0, 0): K♦ K♦' K♥' K♠"
            ]
        ]


roundTrip : String -> Expect.Expectation
roundTrip src =
    BoardDsl.parseBoard src
        |> Result.map BoardDsl.formatBoard
        |> Expect.equal (Ok src)


card : CardValue -> Suit -> OriginDeck -> { value : CardValue, suit : Suit, originDeck : OriginDeck }
card v s d =
    { value = v, suit = s, originDeck = d }
