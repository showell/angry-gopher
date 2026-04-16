// LOOSE_CARD_PLAY: move one board card from its stack onto another
// stack, then play a hand card that the new arrangement accepts.
//
// Mirrors angry-cat/src/lyn_rummy/tricks/loose_card_play.ts.

package tricks

import "angry-gopher/games/lynrummy"

type looseCardPlayTrick struct{}

// LooseCardPlay is the singleton trick value.
var LooseCardPlay Trick = looseCardPlayTrick{}

func (looseCardPlayTrick) ID() string { return "loose_card_play" }
func (looseCardPlayTrick) Description() string {
	return "Move one board card to a new home, then play a hand card on the resulting board."
}

type looseMove struct {
	srcIdx     int
	srcCardIdx int
	srcCard    lynrummy.Card
	destIdx    int
	destCard   lynrummy.Card // anchor
	handCard   lynrummy.HandCard
}

func (t looseCardPlayTrick) FindPlays(
	hand []lynrummy.HandCard,
	board []lynrummy.CardStack,
) []Play {
	var plays []Play

	// Only consider hand cards that can't already directly play.
	var stranded []lynrummy.HandCard
	for _, hc := range hand {
		if !cardExtendsAnyStack(hc.Card, board) {
			stranded = append(stranded, hc)
		}
	}
	if len(stranded) == 0 {
		return plays
	}

	for src, srcStack := range board {
		for ci, bc := range srcStack.BoardCards {
			if !srcStack.CanExtract(ci) {
				continue
			}
			peeled := bc.Card

			for dest, destStack := range board {
				if dest == src {
					continue
				}
				destAnchor := destStack.BoardCards[0].Card
				single := singleStackFromCard(peeled)
				var merged *lynrummy.CardStack
				if m := destStack.LeftMerge(single); m != nil {
					merged = m
				} else if m := destStack.RightMerge(single); m != nil {
					merged = m
				}
				if merged == nil {
					continue
				}
				mt := merged.Type()
				if mt == lynrummy.Bogus || mt == lynrummy.Dup || mt == lynrummy.Incomplete {
					continue
				}

				sim, ok := simulateMove(board, src, ci, dest, *merged)
				if !ok {
					continue
				}

				for _, hc := range stranded {
					if !cardExtendsAnyStack(hc.Card, sim) {
						continue
					}
					plays = append(plays, &looseCardPlayPlay{m: looseMove{
						srcIdx:     src,
						srcCardIdx: ci,
						srcCard:    peeled,
						destIdx:    dest,
						destCard:   destAnchor,
						handCard:   hc,
					}})
				}
			}
		}
	}

	return plays
}

// cardExtendsAnyStack reports whether `card` directly extends any
// stack on `board` via left_merge or right_merge.
func cardExtendsAnyStack(card lynrummy.Card, board []lynrummy.CardStack) bool {
	single := singleStackFromCard(card)
	for _, s := range board {
		if s.LeftMerge(single) != nil || s.RightMerge(single) != nil {
			return true
		}
	}
	return false
}

// simulateMove computes the post-move board without mutating the
// input. Peels (src, ci), replaces dest with merged. Returns
// (newBoard, true) on success.
func simulateMove(
	board []lynrummy.CardStack,
	src, ci, dest int,
	merged lynrummy.CardStack,
) ([]lynrummy.CardStack, bool) {
	residual, ok := peelIntoResidual(board[src], ci)
	if !ok {
		return nil, false
	}
	out := append([]lynrummy.CardStack{}, board...)
	out[src] = residual
	out[dest] = merged
	return out, true
}

// peelIntoResidual returns the source stack after peeling at
// cardIdx, without touching the original board. Mirrors the
// non-splitting forms of extractCard (end peel, set peel). For
// middle-of-run splits we return the LEFT half only — the right
// half wouldn't accept the hand card in a loose-move context that
// this trick contemplates.
func peelIntoResidual(
	stack lynrummy.CardStack,
	cardIdx int,
) (lynrummy.CardStack, bool) {
	cards := stack.BoardCards
	size := len(cards)
	st := stack.Type()

	if cardIdx == 0 && size >= 4 {
		return lynrummy.NewCardStack(
			append([]lynrummy.BoardCard{}, cards[1:]...), stack.Loc), true
	}
	if cardIdx == size-1 && size >= 4 {
		return lynrummy.NewCardStack(
			append([]lynrummy.BoardCard{}, cards[:size-1]...), stack.Loc), true
	}
	if st == lynrummy.Set && size >= 4 {
		remaining := make([]lynrummy.BoardCard, 0, size-1)
		remaining = append(remaining, cards[:cardIdx]...)
		remaining = append(remaining, cards[cardIdx+1:]...)
		return lynrummy.NewCardStack(remaining, stack.Loc), true
	}
	isRun := st == lynrummy.PureRun || st == lynrummy.RedBlackRun
	if isRun && cardIdx >= 3 && (size-cardIdx-1) >= 3 {
		return lynrummy.NewCardStack(
			append([]lynrummy.BoardCard{}, cards[:cardIdx]...), stack.Loc), true
	}
	return lynrummy.CardStack{}, false
}

