module Game.Strategy.DirectPlay exposing (trick)

{-| DIRECT_PLAY: a hand card extends an existing board stack at
one of its ends. The simplest trick.

Mirrors `angry-gopher/lynrummy/tricks/direct_play.go`.

-}

import Game.CardStack
    exposing
        ( CardStack
        , HandCard
        , fromHandCard
        , leftMerge
        , rightMerge
        )
import Game.Strategy.Helpers exposing (dummyLoc, replaceAt)
import Game.Strategy.Trick exposing (Play, Trick)


trick : Trick
trick =
    { id = "direct_play"
    , description = "Play a hand card onto the end of a stack."
    , findPlays = findPlays
    }


findPlays : List HandCard -> List CardStack -> List Play
findPlays hand board =
    List.concatMap
        (\hc -> findPlaysForHandCard hc board)
        hand


findPlaysForHandCard : HandCard -> List CardStack -> List Play
findPlaysForHandCard hc board =
    let
        single =
            fromHandCard hc dummyLoc
    in
    List.indexedMap Tuple.pair board
        |> List.filterMap
            (\( idx, stack ) ->
                case rightMerge stack single of
                    Just _ ->
                        Just (makePlay hc idx)

                    Nothing ->
                        case leftMerge stack single of
                            Just _ ->
                                Just (makePlay hc idx)

                            Nothing ->
                                Nothing
            )


makePlay : HandCard -> Int -> Play
makePlay hc targetIdx =
    { trickId = "direct_play"
    , handCards = [ hc ]
    , apply = applyDirectPlay hc targetIdx
    }


applyDirectPlay : HandCard -> Int -> List CardStack -> ( List CardStack, List HandCard )
applyDirectPlay hc targetIdx board =
    let
        single =
            fromHandCard hc dummyLoc
    in
    case List.drop targetIdx board |> List.head of
        Nothing ->
            ( board, [] )

        Just targetStack ->
            case mergeEitherSide targetStack single of
                Just merged ->
                    ( replaceAt targetIdx merged board, [ hc ] )

                Nothing ->
                    ( board, [] )


{-| Prefer right-merge when both would work — matches the TS / Go
convention.
-}
mergeEitherSide : CardStack -> CardStack -> Maybe CardStack
mergeEitherSide target single =
    case rightMerge target single of
        Just m ->
            Just m

        Nothing ->
            leftMerge target single
