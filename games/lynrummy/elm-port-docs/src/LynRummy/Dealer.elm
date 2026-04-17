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
    (List.indexedMap stackFromRow openingShorthands
        |> List.filterMap identity
    )
        ++ List.filterMap identity dragTestSingletons


{-| THROWAWAY: three single-card stacks parked on the right
for drag-to-merge testing. 7H merges with the 6-run
"2C,3D,4C,5H,6S,7H" (already ends in 7H — pair peel / set
bait). 8C is a loose card. 4S extends the spade run at row 0.
Remove once drag-drop UI is baked.
-}
dragTestSingletons : List (Maybe CardStack)
dragTestSingletons =
    [ CardStack.fromShorthand "7H" DeckOne { top = 40, left = 400 }
    , CardStack.fromShorthand "8C" DeckOne { top = 140, left = 400 }
    , CardStack.fromShorthand "4S" DeckOne { top = 240, left = 400 }
    ]


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
