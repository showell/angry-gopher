module Game.Agent.Cards exposing
    ( isLegalStack
    , isPartialOk
    , neighbors
    )

{-| Agent-side card predicates the BFS planner consumes.

`isLegalStack` is a thin filter on top of
`Game.Rules.StackType.getStackType`. `isPartialOk` and `neighbors`
have no existing Elm equivalent — ported from
`python/beginner.py`.

-}

import Game.Rules.Card
    exposing
        ( Card
        , CardValue
        , Suit
        , allSuits
        , cardColor
        , suitColor
        )
import Game.Rules.StackType as StackType
    exposing
        ( CardStackType(..)
        , predecessor
        , successor
        )


{-| True iff the stack classifies as a complete legal group:
Set, PureRun, or RedBlackRun. Anything else (incomplete,
bogus, dup) is treated as "other" by the agent.
-}
isLegalStack : List Card -> Bool
isLegalStack stack =
    case StackType.getStackType stack of
        Set ->
            True

        PureRun ->
            True

        RedBlackRun ->
            True

        _ ->
            False


{-| True if the stack could legally extend into a complete
group:

  - Length 0 or 1: trivially OK (empty / lone card).
  - Length 2: OK iff the pair is consistent with some
    legal stack type (pure-run partial, rb-run partial, or
    set partial).
  - Length 3+: defer to `isLegalStack`.

-}
isPartialOk : List Card -> Bool
isPartialOk stack =
    case stack of
        [] ->
            True

        [ _ ] ->
            True

        [ a, b ] ->
            isPairOk a b

        _ ->
            isLegalStack stack


isPairOk : Card -> Card -> Bool
isPairOk a b =
    let
        sameValue =
            a.value == b.value

        sameSuit =
            a.suit == b.suit

        consecutive =
            successor a.value == b.value
    in
    if sameValue && not sameSuit then
        -- Set partial.
        True

    else if consecutive && sameSuit then
        -- Pure-run partial.
        True

    else if consecutive && cardColor a /= cardColor b then
        -- Red-black-run partial.
        True

    else
        False


{-| Every (value, suit) shape that could sit adjacent to `c`
in some legal group. Deck-agnostic — the BFS doesn't care
which deck a candidate card comes from at this stage.

  - Pure-run partners: same suit, ±1 value.
  - Red-black-run partners: opposite color, ±1 value.
  - Set partners: same value, different suit.

-}
neighbors : Card -> List ( CardValue, Suit )
neighbors c =
    let
        pred =
            predecessor c.value

        succ =
            successor c.value

        cColor =
            cardColor c

        oppositeColorSuits =
            List.filter (\s -> suitColor s /= cColor) allSuits

        sameValueOtherSuits =
            List.filter (\s -> s /= c.suit) allSuits

        pureRunPartners =
            [ ( pred, c.suit ), ( succ, c.suit ) ]

        rbRunPartners =
            List.concatMap
                (\s -> [ ( pred, s ), ( succ, s ) ])
                oppositeColorSuits

        setPartners =
            List.map (\s -> ( c.value, s )) sameValueOtherSuits
    in
    pureRunPartners ++ rbRunPartners ++ setPartners
