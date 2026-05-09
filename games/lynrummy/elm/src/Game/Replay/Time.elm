module Game.Replay.Time exposing
    ( ClickInstantReplayInputs
    , clickInstantReplay
    , clickReplayPauseToggle
    , handCardRectReceived
    , replayFrame
    )

{-| The temporal half of Instant Replay. Owns the FSM and the
clock-driven Msg handlers. Operates on `ReplayState` only —
Model never enters this module.

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
    CompleteTurn, since a lot happens at once).

-}

import Browser.Dom
import Game.ActionLog as ActionLog
import Game.CardStack exposing (CardStack)
import Game.Drag as Drag exposing (DragState(..))
import Game.Execute as Execute
import Game.Game exposing (GameState)
import Game.GameEvent as GameEvent exposing (GameEvent)
import Game.HandLayout as HandLayout
import Game.Physics.GestureArbitration as GA
import Game.Replay.AnimateMergeHand as AnimateMergeHand
import Game.Replay.AnimateMergeStack as AnimateMergeStack
import Game.Replay.AnimateMoveStack as AnimateMoveStack
import Game.Replay.AnimatePlaceHand as AnimatePlaceHand
import Game.Replay.DragAnimation as DragAnimation
import Game.Replay.Space as Space
import Game.Rules.Card
import Main.Msg exposing (Msg(..))
import Main.State as State
    exposing
        ( ReplayAnimationState(..)
        , ReplayState
        )
import Game.TimeLoc exposing (TimeLoc)
import Game.Point exposing (Point)
import Task
import Time



-- CLICK HANDLER: INSTANT REPLAY


type alias ClickInstantReplayInputs =
    { gameId : String
    , initialGameState : GameState
    , actionLog : List ActionLog.ActionLogEntry
    }


{-| Construct a fresh ReplayState seeded from the session's
pre-first-action snapshot, and emit the cmd that fetches the
live board rect. Caller (Main.Play) is responsible for
attaching the new ReplayState to Model and force-clearing
`model.drag`.
-}
clickInstantReplay : ClickInstantReplayInputs -> ( ReplayState, Cmd Msg )
clickInstantReplay inputs =
    ( { gameState = inputs.initialGameState
      , eventPlan = State.collapseUndos inputs.actionLog
      , paused = False
      , drag = NotDragging
      , anim = PreRolling { untilMs = 0 }
      }
    , Task.attempt BoardRectReceived
        (Browser.Dom.getElement (State.boardDomIdFor inputs.gameId))
    )



-- CLICK HANDLER: PAUSE TOGGLE


clickReplayPauseToggle : ReplayState -> ReplayState
clickReplayPauseToggle rs =
    { rs | paused = not rs.paused }



-- FRAME TICK


{-| Core replay state machine. One step per `onAnimationFrame`;
no-op when paused. Returns `Nothing` when the queue drains
(the caller clears `replayState` from Model).
-}
replayFrame : Float -> ReplayState -> ( Maybe ReplayState, Cmd Msg )
replayFrame nowMs rs =
    if rs.paused then
        ( Just rs, Cmd.none )

    else
        case rs.anim of
            NotAnimating ->
                case rs.eventPlan of
                    [] ->
                        ( Nothing, Cmd.none )

                    entry :: rest ->
                        prepareReplayStep
                            entry.action
                            { rs | eventPlan = rest }
                            nowMs
                            |> mapStateAndCmd Just

            Animating anim ->
                case DragAnimation.step nowMs anim of
                    DragAnimation.InProgress { floaterTopLeft } ->
                        ( Just { rs | drag = Drag.setFloaterTopLeft floaterTopLeft rs.drag }
                        , Cmd.none
                        )

                    DragAnimation.Done { pendingAction } ->
                        ( Just
                            { rs
                                | drag = NotDragging
                                , gameState = Execute.applyEvent pendingAction rs.gameState
                                , anim = Beating { untilMs = nowMs + 1000 }
                            }
                        , Cmd.none
                        )

            Beating { untilMs } ->
                if nowMs >= untilMs then
                    ( Just { rs | anim = NotAnimating }, Cmd.none )

                else
                    ( Just rs, Cmd.none )

            AwaitingHandRect _ ->
                ( Just rs, Cmd.none )

            PreRolling { untilMs } ->
                if untilMs == 0 then
                    -- Lazy-initialize the deadline on the
                    -- first frame so the pre-roll lasts
                    -- a real 1000ms regardless of when
                    -- the first ReplayFrame tick arrives.
                    ( Just { rs | anim = PreRolling { untilMs = nowMs + 1000 } }, Cmd.none )

                else if nowMs >= untilMs then
                    ( Just { rs | anim = NotAnimating }, Cmd.none )

                else
                    ( Just rs, Cmd.none )


