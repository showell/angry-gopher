module Game.Agent.Move exposing
    ( ExtractAbsorbDesc
    , ExtractVerb(..)
    , FreePullDesc
    , Move(..)
    , PushDesc
    , ShiftDesc
    , Side(..)
    , SourceBucket(..)
    , SpliceDesc
    , WhichEnd(..)
    , describe
    )

{-| The typed BFS-DSL output. Each variant of `Move` carries a
record of the fields the corresponding Python desc dict
emits. Field names match the Python keys (camelCased) so a
reader can cross-reference 1:1 with `bfs_solver.py`.

This module is types + a single rendering function. Move
enumeration lives in `Game.Agent.Enumerator`; primitive
translation lives in `Game.Agent.Verbs`.

-}

import Game.Agent.Buckets exposing (Stack)
import Game.Card
    exposing
        ( Card
        , OriginDeck(..)
        , Suit(..)
        , valueStr
        )


{-| Which bucket an absorber came from. Determines bucket
transitions in the post-state and the DSL phrasing.
-}
type SourceBucket
    = Trouble
    | Growing


{-| Physical-isolation pattern for an extract. All five share
the `ExtractAbsorb` move shape — they differ in which
spawned pieces qualify as helpers vs trouble (logical-layer
detail handled by the enumerator). `SplitOut` was added
2026-04-26 to fill the interior-of-length-3-run gap so every
helper card is reachable for absorption.
-}
type ExtractVerb
    = Peel
    | Pluck
    | Yank
    | Steal
    | SplitOut


{-| For `Shift`: which end of the source's length-3 run gets
stolen. `LeftEnd` (index 0) or `RightEnd` (index 2).
-}
type WhichEnd
    = LeftEnd
    | RightEnd


type alias ExtractAbsorbDesc =
    { verb : ExtractVerb
    , source : Stack
    , extCard : Card
    , targetBefore : Stack
    , targetBucketBefore : SourceBucket
    , result : Stack
    , side : Side
    , graduated : Bool
    , spawned : List Stack
    }


type alias FreePullDesc =
    { loose : Card
    , targetBefore : Stack
    , targetBucketBefore : SourceBucket
    , result : Stack
    , side : Side
    , graduated : Bool
    }


type alias PushDesc =
    { troubleBefore : Stack
    , targetBefore : Stack
    , result : Stack
    , side : Side
    }


type alias SpliceDesc =
    { loose : Card
    , source : Stack
    , k : Int
    , side : Side
    , leftResult : Stack
    , rightResult : Stack
    }


type alias ShiftDesc =
    { source : Stack
    , donor : Stack
    , stolen : Card
    , pCard : Card
    , whichEnd : WhichEnd
    , newSource : Stack
    , newDonor : Stack
    , targetBefore : Stack
    , targetBucketBefore : SourceBucket
    , merged : Stack
    , side : Side
    , graduated : Bool
    }


{-| `Side` is shared with the primitive layer's merge_stack
side. The verb translator maps each variant's `.side`
through to the primitive's side parameter.
-}
type Side
    = LeftSide
    | RightSide


type Move
    = ExtractAbsorb ExtractAbsorbDesc
    | FreePull FreePullDesc
    | Push PushDesc
    | Splice SpliceDesc
    | Shift ShiftDesc


{-| One-line human-readable rendering of a move. Mirrors
Python's `describe_move` in shape and verb vocabulary so a
plan reads the same on either side.
-}
describe : Move -> String
describe move =
    case move of
        ExtractAbsorb d ->
            verbStr d.verb
                ++ " "
                ++ cardLabel d.extCard
                ++ " from HELPER ["
                ++ stackStr d.source
                ++ "], absorb onto "
                ++ bucketStr d.targetBucketBefore
                ++ " ["
                ++ stackStr d.targetBefore
                ++ "] → ["
                ++ stackStr d.result
                ++ "]"
                ++ graduationSuffix d.graduated
                ++ spawnedSuffix d.spawned

        FreePull d ->
            "pull "
                ++ cardLabel d.loose
                ++ " onto "
                ++ bucketStr d.targetBucketBefore
                ++ " ["
                ++ stackStr d.targetBefore
                ++ "] → ["
                ++ stackStr d.result
                ++ "]"
                ++ graduationSuffix d.graduated

        Push d ->
            "push TROUBLE ["
                ++ stackStr d.troubleBefore
                ++ "] onto HELPER ["
                ++ stackStr d.targetBefore
                ++ "] → ["
                ++ stackStr d.result
                ++ "]"

        Splice d ->
            "splice ["
                ++ cardLabel d.loose
                ++ "] into HELPER ["
                ++ stackStr d.source
                ++ "] → ["
                ++ stackStr d.leftResult
                ++ "] + ["
                ++ stackStr d.rightResult
                ++ "]"

        Shift d ->
            let
                pLabel =
                    cardLabel d.pCard

                rest =
                    List.filter (\c -> c /= d.pCard) d.newSource

                restLabel =
                    rest |> List.map cardLabel |> String.join " "

                shifted =
                    case d.newSource of
                        first :: _ ->
                            if first == d.pCard then
                                pLabel ++ " + " ++ restLabel

                            else
                                restLabel ++ " + " ++ pLabel

                        [] ->
                            pLabel
            in
            "shift "
                ++ pLabel
                ++ " to pop "
                ++ cardLabel d.stolen
                ++ " ["
                ++ stackStr d.newDonor
                ++ " -> "
                ++ shifted
                ++ "]; absorb onto "
                ++ bucketStr d.targetBucketBefore
                ++ " ["
                ++ stackStr d.targetBefore
                ++ "] → ["
                ++ stackStr d.merged
                ++ "]"
                ++ graduationSuffix d.graduated


verbStr : ExtractVerb -> String
verbStr v =
    case v of
        Peel ->
            "peel"

        Pluck ->
            "pluck"

        Yank ->
            "yank"

        Steal ->
            "steal"

        SplitOut ->
            "split_out"


bucketStr : SourceBucket -> String
bucketStr b =
    case b of
        Trouble ->
            "trouble"

        Growing ->
            "growing"


stackStr : Stack -> String
stackStr =
    List.map cardLabel >> String.join " "


{-| Letter-suit card label for DSL output parity with the
Python solver. `5H`, `JC`, `KS`. Deck suffix appended for
non-deck-zero cards (`5H:1`).
-}
cardLabel : Card -> String
cardLabel c =
    valueStr c.value ++ suitLetter c.suit ++ deckSuffix c.originDeck


suitLetter : Suit -> String
suitLetter s =
    case s of
        Club ->
            "C"

        Diamond ->
            "D"

        Spade ->
            "S"

        Heart ->
            "H"


deckSuffix : OriginDeck -> String
deckSuffix d =
    case d of
        DeckOne ->
            ""

        DeckTwo ->
            ":1"


graduationSuffix : Bool -> String
graduationSuffix graduated =
    if graduated then
        " [→COMPLETE]"

    else
        ""


spawnedSuffix : List Stack -> String
spawnedSuffix spawns =
    case spawns of
        [] ->
            ""

        _ ->
            " ; spawn TROUBLE: "
                ++ String.join ", "
                    (List.map (\s -> "[" ++ stackStr s ++ "]") spawns)
