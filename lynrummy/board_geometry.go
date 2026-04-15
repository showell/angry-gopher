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
	MaxWidth  int `json:"max_width"`
	MaxHeight int `json:"max_height"`
	Margin    int `json:"margin"` // minimum gap between stacks
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

func padRect(r rect, margin int) rect {
	return rect{
		left:   r.left - margin,
		top:    r.top - margin,
		right:  r.right + margin,
		bottom: r.bottom + margin,
	}
}

func checkGeometry(board []CardStack, bounds BoardBounds) *RefereeError {
	rects := make([]rect, len(board))
	for i, s := range board {
		r := stackRect(s)
		if r.left < 0 || r.top < 0 || r.right > bounds.MaxWidth || r.bottom > bounds.MaxHeight {
			return &RefereeError{
				Stage:   "geometry",
				Message: fmt.Sprintf("stack %d extends outside the board", i),
			}
		}
		rects[i] = r
	}

	// Highest severity first: actual overlap, then within-margin crowding.
	for i := 0; i < len(rects); i++ {
		for j := i + 1; j < len(rects); j++ {
			if rectsOverlap(rects[i], rects[j]) {
				return &RefereeError{
					Stage:   "geometry",
					Message: fmt.Sprintf("stacks %d and %d overlap", i, j),
				}
			}
		}
	}

	for i := 0; i < len(rects); i++ {
		for j := i + 1; j < len(rects); j++ {
			if rectsOverlap(padRect(rects[i], bounds.Margin), rects[j]) {
				return &RefereeError{
					Stage:   "geometry",
					Message: fmt.Sprintf("stacks %d and %d are too close (within %dpx margin)", i, j, bounds.Margin),
				}
			}
		}
	}

	return nil
}
