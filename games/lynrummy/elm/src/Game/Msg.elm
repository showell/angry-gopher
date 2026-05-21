module Game.Msg exposing (Msg(..))

import Browser.Dom
import Lib.ActionLog exposing (ActionLogEntry)
import Lib.CardStack exposing (CardStack, HandCard)
import Lib.GameState exposing (GameState)
import Lib.Engine exposing (AgentStep)
import Lib.Point exposing (Point)
import Http
import Time


type Msg
    = PointerDownOnBoardCard { stack : CardStack, cardIndex : Int, point : Point, time : Int }
    | PointerDownOnHandCard { handCard : HandCard, point : Point }
    | PointerMove Point Int
    | PointerUp Point Int
    | LongPressTimerFired Int
    | BoardRectReceived (Result Browser.Dom.Error Browser.Dom.Element)
    | HandCardRectReceived (Result Browser.Dom.Error ( Browser.Dom.Element, Browser.Dom.Element, Time.Posix ))
    | ActionSent (Result Http.Error ())
    | SessionReceived (Result Http.Error Int)
    | ClickCompleteTurn
    | ClickUndo
    | ClickHint
    | ReadyForAgentTurn { afterTurn : GameState, outboundPayload : String }
    | ReadyForHumanTurn { afterTurn : GameState }
    | ResumeAgentTurn
    | ContinueHumanTurn
    | ClickInstantReplay
    | ClickReplayPauseToggle
    | AnimationTick Time.Posix
    | ActionLogFetched (Result Http.Error ( GameState, List ActionLogEntry ))
    | HintLinesReceived (List String)
    | AgentMovesReceived (List AgentStep)
    | EngineResponseFailed String
    | EngineResponseStale