type looseCardPlayPlay struct {
	m looseMove
}

func (p *looseCardPlayPlay) Trick() Trick { return LooseCardPlay }

func (p *looseCardPlayPlay) HandCards() []lynrummy.HandCard {
	return []lynrummy.HandCard{p.m.handCard}
}

func (p *looseCardPlayPlay) Apply(
	board []lynrummy.CardStack,
) ([]lynrummy.CardStack, []lynrummy.HandCard) {
	srcSi, srcCi, ok := relocate(board, p.m.srcCard)
	if !ok {
		return board, nil
	}
	destIdx := relocateStack(board, p.m.destCard)
	if destIdx < 0 || destIdx == srcSi {
		return board, nil
	}

	out, peeled, ok := extractCard(board, srcSi, srcCi)
	if !ok {
		return board, nil
	}

	// Re-locate dest after extraction (indices usually stable, but
	// relocateStack guards against edge cases).
	destIdx = relocateStack(out, p.m.destCard)
	if destIdx < 0 {
		return board, nil
	}

	destStack := out[destIdx]
	single := singleStackFromCard(peeled.Card)
	var merged *lynrummy.CardStack
	if m := destStack.LeftMerge(single); m != nil {
		merged = m
	} else if m := destStack.RightMerge(single); m != nil {
		merged = m
	}
	if merged == nil {
		return board, nil
	}
	mt := merged.Type()
	if mt == lynrummy.Bogus || mt == lynrummy.Dup || mt == lynrummy.Incomplete {
		return board, nil
	}
	out[destIdx] = *merged

	// Play the hand card on the resulting board.
	handSingle := singleStackFromCard(p.m.handCard.Card)
	for i := range out {
		var ext *lynrummy.CardStack
		if e := out[i].RightMerge(handSingle); e != nil {
			ext = e
		} else if e := out[i].LeftMerge(handSingle); e != nil {
			ext = e
		}
		if ext != nil {
			out[i] = *ext
			out = markFreshlyPlayed(out, i, p.m.handCard)
			return out, []lynrummy.HandCard{p.m.handCard}
		}
	}
	return board, nil
}

// relocateStack finds a stack index whose first card matches
// `anchor` (by value+suit+deck). Returns -1 if not found.
func relocateStack(board []lynrummy.CardStack, anchor lynrummy.Card) int {
	for si, s := range board {
		if len(s.BoardCards) == 0 {
			continue
		}
		first := s.BoardCards[0].Card
		if first.Value == anchor.Value &&
			first.Suit == anchor.Suit &&
			first.OriginDeck == anchor.OriginDeck {
			return si
		}
	}
	return -1
}

// markFreshlyPlayed defensively marks the hand card's BoardCard at
// board[stackIdx] as FreshlyPlayed. Since single_stack_from_card
// already produces FreshlyPlayed state, this is a no-op in the
// common path but catches edge cases where the merge preserves a
// different state.
func markFreshlyPlayed(
	board []lynrummy.CardStack,
	stackIdx int,
	hc lynrummy.HandCard,
) []lynrummy.CardStack {
	stack := board[stackIdx]
	newCards := make([]lynrummy.BoardCard, len(stack.BoardCards))
	for i, b := range stack.BoardCards {
		if b.Card.Value == hc.Card.Value &&
			b.Card.Suit == hc.Card.Suit &&
			b.Card.OriginDeck == hc.Card.OriginDeck {
			newCards[i] = freshlyPlayed(hc)
		} else {
			newCards[i] = b
		}
	}
	board[stackIdx] = lynrummy.NewCardStack(newCards, stack.Loc)
	return board
}
