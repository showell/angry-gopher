module Game.Rules.StackType exposing
    ( CardStackType(..)
    , getStackType
    , isLegalStack
    , isPartialOk
    , neighbors
    , predecessor
    , successor
    , valueDistance
    )

{-| Stack classification: given a list of cards (in order),
what kind of stack do they form? Ported from
`angry-cat/src/lyn_rummy/core/stack_type.ts`.

Layout follows the TS source: `successor`, `predecessor`, and
`valueDistance` live here (not in `Game.Rules.Card`) because the
TS organization makes the same choice. Source-parity matters
more than idiom during the port phase.

The pure rule predicates `isLegalStack`, `isPartialOk`, and
`neighbors` also live here. They were originally hosted in
`Game.Agent.Cards` while the BFS planner was the only caller,
but they encode rules of legal stack shape, not agent strategy
— this is their natural home. (Moved 2026-04-28.)

-}

import Game.Rules.Card
    exposing
        ( Card
        , CardValue(..)
        , Suit
        , allSuits
        , cardColor
        , cardValueToInt
        , isPairOfDups
        , suitColor
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


{-| Inverse of successor: Ace -> King, 2 -> Ace, etc.
-}
predecessor : CardValue -> CardValue
predecessor v =
    case v of
        Ace ->
            King

        Two ->
            Ace

        Three ->
            Two

        Four ->
            Three

        Five ->
            Four

        Six ->
            Five

        Seven ->
            Six

        Eight ->
            Seven

        Nine ->
            Eight

        Ten ->
            Nine

        Jack ->
            Ten

        Queen ->
            Jack

        King ->
            Queen


{-| Circular distance between two card values. The deck is
treated as a 13-cycle (A through K, with K wrapping back to A),
so the distance is the minimum number of value-steps in either
direction. A<->A is 0, A<->K and A<->2 are 1, A<->Q and A<->3
are 2, etc. The maximum possible distance is 6 (e.g. 2<->9 or
3<->T).
-}
valueDistance : CardValue -> CardValue -> Int
valueDistance a b =
    let
        diff =
            abs (cardValueToInt a - cardValueToInt b)
    in
    min diff (13 - diff)



-- CLASSIFICATION


{-| Classify a two-card pair. Returns the "provisional" stack
type that the pair *starts*. Does NOT return `Incomplete` — in
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
(same value+suit, ignoring origin_deck).
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
-- Pure predicates over legal stack shape. Originally hosted
-- in Game.Agent.Cards while the BFS planner was the only
-- caller; lifted into Rules/ at the rules-lockdown migration.


{-| True iff the stack classifies as a complete legal group:
Set, PureRun, or RedBlackRun. Anything else (incomplete,
bogus, dup) is treated as "other".
-}
isLegalStack : List Card -> Bool
isLegalStack stack =
    case getStackType stack of
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
in some legal group. Deck-agnostic — callers don't care which
deck a candidate card comes from at this stage.

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
