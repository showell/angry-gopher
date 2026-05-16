module Game.Msg exposing (Msg(..))

import Browser.Dom
import Lib.ActionLog exposing (ActionLogEntry)
import Lib.CardStack exposing (CardStack, HandCard)
import Lib.Game exposing (GameState)
import Lib.GameEvent exposing (GameEvent)
import Lib.Point exposing (Point)
import Http
import Time


type Msg
    = MouseDownOnBoardCard { stack : CardStack, cardIndex : Int, point : Point, time : Int }
    | MouseDownOnHandCard { handCard : HandCard, point : Point }
    | MouseMove Point Int
    | MouseUp Point Int
    | BoardRectReceived (Result Browser.Dom.Error Browser.Dom.Element)
    | HandCardRectReceived (Result Browser.Dom.Error ( Browser.Dom.Element, Browser.Dom.Element, Time.Posix ))
    | ActionSent (Result Http.Error ())
    | SessionReceived (Result Http.Error Int)
    | ClickCompleteTurn
    | ClickUndo
    | ClickHint
    | ReadyForAgentTurn { afterTurn : GameState, outboundPayload : String }
    | ReadyForHumanTurn { afterTurn : GameState }
    | ContinueHumanTurn
    | ClickInstantReplay
    | ClickReplayPauseToggle
    | AnimationTick Time.Posix
    | ActionLogFetched (Result Http.Error ( GameState, List ActionLogEntry ))
    | HintLinesReceived (List String)
    | AgentMovesReceived (List GameEvent)
    | EngineResponseFailed String
    | EngineResponseStale
