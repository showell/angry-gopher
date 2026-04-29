module Game.PlayerTurn exposing
    ( CompleteTurnResult(..)
    , PlayerTurn
    , wasHandEmptied
    , getNumCardsPlayed
    , getScore
    , wasVictoryBonusGained
    , new
    , revokeEmptyHandBonuses
    , turnResult
    , undoScoreAfterMove
    , updateScoreAfterMove
    , updateScoreForEmptyHand
    )

{-| Turn-level scoring and outcome-type tracking for LynRummy.
Faithful port of `angry-cat/src/lyn_rummy/game/player_turn.ts`.

The record holds per-turn state: starting board score, cards
played this turn, empty-hand bonus, victory bonus. Its
functions compute the final turn score and outcome category.

Intentional Elm divergences:

  - TS class → Elm record + module functions.
  - Mutating methods → functions returning new records.
  - Argument order: record comes last where multiple args are
    present, so callers can pipe (`turn |> getScore 100`).

-}

import Game.Score as Score


{-| Outcome of a completed turn. `Failure` is reserved for
callers that want to signal a refused turn; `turnResult`
itself never returns it.
-}
type CompleteTurnResult
    = Success
    | SuccessButNeedsCards
    | SuccessWithHandEmptied
    | SuccessAsVictor
    | Failure


{-| Per-turn scoring state. Start with `new`; update via the
`updateScore*` functions; read via `getScore` /
`turnResult`.
-}
type alias PlayerTurn =
    { startingBoardScore : Int
    , cardsPlayedDuringTurn : Int
    , emptyHandBonus : Int
    , victoryBonus : Int
    }


new : Int -> PlayerTurn
new startingBoardScore =
    { startingBoardScore = startingBoardScore
    , cardsPlayedDuringTurn = 0
    , emptyHandBonus = 0
    , victoryBonus = 0
    }


getScore : Int -> PlayerTurn -> Int
getScore currentBoardScore t =
    let
        boardScore =
            currentBoardScore - t.startingBoardScore

        cardsScore =
            Score.forCardsPlayed t.cardsPlayedDuringTurn
    in
    boardScore + cardsScore + t.victoryBonus + t.emptyHandBonus


getNumCardsPlayed : PlayerTurn -> Int
getNumCardsPlayed t =
    t.cardsPlayedDuringTurn


wasHandEmptied : PlayerTurn -> Bool
wasHandEmptied t =
    t.emptyHandBonus > 0


wasVictoryBonusGained : PlayerTurn -> Bool
wasVictoryBonusGained t =
    t.victoryBonus > 0


{-| Called exactly once per card released to the board during
this turn.
-}
updateScoreAfterMove : PlayerTurn -> PlayerTurn
updateScoreAfterMove t =
    { t | cardsPlayedDuringTurn = t.cardsPlayedDuringTurn + 1 }


undoScoreAfterMove : PlayerTurn -> PlayerTurn
undoScoreAfterMove t =
    { t | cardsPlayedDuringTurn = t.cardsPlayedDuringTurn - 1 }


{-| Zero out the empty-hand and victory bonuses. Called when
the referee disallows an empty-hand state (e.g., illegal
final board).
-}
revokeEmptyHandBonuses : PlayerTurn -> PlayerTurn
revokeEmptyHandBonuses t =
    { t | emptyHandBonus = 0, victoryBonus = 0 }


{-| Record that the player emptied their hand. If `isVictor`,
also grant the victory bonus on top.
-}
updateScoreForEmptyHand : Bool -> PlayerTurn -> PlayerTurn
updateScoreForEmptyHand isVictor t =
    { t
        | emptyHandBonus = 1000
        , victoryBonus =
            if isVictor then
                500

            else
                0
    }


turnResult : PlayerTurn -> CompleteTurnResult
turnResult t =
    if getNumCardsPlayed t == 0 then
        SuccessButNeedsCards

    else if wasHandEmptied t then
        if wasVictoryBonusGained t then
            SuccessAsVictor

        else
            SuccessWithHandEmptied

    else
        Success
