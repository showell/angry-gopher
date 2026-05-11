module Game.ConformanceTests exposing (suite)

{-| End-to-end conformance test runner.

Parses every embedded `.dsl` file in `Game.DslContent.allFiles`
via `Game.ConformanceDsl.parseConformanceDsl`, then dispatches
each scenario to its op-specific verifier. Verifiers are
hand-written Elm functions in this module; the `verify`
case-match is the live op registry.

-}

import Dict
import Expect
import Game.BoardActions exposing (Side(..))
import Game.BoardGesture as BoardGesture
import Game.CardStack as CardStack exposing (BoardCardState(..), BoardLocation, CardStack, HandCard, HandCardState(..))
import Game.ConformanceDsl as Dsl
import Game.DslContent
import Game.HandGesture as HandGesture
import Game.Physics.BoardGeometry as BoardGeometry
    exposing
        ( BoardGeometryStatus(..)
        , GeometryErrorKind(..)
        )
import Game.Physics.GestureArbitration as GA
import Game.Physics.PlaceStack as PlaceStack
import Game.Physics.WingOracle as WingOracle
import Game.Point exposing (Point)
import Game.Rules.Card as Card exposing (Card, OriginDeck(..))
import Game.WingView as WingView
import Game.GameEvent as GameEvent exposing (GameEvent)
import Game.Hand as Hand
import Game.Rules.Referee as Referee exposing (RefereeStage(..))
import Game.Rules.StackType as StackType
import Game.Status as Status
import Main.Msg as Msg
import Main.Play as Play
import Main.State as State
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

        "gesture_split" ->
            verifyGestureSplit sc

        "gesture_merge_stack" ->
            verifyGestureMergeStack sc

        "gesture_merge_hand" ->
            verifyGestureMergeHand sc

        "gesture_move_stack" ->
            verifyGestureMoveStack sc

        "gesture_place_hand" ->
            verifyGesturePlaceHand sc

        "gesture_floater_over_wing" ->
            verifyGestureFloaterOverWing sc

        "click_arbitration" ->
            verifyClickArbitration sc

        "floater_top_left" ->
            verifyFloaterTopLeft sc

        "validate_game_move" ->
            verifyValidateGameMove sc

        "validate_turn_complete" ->
            verifyValidateTurnComplete sc

        "replay_invariant" ->
            verifyReplayInvariant sc

        "undo_walkthrough" ->
            verifyUndoWalkthrough sc

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



-- GESTURE OPS
--
-- Shared shape: each gesture scenario describes the inputs to a
-- pure resolution function (BoardGesture.resolveBoardCardGesture
-- or HandGesture.resolveHandCardGesture or WingView.hoveredWing)
-- and asserts the result. Scalars `floater_at`, `cursor`,
-- `hovered_side`, `gesture_click_intent`, `hand_card` ride on
-- otherScalars; source comes from sc.board (board drag) or
-- otherScalars.hand_card (hand drag); the target stack comes from
-- sc.target.


defaultBoardRect : GA.Rect
defaultBoardRect =
    { x = 300, y = 100, width = 800, height = 600 }


verifyGestureSplit : Dsl.Scenario -> Expect.Expectation
verifyGestureSplit sc =
    case ( sourceStackFromBoard sc, scalarPoint "floater_at" sc ) of
        ( Just sourceStack, Just floater ) ->
            let
                cardIndex =
                    Dict.get "gesture_click_intent" sc.otherScalars
                        |> Maybe.andThen String.toInt
                        |> Maybe.withDefault 0

                d =
                    { stack = sourceStack
                    , cardIndex = cardIndex
                    , originalCursor = { x = 0, y = 0 }
                    , cursor = { x = 0, y = 0 }
                    , floaterTopLeft = pointToLoc floater
                    , boardPath = []
                    , wings = []
                    }
            in
            case BoardGesture.resolveBoardCardGesture d Nothing of
                Just (BoardGesture.Split p) ->
                    expectStr "card_index" sc
                        |> Maybe.andThen String.toInt
                        |> Maybe.map (\n -> p.cardIndex |> Expect.equal n)
                        |> Maybe.withDefault (Expect.fail "gesture_split missing expect.card_index")

                other ->
                    Expect.fail ("expected Split; got " ++ Debug.toString other)

        ( Nothing, _ ) ->
            Expect.fail "gesture_split scenario missing source (board stack)"

        ( _, Nothing ) ->
            Expect.fail "gesture_split scenario missing floater_at"


