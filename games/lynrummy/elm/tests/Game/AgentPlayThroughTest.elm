module Game.AgentPlayThroughTest exposing (suite)

{-| Drives the actual click-then-replay-drain pipeline through
`Play.update` with Msgs and captures a series of model snapshots.

The existing `replay_invariant` walkthroughs seed
`model.replay = Just {...}` directly and bypass the click
reducer entirely. That hides any defect at the click→replay
seam. This module dispatches `ClickAgentPlay` and then drives
synthetic `ReplayFrame` ticks the same way the browser would,
asserting on the model state at each phase.

The ONLY input is a button click. Everything else is a model
snapshot.

-}

import Expect
import Game.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Game.CardStack
    exposing
        ( BoardCardState(..)
        , CardStack
        )
import Game.StackType as StackType
import Http
import Main.Msg exposing (Msg(..))
import Main.Play as Play
import Main.State as State
import Test exposing (Test, describe, test)
import Time



-- HELPERS


makeStack : Int -> Int -> List Card -> CardStack
makeStack top left cards =
    { boardCards = List.map (\card -> { card = card, state = FirmlyOnBoard }) cards
    , loc = { top = top, left = left }
    }


modelFromBoard : List CardStack -> State.Model
modelFromBoard board =
    let
        base =
            State.baseModel
    in
    { base | board = board, sessionId = Just 0 }


posix : Float -> Time.Posix
posix ms =
    Time.millisToPosix (round ms)


driveReplayToCompletion : State.Model -> Float -> Int -> State.Model
driveReplayToCompletion model nowMs budget =
    case model.replay of
        Nothing ->
            model

        Just _ ->
            if budget <= 0 then
                model

            else
                let
                    ( next, _, _ ) =
                        Play.update (ReplayFrame (posix nowMs)) model
                in
                driveReplayToCompletion next (nowMs + 50) (budget - 1)


clickAndDrain : State.Model -> State.Model
clickAndDrain m0 =
    let
        ( m1, _, _ ) =
            Play.update ClickAgentPlay m0
    in
    driveReplayToCompletion m1 0 5000



-- CARD HELPERS


c : CardValue -> Suit -> Card
c v s =
    { value = v, suit = s, originDeck = DeckOne }


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



-- TESTS


suite : Test
suite =
    describe "Agent play-through (click + replay drain)"
        [ statusUpdatesAfterClick
        , replayKicksAfterClick
        , boardChangesAfterDrain
        , clickThenDrainProducesVictory
        , mined001FullWalkthrough
        , mined001FullWalkthroughPuzzleSession
        , wireFailureMidReplayDoesNotStallBoard
        , mouseUpDuringAnimDoesNotAbortPlayback
        ]


{-| The button click that kicked agent play also produces a
mouseup event at document level. While `model.drag = Dragging`
(set by Animating phase for non-Split first primitives), the
document-level `onMouseUp` subscription is LIVE. If the user's
button-release mouseup arrives between Animating start and the
animation completing, `handleMouseUp` runs against the
replay-driven drag state and may abort it.

This test injects a `MouseUp` Msg one frame after Animating
starts, then drives drain. If the action still applies, the
playback layer survives the mouseup race. If not, this test
fails AND we have a localized regression.

-}
mouseUpDuringAnimDoesNotAbortPlayback : Test
mouseUpDuringAnimDoesNotAbortPlayback =
    test "mouseUp during Animating does not abort the action's apply" <|
        \_ ->
            let
                m0 =
                    -- Push-only board: single MergeStack primitive.
                    -- The first replayFrame transitions NotAnimating
                    -- to Animating (drag=Dragging). A mouseUp at
                    -- this point would route into handleMouseUp.
                    modelFromBoard
                        [ makeStack 100 100 [ c Ace Diamond ]
                        , makeStack 200 100 [ c Two Club, c Three Diamond, c Four Club, c Five Heart, c Six Spade, c Seven Heart ]
                        ]

                ( m1, _, _ ) =
                    Play.update ClickAgentPlay m0

                ( m2, _, _ ) =
                    -- One ReplayFrame: NotAnimating → Animating.
                    Play.update (ReplayFrame (posix 16)) m1

                ( m3, _, _ ) =
                    -- The user's button-release mouseup — anywhere
                    -- on the document. handleMouseUp runs because
                    -- drag = Dragging (from Animating).
                    Play.update (MouseUp { x = 0, y = 0 } 16) m2

                final =
                    driveReplayToCompletion m3 32 5000
            in
            if m0.board /= final.board then
                Expect.pass

            else
                Expect.fail
                    ("mouseUp mid-Animating aborted the action; final board unchanged from m0."
                        ++ "\n  m1.replayAnim: "
                        ++ Debug.toString m1.replayAnim
                        ++ "\n  m2.replayAnim: "
                        ++ Debug.toString m2.replayAnim
                        ++ "\n  m2.drag: "
                        ++ Debug.toString m2.drag
                        ++ "\n  m3.replayAnim: "
                        ++ Debug.toString m3.replayAnim
                        ++ "\n  m3.drag: "
                        ++ Debug.toString m3.drag
                        ++ "\n  m3.replay: "
                        ++ Debug.toString m3.replay
                        ++ "\n  m3.agentProgram: "
                        ++ Debug.toString m3.agentProgram
                        ++ "\n  final.replay: "
                        ++ Debug.toString final.replay
                        ++ "\n  final.status: "
                        ++ final.status.text
                    )


