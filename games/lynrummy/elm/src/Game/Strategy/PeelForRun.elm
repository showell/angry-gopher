module Game.Strategy.PeelForRun exposing (trick)

{-| PEEL_FOR_RUN: a hand card of value V finds two extractable
board cards at values V-1 and V+1 such that the three form a
valid 3-card run (pure or rb).

Mirrors `angry-gopher/lynrummy/tricks/peel_for_run.go`.

-}

import Game.Card exposing (Card, cardValueToInt)
import Game.CardStack exposing (CardStack, HandCard, canExtract)
import Game.StackType
    exposing
        ( CardStackType(..)
        , getStackType
        , predecessor
        , successor
        )
import Game.Strategy.Helpers exposing (extractCard, freshlyPlayed, pushNewStack)
import Game.Strategy.Trick exposing (Play, Trick)


trick : Trick
trick =
    { id = "peel_for_run"
    , description = "Peel two adjacent-value board cards to form a new run with your hand card."
    , findPlays = findPlays
    }


type alias Neighbor =
    { stackIdx : Int
    , cardIdx : Int
    , card : Card
    }


findPlays : List HandCard -> List CardStack -> List Play
findPlays hand board =
    List.concatMap (\hc -> findPlaysForHandCard hc board) hand


findPlaysForHandCard : HandCard -> List CardStack -> List Play
findPlaysForHandCard hc board =
    let
        prevV =
            predecessor hc.card.value

        nextV =
            successor hc.card.value

        prevs =
            findPeelableAtValue board prevV hc.card

        nexts =
            findPeelableAtValue board nextV hc.card
    in
    List.concatMap
        (\p ->
            List.filterMap
                (\n ->
                    if p.stackIdx == n.stackIdx then
                        Nothing

                    else
                        let
                            trio =
                                [ p.card, hc.card, n.card ]

                            t =
                                getStackType trio
                        in
                        if t == PureRun || t == RedBlackRun then
                            Just (makePlay hc p.card n.card)

                        else
                            Nothing
                )
                nexts
        )
        prevs


findPeelableAtValue :
    List CardStack
    -> Game.Card.CardValue
    -> Card
    -> List Neighbor
findPeelableAtValue board value exclude =
    List.indexedMap Tuple.pair board
        |> List.concatMap
            (\( si, stack ) ->
                List.indexedMap Tuple.pair stack.boardCards
                    |> List.filterMap
                        (\( ci, bc ) ->
                            if
                                bc.card.value
                                    == value
                                    && not (cardsEqual bc.card exclude)
                                    && canExtract stack ci
                            then
                                Just { stackIdx = si, cardIdx = ci, card = bc.card }

                            else
                                Nothing
                        )
            )


cardsEqual : Card -> Card -> Bool
cardsEqual a b =
    a.value == b.value && a.suit == b.suit && a.originDeck == b.originDeck


makePlay : HandCard -> Card -> Card -> Play
makePlay hc targetPrev targetNext =
    { trickId = "peel_for_run"
    , handCards = [ hc ]
    , apply = applyPeelForRun hc targetPrev targetNext
    }


applyPeelForRun : HandCard -> Card -> Card -> List CardStack -> ( List CardStack, List HandCard )
applyPeelForRun hc targetPrev targetNext board =
    case ( relocate board targetPrev, relocate board targetNext ) of
        ( Just ( siPrev, ciPrev ), Just ( siNext, ciNext ) ) ->
            if siPrev == siNext then
                ( board, [] )

            else
                let
                    -- Extract higher (stackIdx, cardIdx) first so
                    -- the earlier index stays valid.
                    extractPrevFirst =
                        siPrev > siNext || (siPrev == siNext && ciPrev > ciNext)

                    ( firstSi, firstCi, secondTarget ) =
                        if extractPrevFirst then
                            ( siPrev, ciPrev, targetNext )

                        else
                            ( siNext, ciNext, targetPrev )

                    ( board2, maybeExt0 ) =
                        extractCard board firstSi firstCi
                in
                case maybeExt0 of
                    Nothing ->
                        ( board, [] )

                    Just ext0 ->
                        case relocate board2 secondTarget of
                            Nothing ->
                                ( board, [] )

                            Just ( secondSi, secondCi ) ->
                                let
                                    ( board3, maybeExt1 ) =
                                        extractCard board2 secondSi secondCi
                                in
                                case maybeExt1 of
                                    Nothing ->
                                        ( board, [] )

                                    Just ext1 ->
                                        let
                                            trio =
                                                [ freshlyPlayed hc, ext0, ext1 ]
                                                    |> List.sortBy (.card >> .value >> cardValueToInt)
                                        in
                                        ( pushNewStack board3 trio
                                        , [ hc ]
                                        )

        _ ->
            ( board, [] )


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
                    if cardsEqual bc.card target && canExtract stack ci then
                        Just ci

                    else
                        go (ci + 1) rest
    in
    go 0 stack.boardCards
