// Tests for ApplyAction. Mirrors
// elm/tests/Game/ReducerTest.elm — one transition
// test per action type, no-op checks for turn-logic actions,
// silent-pass-through on bad references, and a sequenced-actions
// end-to-end.

package lynrummy

import (
	"testing"
)

// stackAt returns the CardStack at state.Board[idx]. The wire
// identifies stacks by their full CardStack (cards + loc);
// tests extract a known stack and pass it as the action's
// reference.
func stackAt(state State, idx int) CardStack {
	return state.Board[idx]
}

func TestReplay_SplitAppliesToBoard(t *testing.T) {
	before := InitialState()
	after := ApplyAction(SplitAction{Stack: stackAt(before, 0), CardIndex: 2}, before)
	if got, want := len(after.Board), len(before.Board)+1; got != want {
		t.Errorf("board length: got %d, want %d", got, want)
	}
}

func TestReplay_MoveStackUpdatesLoc(t *testing.T) {
	before := InitialState()
	newLoc := Location{Top: 300, Left: 400}
	after := ApplyAction(MoveStackAction{Stack: stackAt(before, 0), NewLoc: newLoc}, before)
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
		MergeHandAction{HandCard: card7H, Target: stackAt(before, 3), Side: RightSide},
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
	initial := InitialState()
	log := []WireAction{
		SplitAction{Stack: stackAt(initial, 0), CardIndex: 2},
		UndoAction{},
	}
	eff := EffectiveActions(log)
	if len(eff) != 0 {
		t.Errorf("after split+undo: expected 0 effective actions, got %d", len(eff))
	}
}

func TestReplay_EffectiveActions_MultipleUndos(t *testing.T) {
	initial := InitialState()
	log := []WireAction{
		SplitAction{Stack: stackAt(initial, 0), CardIndex: 2},
		MoveStackAction{Stack: stackAt(initial, 0), NewLoc: Location{Top: 1, Left: 1}},
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
	before := InitialState()
	log := []WireAction{
		SplitAction{Stack: stackAt(before, 0), CardIndex: 2},
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
	initial := InitialState()
	log := []WireAction{
		SplitAction{Stack: stackAt(initial, 0), CardIndex: 2},
		UndoAction{},
		SplitAction{Stack: stackAt(initial, 1), CardIndex: 2},
	}
	after := ReplayActions(log)
	if len(after.Board) != len(initial.Board)+1 {
		t.Errorf("board length: got %d, want %d", len(after.Board), len(initial.Board)+1)
	}
}

func TestReplay_Undo_PastCompleteTurn(t *testing.T) {
	initial := InitialState()
	log := []WireAction{
		SplitAction{Stack: stackAt(initial, 0), CardIndex: 2},
		CompleteTurnAction{},
		UndoAction{},
	}
	after := ReplayActions(log)
	if after.TurnIndex != 0 {
		t.Errorf("TurnIndex after split+complete+undo: got %d, want 0", after.TurnIndex)
	}
	if len(after.Board) != len(initial.Board)+1 {
		t.Errorf("board length: got %d, want %d (split stands, undo only popped complete_turn)",
			len(after.Board), len(initial.Board)+1)
	}
}

func TestReplay_CardsPlayedThisTurn_Bump(t *testing.T) {
	state := InitialState()
	c7H := Card{Value: 7, Suit: Heart, OriginDeck: 1}
	state = ApplyAction(
		MergeHandAction{HandCard: c7H, Target: stackAt(state, 3), Side: RightSide},
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

	t.Run("split on ghost stack", func(t *testing.T) {
		ghost := CardStack{
			BoardCards: []BoardCard{{Card: Card{Value: 99, Suit: Heart, OriginDeck: 0}}},
			Loc:        Location{Top: 9999, Left: 9999},
		}
		after := ApplyAction(SplitAction{Stack: ghost, CardIndex: 0}, before)
		if len(after.Board) != len(before.Board) {
			t.Error("board should be unchanged")
		}
	})

	t.Run("move_stack on ghost stack", func(t *testing.T) {
		ghost := CardStack{
			BoardCards: []BoardCard{{Card: Card{Value: 99, Suit: Heart, OriginDeck: 0}}},
			Loc:        Location{Top: 9999, Left: 9999},
		}
		after := ApplyAction(
			MoveStackAction{Stack: ghost, NewLoc: Location{Top: 10, Left: 10}},
			before,
		)
		if len(after.Board) != len(before.Board) {
			t.Error("board should be unchanged")
		}
	})

	t.Run("merge_hand with card not in hand", func(t *testing.T) {
		notInHand := Card{Value: 1, Suit: Spade, OriginDeck: 0}
		after := ApplyAction(
			MergeHandAction{HandCard: notInHand, Target: stackAt(before, 3), Side: RightSide},
			before,
		)
		if after.ActiveHand().Size() != before.ActiveHand().Size() {
			t.Error("hand should be unchanged")
		}
		if len(after.Board) != len(before.Board) {
			t.Error("board should be unchanged")
		}
	})

	t.Run("merge_stack with mismatched target surfaces divergence", func(t *testing.T) {
		// Corrupt the target's loc — cards still match the 7-set
		// but the client's view of WHERE it sits is stale. The
		// reducer's CardStack.Equals compares loc too, so the
		// action no-ops. Divergence check working.
		stale := stackAt(before, 3)
		stale.Loc = Location{Top: 0, Left: 0}
		after := ApplyAction(
			MergeStackAction{
				Source: stackAt(before, 0),
				Target: stale,
				Side:   RightSide,
			},
			before,
		)
		if len(after.Board) != len(before.Board) {
			t.Error("board should be unchanged on mismatched target loc")
		}
	})

	t.Run("merge_stack: cards in swapped order still match (multiset equality)", func(t *testing.T) {
		// Reverse the 7-set's card order. Same multiset, same loc,
		// so the reducer treats it as the same stack and the merge
		// proceeds.
		reordered := stackAt(before, 3)
		cards := append([]BoardCard{}, reordered.BoardCards...)
		for i, j := 0, len(cards)-1; i < j; i, j = i+1, j-1 {
			cards[i], cards[j] = cards[j], cards[i]
		}
		reordered.BoardCards = cards
		after := ApplyAction(
			MergeStackAction{
				Source: stackAt(before, 0),
				Target: reordered,
				Side:   RightSide,
			},
			before,
		)
		// A merge that's geometrically invalid will still no-op,
		// but the important check here is that FindStack LOCATED
		// the target despite the reordering. So what we assert:
		// either the merge succeeded (board shrank by 1) or was
		// rejected by the merge-legality check (board unchanged).
		// The test fails only if FindStack returned nil and the
		// action silently didn't try — but that's indistinguishable
		// from a rejected merge at this layer. Instead, verify
		// FindStack directly:
		if FindStack(before.Board, reordered) == nil {
			t.Error("FindStack should match a reordered stack by multiset")
		}
		_ = after
	})
}

func TestReplay_SequenceEndToEnd(t *testing.T) {
	start := InitialState()
	step1 := ApplyAction(SplitAction{Stack: stackAt(start, 0), CardIndex: 2}, start)
	// step1.Board[0] is one of the split halves.
	step2 := ApplyAction(
		MoveStackAction{Stack: stackAt(step1, 0), NewLoc: Location{Top: 500, Left: 400}},
		step1,
	)

	if got, want := len(step2.Board), len(start.Board)+1; got != want {
		t.Errorf("final board length: got %d, want %d", got, want)
	}
}
