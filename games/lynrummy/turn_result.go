// CompleteTurnResult classifies how a turn ended. Mirrors
// angry-cat/src/lyn_rummy/game/player_turn.ts.
//
// Dirty-board submissions are rejected at the action-handler gate
// before ClassifyTurnResult runs, so FAILURE is exposed for wire
// symmetry only — the server never classifies a call as FAILURE.

package lynrummy

type CompleteTurnResult string

const (
	TurnResultSuccess               CompleteTurnResult = "success"
	TurnResultSuccessButNeedsCards  CompleteTurnResult = "success_but_needs_cards"
	TurnResultSuccessAsVictor       CompleteTurnResult = "success_as_victor"
	TurnResultSuccessWithHandEmpty  CompleteTurnResult = "success_with_hand_emptied"
	TurnResultFailure               CompleteTurnResult = "failure"
)

// ClassifyTurnResult decides which variant of success a clean-board
// CompleteTurn yields. Callers pass the state as it exists AT the
// CompleteTurn moment (i.e., after replaying all prior actions
// including the last mid-turn move, but before the CompleteTurn
// itself is applied).
//
// hasPriorVictor = true iff some earlier CompleteTurn in this
// session already awarded victor status. Only the first empty-hand
// CompleteTurn wins victor; later ones are SUCCESS_WITH_HAND_EMPTIED.
func ClassifyTurnResult(state State, hasPriorVictor bool) CompleteTurnResult {
	if state.CardsPlayedThisTurn == 0 {
		return TurnResultSuccessButNeedsCards
	}
	if state.ActiveHand().IsEmpty() {
		if !hasPriorVictor {
			return TurnResultSuccessAsVictor
		}
		return TurnResultSuccessWithHandEmpty
	}
	return TurnResultSuccess
}