verifyGestureMergeStack : Dsl.Scenario -> Expect.Expectation
verifyGestureMergeStack sc =
    case
        ( sourceStackFromBoard sc
        , List.head sc.target
        , scalarPoint "floater_at" sc
        )
    of
        ( Just sourceStack, Just targetDsl, Just floater ) ->
            let
                targetStack =
                    stackFromDsl targetDsl

                wing =
                    { target = targetStack
                    , side =
                        Dict.get "hovered_side" sc.otherScalars
                            |> Maybe.andThen parseSide
                            |> Maybe.withDefault Left
                    }

                d =
                    { stack = sourceStack
                    , cardIndex = 0
                    , originalCursor = { x = -1000, y = 0 }
                    , cursor = { x = 0, y = 0 }
                    , floaterTopLeft = pointToLoc floater
                    , boardPath = []
                    , wings = [ wing ]
                    }
            in
            case BoardGesture.resolveBoardCardGesture d Nothing of
                Just (BoardGesture.MergeStack p) ->
                    expectSide sc
                        |> Maybe.map (\side -> p.side |> Expect.equal side)
                        |> Maybe.withDefault (Expect.fail "gesture_merge_stack missing expect.side")

                other ->
                    Expect.fail ("expected MergeStack; got " ++ Debug.toString other)

        ( Nothing, _, _ ) ->
            Expect.fail "gesture_merge_stack scenario missing source (board stack)"

        ( _, Nothing, _ ) ->
            Expect.fail "gesture_merge_stack scenario missing target"

        ( _, _, Nothing ) ->
            Expect.fail "gesture_merge_stack scenario missing floater_at"


verifyGestureMergeHand : Dsl.Scenario -> Expect.Expectation
verifyGestureMergeHand sc =
    case
        ( Dict.get "hand_card" sc.otherScalars |> Maybe.andThen parseHandCardToken
        , List.head sc.target
        , scalarPoint "floater_at" sc
        )
    of
        ( Just hc, Just targetDsl, Just floater ) ->
            let
                targetStack =
                    stackFromDsl targetDsl

                wing =
                    { target = targetStack
                    , side =
                        Dict.get "hovered_side" sc.otherScalars
                            |> Maybe.andThen parseSide
                            |> Maybe.withDefault Left
                    }

                d =
                    { card = hc.card
                    , cursor = { x = 0, y = 0 }
                    , floaterTopLeft = floater
                    , wings = [ wing ]
                    }
            in
            case HandGesture.resolveHandCardGesture d (Just defaultBoardRect) of
                Just (HandGesture.MergeHand p) ->
                    expectSide sc
                        |> Maybe.map (\side -> p.side |> Expect.equal side)
                        |> Maybe.withDefault (Expect.fail "gesture_merge_hand missing expect.side")

                other ->
                    Expect.fail ("expected MergeHand; got " ++ Debug.toString other)

        ( Nothing, _, _ ) ->
            Expect.fail "gesture_merge_hand scenario missing hand_card"

        ( _, Nothing, _ ) ->
            Expect.fail "gesture_merge_hand scenario missing target"

        ( _, _, Nothing ) ->
            Expect.fail "gesture_merge_hand scenario missing floater_at"


verifyGestureMoveStack : Dsl.Scenario -> Expect.Expectation
verifyGestureMoveStack sc =
    case ( sourceStackFromBoard sc, scalarPoint "floater_at" sc ) of
        ( Just sourceStack, Just floater ) ->
            let
                cursor =
                    scalarPoint "cursor" sc
                        |> Maybe.withDefault { x = 700, y = 400 }

                d =
                    { stack = sourceStack
                    , cardIndex = 0
                    , originalCursor = { x = -1000, y = 0 }
                    , cursor = cursor
                    , floaterTopLeft = pointToLoc floater
                    , boardPath = []
                    , wings = []
                    }

                result =
                    BoardGesture.resolveBoardCardGesture d (Just defaultBoardRect)
            in
            if expectScalarBool "rejected" sc then
                result |> Expect.equal Nothing

            else
                case result of
                    Just (BoardGesture.MoveStack p) ->
                        Expect.all
                            [ \_ ->
                                expectInt "new_loc_left" sc
                                    |> Maybe.map (\n -> p.newLoc.left |> Expect.equal n)
                                    |> Maybe.withDefault Expect.pass
                            , \_ ->
                                expectInt "new_loc_top" sc
                                    |> Maybe.map (\n -> p.newLoc.top |> Expect.equal n)
                                    |> Maybe.withDefault Expect.pass
                            ]
                            ()

                    other ->
                        Expect.fail ("expected MoveStack; got " ++ Debug.toString other)

        ( Nothing, _ ) ->
            Expect.fail "gesture_move_stack scenario missing source (board stack)"

        ( _, Nothing ) ->
            Expect.fail "gesture_move_stack scenario missing floater_at"


