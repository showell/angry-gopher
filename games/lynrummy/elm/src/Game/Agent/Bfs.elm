module Game.Agent.Bfs exposing
    ( Plan
    , solve
    , solveBoard
    , solveWithCap
    )

{-| BFS by program length with iterative outer cap on
`troubleCount`. The first cap to find a plan returns the
shortest plan respecting that cap.

Pure functional implementation. The seen-set is `Set String`
keyed on a signature that includes both the canonical bucket
shape AND the lineage queue — two states with identical
buckets but a different focus are NOT the same state under
the focus rule.

-}

import Game.Agent.Buckets as Buckets exposing (Buckets, Stack)
import Game.Agent.Enumerator as Enumerator
    exposing
        ( FocusedState
        , Lineage
        )
import Game.Agent.Move exposing (Move)
import Game.Card exposing (Card, cardValueToInt, originDeckToInt, suitToInt)
import Game.CardStack exposing (CardStack)
import Game.StackType as StackType
import Set exposing (Set)


type alias Plan =
    List Move


{-| Default outer cap (10) — matches Python's
`solve(..., max_trouble_outer=10)` default.
-}
solve : Buckets -> Maybe Plan
solve =
    solveWithCap 10


{-| Board-shaped entry point: partition a live `List CardStack`
into the helper/trouble buckets BFS expects, then run `solve`.
The solver's `Buckets` shape stays internal — production
callers (the Lab puzzle panel) need only the board.

A stack classifies as helper if `StackType.getStackType`
recognizes it as a complete group (Set / PureRun /
RedBlackRun); everything else is trouble. Mirrors Python's
`bfs.solve(board)` partition step.

-}
solveBoard : List CardStack -> Maybe Plan
solveBoard board =
    let
        cardsOf stack =
            List.map .card stack.boardCards

        ( helper, trouble ) =
            List.foldr
                (\stack ( hs, ts ) ->
                    let
                        cards =
                            cardsOf stack
                    in
                    case StackType.getStackType cards of
                        StackType.Set ->
                            ( cards :: hs, ts )

                        StackType.PureRun ->
                            ( cards :: hs, ts )

                        StackType.RedBlackRun ->
                            ( cards :: hs, ts )

                        _ ->
                            ( hs, cards :: ts )
                )
                ( [], [] )
                board
    in
    solve { helper = helper, trouble = trouble, growing = [], complete = [] }


solveWithCap : Int -> Buckets -> Maybe Plan
solveWithCap maxOuter buckets =
    let
        initial =
            { buckets = buckets
            , lineage = Enumerator.initialLineage buckets
            }
    in
    solveLoop 1 maxOuter initial


solveLoop : Int -> Int -> FocusedState -> Maybe Plan
solveLoop cap maxOuter initial =
    if cap > maxOuter then
        Nothing

    else
        case bfsWithCap cap initial of
            Just plan ->
                Just plan

            Nothing ->
                solveLoop (cap + 1) maxOuter initial


{-| Inner BFS: pure breadth-first by program length, every
state filtered against the cap. Within each level, frontier
is sorted by trouble count so victory-adjacent states are
expanded earlier.
-}
bfsWithCap : Int -> FocusedState -> Maybe Plan
bfsWithCap cap initial =
    if Buckets.troubleCount initial.buckets > cap then
        Nothing

    else if Buckets.isVictory initial.buckets then
        Just []

    else
        let
            initialSig =
                signature initial
        in
        bfsStep cap [ ( initial, [] ) ] (Set.singleton initialSig)


type alias Frontier =
    List ( FocusedState, Plan )


bfsStep : Int -> Frontier -> Set String -> Maybe Plan
bfsStep cap currentLevel seen =
    if List.isEmpty currentLevel then
        Nothing

    else
        let
            sorted =
                List.sortBy
                    (\( s, _ ) -> Buckets.troubleCount s.buckets)
                    currentLevel

            -- Walk the level, accumulating next-level entries
            -- and dedup'd seen-set. Short-circuit on first
            -- victory.
            stepResult =
                walkLevel cap sorted seen []
        in
        case stepResult of
            Found plan ->
                Just plan

            Continue nextLevel newSeen ->
                bfsStep cap nextLevel newSeen


