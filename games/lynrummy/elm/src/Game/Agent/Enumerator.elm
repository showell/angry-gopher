module Game.Agent.Enumerator exposing
    ( FocusedState
    , Lineage
    , enumerateFocused
    , enumerateMoves
    , initialLineage
    , moveTouchesFocus
    , updateLineage
    )

{-| The BFS move generator. Given a `Buckets` state, returns
every legal next-state move with the resulting buckets.

Mirrors `python/bfs_solver._enumerate_moves` move-for-move:
the order of move types matches Python's so that BFS
expansion order (within a level, sort-by-trouble-count) is
identical across implementations.

-}

import Game.Agent.Buckets as Buckets exposing (Buckets, Stack)
import Game.Agent.Cards as Cards
import Game.Agent.Move
    exposing
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
        )
import Game.Card as Card
    exposing
        ( Card
        , CardColor
        , CardValue
        , Suit
        , allSuits
        , cardColor
        , cardValueToInt
        , suitColor
        , suitToInt
        )
import Dict exposing (Dict)
import Game.StackType as StackType
    exposing
        ( CardStackType(..)
        , predecessor
        , successor
        )
import Set exposing (Set)



-- ============================================================
-- Public entry
-- ============================================================


{-| All legal next moves from `state`. Each entry is
`(move, postState)`. The order matches Python's enumeration
order so within-level sort produces identical BFS behavior.

The state-level doomed-growing filter (top of the function)
short-circuits to `[]` if any growing 2-partial has no
completion candidate left on the extractable board. The
merge-time doomed-third filter (in `admissiblePartial`)
catches the same condition for newly-formed length-2
absorbs. Together they prune dead-ended search branches so
the BFS doesn't waste expansions on doomed states.

-}
enumerateMoves : Buckets -> List ( Move, Buckets )
enumerateMoves state =
    let
        inventory =
            completionInventory state

        hasDoomedGrowing =
            state.growing
                |> List.any
                    (\g ->
                        List.length g == 2
                            && hasDoomedThird g inventory
                    )
    in
    if hasDoomedGrowing then
        []

    else
        let
            extractable =
                extractableIndex state.helper
        in
        extractAndAbsorbMoves state inventory extractable
            ++ shiftMoves state inventory extractable
            ++ spliceMoves state
            ++ pushMoves state
            ++ engulfMoves state



-- ============================================================
-- Internal classification (wraps Game.StackType for the BFS)
-- ============================================================


type Kind
    = KSet
    | KPureRun
    | KRbRun
    | KOther


classify : Stack -> Kind
classify stack =
    case StackType.getStackType stack of
        Set ->
            KSet

        PureRun ->
            KPureRun

        RedBlackRun ->
            KRbRun

        _ ->
            KOther



