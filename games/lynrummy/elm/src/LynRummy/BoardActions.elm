module LynRummy.BoardActions exposing
    ( BoardChange
    , HandMergeResult
    , Side(..)
    , StackMergeResult
    , findAllHandMerges
    , findAllStackMerges
    , moveStack
    , placeHandCard
    , tryHandMerge
    , tryStackMerge
    )

{-| Decision logic for card-merging and placement on the
LynRummy board. Pure functions returning `BoardChange`
diffs; no mutation, no DOM. Faithful port of
`angry-cat/src/lyn_rummy/game/board_actions.ts`.

Every successful action returns a `BoardChange`. Callers
apply it to the board; the module itself never mutates.

-}

import LynRummy.CardStack as CardStack
    exposing
        ( BoardLocation
        , CardStack
        , HandCard
        , stacksEqual
        )


{-| Side of a stack to merge onto. TS used a string union
`"left" | "right"`; Elm has a dedicated sum type.
-}
type Side
    = Left
    | Right


{-| A diff against the board. `stacksToRemove` + `stacksToAdd`
updates the board; `handCardsToRelease` tells the UI which
hand cards this action consumed.
-}
type alias BoardChange =
    { stacksToRemove : List CardStack
    , stacksToAdd : List CardStack
    , handCardsToRelease : List HandCard
    }


{-| Result of `findAllStackMerges`: a valid merge of a dragged
stack onto some other board stack, with the side and the
computed diff.
-}
type alias StackMergeResult =
    { side : Side
    , change : BoardChange
    }


{-| Result of `findAllHandMerges`: a valid merge of a dragged
hand card onto some board stack, plus the stack it merges
onto.
-}
type alias HandMergeResult =
    { side : Side
    , stack : CardStack
    , change : BoardChange
    }



-- INTERNAL


{-| TS had a throwaway DUMMY_LOC used when wrapping a hand card
as a stack for merging. The merged result's loc comes from the
target stack's merge operation, so the dummy loc is discarded.
-}
dummyLoc : BoardLocation
dummyLoc =
    { top = -1, left = -1 }


tryMerge : CardStack -> CardStack -> Side -> Maybe CardStack
tryMerge stack other side =
    case side of
        Left ->
            CardStack.leftMerge stack other

        Right ->
            CardStack.rightMerge stack other



-- HAND CARD MERGES


tryHandMerge : CardStack -> HandCard -> Side -> Maybe BoardChange
tryHandMerge stack handCard side =
    let
        handStack =
            CardStack.fromHandCard handCard dummyLoc
    in
    case tryMerge stack handStack side of
        Nothing ->
            Nothing

        Just merged ->
            Just
                { stacksToRemove = [ stack ]
                , stacksToAdd = [ merged ]
                , handCardsToRelease = [ handCard ]
                }



-- BOARD STACK MERGES


tryStackMerge : CardStack -> CardStack -> Side -> Maybe BoardChange
tryStackMerge stack other side =
    case tryMerge stack other side of
        Nothing ->
            Nothing

        Just merged ->
            Just
                { stacksToRemove = [ stack, other ]
                , stacksToAdd = [ merged ]
                , handCardsToRelease = []
                }



-- PLACE AND MOVE


placeHandCard : HandCard -> BoardLocation -> BoardChange
placeHandCard handCard loc =
    { stacksToRemove = []
    , stacksToAdd = [ CardStack.fromHandCard handCard loc ]
    , handCardsToRelease = [ handCard ]
    }


moveStack : CardStack -> BoardLocation -> BoardChange
moveStack stack newLoc =
    { stacksToRemove = [ stack ]
    , stacksToAdd = [ { stack | loc = newLoc } ]
    , handCardsToRelease = []
    }



-- BULK MERGE DISCOVERY


{-| Enumerate every merge of `target` onto any other stack
from the given board. Filters out `target` itself by
structural equality (TS uses reference equality; outcomes
match because `maybeMerge` already rejects stacksEqual pairs).
-}
findAllStackMerges : CardStack -> List CardStack -> List StackMergeResult
findAllStackMerges target allStacks =
    let
        others =
            List.filter (\s -> not (stacksEqual s target)) allStacks
    in
    List.concatMap (tryBothSidesStack target) others


tryBothSidesStack : CardStack -> CardStack -> List StackMergeResult
tryBothSidesStack target other =
    List.filterMap (mergeOnSide target other) [ Left, Right ]


mergeOnSide : CardStack -> CardStack -> Side -> Maybe StackMergeResult
mergeOnSide target other side =
    tryStackMerge target other side
        |> Maybe.map (\change -> { side = side, change = change })


{-| Enumerate every merge of `handCard` onto any board stack.
-}
findAllHandMerges : HandCard -> List CardStack -> List HandMergeResult
findAllHandMerges handCard allStacks =
    List.concatMap (tryBothSidesHand handCard) allStacks


tryBothSidesHand : HandCard -> CardStack -> List HandMergeResult
tryBothSidesHand handCard stack =
    List.filterMap (handMergeOnSide handCard stack) [ Left, Right ]


handMergeOnSide : HandCard -> CardStack -> Side -> Maybe HandMergeResult
handMergeOnSide handCard stack side =
    tryHandMerge stack handCard side
        |> Maybe.map
            (\change ->
                { side = side, stack = stack, change = change }
            )
