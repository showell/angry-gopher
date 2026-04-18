// Hint orchestration: walk the seven tricks in priority order,
// take the FIRST play each produces, and return the combined
// list as ranked Suggestions. Clients pick the top one.
//
// No scoring. No enumeration. No retroactive attribution. Just:
// "here's a move, ordered simplest-first."
//
// See `showell/claude_writings/hints_from_first_principles.md`
// for the design rationale.

package tricks

import (
	lr "angry-gopher/games/lynrummy"
)

// HintPriorityOrder is the sequence we walk when building
// suggestions. Simplest / most visually obvious tricks come
// first. This is the ranking criterion — not a score metric.
var HintPriorityOrder = []Trick{
	DirectPlay,
	HandStacks,
	PairPeel,
	SplitForSet,
	PeelForRun,
	RbSwap,
	LooseCardPlay,
}

// Suggestion is one actionable hint. Rank is its position in the
// priority order (1-indexed). TrickID identifies which recognizer
// produced it. HandCards are the cards to highlight in the
// player's hand. Action is a ready-to-POST wire action.
type Suggestion struct {
	Rank        int          `json:"rank"`
	TrickID     string       `json:"trick_id"`
	Description string       `json:"description"`
	HandCards   []lr.Card    `json:"hand_cards"`
	Action      SuggestedAct `json:"action"`
}

// SuggestedAct is the wire-format action a client can POST
// directly to /actions to make this play. Kind (JSON `action`)
// is one of "merge_hand" / "merge_stack" / "place_hand" /
// "move_stack" / "split" / "trick_result". Fields beyond Kind
// are populated per-kind; unused fields stay empty. The JSON
// shape matches DecodeWireAction exactly — copy-paste POST.
type SuggestedAct struct {
	Kind string `json:"action"`

	// Hand-card actions + trick_result.
	HandCard *lr.Card `json:"hand_card,omitempty"`

	// merge_hand / merge_stack.
	TargetStack *int    `json:"target_stack,omitempty"`
	Side        lr.Side `json:"side,omitempty"`

	// merge_stack.
	SourceStack *int `json:"source_stack,omitempty"`

	// trick_result (the compound-play case: multiple cards
	// released, board diff pre-computed so the client doesn't
	// have to re-derive). No `omitempty` on the three slices:
	// strictUnmarshal requires these keys PRESENT for a
	// trick_result action, and `omitempty` elides empty slices
	// entirely (an empty stacks_to_remove is meaningful — it
	// means "nothing removed"). Non-trick_result actions emit
	// these as `null`, which strictUnmarshal accepts.
	TrickID           string          `json:"trick_id,omitempty"`
	StacksToRemove    []lr.CardStack  `json:"stacks_to_remove"`
	StacksToAdd       []lr.CardStack  `json:"stacks_to_add"`
	HandCardsReleased []lr.Card       `json:"hand_cards_released"`
}

// BuildSuggestions walks HintPriorityOrder and asks each trick
// for plays. The FIRST play each trick produces becomes ONE
// Suggestion in the returned list, ordered by priority rank.
// Returns an empty slice if no trick fires.
func BuildSuggestions(hand lr.Hand, board []lr.CardStack) []Suggestion {
	var out []Suggestion
	for i, trick := range HintPriorityOrder {
		plays := trick.FindPlays(hand.HandCards, board)
		if len(plays) == 0 {
			continue
		}
		first := plays[0]
		out = append(out, Suggestion{
			Rank:        i + 1,
			TrickID:     trick.ID(),
			Description: trick.Description(),
			HandCards:   handCardsToCards(first.HandCards()),
			Action:      suggestionAction(first, board),
		})
	}
	return out
}

// handCardsToCards strips HandCard wrappers to plain Cards for
// the wire.
func handCardsToCards(hcs []lr.HandCard) []lr.Card {
	out := make([]lr.Card, len(hcs))
	for i, hc := range hcs {
		out[i] = hc.Card
	}
	return out
}

// suggestionAction converts a Play into a SuggestedAct by
// inspecting the trick id and the board delta Apply produces.
// For direct_play we emit a merge_hand action (the client can
// POST it directly). For everything else we emit trick_result
// — the compound-play wire shape — with the board diff pre-
// computed.
func suggestionAction(p Play, board []lr.CardStack) SuggestedAct {
	trickID := p.Trick().ID()

	// direct_play maps cleanly onto a merge_hand wire action. The
	// client gets a single-card merge it can POST as-is.
	if trickID == "direct_play" {
		newBoard, _ := p.Apply(board)
		return directPlayAction(p, board, newBoard)
	}

	// Everything else is compound: the trick moves multiple cards
	// and/or transforms multiple stacks. We emit trick_result
	// (pre-diffed) so the client doesn't have to recompute. The
	// three slices are allocated non-nil even when empty so they
	// serialize as `[]` (strictUnmarshal expects them present).
	newBoard, released := p.Apply(board)
	removed, added := diffBoards(board, newBoard)
	if removed == nil {
		removed = []lr.CardStack{}
	}
	if added == nil {
		added = []lr.CardStack{}
	}
	releasedCards := make([]lr.Card, len(released))
	for i, hc := range released {
		releasedCards[i] = hc.Card
	}
	return SuggestedAct{
		Kind:              "trick_result",
		TrickID:           trickID,
		StacksToRemove:    removed,
		StacksToAdd:       added,
		HandCardsReleased: releasedCards,
	}
}

// directPlayAction reads the direct_play Apply result and
// reconstructs the (target_stack, side) the play used. The
// direct_play trick removes one stack and adds its grown
// successor — so we find the stack that disappeared and check
// whether the new stack extended it on the left or right.
func directPlayAction(p Play, before, after []lr.CardStack) SuggestedAct {
	handCards := p.HandCards()
	if len(handCards) != 1 {
		return SuggestedAct{Kind: "noop"}
	}
	hc := handCards[0].Card

	removed, added := diffBoards(before, after)
	if len(removed) != 1 || len(added) != 1 {
		return SuggestedAct{Kind: "noop"}
	}

	// Find the target's original index on the pre-Apply board.
	targetIdx := -1
	for i, s := range before {
		if s.Equals(removed[0]) {
			targetIdx = i
			break
		}
	}
	if targetIdx < 0 {
		return SuggestedAct{Kind: "noop"}
	}

	// Determine side by comparing the first card of the new stack
	// to the first card of the old stack. If they match, we
	// extended on the right; otherwise on the left.
	side := lr.RightSide
	oldFirst := removed[0].BoardCards[0].Card
	newFirst := added[0].BoardCards[0].Card
	if !oldFirst.Equals(newFirst) {
		side = lr.LeftSide
	}

	return SuggestedAct{
		Kind:        "merge_hand",
		HandCard:    &hc,
		TargetStack: &targetIdx,
		Side:        side,
	}
}

// diffBoards returns (removed, added) — stacks in `before` not
// in `after`, and stacks in `after` not in `before`. Matches by
// structural equality (location + cards).
func diffBoards(before, after []lr.CardStack) (removed, added []lr.CardStack) {
	afterCopy := append([]lr.CardStack{}, after...)
	for _, s := range before {
		found := -1
		for i, t := range afterCopy {
			if s.Equals(t) {
				found = i
				break
			}
		}
		if found >= 0 {
			afterCopy = append(afterCopy[:found], afterCopy[found+1:]...)
		} else {
			removed = append(removed, s)
		}
	}
	added = afterCopy
	return
}