mapStateAndCmd : (a -> b) -> ( a, Cmd msg ) -> ( b, Cmd msg )
mapStateAndCmd f ( a, cmd ) =
    ( f a, cmd )



-- STEP PREP


{-| Transition from NotAnimating into the right next replay
state. The path (if any) lives inside the GameEvent's
MergeStack/MoveStack variant; the event itself carries it
end-to-end.
-}
prepareReplayStep : GameEvent -> ReplayState -> Float -> ( ReplayState, Cmd Msg )
prepareReplayStep action rs nowMs =
    let
        startAnimating anim =
            case Space.interpPath anim.path 0 of
                Just cursor ->
                    ( { rs
                        | anim = Animating { startMs = anim.startMs, path = anim.path, pendingAction = anim.pendingAction }
                        , drag = Space.animatedDragState anim cursor
                      }
                    , Cmd.none
                    )

                Nothing ->
                    applyImmediate

        applyImmediate =
            ( { rs
                | gameState = Execute.applyEvent action rs.gameState
                , anim = Beating { untilMs = nowMs + beatAfter action }
                , drag = NotDragging
              }
            , Cmd.none
            )

        animateFromCaptured =
            case startBoardAnim action rs.gameState.board nowMs of
                Just anim ->
                    startAnimating anim

                Nothing ->
                    -- Captured path was deemed valid by
                    -- pathStillValid but the underlying
                    -- source-stack lookup (boardStackSource)
                    -- still failed. Escalate to JIT.
                    jitOrApply

        jitOrApply =
            case Space.synthesizeBoardPath action rs.gameState.board nowMs of
                Just synthPath ->
                    case startBoardAnimWithPath action synthPath rs.gameState.board nowMs of
                        Just anim ->
                            startAnimating anim

                        Nothing ->
                            applyImmediate

                Nothing ->
                    -- No JIT recipe for this action shape. Try
                    -- the hand-origin async measurement path.
                    case prepareHandAnim action rs.gameState of
                        Just result ->
                            ( { rs | anim = AwaitingHandRect { action = action } }
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
    case capturedBoardPath action of
        Just (p :: rest) ->
            if Space.isPathStillValid (p :: rest) action rs.gameState.board then
                animateFromCaptured

            else
                jitOrApply

        _ ->
            jitOrApply


{-| Pull the captured board path out of an event variant.
Only `MergeStack` and `MoveStack` carry one; everything else
returns Nothing.
-}
capturedBoardPath : GameEvent -> Maybe (List TimeLoc)
capturedBoardPath action =
    case action of
        GameEvent.MergeStack p ->
            Just p.boardPath

        GameEvent.MoveStack p ->
            Just p.boardPath

        _ ->
            Nothing



-- ASYNC HAND-RECT COMPLETION


{-| Handle `HandCardRectReceived`: the async continuation of
`prepareReplayStep` for hand-origin actions. When the Task
succeeds we know the card's live center; pair that with the
target endpoint, synthesize a linear path, and begin Animating.

If the target can't be resolved — or the DOM query failed —
apply the action immediately and beat.

-}
handCardRectReceived :
    Result Browser.Dom.Error ( Browser.Dom.Element, Time.Posix )
    -> Maybe GA.Rect
    -> ReplayState
    -> ( ReplayState, Cmd Msg )
handCardRectReceived result maybeBoardRect rs =
    case ( rs.anim, result ) of
        ( AwaitingHandRect ctx, Ok ( element, posix ) ) ->
            let
                nowMs =
                    toFloat (Time.posixToMillis posix)

                origin =
                    Space.elementTopLeftInViewport element

                maybeAnim =
                    finishHandAnim ctx.action origin nowMs rs.gameState maybeBoardRect

                applyNow =
                    ( { rs
                        | gameState = Execute.applyEvent ctx.action rs.gameState
                        , anim = Beating { untilMs = nowMs + beatAfter ctx.action }
                        , drag = NotDragging
                      }
                    , Cmd.none
                    )
            in
            case maybeAnim of
                Just anim ->
                    case Space.interpPath anim.path 0 of
                        Just cursor ->
                            ( { rs
                                | anim = Animating { startMs = anim.startMs, path = anim.path, pendingAction = anim.pendingAction }
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
            in
            ( { rs
                | gameState = Execute.applyEvent ctx.action rs.gameState
                , anim = Beating { untilMs = 1000 }
                , drag = NotDragging
              }
            , Cmd.none
            )

        _ ->
            ( rs, Cmd.none )



-- BEAT DURATION


{-| Inter-action beat duration (ms). `CompleteTurn` gets extra
time because a lot happens at once — hand refresh, score update,
active-player swap, dealt cards appearing.
-}
beatAfter : GameEvent -> Float
beatAfter action =
    case action of
        GameEvent.CompleteTurn ->
            2500

        _ ->
            800



-- INTERNAL


{-| Dispatch a board-origin wire action to its per-operation
Animate module. The path is read from the event's payload.
Nothing means the action is hand-origin (or an unsupported
kind).
-}
startBoardAnim : GameEvent -> List CardStack -> Float -> Maybe Space.AnimationInfo
startBoardAnim action board nowMs =
    case action of
        GameEvent.Split _ ->
            -- Splits are CLICKS in the live UI; replay should not
            -- animate that fake drag. Returning Nothing drops the
            -- action into `applyImmediate`.
            Nothing

        GameEvent.MergeStack payload ->
            AnimateMergeStack.start payload board nowMs

        GameEvent.MoveStack payload ->
            AnimateMoveStack.start payload board nowMs

        _ ->
            Nothing


{-| JIT path: synthesizeBoardPath produced a fresh path, hand
it to the Animate module by overriding the event's boardPath
in flight.
-}
startBoardAnimWithPath :
    GameEvent
    -> List TimeLoc
    -> List CardStack
    -> Float
    -> Maybe Space.AnimationInfo
startBoardAnimWithPath action path board nowMs =
    case action of
        GameEvent.MergeStack p ->
            AnimateMergeStack.start { p | boardPath = path } board nowMs

        GameEvent.MoveStack p ->
            AnimateMoveStack.start { p | boardPath = path } board nowMs

        _ ->
            Nothing


{-| Dispatch the synchronous phase 1 of hand-origin replay to
the matching per-primitive Animate module.
-}
prepareHandAnim : GameEvent -> GameState -> Maybe HandPrepareResult
prepareHandAnim action gameState =
    case action of
        GameEvent.MergeHand payload ->
            AnimateMergeHand.prepare payload gameState
                |> Maybe.map (\r -> { handCardToMeasure = r.handCardToMeasure })

        GameEvent.PlaceHand payload ->
            AnimatePlaceHand.prepare payload gameState
                |> Maybe.map (\r -> { handCardToMeasure = r.handCardToMeasure })

        _ ->
            Nothing


{-| Unified shape for prepareReplayStep return path —
just names which hand card the DOM measurement should target.
-}
type alias HandPrepareResult =
    { handCardToMeasure : Game.Rules.Card.Card
    }


{-| Dispatch the async phase 2 of hand-origin replay.
-}
finishHandAnim :
    GameEvent
    -> Point
    -> Float
    -> GameState
    -> Maybe GA.Rect
    -> Maybe Space.AnimationInfo
finishHandAnim action origin nowMs gameState maybeBoardRect =
    case action of
        GameEvent.MergeHand payload ->
            AnimateMergeHand.finish payload origin nowMs gameState maybeBoardRect

        GameEvent.PlaceHand payload ->
            AnimatePlaceHand.finish payload origin nowMs gameState maybeBoardRect

        _ ->
            Nothing
