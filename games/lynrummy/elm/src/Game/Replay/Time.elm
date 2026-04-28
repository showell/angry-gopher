module Game.Replay.Time exposing
    ( clickInstantReplay
    , clickReplayPauseToggle
    , handCardRectReceived
    , replayFrame
    )

{-| The temporal half of Instant Replay. Owns the FSM and the
clock-driven Msg handlers.

Phases, same as the `ReplayAnimationState` sum type in `Main.State`:

  - **PreRolling** — hold the rewound board for ~1s so the viewer
    registers the starting state before action 0 fires.
  - **NotAnimating** — transient between step N-1 and step N.
    Looks up the next action; if none, replay is done; if yes,
    `prepareReplayStep` decides which animation path applies.
  - **Animating** — interpolate cursor along `path` every frame.
    When elapsed ≥ path duration, apply the action and beat.
  - **AwaitingHandRect** — fired a `Browser.Dom.getElement` Task
    for a hand card's live rect; wait for
    `HandCardRectReceived` to transition us to Animating.
  - **Beating** — hold ~1s between actions (2.5s for
    CompleteTurn, since a lot happens at once). Not the
    real-world inter-drag pause — that would read as buggy.

Companion to `Game.Replay.Space`, which owns the spatial
synthesis (endpoints, paths, interpolation). This module
depends on Space; Space has no dependency here.

Extracted 2026-04-21 from `Main.elm` alongside Space, to collect
the replay FSM + its Msg handlers in one module.

-}

import Browser.Dom
import Game.Rules.Card
import Game.HandLayout as HandLayout
import Game.Replay.AnimateMergeHand as AnimateMergeHand
import Game.Replay.AnimateMergeStack as AnimateMergeStack
import Game.Replay.AnimateMoveStack as AnimateMoveStack
import Game.Replay.AnimatePlaceHand as AnimatePlaceHand
import Game.Replay.DragAnimation as DragAnimation
import Game.Replay.Space as Space
import Game.Score as Score
import Game.WireAction as WA exposing (WireAction)
import Main.Apply as Apply
import Main.Msg exposing (Msg(..))
import Main.State as State
    exposing
        ( DragState(..)
        , Model
        , PathFrame
        , ReplayAnimationState(..)
        , StatusKind(..)
        )
import Task
import Time



-- CLICK HANDLER: INSTANT REPLAY


{-| Handle `ClickInstantReplay`: rewind the Model to the
session's true pre-first-action baseline, seed the replay
walker, and kick off a DOM query for the live board rect.

The PreRolling phase keeps the rewound board on screen briefly so
the viewer registers the starting state before action 0 fires.

Requires a baseline. The baseline is populated at session
bootstrap by `fetchActionLog` (both on new-session and
URL-resume paths), so it's expected to be present. If it
isn't — e.g. if the user clicks Replay before the fetch
resolves — the click no-ops rather than rewinding to an
invented state. Better silent no-op than replaying a lie.

-}
clickInstantReplay : Model -> ( Model, Cmd Msg )
clickInstantReplay model =
    case model.replayBaseline of
        Nothing ->
            ( model, Cmd.none )

        Just baseline ->
            let
                rewound =
                    { model
                        | board = baseline.board
                        , hands = baseline.hands
                        , scores = baseline.scores
                        , activePlayerIndex = baseline.activePlayerIndex
                        , turnIndex = baseline.turnIndex
                        , deck = baseline.deck
                        , cardsPlayedThisTurn = baseline.cardsPlayedThisTurn
                        , victorAwarded = baseline.victorAwarded
                        , turnStartBoardScore = baseline.turnStartBoardScore
                        , score = Score.forStacks baseline.board
                    }
            in
            ( { rewound
                | status = { text = "Replaying…", kind = Inform }
                , replay = Just { pending = model.actionLog, paused = False }
                , replayAnim = PreRolling { untilMs = 0 }
                , drag = NotDragging
                , replayBoardRect = Nothing
              }
            , Task.attempt BoardRectReceived
                (Browser.Dom.getElement (State.boardDomIdFor model.gameId))
            )



-- CLICK HANDLER: PAUSE TOGGLE


