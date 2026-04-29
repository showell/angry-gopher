module Game.Strategy.RbSwap exposing (trick)

{-| RB\_SWAP ("substitute trick"): kick a same-value, same-color,
different-suit card out of an rb run and slot the hand card into
its seat. The kicked card must find a home on a pure run or a
not-yet-full set.

Mirrors `angry-gopher/lynrummy/tricks/rb_swap.go`.

-}

import Game.Rules.Card exposing (Card, suitColor)
import Game.CardStack
    exposing
        ( BoardCardState(..)
        , CardStack
        , HandCard
        , leftMerge
        , rightMerge
        , stackType
        )
import Game.Rules.StackType exposing (CardStackType(..), getStackType)
import Game.Strategy.Helpers
    exposing
        ( freshlyPlayed
        , replaceAt
        , singleStackFromCard
        , substituteInStack
        )
import Game.Strategy.Trick exposing (Play, Trick)


trick : Trick
trick =
    { id = "rb_swap"
    , description = "Substitute your card for a same-color one in an rb run; the kicked card goes to a set or pure run."
    , findPlays = findPlays
    }


findPlays : List HandCard -> List CardStack -> List Play
findPlays hand board =
    List.concatMap (\hc -> findPlaysForHandCard hc board) hand


findPlaysForHandCard : HandCard -> List CardStack -> List Play
findPlaysForHandCard hc board =
    List.indexedMap Tuple.pair board
        |> List.concatMap
            (\( si, stack ) ->
                if stackType stack /= RedBlackRun then
                    []

                else
                    findSeats hc si stack board
            )


findSeats : HandCard -> Int -> CardStack -> List CardStack -> List Play
findSeats hc si stack board =
    let
        cards =
            List.map .card stack.boardCards

        handColor =
            suitColor hc.card.suit
    in
    List.indexedMap Tuple.pair cards
        |> List.concatMap
            (\( ci, bc ) ->
                if
                    bc.value
                        == hc.card.value
                        && suitColor bc.suit
                        == handColor
                        && bc.suit
                        /= hc.card.suit
                then
                    let
                        swapped =
                            List.indexedMap
                                (\i c ->
                                    if i == ci then
                                        hc.card

                                    else
                                        c
                                )
                                cards
                    in
                    if getStackType swapped == RedBlackRun then
                        case findKickedHome board si bc of
                            Just homeIdx ->
                                [ makePlay hc si ci bc homeIdx ]

                            Nothing ->
                                []

                    else
                        []

                else
                    []
            )


findKickedHome : List CardStack -> Int -> Card -> Maybe Int
findKickedHome board skip kicked =
    let
        go j stacks =
            case stacks of
                [] ->
                    Nothing

                target :: rest ->
                    if j == skip then
                        go (j + 1) rest

                    else if isValidSwapTarget target kicked then
                        Just j

                    else
                        go (j + 1) rest
    in
    go 0 board


isValidSwapTarget : CardStack -> Card -> Bool
isValidSwapTarget target kicked =
    let
        tst =
            stackType target
    in
    if tst == Set && List.length target.boardCards < 4 then
        case List.head target.boardCards of
            Just firstCard ->
                if firstCard.card.value == kicked.value then
                    let
                        hasSuit =
                            List.any (\bc -> bc.card.suit == kicked.suit) target.boardCards
                    in
                    not hasSuit

                else
                    False

            Nothing ->
                False

    else if tst == PureRun then
        let
            single =
                singleStackFromCard kicked
        in
        case leftMerge target single of
            Just _ ->
                True

            Nothing ->
                case rightMerge target single of
                    Just _ ->
                        True

                    Nothing ->
                        False

    else
        False


makePlay : HandCard -> Int -> Int -> Card -> Int -> Play
makePlay hc runIdx runPos kicked homeIdx =
    { trickId = "rb_swap"
    , handCards = [ hc ]
    , apply = applyRbSwap hc runIdx runPos kicked homeIdx
    }


applyRbSwap :
    HandCard
    -> Int
    -> Int
    -> Card
    -> Int
    -> List CardStack
    -> ( List CardStack, List HandCard )
applyRbSwap hc runIdx runPos kicked homeIdx board =
    case ( listGet runIdx board, listGet homeIdx board ) of
        ( Just runStack, Just _ ) ->
            if stackType runStack /= RedBlackRun then
                ( board, [] )

            else
                case List.drop runPos runStack.boardCards |> List.head of
                    Nothing ->
                        ( board, [] )

                    Just current ->
                        if
                            current.card.value
                                == kicked.value
                                && current.card.suit
                                == kicked.suit
                                && current.card.originDeck
                                == kicked.originDeck
                        then
                            let
                                substituted =
                                    substituteInStack runStack runPos (freshlyPlayed hc)

                                board2 =
                                    replaceAt runIdx substituted board
                            in
                            case placeKicked board2 homeIdx kicked of
                                Just board3 ->
                                    ( board3, [ hc ] )

                                Nothing ->
                                    ( board, [] )

                        else
                            ( board, [] )

        _ ->
            ( board, [] )


placeKicked : List CardStack -> Int -> Card -> Maybe (List CardStack)
placeKicked board destIdx kicked =
    case listGet destIdx board of
        Nothing ->
            Nothing

        Just dest ->
            if stackType dest == Set then
                let
                    newCards =
                        dest.boardCards
                            ++ [ { card = kicked, state = FirmlyOnBoard } ]

                    newStack =
                        { boardCards = newCards, loc = dest.loc }
                in
                Just (replaceAt destIdx newStack board)

            else
                let
                    single =
                        singleStackFromCard kicked
                in
                case leftMerge dest single of
                    Just merged ->
                        Just (replaceAt destIdx merged board)

                    Nothing ->
                        case rightMerge dest single of
                            Just merged ->
                                Just (replaceAt destIdx merged board)

                            Nothing ->
                                Nothing


listGet : Int -> List a -> Maybe a
listGet idx list =
    List.drop idx list |> List.head
