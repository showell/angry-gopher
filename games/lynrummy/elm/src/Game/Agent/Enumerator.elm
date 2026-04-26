module Game.Agent.Enumerator exposing (enumerateMoves)

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
        , suitColor
        )
import Game.StackType as StackType
    exposing
        ( CardStackType(..)
        , predecessor
        , successor
        )



-- ============================================================
-- Public entry
-- ============================================================


{-| All legal next moves from `state`. Each entry is
`(move, postState)`. The order matches Python's enumeration
order so within-level sort produces identical BFS behavior.
-}
enumerateMoves : Buckets -> List ( Move, Buckets )
enumerateMoves state =
    extractAndAbsorbMoves state
        ++ shiftMoves state
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
            let
                left =
                    List.take ci source

                right =
                    List.drop (ci + 1) source

                helpers =
                    List.filter (\s -> List.length s >= 3) [ left, right ]

                spawned =
                    List.filter (\s -> List.length s < 3) [ left, right ]
            in
            ( helpers, spawned )

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


extractAndAbsorbMoves : Buckets -> List ( Move, Buckets )
extractAndAbsorbMoves state =
    List.concatMap
        (\a -> absorberMoves state a)
        (absorbersOf state)


absorberMoves : Buckets -> Absorber -> List ( Move, Buckets )
absorberMoves state absorber =
    let
        shapes =
            neighborShapes absorber.target
    in
    helperExtractMoves state absorber shapes
        ++ freePullMoves state absorber shapes


neighborShapes : Stack -> List ( CardValue, Suit )
neighborShapes target =
    List.concatMap Cards.neighbors target


helperExtractMoves :
    Buckets
    -> Absorber
    -> List ( CardValue, Suit )
    -> List ( Move, Buckets )
helperExtractMoves state absorber shapes =
    state.helper
        |> List.indexedMap (\hi src -> ( hi, src ))
        |> List.concatMap
            (\( hi, src ) ->
                let
                    kind =
                        classify src

                    n =
                        List.length src
                in
                src
                    |> List.indexedMap (\ci c -> ( ci, c ))
                    |> List.concatMap
                        (\( ci, c ) ->
                            if not (shapeMatches c shapes) then
                                []

                            else
                                case verbFor kind n ci of
                                    Nothing ->
                                        []

                                    Just verb ->
                                        emitExtractAbsorb
                                            state
                                            absorber
                                            hi
                                            src
                                            ci
                                            c
                                            verb
                        )
            )


shapeMatches : Card -> List ( CardValue, Suit ) -> Bool
shapeMatches c shapes =
    List.any (\( v, s ) -> v == c.value && s == c.suit) shapes


emitExtractAbsorb :
    Buckets
    -> Absorber
    -> Int
    -> Stack
    -> Int
    -> Card
    -> ExtractVerb
    -> List ( Move, Buckets )
emitExtractAbsorb state absorber hi src ci extCard verb =
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
                if not (Cards.isPartialOk merged) then
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
    -> Absorber
    -> List ( CardValue, Suit )
    -> List ( Move, Buckets )
freePullMoves state absorber shapes =
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
                            if not (shapeMatches loose shapes) then
                                []

                            else
                                emitFreePull state absorber li loose
            )


emitFreePull :
    Buckets
    -> Absorber
    -> Int
    -> Card
    -> List ( Move, Buckets )
emitFreePull state absorber li loose =
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
                if not (Cards.isPartialOk merged) then
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


shiftMoves : Buckets -> List ( Move, Buckets )
shiftMoves state =
    let
        peelable =
            peelableCards state.helper
    in
    absorbersOf state
        |> List.concatMap
            (\absorber ->
                shiftMovesForAbsorber state absorber peelable
            )


shiftMovesForAbsorber :
    Buckets
    -> Absorber
    -> List ( Card, Int, Stack )
    -> List ( Move, Buckets )
shiftMovesForAbsorber state absorber peelable =
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
                                absorber
                                shapes
                                peelable
                                srcIdx
                                source
                                KPureRun

                        KRbRun ->
                            shiftFromRun
                                state
                                absorber
                                shapes
                                peelable
                                srcIdx
                                source
                                KRbRun

                        _ ->
                            []
            )


shiftFromRun :
    Buckets
    -> Absorber
    -> List ( CardValue, Suit )
    -> List ( Card, Int, Stack )
    -> Int
    -> Stack
    -> Kind
    -> List ( Move, Buckets )
shiftFromRun state absorber shapes peelable srcIdx source kind =
    -- Try each end (LeftEnd → ci=0, RightEnd → ci=2).
    [ LeftEnd, RightEnd ]
        |> List.concatMap
            (\whichEnd ->
                shiftFromEnd
                    state
                    absorber
                    shapes
                    peelable
                    srcIdx
                    source
                    kind
                    whichEnd
            )


shiftFromEnd :
    Buckets
    -> Absorber
    -> List ( CardValue, Suit )
    -> List ( Card, Int, Stack )
    -> Int
    -> Stack
    -> Kind
    -> WhichEnd
    -> List ( Move, Buckets )
shiftFromEnd state absorber shapes peelable srcIdx source kind whichEnd =
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
            if not (shapeMatches stolen shapes) then
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
                peelable
                    |> List.concatMap
                        (\( pCard, donorIdx, newDonor ) ->
                            if donorIdx == srcIdx then
                                []

                            else if pCard.value /= pValue then
                                []

                            else if not (List.member pCard.suit neededSuits) then
                                []

                            else
                                shiftEmit
                                    state
                                    absorber
                                    srcIdx
                                    source
                                    kind
                                    whichEnd
                                    stolen
                                    pCard
                                    donorIdx
                                    newDonor
                        )

        _ ->
            []


shiftEmit :
    Buckets
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
shiftEmit state absorber srcIdx source kind whichEnd stolen pCard donorIdx newDonor =
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
                    if not (Cards.isPartialOk merged) then
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


{-| Pre-compute every (card, donorIdx, newDonor) triple where
the card can be peeled cleanly: from a length-4+ set (any
position) or a length-4+ pure/rb run (end positions only).
-}
peelableCards : List Stack -> List ( Card, Int, Stack )
peelableCards helper =
    helper
        |> List.indexedMap (\di donor -> ( di, donor ))
        |> List.concatMap
            (\( di, donor ) ->
                let
                    n =
                        List.length donor
                in
                if n < 4 then
                    []

                else
                    case classify donor of
                        KSet ->
                            donor
                                |> List.indexedMap (\ci c -> ( ci, c ))
                                |> List.map
                                    (\( _, c ) ->
                                        ( c, di, List.filter ((/=) c) donor )
                                    )

                        KPureRun ->
                            runEnds donor di

                        KRbRun ->
                            runEnds donor di

                        _ ->
                            []
            )


runEnds : Stack -> Int -> List ( Card, Int, Stack )
runEnds donor di =
    let
        n =
            List.length donor

        firstCard =
            List.head donor

        lastCard =
            List.drop (n - 1) donor |> List.head

        leftEnd =
            firstCard
                |> Maybe.map (\c -> ( c, di, List.drop 1 donor ))

        rightEnd =
            lastCard
                |> Maybe.map (\c -> ( c, di, List.take (n - 1) donor ))
    in
    List.filterMap identity [ leftEnd, rightEnd ]



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
