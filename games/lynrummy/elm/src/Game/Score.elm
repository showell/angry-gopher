module Game.Score exposing
    ( forCardsPlayed
    , forStack
    , forStacks
    , stackTypeValue
    )

{-| Scoring functions for LynRummy. Faithful port of
`angry-cat/src/lyn_rummy/core/score.ts`.

Flat per-card scoring: each card in a valid 3+ family is worth
one `stackTypeValue`. Splitting a long stack into two shorter
ones preserves total score (n cards is n cards) — intentional,
so splits aren't punished by the scoring formula.

Intentional Elm divergences:

  - TS uses `export const Score = new ScoreSingleton()` —
    object-as-namespace with methods. Elm exposes free
    functions (no state, so the singleton is gone).
  - Argument-first `stack` parameters in TS methods become the
    sole argument in Elm functions.

-}

import Game.CardStack as CardStack exposing (CardStack)
import Game.StackType exposing (CardStackType(..))


{-| Points awarded per card for stacks of the given valid
type. Non-valid types (Incomplete, Bogus, Dup) score zero.
-}
stackTypeValue : CardStackType -> Int
stackTypeValue stackType =
    case stackType of
        PureRun ->
            100

        Set ->
            60

        RedBlackRun ->
            50

        Incomplete ->
            0

        Bogus ->
            0

        Dup ->
            0


{-| Score for a single stack: size × type value.

Flat per-card formula. The old formula `(n-2)*type_value` had
two problems for cooperative play: it gave away the first two
cards of any stack for free, and punished splitting a long
stack even when the split kept all cards in valid families.
Under the flat formula, splits are free (n cards is n cards)
and the marginal reward for adding a card is still exactly one
type value.

-}
forStack : CardStack -> Int
forStack stack =
    CardStack.size stack * stackTypeValue (CardStack.stackType stack)


{-| Sum of `forStack` across a list of stacks.
-}
forStacks : List CardStack -> Int
forStacks stacks =
    List.sum (List.map forStack stacks)


{-| Per-turn bonus for playing `num` cards. Mirrors the TS
formula: a flat 200-point "actually played" bonus plus
100 × num². Non-positive num returns 0.
-}
forCardsPlayed : Int -> Int
forCardsPlayed num =
    if num <= 0 then
        0

    else
        let
            actuallyPlayedBonus =
                200

            progressivePointsForPlayedCards =
                100 * num * num
        in
        actuallyPlayedBonus + progressivePointsForPlayedCards