type StepResult
    = Found Plan
    | Continue Frontier (Set String)


walkLevel :
    Int
    -> Frontier
    -> Set String
    -> Frontier
    -> StepResult
walkLevel cap frontier seen acc =
    case frontier of
        [] ->
            -- Reverse once at end-of-level so order matches
            -- enumeration order rather than reverse-of-it.
            Continue (List.reverse acc) seen

        ( state, program ) :: rest ->
            case expandState cap state program seen acc of
                Found plan ->
                    Found plan

                Continue updatedAcc updatedSeen ->
                    walkLevel cap rest updatedSeen updatedAcc


{-| Expand a single state. For each enumerated move, check
the cap, dedup against `seen`, check victory, otherwise add
to the accumulator. Returns either a victorious plan or
the updated (acc, seen) pair.
-}
expandState :
    Int
    -> FocusedState
    -> Plan
    -> Set String
    -> Frontier
    -> StepResult
expandState cap state program seen acc =
    let
        moves =
            Enumerator.enumerateFocused state
    in
    expandMoves cap program moves seen acc


expandMoves :
    Int
    -> Plan
    -> List ( Move, FocusedState )
    -> Set String
    -> Frontier
    -> StepResult
expandMoves cap program moves seen acc =
    case moves of
        [] ->
            Continue acc seen

        ( move, newState ) :: rest ->
            if Buckets.troubleCount newState.buckets > cap then
                expandMoves cap program rest seen acc

            else
                let
                    sig =
                        signature newState
                in
                if Set.member sig seen then
                    expandMoves cap program rest seen acc

                else
                    let
                        newSeen =
                            Set.insert sig seen

                        newProgram =
                            program ++ [ move ]
                    in
                    if Buckets.isVictory newState.buckets then
                        Found newProgram

                    else
                        expandMoves cap
                            program
                            rest
                            newSeen
                            (( newState, newProgram ) :: acc)



-- ============================================================
-- State signature
-- ============================================================


{-| A canonical string signature for the focused state.
Bucket order matters; stack order within a bucket does NOT
— sigs sort each bucket's stacks (each stack as its own
sorted list) before joining. Lineage IS order-load-bearing
(the focus and the queue order both affect which moves are
admissible) so it's encoded in original order.

Format:
`H<helper> | T<trouble> | G<growing> | C<complete> | L<lineage>`

-}
signature : FocusedState -> String
signature { buckets, lineage } =
    String.join " | "
        [ "H" ++ encodeBucket buckets.helper
        , "T" ++ encodeBucket buckets.trouble
        , "G" ++ encodeBucket buckets.growing
        , "C" ++ encodeBucket buckets.complete
        , "L" ++ encodeLineage lineage
        ]


encodeBucket : List Stack -> String
encodeBucket stacks =
    stacks
        |> List.map encodeStackSorted
        |> List.sort
        |> String.join ";"


encodeLineage : Lineage -> String
encodeLineage lineage =
    -- Lineage order is significant; do NOT sort the entries
    -- against each other. Sort cards inside each stack only
    -- (so that a stack's representation is canonical even
    -- though the queue order is preserved).
    lineage
        |> List.map encodeStackSorted
        |> String.join ";"


encodeStackSorted : Stack -> String
encodeStackSorted stack =
    stack
        |> List.map encodeCard
        |> List.sort
        |> String.join ","


encodeCard : Card -> String
encodeCard c =
    String.fromInt (cardValueToInt c.value)
        ++ "/"
        ++ String.fromInt (suitToInt c.suit)
        ++ "/"
        ++ String.fromInt (originDeckToInt c.originDeck)
