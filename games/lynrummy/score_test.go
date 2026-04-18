package lynrummy

import "testing"

func TestScore_StackTypeValues(t *testing.T) {
	cases := []struct {
		t    StackType
		want int
	}{
		{PureRun, 100},
		{Set, 60},
		{RedBlackRun, 50},
		{Incomplete, 0},
		{Bogus, 0},
		{Dup, 0},
	}
	for _, tc := range cases {
		t.Run(string(tc.t), func(t *testing.T) {
			if got := StackTypeValue(tc.t); got != tc.want {
				t.Errorf("StackTypeValue(%s): got %d, want %d", tc.t, got, tc.want)
			}
		})
	}
}

func TestScore_ForStacks_InitialBoard(t *testing.T) {
	// Opening board: 6 stacks, all valid (sets and runs). Verify
	// the total is positive and stable.
	board := InitialBoard()
	score := ScoreForStacks(board)
	if score <= 0 {
		t.Errorf("initial board score should be positive, got %d", score)
	}
}

func TestScore_ForCardsPlayed_Formula(t *testing.T) {
	cases := []struct {
		num  int
		want int
	}{
		{0, 0},
		{-1, 0},
		{1, 300},  // 200 + 100*1*1
		{2, 600},  // 200 + 100*4
		{3, 1100}, // 200 + 100*9
		{10, 10200},
	}
	for _, tc := range cases {
		if got := ScoreForCardsPlayed(tc.num); got != tc.want {
			t.Errorf("ScoreForCardsPlayed(%d): got %d, want %d", tc.num, got, tc.want)
		}
	}
}

func TestScore_SplitPreservesTotal(t *testing.T) {
	// Split a 4-card spade run at index 2 → two 2-card runs.
	// (2-card stacks are Incomplete and score zero.) So splitting
	// is only "free" between 3+ card valid stacks.
	// Verify here that scoring a 4-card run, vs scoring its split
	// halves, does differ (this is the known case — the "split is
	// free" claim from the essay applies to valid→valid splits.)
	initial := InitialBoard()
	before := ScoreForStacks(initial)

	// Apply a split that keeps both halves valid: split the
	// 2C,3D,4C,5H,6S,7H 6-run at index 2 → 3-run + 3-run (both
	// valid red/black alternating runs).
	state := ApplyAction(SplitAction{StackIndex: 5, CardIndex: 2}, State{Board: initial, Hands: []Hand{EmptyHand(), EmptyHand()}})
	after := ScoreForStacks(state.Board)

	if before != after {
		t.Errorf("split of 6-run at midpoint should preserve score: before=%d after=%d",
			before, after)
	}
}
