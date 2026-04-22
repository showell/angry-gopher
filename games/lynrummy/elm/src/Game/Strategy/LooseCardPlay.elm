module Game.Strategy.LooseCardPlay exposing (trick)

{-| LOOSE_CARD_PLAY: move one board card from its stack onto
another stack, then play a hand card that the new arrangement
accepts.

Mirrors `angry-gopher/lynrummy/tricks/loose_card_play.go`.

-}

import Game.Card exposing (Card)
import Game.CardStack
    exposing
        ( BoardCard
        , CardStack
        , HandCard
        , canExtract
        , leftMerge
        , rightMerge
        , stackType
        )
import Game.StackType exposing (CardStackType(..))
import Game.Strategy.Helpers
    exposing
        ( dummyLoc
        , extractCard
        , freshlyPlayed
        , replaceAt
        , singleStackFromCard
        )
import Game.Strategy.Trick exposing (Play, Trick)


trick : Trick
trick =
    { id = "loose_card_play"
    , description = "Move one board card to a new home, then play a hand card on the resulting board."
    , findPlays = findPlays
    }


type alias LooseMove =
    { srcIdx : Int
    , srcCardIdx : Int
    , srcCard : Card
    , destIdx : Int
    , destCard : Card -- anchor
    , handCard : HandCard
    }


findPlays : List HandCard -> List CardStack -> List Play
findPlays hand board =
    let
        stranded =
            List.filter (\hc -> not (cardExtendsAnyStack hc.card board)) hand
    in
    if List.isEmpty stranded then
        []

    else
        findMoves board stranded


findMoves : List CardStack -> List HandCard -> List Play
findMoves board stranded =
    List.indexedMap Tuple.pair board
        |> List.concatMap
            (\( src, srcStack ) ->
                List.indexedMap Tuple.pair srcStack.boardCards
                    |> List.concatMap
                        (\( ci, bc ) ->
                            if not (canExtract srcStack ci) then
                                []

                            else
                                tryDestinations board stranded src srcStack ci bc.card
                        )
            )


tryDestinations : List CardStack -> List HandCard -> Int -> CardStack -> Int -> Card -> List Play
tryDestinations board stranded src srcStack ci peeled =
    List.indexedMap Tuple.pair board
        |> List.concatMap
            (\( dest, destStack ) ->
                if dest == src then
                    []

                else
                    case firstBoardCard destStack of
                        Nothing ->
                            []

                        Just destAnchor ->
                            let
                                single =
                                    singleStackFromCard peeled
                            in
                            case mergeEitherSide destStack single of
                                Nothing ->
                                    []

                                Just merged ->
                                    if mergedIsProblematic merged then
                                        []

                                    else
                                        case simulateMove board src ci dest merged srcStack of
                                            Nothing ->
                                                []

                                            Just sim ->
                                                stranded
                                                    |> List.filterMap
                                                        (\hc ->
                                                            if cardExtendsAnyStack hc.card sim then
                                                                Just
                                                                    (makePlay
                                                                        { srcIdx = src
                                                                        , srcCardIdx = ci
                                                                        , srcCard = peeled
                                                                        , destIdx = dest
                                                                        , destCard = destAnchor
                                                                        , handCard = hc
                                                                        }
                                                                    )

                                                            else
                                                                Nothing
                                                        )
            )


firstBoardCard : CardStack -> Maybe Card
firstBoardCard stack =
    List.head stack.boardCards |> Maybe.map .card


mergeEitherSide : CardStack -> CardStack -> Maybe CardStack
mergeEitherSide target single =
    case leftMerge target single of
        Just m ->
            Just m

        Nothing ->
            rightMerge target single


mergedIsProblematic : CardStack -> Bool
mergedIsProblematic s =
    let
        t =
            stackType s
    in
    t == Bogus || t == Dup || t == Incomplete


cardExtendsAnyStack : Card -> List CardStack -> Bool
cardExtendsAnyStack card board =
    let
        single =
            singleStackFromCard card
    in
    List.any
        (\s ->
            case leftMerge s single of
                Just _ ->
                    True

                Nothing ->
                    case rightMerge s single of
                        Just _ ->
                            True

                        Nothing ->
                            False
        )
        board


simulateMove :
    List CardStack
    -> Int
    -> Int
    -> Int
    -> CardStack
    -> CardStack
    -> Maybe (List CardStack)
simulateMove board src ci dest merged srcStack =
    case peelIntoResidual srcStack ci of
        Nothing ->
            Nothing

        Just residual ->
            board
                |> replaceAt src residual
                |> replaceAt dest merged
                |> Just


