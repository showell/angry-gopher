module Game.Agent.HintPlay exposing (HintResult, findPlay, formatHint)

{-| Hint-for-hand: project each hand card as a singleton onto
the board, run BFS, and return the first card that has a plan.

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


{-| For each hand card (in order), build a projected board:
`board ++ [ fromHandCard hc { top = 0, left = 0 } ]`
and run `Bfs.solveBoard`. Return `Just` for the first card
whose projection yields a plan; `Nothing` if none does.
-}
findPlay : List HandCard -> List CardStack -> Maybe HintResult
findPlay handCards board =
    findFirst handCards board


findFirst : List HandCard -> List CardStack -> Maybe HintResult
findFirst handCards board =
    case handCards of
        [] ->
            Nothing

        hc :: rest ->
            let
                projected =
                    board ++ [ fromHandCard hc { top = 0, left = 0 } ]
            in
            case Bfs.solveBoard projected of
                Just plan ->
                    Just { placements = [ hc.card ], plan = plan }

                Nothing ->
                    findFirst rest board


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
