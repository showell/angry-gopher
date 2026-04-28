module Game.Agent.Buckets exposing
    ( Buckets
    , Stack
    , empty
    , isVictory
    , troubleCount
    )

{-| The four-bucket state model for the BFS planner. Ports
`python/bfs_solver.py`'s `(helper, trouble, growing, complete)`
4-tuple to a record, and `_trouble_count` / `_victory` to
named functions.

A `Stack` here is just `List Card` — the BFS doesn't consult
geometry, so the location fields on `Game.CardStack` aren't
needed. When the verb translator emits primitives, it
re-resolves stacks against the live board by content.

-}

import Game.Rules.Card exposing (Card)


type alias Stack =
    List Card


type alias Buckets =
    { helper : List Stack
    , trouble : List Stack
    , growing : List Stack
    , complete : List Stack
    }


{-| The empty state — no stacks anywhere. Useful as a
test-builder seed.
-}
empty : Buckets
empty =
    { helper = [], trouble = [], growing = [], complete = [] }


{-| Total card count across `trouble` + `growing`. The metric
the iterative cap watches.
-}
troubleCount : Buckets -> Int
troubleCount { trouble, growing } =
    List.sum (List.map List.length trouble)
        + List.sum (List.map List.length growing)


{-| Victory: nothing in `trouble`, and every `growing` build
has matured to a complete length-3+ stack.
-}
isVictory : Buckets -> Bool
isVictory { trouble, growing } =
    List.isEmpty trouble
        && List.all (\s -> List.length s >= 3) growing
