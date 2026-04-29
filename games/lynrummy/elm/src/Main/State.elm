module Main.State exposing
    ( ActionLogBundle
    , ActionLogEntry
    , ActionOutcome
    , DragInfo
    , DragSource(..)
    , DragState(..)
    , EnvelopeForGesture
    , Flags
    , GesturePoint
    , Model
    , PathFrame(..)
    , Point
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
rendering, no update logic, no Msg. Other Main.\* modules import
from here; it imports only the LynRummy domain primitives. That
makes State a safe leaf: changes here ripple out, but nothing
ripples in.

-}

import Game.Agent.Move exposing (Move)
import Game.Rules.Card as Card exposing (Card)
import Game.CardStack as CardStack exposing (CardStack)
import Game.Dealer
import Game.Physics.GestureArbitration as GA
import Game.Hand as Hand exposing (Hand)
import Game.Score as Score
import Game.Physics.WingOracle exposing (WingId)
import Game.WireAction exposing (WireAction(..))
import Json.Encode as Encode exposing (Value)
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
      board : List CardStack
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
    , sessionId : Maybe Int

    -- When this Play instance is hosting a puzzle, names
    -- which puzzle. Rides in the JSON body of every action for
    -- forensics (so logs can attribute moves to their puzzle).
    -- Nothing for full-game sessions.
    , puzzleName : Maybe String
    , status : StatusMessage
    , score : Int
    , hintedCards : List Card
    , popup : Maybe PopupContent
    , actionLog : List ActionLogEntry
    , nextSeq : Int
    , replay : Maybe ReplayProgress
    , replayAnim : ReplayAnimationState
    , replayBaseline : Maybe RemoteState

    -- Live DOM-measured board offset used by the replay
    -- synthesizer to translate board-frame coords to current
    -- viewport coords. Fetched via `Browser.Dom.getElement`
    -- when replay starts; stays Nothing outside replay.
    , replayBoardRect : Maybe { x : Int, y : Int }

    -- Per-instance identity. The main app uses "default"; each
    -- Puzzles-embedded Play gets the puzzle's session id stringified.
    -- Drives the board DOM id (via `boardDomIdFor`) so multiple
    -- Play instances on one page don't collide on
    -- `Browser.Dom.getElement`.
    , gameId : String

    -- True when this Play instance lives inside a Puzzles
    -- panel — suppresses the Complete Turn button and the
    -- "← Lobby" link in the turn-controls row. Puzzles are
    -- always within-a-turn; surfacing Complete Turn would mean
    -- nothing. Main app sets this False.
    , hideTurnControls : Bool

    -- Puzzles "Let agent play" program counter. Holds the
    -- list of plan lines the agent computed at the start of
    -- the walk; each click consumes one line (animating its
    -- primitives at 500ms pacing) and advances. Empty/Nothing
    -- means "no walk in progress — next click solves fresh."
    -- A user gesture between clicks invalidates the cache by
    -- clearing this back to Nothing.
    , agentProgram : Maybe (List Move)

    -- The decoded initial board/hand state for the current
    -- puzzle, stored at bootstrap so Reset can restore it
    -- without a server round-trip. Nothing for full-game sessions.
    , puzzleInitialState : Maybe RemoteState
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
    the action and switch to `Beating`.
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
        , source : DragSource
        , pathFrame : PathFrame
        , pendingAction : WireAction
        }
    | Beating { untilMs : Float }
    | PreRolling { untilMs : Float }
    | AwaitingHandRect
        { action : WireAction
        , source : DragSource
        }


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


type DragState
    = NotDragging
    | Dragging DragInfo


{-| Live-drag bookkeeping.

The RENDER-CANONICAL field is `floaterTopLeft` — the one
thing the View layer reads to position the drag floater.
Everything in this record feeds INTO floaterTopLeft;
nothing derives FROM it.

Key invariants:

  - `floaterTopLeft` is in the same frame as `pathFrame`:
    board frame for intra-board drags, viewport frame for
    hand-origin drags. Path samples (in `gesturePath`) match.
  - Mousemove maintains `floaterTopLeft` by ADDING cursor
    deltas (pure vectors, frame-agnostic).
  - `cursor` is the current mouse position in viewport frame.
    Used only for live concerns — the `isCursorOverBoard`
    hit-test, `clickIntentAfterMove`. Never travels on the
    wire.
  - `originalCursor` is the cursor at mousedown, also
    viewport. Used only by `clickIntentAfterMove` to measure
    drift.
  - No `grabOffset` field. For intra-board drags it isn't
    needed at all (the floater starts at `stack.loc`). For
    hand-origin drags it's applied at mousedown to derive the
    initial viewport floater position, then forgotten.

-}
type alias DragInfo =
    { source : DragSource
    , cursor : Point
    , originalCursor : Point
    , floaterTopLeft : Point
    , wings : List WingId
    , hoveredWing : Maybe WingId
    , boardRect : Maybe GA.Rect
    , clickIntent : Maybe Int
    , gesturePath : List GesturePoint
    , pathFrame : PathFrame
    }


{-| What the user picked up at mousedown. Content-based:
a board-stack drag carries the CardStack value; a hand-card
drag carries the Card. Same identification model as the wire
format uses — one representation everywhere.
-}
type DragSource
    = FromBoardStack CardStack
    | FromHandCard Card


type alias Point =
    { x : Int, y : Int }


{-| Coordinate frame for a captured gesture path. The board
is a self-contained widget positioned anywhere in the app via
CSS; drag floaters rendered as children of the board take
board-frame coords directly. Hand-origin drags cross the board
widget boundary and must be viewport-positioned.

  - **ViewportFrame** — origin at the browser viewport top-left.
    Used for live mouse-captured paths and for hand-origin
    drags that cross widget boundaries.
  - **BoardFrame** — origin at the board element's top-left.
    Used for intra-board drags (Python-synthesized and,
    eventually, board-to-board live-captured after a
    capture-time translation).

See `feedback_*` / architecture doc for the rule: pick the
right frame, don't maintain parallel-coordinate bookkeeping.

-}
type PathFrame
    = ViewportFrame
    | BoardFrame


{-| Behaviorist telemetry sample captured during a drag. The
`tMs` is the `MouseEvent.timeStamp` (performance.now-style,
document-lifetime relative). The `x`/`y` pair is in whichever
frame the containing path is tagged with (see `PathFrame`).
-}
type alias GesturePoint =
    { tMs : Float, x : Int, y : Int }


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
    { board : List CardStack
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


{-| CSS id of the board element for a given game id. Per-
instance so multiple Play instances on one page don't collide
on `Browser.Dom.getElement`. The main app uses `gameId =
"default"`; each Puzzles-embedded Play gets its puzzle session
id stringified.
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
    , sessionId = Nothing
    , puzzleName = Nothing
    , status = { text = "You may begin moving.", kind = Inform }
    , score = Score.forStacks Game.Dealer.initialBoard
    , hintedCards = []
    , popup = Nothing
    , actionLog = []
    , nextSeq = 1
    , replay = Nothing
    , replayAnim = NotAnimating
    , replayBaseline = Nothing
    , replayBoardRect = Nothing
    , gameId = "default"
    , hideTurnControls = False
    , agentProgram = Nothing
    , puzzleInitialState = Nothing
    }
