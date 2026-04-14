// DIRECT_PLAY: a hand card extends an existing board stack at one
// of its ends. The simplest trick.
//
// Mirrors angry-cat/src/lyn_rummy/tricks/direct_play.ts.

package tricks

import "angry-gopher/lynrummy"

type directPlayTrick struct{}

// DirectPlay is the singleton trick value.
var DirectPlay Trick = directPlayTrick{}

func (directPlayTrick) ID() string          { return "direct_play" }
func (directPlayTrick) Description() string { return "Play a hand card onto the end of a stack." }

func (t directPlayTrick) FindPlays(
	hand []lynrummy.HandCard,
	board []lynrummy.CardStack,
) []Play {
	var plays []Play
	for _, hc := range hand {
		single := lynrummy.FromHandCard(hc, lynrummy.Location{})
		for i, stack := range board {
			if stack.RightMerge(single) != nil {
				plays = append(plays, &directPlayPlay{handCard: hc, targetIdx: i})
				continue // prefer right-merge if both would work
			}
			if stack.LeftMerge(single) != nil {
				plays = append(plays, &directPlayPlay{handCard: hc, targetIdx: i})
			}
		}
	}
	return plays
}

// directPlayPlay captures one concrete (hand card, target stack)
// pairing. State is explicit — no closures over locals.
type directPlayPlay struct {
	handCard  lynrummy.HandCard
	targetIdx int
}

func (p *directPlayPlay) Trick() Trick { return DirectPlay }

func (p *directPlayPlay) HandCards() []lynrummy.HandCard {
	return []lynrummy.HandCard{p.handCard}
}

func (p *directPlayPlay) Apply(
	board []lynrummy.CardStack,
) ([]lynrummy.CardStack, []lynrummy.HandCard) {
	single := lynrummy.FromHandCard(p.handCard, lynrummy.Location{})
	out := append([]lynrummy.CardStack{}, board...)

	if p.targetIdx < len(out) {
		stack := out[p.targetIdx]
		merged := stack.RightMerge(single)
		if merged == nil {
			merged = stack.LeftMerge(single)
		}
		if merged != nil {
			out[p.targetIdx] = *merged
			return out, []lynrummy.HandCard{p.handCard}
		}
	}
	return out, nil
}
