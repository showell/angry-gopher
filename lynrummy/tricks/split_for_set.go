// SPLIT_FOR_SET: a hand card of value V finds two same-value,
// different-suit board cards that can be extracted, and the three
// together form a new 3-set on the board.
//
// Mirrors angry-cat/src/lyn_rummy/tricks/split_for_set.ts.

package tricks

import "angry-gopher/lynrummy"

type splitForSetTrick struct{}

// SplitForSet is the singleton trick value.
var SplitForSet Trick = splitForSetTrick{}

func (splitForSetTrick) ID() string { return "split_for_set" }
func (splitForSetTrick) Description() string {
	return "Take two same-value cards out of the board and form a new set with your hand card."
}

type extractCandidate struct {
	stackIdx int
	cardIdx  int
	card     lynrummy.Card
}

func (t splitForSetTrick) FindPlays(
	hand []lynrummy.HandCard,
	board []lynrummy.CardStack,
) []Play {
	var plays []Play
	for _, hc := range hand {
		cands := findExtractableSameValue(hc.Card, board)
		if len(cands) < 2 {
			continue
		}
		a, b, ok := pickTwoDistinctSuits(cands, hc.Card.Suit)
		if !ok {
			continue
		}
		// Sanity: the resulting trio is a valid SET.
		trio := []lynrummy.Card{hc.Card, a.card, b.card}
		if lynrummy.GetStackType(trio) != lynrummy.Set {
			continue
		}
		plays = append(plays, &splitForSetPlay{
			handCard: hc,
			targetA:  a.card,
			targetB:  b.card,
		})
	}
	return plays
}

func findExtractableSameValue(
	card lynrummy.Card,
	board []lynrummy.CardStack,
) []extractCandidate {
	var out []extractCandidate
	for si, stack := range board {
		for ci, bc := range stack.BoardCards {
			if bc.Card.Value != card.Value {
				continue
			}
			if bc.Card.Suit == card.Suit {
				continue
			}
			if !stack.CanExtract(ci) {
				continue
			}
			out = append(out, extractCandidate{
				stackIdx: si,
				cardIdx:  ci,
				card:     bc.Card,
			})
		}
	}
	return out
}

// pickTwoDistinctSuits picks the first two candidates with distinct
// suits that aren't the hand-card's suit.
func pickTwoDistinctSuits(
	cands []extractCandidate,
	handSuit lynrummy.Suit,
) (extractCandidate, extractCandidate, bool) {
	for i := 0; i < len(cands); i++ {
		for j := i + 1; j < len(cands); j++ {
			if cands[i].card.Suit == cands[j].card.Suit {
				continue
			}
			if cands[i].card.Suit == handSuit {
				continue
			}
			if cands[j].card.Suit == handSuit {
				continue
			}
			return cands[i], cands[j], true
		}
	}
	return extractCandidate{}, extractCandidate{}, false
}

// splitForSetPlay captures one hand card + two target board cards
// (by identity). Apply relocates each target in the current board
// (since a previous play this turn may have shifted indices),
// extracts them, and pushes a new 3-set stack.
type splitForSetPlay struct {
	handCard lynrummy.HandCard
	targetA  lynrummy.Card
	targetB  lynrummy.Card
}

func (p *splitForSetPlay) Trick() Trick { return SplitForSet }

func (p *splitForSetPlay) HandCards() []lynrummy.HandCard {
	return []lynrummy.HandCard{p.handCard}
}

func (p *splitForSetPlay) Apply(
	board []lynrummy.CardStack,
) ([]lynrummy.CardStack, []lynrummy.HandCard) {
	out := append([]lynrummy.CardStack{}, board...)

	siA, ciA, ok := relocate(out, p.targetA)
	if !ok {
		return out, nil
	}
	out, extA, ok := extractCard(out, siA, ciA)
	if !ok {
		return board, nil
	}

	siB, ciB, ok := relocate(out, p.targetB)
	if !ok {
		return board, nil
	}
	out, extB, ok := extractCard(out, siB, ciB)
	if !ok {
		return board, nil
	}

	out = pushNewStack(out, []lynrummy.BoardCard{
		freshlyPlayed(p.handCard),
		extA,
		extB,
	})
	return out, []lynrummy.HandCard{p.handCard}
}

// relocate finds the (stackIdx, cardIdx) of `target` in the current
// board (by value+suit+deck), with extractable position. Used at
// apply time to rediscover positions after earlier turn mutations.
func relocate(
	board []lynrummy.CardStack,
	target lynrummy.Card,
) (int, int, bool) {
	for si, stack := range board {
		for ci, bc := range stack.BoardCards {
			if bc.Card.Value == target.Value &&
				bc.Card.Suit == target.Suit &&
				bc.Card.OriginDeck == target.OriginDeck &&
				stack.CanExtract(ci) {
				return si, ci, true
			}
		}
	}
	return 0, 0, false
}
