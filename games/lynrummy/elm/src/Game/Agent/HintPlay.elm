module Game.Agent.HintPlay exposing (HintResult, findPlay, formatHint)

{-| Hint-for-hand: project each hand card as a singleton onto
the board, run BFS, and return the candidate with the shortest
plan — i.e. the easiest play for the human.

Singleton-only MVP — no pair projection logic yet.

See `Game/Strategy/ELM_HINTS.md` for the full integration
strategy and the Python counterpart in `agent_prelude.find_play`.
-}

import Game.Agent.Bfs as Bfs exposing (Plan)
import Game.Agent.Move as Move
import Game.CardStack exposing (CardStack, HandCard, fromHandCard)
import Game.Rules.Card exposing (Card)


type alias HintResult =
    { placements : List Card
    , plan : Plan
    }


{-| For each hand card, build a projected board and run BFS.
Collect all candidates that have a plan, then return the one
with the fewest steps — the easiest play for the human.
Returns `Nothing` if no hand card yields a solvable board.
-}
findPlay : List HandCard -> List CardStack -> Maybe HintResult
findPlay handCards board =
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
