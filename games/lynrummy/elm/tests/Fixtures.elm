module Fixtures exposing
    ( DragBundle
    , at
    , boardStackDragAt
    , defaultBoardRect
    , handCardDragAt
    , stackAt
    , withWings
    )

{-| Shared test fixtures for drag-related tests.

The drag state is now split across three records —
`DragInfo`, `DragContext`, and `ClickArbiter`. This module
exports a `DragBundle` wrapper so test code can work with a
single value and destructure only what it needs.

Each builder returns a `DragBundle` that's minimally valid for
the drag type it represents: intra-board drags are BoardFrame
with floaterTopLeft in board frame; hand drags are ViewportFrame
with floaterTopLeft in viewport frame and a measured boardRect
populated.

Adding a field to any of the three records ripples through this
one module, not through every test.

-}

import Game.Rules.Card exposing (Card, OriginDeck(..))
import Game.CardStack as CardStack exposing (BoardLocation, CardStack)
import Game.Physics.GestureArbitration as GA
import Game.Physics.WingOracle exposing (WingId)
import Main.State
    exposing
        ( ClickArbiter
        , DragContext
        , DragInfo
        , DragSource(..)
        , PathFrame(..)
        , Point
        )


{-| Bundles DragInfo + DragContext + ClickArbiter into one
value for test ergonomics. Tests destructure only what they
need.
-}
type alias DragBundle =
    { info : DragInfo
    , ctx : DragContext
    , arb : ClickArbiter
    }


at : Int -> Int -> BoardLocation
at left top =
    { left = left, top = top }


stackAt : String -> BoardLocation -> CardStack
stackAt shorthand loc =
    case CardStack.fromShorthand shorthand DeckOne loc of
        Just s ->
            s

        Nothing ->
            Debug.todo ("bad shorthand in fixture: " ++ shorthand)


defaultBoardRect : GA.Rect
defaultBoardRect =
    { x = 300, y = 100, width = 800, height = 600 }


defaultInfo : DragInfo
defaultInfo =
    let
        placeholder =
            stackAt "2C,3D" (at 0 0)
    in
    { source = FromBoardStack placeholder
    , cursor = { x = 0, y = 0 }
    , floaterTopLeft = { x = 0, y = 0 }
    , gesturePath = []
    , pathFrame = BoardFrame
    }


defaultCtx : DragContext
defaultCtx =
    { wings = [], boardRect = Nothing }


defaultArb : ClickArbiter
defaultArb =
    { clickIntent = Nothing, originalCursor = { x = 0, y = 0 } }


{-| Intra-board drag fixture. `floaterTopLeft` is in BOARD
frame (matches pathFrame). The initial floater of a real
drag is `stack.loc`, but tests pass arbitrary positions to
probe specific distances from wings / landings.
-}
boardStackDragAt : CardStack -> Point -> DragBundle
boardStackDragAt stack floaterTopLeft =
    { info =
        { defaultInfo
            | source = FromBoardStack stack
            , floaterTopLeft = floaterTopLeft
            , pathFrame = BoardFrame
        }
    , ctx = defaultCtx
    , arb = defaultArb
    }


{-| Hand-card drag fixture. `floaterTopLeft` is in VIEWPORT
frame. `boardRect` is populated — hand-card hit-tests need
it to translate the eventual-landing board-frame point into
viewport frame.
-}
handCardDragAt : Card -> Point -> DragBundle
handCardDragAt card floaterTopLeft =
    { info =
        { defaultInfo
            | source = FromHandCard card
            , floaterTopLeft = floaterTopLeft
            , pathFrame = ViewportFrame
        }
    , ctx = { defaultCtx | boardRect = Just defaultBoardRect }
    , arb = defaultArb
    }


{-| Add a list of wings to a DragBundle. Tests setting up a
hit-test scenario need the target wing(s) registered so the
filter in `floaterOverWing` has something to match against.
-}
withWings : List WingId -> DragBundle -> DragBundle
withWings wings bundle =
    { bundle | ctx = { wings = wings, boardRect = bundle.ctx.boardRect } }
