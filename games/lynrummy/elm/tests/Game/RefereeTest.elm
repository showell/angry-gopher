module Game.RefereeTest exposing (suite)

{-| Tests for `Game.Referee`. Ported from
`angry-cat/src/lyn_rummy/game/pipeline_test.ts` (14 of 19
source tests — protocol-validation and board-geometry tests are
deferred with those modules).

Source tests ported:

  - test\_valid\_game\_sequence — four-move happy path
  - test\_midturn\_allows\_bogus / incomplete / dup\_set
  - test\_split\_through\_pipeline
  - test\_stages\_are\_independent
  - test\_inventory\_rejects\_card\_from\_nowhere
  - test\_inventory\_rejects\_unplaced\_hand\_card
  - test\_inventory\_allows\_rearrangement
  - test\_inventory\_rejects\_board\_duplicate
  - test\_inventory\_rejects\_new\_cards\_without\_hand
  - test\_inventory\_rejects\_missing\_remove
  - test\_geometry\_rejects\_overlap
  - test\_geometry\_rejects\_out\_of\_bounds
  - test\_turn\_complete\_clean\_board
  - test\_turn\_complete\_rejects\_incomplete
  - test\_turn\_complete\_rejects\_overlap
  - test\_turn\_complete\_empty\_board

Deferred with their modules:

  - test\_protocol\_rejects\_bad\_json (requires `protocol_validation`)

-}

import Expect
import Game.Physics.BoardGeometry exposing (BoardBounds)
import Game.Rules.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Game.CardStack
    exposing
        ( BoardCard
        , BoardCardState(..)
        , CardStack
        , HandCard
        , HandCardState(..)
        )
import Game.Rules.Referee
    exposing
        ( RefereeError
        , RefereeStage(..)
        , validateGameMove
        , validateTurnComplete
        )
import Test exposing (Test, describe, test)



-- HELPERS


bounds : BoardBounds
bounds =
    { maxWidth = 800, maxHeight = 600, margin = 7 }


card : CardValue -> Suit -> OriginDeck -> Card
card v s d =
    { value = v, suit = s, originDeck = d }


{-| FirmlyOnBoard card from DeckOne.
-}
bc : CardValue -> Suit -> BoardCard
bc v s =
    { card = card v s DeckOne, state = FirmlyOnBoard }


bcDeck : CardValue -> Suit -> OriginDeck -> BoardCard
bcDeck v s d =
    { card = card v s d, state = FirmlyOnBoard }


{-| FreshlyPlayed card from DeckOne.
-}
fresh : CardValue -> Suit -> BoardCard
fresh v s =
    { card = card v s DeckOne, state = FreshlyPlayed }


freshDeck : CardValue -> Suit -> OriginDeck -> BoardCard
freshDeck v s d =
    { card = card v s d, state = FreshlyPlayed }


{-| Hand card (HandNormal) from DeckOne.
-}
hc : CardValue -> Suit -> HandCard
hc v s =
    { card = card v s DeckOne, state = HandNormal }


hcDeck : CardValue -> Suit -> OriginDeck -> HandCard
hcDeck v s d =
    { card = card v s d, state = HandNormal }


stack : List BoardCard -> Int -> Int -> CardStack
stack cards top left =
    { boardCards = cards, loc = { top = top, left = left } }


{-| Shorthand for validate\_game\_move on a given board.
-}
rule :
    List CardStack
    ->
        { remove : List CardStack
        , add : List CardStack
        , played : List HandCard
        }
    -> Result RefereeError ()
rule board opts =
    validateGameMove
        { boardBefore = board
        , stacksToRemove = opts.remove
        , stacksToAdd = opts.add
        , handCardsPlayed = opts.played
        }
        bounds



-- SUITE


suite : Test
suite =
    describe "Game.Rules.Referee"
        [ validGameSequence
        , midturnLeniency
        , splitThroughPipeline
        , stagesAreIndependent
        , inventoryTests
        , geometryTests
        , turnCompleteTests
        ]