clickReplayPauseToggle : Model -> ( Model, Cmd Msg )
clickReplayPauseToggle model =
    case model.replay of
        Just progress ->
            ( { model | replay = Just { progress | paused = not progress.paused } }
            , Cmd.none
            )

        Nothing ->
            ( model, Cmd.none )



-- FRAME TICK


{-| Core replay state machine. One step per `onAnimationFrame`;
no-op when paused. See module-level comment for phase semantics.
-}
replayFrame : Float -> Model -> ( Model, Cmd Msg )
replayFrame nowMs model =
    case model.replay of
        Nothing ->
            ( model, Cmd.none )

        Just progress ->
            if progress.paused then
                ( model, Cmd.none )

            else
                case model.replayAnim of
                    NotAnimating ->
                        case progress.pending of
                            [] ->
                                ( { model
                                    | replay = Nothing
                                    , replayAnim = NotAnimating
                                    , drag = NotDragging
                                  }
                                , Cmd.none
                                )

                            entry :: rest ->
                                let
                                    advanced =
                                        { model
                                            | replay =
                                                Just { progress | pending = rest }
                                        }
                                in
                                prepareReplayStep
                                    entry.action
                                    entry.gesturePath
                                    entry.pathFrame
                                    advanced
                                    nowMs

                    Animating anim ->
                        case DragAnimation.step nowMs anim of
                            DragAnimation.InProgress { drag } ->
                                ( { model | drag = drag }
                                , Cmd.none
                                )

                            DragAnimation.Done { pendingAction } ->
                                let
                                    modelAfter =
                                        (Apply.applyAction pendingAction { model | drag = NotDragging }).model
                                in
                                ( { modelAfter
                                    | replayAnim = Beating { untilMs = nowMs + 1000 }
                                  }
                                , Cmd.none
                                )

                    Beating { untilMs } ->
                        if nowMs >= untilMs then
                            -- Advancement happened at queue-pop
                            -- time in NotAnimating; here we just
                            -- close out the beat.
                            ( { model | replayAnim = NotAnimating }
                            , Cmd.none
                            )

                        else
                            ( model, Cmd.none )

                    AwaitingHandRect _ ->
                        -- Nothing to do on a replay frame while we
                        -- wait for the DOM to report the hand card's
                        -- live rect. The HandCardRectReceived Msg
                        -- handler will transition us to Animating as
                        -- soon as the Task completes — typically the
                        -- very next frame.
                        ( model, Cmd.none )

                    PreRolling { untilMs } ->
                        if untilMs == 0 then
                            -- Lazy-initialize the deadline on the
                            -- first frame so the pre-roll lasts
                            -- a real 1000ms regardless of when
                            -- the first ReplayFrame tick arrives.
                            -- "Order of a second between major
                            -- events" matches the between-action
                            -- Beating duration.
                            ( { model | replayAnim = PreRolling { untilMs = nowMs + 1000 } }
                            , Cmd.none
                            )

                        else if nowMs >= untilMs then
                            ( { model | replayAnim = NotAnimating }
                            , Cmd.none
                            )

                        else
                            ( model, Cmd.none )



-- STEP PREP


