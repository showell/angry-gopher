// Collision-free placement math for new stacks on the LynRummy
// board. Faithful port of elm-port-docs/src/LynRummy/PlaceStack.elm
// (which itself ports angry-cat/src/lyn_rummy/game/place_stack.ts).
//
// When a trick produces a NEW stack (peel a card off, split a run,
// form a new group from hand cards), this module picks a top/left
// that doesn't overlap any existing stack. Without it, every new
// stack lands at (0,0) and the referee rejects the turn with
// "extends outside the board" or "stacks overlap."
//
// Pure geometry — no card semantics.

package lynrummy

// placeStep is the candidate-sweep granularity in pixels. Smaller
// → tighter packing, more iterations. Mirrors the default used by
// Elm's PlaceStack tests; the referee uses a 5px margin so a 10px
// step lands cleanly on valid positions.
const placeStep = 10

// FindOpenLoc returns a Location for a new stack of cardCount
// cards such that its bounding box (padded by bounds.Margin) does
// not overlap any stack in `existing`.
//
// Sweeps a uniform grid row-major from (0,0). Returns the first
// candidate that clears every existing stack.
//
// Fallback when no fit: bottom-left corner. Callers that care can
// re-check the result against existing stacks.
func FindOpenLoc(existing []CardStack, cardCount int, bounds BoardBounds) Location {
	newW := stackWidthForCount(cardCount)
	newH := CardHeight

	existingRects := make([]rect, len(existing))
	for i, s := range existing {
		existingRects[i] = stackRect(s)
	}

	for top := 0; top+newH <= bounds.MaxHeight; top += placeStep {
		for left := 0; left+newW <= bounds.MaxWidth; left += placeStep {
			candidate := rect{
				left:   left - bounds.Margin,
				top:    top - bounds.Margin,
				right:  left + newW + bounds.Margin,
				bottom: top + newH + bounds.Margin,
			}
			collides := false
			for _, er := range existingRects {
				if rectsOverlap(candidate, er) {
					collides = true
					break
				}
			}
			if !collides {
				return Location{Top: top, Left: left}
			}
		}
	}

	// No fit — fall back to bottom-left. Still a valid Location;
	// referee may reject if it overlaps, but the common case has
	// ample room.
	top := bounds.MaxHeight - newH
	if top < 0 {
		top = 0
	}
	return Location{Top: top, Left: 0}
}

// stackWidthForCount returns the pixel width of a stack with n
// cards. 0 for n <= 0. Pairs with stackRect's width calculation.
func stackWidthForCount(n int) int {
	if n <= 0 {
		return 0
	}
	return CardWidth + (n-1)*CardPitch
}