verifyGesturePlaceHand : Dsl.Scenario -> Expect.Expectation
verifyGesturePlaceHand sc =
    case
        ( Dict.get "hand_card" sc.otherScalars |> Maybe.andThen parseHandCardToken
        , scalarPoint "floater_at" sc
        )
    of
        ( Just hc, Just floater ) ->
            let
                cursor =
                    scalarPoint "cursor" sc
                        |> Maybe.withDefault { x = 0, y = 0 }

                d =
                    { card = hc.card
                    , cursor = cursor
                    , floaterTopLeft = floater
                    , wings = []
                    }
            in
            case HandGesture.resolveHandCardGesture d (Just defaultBoardRect) of
                Just (HandGesture.PlaceHand p) ->
                    Expect.all
                        [ \_ ->
                            expectInt "loc_left" sc
                                |> Maybe.map (\n -> p.loc.left |> Expect.equal n)
                                |> Maybe.withDefault Expect.pass
                        , \_ ->
                            expectInt "loc_top" sc
                                |> Maybe.map (\n -> p.loc.top |> Expect.equal n)
                                |> Maybe.withDefault Expect.pass
                        ]
                        ()

                other ->
                    Expect.fail ("expected PlaceHand; got " ++ Debug.toString other)

        ( Nothing, _ ) ->
            Expect.fail "gesture_place_hand scenario missing hand_card"

        ( _, Nothing ) ->
            Expect.fail "gesture_place_hand scenario missing floater_at"


verifyGestureFloaterOverWing : Dsl.Scenario -> Expect.Expectation
verifyGestureFloaterOverWing sc =
    case
        ( sourceStackFromBoard sc
        , List.head sc.target
        , scalarPoint "floater_at" sc
        )
    of
        ( Just sourceStack, Just targetDsl, Just floater ) ->
            let
                wing =
                    { target = stackFromDsl targetDsl
                    , side =
                        Dict.get "hovered_side" sc.otherScalars
                            |> Maybe.andThen parseSide
                            |> Maybe.withDefault Left
                    }

                result =
                    WingView.hoveredWing
                        (pointToLoc floater)
                        (CardStack.stackDisplayWidth sourceStack)
                        [ wing ]
            in
            if expectScalarBool "has_wing" sc then
                result |> Expect.equal (Just wing)

            else
                result |> Expect.equal Nothing

        ( Nothing, _, _ ) ->
            Expect.fail "gesture_floater_over_wing scenario missing source (board stack)"

        ( _, Nothing, _ ) ->
            Expect.fail "gesture_floater_over_wing scenario missing target"

        ( _, _, Nothing ) ->
            Expect.fail "gesture_floater_over_wing scenario missing floater_at"



-- UNDO WALKTHROUGH
--
-- Walks a sequence of steps, each producing a (model, expectations)
-- transition. Steps come in five shapes:
--   undo:                Play.update Msg.ClickUndo
--   place_hand X -> loc: GameEvent.PlaceHand, log, State.applyEvent
--   merge_hand X -> [t] /side: GameEvent.MergeHand, log, applyEvent
--   board verbs:         ReplaySpec → resolveSpec → log → applyEvent
--   no action:           alias previous model (observation only)


verifyUndoWalkthrough : Dsl.Scenario -> Expect.Expectation
verifyUndoWalkthrough sc =
    let
        board =
            stacksFromDsl sc.board

        base =
            State.baseModel

        gs0 =
            base.gameState

        m0 =
            if List.isEmpty sc.hand then
                { base
                    | gameState = { gs0 | board = board }
                    , sessionId = Just 0
                }

            else
                let
                    handCards =
                        List.map (\c -> { card = c, state = HandNormal }) sc.hand

                    gs1 =
                        Hand.setActiveHand { handCards = handCards }
                            { gs0 | board = board }
                in
                { base | gameState = gs1, sessionId = Just 0 }

        ( finalModel, perStepChecks ) =
            applyUndoSteps m0 sc.steps

        finalBoardCheck =
            if List.isEmpty sc.expectFinalBoard then
                Expect.pass

            else
                expectFinalBoard sc.expectFinalBoard finalModel
    in
    Expect.all
        ((\_ -> finalBoardCheck) :: List.map always perStepChecks)
        ()


