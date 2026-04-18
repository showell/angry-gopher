package lynrummy

import "testing"

func TestHints_HandMerges_InitialBoardOpeningHand(t *testing.T) {
	state := InitialState()
	hints := LegalHandMerges(state.Hand, state.Board)
	if len(hints) == 0 {
		t.Fatal("expected some legal hand merges on initial state, got none")
	}

	// 7H from the opening hand should have legal merges against
	// the 7-set (stack 3) on both sides (Left and Right — a set
	// accepts either direction).
	sevenH := Card{Value: 7, Suit: Heart, OriginDeck: 0}
	var sevenHHints []Hint
	for _, h := range hints {
		if h.HandCard != nil && *h.HandCard == sevenH {
			sevenHHints = append(sevenHHints, h)
		}
	}
	if len(sevenHHints) < 2 {
		t.Errorf("7H should have ≥2 hints (both sides of the 7-set); got %d", len(sevenHHints))
	}

	// All 7H hints should target the 7-set at index 3.
	for _, h := range sevenHHints {
		if h.TargetStack != 3 {
			t.Errorf("7H hint targets stack %d, want 3", h.TargetStack)
		}
	}
}

func TestHints_StackMerges_EmptyOnInitialBoard(t *testing.T) {
	// The opening board has six stacks that don't merge with each
	// other — each is its own valid family with no cross-merges.
	// This test pins that; if someone adds a merge-able opening
	// layout, this test will surface it.
	state := InitialState()
	hints := LegalStackMerges(state.Board)
	if len(hints) != 0 {
		t.Errorf("expected 0 stack merges on initial board, got %d", len(hints))
		for _, h := range hints {
			t.Logf("  %+v", h)
		}
	}
}

func TestHints_ResultScoreMakesSense(t *testing.T) {
	state := InitialState()
	baseScore := ScoreForStacks(state.Board)
	hints := LegalHandMerges(state.Hand, state.Board)

	// Merging 7H onto the 7-set adds 60 (one more card in a
	// set, each card worth 60). result_score should be base + 60.
	sevenH := Card{Value: 7, Suit: Heart, OriginDeck: 0}
	for _, h := range hints {
		if h.HandCard != nil && *h.HandCard == sevenH {
			want := baseScore + 60
			if h.ResultScore != want {
				t.Errorf("7H result_score: got %d, want %d", h.ResultScore, want)
			}
			return
		}
	}
	t.Fatal("no 7H hint found")
}
