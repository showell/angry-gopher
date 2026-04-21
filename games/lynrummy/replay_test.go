// Tests for ApplyAction. Mirrors
// elm/tests/LynRummy/ReducerTest.elm — one transition
// test per action type, no-op checks for turn-logic actions,
// silent-pass-through on bad references, and a sequenced-actions
// end-to-end.

package lynrummy

import (
	"testing"
)

func TestReplay_SplitAppliesToBoard(t *testing.T) {
	before := InitialState()
	after := ApplyAction(SplitAction{StackIndex: 0, CardIndex: 2}, before)
	if got, want := len(after.Board), len(before.Board)+1; got != want {
		t.Errorf("board length: got %d, want %d", got, want)
	}
}

func TestReplay_MoveStackUpdatesLoc(t *testing.T) {
	newLoc := Location{Top: 300, Left: 400}
	after := ApplyAction(MoveStackAction{StackIndex: 0, NewLoc: newLoc}, InitialState())
	// Moved stack lands at the end of the board slice (removeStack
	// + append pattern). Verify its loc.
	last := after.Board[len(after.Board)-1]
	if last.Loc != newLoc {
		t.Errorf("moved stack loc: got %+v, want %+v", last.Loc, newLoc)
	}
}

func TestReplay_PlaceHandAddsToBoardRemovesFromHand(t *testing.T) {
	before := InitialState()
	card7H := Card{Value: 7, Suit: Heart, OriginDeck: 1}
	after := ApplyAction(
		PlaceHandAction{HandCard: card7H, Loc: Location{Top: 400, Left: 500}},
		before,
	)
	if got, want := after.ActiveHand().Size(), before.ActiveHand().Size()-1; got != want {
		t.Errorf("hand size: got %d, want %d", got, want)
	}
	if got, want := len(after.Board), len(before.Board)+1; got != want {
		t.Errorf("board length: got %d, want %d", got, want)
	}
}

func TestReplay_MergeHand7HOnto7Set(t *testing.T) {
	// Opening board stack at index 3 is "7S,7D,7C" — a 7-set.
	// Adding 7H from the hand (right side) makes it a 4-set.
	before := InitialState()
	card7H := Card{Value: 7, Suit: Heart, OriginDeck: 1}
	after := ApplyAction(
		MergeHandAction{HandCard: card7H, TargetStack: 3, Side: RightSide},
		before,
	)
	if got, want := after.ActiveHand().Size(), before.ActiveHand().Size()-1; got != want {
		t.Errorf("hand size: got %d, want %d", got, want)
	}
	if got, want := len(after.Board), len(before.Board); got != want {
		t.Errorf("board length: got %d, want %d", got, want)
	}
}

func TestReplay_TurnActions_CompleteTurn(t *testing.T) {
	state := InitialState()
	state = ApplyAction(CompleteTurnAction{}, state)
	for i, hc := range state.ActiveHand().HandCards {
		if hc.State != HandNormal {
			t.Errorf("hand[%d] state after complete_turn: got %v, want HandNormal", i, hc.State)
		}
	}
	if state.TurnIndex != 1 {
		t.Errorf("turn_index: got %d, want 1", state.TurnIndex)
	}
	if state.CardsPlayedThisTurn != 0 {
		t.Errorf("cards_played_this_turn: got %d, want 0", state.CardsPlayedThisTurn)
	}
}

func TestReplay_EffectiveActions_UndoPopsLast(t *testing.T) {
	log := []WireAction{
		SplitAction{StackIndex: 0, CardIndex: 2},
		UndoAction{},
	}
	eff := EffectiveActions(log)
	if len(eff) != 0 {
		t.Errorf("after split+undo: expected 0 effective actions, got %d", len(eff))
	}
}

func TestReplay_EffectiveActions_MultipleUndos(t *testing.T) {
	log := []WireAction{
		SplitAction{StackIndex: 0, CardIndex: 2},
		MoveStackAction{StackIndex: 0, NewLoc: Location{Top: 1, Left: 1}},
		UndoAction{},
		UndoAction{},
	}
	eff := EffectiveActions(log)
	if len(eff) != 0 {
		t.Errorf("after 2 ops + 2 undos: expected 0 effective actions, got %d", len(eff))
	}
}

func TestReplay_EffectiveActions_UndoOnEmptyHistoryIsNoOp(t *testing.T) {
	log := []WireAction{UndoAction{}, UndoAction{}}
	eff := EffectiveActions(log)
	if len(eff) != 0 {
		t.Errorf("undo on empty history: expected 0, got %d", len(eff))
	}
}

func TestReplay_Undo_RevertsStateToBefore(t *testing.T) {
	// Full-round-trip: do an action, undo it, state matches
	// initial.
	before := InitialState()
	log := []WireAction{
		SplitAction{StackIndex: 0, CardIndex: 2},
		UndoAction{},
	}
	after := ReplayActions(log)
	if len(after.Board) != len(before.Board) {
		t.Errorf("board length mismatch after undo: got %d, want %d",
			len(after.Board), len(before.Board))
	}
	if after.ActiveHand().Size() != before.ActiveHand().Size() {
		t.Errorf("hand size mismatch after undo")
	}
}

