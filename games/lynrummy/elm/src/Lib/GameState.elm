module Lib.GameState exposing (GameState)

import Lib.CardStack exposing (CardStack)
import Lib.Hand exposing (Hand)
import Lib.Rules.Card exposing (Card)


type alias GameState =
    { board : List CardStack
    , hands : List Hand
    , activePlayerIndex : Int
    , turnIndex : Int
    , deck : List Card
    , cardsPlayedThisTurn : Int
    , victorAwarded : Bool
    }