{-| What happens if the wire POST returns 400 mid-replay?
The browser fires `ActionSent (Err _)` which my recent
visibility patch (commit 6cdaa6f) handles by setting status
to a Scold. If that handler corrupted replay state — e.g.,
cleared `replay = Nothing` — the FSM would silently abandon
pending entries. Test: dispatch ClickAgentPlay, then inject
`ActionSent (Err NetworkError)` after one frame, then continue
draining. Final board should still reach victory.
-}
wireFailureMidReplayDoesNotStallBoard : Test
wireFailureMidReplayDoesNotStallBoard =
    test "ActionSent (Err) mid-replay does not abandon pending entries" <|
        \_ ->
            let
                m0 =
                    modelFromBoard simplePeelBoard

                ( m1, _, _ ) =
                    Play.update ClickAgentPlay m0

                ( m2, _, _ ) =
                    Play.update (ReplayFrame (posix 16)) m1

                -- Inject the wire-failure Msg mid-flight.
                ( m3, _, _ ) =
                    Play.update
                        (ActionSent (Err Http.NetworkError))
                        m2

                final =
                    driveReplayToCompletion m3 32 5000
            in
            if List.all isCleanStack final.board then
                Expect.pass

            else
                Expect.fail
                    ("wire-error mid-replay corrupted state; final.board: "
                        ++ Debug.toString final.board
                        ++ "\n  replay: "
                        ++ Debug.toString final.replay
                        ++ "\n  status: "
                        ++ final.status.text
                    )


cd2 : CardValue -> Suit -> Card
cd2 v s =
    { value = v, suit = s, originDeck = DeckTwo }


mined001Board : List CardStack
mined001Board =
    [ makeStack 26 26 [ c Two Heart, c Three Heart, c Four Heart ]
    , makeStack 107 52 [ c Seven Spade, c Seven Diamond, c Seven Club ]
    , makeStack 182 52 [ c Ace Club, c Ace Diamond, c Ace Heart ]
    , makeStack 257 52 [ c Two Club, c Three Diamond, c Four Club, c Five Heart, c Six Spade, c Seven Heart ]
    , makeStack 332 52 [ cd2 Two Diamond, cd2 Three Spade, cd2 Four Diamond ]
    , makeStack 407 52 [ c Ace Spade, c Two Spade, c Three Spade ]
    , makeStack 482 52 [ cd2 King Diamond, cd2 King Heart, c King Spade ]
    , makeStack 92 187 [ c Jack Diamond, c Queen Diamond, c King Diamond ]
    , makeStack 167 187 [ c Ten Spade, cd2 Ten Club, c Ten Diamond ]
    , makeStack 332 187 [ c Four Spade, cd2 Four Club ]
    ]


{-| Walk the full mined\_001\_4S\_4Cp1 program via repeated
ClickAgentPlay. Reproduces what Steve does in the browser:
click, watch the move animate, click for the next move,
etc. The test asserts the final board is victory after walking
through ALL plan lines (4 for this puzzle).
-}
mined001FullWalkthrough : Test
mined001FullWalkthrough =
    test "mined_001_4S_4Cp1: 4 clicks → 4 moves → victory" <|
        \_ ->
            let
                m0 =
                    modelFromBoard mined001Board

                final =
                    walkClicks m0 10
            in
            if List.all isCleanStack final.board then
                Expect.pass

            else
                Expect.fail
                    ("after walking the full program, board is not victory; incomplete stacks: "
                        ++ Debug.toString
                            (List.filter (not << isCleanStack) final.board)
                        ++ "\n  agentProgram: "
                        ++ Debug.toString final.agentProgram
                        ++ "\n  status: "
                        ++ final.status.text
                    )


