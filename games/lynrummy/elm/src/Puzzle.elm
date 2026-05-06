module Puzzle exposing (main)

{-| Puzzle V1 — read-only single-puzzle render.

The minimum viable puzzle: draw three hard-coded stacks on
the standard board shell. No drag, no replay, no buttons,
no engine, no model beyond the static stack list itself.

This is the first "second consumer" of game-side components
post-puzzle-rip — the entire app fits in one file because the
extraction work has reduced "render a board" to one function
call against `Main.BoardView.viewBoard`.

Future iterations will add interaction (drag → place → reset),
hint, agent-play, replay. Each addition forces another
extract-and-share pass on the game side.

-}

import Browser
import Game.CardStack exposing (BoardCardState(..), CardStack)
import Game.Rules.Card exposing (CardValue(..), OriginDeck(..), Suit(..))
import Html exposing (Html)
import Main.BoardView as BoardView


main : Program () () msg
main =
    Browser.sandbox
        { init = ()
        , update = \_ () -> ()
        , view = view
        }


view : () -> Html msg
view () =
    BoardView.viewBoard puzzleStacks



-- THE PUZZLE
--
-- Three stacks: 7♥ 8♥ 9♥ (a 3-card pure hearts run), K♣ A♣ 2♣
-- (a wrapped 3-card spade run? — no, clubs), and a singleton
-- Q♣. Hard-coded board positions chosen to leave the board
-- visibly readable.


puzzleStacks : List CardStack
puzzleStacks =
    [ stackAt 100 100
        [ ( Seven, Heart )
        , ( Eight, Heart )
        , ( Nine, Heart )
        ]
    , stackAt 220 100
        [ ( King, Club )
        , ( Ace, Club )
        , ( Two, Club )
        ]
    , stackAt 340 100
        [ ( Queen, Club )
        ]
    ]


stackAt : Int -> Int -> List ( CardValue, Suit ) -> CardStack
stackAt top left valuesAndSuits =
    { boardCards =
        List.map
            (\( v, s ) ->
                { card = { value = v, suit = s, originDeck = DeckOne }
                , state = FirmlyOnBoard
                }
            )
            valuesAndSuits
    , loc = { top = top, left = left }
    }
