module Game.Hand exposing
    ( Hand
    , addCards
    , empty
    , removeHandCard
    , resetState
    , size
    )

{-| Faithful port of the `Hand` class in
`angry-cat/src/lyn_rummy/game/game.ts:322`. A hand holds a
list of `HandCard`s; operations add, remove, reset state, and
query.
-}

import Game.Rules.Card exposing (Card)
import Game.CardStack exposing (HandCard, HandCardState(..), isHandCardSameCard)


type alias Hand =
    { handCards : List HandCard }


empty : Hand
empty =
    { handCards = [] }


size : Hand -> Int
size h =
    List.length h.handCards


addCards : List Card -> HandCardState -> Hand -> Hand
addCards cards state h =
    let
        newHandCards =
            List.map (\c -> { card = c, state = state }) cards
    in
    { h | handCards = h.handCards ++ newHandCards }


{-| Remove the first hand card with the same card-identity as
the target. Mirrors TS's behavior: first match wins, silently
no-op if not present (TS throws; Elm avoids the exception —
the caller should be sure the card is present).
-}
removeHandCard : HandCard -> Hand -> Hand
removeHandCard target h =
    { h | handCards = removeFirstMatch target h.handCards }


removeFirstMatch : HandCard -> List HandCard -> List HandCard
removeFirstMatch target cards =
    case cards of
        [] ->
            []

        c :: rest ->
            if isHandCardSameCard c target then
                rest

            else
                c :: removeFirstMatch target rest


{-| Called after the player's turn ends. Resets every hand
card to `HandNormal`. No turn logic in the current game, but
the function is port-complete.
-}
resetState : Hand -> Hand
resetState h =
    { h
        | handCards =
            List.map (\hc -> { hc | state = HandNormal }) h.handCards
    }