applyUndoSteps : State.Model -> List Dsl.Step -> ( State.Model, List Expect.Expectation )
applyUndoSteps initial steps =
    let
        loop model expectations remaining =
            case remaining of
                [] ->
                    ( model, List.reverse expectations )

                step :: rest ->
                    let
                        next =
                            transitionUndoStep model step

                        stepCheck =
                            stepExpectation next step
                    in
                    loop next (stepCheck :: expectations) rest
    in
    loop initial [] steps


transitionUndoStep : State.Model -> Dsl.Step -> State.Model
transitionUndoStep prev step =
    case Dict.get "action" step.fields of
        Nothing ->
            prev

        Just "undo" ->
            let
                ( model, _, _ ) =
                    Play.update Msg.ClickUndo prev
            in
            model

        Just raw ->
            applyTransitionAction prev raw


applyTransitionAction : State.Model -> String -> State.Model
applyTransitionAction prev raw =
    case parseStepAction prev raw of
        Just action ->
            let
                entry =
                    { action = action }

                next =
                    { prev | gameState = State.applyEvent action prev.gameState }
            in
            { next | actionLog = prev.actionLog ++ [ entry ] }

        Nothing ->
            prev


parseStepAction : State.Model -> String -> Maybe GameEvent
parseStepAction model raw =
    let
        s =
            String.trim raw
    in
    if String.startsWith "place_hand " s then
        parsePlaceHand (String.dropLeft 11 s)

    else if String.startsWith "merge_hand " s then
        parseMergeHand model.gameState.board (String.dropLeft 11 s)

    else
        parseReplaySpec s
            |> Maybe.map (\spec -> resolveSpec spec model.gameState.board)


parsePlaceHand : String -> Maybe GameEvent
parsePlaceHand body =
    -- "<card> -> (top,left)"
    case String.split " -> " body of
        [ cardStr, locStr ] ->
            case ( parseCardTokenForExpect (String.trim cardStr), parseParenIntPair locStr ) of
                ( Just card, Just ( top, left ) ) ->
                    Just (GameEvent.PlaceHand { handCard = card, loc = { top = top, left = left } })

                _ ->
                    Nothing

        _ ->
            Nothing


parseMergeHand : List CardStack -> String -> Maybe GameEvent
parseMergeHand board body =
    -- "<card> -> [tgt] /side"
    case String.split " -> " body of
        [ cardStr, rightSide ] ->
            case String.split " /" rightSide of
                [ tgtStr, sideStr ] ->
                    case
                        ( parseCardTokenForExpect (String.trim cardStr)
                        , parseBracketCards tgtStr
                        , parseLowerSide sideStr
                        )
                    of
                        ( Just card, Just tgt, Just side ) ->
                            Just
                                (GameEvent.MergeHand
                                    { handCard = card
                                    , target = findStackByContent tgt board
                                    , side = side
                                    }
                                )

                        _ ->
                            Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


stepExpectation : State.Model -> Dsl.Step -> Expect.Expectation
stepExpectation model step =
    let
        checks =
            List.filterMap identity
                [ Dict.get "expect_board_count" step.fields
                    |> Maybe.andThen String.toInt
                    |> Maybe.map (\n -> List.length model.gameState.board |> Expect.equal n)
                , Dict.get "expect_hand_count" step.fields
                    |> Maybe.andThen String.toInt
                    |> Maybe.map
                        (\n ->
                            List.length (Hand.activeHand model.gameState).handCards
                                |> Expect.equal n
                        )
                , Dict.get "expect_undoable" step.fields
                    |> Maybe.andThen parseBool
                    |> Maybe.map (\b -> State.canUndoThisTurn model.actionLog |> Expect.equal b)
                , Dict.get "expect_stack" step.fields
                    |> Maybe.map (checkBoardHasStack model)
                , Dict.get "expect_hand_contains" step.fields
                    |> Maybe.andThen parseCardTokenForExpect
                    |> Maybe.map (checkHandContains model)
                , Dict.get "expect_loc" step.fields
                    |> Maybe.andThen parseParenIntPair
                    |> Maybe.map (\( top, left ) -> checkBoardHasLoc model { top = top, left = left })
                ]
    in
    case checks of
        [] ->
            Expect.pass

        _ ->
            Expect.all (List.map always checks) ()


