module Game.Agent.EnumeratorTest exposing (suite)

{-| Snapshot tests for `Game.Agent.Enumerator.enumerateMoves`,
mirroring `python/test_bfs_enumerate.py`. Each test feeds a
hand-built 4-bucket state and asserts at least one move of
the named type fires. SHIFT scenarios are deferred until that
branch lands; until then the test suite just doesn't include
them.
-}

import Expect
import Game.Agent.Buckets exposing (Buckets)
import Game.Agent.Enumerator as Enumerator exposing (enumerateMoves)
import Game.Agent.Move as Move exposing (Move(..))
import Game.Rules.Card exposing (Card, OriginDeck(..))
import Test exposing (..)


card : String -> Card
card label =
    case Game.Rules.Card.cardFromLabel label DeckOne of
        Just c ->
            c

        Nothing ->
            Debug.todo ("bad label: " ++ label)


cardD2 : String -> Card
cardD2 label =
    case Game.Rules.Card.cardFromLabel label DeckTwo of
        Just c ->
            c

        Nothing ->
            Debug.todo ("bad label: " ++ label)


hasMoveType : (Move -> Bool) -> List ( Move, Buckets ) -> Bool
hasMoveType pred moves =
    List.any (\( m, _ ) -> pred m) moves


isExtractAbsorb : Move -> Bool
isExtractAbsorb m =
    case m of
        ExtractAbsorb _ ->
            True

        _ ->
            False


isFreePull : Move -> Bool
isFreePull m =
    case m of
        FreePull _ ->
            True

        _ ->
            False


isPush : Move -> Bool
isPush m =
    case m of
        Push _ ->
            True

        _ ->
            False


isSplice : Move -> Bool
isSplice m =
    case m of
        Splice _ ->
            True

        _ ->
            False


isShift : Move -> Bool
isShift m =
    case m of
        Shift _ ->
            True

        _ ->
            False