validGameSequence : Test
validGameSequence =
    describe "valid game sequence (four moves)"
        [ test "move 1: extend a run from hand" <|
            \_ ->
                let
                    run =
                        stack [ bc Five Heart, bc Six Heart, bc Seven Heart ] 10 10

                    set =
                        stack [ bc King Club, bc King Diamond, bc King Spade ] 10 200

                    extendedRun =
                        stack
                            [ bc Five Heart
                            , bc Six Heart
                            , bc Seven Heart
                            , fresh Eight Heart
                            ]
                            10
                            10
                in
                rule [ run, set ]
                    { remove = [ run ]
                    , add = [ extendedRun ]
                    , played = [ hc Eight Heart ]
                    }
                    |> Expect.equal (Ok ())
        , test "move 2: extend a set from hand" <|
            \_ ->
                let
                    extendedRun =
                        stack
                            [ bc Five Heart, bc Six Heart, bc Seven Heart, bc Eight Heart ]
                            10
                            10

                    set =
                        stack [ bc King Club, bc King Diamond, bc King Spade ] 10 200

                    extendedSet =
                        stack
                            [ bc King Club, bc King Diamond, bc King Spade, fresh King Heart ]
                            10
                            200
                in
                rule [ extendedRun, set ]
                    { remove = [ set ]
                    , add = [ extendedSet ]
                    , played = [ hc King Heart ]
                    }
                    |> Expect.equal (Ok ())
        , test "move 3: place a new 3-card run from hand" <|
            \_ ->
                let
                    extendedRun =
                        stack
                            [ bc Five Heart, bc Six Heart, bc Seven Heart, bc Eight Heart ]
                            10
                            10

                    extendedSet =
                        stack
                            [ bc King Club, bc King Diamond, bc King Spade, bc King Heart ]
                            10
                            200

                    newRun =
                        stack [ fresh Ace Spade, fresh Two Spade, fresh Three Spade ] 60 10
                in
                rule [ extendedRun, extendedSet ]
                    { remove = []
                    , add = [ newRun ]
                    , played = [ hc Ace Spade, hc Two Spade, hc Three Spade ]
                    }
                    |> Expect.equal (Ok ())
        , test "move 4: pure rearrangement — move the set" <|
            \_ ->
                let
                    extendedSet =
                        stack
                            [ bc King Club, bc King Diamond, bc King Spade, bc King Heart ]
                            10
                            200

                    movedSet =
                        { boardCards = extendedSet.boardCards
                        , loc = { top = 60, left = 200 }
                        }
                in
                rule [ extendedSet ]
                    { remove = [ extendedSet ]
                    , add = [ movedSet ]
                    , played = []
                    }
                    |> Expect.equal (Ok ())
        ]


midturnLeniency : Test
midturnLeniency =
    describe "validateGameMove allows bogus/incomplete/dup mid-turn"
        [ test "mid-turn: bogus stack is accepted" <|
            \_ ->
                let
                    bogus =
                        stack [ fresh Ace Heart, fresh Five Club, fresh King Diamond ] 10 10
                in
                rule []
                    { remove = []
                    , add = [ bogus ]
                    , played = [ hc Ace Heart, hc Five Club, hc King Diamond ]
                    }
                    |> Expect.equal (Ok ())
        , test "turn-complete: bogus stack is rejected (semantics)" <|
            \_ ->
                let
                    bogus =
                        stack [ fresh Ace Heart, fresh Five Club, fresh King Diamond ] 10 10
                in
                case validateTurnComplete [ bogus ] bounds of
                    Err err ->
                        Expect.equal Semantics err.stage

                    Ok _ ->
                        Expect.fail "expected semantics rejection, got Ok"
        , test "mid-turn: incomplete 2-card stack is accepted" <|
            \_ ->
                let
                    incomplete =
                        stack [ fresh Ace Heart, fresh Two Heart ] 10 10
                in
                rule []
                    { remove = []
                    , add = [ incomplete ]
                    , played = [ hc Ace Heart, hc Two Heart ]
                    }
                    |> Expect.equal (Ok ())
        , test "turn-complete: incomplete stack is rejected (semantics)" <|
            \_ ->
                let
                    incomplete =
                        stack [ bc Ace Heart, bc Two Heart ] 10 10
                in
                case validateTurnComplete [ incomplete ] bounds of
                    Err err ->
                        Expect.equal Semantics err.stage

                    Ok _ ->
                        Expect.fail "expected semantics rejection, got Ok"
        , test "mid-turn: dup set (same card from both decks) is accepted" <|
            \_ ->
                let
                    dupSet =
                        stack
                            [ freshDeck Seven Heart DeckOne
                            , freshDeck Seven Heart DeckTwo
                            , fresh Seven Club
                            ]
                            10
                            10
                in
                rule []
                    { remove = []
                    , add = [ dupSet ]
                    , played =
                        [ hcDeck Seven Heart DeckOne
                        , hcDeck Seven Heart DeckTwo
                        , hc Seven Club
                        ]
                    }
                    |> Expect.equal (Ok ())
        , test "turn-complete: dup set is rejected (semantics)" <|
            \_ ->
                let
                    dupSet =
                        stack
                            [ bcDeck Seven Heart DeckOne
                            , bcDeck Seven Heart DeckTwo
                            , bc Seven Club
                            ]
                            10
                            10
                in
                case validateTurnComplete [ dupSet ] bounds of
                    Err err ->
                        Expect.equal Semantics err.stage

                    Ok _ ->
                        Expect.fail "expected semantics rejection, got Ok"
        ]


