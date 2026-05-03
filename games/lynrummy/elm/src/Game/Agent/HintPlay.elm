module Game.Agent.HintPlay exposing (HintResult, findPlay, formatHint)

{-| Hint-for-hand: find the easiest play for the human given
their current hand and the board.

Search order (mirrors `agent_prelude.find_play` in Python):

  (a) Triple in hand — three hand cards that already form a
      complete legal group. Zero BFS steps; best possible result.
      Returns as soon as the first triple is found.

  (b) Singleton-via-BFS — project each hand card as a singleton
      trouble onto the board, run BFS, collect all candidates that
      yield a plan, return the one with the fewest steps.

Pair-via-BFS (step b in the Python version) is not yet ported.
The Elm BFS is now on life-support — the canonical browser engine
going forward is the TypeScript port at `games/lynrummy/ts/`.

-}

import Game.Agent.Bfs as Bfs exposing (Plan)
import Game.Agent.Move as Move
import Game.CardStack exposing (CardStack, HandCard, fromHandCard)
import Game.Rules.Card exposing (Card)
import Game.Rules.StackType as StackType


type alias HintResult =
    { placements : List Card
    , plan : Plan
    }


{-| Find the easiest play for the human. Checks for a triple-in-hand
first (no BFS needed), then falls back to singleton BFS.
-}
findPlay : List HandCard -> List CardStack -> Maybe HintResult
findPlay handCards board =
    case findTripleInHand handCards of
        Just triple ->
            Just { placements = triple, plan = [] }

        Nothing ->
            findBestSingleton handCards board


{-| Check every pair of hand cards for a completing third — all three
from hand, forming a legal group. Returns the ordered triple if found,
Nothing otherwise.
-}
findTripleInHand : List HandCard -> Maybe (List Card)
findTripleInHand handCards =
    let
        cards =
            List.map .card handCards
    in
    findTripleFromPairs cards cards


findTripleFromPairs : List Card -> List Card -> Maybe (List Card)
findTripleFromPairs allCards remaining =
    case remaining of
        [] ->
            Nothing

        c1 :: rest ->
            case findCompletingPair c1 rest allCards of
                Just triple ->
                    Just triple

                Nothing ->
                    findTripleFromPairs allCards rest


findCompletingPair : Card -> List Card -> List Card -> Maybe (List Card)
findCompletingPair c1 remaining allCards =
    case remaining of
        [] ->
            Nothing

        c2 :: rest ->
            if not (StackType.isPartialOk [ c1, c2 ]) then
                findCompletingPair c1 rest allCards

            else
                case findThird c1 c2 allCards of
                    Just triple ->
                        Just triple

                    Nothing ->
                        findCompletingPair c1 rest allCards


{-| Given a valid pair (c1, c2), look for a third hand card that
completes a legal group in some ordering.
-}
findThird : Card -> Card -> List Card -> Maybe (List Card)
findThird c1 c2 allCards =
    let
        isDistinct c =
            c /= c1 && c /= c2

        tryThird c3 =
            List.filter StackType.isLegalStack
                [ [ c1, c2, c3 ]
                , [ c1, c3, c2 ]
                , [ c3, c1, c2 ]
                ]
                |> List.head
    in
    allCards
        |> List.filter isDistinct
        |> List.filterMap tryThird
        |> List.head


{-| Singleton BFS fallback: project each hand card as a singleton
trouble, collect all candidates with a plan, return the shortest.
-}
findBestSingleton : List HandCard -> List CardStack -> Maybe HintResult
findBestSingleton handCards board =
    let
        tryCard hc =
            let
                projected =
                    board ++ [ fromHandCard hc { top = 0, left = 0 } ]
            in
            case Bfs.solveBoard projected of
                Just plan ->
                    Just { placements = [ hc.card ], plan = plan }

                Nothing ->
                    Nothing

        candidates =
            List.filterMap tryCard handCards
    in
    candidates
        |> List.sortBy (\r -> List.length r.plan)
        |> List.head


{-| Render a `Maybe HintResult` as a `List String`.

  - `Nothing` → `[]`
  - `Just { placements, plan }`:
      - Step 0: `"place [JD:1 QD:1] from hand"`
      - Steps 1..n: one line per BFS move via `Move.describe`

-}
formatHint : Maybe HintResult -> List String
formatHint maybeResult =
    case maybeResult of
        Nothing ->
            []

        Just { placements, plan } ->
            let
                placementStep =
                    "place ["
                        ++ (List.map Move.cardLabel placements |> String.join " ")
                        ++ "] from hand"

                planSteps =
                    List.map Move.describe plan
            in
            placementStep :: planSteps