func TestReplay_Undo_ThenDifferentAction(t *testing.T) {
	// Split, undo, then do a different split. Final state
	// reflects only the second split.
	log := []WireAction{
		SplitAction{StackIndex: 0, CardIndex: 2},
		UndoAction{},
		SplitAction{StackIndex: 1, CardIndex: 2},
	}
	after := ReplayActions(log)
	// One split → board grew by 1.
	initial := InitialState()
	if len(after.Board) != len(initial.Board)+1 {
		t.Errorf("board length: got %d, want %d", len(after.Board), len(initial.Board)+1)
	}
}

func TestReplay_Undo_PastCompleteTurn(t *testing.T) {
	// Undo CAN cross a CompleteTurn boundary in V1. If Steve
	// decides the Elm client should block undoing past
	// CompleteTurn, that's a validation layer we'd add here.
	log := []WireAction{
		SplitAction{StackIndex: 0, CardIndex: 2},
		CompleteTurnAction{},
		UndoAction{},
	}
	after := ReplayActions(log)
	if after.TurnIndex != 0 {
		t.Errorf("TurnIndex after split+complete+undo: got %d, want 0", after.TurnIndex)
	}
	// The split still stands; only the complete_turn was undone.
	initial := InitialState()
	if len(after.Board) != len(initial.Board)+1 {
		t.Errorf("board length: got %d, want %d (split stands, undo only popped complete_turn)",
			len(after.Board), len(initial.Board)+1)
	}
}

func TestReplay_CardsPlayedThisTurn_Bump(t *testing.T) {
	state := InitialState()
	c7H := Card{Value: 7, Suit: Heart, OriginDeck: 1}
	state = ApplyAction(
		MergeHandAction{HandCard: c7H, TargetStack: 3, Side: RightSide},
		state,
	)
	if state.CardsPlayedThisTurn != 1 {
		t.Errorf("after 1 merge_hand: got %d, want 1", state.CardsPlayedThisTurn)
	}
	c8C := Card{Value: 8, Suit: Club, OriginDeck: 1}
	state = ApplyAction(
		PlaceHandAction{HandCard: c8C, Loc: Location{Top: 400, Left: 500}},
		state,
	)
	if state.CardsPlayedThisTurn != 2 {
		t.Errorf("after merge+place: got %d, want 2", state.CardsPlayedThisTurn)
	}
}

func TestReplay_InitialDeckHasRemainingCards(t *testing.T) {
	state := InitialState()
	// Double deck = 104. Initial board has 4+4+3+3+3+6=23 cards.
	// Two hands of 15 each. So deck = 104 - 23 - 30 = 51.
	if got, want := len(state.Deck), 51; got != want {
		t.Errorf("initial deck size: got %d, want %d", got, want)
	}
}

func TestReplay_BadReferencesAreNoOps(t *testing.T) {
	before := InitialState()

	t.Run("split on nonexistent stack index", func(t *testing.T) {
		after := ApplyAction(SplitAction{StackIndex: 99, CardIndex: 0}, before)
		if len(after.Board) != len(before.Board) {
			t.Error("board should be unchanged")
		}
	})

	t.Run("move_stack on nonexistent stack index", func(t *testing.T) {
		after := ApplyAction(
			MoveStackAction{StackIndex: 99, NewLoc: Location{Top: 10, Left: 10}},
			before,
		)
		if len(after.Board) != len(before.Board) {
			t.Error("board should be unchanged")
		}
	})

	t.Run("merge_hand with card not in hand", func(t *testing.T) {
		notInHand := Card{Value: 1, Suit: Spade, OriginDeck: 0}
		after := ApplyAction(
			MergeHandAction{HandCard: notInHand, TargetStack: 3, Side: RightSide},
			before,
		)
		if after.ActiveHand().Size() != before.ActiveHand().Size() {
			t.Error("hand should be unchanged")
		}
		if len(after.Board) != len(before.Board) {
			t.Error("board should be unchanged")
		}
	})
}

func TestReplay_SequenceEndToEnd(t *testing.T) {
	// Sequence: split stack 0, then move stack 0 to a new loc.
	start := InitialState()
	step1 := ApplyAction(SplitAction{StackIndex: 0, CardIndex: 2}, start)
	step2 := ApplyAction(MoveStackAction{StackIndex: 0, NewLoc: Location{Top: 500, Left: 400}}, step1)

	if got, want := len(step2.Board), len(start.Board)+1; got != want {
		t.Errorf("final board length: got %d, want %d", got, want)
	}
}

