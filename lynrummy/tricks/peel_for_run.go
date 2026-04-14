// PEEL_FOR_RUN: a hand card of value V finds two extractable board
// cards at values V-1 and V+1 such that the three cards form a
// valid 3-card run (pure or rb). The two board cards get peeled
// off their stacks and the new run gets pushed.
//
// Mirrors angry-cat/src/lyn_rummy/tricks/peel_for_run.ts.

package tricks

import (
	"sort"

	"angry-gopher/lynrummy"
)

type peelForRunTrick struct{}

// PeelForRun is the singleton trick value.
var PeelForRun Trick = peelForRunTrick{}

func (peelForRunTrick) ID() string { return "peel_for_run" }
func (peelForRunTrick) Description() string {
	return "Peel two adjacent-value board cards to form a new run with your hand card."
}

type neighbor struct {
	stackIdx int
	cardIdx  int
	card     lynrummy.Card
}

func (t peelForRunTrick) FindPlays(
	hand []lynrummy.HandCard,
	board []lynrummy.CardStack,
) []Play {
	var plays []Play
	for _, hc := range hand {
		v := hc.Card.Value
		prevV := lynrummy.Predecessor(v)
		nextV := lynrummy.Successor(v)

		prevs := findPeelableAtValue(board, prevV, hc.Card)
		nexts := findPeelableAtValue(board, nextV, hc.Card)
		if len(prevs) == 0 || len(nexts) == 0 {
			continue
		}

		for _, p := range prevs {
			for _, n := range nexts {
				if p.stackIdx == n.stackIdx {
					continue
				}
				trio := []lynrummy.Card{p.card, hc.Card, n.card}
				t := lynrummy.GetStackType(trio)
				if t != lynrummy.PureRun && t != lynrummy.RedBlackRun {
					continue
				}
				plays = append(plays, &peelForRunPlay{
					handCard:   hc,
					targetPrev: p.card,
					targetNext: n.card,
				})
			}
		}
	}
	return plays
}

func findPeelableAtValue(
	board []lynrummy.CardStack,
	value int,
	exclude lynrummy.Card,
) []neighbor {
	var out []neighbor
	for si, stack := range board {
		for ci, bc := range stack.BoardCards {
			if bc.Card.Value != value {
				continue
			}
			if bc.Card.Equals(exclude) {
				continue
			}
			if !stack.CanExtract(ci) {
				continue
			}
			out = append(out, neighbor{stackIdx: si, cardIdx: ci, card: bc.Card})
		}
	}
	return out
}

type peelForRunPlay struct {
	handCard   lynrummy.HandCard
	targetPrev lynrummy.Card
	targetNext lynrummy.Card
}

func (p *peelForRunPlay) Trick() Trick { return PeelForRun }

func (p *peelForRunPlay) HandCards() []lynrummy.HandCard {
	return []lynrummy.HandCard{p.handCard}
}

func (p *peelForRunPlay) Apply(
	board []lynrummy.CardStack,
) ([]lynrummy.CardStack, []lynrummy.HandCard) {
	out := append([]lynrummy.CardStack{}, board...)

	siPrev, ciPrev, ok := relocate(out, p.targetPrev)
	if !ok {
		return board, nil
	}
	siNext, ciNext, ok := relocate(out, p.targetNext)
	if !ok {
		return board, nil
	}
	if siPrev == siNext {
		return board, nil
	}

	// Extract higher (stackIdx, cardIdx) first so the earlier
	// index stays valid.
	extractPrevFirst := siPrev > siNext ||
		(siPrev == siNext && ciPrev > ciNext)

	var firstSi, firstCi int
	var secondTarget lynrummy.Card
	if extractPrevFirst {
		firstSi, firstCi = siPrev, ciPrev
		secondTarget = p.targetNext
	} else {
		firstSi, firstCi = siNext, ciNext
		secondTarget = p.targetPrev
	}

	out, ext0, ok := extractCard(out, firstSi, firstCi)
	if !ok {
		return board, nil
	}

	secondSi, secondCi, ok := relocate(out, secondTarget)
	if !ok {
		return board, nil
	}
	out, ext1, ok := extractCard(out, secondSi, secondCi)
	if !ok {
		return board, nil
	}

	// Assemble in value order so the new stack reads naturally.
	trio := []lynrummy.BoardCard{freshlyPlayed(p.handCard), ext0, ext1}
	sort.SliceStable(trio, func(i, j int) bool {
		return trio[i].Card.Value < trio[j].Card.Value
	})
	out = pushNewStack(out, trio)
	return out, []lynrummy.HandCard{p.handCard}
}
