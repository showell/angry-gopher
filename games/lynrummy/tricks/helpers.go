// Small helpers used across multiple tricks. Mirrors
// angry-cat/src/lyn_rummy/tricks/helpers.ts.

package tricks

import "angry-gopher/games/lynrummy"

// placerBounds is the board region tricks must stay inside when
// placing freshly-created stacks. Matches the referee's bounds
// (views/lynrummy_elm.go complete_turn gate) so every placement
// the tricks pick can survive ValidateTurnComplete.
var placerBounds = lynrummy.BoardBounds{MaxWidth: 800, MaxHeight: 600, Margin: 5}

// mergeScratchLoc is a throwaway Location for ephemeral stacks
// that exist only as a merge argument and never reach the
// returned board. The merge routines preserve the target stack's
// loc, so the scratch value is invisible to callers.
var mergeScratchLoc = lynrummy.Location{Top: 0, Left: 0}

// freshlyPlayed wraps a HandCard's Card as a newly-placed
// BoardCard. Mirrors TS's freshly_played helper.
func freshlyPlayed(hc lynrummy.HandCard) lynrummy.BoardCard {
	return lynrummy.BoardCard{Card: hc.Card, State: lynrummy.FreshlyPlayed}
}

// singleStackFromCard wraps a raw Card as a singleton CardStack
// used as a merge argument only — the caller merges it into a real
// stack and throws the wrapper away, so the location is scratch.
// Mirrors TS's single_stack_from_card.
func singleStackFromCard(c lynrummy.Card) lynrummy.CardStack {
	return lynrummy.NewCardStack(
		[]lynrummy.BoardCard{{Card: c, State: lynrummy.FreshlyPlayed}},
		mergeScratchLoc,
	)
}

// substituteInStack replaces the card at `position` in `stack`
// with `newCard`, preserving the stack's location. Mirrors TS's
// substitute_in_stack.
func substituteInStack(
	stack lynrummy.CardStack,
	position int,
	newCard lynrummy.BoardCard,
) lynrummy.CardStack {
	newCards := make([]lynrummy.BoardCard, len(stack.BoardCards))
	copy(newCards, stack.BoardCards)
	newCards[position] = newCard
	return lynrummy.NewCardStack(newCards, stack.Loc)
}

// pushNewStack appends a new CardStack to the board at a
// collision-free Location computed via FindOpenLoc. Used by
// tricks that produce "form a brand-new group" as their apply
// behavior. Mirrors TS's push_new_stack, diverging only by
// computing a real Location instead of DUMMY_LOC — required
// after bcaea72 moved board-diff computation server-side, since
// the auto-player no longer places stacks client-side.
func pushNewStack(
	board []lynrummy.CardStack,
	boardCards []lynrummy.BoardCard,
) []lynrummy.CardStack {
	loc := lynrummy.FindOpenLoc(board, len(boardCards), placerBounds)
	return append(board, lynrummy.NewCardStack(boardCards, loc))
}

// extractCard removes the card at (stackIdx, cardIdx) from the
// board and returns (newBoard, extractedCard, ok).
//
// Three extraction modes:
//   - End peel (size>=4, first/last): shortened stack.
//   - Set peel (SET, size>=4, middle): card removed from middle.
//   - Middle peel (run, both halves >=3): stack splits into two.
//
// Returns ok=false if the extraction isn't legal at that index.
//
// **Divergence from TS:** TS mutates the board in place. Go
// returns a new board — simpler semantics for atomic Apply.
func extractCard(
	board []lynrummy.CardStack,
	stackIdx, cardIdx int,
) ([]lynrummy.CardStack, lynrummy.BoardCard, bool) {
	if stackIdx < 0 || stackIdx >= len(board) {
		return board, lynrummy.BoardCard{}, false
	}
	stack := board[stackIdx]
	cards := stack.BoardCards
	size := len(cards)
	st := stack.Type()

	out := append([]lynrummy.CardStack{}, board...)

	// End peel — first card.
	if cardIdx == 0 && size >= 4 {
		out[stackIdx] = lynrummy.NewCardStack(
			append([]lynrummy.BoardCard{}, cards[1:]...), stack.Loc)
		return out, cards[0], true
	}
	// End peel — last card.
	if cardIdx == size-1 && size >= 4 {
		out[stackIdx] = lynrummy.NewCardStack(
			append([]lynrummy.BoardCard{}, cards[:size-1]...), stack.Loc)
		return out, cards[size-1], true
	}
	// Set peel — any middle card of a 4+ set.
	if st == lynrummy.Set && size >= 4 {
		remaining := make([]lynrummy.BoardCard, 0, size-1)
		remaining = append(remaining, cards[:cardIdx]...)
		remaining = append(remaining, cards[cardIdx+1:]...)
		out[stackIdx] = lynrummy.NewCardStack(remaining, stack.Loc)
		return out, cards[cardIdx], true
	}
	// Middle peel — run, both halves must be size>=3.
	isRun := st == lynrummy.PureRun || st == lynrummy.RedBlackRun
	if isRun && cardIdx >= 3 && (size-cardIdx-1) >= 3 {
		left := lynrummy.NewCardStack(
			append([]lynrummy.BoardCard{}, cards[:cardIdx]...), stack.Loc)
		out[stackIdx] = left
		rightCards := append([]lynrummy.BoardCard{}, cards[cardIdx+1:]...)
		rightLoc := lynrummy.FindOpenLoc(out, len(rightCards), placerBounds)
		right := lynrummy.NewCardStack(rightCards, rightLoc)
		out = append(out, right)
		return out, cards[cardIdx], true
	}
	return board, lynrummy.BoardCard{}, false
}
