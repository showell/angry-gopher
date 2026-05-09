module Main.State exposing
    ( Flags
    , Model
    , ReplayAnimationState(..)
    , ReplayState
    , baseModel
    , bootstrapFromBundle
    , canUndoThisTurn
    , encodeGameState
    , lastUndoableAction
    )

{-| All application-wide data types and the initial Model. -}

import Game.ActionLog as ActionLog exposing (ActionLogBundle, ActionLogEntry)
import Game.Execute as Execute
import Game.BoardDragTypes exposing (BoardCardDragInfo)
import Game.CardStack as CardStack
import Game.Dealer
import Game.Drag exposing (DragState(..))
import Game.Game exposing (GameState)
import Game.GameEvent exposing (GameEvent(..))
import Game.Hand as Hand exposing (Hand)
import Game.HandDragTypes exposing (HandCardDragInfo)
import Game.Physics.GestureArbitration as GA
import Game.Popup exposing (PopupContent)
import Game.Rules.Card as Card exposing (Card)
import Game.Status exposing (StatusKind(..), StatusMessage)
import Game.TimeLoc exposing (TimeLoc)
import Json.Encode as Encode exposing (Value)



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
    , anim : ReplayAnimationState
    }


{-| Per-step animation state for Instant Replay.

Phases:

  - **NotAnimating** — transient between steps. Replay init
    enters here.
  - **AnimatingBoard / AnimatingHand** — a drag is replaying.
    Each variant carries its own `dragInfo` (the live drag data
    the view renders) plus the path being interpolated.
    Splitting board vs hand at the type level eliminates the
    parallel `rs.drag` field and the runtime variant-tag
    re-discovery that `setFloaterTopLeft` used to do.
  - **Beating** — 1-second gap between actions.
  - **PreRolling** — hold the rewound starting board briefly
    before action 0 fires.
  - **AwaitingHandRect** — fired a `Browser.Dom.getElement` for
    a hand card's live rect; transitions to `AnimatingHand`
    when the Task resolves.

-}
type ReplayAnimationState
    = NotAnimating
    | AnimatingBoard
        { startMs : Float
        , path : List TimeLoc
        , pendingAction : GameEvent
        , dragInfo : BoardCardDragInfo
        }
    | AnimatingHand
        { startMs : Float
        , path : List TimeLoc
        , pendingAction : GameEvent
        , dragInfo : HandCardDragInfo
        }
    | Beating { untilMs : Float }
    | PreRolling { untilMs : Float }
    | AwaitingHandRect { action : GameEvent }


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


-- ACTION LOG HELPERS


{-| True when clicking Undo would do something — the effective
action list has at least one non-CompleteTurn entry in the
current turn.
-}
canUndoThisTurn : Model -> Bool
canUndoThisTurn model =
    lastUndoableAction model /= Nothing


{-| The most recent action eligible for undo, or Nothing.
"Eligible" = top of `collapseUndos`'s effective list AND not a
CompleteTurn (turn flips can't be undone).
-}
lastUndoableAction : Model -> Maybe GameEvent
lastUndoableAction model =
    case List.reverse (ActionLog.collapseUndos model.actionLog) of
        [] ->
            Nothing

        last :: _ ->
            case last.action of
                CompleteTurn ->
                    Nothing

                _ ->
                    Just last.action



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



-- BOOTSTRAP


{-| Hydrate a Model from a server-fetched ActionLogBundle:
pin the bundle's initial state as both the live `gameState`
and the immutable `initialGameState` (used by Instant Replay's
ReplayState seed), then fold the action log forward.
-}
bootstrapFromBundle : ActionLogBundle -> Model -> Model
bootstrapFromBundle bundle model =
    let
        atInitial =
            { model
                | actionLog = bundle.actions
                , nextSeq = List.length bundle.actions + 1
                , gameState = bundle.initialState
                , initialGameState = bundle.initialState
            }
    in
    List.foldl
        (\entry m -> { m | gameState = Execute.applyEvent entry.action m.gameState })
        atInitial
        (ActionLog.collapseUndos bundle.actions)
