module Main.Msg exposing (Msg(..))

{-| The `Msg` type — every way the Elm runtime can nudge the
update function. Kept in its own module so `Main.Wire`,
`Main.Gesture`, `Main.View`, and `Main.elm` can all reference
its constructors without cyclic imports.

Extracted 2026-04-19 from the pre-split `Main.elm` monolith.

-}

import Browser.Dom
import Http
import Json.Encode as Encode
import Game.Rules.Card exposing (Card)
import Game.CardStack exposing (CardStack)
import Main.State exposing (ActionLogBundle, Point)
import Time


{-| Four flavours of constructor, grouped here for scan-ability:

  - **Pointer gestures** — MouseDownOnBoardCard,
    MouseDownOnHandCard, MouseMove (carries MouseEvent
    timeStamp for behaviorist telemetry), MouseUp,
    BoardRectReceived. Wing hover is NOT a Msg — wing
    detection is computed in Elm on every MouseMove from the
    floater's rect, not dispatched by DOM events.
  - **Button clicks** — ClickCompleteTurn, ClickUndo, ClickHint,
    ClickInstantReplay, ClickReplayPauseToggle, PopupOk.
  - **HTTP responses** — ActionSent (fire-and-forget),
    SessionReceived, ActionLogFetched.
  - **Timer** — ReplayFrame (fires via onAnimationFrame
    during replay; drives drag re-animation + inter-action
    beat).

-}
{- MouseMove and MouseUp deliberately drop the `MouseDownOn*`
   prefix family. The two `MouseDownOn*` siblings share a
   prefix because each one names which target the press
   landed on (board card vs hand card) — the target is
   load-bearing for `update`'s dispatch. MouseMove and MouseUp
   carry no per-target distinction: while a drag is live, the
   only listeners are the document-level `Browser.Events`
   subscriptions, and the gesture's target is already pinned in
   `model.drag`. Renaming them to `MouseUpAnywhere` etc. would
   be lying about a sub-pattern that doesn't exist.

   Per `union_naming_three_calls.md` rule U3: when two siblings
   share a prefix that encodes a sub-pattern, every sibling
   that fits the sub-pattern should follow it, OR the prefix
   should be dropped entirely on those that don't fit, with a
   comment. This is the comment.
-}
type Msg
    = MouseDownOnBoardCard { stack : CardStack, cardIndex : Int, point : Point, time : Float }
    | MouseDownOnHandCard { card : Card, point : Point, time : Float }
    | MouseMove Point Float
    | MouseUp Point Float
    | BoardRectReceived (Result Browser.Dom.Error Browser.Dom.Element)
    | HandCardRectReceived (Result Browser.Dom.Error ( Browser.Dom.Element, Time.Posix ))
    | ActionSent (Result Http.Error ())
    | SessionReceived (Result Http.Error Int)
    | ClickCompleteTurn
    | ClickUndo
    | ClickReset
    | ClickHint
    | ClickAgentPlay
    | PopupOk
    | ClickInstantReplay
    | ReplayFrame Time.Posix
    | ClickReplayPauseToggle
    | ActionLogFetched (Result Http.Error ActionLogBundle)
    | EngineSolveResult Encode.Value
    | GameHintReceived Encode.Value
