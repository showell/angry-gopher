module LynRummy.Tricks.Trick exposing (Play, Trick)

{-| Trick + Play types. Mirrors
`angry-gopher/lynrummy/tricks/trick.go`.

The Go version uses interfaces; Elm uses record types with
function fields. Play does NOT carry a back-reference to its
Trick — Elm type aliases can't be mutually recursive without
indirection, and downstream consumers don't need it (the Play's
trickId string suffices for logging / fixture matching).

-}

import LynRummy.CardStack exposing (CardStack, HandCard)


{-| A concrete proposed move that a trick has recognized.

Fields:

  - `trickId` — stable machine id of the originating trick, e.g.
    `"direct_play"`. Used for logging / annotations / stats.
  - `handCards` — hand cards this play will consume.
  - `apply` — produce (newBoard, cardsActuallyConsumed) from the
    current board. Empty `cardsActuallyConsumed` means the apply
    couldn't complete (board drifted since `findPlays` ran).

-}
type alias Play =
    { trickId : String
    , handCards : List HandCard
    , apply : List CardStack -> ( List CardStack, List HandCard )
    }


{-| The trick plugin itself. Stateless; `findPlays` returns every
applicable Play for the given (hand, board) state.
-}
type alias Trick =
    { id : String
    , description : String
    , findPlays : List HandCard -> List CardStack -> List Play
    }
