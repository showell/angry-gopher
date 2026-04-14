// RB_SWAP ("substitute trick"): kick a same-value, same-color,
// different-suit card out of an rb (red/black alternating) run and
// slot the hand card into its seat. The kicked card must find a
// home on a pure run or a not-yet-full set.
//
// Mirrors angry-cat/src/lyn_rummy/tricks/rb_swap.ts.

package tricks

import "angry-gopher/lynrummy"

type rbSwapTrick struct{}

// RbSwap is the singleton trick value.
var RbSwap Trick = rbSwapTrick{}

func (rbSwapTrick) ID() string { return "rb_swap" }
func (rbSwapTrick) Description() string {
	return "Substitute your card for a same-color one in an rb run; the kicked card goes to a set or pure run."
}

func (t rbSwapTrick) FindPlays(
	hand []lynrummy.HandCard,
	board []lynrummy.CardStack,
) []Play {
	var plays []Play

	for _, hc := range hand {
		handColor := lynrummy.SuitColor(hc.Card.Suit)

		for si, stack := range board {
			if stack.Type() != lynrummy.RedBlackRun {
				continue
			}
			cards := stack.Cards()
			for ci, bc := range cards {
				if bc.Value != hc.Card.Value {
					continue
				}
				if lynrummy.SuitColor(bc.Suit) != handColor {
					continue
				}
				if bc.Suit == hc.Card.Suit {
					continue
				}

				// Does the rb run stay rb after substitution?
				swapped := make([]lynrummy.Card, len(cards))
				copy(swapped, cards)
				swapped[ci] = hc.Card
				if lynrummy.GetStackType(swapped) != lynrummy.RedBlackRun {
					continue
				}

				// The kicked card needs a home.
				kicked := bc
				homeIdx := findKickedHome(board, si, kicked)
				if homeIdx < 0 {
					continue
				}

				plays = append(plays, &rbSwapPlay{
					handCard: hc,
					runIdx:   si,
					runPos:   ci,
					kicked:   kicked,
					homeIdx:  homeIdx,
				})
			}
		}
	}

	return plays
}

// findKickedHome finds an index for the kicked card: a same-value
// set with < 4 cards missing this suit, or a pure run that accepts
// the card at an end.
func findKickedHome(
	board []lynrummy.CardStack,
	skip int,
	kicked lynrummy.Card,
) int {
	for j, target := range board {
		if j == skip {
			continue
		}
		tst := target.Type()
		if tst == lynrummy.Set && len(target.BoardCards) < 4 {
			if target.BoardCards[0].Card.Value == kicked.Value {
				hasSuit := false
				for _, bc := range target.BoardCards {
					if bc.Card.Suit == kicked.Suit {
						hasSuit = true
						break
					}
				}
				if !hasSuit {
					return j
				}
			}
		}
		if tst == lynrummy.PureRun {
			single := singleStackFromCard(kicked)
			if target.LeftMerge(single) != nil || target.RightMerge(single) != nil {
				return j
			}
		}
	}
	return -1
}

type rbSwapPlay struct {
	handCard lynrummy.HandCard
	runIdx   int
	runPos   int
	kicked   lynrummy.Card
	homeIdx  int
}

func (p *rbSwapPlay) Trick() Trick { return RbSwap }

func (p *rbSwapPlay) HandCards() []lynrummy.HandCard {
	return []lynrummy.HandCard{p.handCard}
}

func (p *rbSwapPlay) Apply(
	board []lynrummy.CardStack,
) ([]lynrummy.CardStack, []lynrummy.HandCard) {
	if p.runIdx >= len(board) || p.homeIdx >= len(board) {
		return board, nil
	}
	stack := board[p.runIdx]
	if stack.Type() != lynrummy.RedBlackRun {
		return board, nil
	}
	cards := stack.Cards()
	if p.runPos >= len(cards) {
		return board, nil
	}
	current := cards[p.runPos]
	if current.Value != p.kicked.Value ||
		current.Suit != p.kicked.Suit ||
		current.OriginDeck != p.kicked.OriginDeck {
		return board, nil
	}

	out := append([]lynrummy.CardStack{}, board...)

	out[p.runIdx] = substituteInStack(stack, p.runPos, freshlyPlayed(p.handCard))
	out = placeKicked(out, p.homeIdx, p.kicked)
	return out, []lynrummy.HandCard{p.handCard}
}

// placeKicked homes the kicked card onto dest_idx's stack. Returns
// new board. If the destination is a set, append. If a pure run,
// merge.
func placeKicked(
	board []lynrummy.CardStack,
	destIdx int,
	kicked lynrummy.Card,
) []lynrummy.CardStack {
	dest := board[destIdx]
	if dest.Type() == lynrummy.Set {
		newCards := append([]lynrummy.BoardCard{}, dest.BoardCards...)
		newCards = append(newCards, lynrummy.BoardCard{
			Card:  kicked,
			State: lynrummy.FirmlyOnBoard,
		})
		board[destIdx] = lynrummy.NewCardStack(newCards, dest.Loc)
		return board
	}
	single := singleStackFromCard(kicked)
	if merged := dest.LeftMerge(single); merged != nil {
		board[destIdx] = *merged
		return board
	}
	if merged := dest.RightMerge(single); merged != nil {
		board[destIdx] = *merged
		return board
	}
	return board
}
