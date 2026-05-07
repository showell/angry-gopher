module Fixtures exposing
    ( at
    , boardCardDragAt
    , defaultBoardRect
    , handCardDragAt
    , stackAt
    , withWingsBoard
    , withWingsHand
    )

{-| Shared test fixtures for drag-related tests.

The drag state is now two clean variants — `DraggingBoardCard`
holds a `BoardCardDragInfo`; `DraggingHandCard` holds a
`HandCardDragInfo`. These builders return the variant-specific
record so tests can construct realistic drags without boiling
back through any union-of-records intermediary.

`floaterTopLeft` is in board frame for board drags and
viewport frame for hand drags (matching the variant's implicit
coordinate frame). Adding a field to either info record ripples
through this one module, not through every test.

-}

import Game.Drag exposing (BoardCardDragInfo, HandCardDragInfo)
import Game.Rules.Card exposing (Card, OriginDeck(..))
import Game.CardStack as CardStack exposing (BoardLocation, CardStack)
import Game.Physics.GestureArbitration as GA
import Game.Physics.WingOracle exposing (WingId)
import Main.Types exposing (Point)


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


{-| Board-card drag fixture. `floaterTopLeft` is in BOARD
frame. The initial floater of a real drag is `stack.loc`, but
tests pass arbitrary positions to probe specific distances
from wings / landings. `cardIndex` defaults to 0 and
`originalCursor` defaults to (0, 0); tests that exercise
click-vs-drag arbitration set these explicitly via record
update.
-}
boardCardDragAt : CardStack -> Point -> BoardCardDragInfo
boardCardDragAt stack floaterTopLeft =
    { stack = stack
    , cardIndex = 0
    , originalCursor = { x = 0, y = 0 }
    , cursor = { x = 0, y = 0 }
    , floaterTopLeft = floaterTopLeft
    , gesturePath = []
    , wings = []
    }


{-| Hand-card drag fixture. `floaterTopLeft` is in VIEWPORT
frame. Hand drags don't carry `gesturePath` (replay
re-synthesizes via DOM measurement) and don't have a
click-vs-drag arbitration, so neither field is here.
-}
handCardDragAt : Card -> Point -> HandCardDragInfo
handCardDragAt card floaterTopLeft =
    { card = card
    , cursor = { x = 0, y = 0 }
    , floaterTopLeft = floaterTopLeft
    , wings = []
    }


{-| Add a list of wings to a board-card drag. Tests setting
up a hit-test scenario need the target wing(s) registered so
the filter in `floaterOverWingForBoard` has something to match
against.
-}
withWingsBoard : List WingId -> BoardCardDragInfo -> BoardCardDragInfo
withWingsBoard wings d =
    { d | wings = wings }


withWingsHand : List WingId -> HandCardDragInfo -> HandCardDragInfo
withWingsHand wings d =
    { d | wings = wings }
