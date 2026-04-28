module Game.BoardPhysics exposing
    ( canExtract
    , joinAdjacentRuns
    )

{-| Pure physics utilities for LynRummy boards. No notion of
tricks, hints, or strategy — these describe what is legal to
do with stacks of cards, independent of any algorithm that
uses them. Faithful port of
`angry-cat/src/lyn_rummy/core/board_physics.ts`.

Intentional Elm divergences:

  - TS uses a `while progress` loop inside `join_adjacent_runs`
    that mutates the array in place. The Elm version threads a
    recursive helper, producing the same fixed-point behavior
    without mutation.
  - TS returns `{ board, changed }`; Elm returns the same shape
    as a record literal.

-}

import Game.CardStack as CardStack exposing (CardStack)
import Game.Rules.StackType exposing (CardStackType(..))


{-| Can this card be extracted from its stack without breaking
it? Returns true if the card is on an end of a 4+ run, or if
splitting the run at this position leaves two valid halves
(3+ each), or if this is any card in a 4+ set.

Three legal cases:

1.  End of a 4+ run — peel left or right, remaining 3+ run is valid.
2.  Middle of a 7+ run — removing leaves 3+ on each side.
3.  Any card in a 4-card set — remaining 3-card set is valid.

-}
canExtract : CardStack -> Int -> Bool
canExtract stack cardIndex =
    let
        stSize =
            CardStack.size stack

        st =
            CardStack.stackType stack
    in
    case st of
        Set ->
            stSize >= 4

        PureRun ->
            runPeelLegal stSize cardIndex

        RedBlackRun ->
            runPeelLegal stSize cardIndex

        _ ->
            False


{-| For a run of the given size, is extracting at cardIndex
legal? End peel requires size >= 4. Middle peel requires both
halves to be 3+ cards long.
-}
runPeelLegal : Int -> Int -> Bool
runPeelLegal stSize cardIndex =
    let
        endPeel =
            stSize >= 4 && (cardIndex == 0 || cardIndex == stSize - 1)

        middlePeel =
            cardIndex >= 3 && (stSize - cardIndex - 1) >= 3
    in
    endPeel || middlePeel


{-| Join any pair of stacks whose cards merge into one valid
stack. Iterates until no more joins are possible. Returns the
consolidated board and whether anything actually changed.
-}
joinAdjacentRuns : List CardStack -> { board : List CardStack, changed : Bool }
joinAdjacentRuns boardStacks =
    joinLoop boardStacks False


joinLoop : List CardStack -> Bool -> { board : List CardStack, changed : Bool }
joinLoop stacks accChanged =
    case onePassMerge stacks of
        Just newStacks ->
            joinLoop newStacks True

        Nothing ->
            { board = stacks, changed = accChanged }


{-| Scan the list for the first (i, j) pair (i < j) whose
merge succeeds; return the list with stacks[i] replaced by the
merged result and stacks[j] removed.
-}
onePassMerge : List CardStack -> Maybe (List CardStack)
onePassMerge stacks =
    scanOuter [] stacks


scanOuter : List CardStack -> List CardStack -> Maybe (List CardStack)
scanOuter done todo =
    case todo of
        [] ->
            Nothing

        first :: rest ->
            case scanInner first [] rest of
                Just ( merged, restWithJRemoved ) ->
                    Just (List.reverse done ++ merged :: restWithJRemoved)

                Nothing ->
                    scanOuter (first :: done) rest


{-| Try to merge `target` with any element of `rest`. On first
success, return the merged stack plus `rest` with the merged
partner removed.
-}
scanInner : CardStack -> List CardStack -> List CardStack -> Maybe ( CardStack, List CardStack )
scanInner target skipped rest =
    case rest of
        [] ->
            Nothing

        other :: more ->
            case tryMergePair target other of
                Just merged ->
                    Just ( merged, List.reverse skipped ++ more )

                Nothing ->
                    scanInner target (other :: skipped) more


{-| Attempt to merge two stacks in either order. TS uses
`a.right_merge(b) ?? b.right_merge(a)`; mirrored here. Note
the result position is `a.loc` in the first-wins case,
`b.loc` in the fallback.
-}
tryMergePair : CardStack -> CardStack -> Maybe CardStack
tryMergePair a b =
    case CardStack.rightMerge a b of
        Just merged ->
            Just merged

        Nothing ->
            CardStack.rightMerge b a
