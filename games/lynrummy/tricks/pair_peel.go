// PAIR_PEEL: two hand cards form a pair (set-pair or run-pair) and
// a peelable board card completes the triplet.
//
// Mirrors angry-cat/src/lyn_rummy/tricks/pair_peel.ts.

package tricks

import (
	"sort"

	"angry-gopher/games/lynrummy"
)

type pairPeelTrick struct{}

// PairPeel is the singleton trick value.
var PairPeel Trick = pairPeelTrick{}

func (pairPeelTrick) ID() string          { return "pair_peel" }
func (pairPeelTrick) Description() string { return "Peel a board card to complete a pair in your hand." }

type pairNeed struct {
	value int
	suits []lynrummy.Suit
}

func (t pairPeelTrick) FindPlays(
	hand []lynrummy.HandCard,
	board []lynrummy.CardStack,
) []Play {
	var plays []Play

	for i := 0; i < len(hand); i++ {
		for j := i + 1; j < len(hand); j++ {
			hca, hcb := hand[i], hand[j]
			if hca.Card.Equals(hcb.Card) {
				continue
			}

			for _, need := range pairNeeds(hca.Card, hcb.Card) {
				for si, stack := range board {
					for ci, bc := range stack.BoardCards {
						if bc.Card.Value != need.value {
							continue
						}
						if !suitIn(need.suits, bc.Card.Suit) {
							continue
						}
						if !stack.CanExtract(ci) {
							continue
						}
						plays = append(plays, &pairPeelPlay{
							hca:        hca,
							hcb:        hcb,
							stackIdx:   si,
							cardIdx:    ci,
							peelTarget: bc.Card,
						})
					}
				}
			}
		}
	}

	return plays
}

func suitIn(list []lynrummy.Suit, s lynrummy.Suit) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// pairNeeds returns zero or more "complete this pair" requests.
func pairNeeds(a, b lynrummy.Card) []pairNeed {
	// Set pair.
	if a.Value == b.Value && a.Suit != b.Suit {
		allSuits := []lynrummy.Suit{lynrummy.Heart, lynrummy.Spade, lynrummy.Diamond, lynrummy.Club}
		var suits []lynrummy.Suit
		for _, s := range allSuits {
			if s != a.Suit && s != b.Suit {
				suits = append(suits, s)
			}
		}
		return []pairNeed{{value: a.Value, suits: suits}}
	}

	// Run pair needs consecutive values.
	lo, hi := a, b
	if b.Value < a.Value {
		lo, hi = b, a
	}
	if hi.Value != lynrummy.Successor(lo.Value) {
		return nil
	}

	if a.Suit == b.Suit {
		// Pure-run pair.
		return []pairNeed{
			{value: lynrummy.Predecessor(lo.Value), suits: []lynrummy.Suit{lo.Suit}},
			{value: lynrummy.Successor(hi.Value), suits: []lynrummy.Suit{hi.Suit}},
		}
	}

	aColor := lynrummy.SuitColor(a.Suit)
	bColor := lynrummy.SuitColor(b.Suit)
	if aColor != bColor {
		// Rb-run pair.
		oppLo := oppositeColorSuits(lynrummy.SuitColor(lo.Suit))
		oppHi := oppositeColorSuits(lynrummy.SuitColor(hi.Suit))
		return []pairNeed{
			{value: lynrummy.Predecessor(lo.Value), suits: oppLo},
			{value: lynrummy.Successor(hi.Value), suits: oppHi},
		}
	}

	return nil
}

func oppositeColorSuits(c lynrummy.CardColor) []lynrummy.Suit {
	if c == lynrummy.Red {
		return []lynrummy.Suit{lynrummy.Spade, lynrummy.Club}
	}
	return []lynrummy.Suit{lynrummy.Heart, lynrummy.Diamond}
}

type pairPeelPlay struct {
	hca        lynrummy.HandCard
	hcb        lynrummy.HandCard
	stackIdx   int
	cardIdx    int
	peelTarget lynrummy.Card
}

func (p *pairPeelPlay) Trick() Trick { return PairPeel }

func (p *pairPeelPlay) HandCards() []lynrummy.HandCard {
	return []lynrummy.HandCard{p.hca, p.hcb}
}

func (p *pairPeelPlay) Apply(
	board []lynrummy.CardStack,
) ([]lynrummy.CardStack, []lynrummy.HandCard) {
	if p.stackIdx >= len(board) {
		return board, nil
	}
	stack := board[p.stackIdx]
	if p.cardIdx >= len(stack.BoardCards) {
		return board, nil
	}
	bc := stack.BoardCards[p.cardIdx]
	if bc.Card.Value != p.peelTarget.Value ||
		bc.Card.Suit != p.peelTarget.Suit ||
		bc.Card.OriginDeck != p.peelTarget.OriginDeck {
		return board, nil
	}
	if !stack.CanExtract(p.cardIdx) {
		return board, nil
	}

	out, extracted, ok := extractCard(board, p.stackIdx, p.cardIdx)
	if !ok {
		return board, nil
	}

	group := []lynrummy.BoardCard{
		freshlyPlayed(p.hca),
		freshlyPlayed(p.hcb),
		extracted,
	}
	sort.SliceStable(group, func(i, j int) bool {
		return group[i].Card.Value < group[j].Card.Value
	})
	loc := lynrummy.FindOpenLoc(out, len(group), placerBounds)
	newStack := lynrummy.NewCardStack(group, loc)

	// Belt-and-braces validity check.
	st := newStack.Type()
	if st == lynrummy.Bogus || st == lynrummy.Dup || st == lynrummy.Incomplete {
		return board, nil
	}

	out = append(out, newStack)
	return out, []lynrummy.HandCard{p.hca, p.hcb}
}
