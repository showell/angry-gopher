module Main.Msg exposing (Msg(..))

{-| The `Msg` type — every way the Elm runtime can nudge the
update function. Kept in its own module so `Main.Wire`,
`Main.Gesture`, `Main.View`, and `Main.elm` can all reference
its constructors without cyclic imports.

Extracted 2026-04-19 from the pre-split `Main.elm` monolith.

-}

import Browser.Dom
import Http
import Game.WingOracle exposing (WingId)
import Main.State exposing (ActionLogBundle, CompleteTurnOutcome, Point, RemoteState)
import Time


{-| Four flavours of constructor, grouped here for scan-ability:

  - **Pointer gestures** — MouseDownOnBoardCard,
    MouseDownOnHandCard, MouseMove (carries MouseEvent
    timeStamp for behaviorist telemetry), MouseUp,
    WingEntered, WingLeft, BoardRectReceived.
  - **Button clicks** — ClickCompleteTurn, ClickHint,
    ClickInstantReplay, ClickReplayPauseToggle, PopupOk.
  - **HTTP responses** — ActionSent (fire-and-forget),
    SessionReceived, StateRefreshed,
    CompleteTurnResponded, ActionLogFetched.
  - **Timer** — ReplayFrame (fires via onAnimationFrame
    during replay; drives drag re-animation + inter-action
    beat).

-}
type Msg
    = MouseDownOnBoardCard { stackIndex : Int, cardIndex : Int } Point Float
    | MouseDownOnHandCard Int Point Float
    | MouseMove Point Float
    | MouseUp Point Float
    | WingEntered WingId
    | WingLeft WingId
    | BoardRectReceived (Result Browser.Dom.Error Browser.Dom.Element)
    | HandCardRectReceived (Result Browser.Dom.Error ( Browser.Dom.Element, Time.Posix ))
    | ActionSent (Result Http.Error ())
    | SessionReceived (Result Http.Error Int)
    | ClickCompleteTurn
    | StateRefreshed (Result Http.Error RemoteState)
    | ClickHint
    | CompleteTurnResponded (Result Http.Error CompleteTurnOutcome)
    | PopupOk
    | ClickInstantReplay
    | ReplayFrame Time.Posix
    | ClickReplayPauseToggle
    | ActionLogFetched (Result Http.Error ActionLogBundle)
