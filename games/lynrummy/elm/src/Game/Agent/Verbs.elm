module Game.Agent.Verbs exposing (moveToPrimitives)

{-| Translate one BFS `Move` into a sequence of `WireAction`s
(server-bound primitives). Mirrors `python/verbs.py`'s
`step_to_primitives` but skips the index→content layer:
`WireAction` is content-based, so each emitted action
references a `CardStack` directly.

Geometry pre-flight (reactively pre-moving target stacks
before merges) lives in a separate module —
`Game.Agent.GeometryPlan.planActions`. Callers that send
emitted primitives to a referee should pipe through that
wrapper; this module stays focused on the logical
decomposition and emits in-place merges.

-}

import Game.Agent.Move as Move
    exposing
        ( ExtractAbsorbDesc
        , ExtractVerb(..)
        , FreePullDesc
        , Move(..)
        , PushDesc
        , ShiftDesc
        , SpliceDesc
        , WhichEnd(..)
        )
import Game.BoardActions as BoardActions
import Game.Card exposing (Card)
import Game.CardStack as CardStack exposing (CardStack, stacksEqual)
import Game.PlaceStack as PlaceStack
import Game.WireAction exposing (WireAction(..))


{-| Translate one move against the live board into a list of
WireActions in send order.
-}
moveToPrimitives : List CardStack -> Move -> List WireAction
moveToPrimitives board move =
    case move of
        ExtractAbsorb d ->
            extractAbsorbPrims board d

        FreePull d ->
            freePullPrims board d

        Push d ->
            pushPrims board d

        Splice d ->
            splicePrims board d

        Shift d ->
            shiftPrims board d



-- ============================================================
-- Stack lookup + local simulator
-- ============================================================


{-| Find a CardStack on `board` whose card sequence matches
`cards` exactly (by content, ignoring loc).
-}
findByCards : List Card -> List CardStack -> Maybe CardStack
findByCards cards =
    let
        cardsOf s =
            List.map .card s.boardCards
    in
    List.filter (\s -> cardsOf s == cards) >> List.head


{-| Apply a WireAction to a local board copy. Mirrors
`Game.Reducer.applyAction`'s board-only branches.
-}
applyOnBoard : WireAction -> List CardStack -> List CardStack
applyOnBoard action board =
    case action of
        Split { stack, cardIndex } ->
            case findReal stack board of
                Just real ->
                    List.filter (not << stacksEqual real) board
                        ++ CardStack.split cardIndex real

                Nothing ->
                    board

        MergeStack { source, target, side } ->
            case ( findReal source board, findReal target board ) of
                ( Just realSrc, Just realTgt ) ->
                    case BoardActions.tryStackMerge realTgt realSrc side of
                        Just change ->
                            applyChange change board

                        Nothing ->
                            board

                _ ->
                    board

        MoveStack { stack, newLoc } ->
            case findReal stack board of
                Just real ->
                    applyChange
                        (BoardActions.moveStack real newLoc)
                        board

                Nothing ->
                    board

        _ ->
            board


findReal : CardStack -> List CardStack -> Maybe CardStack
findReal target =
    List.filter (stacksEqual target) >> List.head


applyChange : BoardActions.BoardChange -> List CardStack -> List CardStack
applyChange change board =
    List.filter
        (\s -> not (List.any (stacksEqual s) change.stacksToRemove))
        board
        ++ change.stacksToAdd



-- ============================================================
-- Side translation (Move.Side ↔ BoardActions.Side)
-- ============================================================


toBoardSide : Move.Side -> BoardActions.Side
toBoardSide s =
    case s of
        Move.LeftSide ->
            BoardActions.Left

        Move.RightSide ->
            BoardActions.Right



-- ============================================================
-- Per-verb translators
-- ============================================================


extractAbsorbPrims :
    List CardStack
    -> ExtractAbsorbDesc
    -> List WireAction
