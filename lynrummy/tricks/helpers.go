// Small helpers used across multiple tricks. Mirrors
// angry-cat/src/lyn_rummy/tricks/helpers.ts.

package tricks

import "angry-gopher/lynrummy"

// dummyLoc is the default location for a freshly-created stack
// that a trick appends to the board. Matches TS's DUMMY_LOC.
var dummyLoc = lynrummy.Location{Top: 0, Left: 0}

// freshlyPlayed wraps a HandCard's Card as a newly-placed
// BoardCard. Mirrors TS's freshly_played helper.
func freshlyPlayed(hc lynrummy.HandCard) lynrummy.BoardCard {
	return lynrummy.BoardCard{Card: hc.Card, State: lynrummy.FreshlyPlayed}
}

// pushNewStack appends a new CardStack (at dummyLoc) to the board.
// Used by tricks that produce "form a brand-new group" as their
// apply behavior. Mirrors TS's push_new_stack.
func pushNewStack(
	board []lynrummy.CardStack,
	boardCards []lynrummy.BoardCard,
) []lynrummy.CardStack {
	return append(board, lynrummy.NewCardStack(boardCards, dummyLoc))
}
