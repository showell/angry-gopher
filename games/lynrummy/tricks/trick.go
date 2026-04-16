// Package tricks implements the LynRummy TrickBag — a set of
// plugin-style "trick" recognizers that each propose moves a
// human player might make.
//
// A Trick is stateless: given (hand, board), it returns zero or
// more Plays. A Play knows how to apply itself to the board and
// what hand cards it consumes.
//
// Mirrors angry-cat/src/lyn_rummy/tricks/ (TS canonical). See
// TS_TO_GO.md at this level for porting idioms.

package tricks

import "angry-gopher/games/lynrummy"

// Trick is the plugin interface. Each registered trick is a
// stateless singleton (zero-sized struct) with methods for its
// identity and its move-finder.
type Trick interface {
	ID() string
	Description() string
	FindPlays(hand []lynrummy.HandCard, board []lynrummy.CardStack) []Play
}

// Play is a concrete proposed move. Carries the state captured at
// detection time; Apply produces (updated board, hand cards
// consumed).
//
// **Divergence from TS:** TS's `apply(board)` mutates `board` in
// place and returns the hand cards. Go returns a new board
// alongside, which is simpler and avoids TS's "re-check at apply
// time" defensive rescan — by the time Apply runs on a specific
// `board`, that's the board we're working against.
type Play interface {
	Trick() Trick
	HandCards() []lynrummy.HandCard
	Apply(board []lynrummy.CardStack) (newBoard []lynrummy.CardStack, played []lynrummy.HandCard)
}