-- ============================================================
-- Verb eligibility (mirror of beginner.py's _can_*_kind)
-- ============================================================


verbFor : Kind -> Int -> Int -> Maybe ExtractVerb
verbFor kind n ci =
    if canPeel kind n ci then
        Just Peel

    else if canPluck kind n ci then
        Just Pluck

    else if canYank kind n ci then
        Just Yank

    else if canSteal kind n ci then
        Just Steal

    else if canSplitOut kind n ci then
        Just SplitOut

    else
        Nothing


canPeel : Kind -> Int -> Int -> Bool
canPeel kind n ci =
    case kind of
        KSet ->
            n >= 4

        KPureRun ->
            n >= 4 && (ci == 0 || ci == n - 1)

        KRbRun ->
            n >= 4 && (ci == 0 || ci == n - 1)

        KOther ->
            False


canPluck : Kind -> Int -> Int -> Bool
canPluck kind n ci =
    isRunKind kind && ci >= 3 && ci <= n - 4


canYank : Kind -> Int -> Int -> Bool
canYank kind n ci =
    if not (isRunKind kind) then
        False

    else if ci == 0 || ci == n - 1 || (ci >= 3 && ci <= n - 4) then
        False

    else
        let
            leftLen =
                ci

            rightLen =
                n - ci - 1
        in
        max leftLen rightLen >= 3 && min leftLen rightLen >= 1


canSteal : Kind -> Int -> Int -> Bool
canSteal kind n ci =
    if n /= 3 then
        False

    else
        case kind of
            KPureRun ->
                ci == 0 || ci == n - 1

            KRbRun ->
                ci == 0 || ci == n - 1

            KSet ->
                True

            KOther ->
                False


{-| `SplitOut` extracts the interior of a length-3 run,
splitting it into two singleton TROUBLE fragments. Closes
the only extraction gap in the verb vocabulary so every
helper card is reachable for absorption. Added 2026-04-26.
-}
canSplitOut : Kind -> Int -> Int -> Bool
canSplitOut kind n ci =
    isRunKind kind && n == 3 && ci == 1


isRunKind : Kind -> Bool
isRunKind kind =
    case kind of
        KPureRun ->
            True

        KRbRun ->
            True

        _ ->
            False



-- ============================================================
-- Extractable index (loop inversion, OPTIMIZE_PYTHON)
-- ============================================================


{-| A single extractable position in the helper bucket: which
helper stack (`hi`), which card index (`ci`), and which verb
the extraction would use.
-}
type alias ExtractEntry =
    { hi : Int, ci : Int, verb : ExtractVerb }


{-| Maps every shape `(value, suit)` reachable as an extract to
the list of helper positions that can produce it. Built once
per state. The absorb loop iterates the absorber's neighbor
shapes and looks up matches directly, instead of scanning
every (helper × position) and filtering by shape.
-}
type alias ExtractableIndex =
    Dict ShapeKey (List ExtractEntry)


extractableIndex : List Stack -> ExtractableIndex
extractableIndex helper =
    helper
        |> List.indexedMap Tuple.pair
        |> List.foldl addHelperEntries Dict.empty


addHelperEntries :
    ( Int, Stack )
    -> ExtractableIndex
    -> ExtractableIndex
addHelperEntries ( hi, src ) acc =
    let
        kind =
            classify src

        n =
            List.length src
    in
    src
        |> List.indexedMap Tuple.pair
        |> List.foldl
            (\( ci, c ) inner ->
                case verbFor kind n ci of
                    Nothing ->
                        inner

                    Just verb ->
                        let
                            key =
                                ( cardValueToInt c.value, suitToInt c.suit )

                            entry =
                                { hi = hi, ci = ci, verb = verb }
                        in
                        Dict.update key
                            (\maybeList ->
                                case maybeList of
                                    Just xs ->
                                        Just (xs ++ [ entry ])

                                    Nothing ->
                                        Just [ entry ]
                            )
                            inner
            )
            acc



-- ============================================================
-- Pure helpers — bucket / state transitions
-- ============================================================


{-| Drop the element at index `i` from a list. Pure.
-}
withoutAt : Int -> List a -> List a
withoutAt i xs =
    List.take i xs ++ List.drop (i + 1) xs


{-| Drop the absorber at (bucket, idx) from its bucket; the
other bucket passes through unchanged. Returns the updated
trouble + growing lists.
-}
removeAbsorber :
    SourceBucket
    -> Int
    -> List Stack
    -> List Stack
    -> ( List Stack, List Stack )
removeAbsorber bucket idx trouble growing =
    case bucket of
        Trouble ->
            ( withoutAt idx trouble, growing )

        Growing ->
            ( trouble, withoutAt idx growing )


{-| Route a merged stack to GROWING (still partial) or
COMPLETE (legal). Returns (newGrowing, newComplete,
graduatedFlag).
-}
graduate :
    Stack
    -> List Stack
    -> List Stack
    -> ( List Stack, List Stack, Bool )
graduate merged growing complete =
    if Cards.isLegalStack merged then
        ( growing, complete ++ [ merged ], True )

    else
        ( growing ++ [ merged ], complete, False )



-- ============================================================
-- Verb-keyed extract (mirror of bfs_solver._extract_pieces)
-- ============================================================


{-| Decompose a source stack after extracting the card at
index `ci` per `verb`. Returns (helperPieces, spawnedPieces).

Helper pieces are length-3+ classifiable pieces that stay in
HELPER. Spawned pieces are short remnants that land in
TROUBLE.

-}
extractPieces : Stack -> Int -> ExtractVerb -> ( List Stack, List Stack )
extractPieces source ci verb =
    case verb of
        Peel ->
            let
                kind =
                    classify source

                remnant =
                    if kind == KSet then
                        case List.drop ci source |> List.head of
                            Just c ->
                                List.filter (\x -> x /= c) source

                            Nothing ->
                                source

                    else if ci == 0 then
                        List.drop 1 source

                    else
                        List.take (List.length source - 1) source
            in
            ( [ remnant ], [] )

        Pluck ->
            ( [ List.take ci source, List.drop (ci + 1) source ], [] )

        Yank ->
            yankShape source ci

        SplitOut ->
            -- Same physical decomposition as yank (left+right
            -- halves), but constrained to n=3, ci=1 where both
            -- halves are length-1 singletons. Reusing the yank
            -- shape keeps the bookkeeping uniform.
            yankShape source ci

        Steal ->
            let
                kind =
                    classify source
            in
            case kind of
                KSet ->
                    case List.drop ci source |> List.head of
                        Just c ->
                            ( [], List.filter ((/=) c) source |> List.map List.singleton )

                        Nothing ->
                            ( [], [] )

                _ ->
                    let
                        remnant =
                            if ci == 0 then
                                List.drop 1 source

                            else
                                List.take (List.length source - 1) source
                    in
                    ( [], [ remnant ] )


{-| Shared decomposition for verbs that split the source
around `ci` and route each half by length: length-3+ stays
in HELPER, length-≤2 falls to TROUBLE. Used by both Yank
(any qualifying interior) and SplitOut (n=3, ci=1).
-}
yankShape : Stack -> Int -> ( List Stack, List Stack )
yankShape source ci =
    let
        halves =
            [ List.take ci source, List.drop (ci + 1) source ]
    in
    ( List.filter (\s -> List.length s >= 3) halves
    , List.filter (\s -> List.length s < 3) halves
    )



-- ============================================================
-- Doomed-third filter (OPTIMIZE_PYTHON, 2026-04-25)
-- ============================================================


{-| Encode `(value, suit)` as a comparable Int pair so we can
keep the inventory in `Set` for O(log n) membership.
-}
type alias ShapeKey =
    ( Int, Int )


shapeOfCard : Card -> ShapeKey
shapeOfCard c =
    ( cardValueToInt c.value, suitToInt c.suit )


{-| Set of `(value, suit)` shapes available as candidate
"third cards" anywhere on the (extractable) board: every
helper card plus every trouble singleton. Excludes growing /
complete (sealed) and trouble 2-partials (committed).
-}
completionInventory : Buckets -> Set ShapeKey
completionInventory state =
    let
        helperShapes =
            List.concatMap (List.map shapeOfCard) state.helper

        troubleSingletonShapes =
            state.trouble
                |> List.filter (\s -> List.length s == 1)
                |> List.concatMap (List.map shapeOfCard)
    in
    Set.fromList (helperShapes ++ troubleSingletonShapes)


{-| Shapes that would extend a 2-card partial into a legal
length-3 stack. Mirrors Python's `_completion_shapes`.
-}
completionShapes : Stack -> Set ShapeKey
completionShapes partial =
    case partial of
        [ c1, c2 ] ->
            let
                v1 =
                    cardValueToInt c1.value

                v2 =
                    cardValueToInt c2.value
            in
            if v1 == v2 then
                -- Set partial — distinct-suit third of same value.
                allSuits
                    |> List.filter (\s -> s /= c1.suit && s /= c2.suit)
                    |> List.map (\s -> ( v1, suitToInt s ))
                    |> Set.fromList

            else
                -- Run partial: c1, c2 consecutive (c2 = c1 + 1).
                let
                    predV =
                        if v1 == 1 then
                            13

                        else
                            v1 - 1

                    succV =
                        if v2 == 13 then
                            1

                        else
                            v2 + 1
                in
                if c1.suit == c2.suit then
                    -- Pure run — same-suit extensions on either end.
                    Set.fromList
                        [ ( predV, suitToInt c1.suit )
                        , ( succV, suitToInt c2.suit )
                        ]

                else
                    -- rb run — opposite-color extensions on each end.
                    let
                        c1Color =
                            cardColor c1

                        c2Color =
                            cardColor c2

                        predShapes =
                            allSuits
                                |> List.filter (\s -> suitColor s /= c1Color)
                                |> List.map (\s -> ( predV, suitToInt s ))

                        succShapes =
                            allSuits
                                |> List.filter (\s -> suitColor s /= c2Color)
                                |> List.map (\s -> ( succV, suitToInt s ))
                    in
                    Set.fromList (predShapes ++ succShapes)

        _ ->
            Set.empty


{-| True iff NO completion shape for `partial` exists in
`inventory` — i.e., the partial is doomed to remain a
2-partial because no third card is available anywhere on the
extractable part of the board.
-}
hasDoomedThird : Stack -> Set ShapeKey -> Bool
hasDoomedThird partial inventory =
    completionShapes partial
        |> Set.intersect inventory
        |> Set.isEmpty


{-| Combined gate: every length-2 absorption result must be
legal as a partial AND have at least one completion candidate
somewhere in `inventory`. Mirrors Python's `_admissible_partial`.
-}
admissiblePartial : Stack -> Set ShapeKey -> Bool
admissiblePartial merged inventory =
    if not (Cards.isPartialOk merged) then
        False

    else if List.length merged == 2 && hasDoomedThird merged inventory then
        False

    else
        True



-- ============================================================
-- Focus rule (oldest-lineage-first pruning, 2026-04-26)
-- ============================================================


{-| The lineage queue: ordered content for every entry
currently in TROUBLE + GROWING. `lineage[0]` is the focus —
the in-progress entry the BFS must grow or consume. Yank
spawn fragments append at the tail in left-then-right order
(the older fragment gets focus first when the queue
advances).
-}
type alias Lineage =
    List Stack


{-| BFS state under the focus rule: the 4-tuple buckets plus
the lineage queue. The seen-set signature must include
lineage because two states with the same buckets but a
different focus are NOT the same state for search purposes.
-}
type alias FocusedState =
    { buckets : Buckets
    , lineage : Lineage
    }


{-| Initial lineage = trouble entries (board order) followed
by any pre-existing growing 2-partials. Both are in-flight
commitments that need to land before victory. Mirrors
Python's `_initial_lineage(trouble, growing)`.
-}
initialLineage : Buckets -> Lineage
initialLineage state =
    state.trouble ++ state.growing


{-| True iff this move grows or consumes the focus stack
(identified by content). Mirrors Python's
`_move_touches_focus`.
-}
moveTouchesFocus : Move -> Stack -> Bool
moveTouchesFocus move focus =
    case move of
        ExtractAbsorb d ->
            d.targetBefore == focus

        Shift d ->
            d.targetBefore == focus

        FreePull d ->
            -- Either target = focus (focus grew, loose was a
            -- queued sibling) or loose = focus (focus singleton
            -- consumed onto a non-focus target).
            d.targetBefore
                == focus
                || (case focus of
                        [ c ] ->
                            c == d.loose

                        _ ->
                            False
                   )

        Splice d ->
            case focus of
                [ c ] ->
                    c == d.loose

                _ ->
                    False

        Push d ->
            -- Both b (trouble pushed onto helper) and b' (growing
            -- engulfs helper) carry trouble_before = the consumed
            -- entry's content.
            d.troubleBefore == focus


