module Game.State exposing
    ( Model
    , applyEvent
    , baseModel
    , bootstrapFromBundle
    , canUndoThisTurn
    , lastUndoableAction
    )

{-| All application-wide data types and the initial Model.
-}

import Game.Msg exposing (Msg)
import Lib.ActionLog as ActionLog exposing (ActionLogEntry)
import Lib.Animation.Animate exposing (AnimationState)
import Lib.Dealer
import Lib.Drag exposing (DragState(..))
import Lib.Execute as Execute
import Lib.Game as Game
import Lib.GameState exposing (GameState)
import Lib.GameEvent exposing (GameEvent(..))
import Lib.Hand as Hand
import Lib.Physics.BoardGeometry exposing (refereeBounds)
import Lib.Physics.GestureArbitration as GA
import Lib.Popup exposing (PopupContent)
import Lib.Rules.Card exposing (Card)
import Lib.Status exposing (StatusKind(..), StatusMessage)



-- MODEL


type alias Model =
    { gameState : GameState

    -- The session's pre-first-action snapshot. Pinned at
    -- bootstrap (new-session deal or resume's bundle) and
    -- never mutated thereafter. Instant Replay seeds its
    -- AnimationState's gameState from this.
    , initialGameState : GameState
    , drag : DragState

    -- Live DOM-measured board rect. Populated lazily on the
    -- first drag-start of the session via
    -- `Browser.Dom.getElement`; reused thereafter.
    , boardRect : Maybe GA.Rect
    , sessionId : Maybe Int
    , status : StatusMessage
    , hintedCards : List Card
    , popup : Maybe { content : PopupContent, dismissMsg : Msg }
    , actionLog : List ActionLogEntry
    , nextSeq : Int

    -- The single in-flight animation, if any. Two flavors fill
    -- it: Instant Replay (user-initiated, only outside an agent
    -- turn) or the real-time agent move (during an agent turn,
    -- one Animate.start per agent_step response). They're
    -- mutually exclusive — `agentTurnActive` discriminates on
    -- Completed. During an agent move, the animation's
    -- `entries` field carries the actions being played; the
    -- AnimationTick Completed branch pushes them onto
    -- `actionLog` at the moment `gameState` catches up.
    , animationState : Maybe AnimationState

    -- Spans the entire agent turn: from ReadyForAgentTurn
    -- kickoff through the loop (Thinking…, animations,
    -- between-step gaps) and across the closing "agent done"
    -- popup, cleared on ReadyForHumanTurn. Source of truth for
    -- the human-input lockout — and the discriminator for
    -- AnimationTick's Completed branch (agent move vs replay).
    , agentTurnActive : Bool

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



-- ACTION LOG HELPERS


{-| True when clicking Undo would do something — the effective
action list has at least one non-CompleteTurn entry in the
current turn.
-}
canUndoThisTurn : List ActionLogEntry -> Bool
canUndoThisTurn log =
    lastUndoableAction log /= Nothing


{-| The most recent action eligible for undo, or Nothing.
"Eligible" = top of `collapseUndos`'s effective list AND not a
CompleteTurn (turn flips can't be undone).
-}
lastUndoableAction : List ActionLogEntry -> Maybe GameEvent
lastUndoableAction log =
    case List.reverse (ActionLog.collapseUndos log) of
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
            { board = Lib.Dealer.initialBoard
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
    , animationState = Nothing
    , agentTurnActive = False
    , gameId = "default"
    , pendingEngineRequest = Nothing
    , nextEngineRequestId = 1
    }



-- BOOTSTRAP


{-| Hydrate a Model from a server-fetched action log: pin the
initial state as both the live `gameState` and the immutable
`initialGameState` (reserved for Instant Replay's rebuild), then
fold the action log forward.
-}
bootstrapFromBundle : GameState -> List ActionLogEntry -> Model -> Model
bootstrapFromBundle initialState actions model =
    let
        atInitial =
            { model
                | actionLog = actions
                , nextSeq = List.length actions + 1
                , gameState = initialState
                , initialGameState = initialState
            }
    in
    List.foldl
        (\entry m -> { m | gameState = applyEvent entry.action m.gameState })
        atInitial
        (ActionLog.collapseUndos actions)


{-| The UI serializes core game actions transparently back and
forth with the Go server (and file system). We replay them
back here so that players can resume where the prior session
left off.
-}
applyEvent : GameEvent -> GameState -> GameState
applyEvent event state =
    case event of
        Split p ->
            { state | board = Execute.split p.stack p.cardIndex state.board }

        MergeStack p ->
            { state | board = Execute.mergeStack p.source p.target p.side state.board }

        MoveStack p ->
            { state | board = Execute.moveStack p.stack p.newLoc state.board }

        MergeHand p ->
            Execute.mergeHand p.handCard p.target p.side state

        PlaceHand p ->
            Execute.placeHand p.handCard p.loc state

        CompleteTurn ->
            Tuple.first (Game.applyCompleteTurn refereeBounds state)

        Undo ->
            state