{-| Same walkthrough but with the puzzleSession-bootstrapped
model shape: puzzleName = Just, gameId = puzzleName,
hideTurnControls = True, replayBaseline = Just (the initial
state). Mirrors what `Play.init (PuzzleSession ...)` produces
without going through JSON encode/decode. If the click+drain
contract holds with this shape, the bug is outside the model
layer.
-}
mined001FullWalkthroughPuzzleSession : Test
mined001FullWalkthroughPuzzleSession =
    test "mined_001 (puzzleSession-shaped model): 4 clicks → victory" <|
        \_ ->
            let
                base =
                    State.baseModel

                puzzleName =
                    "mined_001_4S_4Cp1"

                initialRemote =
                    { board = mined001Board
                    , hands = base.hands
                    , scores = base.scores
                    , activePlayerIndex = base.activePlayerIndex
                    , turnIndex = base.turnIndex
                    , deck = base.deck
                    , cardsPlayedThisTurn = base.cardsPlayedThisTurn
                    , victorAwarded = base.victorAwarded
                    , turnStartBoardScore = base.turnStartBoardScore
                    }

                m0 =
                    { base
                        | sessionId = Just 629
                        , puzzleName = Just puzzleName
                        , gameId = puzzleName
                        , hideTurnControls = True
                        , board = mined001Board
                        , replayBaseline = Just initialRemote
                    }

                final =
                    walkClicks m0 10
            in
            if List.all isCleanStack final.board then
                Expect.pass

            else
                Expect.fail
                    ("puzzleSession walkthrough failed; incomplete stacks: "
                        ++ Debug.toString
                            (List.filter (not << isCleanStack) final.board)
                        ++ "\n  agentProgram: "
                        ++ Debug.toString final.agentProgram
                        ++ "\n  replay: "
                        ++ Debug.toString final.replay
                        ++ "\n  replayAnim: "
                        ++ Debug.toString final.replayAnim
                        ++ "\n  status: "
                        ++ final.status.text
                    )


walkClicks : State.Model -> Int -> State.Model
walkClicks model budget =
    if budget <= 0 then
        model

    else
        let
            after =
                clickAndDrain model
        in
        case after.agentProgram of
            Just (_ :: _) ->
                walkClicks after (budget - 1)

            _ ->
                after


simplePeelBoard : List CardStack
simplePeelBoard =
    -- Peel TC from [TC JD QS KH], absorb onto trouble [9D].
    -- BFS picks this in one line; expected primitive: one
    -- MergeStack of [TC] onto [9D] after isolating TC, then
    -- merging the remnant [JD QS KH] back in (TC at end is a
    -- one-split end-extract; remnant stays a length-3 RB run).
    [ makeStack 50 50 [ c Ten Club, c Jack Diamond, c Queen Spade, c King Heart ]
    , makeStack 100 200 [ c Nine Diamond ]
    ]


statusUpdatesAfterClick : Test
statusUpdatesAfterClick =
    test "status text updates to 'Agent: …' immediately after click" <|
        \_ ->
            let
                m0 =
                    modelFromBoard simplePeelBoard

                ( m1, _, _ ) =
                    Play.update ClickAgentPlay m0
            in
            if String.startsWith "Agent: " m1.status.text then
                Expect.pass

            else
                Expect.fail
                    ("status didn't update to Agent: ... — got: "
                        ++ m1.status.text
                    )


replayKicksAfterClick : Test
replayKicksAfterClick =
    test "model.replay /= Nothing immediately after click" <|
        \_ ->
            let
                m0 =
                    modelFromBoard simplePeelBoard

                ( m1, _, _ ) =
                    Play.update ClickAgentPlay m0
            in
            case m1.replay of
                Just _ ->
                    Expect.pass

                Nothing ->
                    Expect.fail
                        "expected model.replay = Just {...} after ClickAgentPlay"


boardChangesAfterDrain : Test
boardChangesAfterDrain =
    test "board changes between click and replay completion" <|
        \_ ->
            let
                m0 =
                    modelFromBoard simplePeelBoard

                final =
                    clickAndDrain m0
            in
            if m0.board /= final.board then
                Expect.pass

            else
                Expect.fail
                    "board unchanged after click + replay drain — Apply.applyAction never fired"


clickThenDrainProducesVictory : Test
clickThenDrainProducesVictory =
    test "click → drain → final board is victory (one-line plan)" <|
        \_ ->
            let
                m0 =
                    modelFromBoard simplePeelBoard

                final =
                    clickAndDrain m0
            in
            if List.all isCleanStack final.board then
                Expect.pass

            else
                let
                    incomplete =
                        List.filter (not << isCleanStack) final.board
                in
                Expect.fail
                    ("final board not victory; incomplete stacks: "
                        ++ Debug.toString incomplete
                    )
