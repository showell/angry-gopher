module Lib.GameState exposing (GameState)

import Lib.CardStack exposing (CardStack)
import Lib.Hand exposing (Hand)
import Lib.Player exposing (Player)
import Lib.Rules.Card exposing (Card)


type alias GameState =
    { board : List CardStack
    , humanHand : Hand
    , agentHand : Hand
    , activePlayer : Player
    , turnIndex : Int
    , deck : List Card
    , cardsPlayedThisTurn : Int
    , victorAwarded : Bool
    }
