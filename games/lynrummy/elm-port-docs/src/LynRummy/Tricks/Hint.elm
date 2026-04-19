module LynRummy.Tricks.Hint exposing
    ( Suggestion
    , buildSuggestions
    , hintPriorityOrder
    )

{-| Hint orchestration. Walks the seven tricks in a fixed
priority order and, for each trick that fires, emits a single
representative `Suggestion` — the first play the trick found.
Returns the list in priority order.

Faithful port of `games/lynrummy/tricks/hint.go` `BuildSuggestions`.
Both sides accept the same input (a hand + a board) and produce
the same shape of output — there is no server-privileged input
this layer needs, so client and server are solving the same
problem in isolation.

Priority order is a ranking criterion, not a score metric —
simpler / more visually obvious tricks come first. Clients
typically pick `suggestions[0]`; strategic agents can inspect
deeper.

-}

import LynRummy.Card exposing (Card)
import LynRummy.CardStack exposing (CardStack, HandCard)
import LynRummy.Hand exposing (Hand)
import LynRummy.Tricks.DirectPlay as DirectPlay
import LynRummy.Tricks.HandStacks as HandStacks
import LynRummy.Tricks.LooseCardPlay as LooseCardPlay
import LynRummy.Tricks.PairPeel as PairPeel
import LynRummy.Tricks.PeelForRun as PeelForRun
import LynRummy.Tricks.RbSwap as RbSwap
import LynRummy.Tricks.SplitForSet as SplitForSet
import LynRummy.Tricks.Trick exposing (Trick)


{-| One actionable hint. `rank` is the trick's position in the
priority order (1-indexed). `trickId` identifies the producer.
`description` is the trick's human-readable one-liner.
`handCards` are the cards the play would consume — clients
highlight these to guide the player.
-}
type alias Suggestion =
    { rank : Int
    , trickId : String
    , description : String
    , handCards : List Card
    }


{-| The seven tricks, in priority order. Simplest / most
visually obvious first; complex multi-step tricks last.
Matches Go's `HintPriorityOrder` verbatim.
-}
hintPriorityOrder : List Trick
hintPriorityOrder =
    [ DirectPlay.trick
    , HandStacks.trick
    , PairPeel.trick
    , SplitForSet.trick
    , PeelForRun.trick
    , RbSwap.trick
    , LooseCardPlay.trick
    ]


{-| For each firing trick, take the first Play and emit a
Suggestion. Non-firing tricks are skipped. Preserves priority
order in the output.
-}
buildSuggestions : Hand -> List CardStack -> List Suggestion
buildSuggestions hand board =
    hintPriorityOrder
        |> List.indexedMap Tuple.pair
        |> List.filterMap (firstPlayAsSuggestion hand.handCards board)


firstPlayAsSuggestion : List HandCard -> List CardStack -> ( Int, Trick ) -> Maybe Suggestion
firstPlayAsSuggestion handCards board ( i, trick ) =
    case trick.findPlays handCards board of
        [] ->
            Nothing

        first :: _ ->
            Just
                { rank = i + 1
                , trickId = trick.id
                , description = trick.description
                , handCards = List.map .card first.handCards
                }
