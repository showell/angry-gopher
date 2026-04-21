// Hand type and operations. Mirrors elm/src/LynRummy/Hand.elm.

package lynrummy

type Hand struct {
	HandCards []HandCard `json:"hand_cards"`
}

func EmptyHand() Hand {
	return Hand{HandCards: nil}
}

func (h Hand) IsEmpty() bool {
	return len(h.HandCards) == 0
}

func (h Hand) Size() int {
	return len(h.HandCards)
}

// AddCards appends cards to the hand, stamped with the given state.
// Mirrors Elm's Hand.addCards.
func (h Hand) AddCards(cards []Card, state HandCardState) Hand {
	out := append([]HandCard{}, h.HandCards...)
	for _, c := range cards {
		out = append(out, HandCard{Card: c, State: state})
	}
	return Hand{HandCards: out}
}

// RemoveHandCard removes the first hand card whose Card matches the
// target (ignoring state). Silent no-op if not present. Mirrors
// Elm's Hand.removeHandCard.
func (h Hand) RemoveHandCard(target HandCard) Hand {
	for i, hc := range h.HandCards {
		if hc.Card == target.Card {
			out := append([]HandCard{}, h.HandCards[:i]...)
			out = append(out, h.HandCards[i+1:]...)
			return Hand{HandCards: out}
		}
	}
	return h
}

// FindByCard returns the first hand card matching the given Card
// (ignoring state), or nil if not present. Used during replay where
// the wire carries a Card and we need the HandCard to mutate.
func (h Hand) FindByCard(c Card) *HandCard {
	for i, hc := range h.HandCards {
		if hc.Card == c {
			return &h.HandCards[i]
		}
	}
	return nil
}

// ResetState returns a Hand with every card's state set to
// HandNormal. Called at CompleteTurn to clear per-turn flags
// (FreshlyDrawn, BackFromBoard). Mirrors Elm's Hand.resetState.
func (h Hand) ResetState() Hand {
	out := make([]HandCard, len(h.HandCards))
	for i, hc := range h.HandCards {
		out[i] = HandCard{Card: hc.Card, State: HandNormal}
	}
	return Hand{HandCards: out}
}
