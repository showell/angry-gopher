module Lib.BoardActions exposing
    ( BoardChange
    , Side(..)
    , placeHandCardAt
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

import Lib.CardStack as CardStack
    exposing
        ( BoardLocation
        , CardStack
        , HandCard
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



-- INTERNAL


{-| TS had a throwaway DUMMY\_LOC used when wrapping a hand card
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


placeHandCardAt : HandCard -> BoardLocation -> BoardChange
placeHandCardAt handCard loc =
    { stacksToRemove = []
    , stacksToAdd = [ CardStack.fromHandCard handCard loc ]
    , handCardsToRelease = [ handCard ]
    }



-- BULK MERGE DISCOVERY