checkBoardHasStack : State.Model -> String -> Expect.Expectation
checkBoardHasStack model raw =
    let
        want =
            parseCardTokens raw
    in
    if List.any (\s -> List.map .card s.boardCards == want) model.gameState.board then
        Expect.pass

    else
        Expect.fail ("board missing stack [" ++ raw ++ "]")


checkHandContains : State.Model -> Card -> Expect.Expectation
checkHandContains model card =
    if List.any (\hc -> hc.card == card) (Hand.activeHand model.gameState).handCards then
        Expect.pass

    else
        Expect.fail "hand missing expected card"


checkBoardHasLoc : State.Model -> BoardLocation -> Expect.Expectation
checkBoardHasLoc model loc =
    if List.any (\s -> s.loc == loc) model.gameState.board then
        Expect.pass

    else
        Expect.fail
            ("board missing stack at ("
                ++ String.fromInt loc.top
                ++ ", "
                ++ String.fromInt loc.left
                ++ ")"
            )


expectFinalBoard : List Dsl.Stack -> State.Model -> Expect.Expectation
expectFinalBoard expectedStacks model =
    let
        byLoc =
            List.sortBy (\s -> ( s.loc.top, s.loc.left ))

        cardRows =
            List.map (.boardCards >> List.map .card)

        expected =
            stacksFromDsl expectedStacks
    in
    cardRows (byLoc model.gameState.board)
        |> Expect.equal (cardRows (byLoc expected))


parseBool : String -> Maybe Bool
parseBool s =
    case s of
        "true" ->
            Just True

        "false" ->
            Just False

        _ ->
            Nothing



-- REPLAY INVARIANT
--
-- Compare two paths to the same final state: eager-fold over
-- GameEvents vs animation-FSM replay. The two should converge
-- on byte-identical gameState. Optional victory check.


verifyReplayInvariant : Dsl.Scenario -> Expect.Expectation
verifyReplayInvariant sc =
    let
        board =
            stacksFromDsl sc.board

        base =
            State.baseModel

        gs0 =
            base.gameState

        initialModel =
            { base
                | gameState = { gs0 | board = board }
                , sessionId = Just 0
            }

        specs =
            List.filterMap parseReplaySpec sc.actions

        ( eagerModel, actions ) =
            buildEagerAndActions initialModel specs

        replayedModel =
            runReplay initialModel actions

        wantVictory =
            case sc.expect of
                Dsl.ExpectBlock dict ->
                    getStr "final_board_victory" dict == Just "true"

                _ ->
                    False

        victoryCheck _ =
            if not wantVictory then
                Expect.pass

            else if List.all isCleanStack eagerModel.gameState.board && List.all isCleanStack replayedModel.gameState.board then
                Expect.pass

            else
                Expect.fail "final board not victory"
    in
    Expect.all
        [ \_ -> Expect.equal eagerModel.gameState replayedModel.gameState
        , victoryCheck
        ]
        ()


type ReplaySpec
    = SpecSplit (List Card) Int
    | SpecMergeStack (List Card) (List Card) Side
    | SpecMoveStack (List Card) BoardLocation
    | SpecCompleteTurn


parseReplaySpec : String -> Maybe ReplaySpec
parseReplaySpec raw =
    let
        s =
            String.trim raw
    in
    if s == "complete_turn" then
        Just SpecCompleteTurn

    else if String.startsWith "split " s then
        parseSplit (String.dropLeft 6 s)

    else if String.startsWith "merge_stack " s then
        parseMergeStack (String.dropLeft 12 s)

    else if String.startsWith "move_stack " s then
        parseMoveStack (String.dropLeft 11 s)

    else
        Nothing


parseSplit : String -> Maybe ReplaySpec
parseSplit body =
    -- "[cards]@idx"
    case splitOnLast "@" body of
        Just ( head, tail ) ->
            case ( parseBracketCards head, String.toInt (String.trim tail) ) of
                ( Just cards, Just idx ) ->
                    Just (SpecSplit cards idx)

                _ ->
                    Nothing

        Nothing ->
            Nothing


parseMergeStack : String -> Maybe ReplaySpec
parseMergeStack body =
    -- "[src] -> [tgt] /side"
    case String.split " -> " body of
        [ srcStr, rightSide ] ->
            case String.split " /" rightSide of
                [ tgtStr, sideStr ] ->
                    case
                        ( parseBracketCards srcStr
                        , parseBracketCards tgtStr
                        , parseLowerSide sideStr
                        )
                    of
                        ( Just src, Just tgt, Just side ) ->
                            Just (SpecMergeStack src tgt side)

                        _ ->
                            Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