{-| Compute the new lineage tuple after applying the move.
Caller has verified the move touches `lineage[0]`.
Mirrors Python's `_update_lineage`.
-}
updateLineage : Lineage -> Move -> Lineage
updateLineage lineage move =
    case lineage of
        [] ->
            []

        focus :: rest ->
            case move of
                ExtractAbsorb d ->
                    -- Focus (target) grew. Result joins (or
                    -- graduates). Spawned fragments append in
                    -- left-then-right order at the tail.
                    let
                        afterFocus =
                            if d.graduated then
                                rest

                            else
                                d.result :: rest
                    in
                    afterFocus ++ d.spawned

                Shift d ->
                    -- Same as ExtractAbsorb but uses `merged`
                    -- and produces no spawned trouble.
                    if d.graduated then
                        rest

                    else
                        d.merged :: rest

                FreePull d ->
                    if d.targetBefore == focus then
                        -- Focus grew; the loose was a queued
                        -- singleton — remove it from rest.
                        let
                            rest2 =
                                removeFirstEqual [ d.loose ] rest
                        in
                        if d.graduated then
                            rest2

                        else
                            d.result :: rest2

                    else
                        -- Focus is the loose (singleton);
                        -- target is a queued sibling that grew.
                        updateMatching d.targetBefore d.result d.graduated rest

                Splice _ ->
                    -- Focus (loose) consumed.
                    rest

                Push _ ->
                    -- Focus consumed (b: pushed onto helper,
                    -- or b': growing engulfed a helper).
                    rest


{-| Wrap `enumerateMoves` with the focus filter and the
lineage update. Yields `(move, newFocusedState)`. If lineage
is empty (which means victory, in a well-formed search),
yields nothing.
-}
enumerateFocused : FocusedState -> List ( Move, FocusedState )
enumerateFocused state =
    case state.lineage of
        [] ->
            []

        focus :: _ ->
            enumerateMoves state.buckets
                |> List.filterMap
                    (\( move, newBuckets ) ->
                        if moveTouchesFocus move focus then
                            Just
                                ( move
                                , { buckets = newBuckets
                                  , lineage = updateLineage state.lineage move
                                  }
                                )

                        else
                            Nothing
                    )


{-| Drop the first occurrence of `target` from `xs`. If
absent, returns `xs` unchanged.
-}
removeFirstEqual : a -> List a -> List a
removeFirstEqual target xs =
    case xs of
        [] ->
            []

        h :: t ->
            if h == target then
                t

            else
                h :: removeFirstEqual target t


{-| Find the first entry in `xs` matching `oldContent` and
either drop it (if `graduated`) or replace it with
`newContent`. Used when a non-focus lineage entry is
mutated by a free_pull where focus is the loose.
-}
updateMatching : a -> a -> Bool -> List a -> List a
updateMatching oldContent newContent graduated xs =
    case xs of
        [] ->
            []

        h :: t ->
            if h == oldContent then
                if graduated then
                    t

                else
                    newContent :: t

            else
                h :: updateMatching oldContent newContent graduated t



-- ============================================================
-- Move type (a) — extract + absorb, plus free pull
-- ============================================================


type alias Absorber =
    { bucket : SourceBucket
    , idx : Int
    , target : Stack
    }


absorbersOf : Buckets -> List Absorber
absorbersOf { trouble, growing } =
    let
        ts =
            List.indexedMap
                (\i t -> { bucket = Trouble, idx = i, target = t })
                trouble

        gs =
            List.indexedMap
                (\i g -> { bucket = Growing, idx = i, target = g })
                growing
    in
    ts ++ gs


extractAndAbsorbMoves :
    Buckets
    -> Set ShapeKey
    -> ExtractableIndex
    -> List ( Move, Buckets )
extractAndAbsorbMoves state inventory extractable =
    List.concatMap
        (\a -> absorberMoves state inventory extractable a)
        (absorbersOf state)


absorberMoves :
    Buckets
    -> Set ShapeKey
    -> ExtractableIndex
    -> Absorber
    -> List ( Move, Buckets )
absorberMoves state inventory extractable absorber =
    let
        shapes =
            neighborShapes absorber.target
    in
    helperExtractMoves state inventory extractable absorber shapes
        ++ freePullMoves state inventory absorber shapes


{-| Neighbor shapes for a target stack — every `(value, suit)`
that could legally sit adjacent to any card in the stack.
Returns `ShapeKey`s directly so the loop-inverted absorb
path can use them as `Dict` keys.
-}
neighborShapes : Stack -> List ShapeKey
neighborShapes target =
    target
        |> List.concatMap Cards.neighbors
        |> List.map (\( v, s ) -> ( cardValueToInt v, suitToInt s ))


{-| Loop-inverted absorb: iterate the absorber's neighbor
shapes and look up matching helper positions in the
extractable index, instead of scanning every helper × ci
and filtering by shape. Mirrors Python's 2026-04-25 win.
-}
helperExtractMoves :
    Buckets
    -> Set ShapeKey
    -> ExtractableIndex
    -> Absorber
    -> List ShapeKey
    -> List ( Move, Buckets )
helperExtractMoves state inventory extractable absorber shapes =
    shapes
        |> List.concatMap
            (\shape ->
                Dict.get shape extractable
                    |> Maybe.withDefault []
                    |> List.concatMap
                        (\entry ->
                            case lookupHelperCard state.helper entry.hi entry.ci of
                                Just ( src, extCard ) ->
                                    emitExtractAbsorb
                                        state
                                        inventory
                                        absorber
                                        entry.hi
                                        src
                                        entry.ci
                                        extCard
                                        entry.verb

                                Nothing ->
                                    []
                        )
            )


lookupHelperCard : List Stack -> Int -> Int -> Maybe ( Stack, Card )
lookupHelperCard helper hi ci =
    helper
        |> List.drop hi
        |> List.head
        |> Maybe.andThen
            (\src ->
                src
                    |> List.drop ci
                    |> List.head
                    |> Maybe.map (\c -> ( src, c ))
            )


emitExtractAbsorb :
    Buckets
    -> Set ShapeKey
    -> Absorber
    -> Int
    -> Stack
    -> Int
    -> Card
    -> ExtractVerb
    -> List ( Move, Buckets )
emitExtractAbsorb state inventory absorber hi src ci extCard verb =
    let
        ( helperPieces, spawned ) =
            extractPieces src ci verb

        newHelper =
            withoutAt hi state.helper ++ helperPieces
    in
    [ RightSide, LeftSide ]
        |> List.filterMap
            (\side ->
                let
                    merged =
                        case side of
                            RightSide ->
                                absorber.target ++ [ extCard ]

                            LeftSide ->
                                extCard :: absorber.target
                in
                if not (admissiblePartial merged inventory) then
                    Nothing

                else
                    let
                        ( ntBase, ng ) =
                            removeAbsorber
                                absorber.bucket
                                absorber.idx
                                state.trouble
                                state.growing

                        nt =
                            ntBase ++ spawned

                        ( ngFinal, nc, graduated ) =
                            graduate merged ng state.complete

                        desc : ExtractAbsorbDesc
                        desc =
                            { verb = verb
                            , source = src
                            , extCard = extCard
                            , targetBefore = absorber.target
                            , targetBucketBefore = absorber.bucket
                            , result = merged
                            , side = side
                            , graduated = graduated
                            , spawned = spawned
                            }
                    in
                    Just
                        ( ExtractAbsorb desc
                        , { helper = newHelper
                          , trouble = nt
                          , growing = ngFinal
                          , complete = nc
                          }
                        )
            )


freePullMoves :
    Buckets
    -> Set ShapeKey
    -> Absorber
    -> List ShapeKey
    -> List ( Move, Buckets )
freePullMoves state inventory absorber shapes =
    state.trouble
        |> List.indexedMap (\li ts -> ( li, ts ))
        |> List.concatMap
            (\( li, looseStack ) ->
                if List.length looseStack /= 1 then
                    []

                else if absorber.bucket == Trouble && li == absorber.idx then
                    []

                else
                    case List.head looseStack of
                        Nothing ->
                            []

                        Just loose ->
                            if not (List.member (shapeOfCard loose) shapes) then
                                []

                            else
                                emitFreePull state inventory absorber li loose
            )


emitFreePull :
    Buckets
    -> Set ShapeKey
    -> Absorber
    -> Int
    -> Card
    -> List ( Move, Buckets )
emitFreePull state inventory absorber li loose =
    [ RightSide, LeftSide ]
        |> List.filterMap
            (\side ->
                let
                    merged =
                        case side of
                            RightSide ->
                                absorber.target ++ [ loose ]

                            LeftSide ->
                                loose :: absorber.target
                in
                if not (admissiblePartial merged inventory) then
                    Nothing

                else
                    let
                        ( ntBase, ng ) =
                            removeAbsorber
                                absorber.bucket
                                absorber.idx
                                state.trouble
                                state.growing

                        -- Drop the loose source's TROUBLE entry
                        -- as well, accounting for index shift if
                        -- both removals are in TROUBLE.
                        nt =
                            case absorber.bucket of
                                Trouble ->
                                    let
                                        liInBase =
                                            if li > absorber.idx then
                                                li - 1

                                            else
                                                li
                                    in
                                    withoutAt liInBase ntBase

                                Growing ->
                                    withoutAt li ntBase

                        ( ngFinal, nc, graduated ) =
                            graduate merged ng state.complete

                        desc : FreePullDesc
                        desc =
                            { loose = loose
                            , targetBefore = absorber.target
                            , targetBucketBefore = absorber.bucket
                            , result = merged
                            , side = side
                            , graduated = graduated
                            }
                    in
                    Just
                        ( FreePull desc
                        , { helper = state.helper
                          , trouble = nt
                          , growing = ngFinal
                          , complete = nc
                          }
                        )
            )



-- ============================================================
-- Move type (d) — SHIFT
-- ============================================================


shiftMoves :
    Buckets
    -> Set ShapeKey
    -> ExtractableIndex
    -> List ( Move, Buckets )
shiftMoves state inventory extractable =
    absorbersOf state
        |> List.concatMap
            (\absorber ->
                shiftMovesForAbsorber state inventory extractable absorber
            )


shiftMovesForAbsorber :
    Buckets
    -> Set ShapeKey
    -> ExtractableIndex
    -> Absorber
    -> List ( Move, Buckets )
shiftMovesForAbsorber state inventory extractable absorber =
    let
        shapes =
            neighborShapes absorber.target
    in
    state.helper
        |> List.indexedMap (\srcIdx src -> ( srcIdx, src ))
        |> List.concatMap
            (\( srcIdx, source ) ->
                if List.length source /= 3 then
                    []

                else
                    case classify source of
                        KPureRun ->
                            shiftFromRun
                                state
                                inventory
                                extractable
                                absorber
                                shapes
                                srcIdx
                                source
                                KPureRun

                        KRbRun ->
                            shiftFromRun
                                state
                                inventory
                                extractable
                                absorber
                                shapes
                                srcIdx
                                source
                                KRbRun

                        _ ->
                            []
            )


shiftFromRun :
    Buckets
    -> Set ShapeKey
    -> ExtractableIndex
    -> Absorber
    -> List ShapeKey
    -> Int
    -> Stack
    -> Kind
    -> List ( Move, Buckets )
shiftFromRun state inventory extractable absorber shapes srcIdx source kind =
    -- Try each end (LeftEnd → ci=0, RightEnd → ci=2).
    [ LeftEnd, RightEnd ]
        |> List.concatMap
            (\whichEnd ->
                shiftFromEnd
                    state
                    inventory
                    extractable
                    absorber
                    shapes
                    srcIdx
                    source
                    kind
                    whichEnd
            )


shiftFromEnd :
    Buckets
    -> Set ShapeKey
    -> ExtractableIndex
    -> Absorber
    -> List ShapeKey
    -> Int
    -> Stack
    -> Kind
    -> WhichEnd
    -> List ( Move, Buckets )
shiftFromEnd state inventory extractable absorber shapes srcIdx source kind whichEnd =
    let
        stolenIdx =
            case whichEnd of
                LeftEnd ->
                    0

                RightEnd ->
                    2

        anchorIdx =
            case whichEnd of
                LeftEnd ->
                    2

                RightEnd ->
                    0
    in
    case ( cardAt source stolenIdx, cardAt source anchorIdx ) of
        ( Just stolen, Just anchor ) ->
            if not (List.member (shapeOfCard stolen) shapes) then
                []

            else
                let
                    pValue =
                        case whichEnd of
                            RightEnd ->
                                predecessor anchor.value

                            LeftEnd ->
                                successor anchor.value

                    neededSuits =
                        case kind of
                            KPureRun ->
                                [ anchor.suit ]

                            _ ->
                                List.filter
                                    (\s -> suitColor s /= cardColor anchor)
                                    allSuits
                in
                -- Donor candidates: peel-eligible helpers
                -- whose card matches (pValue, suit) for some
                -- suit in `neededSuits`. Read directly from
                -- the extractable index (filtered to peels)
                -- — same shape as Python's 2026-04-26
                -- consolidation, no separate peelable index.
                neededSuits
                    |> List.concatMap
                        (\pSuit ->
                            let
                                key =
                                    ( cardValueToInt pValue, suitToInt pSuit )
                            in
                            Dict.get key extractable
                                |> Maybe.withDefault []
                                |> List.concatMap
                                    (\entry ->
                                        if entry.verb /= Peel then
                                            []

                                        else if entry.hi == srcIdx then
                                            []

                                        else
                                            shiftEmitFromEntry
                                                state
                                                inventory
                                                absorber
                                                srcIdx
                                                source
                                                kind
                                                whichEnd
                                                stolen
                                                entry
                                    )
                        )

        _ ->
            []


{-| Resolve the donor stack from the index entry and emit
the shift moves. The new_donor stack is computed at use
time by re-running the peel decomposition.
-}
shiftEmitFromEntry :
    Buckets
    -> Set ShapeKey
    -> Absorber
    -> Int
    -> Stack
    -> Kind
    -> WhichEnd
    -> Card
    -> ExtractEntry
    -> List ( Move, Buckets )
shiftEmitFromEntry state inventory absorber srcIdx source kind whichEnd stolen entry =
    case lookupHelperCard state.helper entry.hi entry.ci of
        Just ( donor, pCard ) ->
            let
                ( helperPieces, _ ) =
                    extractPieces donor entry.ci Peel
            in
            case helperPieces of
                [ newDonor ] ->
                    shiftEmit
                        state
                        inventory
                        absorber
                        srcIdx
                        source
                        kind
                        whichEnd
                        stolen
                        pCard
                        entry.hi
                        newDonor

                _ ->
                    []

        Nothing ->
            []


shiftEmit :
    Buckets
    -> Set ShapeKey
    -> Absorber
    -> Int
    -> Stack
    -> Kind
    -> WhichEnd
    -> Card
    -> Card
    -> Int
    -> Stack
    -> List ( Move, Buckets )
shiftEmit state inventory absorber srcIdx source kind whichEnd stolen pCard donorIdx newDonor =
    let
        newSource =
            case ( whichEnd, source ) of
                ( RightEnd, [ a, b, _ ] ) ->
                    [ pCard, a, b ]

                ( LeftEnd, [ _, b, c ] ) ->
                    [ b, c, pCard ]

                _ ->
                    -- Length-3 source guaranteed by caller.
                    source

        sameKind =
            classify newSource == kind
    in
    if not sameKind then
        []

    else
        [ RightSide, LeftSide ]
            |> List.filterMap
                (\side ->
                    let
                        merged =
                            case side of
                                RightSide ->
                                    absorber.target ++ [ stolen ]

                                LeftSide ->
                                    stolen :: absorber.target
                    in
                    if not (admissiblePartial merged inventory) then
                        Nothing

                    else
                        let
                            -- Drop both srcIdx and donorIdx from
                            -- HELPER. Use descending order so
                            -- earlier removal doesn't shift the
                            -- later index.
                            ( hi, lo ) =
                                if srcIdx > donorIdx then
                                    ( srcIdx, donorIdx )

                                else
                                    ( donorIdx, srcIdx )

                            helperWithoutPair =
                                state.helper
                                    |> withoutAt hi
                                    |> withoutAt lo

                            newHelper =
                                helperWithoutPair ++ [ newSource, newDonor ]

                            ( ntBase, ng ) =
                                removeAbsorber
                                    absorber.bucket
                                    absorber.idx
                                    state.trouble
                                    state.growing

                            ( ngFinal, nc, graduated ) =
                                graduate merged ng state.complete

                            donorStack =
                                state.helper
                                    |> List.drop donorIdx
                                    |> List.head
                                    |> Maybe.withDefault []

                            desc : ShiftDesc
                            desc =
                                { source = source
                                , donor = donorStack
                                , stolen = stolen
                                , pCard = pCard
                                , whichEnd = whichEnd
                                , newSource = newSource
                                , newDonor = newDonor
                                , targetBefore = absorber.target
                                , targetBucketBefore = absorber.bucket
                                , merged = merged
                                , side = side
                                , graduated = graduated
                                }
                        in
                        Just
                            ( Shift desc
                            , { helper = newHelper
                              , trouble = ntBase
                              , growing = ngFinal
                              , complete = nc
                              }
                            )
                )


cardAt : Stack -> Int -> Maybe Card
cardAt stack i =
    stack |> List.drop i |> List.head



-- ============================================================
-- Move type (c) — SPLICE
-- ============================================================


spliceMoves : Buckets -> List ( Move, Buckets )
spliceMoves state =
    state.trouble
        |> List.indexedMap (\ti t -> ( ti, t ))
        |> List.concatMap
            (\( ti, t ) ->
                case t of
                    [ loose ] ->
                        spliceFromTrouble state ti loose

                    _ ->
                        []
            )


spliceFromTrouble : Buckets -> Int -> Card -> List ( Move, Buckets )
spliceFromTrouble state ti loose =
    state.helper
        |> List.indexedMap (\hi src -> ( hi, src ))
        |> List.concatMap
            (\( hi, src ) ->
                let
                    n =
                        List.length src
                in
                if n < 4 then
                    []

                else
                    case classify src of
                        KPureRun ->
                            spliceCandidates state ti loose hi src n

                        KRbRun ->
                            spliceCandidates state ti loose hi src n

                        _ ->
                            []
            )


spliceCandidates :
    Buckets
    -> Int
    -> Card
    -> Int
    -> Stack
    -> Int
    -> List ( Move, Buckets )
spliceCandidates state ti loose hi src n =
    List.range 1 (n - 1)
        |> List.concatMap
            (\k ->
                let
                    leftJoin =
                        ( List.take k src ++ [ loose ], List.drop k src )

                    rightJoin =
                        ( List.take k src, loose :: List.drop k src )

                    spliceForJoin side ( left, right ) =
                        if
                            List.length left
                                >= 3
                                && List.length right
                                >= 3
                                && Cards.isLegalStack left
                                && Cards.isLegalStack right
                        then
                            let
                                desc =
                                    { loose = loose
                                    , source = src
                                    , k = k
                                    , side = side
                                    , leftResult = left
                                    , rightResult = right
                                    }

                                newState =
                                    { helper = withoutAt hi state.helper ++ [ left, right ]
                                    , trouble = withoutAt ti state.trouble
                                    , growing = state.growing
                                    , complete = state.complete
                                    }
                            in
                            [ ( Splice desc, newState ) ]

                        else
                            []
                in
                spliceForJoin LeftSide leftJoin
                    ++ spliceForJoin RightSide rightJoin
            )



-- ============================================================
-- Move type (b) — PUSH (TROUBLE → HELPER)
-- ============================================================


pushMoves : Buckets -> List ( Move, Buckets )
pushMoves state =
    state.trouble
        |> List.indexedMap (\ti t -> ( ti, t ))
        |> List.concatMap
            (\( ti, t ) ->
                if List.length t > 2 then
                    []

                else
                    pushOnto state ti t state.helper
            )


pushOnto :
    Buckets
    -> Int
    -> Stack
    -> List Stack
    -> List ( Move, Buckets )
pushOnto state ti t helper =
    helper
        |> List.indexedMap (\hi h -> ( hi, h ))
        |> List.concatMap
            (\( hi, h ) ->
                [ RightSide, LeftSide ]
                    |> List.filterMap
                        (\side ->
                            let
                                merged =
                                    case side of
                                        RightSide ->
                                            h ++ t

                                        LeftSide ->
                                            t ++ h
                            in
                            if not (Cards.isLegalStack merged) then
                                Nothing

                            else
                                let
                                    desc =
                                        { troubleBefore = t
                                        , targetBefore = h
                                        , result = merged
                                        , side = side
                                        }

                                    newState =
                                        { helper = withoutAt hi state.helper ++ [ merged ]
                                        , trouble = withoutAt ti state.trouble
                                        , growing = state.growing
                                        , complete = state.complete
                                        }
                                in
                                Just ( Push desc, newState )
                        )
            )



-- ============================================================
-- Move type (b') — ENGULF (GROWING → HELPER, graduates)
-- ============================================================


engulfMoves : Buckets -> List ( Move, Buckets )
engulfMoves state =
    state.growing
        |> List.indexedMap (\gi g -> ( gi, g ))
        |> List.concatMap
            (\( gi, g ) -> engulfFromGrowing state gi g)


engulfFromGrowing :
    Buckets
    -> Int
    -> Stack
    -> List ( Move, Buckets )
engulfFromGrowing state gi g =
    state.helper
        |> List.indexedMap (\hi h -> ( hi, h ))
        |> List.concatMap
            (\( hi, h ) ->
                [ RightSide, LeftSide ]
                    |> List.filterMap
                        (\side ->
                            let
                                merged =
                                    case side of
                                        RightSide ->
                                            h ++ g

                                        LeftSide ->
                                            g ++ h
                            in
                            if not (Cards.isLegalStack merged) then
                                Nothing

                            else
                                let
                                    desc =
                                        { troubleBefore = g
                                        , targetBefore = h
                                        , result = merged
                                        , side = side
                                        }

                                    newState =
                                        { helper = withoutAt hi state.helper
                                        , trouble = state.trouble
                                        , growing = withoutAt gi state.growing
                                        , complete = state.complete ++ [ merged ]
                                        }
                                in
                                Just ( Push desc, newState )
                        )
            )
