// Hints: enumerate every legal merge available from the current
// (board, hand) state. Two families:
//
//   - hand → board: each hand card × each board stack × each side.
//   - stack → stack: each board stack × each OTHER board stack ×
//     each side.
//
// Both families exhaustively enumerate tryHandMerge / tryStackMerge.
// Consumers decide which subset to display or act on.
//
// Splits and placements aren't reported as hints (splits are always
// structurally legal; placements are too if the target location is
// empty). Add them if the agent ever wants them.

package lynrummy

// HintKind discriminates the hint families.
type HintKind string

const (
	HintMergeHand  HintKind = "merge_hand"
	HintMergeStack HintKind = "merge_stack"
)

// Hint is one legal move. Same shape across families; unused fields
// stay at their zero values. The JSON tags make this agent-readable
// in the obvious way.
type Hint struct {
	Kind        HintKind `json:"kind"`
	HandCard    *Card    `json:"hand_card,omitempty"`
	SourceStack *int     `json:"source_stack,omitempty"`
	TargetStack int      `json:"target_stack"`
	Side        Side     `json:"side"`
	ResultScore int      `json:"result_score"`
}

// LegalHandMerges returns every (hand_card, target, side) tuple
// where tryHandMerge would succeed against the given board.
func LegalHandMerges(hand Hand, board []CardStack) []Hint {
	var out []Hint
	for _, hc := range hand.HandCards {
		card := hc.Card
		for targetIdx, target := range board {
			for _, side := range []Side{LeftSide, RightSide} {
				merged := tryHandMergeMerged(target, hc, side)
				if merged == nil {
					continue
				}
				hint := Hint{
					Kind:        HintMergeHand,
					HandCard:    &card,
					TargetStack: targetIdx,
					Side:        side,
					ResultScore: scoreAfterReplace(board, []CardStack{target}, []CardStack{*merged}),
				}
				out = append(out, hint)
			}
		}
	}
	return out
}

// LegalStackMerges returns every (source, target, side) tuple where
// tryStackMerge would succeed against the given board. Source and
// target are both indices into the same board list.
func LegalStackMerges(board []CardStack) []Hint {
	var out []Hint
	for sourceIdx, source := range board {
		for targetIdx, target := range board {
			if sourceIdx == targetIdx {
				continue
			}
			for _, side := range []Side{LeftSide, RightSide} {
				var merged *CardStack
				switch side {
				case LeftSide:
					merged = target.LeftMerge(source)
				case RightSide:
					merged = target.RightMerge(source)
				}
				if merged == nil {
					continue
				}
				sIdx := sourceIdx
				hint := Hint{
					Kind:        HintMergeStack,
					SourceStack: &sIdx,
					TargetStack: targetIdx,
					Side:        side,
					ResultScore: scoreAfterReplace(board, []CardStack{source, target}, []CardStack{*merged}),
				}
				out = append(out, hint)
			}
		}
	}
	return out
}

// AllLegalMerges concatenates hand-merges and stack-merges.
func AllLegalMerges(hand Hand, board []CardStack) []Hint {
	return append(LegalHandMerges(hand, board), LegalStackMerges(board)...)
}

// --- Internal helpers ---

// tryHandMergeMerged attempts a hand-card merge onto the target
// stack's given side. Returns the merged stack (or nil if the
// merge isn't legal). Mirrors Elm's BoardActions.tryHandMerge in
// behavior but returns just the new stack.
func tryHandMergeMerged(target CardStack, hc HandCard, side Side) *CardStack {
	source := FromHandCard(hc, Location{Top: -1, Left: -1})
	switch side {
	case LeftSide:
		return target.LeftMerge(source)
	case RightSide:
		return target.RightMerge(source)
	}
	return nil
}

// scoreAfterReplace computes the board score if `remove` stacks
// are replaced by `add` stacks. Used to preview a hint's score
// impact without mutating.
func scoreAfterReplace(board []CardStack, remove, add []CardStack) int {
	total := 0
	for _, s := range board {
		skip := false
		for _, r := range remove {
			if stacksEqual(s, r) {
				skip = true
				break
			}
		}
		if !skip {
			total += ScoreForStack(s)
		}
	}
	for _, s := range add {
		total += ScoreForStack(s)
	}
	return total
}
