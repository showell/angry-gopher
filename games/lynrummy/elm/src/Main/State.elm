module Main.State exposing
    ( ActionLogBundle
    , ActionLogEntry
    , EnvelopeForGesture
    , Flags
    , Model
    , PopupContent
    , ReplayAnimationState(..)
    , ReplayState
    , baseModel
    , boardDomIdFor
    , canUndoThisTurn
    , collapseUndos
    , encodeGameState
    )

{-| All application-wide data types and the initial Model.

Extracted from the pre-split Main.elm monolith 2026-04-19 during
the refactor that unwound "one big module" (an artifact of the
original TS game's deployment constraint that no longer applies).

This module is pure types + trivial helpers — no I/O, no
rendering, no update logic, no Msg. Drag state types now live
in `Game.Drag`; small leaf types (`Point`, `PathFrame`,
`GesturePoint`) live in `Main.Types`.

-}

import Game.CardStack as CardStack
import Game.Dealer
import Game.Drag exposing (DragState(..))
import Game.Game exposing (GameState)
import Game.GameEvent exposing (GameEvent(..))
import Game.Hand as Hand exposing (Hand)
import Game.Physics.GestureArbitration as GA
import Game.Rules.Card as Card exposing (Card)
import Game.Status exposing (StatusKind(..), StatusMessage)
import Json.Encode as Encode exposing (Value)
import Main.Types exposing (GesturePoint, PathFrame)



-- MODEL


type alias Model =
    { gameState : GameState

    -- The session's pre-first-action snapshot. Pinned at
    -- bootstrap (new-session deal or resume's bundle) and
    -- never mutated thereafter. Instant Replay seeds its
    -- ReplayState's gameState from this.
    , initialGameState : GameState
    , drag : DragState

    -- Live DOM-measured board rect. Populated lazily on the
    -- first drag-start (or replay-start) of the session via
    -- `Browser.Dom.getElement`; reused thereafter. Lifted out
    -- of drag state so it isn't re-fetched per drag and so
    -- replay doesn't need a parallel storage site.
    , boardRect : Maybe GA.Rect
    , sessionId : Maybe Int
    , status : StatusMessage
    , hintedCards : List Card
    , popup : Maybe PopupContent
    , actionLog : List ActionLogEntry
    , nextSeq : Int

    -- When `Just`, replay is in flight; the engine owns its
    -- own gameState/drag/anim/eventPlan. When `Nothing`,
    -- the live game is on screen. Replaces the prior trio
    -- (replay / replayAnim / replayBaseline).
    , replayState : Maybe ReplayState

    -- Constant string forming the board's DOM id (via
    -- `boardDomIdFor`). Multi-Play-per-page hosting retired
    -- with the puzzle gallery; the field survives so the DOM
    -- contract is unchanged.
    , gameId : String

    -- The id of the engine port request currently in flight (if
    -- any). Set when the Hint button fires `engineRequest`;
    -- cleared by the matching `gameHintResponse`. Used to discard
    -- stale responses (e.g. if the user clicks hint twice rapidly).
    , pendingEngineRequest : Maybe Int

    -- Monotonic counter for engine port request ids. Incremented
    -- each time we fire a request so the response can be matched
    -- back.
    , nextEngineRequestId : Int
    }


{-| The replay engine's complete working state — only present
on Model when replay is in flight (`Maybe ReplayState`).

`gameState` is the replay's frame-by-frame view of the world;
it advances as `eventPlan` is consumed, while `Model.gameState`
stays at the live game position. `drag` is the synthesized
animation drag that paints the floater (independent of the
live drag, which is force-cleared during replay). `anim` is
the per-step FSM. `eventPlan` is the queue of entries left to
walk — sliced from `actionLog` at replay start.

Subscription during replay is `Browser.Events.onAnimationFrame`
(not a fixed Time.every tick) so drag animations can interpolate
cursor position smoothly.

-}
type alias ReplayState =
    { gameState : GameState
    , eventPlan : List ActionLogEntry
    , paused : Bool
    , drag : DragState
    , anim : ReplayAnimationState
    }


{-| Per-step animation state for Instant Replay. Separated from
`ReplayProgress` so the replay walker can be driven at real-time
cadence (matching the captured gesture durations) for drag-
derived actions, and a fixed 1-second "beat" between actions.

Phases:

  - **NotAnimating** — transient: between `step` increment and
    the first animation frame of the new step. Replay init
    enters here.
  - **Animating** — a drag-derived action is replaying. The
    cursor position is interpolated along `path` by
    `(nowMs - startMs)`. When elapsed ≥ path duration, apply
    the action and switch to `Beating`. The seeded `DragState`
    lives in `model.drag`; per-frame updates patch only its
    `floaterTopLeft`.
  - **Beating** — holding a 1-second gap between actions.
    When `nowMs ≥ untilMs`, advance `step` and return to
    `NotAnimating`.
  - **PreRolling** — holding the rewound starting board on screen
    for a moment before the very first action fires, so the
    viewer registers the initial state. When `nowMs ≥ untilMs`,
    returns to `NotAnimating` WITHOUT advancing `step`.

-}
type ReplayAnimationState
    = NotAnimating
    | Animating
        { startMs : Float
        , path : List GesturePoint
        , pendingAction : GameEvent
        }
    | Beating { untilMs : Float }
    | PreRolling { untilMs : Float }
    | AwaitingHandRect { action : GameEvent }


{-| Cheapest-possible popup for turn-boundary ceremony. One
character speaks (admin), delivers a multi-line message, user
clicks OK to dismiss + advance. The body is the full text —
caller builds it with whatever narrative (you scored N, we'll
deal M next turn, etc.).
-}
type alias PopupContent =
    { admin : String
    , body : String
    }


{-| Captured drag telemetry attached to a wire-bound action. A
sequence of timestamped points plus the coordinate frame those
points live in. Travels alongside primitives on the wire (in
`Main.Wire.encodeEnvelope`'s `gesture_metadata`) and through the
in-process action-log entries that drive Instant Replay.

Hand-origin actions (`MergeHand`, `PlaceHand`) ship as `Nothing`:
they always replay via live DOM measurement, so a captured path
would be dead weight. Drag-derived intra-board actions ship a
`Just envelope` after translating viewport samples to board
frame at the send boundary. Non-drag actions (button clicks,
`CompleteTurn`) ship `Nothing`.

The shape is also produced by the agent-gesture synthesizer
(`Main.Play.synthesizeAgentGestures`) so agent-driven actions
land in the action-log with the same envelope as human drags.

-}
type alias EnvelopeForGesture =
    { path : List GesturePoint, frame : PathFrame }



-- FLAGS


{-| Flags from the HTML harness. `initialSessionId` is server-side
rendered from the URL (present on reload so the UI resumes the
same game rather than dropping back to the lobby); `seedSource`
is `Date.now()` from the host page, used by `Play.init` to seed
`Game.Dealer.dealFullGame` for fresh sessions.
-}
type alias Flags =
    { initialSessionId : Maybe Int
    , seedSource : Int
    }



-- SERVER-RESPONSE DATA SHAPES




{-| Mirror of the `initialStateDecoder` shape on the wire — produces
JSON that the server stores in `meta.initial_state` and that
`initialStateDecoder` can read back on resume.
-}
encodeGameState : GameState -> Value
encodeGameState rs =
    Encode.object
        [ ( "board", Encode.list CardStack.encodeCardStack rs.board )
        , ( "hands", Encode.list encodeHand rs.hands )
        , ( "active_player_index", Encode.int rs.activePlayerIndex )
        , ( "turn_index", Encode.int rs.turnIndex )
        , ( "deck", Encode.list Card.encodeCard rs.deck )
        , ( "cards_played_this_turn", Encode.int rs.cardsPlayedThisTurn )
        , ( "victor_awarded", Encode.bool rs.victorAwarded )
        ]


encodeHand : Hand -> Value
encodeHand h =
    Encode.object
        [ ( "hand_cards", Encode.list CardStack.encodeHandCard h.handCards ) ]


{-| Bundle returned by /sessions/:id/actions — the action log
plus the session-specific initial-state snapshot. Initial state
lets `ClickInstantReplay` rewind to the session's actual seeded
deal instead of a hardcoded Dealer fixture. Each action entry
also carries any captured gesture telemetry, so replay can
re-animate the original drag at real speed.
-}
type alias ActionLogBundle =
    { initialState : GameState
    , actions : List ActionLogEntry
    }


type alias ActionLogEntry =
    { action : GameEvent
    , gesturePath : Maybe (List GesturePoint)
    , pathFrame : PathFrame
    }



-- ACTION LOG HELPERS


{-| Collapse Undo tokens: each Undo cancels the most recent
non-CompleteTurn entry. The result is the effective action
sequence — what replay and bootstrap should actually apply.

Used by bootstrapFromBundle (to fold only effective actions)
and clickInstantReplay (so replay never animates Undo tokens).

-}
collapseUndos : List ActionLogEntry -> List ActionLogEntry
collapseUndos entries =
    List.foldl
        (\entry stack ->
            case entry.action of
                Undo ->
                    popLastUndoable stack

                _ ->
                    stack ++ [ entry ]
        )
        []
        entries


popLastUndoable : List ActionLogEntry -> List ActionLogEntry
popLastUndoable entries =
    case List.reverse entries of
        [] ->
            entries

        last :: rest ->
            case last.action of
                CompleteTurn ->
                    entries

                _ ->
                    List.reverse rest


{-| True when clicking Undo would do something — the effective
action list has at least one non-CompleteTurn entry in the
current turn.
-}
canUndoThisTurn : Model -> Bool
canUndoThisTurn model =
    case List.reverse (collapseUndos model.actionLog) of
        [] ->
            False

        last :: _ ->
            case last.action of
                CompleteTurn ->
                    False

                _ ->
                    True



-- DOM ID


{-| CSS id of the board element. The main app uses `gameId =
"default"` (a constant; multi-Play-per-page hosting retired
with the puzzle gallery, so disambiguation is no longer
load-bearing — the parameter survives so the DOM contract is
unchanged).
-}
boardDomIdFor : String -> String
boardDomIdFor gameId =
    "lynrummy-board-" ++ gameId



-- ACTIVE HAND
-- INIT STATE


{-| Starting Model. Both `gameState` and `initialGameState`
share the empty placeholder until bootstrap (NewSession's deal
or ResumeSession's bundle) replaces them with the real session
state.
-}
baseModel : Model
baseModel =
    let
        emptyGameState =
            { board = Game.Dealer.initialBoard
            , hands = [ Hand.empty, Hand.empty ]
            , activePlayerIndex = 0
            , turnIndex = 0
            , deck = []
            , cardsPlayedThisTurn = 0
            , victorAwarded = False
            }
    in
    { gameState = emptyGameState
    , initialGameState = emptyGameState
    , drag = NotDragging
    , boardRect = Nothing
    , sessionId = Nothing
    , status = { text = "You may begin moving.", kind = Inform }
    , hintedCards = []
    , popup = Nothing
    , actionLog = []
    , nextSeq = 1
    , replayState = Nothing
    , gameId = "default"
    , pendingEngineRequest = Nothing
    , nextEngineRequestId = 1
    }
