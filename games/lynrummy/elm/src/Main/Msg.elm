module Main.Msg exposing (Msg(..))

{-| The `Msg` type — every way the Elm runtime can nudge the
update function. Kept in its own module so `Main.Wire`,
`Main.Gesture`, `Main.View`, and `Main.elm` can all reference
its constructors without cyclic imports.

Extracted 2026-04-19 from the pre-split `Main.elm` monolith.

-}

import Browser.Dom
import Http
import Game.Card exposing (Card)
import Game.CardStack exposing (CardStack)
import Game.Game exposing (CompleteTurnOutcome)
import Main.State exposing (ActionLogBundle, Point)
import Time


{-| Four flavours of constructor, grouped here for scan-ability:

  - **Pointer gestures** — MouseDownOnBoardCard,
    MouseDownOnHandCard, MouseMove (carries MouseEvent
    timeStamp for behaviorist telemetry), MouseUp,
    BoardRectReceived. Wing hover is NOT a Msg — wing
    detection is computed in Elm on every MouseMove from the
    floater's rect, not dispatched by DOM events.
  - **Button clicks** — ClickCompleteTurn, ClickHint,
    ClickInstantReplay, ClickReplayPauseToggle, PopupOk.
  - **HTTP responses** — ActionSent (fire-and-forget),
    SessionReceived, CompleteTurnResponded,
    ActionLogFetched.
  - **Timer** — ReplayFrame (fires via onAnimationFrame
    during replay; drives drag re-animation + inter-action
    beat).

-}
type Msg
    = MouseDownOnBoardCard { stack : CardStack, cardIndex : Int } Point Float
    | MouseDownOnHandCard Card Point Float
    | MouseMove Point Float
    | MouseUp Point Float
    | BoardRectReceived (Result Browser.Dom.Error Browser.Dom.Element)
    | HandCardRectReceived (Result Browser.Dom.Error ( Browser.Dom.Element, Time.Posix ))
    | ActionSent (Result Http.Error ())
    | SessionReceived (Result Http.Error Int)
    | ClickCompleteTurn
    | ClickHint
    | CompleteTurnResponded (Result Http.Error CompleteTurnOutcome)
    | PopupOk
    | ClickInstantReplay
    | ReplayFrame Time.Posix
    | ClickReplayPauseToggle
    | ActionLogFetched (Result Http.Error ActionLogBundle)