extractAbsorbPrims board d =
    if isStealFromSet d then
        -- Mirrors python/verbs.py's `verb == "steal" and
        -- kind == "set"` branch: dismantle the length-3 set
        -- into three singletons by splitting from the LEFT
        -- twice, regardless of where the ext card sits in
        -- the source. The BFS plan reasons about each remnant
        -- card as an independent trouble singleton, so leaving
        -- them as a pair stalls subsequent push moves that
        -- can't find their content-keyed source. Identifying
        -- the ext card by content (rather than by index)
        -- lets the same code path serve ext-at-0, ext-at-1,
        -- and ext-at-2.
        stealFromSetPrims board d

    else
        let
            ci =
                indexOf d.extCard d.source

            ( isolatePrims, postIsolate ) =
                isolateCard board d.source ci d.verb

            followUp =
                if isInteriorSetPeel d then
                    interiorSetReassemble d postIsolate

                else
                    []

            postFollowUp =
                List.foldl applyOnBoard postIsolate followUp

            absorbStep =
                case ( findByCards [ d.extCard ] postFollowUp, findByCards d.targetBefore postFollowUp ) of
                    ( Just singleton, Just target ) ->
                        [ MergeStack
                            { source = singleton
                            , target = target
                            , side = toBoardSide d.side
                            }
                        ]

                    _ ->
                        []
        in
        isolatePrims ++ followUp ++ absorbStep


isStealFromSet : ExtractAbsorbDesc -> Bool
isStealFromSet d =
    d.verb == Steal && allSameValue d.source && List.length d.source == 3


stealFromSetPrims :
    List CardStack
    -> ExtractAbsorbDesc
    -> List WireAction
stealFromSetPrims board d =
    case findByCards d.source board of
        Nothing ->
            []

        Just src ->
            let
                ci =
                    indexOf d.extCard d.source

                n =
                    List.length d.source

                ( firstSplitIndex, residueCards ) =
                    if ci == n - 1 then
                        -- X at right end. Split off the right
                        -- card first so X visibly detaches; the
                        -- residue is the same-value pair to
                        -- the left.
                        ( splitCardIndex (n - 1) n
                        , List.take (n - 1) d.source
                        )

                    else
                        -- ci == 0 (left end) or ci == 1
                        -- (interior, rare). Split @1 first so
                        -- s[0] (ci==0 case: that's X) detaches
                        -- left, or X's pair is isolated
                        -- (ci==1 case).
                        ( splitCardIndex 1 n
                        , List.drop 1 d.source
                        )

                first =
                    Split { stack = src, cardIndex = firstSplitIndex }

                boardAfterFirst =
                    applyOnBoard first board
            in
            case findByCards residueCards boardAfterFirst of
                Nothing ->
                    []

                Just residueStack ->
                    let
                        second =
                            Split
                                { stack = residueStack
                                , cardIndex = splitCardIndex 1 (List.length residueCards)
                                }

                        boardAfterSecond =
                            applyOnBoard second boardAfterFirst
                    in
                    case
                        ( findByCards [ d.extCard ] boardAfterSecond
                        , findByCards d.targetBefore boardAfterSecond
                        )
                    of
                        ( Just extSt, Just tgt ) ->
                            [ first
                            , second
                            , MergeStack
                                { source = extSt
                                , target = tgt
                                , side = toBoardSide d.side
                                }
                            ]

                        _ ->
                            []


freePullPrims : List CardStack -> FreePullDesc -> List WireAction
freePullPrims board d =
    case ( findByCards [ d.loose ] board, findByCards d.targetBefore board ) of
        ( Just looseStack, Just target ) ->
            [ MergeStack
                { source = looseStack
                , target = target
                , side = toBoardSide d.side
                }
            ]

        _ ->
            []


pushPrims : List CardStack -> PushDesc -> List WireAction
pushPrims board d =
    case ( findByCards d.troubleBefore board, findByCards d.targetBefore board ) of
        ( Just src, Just target ) ->
            [ MergeStack
                { source = src
                , target = target
                , side = toBoardSide d.side
                }
            ]

        _ ->
            []


splicePrims : List CardStack -> SpliceDesc -> List WireAction
splicePrims board d =
    let
        ( splitPrims, postSplit ) =
            planSplit board d.source d.k

        leftChunk =
            List.take d.k d.source

        rightChunk =
            List.drop d.k d.source

        mergeStep =
            case d.side of
                Move.LeftSide ->
                    -- Loose joins left chunk's right end.
                    case ( findByCards [ d.loose ] postSplit, findByCards leftChunk postSplit ) of
                        ( Just looseSt, Just leftSt ) ->
                            [ MergeStack
                                { source = looseSt
                                , target = leftSt
                                , side = BoardActions.Right
                                }
                            ]

                        _ ->
                            []

                Move.RightSide ->
                    -- Loose joins right chunk's left end.
                    case ( findByCards [ d.loose ] postSplit, findByCards rightChunk postSplit ) of
                        ( Just looseSt, Just rightSt ) ->
                            [ MergeStack
                                { source = looseSt
                                , target = rightSt
                                , side = BoardActions.Left
                                }
                            ]

                        _ ->
                            []
    in
    splitPrims ++ mergeStep


{-| Shift verb: p_card moves from donor INTO source's
opposite-end position, displacing stolen, which then absorbs
onto target.

Sequence (matches python/verbs._shift_prims):

  1. Isolate p_card from donor (split + interior-set
     reassemble if applicable).
  2. Merge p_card onto source on the OPPOSITE side from
     stolen — source becomes augmented length+1.
  3. Pop stolen off the augmented source by splitting at its
     end.
  4. Merge stolen onto target.

The ordering reflects the LOGIC of a shift: the user sees
p_card join source (the swap moment), then stolen pop and
absorb. The earlier ordering pre-disassembled source before
p_card touched it, which obscured the swap (Steve, 2026-04-27).
-}
shiftPrims : List CardStack -> ShiftDesc -> List WireAction
shiftPrims board d =
    case ( findByCards d.donor board, findByCards d.source board ) of
        ( Just _, Just _ ) ->
            let
                pi =
                    indexOf d.pCard d.donor

                donorIsSet =
                    allSameValue d.donor

                ( donorPrims, postDonor ) =
                    isolateCard board d.donor pi Peel

                donorFollowUp =
                    if donorIsSet && pi > 0 && pi < List.length d.donor - 1 then
                        interiorSetReassembleDonor d postDonor

                    else
                        []

                postDonorAssembled =
                    List.foldl applyOnBoard postDonor donorFollowUp

                ( pSide, augmentedSource, splitK ) =
                    case d.whichEnd of
                        Move.LeftEnd ->
                            -- stolen at LEFT of source; p_card joins RIGHT.
                            ( BoardActions.Right
                            , d.source ++ [ d.pCard ]
                            , 1
                            )

                        Move.RightEnd ->
                            -- stolen at RIGHT of source; p_card joins LEFT.
                            ( BoardActions.Left
                            , d.pCard :: d.source
                            , List.length d.source
                            )

                pMergeStep =
                    case ( findByCards [ d.pCard ] postDonorAssembled, findByCards d.source postDonorAssembled ) of
                        ( Just pSt, Just srcSt ) ->
                            [ MergeStack { source = pSt, target = srcSt, side = pSide } ]

                        _ ->
                            []

                postPMerge =
                    List.foldl applyOnBoard postDonorAssembled pMergeStep

                ( stolenSplitPrims, postStolenSplit ) =
                    planSplit postPMerge augmentedSource splitK

                stolenMergeStep =
                    case ( findByCards [ d.stolen ] postStolenSplit, findByCards d.targetBefore postStolenSplit ) of
                        ( Just stlnSt, Just tgtSt ) ->
                            [ MergeStack
                                { source = stlnSt
                                , target = tgtSt
                                , side = toBoardSide d.side
                                }
                            ]

                        _ ->
                            []
            in
            donorPrims
                ++ donorFollowUp
                ++ pMergeStep
                ++ stolenSplitPrims
                ++ stolenMergeStep

        _ ->
            []



-- ============================================================
-- Card isolation (the split sequence)
-- ============================================================


{-| Generate the split primitives that leave the card at
`ci` of `source` as a singleton, plus the post-state board.

  - End extracts (ci=0 or ci=n-1): one split.
  - Interior extracts: split after ci, then split the right
    chunk after 1.

Returns (prims, postState). The translator chains these.

-}
isolateCard :
    List CardStack
    -> List Card
    -> Int
    -> ExtractVerb
    -> ( List WireAction, List CardStack )
isolateCard board source ci _ =
    let
        n =
            List.length source
    in
    case findByCards source board of
        Nothing ->
            ( [], board )

        Just srcStack ->
            if ci == 0 && n > 1 then
                let
                    ( pre, board1 ) =
                        planSplit board source 1
                in
                ( pre, board1 )

            else if ci == n - 1 && n > 1 then
                let
                    ( pre, board1 ) =
                        planSplit board source (n - 1)
                in
                ( pre, board1 )

            else
                let
                    -- First split: source @ k=ci → left=source[:ci], right=source[ci:].
                    ( firstPrims, afterFirst ) =
                        planSplit board source ci

                    rightChunk =
                        List.drop ci source

                    ( secondPrims, afterSecond ) =
                        planSplit afterFirst rightChunk 1
                in
                ( firstPrims ++ secondPrims, afterSecond )


{-| Geometry-agnostic split planner. Emits exactly one Split
primitive (or zero, if the source isn't on the board). Any
necessary pre-flight MoveStack to keep the post-split board
clean is added later by `Game.Agent.GeometryPlan.planActions`.
-}
planSplit :
    List CardStack
    -> List Card
    -> Int
    -> ( List WireAction, List CardStack )
planSplit board source k =
    let
        n =
            List.length source

        ci =
            splitCardIndex k n

        donorStack =
            findByCards source board
    in
    case donorStack of
        Just real ->
            let
                splitPrim =
                    Split { stack = real, cardIndex = ci }
            in
            ( [ splitPrim ], applyOnBoard splitPrim board )

        Nothing ->
            ( [], board )



-- ============================================================
-- Set-peel reassembly
-- ============================================================


isInteriorSetPeel : ExtractAbsorbDesc -> Bool
isInteriorSetPeel d =
    let
        ci =
            indexOf d.extCard d.source

        n =
            List.length d.source
    in
    d.verb == Peel && allSameValue d.source && ci > 0 && ci < n - 1


interiorSetReassemble :
    ExtractAbsorbDesc
    -> List CardStack
    -> List WireAction
interiorSetReassemble d board =
    let
        ci =
            indexOf d.extCard d.source

        leftChunk =
            List.take ci d.source

        tailChunk =
            List.drop (ci + 1) d.source
    in
    case ( findByCards tailChunk board, findByCards leftChunk board ) of
        ( Just tail, Just left ) ->
            [ MergeStack
                { source = tail
                , target = left
                , side = BoardActions.Right
                }
            ]

        _ ->
            []


interiorSetReassembleDonor :
    ShiftDesc
    -> List CardStack
    -> List WireAction
interiorSetReassembleDonor d board =
    let
        ci =
            indexOf d.pCard d.donor

        leftChunk =
            List.take ci d.donor

        tailChunk =
            List.drop (ci + 1) d.donor
    in
    case ( findByCards tailChunk board, findByCards leftChunk board ) of
        ( Just tail, Just left ) ->
            [ MergeStack
                { source = tail
                , target = left
                , side = BoardActions.Right
                }
            ]

        _ ->
            []



-- ============================================================
-- Helpers
-- ============================================================


{-| Translate "split such that left half has `k` cards, right
has `n - k`" into the underlying `CardStack.split`'s
`cardIndex` parameter. Hides the leftSplit/rightSplit
asymmetry of the underlying implementation.
-}
splitCardIndex : Int -> Int -> Int
splitCardIndex k n =
    if k <= n // 2 then
        k - 1

    else
        k


allSameValue : List Card -> Bool
allSameValue cards =
    case cards of
        [] ->
            True

        first :: rest ->
            List.all (\c -> c.value == first.value) rest


indexOf : Card -> List Card -> Int
indexOf target cards =
    indexOfHelp target cards 0


indexOfHelp : Card -> List Card -> Int -> Int
indexOfHelp target cards i =
    case cards of
        [] ->
            -1

        c :: rest ->
            if c == target then
                i

            else
                indexOfHelp target rest (i + 1)
