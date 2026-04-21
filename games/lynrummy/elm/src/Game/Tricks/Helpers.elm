module Game.Tricks.Helpers exposing
    ( dummyLoc
    , extractCard
    , freshlyPlayed
    , pushNewStack
    , replaceAt
    , singleStackFromCard
    , substituteInStack
    )

{-| Trick-layer helpers. Mirrors
`angry-gopher/lynrummy/tricks/helpers.go`.

All return-new (no mutation). Matches the Go port's divergence
from TS's in-place style — tricks compose atomically on a passed-in
board and return a new board plus whatever they consumed.

-}

import Game.Card exposing (Card)
import Game.CardStack
    exposing
        ( BoardCard
        , BoardCardState(..)
        , BoardLocation
        , CardStack
        , HandCard
        , HandCardState(..)
        , fromHandCard
        , stackType
        )
import Game.StackType exposing (CardStackType(..))


{-| Default location for a freshly-created stack that a trick
appends to the board.
-}
dummyLoc : BoardLocation
dummyLoc =
    { top = 0, left = 0 }


{-| Wrap a HandCard's Card as a newly-placed BoardCard.
-}
freshlyPlayed : HandCard -> BoardCard
freshlyPlayed hc =
    { card = hc.card, state = FreshlyPlayed }


{-| Wrap a raw Card as a singleton CardStack at dummyLoc,
card-state FreshlyPlayed. Used by tricks that route a non-hand
card (e.g., a kicked card) through merge operations.
-}
singleStackFromCard : Card -> CardStack
singleStackFromCard c =
    fromHandCard { card = c, state = HandNormal } dummyLoc


{-| Append a new CardStack (at dummyLoc) holding boardCards.
-}
pushNewStack : List CardStack -> List BoardCard -> List CardStack
pushNewStack board boardCards =
    board ++ [ { boardCards = boardCards, loc = dummyLoc } ]


{-| Replace the card at `position` in `stack` with `newCard`,
preserving loc.
-}
substituteInStack : CardStack -> Int -> BoardCard -> CardStack
substituteInStack stack position newCard =
    let
        updated =
            List.indexedMap
                (\i bc ->
                    if i == position then
                        newCard

                    else
                        bc
                )
                stack.boardCards
    in
    { boardCards = updated, loc = stack.loc }


{-| Remove the card at (stackIdx, cardIdx) from the board and
return (newBoard, Just extractedCard) or (board, Nothing) if the
extraction isn't legal.

Three modes, matching Go:

  - End peel: size >= 4, first/last position
  - Set peel: size >= 4 SET, any middle position
  - Middle peel: run, both halves would be size >= 3

-}
extractCard : List CardStack -> Int -> Int -> ( List CardStack, Maybe BoardCard )
extractCard board stackIdx cardIdx =
    case List.drop stackIdx board |> List.head of
        Nothing ->
            ( board, Nothing )

        Just stack ->
            let
                cards =
                    stack.boardCards

                n =
                    List.length cards

                st =
                    stackType stack

                isRun =
                    st == PureRun || st == RedBlackRun
            in
            -- End peel: first card.
            if cardIdx == 0 && n >= 4 then
                let
                    newStack =
                        { boardCards = List.drop 1 cards, loc = stack.loc }
                in
                ( replaceAt stackIdx newStack board
                , List.head cards
                )

            -- End peel: last card.
            else if cardIdx == n - 1 && n >= 4 then
                let
                    newStack =
                        { boardCards = List.take (n - 1) cards, loc = stack.loc }
                in
                ( replaceAt stackIdx newStack board
                , List.drop (n - 1) cards |> List.head
                )

            -- Set peel: any middle card of a size-4+ SET.
            else if st == Set && n >= 4 then
                let
                    remaining =
                        List.take cardIdx cards ++ List.drop (cardIdx + 1) cards

                    newStack =
                        { boardCards = remaining, loc = stack.loc }

                    extracted =
                        List.drop cardIdx cards |> List.head
                in
                ( replaceAt stackIdx newStack board, extracted )

            -- Middle peel: run, both halves >= 3.
            else if isRun && cardIdx >= 3 && n - cardIdx - 1 >= 3 then
                let
                    leftHalf =
                        { boardCards = List.take cardIdx cards, loc = stack.loc }

                    rightHalf =
                        { boardCards = List.drop (cardIdx + 1) cards, loc = dummyLoc }

                    extracted =
                        List.drop cardIdx cards |> List.head

                    newBoard =
                        replaceAt stackIdx leftHalf board ++ [ rightHalf ]
                in
                ( newBoard, extracted )

            else
                ( board, Nothing )


{-| Replace element at index in a list. Noop if index out of
range.
-}
replaceAt : Int -> a -> List a -> List a
replaceAt idx x list =
    List.indexedMap
        (\i y ->
            if i == idx then
                x

            else
                y
        )
        list