{-| Transition from NotAnimating into the right next replay
state, given an action and its captured gesture path (if any).

Replay is the runtime — it owns the decision of whether to
honor a captured path or synthesize a fresh one (the "JIT"
branch, used by agent-emitted primitives that ship without a
path). The decision tree:

1.  **Captured path present and still valid** (its first
    sample matches the live source stack's loc): faithful
    playback. This is the human-replay common case.
2.  **Captured path absent OR stale** for an intra-board
    action: synthesize a fresh path via
    `Space.synthesizeBoardPath` and animate it. This is the
    agent-play common case (no path captured) and the
    out-of-band-MoveStack edge case (path captured but the
    source has since moved).
3.  **Captured path absent for a hand-origin action**: fire a
    `Browser.Dom.getElement` Task for the hand card's DOM id
    and transition to AwaitingHandRect. Hand origins live in
    the DOM, not in board coords, so we measure at replay
    time rather than synthesize blindly.
4.  **Anything else** (Splits, unknown shapes): apply
    immediately and beat. Splits are clicks in the live UI,
    so animating a fake drag for them would be a lie.

-}
prepareReplayStep :
    WireAction
    -> Maybe (List State.GesturePoint)
    -> PathFrame
    -> Model
    -> Float
    -> ( Model, Cmd Msg )
prepareReplayStep action maybePath frame model nowMs =
    let
        startAnimating anim =
            case Space.interpPath anim.path 0 of
                Just cursor ->
                    ( { model
                        | replayAnim = Animating anim
                        , drag = Space.animatedDragState anim cursor
                      }
                    , Cmd.none
                    )

                Nothing ->
                    applyImmediate

        applyImmediate =
            let
                modelAfter =
                    (Apply.applyAction action model).model
            in
            ( { modelAfter
                | replayAnim = Beating { untilMs = nowMs + beatAfter action }
                , drag = NotDragging
              }
            , Cmd.none
            )

        animateFromCaptured path =
            case path of
                [] ->
                    jitOrApply

                _ ->
                    case startBoardAnim action path frame model nowMs of
                        Just anim ->
                            startAnimating anim

                        Nothing ->
                            -- Captured path was deemed valid by
                            -- pathStillValid but the underlying
                            -- source-stack lookup (boardStackSource)
                            -- still failed. The two checks aren't
                            -- coupled; rather than silently degrade
                            -- to applyImmediate, escalate to JIT
                            -- synthesis. JIT itself falls back to
                            -- applyImmediate if it can't synthesize
                            -- either. This is the only place where
                            -- this lookup gap can surface during
                            -- replay; centralizing the fallback
                            -- here keeps the gap from being silent.
                            jitOrApply

        jitOrApply =
            case Space.synthesizeBoardPath action model nowMs of
                Just ( synthPath, synthFrame ) ->
                    case startBoardAnim action synthPath synthFrame model nowMs of
                        Just anim ->
                            startAnimating anim

                        Nothing ->
                            applyImmediate

                Nothing ->
                    -- No JIT recipe for this action shape. Try
                    -- the hand-origin async measurement path.
                    case prepareHandAnim action model of
                        Just result ->
                            ( { model
                                | replayAnim =
                                    AwaitingHandRect
                                        { action = action
                                        , source = result.source
                                        }
                              }
                            , Task.attempt HandCardRectReceived
                                (Task.map2 Tuple.pair
                                    (Browser.Dom.getElement
                                        (HandLayout.handCardDomId result.handCardToMeasure)
                                    )
                                    Time.now
                                )
                            )

                        Nothing ->
                            applyImmediate
    in
    case maybePath of
        Just (p :: rest) ->
            if Space.pathStillValid (p :: rest) action model then
                animateFromCaptured (p :: rest)

            else
                jitOrApply

        _ ->
            jitOrApply



-- ASYNC HAND-RECT COMPLETION


{-| Handle `HandCardRectReceived`: the async continuation of
`prepareReplayStep` for hand-origin actions. When the Task
succeeds we know the card's live center; pair that with the
target endpoint (stack edge for MergeHand, drop loc for
PlaceHand), synthesize a linear path, and begin Animating.

If the target can't be resolved — or the DOM query failed —
apply the action immediately and beat.

-}
handCardRectReceived :
    Result Browser.Dom.Error ( Browser.Dom.Element, Time.Posix )
    -> Model
    -> ( Model, Cmd Msg )
handCardRectReceived result model =
    case ( model.replayAnim, result ) of
        ( AwaitingHandRect ctx, Ok ( element, posix ) ) ->
            let
                nowMs =
                    toFloat (Time.posixToMillis posix)

                origin =
                    Space.elementTopLeftInViewport element

                maybeAnim =
                    finishHandAnim ctx.action origin nowMs ctx.source model
            in
            let
                applyNow =
                    let
                        modelAfter =
                            (Apply.applyAction ctx.action model).model
                    in
                    ( { modelAfter
                        | replayAnim = Beating { untilMs = nowMs + beatAfter ctx.action }
                        , drag = NotDragging
                      }
                    , Cmd.none
                    )
            in
            case maybeAnim of
                Just anim ->
                    case Space.interpPath anim.path 0 of
                        Just cursor ->
                            ( { model
                                | replayAnim = Animating anim
                                , drag = Space.animatedDragState anim cursor
                              }
                            , Cmd.none
                            )

                        Nothing ->
                            applyNow

                Nothing ->
                    applyNow

        ( AwaitingHandRect ctx, Err err ) ->
            -- DOM query failed (very unusual — the hand card is
            -- rendered and its id is stable). No synthesis
            -- fallback exists for hand-origin actions: we can't
            -- honestly produce a drag path without the card's
            -- live rect. Apply the action immediately and beat.
            let
                _ =
                    Debug.log "HandCardRectReceived err" err

                modelAfter =
                    (Apply.applyAction ctx.action model).model
            in
            ( { modelAfter
                | replayAnim = Beating { untilMs = 1000 }
                , drag = NotDragging
              }
            , Cmd.none
            )

        _ ->
            ( model, Cmd.none )



-- BEAT DURATION


{-| Inter-action beat duration (ms). `CompleteTurn` gets extra
time because a lot happens at once — hand refresh, score update,
active-player swap, dealt cards appearing. A normal beat reads
as buggy at that boundary. The base 800ms beat applies to
every primitive, whether it came from a captured human drag
or from an agent program — Replay is the runtime, the source
of the action doesn't change the timing budget.
-}
beatAfter : WireAction -> Float
beatAfter action =
    case action of
        WA.CompleteTurn ->
            2500

        _ ->
            800



-- INTERNAL


{-| Dispatch a board-origin wire action to its per-operation
Animate module. Nothing means the action is hand-origin (or an
unsupported kind); the caller falls back to the async DOM
measurement path or `applyImmediate`. One branch per
synchronous board-drag primitive.
-}
startBoardAnim :
    WireAction
    -> List State.GesturePoint
    -> PathFrame
    -> Model
    -> Float
    -> Maybe Space.AnimationInfo
startBoardAnim action path frame model nowMs =
    case action of
        WA.Split _ ->
            -- Splits are CLICKS in the live UI — a single event
            -- producing a single redraw. The server's
            -- requiresGestureMetadata gate forces a gesture path
            -- onto them for telemetry, but replay should not
            -- animate that fake drag: no floater, no cursor interp,
            -- just apply + beat, matching the live UI's
            -- click-responds-with-redraw simplicity. Returning
            -- Nothing drops the action into `applyImmediate`.
            Nothing

        WA.MergeStack payload ->
            AnimateMergeStack.start payload path frame model nowMs

        WA.MoveStack payload ->
            AnimateMoveStack.start payload path frame model nowMs

        _ ->
            Nothing


{-| Dispatch the synchronous phase 1 of hand-origin replay to
the matching per-primitive Animate module. Nothing means the
action isn't hand-origin (shouldn't reach this helper) or the
hand card can't be resolved on the current model.
-}
prepareHandAnim : WireAction -> Model -> Maybe HandPrepareResult
prepareHandAnim action model =
    case action of
        WA.MergeHand payload ->
            AnimateMergeHand.prepare payload model
                |> Maybe.map prepareResultFromMergeHand

        WA.PlaceHand payload ->
            AnimatePlaceHand.prepare payload model
                |> Maybe.map prepareResultFromPlaceHand

        _ ->
            Nothing