peelIntoResidual : CardStack -> Int -> Maybe CardStack
peelIntoResidual stack cardIdx =
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
    if cardIdx == 0 && n >= 4 then
        Just { boardCards = List.drop 1 cards, loc = stack.loc }

    else if cardIdx == n - 1 && n >= 4 then
        Just { boardCards = List.take (n - 1) cards, loc = stack.loc }

    else if st == Set && n >= 4 then
        Just
            { boardCards =
                List.take cardIdx cards ++ List.drop (cardIdx + 1) cards
            , loc = stack.loc
            }

    else if isRun && cardIdx >= 3 && n - cardIdx - 1 >= 3 then
        Just { boardCards = List.take cardIdx cards, loc = stack.loc }

    else
        Nothing


makePlay : LooseMove -> Play
makePlay m =
    { trickId = "loose_card_play"
    , handCards = [ m.handCard ]
    , apply = applyLooseCardPlay m
    }


applyLooseCardPlay : LooseMove -> List CardStack -> ( List CardStack, List HandCard )
applyLooseCardPlay m board =
    case relocate board m.srcCard of
        Nothing ->
            ( board, [] )

        Just ( srcSi, srcCi ) ->
            let
                destIdx =
                    relocateStack board m.destCard
            in
            if destIdx < 0 || destIdx == srcSi then
                ( board, [] )

            else
                let
                    ( board2, maybePeeled ) =
                        extractCard board srcSi srcCi
                in
                case maybePeeled of
                    Nothing ->
                        ( board, [] )

                    Just peeled ->
                        let
                            destIdxAfter =
                                relocateStack board2 m.destCard
                        in
                        if destIdxAfter < 0 then
                            ( board, [] )

                        else
                            case List.drop destIdxAfter board2 |> List.head of
                                Nothing ->
                                    ( board, [] )

                                Just destStack ->
                                    let
                                        single =
                                            singleStackFromCard peeled.card
                                    in
                                    case mergeEitherSide destStack single of
                                        Nothing ->
                                            ( board, [] )

                                        Just merged ->
                                            if mergedIsProblematic merged then
                                                ( board, [] )

                                            else
                                                let
                                                    board3 =
                                                        replaceAt destIdxAfter merged board2
                                                in
                                                case playHandCardOnBoard m.handCard board3 of
                                                    Just board4 ->
                                                        ( markFreshlyPlayedFor m.handCard board4, [ m.handCard ] )

                                                    Nothing ->
                                                        ( board, [] )


playHandCardOnBoard : HandCard -> List CardStack -> Maybe (List CardStack)
playHandCardOnBoard hc board =
    let
        handSingle =
            singleStackFromCard hc.card

        go i stacks =
            case stacks of
                [] ->
                    Nothing

                s :: rest ->
                    case rightMerge s handSingle of
                        Just ext ->
                            Just (replaceAt i ext board)

                        Nothing ->
                            case leftMerge s handSingle of
                                Just ext ->
                                    Just (replaceAt i ext board)

                                Nothing ->
                                    go (i + 1) rest
    in
    go 0 board


markFreshlyPlayedFor : HandCard -> List CardStack -> List CardStack
markFreshlyPlayedFor hc board =
    List.map
        (\stack ->
            { boardCards =
                List.map
                    (\bc ->
                        if
                            bc.card.value
                                == hc.card.value
                                && bc.card.suit
                                == hc.card.suit
                                && bc.card.originDeck
                                == hc.card.originDeck
                        then
                            freshlyPlayed hc

                        else
                            bc
                    )
                    stack.boardCards
            , loc = stack.loc
            }
        )
        board


relocate : List CardStack -> Card -> Maybe ( Int, Int )
relocate board target =
    let
        go si stacks =
            case stacks of
                [] ->
                    Nothing

                stack :: rest ->
                    case findInStack stack target of
                        Just ci ->
                            Just ( si, ci )

                        Nothing ->
                            go (si + 1) rest
    in
    go 0 board


findInStack : CardStack -> Card -> Maybe Int
findInStack stack target =
    let
        go ci cards =
            case cards of
                [] ->
                    Nothing

                bc :: rest ->
                    if
                        bc.card.value
                            == target.value
                            && bc.card.suit
                            == target.suit
                            && bc.card.originDeck
                            == target.originDeck
                            && canExtract stack ci
                    then
                        Just ci

                    else
                        go (ci + 1) rest
    in
    go 0 stack.boardCards


relocateStack : List CardStack -> Card -> Int
relocateStack board anchor =
    let
        go si stacks =
            case stacks of
                [] ->
                    -1

                stack :: rest ->
                    case List.head stack.boardCards of
                        Just firstCard ->
                            if
                                firstCard.card.value
                                    == anchor.value
                                    && firstCard.card.suit
                                    == anchor.suit
                                    && firstCard.card.originDeck
                                    == anchor.originDeck
                            then
                                si

                            else
                                go (si + 1) rest

                        Nothing ->
                            go (si + 1) rest
    in
    go 0 board
