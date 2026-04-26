module Game.Agent.Bfs exposing
    ( Plan
    , bfsWithCap
    , solve
    , solveWithCap
    )

{-| BFS by program length with iterative outer cap on
`troubleCount`. The first cap to find a plan returns the
shortest plan respecting that cap.

Pure functional implementation. The seen-set is `Set String`
keyed on a signature function that's stable under stack
ordering within each bucket.

-}

import Game.Agent.Buckets as Buckets exposing (Buckets, Stack)
import Game.Agent.Enumerator as Enumerator
import Game.Agent.Move exposing (Move)
import Game.Card exposing (Card, originDeckToInt, suitToInt, cardValueToInt)
import Set exposing (Set)


type alias Plan =
    List Move


{-| Default outer cap (10) — matches Python's
`solve(..., max_trouble_outer=10)` default.
-}
solve : Buckets -> Maybe Plan
solve =
    solveWithCap 10


solveWithCap : Int -> Buckets -> Maybe Plan
solveWithCap maxOuter initial =
    solveLoop 1 maxOuter initial


solveLoop : Int -> Int -> Buckets -> Maybe Plan
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
bfsWithCap : Int -> Buckets -> Maybe Plan
bfsWithCap cap initial =
    if Buckets.troubleCount initial > cap then
        Nothing

    else if Buckets.isVictory initial then
        Just []

    else
        let
            initialSig =
                signature initial
        in
        bfsStep cap [ ( initial, [] ) ] (Set.singleton initialSig)


type alias Frontier =
    List ( Buckets, Plan )


bfsStep : Int -> Frontier -> Set String -> Maybe Plan
bfsStep cap currentLevel seen =
    if List.isEmpty currentLevel then
        Nothing

    else
        let
            sorted =
                List.sortBy
                    (\( s, _ ) -> Buckets.troubleCount s)
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
    -> Buckets
    -> Plan
    -> Set String
    -> Frontier
    -> StepResult
expandState cap state program seen acc =
    let
        moves =
            Enumerator.enumerateMoves state
    in
    expandMoves cap program moves seen acc


expandMoves :
    Int
    -> Plan
    -> List ( Move, Buckets )
    -> Set String
    -> Frontier
    -> StepResult
expandMoves cap program moves seen acc =
    case moves of
        [] ->
            Continue acc seen

        ( move, newState ) :: rest ->
            if Buckets.troubleCount newState > cap then
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
                    if Buckets.isVictory newState then
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


{-| A canonical string signature. Bucket order matters; stack
order within a bucket does NOT — sigs sort each bucket's
stacks (each stack as its own sorted list) before joining.

Format: `H<helper> | T<trouble> | G<growing> | C<complete>`
where each bucket section sorts its stacks and joins them
with `;`, and each stack joins its sorted cards with `,`.

-}
signature : Buckets -> String
signature { helper, trouble, growing, complete } =
    String.join " | "
        [ "H" ++ encodeBucket helper
        , "T" ++ encodeBucket trouble
        , "G" ++ encodeBucket growing
        , "C" ++ encodeBucket complete
        ]


encodeBucket : List Stack -> String
encodeBucket stacks =
    stacks
        |> List.map encodeStack
        |> List.sort
        |> String.join ";"


encodeStack : Stack -> String
encodeStack stack =
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
