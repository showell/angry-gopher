module Fixtures exposing
    ( at
    , boardStackDragAt
    , defaultBoardRect
    , handCardDragAt
    , stackAt
    , withWings
    )

{-| Shared test fixtures for drag-related tests.

DragInfo has a wide record shape — every test that constructs
one has historically been vulnerable to "add a field, break
every test" fragility. This module provides a neutral
`defaultDragInfo` plus small builders that override only the
fields a test cares about. Adding a field to `DragInfo`
ripples through this one module, not through every test.

Each builder returns a DragInfo that's minimally valid for
the drag type it represents: intra-board drags are
BoardFrame with floaterTopLeft in board frame; hand drags
are ViewportFrame with floaterTopLeft in viewport frame and a
measured boardRect populated.

-}

import Game.Card exposing (Card, OriginDeck(..))
import Game.CardStack as CardStack exposing (BoardLocation, CardStack)
import Game.GestureArbitration as GA
import Game.WingOracle exposing (WingId)
import Main.State exposing (DragInfo, DragSource(..), PathFrame(..), Point)


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


{-| A neutral DragInfo, suitable as a base to override from.
Source is a 2-card placeholder at the board origin;
floaterTopLeft = (0, 0); pathFrame = BoardFrame. Tests that
care about any of these override them via Elm record update
syntax.
-}
defaultDragInfo : DragInfo
defaultDragInfo =
    let
        placeholder =
            stackAt "2C,3D" (at 0 0)
    in
    { source = FromBoardStack placeholder
    , cursor = { x = 0, y = 0 }
    , originalCursor = { x = 0, y = 0 }
    , floaterTopLeft = { x = 0, y = 0 }
    , wings = []
    , hoveredWing = Nothing
    , boardRect = Nothing
    , clickIntent = Nothing
    , gesturePath = []
    , pathFrame = BoardFrame
    }


{-| Intra-board drag fixture. `floaterTopLeft` is in BOARD
frame (matches pathFrame). The initial floater of a real
drag is `stack.loc`, but tests pass arbitrary positions to
probe specific distances from wings / landings.
-}
boardStackDragAt : CardStack -> Point -> DragInfo
boardStackDragAt stack floaterTopLeft =
    { defaultDragInfo
        | source = FromBoardStack stack
        , floaterTopLeft = floaterTopLeft
        , pathFrame = BoardFrame
    }


{-| Hand-card drag fixture. `floaterTopLeft` is in VIEWPORT
frame. `boardRect` is populated — hand-card hit-tests need
it to translate the eventual-landing board-frame point into
viewport frame.
-}
handCardDragAt : Card -> Point -> DragInfo
handCardDragAt card floaterTopLeft =
    { defaultDragInfo
        | source = FromHandCard card
        , floaterTopLeft = floaterTopLeft
        , boardRect = Just defaultBoardRect
        , pathFrame = ViewportFrame
    }


{-| Add a list of wings to a DragInfo. Tests setting up a
hit-test scenario need the target wing(s) registered so the
filter in `floaterOverWing` has something to match against.
-}
withWings : List WingId -> DragInfo -> DragInfo
withWings wings info =
    { info | wings = wings }