splitThroughPipeline : Test
splitThroughPipeline =
    describe "split through the pipeline"
        [ test "splitting a run into two halves is accepted" <|
            \_ ->
                let
                    longRun =
                        stack
                            [ bc Three Diamond
                            , bc Four Diamond
                            , bc Five Diamond
                            , bc Six Diamond
                            , bc Seven Diamond
                            , bc Eight Diamond
                            ]
                            10
                            10

                    left =
                        stack [ bc Three Diamond, bc Four Diamond, bc Five Diamond ] 10 10

                    right =
                        stack [ bc Six Diamond, bc Seven Diamond, bc Eight Diamond ] 10 200
                in
                rule [ longRun ]
                    { remove = [ longRun ], add = [ left, right ], played = [] }
                    |> Expect.equal (Ok ())
        ]


stagesAreIndependent : Test
stagesAreIndependent =
    describe "stages are independent (mid-turn bogus accepted; turn-complete rejects)"
        [ test "mid-turn: bogus replacement for a valid run is accepted" <|
            \_ ->
                let
                    validRun =
                        stack [ bc Ace Club, bc Two Club, bc Three Club ] 10 10

                    bogus =
                        stack [ bc Ace Club, fresh Five Diamond, fresh King Heart ] 10 10
                in
                rule [ validRun ]
                    { remove = [ validRun ]
                    , add = [ bogus ]
                    , played = [ hc Five Diamond, hc King Heart ]
                    }
                    |> Expect.equal (Ok ())
        , test "turn-complete: same bogus stack is rejected (semantics)" <|
            \_ ->
                let
                    bogus =
                        stack [ bc Ace Club, bc Five Diamond, bc King Heart ] 10 10
                in
                case validateTurnComplete [ bogus ] bounds of
                    Err err ->
                        Expect.equal Semantics err.stage

                    Ok _ ->
                        Expect.fail "expected semantics rejection, got Ok"
        ]


inventoryTests : Test
inventoryTests =
    describe "inventory stage"
        [ test "rejects a card that appears from nowhere" <|
            \_ ->
                let
                    run =
                        stack [ fresh Ace Heart, fresh Two Heart, fresh Three Heart ] 10 10
                in
                case rule [] { remove = [], add = [ run ], played = [ hc Ace Heart, hc Two Heart ] } of
                    Err err ->
                        Expect.all
                            [ .stage >> Expect.equal Inventory
                            , .message >> String.contains "no source" >> Expect.equal True
                            ]
                            err

                    Ok _ ->
                        Expect.fail "expected inventory rejection, got Ok"
        , test "rejects an unplaced hand card" <|
            \_ ->
                let
                    run =
                        stack [ fresh Ace Heart, fresh Two Heart, fresh Three Heart ] 10 10
                in
                case
                    rule []
                        { remove = []
                        , add = [ run ]
                        , played = [ hc Ace Heart, hc Two Heart, hc Three Heart, hc Four Heart ]
                        }
                of
                    Err err ->
                        Expect.all
                            [ .stage >> Expect.equal Inventory
                            , .message >> String.contains "not placed" >> Expect.equal True
                            ]
                            err

                    Ok _ ->
                        Expect.fail "expected inventory rejection, got Ok"
        , test "allows pure rearrangement (no hand cards needed)" <|
            \_ ->
                let
                    run =
                        stack
                            [ bc Ace Club
                            , bc Two Club
                            , bc Three Club
                            , bc Four Club
                            , bc Five Club
                            , bc Six Club
                            ]
                            10
                            10

                    left =
                        stack [ bc Ace Club, bc Two Club, bc Three Club ] 10 10

                    right =
                        stack [ bc Four Club, bc Five Club, bc Six Club ] 10 200
                in
                rule [ run ] { remove = [ run ], add = [ left, right ], played = [] }
                    |> Expect.equal (Ok ())
        , test "rejects a board with duplicate cards (same value+suit+deck)" <|
            \_ ->
                let
                    run =
                        stack [ bc Ace Heart, bc Two Heart, bc Three Heart ] 10 10

                    setWithDup =
                        stack [ fresh Ace Heart, fresh Ace Club, fresh Ace Diamond ] 60 10
                in
                case
                    rule [ run ]
                        { remove = []
                        , add = [ setWithDup ]
                        , played = [ hc Ace Heart, hc Ace Club, hc Ace Diamond ]
                        }
                of
                    Err err ->
                        Expect.all
                            [ .stage >> Expect.equal Inventory
                            , .message >> String.contains "duplicate" >> Expect.equal True
                            ]
                            err

                    Ok _ ->
                        Expect.fail "expected inventory rejection, got Ok"
        , test "rejects new cards with no hand-played declaration" <|
            \_ ->
                let
                    run =
                        stack [ fresh Ace Heart, fresh Two Heart, fresh Three Heart ] 10 10
                in
                case rule [] { remove = [], add = [ run ], played = [] } of
                    Err err ->
                        Expect.equal Inventory err.stage

                    Ok _ ->
                        Expect.fail "expected inventory rejection, got Ok"
        , test "rejects a remove-reference to a stack not on the board" <|
            \_ ->
                let
                    phantom =
                        stack [ bc Ace Heart, bc Two Heart, bc Three Heart ] 10 10
                in
                case rule [] { remove = [ phantom ], add = [], played = [] } of
                    Err err ->
                        Expect.all
                            [ .stage >> Expect.equal Inventory
                            , .message >> String.contains "not on the board" >> Expect.equal True
                            ]
                            err

                    Ok _ ->
                        Expect.fail "expected inventory rejection, got Ok"
        ]


