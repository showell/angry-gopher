module Lib.EngineTest exposing (suite)

import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Lib.CardStack exposing (BoardCardState(..))
import Lib.Engine as Engine
import Lib.GameEvent exposing (GameEvent(..))
import Lib.Rules.Card as Card exposing (CardValue(..), OriginDeck(..), Suit(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Lib.Engine — agent_step wire"
        [ describe "buildAgentStepRequest"
            [ test "encodes board+hand as canonical DSL strings" <|
                \_ ->
                    let
                        board =
                            [ { boardCards =
                                    [ { card = card Two Heart DeckOne, state = FirmlyOnBoard }
                                    , { card = card Three Heart DeckOne, state = FirmlyOnBoard }
                                    ]
                              , loc = { left = 26, top = 26 }
                              }
                            ]

                        hand =
                            [ card Five Heart DeckOne, card Six Heart DeckOne ]

                        payload =
                            Engine.buildAgentStepRequest 7 board hand

                        getField field =
                            Decode.decodeValue (Decode.field field Decode.string) payload
                    in
                    Expect.all
                        [ \_ -> Expect.equal (Ok 7) (Decode.decodeValue (Decode.field "request_id" Decode.int) payload)
                        , \_ -> Expect.equal (Ok "agent_step") (getField "op")
                        , \_ -> Expect.equal (Ok "at ( 26,  26): 2♥ 3♥") (getField "board_dsl")
                        , \_ -> Expect.equal (Ok "5♥ 6♥") (getField "hand_dsl")
                        ]
                        ()
            ]
        , describe "decodeAgentStepResponse"
            [ test "ok response with primitives_dsl parses each line through parseEvent" <|
                \_ ->
                    let
                        value =
                            Encode.object
                                [ ( "request_id", Encode.int 3 )
                                , ( "ok", Encode.bool True )
                                , ( "primitives_dsl"
                                  , Encode.string "merge_hand 5♥ -> [3♥ 4♥] at (100,100) /right"
                                  )
                                ]
                    in
                    case Engine.decodeAgentStepResponse (Just 3) value of
                        Engine.AgentStepEvents [ { event } ] ->
                            case event of
                                MergeHand _ ->
                                    Expect.pass

                                _ ->
                                    Expect.fail ("expected one MergeHand event, got: " ++ Debug.toString event)

                        other ->
                            Expect.fail ("expected one MergeHand event, got: " ++ Debug.toString other)
            , test "empty primitives_dsl → AgentStepEvents []" <|
                \_ ->
                    let
                        value =
                            Encode.object
                                [ ( "request_id", Encode.int 3 )
                                , ( "ok", Encode.bool True )
                                , ( "primitives_dsl", Encode.string "" )
                                ]
                    in
                    Engine.decodeAgentStepResponse (Just 3) value
                        |> Expect.equal (Engine.AgentStepEvents [])
            , test "stale request_id is recognized" <|
                \_ ->
                    let
                        value =
                            Encode.object
                                [ ( "request_id", Encode.int 1 )
                                , ( "ok", Encode.bool True )
                                , ( "primitives_dsl", Encode.string "" )
                                ]
                    in
                    Engine.decodeAgentStepResponse (Just 2) value
                        |> Expect.equal Engine.AgentStepStaleId
            , test "ok=false surfaces engine error string" <|
                \_ ->
                    let
                        value =
                            Encode.object
                                [ ( "request_id", Encode.int 3 )
                                , ( "ok", Encode.bool False )
                                , ( "error", Encode.string "boom" )
                                ]
                    in
                    Engine.decodeAgentStepResponse (Just 3) value
                        |> Expect.equal (Engine.AgentStepError "boom")
            ]
        ]


card : CardValue -> Suit -> OriginDeck -> Card.Card
card v s d =
    { value = v, suit = s, originDeck = d }