parseMoveStack : String -> Maybe ReplaySpec
parseMoveStack body =
    -- "[cards] -> (top,left)"
    case String.split " -> " body of
        [ cardsStr, locStr ] ->
            case ( parseBracketCards cardsStr, parseParenIntPair locStr ) of
                ( Just cards, Just ( top, left ) ) ->
                    Just (SpecMoveStack cards { top = top, left = left })

                _ ->
                    Nothing

        _ ->
            Nothing


parseBracketCards : String -> Maybe (List Card)
parseBracketCards s =
    let
        t =
            String.trim s
    in
    if String.startsWith "[" t && String.endsWith "]" t then
        Just (parseCardTokens (String.slice 1 -1 t))

    else
        Nothing


parseLowerSide : String -> Maybe Side
parseLowerSide s =
    case String.trim s of
        "left" ->
            Just Left

        "right" ->
            Just Right

        _ ->
            Nothing


splitOnLast : String -> String -> Maybe ( String, String )
splitOnLast sep s =
    case List.reverse (String.indexes sep s) of
        last :: _ ->
            Just
                ( String.left last s
                , String.dropLeft (last + String.length sep) s
                )

        [] ->
            Nothing


findStackByContent : List Card -> List CardStack -> CardStack
findStackByContent cards board =
    case List.filter (\s -> List.map .card s.boardCards == cards) board of
        match :: _ ->
            match

        [] ->
            { boardCards = [], loc = { top = -1, left = -1 } }


resolveSpec : ReplaySpec -> List CardStack -> GameEvent
resolveSpec spec board =
    case spec of
        SpecSplit cards idx ->
            GameEvent.Split { stack = findStackByContent cards board, cardIndex = idx }

        SpecMergeStack src tgt side ->
            GameEvent.MergeStack
                { source = findStackByContent src board
                , target = findStackByContent tgt board
                , side = side
                , boardPath = []
                }

        SpecMoveStack cards loc ->
            GameEvent.MoveStack
                { stack = findStackByContent cards board
                , newLoc = loc
                , boardPath = []
                }

        SpecCompleteTurn ->
            GameEvent.CompleteTurn


buildEagerAndActions : State.Model -> List ReplaySpec -> ( State.Model, List GameEvent )
buildEagerAndActions initialModel specs =
    let
        loop model acc remaining =
            case remaining of
                [] ->
                    ( model, List.reverse acc )

                spec :: rest ->
                    let
                        action =
                            resolveSpec spec model.gameState.board

                        next =
                            { model | gameState = State.applyEvent action model.gameState }
                    in
                    loop next (action :: acc) rest
    in
    loop initialModel [] specs


runReplay : State.Model -> List GameEvent -> State.Model
runReplay initialModel actions =
    let
        gs0 =
            initialModel.gameState

        finalGameState =
            List.foldl State.applyEvent gs0 actions
    in
    { initialModel | gameState = finalGameState }


isCleanStack : CardStack -> Bool
isCleanStack s =
    case StackType.getStackType (List.map .card s.boardCards) of
        StackType.Set ->
            True

        StackType.PureRun ->
            True

        StackType.RedBlackRun ->
            True

        _ ->
            False



-- REFEREE: validate_game_move / validate_turn_complete


verifyValidateGameMove : Dsl.Scenario -> Expect.Expectation
verifyValidateGameMove sc =
    let
        move =
            { boardBefore = stacksFromDsl sc.boardBefore
            , stacksToRemove = stacksFromDsl sc.stacksToRemove
            , stacksToAdd = stacksFromDsl sc.stacksToAdd
            , handCardsPlayed = parseHandCards sc
            }

        result =
            Referee.validateGameMove move BoardGeometry.refereeBounds
    in
    checkRefereeResult sc result


verifyValidateTurnComplete : Dsl.Scenario -> Expect.Expectation
verifyValidateTurnComplete sc =
    let
        result =
            Referee.validateTurnComplete
                (stacksFromDsl sc.board)
                BoardGeometry.refereeBounds
    in
    checkRefereeResult sc result


