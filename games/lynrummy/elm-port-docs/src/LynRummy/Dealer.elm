module LynRummy.Dealer exposing (initialBoard, openingHand)

{-| Opening-board + opening-hand factory. Produces the six
hardcoded board stacks at formula-derived positions, and a
15-card canned hand. Faithful-enough port of
`Dealer.build_initial_board` inside
`angry-cat/src/lyn_rummy/game/game.ts` (line 291); the hand
is not from TS — it's a test fixture for the hand-to-board
drag milestone.

TS threads cards through a deck via `pull_from_deck`; Elm
constructs stacks and hand cards directly. Same resulting
`CardStack` and `HandCard` shapes.

-}

import LynRummy.Card as Card exposing (Card, OriginDeck(..))
import LynRummy.CardStack as CardStack exposing (BoardLocation, CardStack)
import LynRummy.Hand as Hand exposing (Hand)



-- BOARD


{-| The six-stack hardcoded opening board.
-}
initialBoard : List CardStack
initialBoard =
    List.indexedMap stackFromRow openingShorthands
        |> List.filterMap identity


openingShorthands : List String
openingShorthands =
    [ "KS,AS,2S,3S"
    , "TD,JD,QD,KD"
    , "2H,3H,4H"
    , "7S,7D,7C"
    , "AC,AD,AH"
    , "2C,3D,4C,5H,6S,7H"
    ]


stackFromRow : Int -> String -> Maybe CardStack
stackFromRow row sig =
    CardStack.fromShorthand sig DeckOne (rowLoc row)


rowLoc : Int -> BoardLocation
rowLoc row =
    let
        col =
            modBy 5 (row * 3 + 1)
    in
    { top = 20 + row * 60
    , left = 40 + col * 30
    }



-- HAND


{-| Canned 15-card hand for the hand-to-board drag milestone.
Includes 7H, 8C, 4S (our known drag testers — all three have
legal merges against the initial board). Other 12 are a grab
bag: 9D and QS also extend existing runs; the rest are loose
cards with no merges to exercise the "land as singleton"
path.
-}
openingHand : Hand
openingHand =
    let
        -- Hand uses DeckTwo so 7H in the hand doesn't collide with
        -- the 7H in the initial board's 6-run (DeckOne). Both-deck
        -- sources are idiomatic in double-deck LynRummy.
        cards =
            List.filterMap (\label -> Card.cardFromLabel label DeckTwo) openingHandLabels
    in
    Hand.addCards cards CardStack.HandNormal Hand.empty


openingHandLabels : List String
openingHandLabels =
    [ "7H"
    , "8C"
    , "4S"
    , "9D"
    , "QS"
    , "KH"
    , "JH"
    , "6H"
    , "TS"
    , "5D"
    , "8H"
    , "3C"
    , "2D"
    , "9C"
    , "6C"
    ]