suite : Test
suite =
    describe "Game.Agent.Enumerator.enumerateMoves"
        [ test "simple peel into trouble singleton fires extract_absorb" <|
            \_ ->
                let
                    state =
                        { helper = [ [ card "5H", card "6H", card "7H", card "8H" ] ]
                        , trouble = [ [ card "4H" ] ]
                        , growing = []
                        , complete = []
                        }
                in
                enumerateMoves state
                    |> hasMoveType isExtractAbsorb
                    |> Expect.equal True
        , test "engulf: GROWING [AC 2D] + HELPER [3S 4D 5C] yields a Push" <|
            \_ ->
                let
                    state =
                        { helper = [ [ card "3S", card "4D", card "5C" ] ]
                        , trouble = []
                        , growing = [ [ card "AC", card "2D" ] ]
                        , complete = []
                        }
                in
                enumerateMoves state
                    |> hasMoveType isPush
                    |> Expect.equal True
        , test "splice: 5D' inserts into pure-D 6-run" <|
            \_ ->
                let
                    state =
                        { helper =
                            [ [ card "3D", card "4D", card "5D", card "6D", card "7D", card "8D" ] ]
                        , trouble = [ [ cardD2 "5D" ] ]
                        , growing = []
                        , complete = []
                        }
                in
                enumerateMoves state
                    |> hasMoveType isSplice
                    |> Expect.equal True
        , test "push: TROUBLE 2-partial onto helper run" <|
            \_ ->
                let
                    state =
                        { helper = [ [ card "9C", card "TC", card "JC" ] ]
                        , trouble = [ [ card "QC", card "KC" ] ]
                        , growing = []
                        , complete = []
                        }
                in
                enumerateMoves state
                    |> hasMoveType isPush
                    |> Expect.equal True
        , test "free_pull: loose singleton onto growing 2-partial" <|
            \_ ->
                let
                    state =
                        { helper = []
                        , trouble = [ [ card "4H" ], [ card "5H" ] ]
                        , growing = [ [ card "6H", card "7H" ] ]
                        , complete = []
                        }
                in
                enumerateMoves state
                    |> hasMoveType isFreePull
                    |> Expect.equal True
        , test "split_out: interior of length-3 run becomes extract_absorb with SplitOut verb" <|
            \_ ->
                -- focus is the rb-run partial [2H 3S] (alternating
                -- colors, consecutive values). It needs a red 4 to
                -- graduate. 4D is in helper [3D 4D 5D] at ci=1 —
                -- interior of a length-3 run. Only split_out can
                -- extract it.
                let
                    state =
                        { helper = [ [ card "3D", card "4D", card "5D" ] ]
                        , trouble = [ [ card "2H", card "3S" ] ]
                        , growing = []
                        , complete = []
                        }

                    isSplitOut m =
                        case m of
                            ExtractAbsorb d ->
                                d.verb == Move.SplitOut

                            _ ->
                                False
                in
                enumerateMoves state
                    |> hasMoveType isSplitOut
                    |> Expect.equal True
        , test "shift: 8C-pops-JC idiom (length-3 run + length-4 set donor)" <|
            \_ ->
                -- Third helper [9D TD JD] provides 10D so the
                -- post-shift merge [JC QH] passes the doomed-
                -- third filter (10D is a viable completion).
                let
                    state =
                        { helper =
                            [ [ card "9C", card "TC", card "JC" ]
                            , [ card "8D", card "8S", card "8H", card "8C" ]
                            , [ card "9D", card "TD", card "JD" ]
                            ]
                        , trouble = [ [ card "QH" ] ]
                        , growing = []
                        , complete = []
                        }
                in
                enumerateMoves state
                    |> hasMoveType isShift
                    |> Expect.equal True
        , test "doomed-third filter blocks doomed peels" <|
            \_ ->
                -- Trouble [4S], helper [5H 6H 7H 8H] (pure-H run).
                -- A peel of 5H onto 4S would form rb-partial [4S 5H]
                -- needing 3-red or 6-black. Inventory is 4S/5H/6H/
                -- 7H/8H — 6H is RED, no 3-red anywhere. Doomed.
                -- Filter must reject every extract_absorb.
                let
                    state =
                        { helper = [ [ card "5H", card "6H", card "7H", card "8H" ] ]
                        , trouble = [ [ card "4S" ] ]
                        , growing = []
                        , complete = []
                        }

                    extracts =
                        enumerateMoves state
                            |> List.filter (\( m, _ ) -> isExtractAbsorb m)
                in
                List.length extracts
                    |> Expect.equal 0
        , test "doomed-third filter admits when completion exists" <|
            \_ ->
                -- Same as above but add helper [3D 4D 5D] supplying
                -- a 3-red. The partial [4S 5H] is no longer doomed,
                -- so the peel of 5H is admitted.
                let
                    state =
                        { helper =
                            [ [ card "5H", card "6H", card "7H", card "8H" ]
                            , [ card "3D", card "4D", card "5D" ]
                            ]
                        , trouble = [ [ card "4S" ] ]
                        , growing = []
                        , complete = []
                        }
                in
                enumerateMoves state
                    |> hasMoveType isExtractAbsorb
                    |> Expect.equal True
        , test "state-level filter: yields nothing when a growing 2-partial is doomed" <|
            \_ ->
                -- Growing [7C 7D] (set partial of 7s); inventory has
                -- only 7C/7D in trouble, no 7H/7S anywhere → doomed.
                -- enumerate_moves must short-circuit to [].
                let
                    state =
                        { helper = [ [ card "2C", card "3D", card "4C" ] ]
                        , trouble = []
                        , growing = [ [ card "7C", card "7D" ] ]
                        , complete = []
                        }
                in
                enumerateMoves state
                    |> Expect.equal []
        , test "focus rule: only moves touching the focus are yielded" <|
            \_ ->
                -- Two trouble singletons: [4H] (focus) and [9C]
                -- (queued sibling). Without the focus rule,
                -- moves on the 9C absorber would also enumerate.
                -- The focused enumerator must only yield moves
                -- whose target is the focus [4H].
                --
                -- Helper [5H 6H 7H 8H] (pure-H length-4) provides
                -- 5H peel onto 4H → [4H 5H] partial; 6H stays in
                -- inventory as a completion candidate so doomed-
                -- third doesn't reject the merge.
                let
                    buckets =
                        { helper = [ [ card "5H", card "6H", card "7H", card "8H" ] ]
                        , trouble = [ [ card "4H" ], [ card "9C" ] ]
                        , growing = []
                        , complete = []
                        }

                    state =
                        { buckets = buckets
                        , lineage = Enumerator.initialLineage buckets
                        }

                    focusedMoves =
                        Enumerator.enumerateFocused state

                    focus =
                        [ card "4H" ]

                    allTouchFocus =
                        focusedMoves
                            |> List.all
                                (\( m, _ ) ->
                                    Enumerator.moveTouchesFocus m focus
                                )
                in
                Expect.all
                    [ \_ -> List.length focusedMoves |> Expect.greaterThan 0
                    , \_ -> allTouchFocus |> Expect.equal True
                    ]
                    ()
        , test "focus rule: lineage updates to the merged partial after a non-graduating absorb" <|
            \_ ->
                -- Focus = [4H]. Peel 5H from helper [5H 6H 7H 8H]
                -- absorbs 5H onto focus → 2-partial [4H 5H].
                -- Lineage should advance from [[4H]] to either
                -- [[4H,5H]] or [[5H,4H]] depending on which side
                -- the merge picked.
                let
                    buckets =
                        { helper = [ [ card "5H", card "6H", card "7H", card "8H" ] ]
                        , trouble = [ [ card "4H" ] ]
                        , growing = []
                        , complete = []
                        }

                    state =
                        { buckets = buckets
                        , lineage = Enumerator.initialLineage buckets
                        }

                    after5HPeel =
                        Enumerator.enumerateFocused state
                            |> List.filter
                                (\( m, _ ) ->
                                    case m of
                                        ExtractAbsorb d ->
                                            d.extCard == card "5H"

                                        _ ->
                                            False
                                )
                            |> List.head
                in
                case after5HPeel of
                    Just ( _, newState ) ->
                        case newState.lineage of
                            [ [ a, b ] ] ->
                                ((a == card "4H" && b == card "5H")
                                    || (a == card "5H" && b == card "4H")
                                )
                                    |> Expect.equal True

                            other ->
                                Expect.fail
                                    ("expected single 2-partial lineage, got "
                                        ++ Debug.toString other
                                    )

                    Nothing ->
                        Expect.fail "expected to find a peel-5H move"
        , test "enumerator does not mutate input state" <|
            \_ ->
                let
                    helper =
                        [ [ card "5H", card "6H", card "7H", card "8H" ] ]

                    trouble =
                        [ [ card "4H" ], [ card "9H" ] ]

                    growing =
                        [ [ card "JC", card "QC" ] ]

                    state =
                        { helper = helper
                        , trouble = trouble
                        , growing = growing
                        , complete = []
                        }
                in
                ( state.helper, state.trouble, state.growing )
                    |> Expect.equal ( helper, trouble, growing )
        ]
