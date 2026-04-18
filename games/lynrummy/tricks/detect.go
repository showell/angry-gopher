// Retroactive trick detection: given the hand cards a player
// released and the board state just before the move, identify
// which trick best explains the move.
//
// Used by the CRUD replay view to annotate historical moves from
// live-Cat games that never populated the lynrummy_plays table.
// Gopher computes the annotation itself from its own Go TrickBag.

package tricks

import "angry-gopher/games/lynrummy"

// DefaultOrder is the canonical trick iteration order. Matches
// TS's BAG order in angry-cat/src/lyn_rummy/tools/record_game.ts
// so detection heuristics agree across impls.
var DefaultOrder = []Trick{
	HandStacks,
	DirectPlay,
	RbSwap,
	PairPeel,
	SplitForSet,
	PeelForRun,
	LooseCardPlay,
}

// FindPlay returns the first Play from the named trick whose
// HandCards match (as a multiset) the given `hand` argument.
// Returns nil if the trick id is unknown or no matching Play
// exists. The caller is responsible for applying the Play via
// Play.Apply(board).
//
// Used by the server when executing a PlayTrickAction: agent
// supplies (trick_id, hand_cards); server re-runs FindPlays and
// picks the matching Play to Apply.
func FindPlay(trickID string, hand []lynrummy.Card, board []lynrummy.CardStack) Play {
	handHC := make([]lynrummy.HandCard, len(hand))
	for i, c := range hand {
		handHC[i] = lynrummy.HandCard{Card: c, State: lynrummy.HandNormal}
	}
	for _, trick := range DefaultOrder {
		if trick.ID() != trickID {
			continue
		}
		plays := trick.FindPlays(handHC, board)
		for _, p := range plays {
			if handCardsEqualMultiset(p.HandCards(), handHC) {
				return p
			}
		}
		return nil
	}
	return nil
}

// Detect returns the ID of the first trick whose FindPlays emits
// at least one play that uses EXACTLY the given hand cards (as a
// multiset). Empty string if no trick matches.
//
// Caller supplies the cards the player actually released this
// move. The function wraps them as HandCards in HandNormal state
// (tricks don't care about HandCardState for detection).
//
// **Heuristic:** this matches by hand-card usage only, not by
// board-after byte-equality. Ambiguity is possible in principle
// (two tricks might both consume the same cards), but the
// canonical ordering gives a deterministic choice. Sharpen later
// if real games turn up false attributions.
func Detect(handReleased []lynrummy.Card, board []lynrummy.CardStack) string {
	if len(handReleased) == 0 {
		return ""
	}

	hand := make([]lynrummy.HandCard, len(handReleased))
	for i, c := range handReleased {
		hand[i] = lynrummy.HandCard{Card: c, State: lynrummy.HandNormal}
	}

	for _, trick := range DefaultOrder {
		plays := trick.FindPlays(hand, board)
		for _, p := range plays {
			if handCardsEqualMultiset(p.HandCards(), hand) {
				return trick.ID()
			}
		}
	}
	return ""
}

// handCardsEqualMultiset compares two HandCard lists as multisets
// of Card values. States are ignored — we match on identity only.
func handCardsEqualMultiset(a, b []lynrummy.HandCard) bool {
	if len(a) != len(b) {
		return false
	}
	counts := map[lynrummy.Card]int{}
	for _, hc := range a {
		counts[hc.Card]++
	}
	for _, hc := range b {
		counts[hc.Card]--
		if counts[hc.Card] < 0 {
			return false
		}
	}
	return true
}
