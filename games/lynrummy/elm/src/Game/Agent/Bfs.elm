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
import Game.Rules.Card exposing (Card, cardValueToInt, originDeckToInt, suitToInt)
import Game.CardStack exposing (CardStack)
import Game.Rules.StackType as StackType
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
callers (the Puzzles gallery) need only the board.

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
    if not (allTroubleSingletonsLive buckets) then
        Nothing

    else
        let
            initial =
                { buckets = buckets
                , lineage = Enumerator.initialLineage buckets
                }
        in
        solveLoop 1 maxOuter initial


{-| Dead-trouble-singleton filter. Return False if any trouble
singleton cannot be part of any valid 3-card group given all
cards on the board. A dead singleton means no BFS plan can
ever succeed. Companion to the doomed-third and state-level
doomed-growing filters in Enumerator.
-}
allTroubleSingletonsLive : Buckets -> Bool
allTroubleSingletonsLive b =
    let
        pool =
            List.concat b.helper
                ++ List.concat b.trouble
                ++ List.concat b.growing
                ++ List.concat b.complete

        checkStack stack =
            case stack of
                [ c ] ->
                    let
                        others =
                            List.filter (\x -> x /= c) pool
                    in
                    singletonIsLive c others

                _ ->
                    True
    in
    List.all checkStack b.trouble


{-| True if card `c` can be part of any valid 3-card group
using cards from `pool` (which must not contain `c`).
-}
singletonIsLive : Card -> List Card -> Bool
singletonIsLive c pool =
    List.any
        (\( c1, c2 ) ->
            StackType.isLegalStack [ c, c1, c2 ]
                || StackType.isLegalStack [ c1, c, c2 ]
                || StackType.isLegalStack [ c1, c2, c ]
        )
        (allPairs pool)


{-| All unordered pairs from a list. O(n²).
-}
allPairs : List a -> List ( a, a )
allPairs xs =
    case xs of
        [] ->
            []

        h :: t ->
            List.map (Tuple.pair h) t ++ allPairs t


solveLoop : Int -> Int -> FocusedState -> Maybe Plan
solveLoop cap maxOuter initial =
    if cap > maxOuter then
        Nothing

    else
        let
            ( maybePlan, maxTroubleSeen ) =
                bfsWithCap cap initial
        in
        case maybePlan of
            Just plan ->
                Just plan

            Nothing ->
                -- Plateau detection: if no generated candidate
                -- (admitted or pruned) exceeded maxTroubleSeen,
                -- no move from any reachable state leads to higher
                -- trouble. Higher caps admit nothing new — stop.
                -- Includes pruned candidates because troubleCount
                -- can jump by >1 per move (e.g. 1→3 on a yank).
                if maxTroubleSeen < cap then
                    Nothing

                else
                    solveLoop (cap + 1) maxOuter initial


{-| Inner BFS: pure breadth-first by program length, every
state filtered against the cap. Within each level, frontier
is sorted by trouble count so victory-adjacent states are
expanded earlier.

Returns (Maybe Plan, maxTroubleSeen) where maxTroubleSeen is
the highest troubleCount seen across ALL generated candidates
(admitted or pruned). Used by solveLoop for plateau detection.
-}
bfsWithCap : Int -> FocusedState -> ( Maybe Plan, Int )
bfsWithCap cap initial =
    if Buckets.troubleCount initial.buckets > cap then
        -- Sentinel: return cap so plateau check (maxTroubleSeen < cap)
        -- does not fire. Higher caps may admit this initial state.
        ( Nothing, cap )

    else if Buckets.isVictory initial.buckets then
        ( Just [], 0 )

    else
        let
            initialSig =
                signature initial

            initialTrouble =
                Buckets.troubleCount initial.buckets
        in
        bfsStep cap [ ( initial, [] ) ] (Set.singleton initialSig) initialTrouble


type alias Frontier =
    List ( FocusedState, Plan )


bfsStep : Int -> Frontier -> Set String -> Int -> ( Maybe Plan, Int )
bfsStep cap currentLevel seen maxTroubleSeen =
    if List.isEmpty currentLevel then
        ( Nothing, maxTroubleSeen )

    else
        let
            sorted =
                List.sortBy
                    (\( s, _ ) -> Buckets.troubleCount s.buckets)
                    currentLevel

            stepResult =
                walkLevel cap sorted seen [] maxTroubleSeen
        in
        case stepResult of
            Found plan ->
                ( Just plan, 0 )

            Continue nextLevel newSeen newMax ->
                bfsStep cap nextLevel newSeen newMax


type StepResult
    = Found Plan
    | Continue Frontier (Set String) Int


walkLevel :
    Int
    -> Frontier
    -> Set String
    -> Frontier
    -> Int
    -> StepResult
walkLevel cap frontier seen acc maxTroubleSeen =
    case frontier of
        [] ->
            -- Reverse once at end-of-level so order matches
            -- enumeration order rather than reverse-of-it.
            Continue (List.reverse acc) seen maxTroubleSeen

        ( state, program ) :: rest ->
            case expandState cap state program seen acc maxTroubleSeen of
                Found plan ->
                    Found plan

                Continue updatedAcc updatedSeen updatedMax ->
                    walkLevel cap rest updatedSeen updatedAcc updatedMax


{-| Expand a single state. For each enumerated move, check
the cap, dedup against `seen`, check victory, otherwise add
to the accumulator. Returns either a victorious plan or
the updated (acc, seen, maxTroubleSeen) triple.
-}
expandState :
    Int
    -> FocusedState
    -> Plan
    -> Set String
    -> Frontier
    -> Int
    -> StepResult
expandState cap state program seen acc maxTroubleSeen =
    let
        moves =
            Enumerator.enumerateFocused state
    in
    expandMoves cap program moves seen acc maxTroubleSeen


expandMoves :
    Int
    -> Plan
    -> List ( Move, FocusedState )
    -> Set String
    -> Frontier
    -> Int
    -> StepResult
expandMoves cap program moves seen acc maxTroubleSeen =
    case moves of
        [] ->
            Continue acc seen maxTroubleSeen

        ( move, newState ) :: rest ->
            let
                tc =
                    Buckets.troubleCount newState.buckets

                -- Track ALL candidates (pruned or admitted).
                -- troubleCount can jump by >1 per move, so
                -- admitted-only tracking fires plateau too early.
                newMax =
                    max maxTroubleSeen tc
            in
            if tc > cap then
                expandMoves cap program rest seen acc newMax

            else
                let
                    sig =
                        signature newState
                in
                if Set.member sig seen then
                    expandMoves cap program rest seen acc newMax

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
                            newMax



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
