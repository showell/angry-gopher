module Game.ConformanceTests exposing (suite)

{-| End-to-end conformance test runner.

Parses every embedded `.dsl` file in `Game.DslContent.allFiles`
via `Game.ConformanceDsl.parseConformanceDsl`, then dispatches
each scenario to its op-specific verifier. Verifiers are
hand-written Elm functions in this module (formerly emitted
as templated Elm code from `cmd/fixturegen`).

Phase 3 of the DSL retirement: as each op gets a real
verifier, scenarios that op covers stop being `Expect.pass`
stubs and start asserting real behavior. The legacy
`DslConformanceTest.elm` still covers everything during the
transition; once all ops are ported here, that file (and
the Elm-emit code in `cmd/fixturegen`) goes away.

-}

import Dict
import Expect
import Game.BoardActions exposing (Side(..))
import Game.CardStack exposing (BoardCardState(..), CardStack, HandCard, HandCardState(..))
import Game.ConformanceDsl as Dsl
import Game.DslContent
import Game.Physics.BoardGeometry as BoardGeometry
    exposing
        ( BoardGeometryStatus(..)
        , GeometryErrorKind(..)
        )
import Game.Physics.PlaceStack as PlaceStack
import Game.Physics.WingOracle as WingOracle
import Game.Rules.Card as Card exposing (Card, OriginDeck(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    let
        scenarios =
            Game.DslContent.allFiles
                |> List.concatMap (\( _, text ) -> Dsl.parseConformanceDsl text)
    in
    describe "Conformance"
        (List.map scenarioTest scenarios)


scenarioTest : Dsl.Scenario -> Test
scenarioTest sc =
    test sc.name (\_ -> verify sc)


verify : Dsl.Scenario -> Expect.Expectation
verify sc =
    case sc.op of
        "stack_height_constant" ->
            BoardGeometry.stackHeight |> Expect.equal 40

        "find_open_loc" ->
            verifyFindOpenLoc sc

        "classify_board_geometry" ->
            verifyClassifyBoardGeometry sc

        "validate_board_geometry" ->
            verifyValidateBoardGeometry sc

        "wings_for_stack" ->
            verifyWingsForStack sc

        "wings_for_hand_card" ->
            verifyWingsForHandCard sc

        _ ->
            -- Verifier not yet ported from fixturegen. The legacy
            -- DslConformanceTest.elm still covers this op.
            Expect.pass



-- HELPERS


{-| Convert parsed DSL stacks into CardStacks. Each bare Card
becomes a `BoardCard` marked `FirmlyOnBoard`. State markers
(`*` / `**`) are dropped by the DSL parser today; verifiers
that need freshness re-parse from the raw token.
-}
stacksFromDsl : List Dsl.Stack -> List CardStack
stacksFromDsl =
    List.map stackFromDsl


stackFromDsl : Dsl.Stack -> CardStack
stackFromDsl s =
    { boardCards = List.map (\c -> { card = c, state = FirmlyOnBoard }) s.cards
    , loc = s.loc
    }



-- find_open_loc


verifyFindOpenLoc : Dsl.Scenario -> Expect.Expectation
verifyFindOpenLoc sc =
    case ( sc.cardCount, expectLoc sc ) of
        ( Just count, Just expected ) ->
            PlaceStack.findOpenLoc (stacksFromDsl sc.existing) count
                |> Expect.equal expected

        ( Nothing, _ ) ->
            Expect.fail "find_open_loc scenario missing card_count"

        ( _, Nothing ) ->
            Expect.fail "find_open_loc scenario missing expect.loc"


expectLoc : Dsl.Scenario -> Maybe { top : Int, left : Int }
expectLoc sc =
    case sc.expect of
        Dsl.ExpectBlock dict ->
            case Dict.get "loc" dict of
                Just (Dsl.ExpectLoc loc) ->
                    Just loc

                _ ->
                    Nothing

        _ ->
            Nothing



-- classify_board_geometry


verifyClassifyBoardGeometry : Dsl.Scenario -> Expect.Expectation
verifyClassifyBoardGeometry sc =
    case expectStr "geometry_status" sc of
        Nothing ->
            Expect.fail "classify_board_geometry scenario missing geometry_status"

        Just raw ->
            case parseGeometryStatus raw of
                Just status ->
                    BoardGeometry.classifyBoardGeometry
                        (stacksFromDsl sc.board)
                        BoardGeometry.refereeBounds
                        |> Expect.equal status

                Nothing ->
                    Expect.fail ("unknown geometry status: " ++ raw)


parseGeometryStatus : String -> Maybe BoardGeometryStatus
parseGeometryStatus s =
    case s of
        "CleanlySpaced" ->
            Just CleanlySpaced

        "Crowded" ->
            Just Crowded

        "Illegal" ->
            Just Illegal

        _ ->
            Nothing



-- validate_board_geometry


verifyValidateBoardGeometry : Dsl.Scenario -> Expect.Expectation
verifyValidateBoardGeometry sc =
    let
        errors =
            BoardGeometry.validateBoardGeometry
                (stacksFromDsl sc.board)
                BoardGeometry.refereeBounds
    in
    case sc.expect of
        Dsl.ExpectScalar "ok" ->
            errors |> Expect.equal []

        Dsl.ExpectBlock dict ->
            verifyGeometryErrorBlock dict errors

        _ ->
            Expect.fail "validate_board_geometry scenario missing expect"


verifyGeometryErrorBlock :
    Dict.Dict String Dsl.ExpectField
    -> List BoardGeometry.GeometryError
    -> Expect.Expectation
verifyGeometryErrorBlock dict errors =
    let
        kind =
            getStr "kind" dict

        checks =
            List.filterMap identity
                [ kind
                    |> Maybe.andThen
                        (\k ->
                            if k == "ok" then
                                Just (Expect.equal [] errors)

                            else
                                Nothing
                        )
                , getStr "error_count" dict
                    |> Maybe.andThen String.toInt
                    |> Maybe.map (\n -> List.length errors |> Expect.equal n)
                , getStr "any_error_kind" dict
                    |> Maybe.andThen parseGeometryKind
                    |> Maybe.map
                        (\k ->
                            List.any (\e -> e.kind == k) errors
                                |> Expect.equal True
                        )
                , getStr "no_error_kind" dict
                    |> Maybe.andThen parseGeometryKind
                    |> Maybe.map
                        (\k ->
                            List.any (\e -> e.kind == k) errors
                                |> Expect.equal False
                        )
                , getStr "overlap_count" dict
                    |> Maybe.andThen String.toInt
                    |> Maybe.map
                        (\n ->
                            List.filter (\e -> e.kind == Overlap) errors
                                |> List.length
                                |> Expect.equal n
                        )
                , getStr "overlap_stack_indices" dict
                    |> Maybe.andThen parseIntList
                    |> Maybe.map
                        (\indices ->
                            List.filter (\e -> e.kind == Overlap) errors
                                |> List.head
                                |> Maybe.map .stackIndices
                                |> Expect.equal (Just indices)
                        )
                ]
    in
    case checks of
        [] ->
            Expect.fail "validate_board_geometry scenario missing assertions"

        _ ->
            Expect.all (List.map always checks) ()


parseGeometryKind : String -> Maybe GeometryErrorKind
parseGeometryKind s =
    case s of
        "out_of_bounds" ->
            Just OutOfBounds

        "overlap" ->
            Just Overlap

        "too_close" ->
            Just TooClose

        _ ->
            Nothing


parseIntList : String -> Maybe (List Int)
parseIntList s =
    let
        parts =
            String.words s
                |> List.map String.toInt
    in
    if List.all (\m -> m /= Nothing) parts then
        Just (List.filterMap identity parts)

    else
        Nothing



-- wings_for_stack / wings_for_hand_card


verifyWingsForStack : Dsl.Scenario -> Expect.Expectation
verifyWingsForStack sc =
    case List.head sc.source of
        Nothing ->
            Expect.fail "wings_for_stack scenario missing source block"

        Just src ->
            let
                source =
                    stackFromDsl src

                board =
                    stacksFromDsl sc.board

                actual =
                    WingOracle.wingsForStack source board
                        |> List.map wingKey

                expected =
                    parseExpectedWings sc
            in
            actual |> Expect.equal expected


verifyWingsForHandCard : Dsl.Scenario -> Expect.Expectation
verifyWingsForHandCard sc =
    case Dict.get "hand_card" sc.otherScalars |> Maybe.andThen parseHandCardToken of
        Nothing ->
            Expect.fail "wings_for_hand_card scenario missing hand_card"

        Just hc ->
            let
                actual =
                    WingOracle.wingsForHandCard hc (stacksFromDsl sc.board)
                        |> List.map wingKey

                expected =
                    parseExpectedWings sc
            in
            actual |> Expect.equal expected


wingKey : WingOracle.WingId -> ( List Card, Side )
wingKey w =
    ( List.map .card w.target.boardCards, w.side )


parseExpectedWings : Dsl.Scenario -> List ( List Card, Side )
parseExpectedWings sc =
    case Dict.get "expect_wings" sc.otherBlocks of
        Nothing ->
            []

        Just rawLines ->
            groupWingEntries rawLines
                |> List.filterMap parseWingEntry


groupWingEntries : List String -> List (List String)
groupWingEntries lines =
    case lines of
        [] ->
            []

        first :: rest ->
            if String.startsWith "- " first then
                let
                    ( more, after ) =
                        spanNonDash rest
                in
                (first :: more) :: groupWingEntries after

            else
                -- skip stray non-dash prefix lines (shouldn't happen
                -- with well-formed input)
                groupWingEntries rest


spanNonDash : List String -> ( List String, List String )
spanNonDash lines =
    case lines of
        [] ->
            ( [], [] )

        head :: rest ->
            if String.startsWith "- " head then
                ( [], lines )

            else
                let
                    ( more, after ) =
                        spanNonDash rest
                in
                ( head :: more, after )


parseWingEntry : List String -> Maybe ( List Card, Side )
parseWingEntry entryLines =
    let
        fields =
            List.map normalizeWingLine entryLines
                |> List.filterMap parseKeyVal
                |> Dict.fromList

        target =
            Dict.get "target" fields
                |> Maybe.map parseCardTokens

        side =
            Dict.get "side" fields
                |> Maybe.andThen parseSide
    in
    Maybe.map2 Tuple.pair target side


normalizeWingLine : String -> String
normalizeWingLine s =
    if String.startsWith "- " s then
        String.trim (String.dropLeft 2 s)

    else
        String.trim s


parseKeyVal : String -> Maybe ( String, String )
parseKeyVal s =
    case String.indexes ":" s of
        idx :: _ ->
            Just
                ( String.trim (String.left idx s)
                , String.trim (String.dropLeft (idx + 1) s)
                )

        [] ->
            Nothing


parseSide : String -> Maybe Side
parseSide s =
    case s of
        "Left" ->
            Just Left

        "Right" ->
            Just Right

        _ ->
            Nothing


parseCardTokens : String -> List Card
parseCardTokens raw =
    String.words (String.trim raw)
        |> List.filter (\w -> w /= "")
        |> List.filterMap parseCardTokenForExpect


parseCardTokenForExpect : String -> Maybe Card
parseCardTokenForExpect raw =
    let
        ( base, deck ) =
            if String.endsWith "'" raw then
                ( String.dropRight 1 raw, DeckTwo )

            else
                ( raw, DeckOne )
    in
    Card.cardFromLabel base deck


parseHandCardToken : String -> Maybe HandCard
parseHandCardToken raw =
    parseCardTokenForExpect raw
        |> Maybe.map (\c -> { card = c, state = HandNormal })



-- EXPECT-BLOCK ACCESSORS


expectStr : String -> Dsl.Scenario -> Maybe String
expectStr key sc =
    case sc.expect of
        Dsl.ExpectBlock dict ->
            getStr key dict

        _ ->
            Nothing


getStr : String -> Dict.Dict String Dsl.ExpectField -> Maybe String
getStr key dict =
    case Dict.get key dict of
        Just (Dsl.ExpectStr s) ->
            Just s

        _ ->
            Nothing
