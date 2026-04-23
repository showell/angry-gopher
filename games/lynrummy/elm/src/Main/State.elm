module Main.State exposing
    ( ActionLogBundle
    , ActionLogEntry
    , ActionOutcome
    , DragInfo
    , DragSource(..)
    , DragState(..)
    , Flags
    , GesturePoint
    , Model
    , PathFrame(..)
    , Point
    , PopupContent
    , RemoteState
    , ReplayAnimation(..)
    , ReplayProgress
    , StatusKind(..)
    , StatusMessage
    , activeHand
    , baseModel
    , boardDomIdFor
    , setActiveHand
    )

{-| All application-wide data types and the initial Model.

Extracted from the pre-split Main.elm monolith 2026-04-19 during
the refactor that unwound "one big module" (an artifact of the
original TS game's deployment constraint that no longer applies).

This module is pure types + trivial helpers — no I/O, no
rendering, no update logic, no Msg. Other Main.* modules import
from here; it imports only the LynRummy domain primitives. That
makes State a safe leaf: changes here ripple out, but nothing
ripples in.

-}

import Game.Card exposing (Card)
import Game.CardStack exposing (CardStack)
import Game.GestureArbitration as GA
import Game.Hand as Hand exposing (Hand)
import Game.PlayerTurn exposing (CompleteTurnResult)
import Game.Score as Score
import Game.WingOracle exposing (WingId)
import Game.WireAction exposing (WireAction)
import Game.Dealer



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
    , status : StatusMessage
    , score : Int
    , hintedCards : List Card
    , popup : Maybe PopupContent
    , actionLog : List ActionLogEntry
    , replay : Maybe ReplayProgress
    , replayAnim : ReplayAnimation
    , replayBaseline : Maybe RemoteState

    -- Live DOM-measured board offset used by the replay
    -- synthesizer to translate board-frame coords to current
    -- viewport coords. Fetched via `Browser.Dom.getElement`
    -- when replay starts; stays Nothing outside replay.
    , replayBoardRect : Maybe { x : Int, y : Int }

    -- Per-instance identity. The main app uses "default"; each
    -- lab-embedded Play gets the puzzle's session id stringified.
    -- Drives the board DOM id (via `boardDomIdFor`) so multiple
    -- Play instances on one page don't collide on
    -- `Browser.Dom.getElement`.
    , gameId : String

    -- True when this Play instance lives inside a BOARD_LAB
    -- puzzle panel — suppresses the Complete Turn button and
    -- the "← Lobby" link in the turn-controls row. Puzzles are
    -- always within-a-turn; surfacing Complete Turn would mean
    -- nothing. Main app sets this False.
    , hideTurnControls : Bool

    -- True when this Play instance is displaying a pre-captured
    -- session (e.g. the lab's agent-review mode). Gestures are
    -- ignored so the viewer can't accidentally contaminate the
    -- captured session's action log. Only Instant Replay + the
    -- rendered board/hand surface work.
    , readonly : Bool
    }


{-| Replay progress: a walker over `actionLog`. `step` is the
index of the action to play NEXT. When it reaches
`List.length log`, replay stops and `replay` returns to
`Nothing`.

Subscription during replay is `Browser.Events.onAnimationFrame`
(not a fixed Time.every tick) so drag animations can interpolate
cursor position smoothly. See `replayAnim` for per-step
animation state.
-}
type alias ReplayProgress =
    { step : Int
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
  - **PreRoll** — holding the rewound starting board on screen
    for a moment before the very first action fires, so the
    viewer registers the initial state. When `nowMs ≥ untilMs`,
    returns to `NotAnimating` WITHOUT advancing `step`.

-}
type ReplayAnimation
    = NotAnimating
    | Animating
        { startMs : Float
        , path : List GesturePoint
        , source : DragSource
        , grabOffset : Point
        , pathFrame : PathFrame
        , pendingAction : WireAction
        }
    | Beating { untilMs : Float }
    | PreRoll { untilMs : Float }
    | AwaitingHandRect
        { action : WireAction
        , source : DragSource
        , grabOffset : Point
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


type alias DragInfo =
    { source : DragSource
    , cursor : Point
    , originalCursor : Point
    , grabOffset : Point
    , wings : List WingId
    , hoveredWing : Maybe WingId
    , boardRect : Maybe GA.Rect
    , clickIntent : Maybe Int
    , gesturePath : List GesturePoint
    , pathFrame : PathFrame
    }


{-| What the user picked up at mousedown. Content-based, not
positional: a board-stack drag carries the CardStack value it
started from; a hand-card drag carries the Card. This mirrors
the wire format's CardStack refs — one model for identifying
stacks/cards everywhere, not "index in the middle of the drag
lifecycle, value on the wire." See `feedback_record_facts_decide_later.md`
and the STATUS_BAR-era discussion on competing representations.
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



-- FLAGS


{-| Flags from the HTML harness. `initialSessionId` comes from
the URL hash (e.g., "#12") — present on reload so the UI can
resume the same game rather than dropping back to the lobby.
-}
type alias Flags =
    { initialSessionId : Maybe Int }



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



-- DOM ID


{-| CSS id of the board element for a given game id. Per-
instance so multiple Play instances on one page don't collide
on `Browser.Dom.getElement`. The main app uses `gameId =
"default"`; each lab-embedded Play gets its puzzle session
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


listAt : Int -> List a -> Maybe a
listAt i xs =
    List.head (List.drop i xs)



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
    { -- Game-state fields.
      board = Game.Dealer.initialBoard
    , hands = [ Game.Dealer.openingHand, Hand.empty ]
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
    , status = { text = "You may begin moving.", kind = Inform }
    , score = Score.forStacks Game.Dealer.initialBoard
    , hintedCards = []
    , popup = Nothing
    , actionLog = []
    , replay = Nothing
    , replayAnim = NotAnimating
    , replayBaseline = Nothing
    , replayBoardRect = Nothing
    , gameId = "default"
    , hideTurnControls = False
    , readonly = False
    }
