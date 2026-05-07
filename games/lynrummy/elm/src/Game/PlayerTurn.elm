module Game.PlayerTurn exposing
    ( CompleteTurnResult(..)
    , PlayerTurn
    , getNumCardsPlayed
    , new
    , noteCardPlayed
    , noteEmptyHand
    , revokeEmptyHandBonuses
    , turnResult
    , undoCardPlayed
    , wasHandEmptied
    , wasVictoryBonusGained
    )

{-| Turn-level outcome tracking for LynRummy. Records whether
the player played any cards, whether they emptied their hand,
and whether they got the victor award. Drives the
`turnResult` discriminator that picks success category.

Ported from `angry-cat/src/lyn_rummy/game/player_turn.ts`,
trimmed to drop the score-tracking machinery (the kitchen-
table game has no scoring; the bonuses here used to be Int
values, now plain Bool flags).

-}


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


{-| Per-turn tracking state. Start with `new`; update via the
mutators; read via `turnResult` / the `wasX` accessors.
-}
type alias PlayerTurn =
    { cardsPlayedDuringTurn : Int
    , handEmptied : Bool
    , victoryGained : Bool
    }


new : PlayerTurn
new =
    { cardsPlayedDuringTurn = 0
    , handEmptied = False
    , victoryGained = False
    }


getNumCardsPlayed : PlayerTurn -> Int
getNumCardsPlayed t =
    t.cardsPlayedDuringTurn


wasHandEmptied : PlayerTurn -> Bool
wasHandEmptied t =
    t.handEmptied


wasVictoryBonusGained : PlayerTurn -> Bool
wasVictoryBonusGained t =
    t.victoryGained


{-| Called exactly once per card released to the board during
this turn.
-}
noteCardPlayed : PlayerTurn -> PlayerTurn
noteCardPlayed t =
    { t | cardsPlayedDuringTurn = t.cardsPlayedDuringTurn + 1 }


undoCardPlayed : PlayerTurn -> PlayerTurn
undoCardPlayed t =
    { t | cardsPlayedDuringTurn = t.cardsPlayedDuringTurn - 1 }


{-| Clear the empty-hand and victory flags. Called when the
referee disallows an empty-hand state (e.g., illegal final
board).
-}
revokeEmptyHandBonuses : PlayerTurn -> PlayerTurn
revokeEmptyHandBonuses t =
    { t | handEmptied = False, victoryGained = False }


{-| Record that the player emptied their hand. If `isVictor`,
also flag the victory bonus.
-}
noteEmptyHand : Bool -> PlayerTurn -> PlayerTurn
noteEmptyHand isVictor t =
    { t | handEmptied = True, victoryGained = isVictor }


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
