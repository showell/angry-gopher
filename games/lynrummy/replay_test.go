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
	card7H := Card{Value: 7, Suit: Heart, OriginDeck: 0}
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
	card7H := Card{Value: 7, Suit: Heart, OriginDeck: 0}
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

func TestReplay_TurnLogicActionsAreNoOps(t *testing.T) {
	before := InitialState()
	cases := []struct {
		name   string
		action WireAction
	}{
		{"draw", DrawAction{}},
		{"discard", DiscardAction{HandCard: Card{Value: 7, Suit: Heart, OriginDeck: 0}}},
		{"complete_turn", CompleteTurnAction{}},
		{"undo", UndoAction{}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			after := ApplyAction(tc.action, before)
			if got := len(after.Board); got != len(before.Board) {
				t.Errorf("board changed: got %d stacks, want %d", got, len(before.Board))
			}
			if got := after.Hand.Size(); got != before.Hand.Size() {
				t.Errorf("hand changed: got %d cards, want %d", got, before.Hand.Size())
			}
		})
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
