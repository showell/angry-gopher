module Game.Hand exposing
    ( Hand
    , activeHand
    , addCards
    , addHandCards
    , empty
    , findHandCard
    , removeHandCard
    , resetState
    , setActiveHand
    , size
    , sortIntoSuitRows
    )

{-| Faithful port of the `Hand` class in
`angry-cat/src/lyn_rummy/game/game.ts:322`. A hand holds a
list of `HandCard`s; operations add, remove, reset state, and
query.
-}

import Game.Rules.Card as Card exposing (Card, Suit)
import Game.CardStack exposing (HandCard, HandCardState(..), isHandCardSameCard)


type alias Hand =
    { handCards : List HandCard }


{-| Find a hand card by content identity (ignores state). The
wire's `Card` references identify a hand card; the actual
`HandCard` record on the hand carries the mutable state that
matters for rendering.
-}
findHandCard : Card -> Hand -> Maybe HandCard
findHandCard card hand =
    hand.handCards
        |> List.filter (\hc -> isHandCardSameCard hc { card = card, state = HandNormal })
        |> List.head


{-| Active hand of any state record carrying `hands` and
`activePlayerIndex`. Empty-hand fallback keeps callers
resilient if state hasn't populated yet (the bridge-bug log
happens at the call sites that care).
-}
activeHand : { a | activePlayerIndex : Int, hands : List Hand } -> Hand
activeHand state =
    state.hands
        |> List.drop state.activePlayerIndex
        |> List.head
        |> Maybe.withDefault empty


{-| Replace the active player's hand on the state.
-}
setActiveHand :
    Hand
    -> { a | activePlayerIndex : Int, hands : List Hand }
    -> { a | activePlayerIndex : Int, hands : List Hand }
setActiveHand newHand state =
    { state
        | hands =
            List.indexedMap
                (\i h ->
                    if i == state.activePlayerIndex then
                        newHand

                    else
                        h
                )
                state.hands
    }


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


addHandCards : List HandCard -> Hand -> Hand
addHandCards cards h =
    { h | handCards = h.handCards ++ cards }


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


{-| Group a hand into display rows — one row per non-empty
suit, in `Card.allSuits` order (Heart, Spade, Diamond, Club),
each row sorted ascending by value. The hand UI
(`Game.View.viewHand`) and the hand DSL encoder
(`Game.HandDsl.formatHand`) both consume this so the layout
is byte-canonical across surfaces.
-}
sortIntoSuitRows : Hand -> List ( Suit, List HandCard )
sortIntoSuitRows hand =
    Card.allSuits
        |> List.filterMap (suitRow hand.handCards)


suitRow : List HandCard -> Suit -> Maybe ( Suit, List HandCard )
suitRow handCards suit =
    case
        handCards
            |> List.filter (\hc -> hc.card.suit == suit)
            |> List.sortBy (\hc -> Card.cardValueToInt hc.card.value)
    of
        [] ->
            Nothing

        cards ->
            Just ( suit, cards )


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