func TestReplay_InitialStateMatchesExpectedShape(t *testing.T) {
	state := InitialState()
	if got := len(state.Board); got != 6 {
		t.Errorf("initial board: got %d stacks, want 6", got)
	}
	if got := state.ActiveHand().Size(); got != 15 {
		t.Errorf("initial hand: got %d cards, want 15", got)
	}
}

func TestReplay_ReplayActionsIsFoldLeft(t *testing.T) {
	actions := []WireAction{
		SplitAction{StackIndex: 0, CardIndex: 2},
		MoveStackAction{StackIndex: 0, NewLoc: Location{Top: 500, Left: 400}},
	}
	got := ReplayActions(actions)

	// Same end-state whether we use ReplayActions or fold manually.
	manual := InitialState()
	for _, a := range actions {
		manual = ApplyAction(a, manual)
	}

	if len(got.Board) != len(manual.Board) {
		t.Errorf("board diverges: %d vs %d", len(got.Board), len(manual.Board))
	}
	if got.ActiveHand().Size() != manual.ActiveHand().Size() {
		t.Errorf("hand diverges: %d vs %d", got.ActiveHand().Size(), manual.ActiveHand().Size())
	}
}

// TestTwoPlayerTurnChange_ScoresAccumulatePerPlayer walks through
// a minimal two-player exchange and verifies per-player scoring.
//
//   Turn 1 (P0): play QS onto the KS-AS-2S-3S spade run → 5-run.
//   CompleteTurn. P0 gets +400. P1 still 0.
//
//   Turn 2 (P1): play 4S onto the QS-KS-AS-2S-3S run → 6-run.
//   CompleteTurn. P1 gets +400. P0 unchanged.
//
// HARDCODED SCORES ARE INTENTIONAL. This test asserts exact
// integers (400, 400) rather than computing them from board
// deltas. If you change StackTypeValue / ScoreForCardsPlayed,
// this test WILL fail — that's the point: it forces you to
// re-examine per-player scoring whenever you touch the
// arithmetic. Update the numbers here consciously.
//
// Math (for reviewers): each turn is a single 1-card PureRun
// merge. Board delta +100 (PureRun grows by one card at 100
// per card). Cards-played bonus 200 + 100·1² = 300. Total 400.
func TestTwoPlayerTurnChange_ScoresAccumulatePerPlayer(t *testing.T) {
	state := InitialState()

	if state.ActivePlayerIndex != 0 {
		t.Fatalf("expected P0 active initially, got %d", state.ActivePlayerIndex)
	}
	if state.Scores[0] != 0 || state.Scores[1] != 0 {
		t.Fatalf("expected scores [0,0], got %v", state.Scores)
	}
	if got := ScoreForStacks(state.Board); got != 1760 {
		t.Fatalf("initial board score: got %d, want 1760", got)
	}

	// --- Turn 1: P0 merges QS onto the left of the KS-holding stack ---
	qs := Card{Value: 12, Suit: Spade, OriginDeck: 1} // P0 hand, DeckTwo
	ks := Card{Value: 13, Suit: Spade, OriginDeck: 0} // initial board, DeckOne
	state = ApplyAction(MergeHandAction{
		HandCard:    qs,
		TargetStack: stackHolding(state.Board, ks),
		Side:        LeftSide,
	}, state)
	state = ApplyAction(CompleteTurnAction{}, state)

	if got := state.Scores[0]; got != 400 {
		t.Errorf("P0 score after turn 1: got %d, want 400", got)
	}
	if got := state.Scores[1]; got != 0 {
		t.Errorf("P1 score after turn 1: got %d, want 0", got)
	}
	if state.ActivePlayerIndex != 1 {
		t.Errorf("seat after P0's CompleteTurn: got %d, want 1", state.ActivePlayerIndex)
	}

	// --- Turn 2: P1 merges 4S onto the right of the stack now holding QS ---
	fourS := Card{Value: 4, Suit: Spade, OriginDeck: 0} // P1 hand, DeckOne
	state = ApplyAction(MergeHandAction{
		HandCard:    fourS,
		TargetStack: stackHolding(state.Board, qs),
		Side:        RightSide,
	}, state)
	state = ApplyAction(CompleteTurnAction{}, state)

	if got := state.Scores[0]; got != 400 {
		t.Errorf("P0 score after turn 2 (should be unchanged): got %d, want 400", got)
	}
	if got := state.Scores[1]; got != 400 {
		t.Errorf("P1 score after turn 2: got %d, want 400", got)
	}
	if state.ActivePlayerIndex != 0 {
		t.Errorf("seat after P1's CompleteTurn: got %d, want 0", state.ActivePlayerIndex)
	}
}

// stackHolding returns the index of the first stack that contains
// the given card, or -1. Tests use this to reference a stack
// across mutations — merges remove the target stack and append
// the merged result, so raw indexes aren't stable across actions.
func stackHolding(board []CardStack, target Card) int {
	for i, s := range board {
		if s.Contains(target) {
			return i
		}
	}
	return -1
}