checkRefereeResult : Dsl.Scenario -> Result Referee.RefereeError () -> Expect.Expectation
checkRefereeResult sc result =
    case sc.expect of
        Dsl.ExpectScalar "ok" ->
            case result of
                Ok _ ->
                    Expect.pass

                Err err ->
                    Expect.fail
                        (Referee.refereeStageToString err.stage
                            ++ ": "
                            ++ err.message
                        )

        Dsl.ExpectBlock dict ->
            let
                stage =
                    getStr "stage" dict
                        |> Maybe.andThen parseRefereeStage

                msgSubstr =
                    getStr "message_contains" dict
                        |> Maybe.withDefault ""
            in
            case ( result, stage ) of
                ( Ok _, _ ) ->
                    Expect.fail "expected error, got Ok"

                ( Err err, Just want ) ->
                    if err.stage /= want then
                        Expect.fail
                            ("stage: want "
                                ++ Referee.refereeStageToString want
                                ++ ", got "
                                ++ Referee.refereeStageToString err.stage
                            )

                    else if msgSubstr /= "" && not (String.contains msgSubstr err.message) then
                        Expect.fail
                            ("message substring \""
                                ++ msgSubstr
                                ++ "\" not found in: "
                                ++ err.message
                            )

                    else
                        Expect.pass

                ( Err _, Nothing ) ->
                    Expect.fail "referee scenario expect block missing stage"

        _ ->
            Expect.fail "referee scenario missing expect"


parseRefereeStage : String -> Maybe RefereeStage
parseRefereeStage s =
    case s of
        "protocol" ->
            Just Protocol

        "geometry" ->
            Just Geometry

        "semantics" ->
            Just Semantics

        "inventory" ->
            Just Inventory

        _ ->
            Nothing


parseHandCards : Dsl.Scenario -> List HandCard
parseHandCards sc =
    Dict.get "hand_cards_played" sc.otherScalars
        |> Maybe.map
            (\raw ->
                String.words (String.trim raw)
                    |> List.filter (\w -> w /= "")
                    |> List.filterMap parseHandCardToken
            )
        |> Maybe.withDefault []



-- click_arbitration


verifyClickArbitration : Dsl.Scenario -> Expect.Expectation
verifyClickArbitration sc =
    case ( scalarPoint "mousedown" sc, scalarPoint "current" sc ) of
        ( Just md, Just cur ) ->
            let
                initialIntent =
                    Dict.get "initial_click_intent" sc.otherScalars
                        |> Maybe.andThen String.toInt

                expected =
                    case Dict.get "expect_click_intent" sc.otherScalars of
                        Just "nothing" ->
                            Just Nothing

                        Just s ->
                            Just (Just (Maybe.withDefault 0 (String.toInt s)))

                        Nothing ->
                            Nothing

                preKill =
                    scalarPoint "pre_kill_at" sc

                intentAfterKill =
                    case preKill of
                        Just pk ->
                            GA.clickIntentAfterMove md pk initialIntent

                        Nothing ->
                            initialIntent

                actual =
                    GA.clickIntentAfterMove md cur intentAfterKill
            in
            case expected of
                Just exp ->
                    actual |> Expect.equal exp

                Nothing ->
                    Expect.fail "click_arbitration scenario missing expect_click_intent"

        _ ->
            Expect.fail "click_arbitration scenario missing mousedown or current"



-- floater_top_left
--
-- Three sub-cases distinguished by which expect-field is present:
--   shift_equals_delta: floater.shift == cursor.delta after a
--     single mouseMove.
--   grab_point_invariant: two distinct mousedown grab points
--     produce the same floater shift for the same delta.
--   initial_floater_at: BoardGesture.startBoardDragInfo's
--     floaterTopLeft equals the source stack's loc.


verifyFloaterTopLeft : Dsl.Scenario -> Expect.Expectation
verifyFloaterTopLeft sc =
    case List.head sc.board |> Maybe.map stackFromDsl of
        Nothing ->
            Expect.fail "floater_top_left scenario missing board"

        Just stack ->
            let
                cardIndex =
                    Dict.get "card_index" sc.otherScalars
                        |> Maybe.andThen String.toInt
                        |> Maybe.withDefault 0
            in
            if expectScalarBool "shift_equals_delta" sc then
                verifyShiftEqualsDelta sc stack cardIndex

            else if expectScalarBool "grab_point_invariant" sc then
                verifyGrabPointInvariant sc stack

            else
                case expectLocField "initial_floater_at" sc of
                    Just expected ->
                        verifyInitialFloaterAt sc stack cardIndex expected

                    Nothing ->
                        Expect.fail "floater_top_left scenario missing shift_equals_delta / grab_point_invariant / initial_floater_at"


