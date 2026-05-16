module Lib.Player exposing (Player(..), otherPlayer)


type Player
    = Human
    | Agent


otherPlayer : Player -> Player
otherPlayer p =
    case p of
        Human ->
            Agent

        Agent ->
            Human
