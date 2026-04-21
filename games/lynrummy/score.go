// Scoring. Mirrors elm/src/LynRummy/Score.elm — which
// mirrors angry-cat/src/lyn_rummy/core/score.ts.
//
// Flat per-card formula: each card in a valid 3+ family is worth
// one stackTypeValue. Splitting a long stack into two shorter
// valid ones preserves total score. No first-two-free discount.

package lynrummy

// StackTypeValue returns points per card for the given stack type.
// Non-valid types (Incomplete / Bogus / Dup) are worth zero.
func StackTypeValue(t StackType) int {
	switch t {
	case PureRun:
		return 100
	case Set:
		return 60
	case RedBlackRun:
		return 50
	default:
		return 0
	}
}

// ScoreForStack returns the score for a single stack:
// size × stackTypeValue.
func ScoreForStack(s CardStack) int {
	return s.Size() * StackTypeValue(s.Type())
}

// ScoreForStacks is the sum of ScoreForStack over a list.
func ScoreForStacks(stacks []CardStack) int {
	total := 0
	for _, s := range stacks {
		total += ScoreForStack(s)
	}
	return total
}

// ScoreForCardsPlayed is the per-turn bonus for playing `num`
// cards. Flat 200-point "actually played" bonus plus
// 100 × num². Non-positive num returns 0.
func ScoreForCardsPlayed(num int) int {
	if num <= 0 {
		return 0
	}
	return 200 + 100*num*num
}