{-| Unified shape for Time's AwaitingHandRect bookkeeping.
The per-primitive Animate modules define their own typed
PrepareResult; we lift both into this common record for
the FSM.
-}
type alias HandPrepareResult =
    { source : State.DragSource
    , handCardToMeasure : Game.Rules.Card.Card
    }


prepareResultFromMergeHand : AnimateMergeHand.PrepareResult -> HandPrepareResult
prepareResultFromMergeHand r =
    { source = r.source
    , handCardToMeasure = r.handCardToMeasure
    }


prepareResultFromPlaceHand : AnimatePlaceHand.PrepareResult -> HandPrepareResult
prepareResultFromPlaceHand r =
    { source = r.source
    , handCardToMeasure = r.handCardToMeasure
    }


{-| Dispatch the async phase 2 of hand-origin replay. Given
the measured viewport origin and the stashed context, forward
to the matching Animate module to build the AnimationInfo.
-}
finishHandAnim :
    WireAction
    -> State.Point
    -> Float
    -> State.DragSource
    -> Model
    -> Maybe Space.AnimationInfo
finishHandAnim action origin nowMs source model =
    case action of
        WA.MergeHand payload ->
            AnimateMergeHand.finish payload origin nowMs source model

        WA.PlaceHand payload ->
            AnimatePlaceHand.finish payload origin nowMs source model

        _ ->
            Nothing
