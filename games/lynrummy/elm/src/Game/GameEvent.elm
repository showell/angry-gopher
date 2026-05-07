module Game.GameEvent exposing (GameEvent(..))

{-| The fundamental player-action vocabulary of Lyn Rummy.
Each value names a thing the player did — Split, MergeStack,
MergeHand, PlaceHand, MoveStack, CompleteTurn, Undo. The
post-state is derived by applying the event to the prior
state; events are diffless.

Stacks are referenced by their **full ordered card list**
(`cards`, `source_cards`, `target_cards`), not by positional
index. Cards are globally unique in the double deck, so a card
list identifies a stack unambiguously AND stays stable under
the reducer's reordering.

Type-only module — encoder/decoder live in
`Game.WireAction` (which imports the type from here).

-}

import Game.BoardActions exposing (Side)
import Game.Rules.Card exposing (Card)
import Game.CardStack exposing (BoardLocation, CardStack)


type GameEvent
    = Split { stack : CardStack, cardIndex : Int }
    | MergeStack { source : CardStack, target : CardStack, side : Side }
    | MergeHand { handCard : Card, target : CardStack, side : Side }
    | PlaceHand { handCard : Card, loc : BoardLocation }
    | MoveStack { stack : CardStack, newLoc : BoardLocation }
    | CompleteTurn
    | Undo
