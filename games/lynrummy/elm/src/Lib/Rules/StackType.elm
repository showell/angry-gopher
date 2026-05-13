module Lib.Rules.StackType exposing
    ( CardStackType(..)
    , getStackType
    )

{-| Stack classification: given a list of cards (in order),
what kind of stack do they form? Ported from
`angry-cat/src/lyn_rummy/core/stack_type.ts`.

Layout follows the TS source: `successor`, `predecessor`, and
`valueDistance` live here (not in `Lib.Rules.Card`) because the
TS organization makes the same choice. Source-parity matters
more than idiom during the port phase.

The pure rule predicates `isLegalStack`, `isPartialOk`, and
`neighbors` also live here — they encode rules of legal stack
shape, not agent strategy.

-}

import Lib.Rules.Card
    exposing
        ( Card
        , CardValue(..)
        , cardColor
        , isPairOfDups
        )



-- STACK TYPE


type CardStackType
    = Incomplete
    | Bogus
    | Dup
    | Set
    | PureRun
    | RedBlackRun



-- CARD VALUE NEIGHBOR FUNCTIONS


{-| Successor wraps: King -> Ace. K, A, 2 is a valid run in
LynRummy because successor(King) = Ace and successor(Ace) = Two.
-}
successor : CardValue -> CardValue
successor v =
    case v of
        Ace ->
            Two

        Two ->
            Three

        Three ->
            Four

        Four ->
            Five

        Five ->
            Six

        Six ->
            Seven

        Seven ->
            Eight

        Eight ->
            Nine

        Nine ->
            Ten

        Ten ->
            Jack

        Jack ->
            Queen

        Queen ->
            King

        King ->
            Ace



-- CLASSIFICATION


{-| Classify a two-card pair. Returns the "provisional" stack
type that the pair _starts_. Does NOT return `Incomplete` — in
the pair context, the caller knows it's incomplete by shape.
Order matters for the successor check.
-}
cardPairStackType : Card -> Card -> CardStackType
cardPairStackType a b =
    if isPairOfDups a b then
        Dup

    else if a.value == b.value then
        Set

    else if b.value == successor a.value then
        -- Order is important for the successor check!
        if a.suit == b.suit then
            PureRun

        else if cardColor a /= cardColor b then
            RedBlackRun

        else
            Bogus

    else
        Bogus


{-| True if any pair of cards in the list are dups
(same value+suit, ignoring origin\_deck).
-}
hasDuplicateCards : List Card -> Bool
hasDuplicateCards cards =
    case cards of
        [] ->
            False

        first :: rest ->
            List.any (isPairOfDups first) rest
                || hasDuplicateCards rest


{-| True if every adjacent pair in the list classifies as the
same stack type. (Lists of length 0 or 1 trivially pass.)
-}
isFollowsConsistentPattern : CardStackType -> List Card -> Bool
isFollowsConsistentPattern stackType cards =
    case cards of
        a :: b :: rest ->
            (cardPairStackType a b == stackType)
                && isFollowsConsistentPattern stackType (b :: rest)

        _ ->
            True


{-| THIS IS THE MOST IMPORTANT FUNCTION OF THE GAME.

This determines the whole logic of Lyn Rummy.

You have to have valid, complete stacks, and sets can have
no dups!

-}
getStackType : List Card -> CardStackType
getStackType cards =
    case cards of
        [] ->
            Incomplete

        [ _ ] ->
            Incomplete

        a :: b :: _ ->
            let
                provisional =
                    cardPairStackType a b
            in
            case provisional of
                Bogus ->
                    Bogus

                Dup ->
                    Dup

                _ ->
                    if List.length cards == 2 then
                        Incomplete

                    else if provisional == Set && hasDuplicateCards cards then
                        -- Prevent dups within a provisional SET.
                        Dup

                    else if not (isFollowsConsistentPattern provisional cards) then
                        -- Prevent mixing up types of stacks.
                        Bogus

                    else
                        -- HAPPY PATH! We have a stack that can stay
                        -- on the board!
                        provisional



-- RULE PREDICATES
--
-- Pure predicates over legal stack shape.