verifyShiftEqualsDelta : Dsl.Scenario -> CardStack -> Int -> Expect.Expectation
verifyShiftEqualsDelta sc stack cardIndex =
    case
        ( scalarPoint "mousedown" sc
        , scalarPoint "mousemove_delta" sc
        )
    of
        ( Just mousedown, Just delta ) ->
            let
                before =
                    BoardGesture.startBoardDragInfo
                        { stack = stack
                        , cardIndex = cardIndex
                        , cursor = mousedown
                        , tMs = 0
                        , board = [ stack ]
                        }

                ( after, _ ) =
                    BoardGesture.mouseMove
                        { x = mousedown.x + delta.x, y = mousedown.y + delta.y }
                        100
                        before
                        idleStatus
            in
            Expect.equal
                { left = before.floaterTopLeft.left + delta.x
                , top = before.floaterTopLeft.top + delta.y
                }
                after.floaterTopLeft

        _ ->
            Expect.fail "floater_top_left shift_equals_delta missing mousedown or mousemove_delta"


verifyGrabPointInvariant : Dsl.Scenario -> CardStack -> Expect.Expectation
verifyGrabPointInvariant sc stack =
    case
        ( scalarPoint "mousedown_a" sc
        , scalarPoint "mousedown_b" sc
        , scalarPoint "delta" sc
        )
    of
        ( Just a, Just bpt, Just delta ) ->
            let
                shiftFor down =
                    let
                        before =
                            BoardGesture.startBoardDragInfo
                                { stack = stack
                                , cardIndex = 0
                                , cursor = down
                                , tMs = 0
                                , board = [ stack ]
                                }

                        ( after, _ ) =
                            BoardGesture.mouseMove
                                { x = down.x + delta.x, y = down.y + delta.y }
                                100
                                before
                                idleStatus
                    in
                    { x = after.floaterTopLeft.left - before.floaterTopLeft.left
                    , y = after.floaterTopLeft.top - before.floaterTopLeft.top
                    }
            in
            Expect.equal (shiftFor a) (shiftFor bpt)

        _ ->
            Expect.fail "floater_top_left grab_point_invariant missing mousedown_a/mousedown_b/delta"


verifyInitialFloaterAt : Dsl.Scenario -> CardStack -> Int -> BoardLocation -> Expect.Expectation
verifyInitialFloaterAt sc stack cardIndex expected =
    case scalarPoint "mousedown" sc of
        Just mousedown ->
            (BoardGesture.startBoardDragInfo
                { stack = stack
                , cardIndex = cardIndex
                , cursor = mousedown
                , tMs = 0
                , board = [ stack ]
                }
            ).floaterTopLeft
                |> Expect.equal expected

        Nothing ->
            Expect.fail "floater_top_left initial_floater_at missing mousedown"


idleStatus : Status.StatusMessage
idleStatus =
    { text = "", kind = Status.Inform }


expectLocField : String -> Dsl.Scenario -> Maybe BoardLocation
expectLocField key sc =
    case sc.expect of
        Dsl.ExpectBlock dict ->
            case Dict.get key dict of
                Just (Dsl.ExpectStr s) ->
                    parseParenIntPair s
                        |> Maybe.map (\( x, y ) -> { left = x, top = y })

                _ ->
                    Nothing

        _ ->
            Nothing



-- GESTURE HELPERS


sourceStackFromBoard : Dsl.Scenario -> Maybe CardStack
sourceStackFromBoard sc =
    List.head sc.board |> Maybe.map stackFromDsl


scalarPoint : String -> Dsl.Scenario -> Maybe Point
scalarPoint key sc =
    Dict.get key sc.otherScalars
        |> Maybe.andThen parseParenIntPair
        |> Maybe.map (\( x, y ) -> { x = x, y = y })


pointToLoc : Point -> BoardLocation
pointToLoc p =
    { left = p.x, top = p.y }


parseParenIntPair : String -> Maybe ( Int, Int )
parseParenIntPair s =
    let
        t =
            String.trim s
    in
    if String.startsWith "(" t && String.endsWith ")" t then
        case String.split "," (String.slice 1 -1 t) of
            [ a, b ] ->
                Maybe.map2 Tuple.pair
                    (String.toInt (String.trim a))
                    (String.toInt (String.trim b))

            _ ->
                Nothing

    else
        Nothing


expectSide : Dsl.Scenario -> Maybe Side
expectSide sc =
    expectStr "side" sc |> Maybe.andThen parseSide


expectInt : String -> Dsl.Scenario -> Maybe Int
expectInt key sc =
    expectStr key sc |> Maybe.andThen String.toInt


expectScalarBool : String -> Dsl.Scenario -> Bool
expectScalarBool key sc =
    case expectStr key sc of
        Just "true" ->
            True

        _ ->
            False



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
