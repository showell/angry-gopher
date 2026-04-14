// Board geometry — bounds checks, rectangle overlap, and the card
// pitch/height constants. Mirrors elm-lynrummy's BoardGeometry.elm.

package lynrummy

import "fmt"

// CardHeight is the on-board visual height of a single card.
// CardPitch is the horizontal spacing between adjacent cards in a
// stack. Elm places both of these in BoardGeometry.elm alongside
// the overlap/bounds logic; Go mirrors that placement.
const (
	CardHeight = 40
	CardPitch  = CardWidth + 6
)

type BoardBounds struct {
	MaxWidth  int
	MaxHeight int
	Margin    int // minimum gap between stacks
}

type rect struct {
	left, top, right, bottom int
}

func stackRect(s CardStack) rect {
	w := CardWidth
	if s.Size() > 1 {
		w = CardWidth + (s.Size()-1)*CardPitch
	}
	return rect{
		left:   s.Loc.Left,
		top:    s.Loc.Top,
		right:  s.Loc.Left + w,
		bottom: s.Loc.Top + CardHeight,
	}
}

func rectsOverlap(a, b rect) bool {
	return a.left < b.right &&
		a.right > b.left &&
		a.top < b.bottom &&
		a.bottom > b.top
}

func checkGeometry(board []CardStack, bounds BoardBounds) *RefereeError {
	for i, s := range board {
		r := stackRect(s)
		if r.left < 0 || r.top < 0 || r.right > bounds.MaxWidth || r.bottom > bounds.MaxHeight {
			return &RefereeError{
				Stage:   "geometry",
				Message: fmt.Sprintf("stack %d out of bounds", i),
			}
		}
	}

	for i := 0; i < len(board); i++ {
		for j := i + 1; j < len(board); j++ {
			if rectsOverlap(stackRect(board[i]), stackRect(board[j])) {
				return &RefereeError{
					Stage:   "geometry",
					Message: fmt.Sprintf("stacks %d and %d overlap", i, j),
				}
			}
		}
	}

	return nil
}
