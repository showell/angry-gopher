module Main.State exposing
    ( ActionLogBundle
    , ActionLogEntry
    , ActionOutcome
    , EnvelopeForGesture
    , Flags
    , Model
    , PopupContent
    , RemoteState
    , ReplayAnimationState(..)
    , ReplayProgress
    , StatusKind(..)
    , StatusMessage
    , activeHand
    , baseModel
    , boardDomIdFor
    , canUndoThisTurn
    , collapseUndos
    , encodeRemoteState
    , setActiveHand
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

import Game.Drag exposing (DragState(..))
import Game.Rules.Card as Card exposing (Card)
import Game.CardStack as CardStack
import Game.Dealer
import Game.Physics.GestureArbitration as GA
import Game.Hand as Hand exposing (Hand)
import Game.Score as Score
import Game.WireAction exposing (WireAction(..))
import Json.Encode as Encode exposing (Value)
import Main.Types exposing (GesturePoint, PathFrame)
import Main.Util exposing (listAt)



-- MODEL


{-| The full client state. Field groups:

  - **Game-state fields** — shape of `Game.Game.GameState`,
    threaded through `Main.Apply.applyAction` and
    `Game.applyCompleteTurn`. Changes here reflect real game
    progression.
  - **UI-layer fields** — drag state, popup, status, score
    display, replay progress. These are the client's own
    concerns that never cross the wire.

The extensible-record pattern lets `Game.applyCompleteTurn`
operate on Model directly without wrapping/unwrapping.

-}
type alias Model =
    { -- Game-state fields.
      board : List CardStack.CardStack
    , hands : List Hand
    , scores : List Int
    , activePlayerIndex : Int
    , turnIndex : Int
    , deck : List Card
    , cardsPlayedThisTurn : Int
    , victorAwarded : Bool
    , turnStartBoardScore : Int

    -- UI-layer fields.
    , drag : DragState

    -- Live DOM-measured board rect. Populated lazily on the
    -- first drag-start (or replay-start) of the session via
    -- `Browser.Dom.getElement`; reused thereafter. Lifted out
    -- of drag state so it isn't re-fetched per drag and so
    -- replay doesn't need a parallel storage site.
    , boardRect : Maybe GA.Rect
    , sessionId : Maybe Int
    , status : StatusMessage
    , score : Int
    , hintedCards : List Card
    , popup : Maybe PopupContent
    , actionLog : List ActionLogEntry
    , nextSeq : Int
    , replay : Maybe ReplayProgress
    , replayAnim : ReplayAnimationState
    , replayBaseline : Maybe RemoteState

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


{-| Replay's own work queue: the entries left to walk, in
order. Replay pops the head, animates / applies, and stops
when the queue is empty.

One engine serves two callers:

  - **Instant Replay** (the Replay button): rewinds the model
    to baseline and hands the entire `actionLog` to Replay.
  - **Agent play** (the Let-Agent-Play button): hands Replay
    just the primitives the agent emitted for this move.

Either way, Replay only sees the entries it's supposed to
walk — no indexing into a longer list, no off-by-one stop
arithmetic. The full `actionLog` stays the persistent record
that other code (replay-resume on session bootstrap, the
wire) reads; Replay's queue is a transient slice.

Subscription during replay is `Browser.Events.onAnimationFrame`
(not a fixed Time.every tick) so drag animations can interpolate
cursor position smoothly. See `replayAnim` for per-step
animation state.

-}
type alias ReplayProgress =
    { pending : List ActionLogEntry
    , paused : Bool
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
        , pendingAction : WireAction
        }
    | Beating { untilMs : Float }
    | PreRolling { untilMs : Float }
    | AwaitingHandRect { action : WireAction }


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


type alias StatusMessage =
    { text : String, kind : StatusKind }


{-| What `Main.Apply.applyAction` returns: the post-action Model
plus the status message describing what just happened. The
message is generated at the same point the mutation is
performed, colocated with the physics — no separate "diff the
boards to figure out what happened" classifier. Callers decide
whether to use the status (human actions do; replay ignores).
-}
type alias ActionOutcome =
    { model : Model
    , status : StatusMessage
    }


type StatusKind
    = Inform
    | Celebrate
    | Scold


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


{-| Authoritative game-state snapshot as the server computes it.
Elm pulls this once on session bootstrap; after that, all state
updates flow through `Main.Apply.applyAction` /
`Game.applyCompleteTurn`. Shape carries every field required to
reconstitute the autonomous game.
-}
type alias RemoteState =
    { board : List CardStack.CardStack
    , hands : List Hand
    , scores : List Int
    , activePlayerIndex : Int
    , turnIndex : Int
    , deck : List Card
    , cardsPlayedThisTurn : Int
    , victorAwarded : Bool
    , turnStartBoardScore : Int
    }


{-| Mirror of the `initialStateDecoder` shape on the wire — produces
JSON that the server stores in `meta.initial_state` and that
`initialStateDecoder` can read back on resume.
-}
encodeRemoteState : RemoteState -> Value
encodeRemoteState rs =
    Encode.object
        [ ( "board", Encode.list CardStack.encodeCardStack rs.board )
        , ( "hands", Encode.list encodeHand rs.hands )
        , ( "scores", Encode.list Encode.int rs.scores )
        , ( "active_player_index", Encode.int rs.activePlayerIndex )
        , ( "turn_index", Encode.int rs.turnIndex )
        , ( "deck", Encode.list Card.encodeCard rs.deck )
        , ( "cards_played_this_turn", Encode.int rs.cardsPlayedThisTurn )
        , ( "victor_awarded", Encode.bool rs.victorAwarded )
        , ( "turn_start_board_score", Encode.int rs.turnStartBoardScore )
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
    { initialState : RemoteState
    , actions : List ActionLogEntry
    }


type alias ActionLogEntry =
    { action : WireAction
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


{-| Active hand is whichever player's turn it is. All hand-card
drag/drop uses this. Empty-hand fallback keeps the view
resilient if state hasn't populated yet.
-}
activeHand : Model -> Hand
activeHand model =
    case listAt model.activePlayerIndex model.hands of
        Just h ->
            h

        Nothing ->
            -- Per memory/feedback_dont_paper_over_problems.md: if the
            -- active player index falls off the end of the hands list,
            -- log loud rather than silently returning an empty hand.
            -- This was a paper-over for live-play race conditions; in
            -- replay it just hides bridge bugs.
            let
                _ =
                    Debug.log
                        ("[activeHand] no hand at activePlayerIndex="
                            ++ String.fromInt model.activePlayerIndex
                            ++ " (have "
                            ++ String.fromInt (List.length model.hands)
                            ++ " hands) — returning Hand.empty (paper-over symptom)"
                        )
                        ()
            in
            Hand.empty


{-| Returns a Model with the active player's hand replaced.
Used by local UI-side hand updates (drag-drop that removes a
card before the server round-trip).
-}
setActiveHand : Hand -> Model -> Model
setActiveHand newHand model =
    { model
        | hands =
            List.indexedMap
                (\i h ->
                    if i == model.activePlayerIndex then
                        newHand

                    else
                        h
                )
                model.hands
    }



-- INIT STATE


{-| Starting Model. Game-state fields default to the hardcoded
opening board + canned P1 hand + empty P2 hand; UI-layer fields
default to quiescent / empty values.

On session resume (URL hash), `Main.elm init` immediately fires
`fetchActionLog` which replaces these defaults: the bundle's
`initialState` seeds the board/hands/deck/..., the action log
is folded through the local reducer to reach current state,
and `initialState` is also stashed in `replayBaseline` for the
Instant Replay rewind target.

-}
baseModel : Model
baseModel =
    { -- Game-state fields. Hands start empty as a placeholder
      -- before bootstrap; the real deal arrives from the
      -- session bootstrap (existing session) or from
      -- `Game.Dealer.dealFullGame` (fresh page load).
      board = Game.Dealer.initialBoard
    , hands = [ Hand.empty, Hand.empty ]
    , scores = [ 0, 0 ]
    , activePlayerIndex = 0
    , turnIndex = 0
    , deck = []
    , cardsPlayedThisTurn = 0
    , victorAwarded = False
    , turnStartBoardScore = Score.forStacks Game.Dealer.initialBoard

    -- UI-layer fields.
    , drag = NotDragging
    , boardRect = Nothing
    , sessionId = Nothing
    , status = { text = "You may begin moving.", kind = Inform }
    , score = Score.forStacks Game.Dealer.initialBoard
    , hintedCards = []
    , popup = Nothing
    , actionLog = []
    , nextSeq = 1
    , replay = Nothing
    , replayAnim = NotAnimating
    , replayBaseline = Nothing
    , gameId = "default"
    , pendingEngineRequest = Nothing
    , nextEngineRequestId = 1
    }
