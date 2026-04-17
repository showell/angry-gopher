module LynRummy.Dealer exposing (initialBoard)

{-| Opening-board factory. Produces the six hardcoded stacks
at formula-derived positions. Faithful port of
`Dealer.build_initial_board` inside
`angry-cat/src/lyn_rummy/game/game.ts` (line 291).

TS threads cards through a deck via `pull_from_deck`; Elm
constructs stacks directly via `fromShorthand`. Same resulting
`CardStack` shape.

-}

import LynRummy.Card exposing (OriginDeck(..))
import LynRummy.CardStack as CardStack exposing (BoardLocation, CardStack)


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
