// Tests for ApplyAction. Mirrors
// elm-port-docs/tests/LynRummy/ReplayTest.elm — one transition
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
	if got, want := after.Hand.Size(), before.Hand.Size()-1; got != want {
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
	if got, want := after.Hand.Size(), before.Hand.Size()-1; got != want {
		t.Errorf("hand size: got %d, want %d", got, want)
	}
	if got, want := len(after.Board), len(before.Board); got != want {
		t.Errorf("board length: got %d, want %d", got, want)
	}
}

func TestReplay_TurnActions_Draw(t *testing.T) {
	before := InitialState()
	after := ApplyAction(DrawAction{}, before)
	if got, want := after.Hand.Size(), before.Hand.Size()+1; got != want {
		t.Errorf("hand size after draw: got %d, want %d", got, want)
	}
	if got, want := len(after.Deck), len(before.Deck)-1; got != want {
		t.Errorf("deck size after draw: got %d, want %d", got, want)
	}
	newest := after.Hand.HandCards[len(after.Hand.HandCards)-1]
	if newest.State != FreshlyDrawn {
		t.Errorf("drawn card state: got %v, want FreshlyDrawn", newest.State)
	}
}

func TestReplay_TurnActions_DrawEmptyDeckIsNoOp(t *testing.T) {
	state := InitialState()
	state.Deck = nil
	after := ApplyAction(DrawAction{}, state)
	if after.Hand.Size() != state.Hand.Size() {
		t.Error("draw on empty deck should not change hand")
	}
}

func TestReplay_TurnActions_Discard(t *testing.T) {
	before := InitialState()
	c7H := Card{Value: 7, Suit: Heart, OriginDeck: 1}
	after := ApplyAction(DiscardAction{HandCard: c7H}, before)
	if got, want := after.Hand.Size(), before.Hand.Size()-1; got != want {
		t.Errorf("hand size after discard: got %d, want %d", got, want)
	}
	if len(after.Discard) != 1 || after.Discard[0] != c7H {
		t.Errorf("discard pile: got %v, want [7H]", after.Discard)
	}
}

func TestReplay_TurnActions_CompleteTurn(t *testing.T) {
	state := InitialState()
	state = ApplyAction(DrawAction{}, state)
	state = ApplyAction(CompleteTurnAction{}, state)
	for i, hc := range state.Hand.HandCards {
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

func TestReplay_TurnActions_UndoIsNoOp(t *testing.T) {
	before := InitialState()
	after := ApplyAction(UndoAction{}, before)
	if after.Hand.Size() != before.Hand.Size() {
		t.Error("undo should be a no-op for now")
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
	// Hand has 15. So deck = 104 - 23 - 15 = 66.
	if got, want := len(state.Deck), 66; got != want {
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
		if after.Hand.Size() != before.Hand.Size() {
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
	if got := state.Hand.Size(); got != 15 {
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
	if got.Hand.Size() != manual.Hand.Size() {
		t.Errorf("hand diverges: %d vs %d", got.Hand.Size(), manual.Hand.Size())
	}
}
