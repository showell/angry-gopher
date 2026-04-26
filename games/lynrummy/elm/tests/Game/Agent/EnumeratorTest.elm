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
import Game.Agent.Enumerator exposing (enumerateMoves)
import Game.Agent.Move as Move exposing (Move(..))
import Game.Card exposing (Card, OriginDeck(..))
import Test exposing (..)


card : String -> Card
card label =
    case Game.Card.cardFromLabel label DeckOne of
        Just c ->
            c

        Nothing ->
            Debug.todo ("bad label: " ++ label)


cardD2 : String -> Card
cardD2 label =
    case Game.Card.cardFromLabel label DeckTwo of
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
        , test "shift: 8C-pops-JC idiom (length-3 run + length-4 set donor)" <|
            \_ ->
                let
                    state =
                        { helper =
                            [ [ card "9C", card "TC", card "JC" ]
                            , [ card "8D", card "8S", card "8H", card "8C" ]
                            ]
                        , trouble = [ [ card "QH" ] ]
                        , growing = []
                        , complete = []
                        }
                in
                enumerateMoves state
                    |> hasMoveType isShift
                    |> Expect.equal True
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

                    _ =
                        enumerateMoves state
                in
                ( state.helper, state.trouble, state.growing )
                    |> Expect.equal ( helper, trouble, growing )
        ]
