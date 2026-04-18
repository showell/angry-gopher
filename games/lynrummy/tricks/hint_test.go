// Tests for BuildSuggestions. Each fixture is a named hand +
// board scenario; tests assert the top suggestion's trick_id
// and (where relevant) its hand cards. Hardcoded expected
// values so scoring/priority changes force intentional review.

package tricks_test

import (
	"testing"

	lr "angry-gopher/games/lynrummy"
	"angry-gopher/games/lynrummy/tricks"
)

// Hand-empty → no suggestions (empty slice, not nil-with-content).
func TestBuildSuggestions_EmptyHand_NoSuggestions(t *testing.T) {
	state := lr.InitialState()
	// Replace hand 0 with an empty one.
	state.Hands[state.ActivePlayerIndex] = lr.EmptyHand()

	got := tricks.BuildSuggestions(state.Hands[state.ActivePlayerIndex], state.Board)
	if len(got) != 0 {
		t.Fatalf("empty hand should produce no suggestions, got %d: %+v", len(got), got)
	}
}

// Canned opening hand against the canned initial board:
// `direct_play` is the top suggestion. Verifies that the
// simplest-available trick wins the priority walk.
func TestBuildSuggestions_OpeningHand_DirectPlayFirst(t *testing.T) {
	state := lr.InitialState()
	hand := state.Hands[state.ActivePlayerIndex]

	got := tricks.BuildSuggestions(hand, state.Board)
	if len(got) == 0 {
		t.Fatal("expected at least one suggestion for opening hand")
	}
	top := got[0]

	if top.Rank != 1 {
		t.Errorf("top suggestion rank: got %d, want 1", top.Rank)
	}
	if top.TrickID != "direct_play" {
		t.Errorf("top suggestion trick_id: got %q, want %q", top.TrickID, "direct_play")
	}
	if top.Action.Kind != "merge_hand" {
		t.Errorf("top suggestion action.kind: got %q, want %q", top.Action.Kind, "merge_hand")
	}
	if top.Action.HandCard == nil {
		t.Fatal("top suggestion action.hand_card: got nil, want a Card")
	}
	if top.Action.TargetStack == nil {
		t.Fatal("top suggestion action.target_stack: got nil, want an index")
	}
	if len(top.HandCards) != 1 {
		t.Errorf("top suggestion hand_cards: got %d cards, want 1 (direct_play is one card)", len(top.HandCards))
	}
}

// Contrived hand: no direct_play target exists, but the hand
// contains a pure run. Verifies hand_stacks fires when
// direct_play doesn't, AND that the pure-run candidate wins
// hand_stacks' internal sub-ordering (pure > rb > set).
func TestBuildSuggestions_NoDirectPlay_HandStacksPureRunWins(t *testing.T) {
	// Build a board with no hand-mergeable stacks:
	// one incomplete 2-card stack the hand can't extend.
	board := []lr.CardStack{
		lr.NewCardStack(
			[]lr.BoardCard{
				{Card: lr.Card{Value: 10, Suit: lr.Spade, OriginDeck: 0}, State: lr.FirmlyOnBoard},
				{Card: lr.Card{Value: 11, Suit: lr.Spade, OriginDeck: 0}, State: lr.FirmlyOnBoard},
			},
			lr.Location{Top: 20, Left: 40},
		),
	}

	// Hand: 2H-3H-4H pure run + a couple non-mergeable cards.
	hand := lr.EmptyHand().AddCards(
		[]lr.Card{
			{Value: 2, Suit: lr.Heart, OriginDeck: 0},
			{Value: 3, Suit: lr.Heart, OriginDeck: 0},
			{Value: 4, Suit: lr.Heart, OriginDeck: 0},
			{Value: 7, Suit: lr.Club, OriginDeck: 0}, // orphan
		},
		lr.HandNormal,
	)

	got := tricks.BuildSuggestions(hand, board)
	if len(got) == 0 {
		t.Fatal("expected at least one suggestion")
	}
	top := got[0]

	if top.TrickID != "hand_stacks" {
		t.Errorf("top suggestion trick_id: got %q, want %q", top.TrickID, "hand_stacks")
	}
	if top.Action.Kind != "trick_result" {
		t.Errorf("action.kind: got %q, want %q", top.Action.Kind, "trick_result")
	}
	// Pure run: three hearts, values 2-3-4.
	if len(top.HandCards) != 3 {
		t.Fatalf("hand_cards count: got %d, want 3", len(top.HandCards))
	}
	wantValues := map[int]bool{2: true, 3: true, 4: true}
	for _, c := range top.HandCards {
		if c.Suit != lr.Heart {
			t.Errorf("hand card suit: got %v, want Heart (pure run means same suit)", c.Suit)
		}
		if !wantValues[c.Value] {
			t.Errorf("hand card value: got %d, want one of 2/3/4", c.Value)
		}
	}
}