geometryTests : Test
geometryTests =
    describe "geometry stage"
        [ test "rejects an overlapping stack (mid-turn)" <|
            \_ ->
                let
                    stack1 =
                        stack [ bc Ace Heart, bc Two Heart, bc Three Heart ] 10 10

                    overlapping =
                        stack
                            [ fresh Seven Club, fresh Seven Diamond, fresh Seven Spade ]
                            10
                            10
                in
                case
                    rule [ stack1 ]
                        { remove = []
                        , add = [ overlapping ]
                        , played = [ hc Seven Club, hc Seven Diamond, hc Seven Spade ]
                        }
                of
                    Err err ->
                        Expect.equal Geometry err.stage

                    Ok _ ->
                        Expect.fail "expected geometry rejection, got Ok"
        , test "rejects a stack past the right edge (mid-turn)" <|
            \_ ->
                let
                    outOfBounds =
                        -- A 3-card stack at x=780 extends past maxWidth=800
                        stack [ fresh Ace Heart, fresh Two Heart, fresh Three Heart ] 10 780
                in
                case
                    rule []
                        { remove = []
                        , add = [ outOfBounds ]
                        , played = [ hc Ace Heart, hc Two Heart, hc Three Heart ]
                        }
                of
                    Err err ->
                        Expect.equal Geometry err.stage

                    Ok _ ->
                        Expect.fail "expected geometry rejection, got Ok"
        ]


turnCompleteTests : Test
turnCompleteTests =
    describe "turn completion"
        [ test "clean board of valid stacks is accepted" <|
            \_ ->
                let
                    run =
                        stack [ bc Ace Heart, bc Two Heart, bc Three Heart ] 10 10

                    set =
                        stack [ bc King Club, bc King Diamond, bc King Spade ] 10 200
                in
                validateTurnComplete [ run, set ] bounds
                    |> Expect.equal (Ok ())
        , test "incomplete 2-card stack at turn end is rejected (semantics)" <|
            \_ ->
                let
                    incomplete =
                        stack [ bc Ace Heart, bc Two Heart ] 10 10
                in
                case validateTurnComplete [ incomplete ] bounds of
                    Err err ->
                        Expect.equal Semantics err.stage

                    Ok _ ->
                        Expect.fail "expected semantics rejection, got Ok"
        , test "overlapping stacks at turn end are rejected (geometry)" <|
            \_ ->
                let
                    s1 =
                        stack [ bc Ace Heart, bc Two Heart, bc Three Heart ] 10 10

                    s2 =
                        stack [ bc Seven Club, bc Seven Diamond, bc Seven Spade ] 10 10
                in
                case validateTurnComplete [ s1, s2 ] bounds of
                    Err err ->
                        Expect.equal Geometry err.stage

                    Ok _ ->
                        Expect.fail "expected geometry rejection, got Ok"
        , test "empty board is accepted at turn end" <|
            \_ ->
                validateTurnComplete [] bounds
                    |> Expect.equal (Ok ())
        ]
