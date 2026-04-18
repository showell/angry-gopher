// Replay primitives: apply a WireAction to a (board, hand) state
// to produce the next state. Mirror of
// elm-port-docs/src/LynRummy/Replay.elm.
//
// This is the server's authoritative state-reconstruction function.
// Given any action log, calling ApplyAction in sequence from
// InitialState produces the game state after those actions. All
// downstream queries (score, hints, turn-state) read from state
// produced this way.
//
// No-op for Draw / Discard / CompleteTurn / Undo — turn-logic
// isn't modeled yet. When it is, they'll get their own transitions
// here.

package lynrummy

type State struct {
	Board []CardStack `json:"board"`
	Hand  Hand        `json:"hand"`
}

// InitialState produces the starting state for a fresh session:
// the canonical opening board + the canned 15-card opening hand.
// Matches elm-port-docs/src/LynRummy/Replay.elm's initialState.
func InitialState() State {
	return State{
		Board: InitialBoard(),
		Hand:  OpeningHand(),
	}
}

// ApplyAction applies a single WireAction to the given state and
// returns the resulting state. Returns the state unchanged if the
// action refers to indices or hand cards that aren't present (the
// same silent-pass-through contract as the Elm side).
func ApplyAction(action WireAction, state State) State {
	switch a := action.(type) {
	case SplitAction:
		return applySplit(a.StackIndex, a.CardIndex, state)

	case MergeStackAction:
		return applyMergeStack(a, state)

	case MergeHandAction:
		return applyMergeHand(a, state)

	case PlaceHandAction:
		return applyPlaceHand(a, state)

	case MoveStackAction:
		return applyMoveStack(a, state)

	case DrawAction, DiscardAction, CompleteTurnAction, UndoAction:
		// Turn-logic not yet modeled.
		return state
	}
	return state
}

// --- Transition helpers ---

func applySplit(stackIdx, cardIdx int, state State) State {
	if stackIdx < 0 || stackIdx >= len(state.Board) {
		return state
	}
	stack := state.Board[stackIdx]
	newStacks := stack.Split(cardIdx)
	newBoard := removeStack(state.Board, stack)
	newBoard = append(newBoard, newStacks...)
	return State{Board: newBoard, Hand: state.Hand}
}

func applyMergeStack(a MergeStackAction, state State) State {
	if a.SourceStack < 0 || a.SourceStack >= len(state.Board) {
		return state
	}
	if a.TargetStack < 0 || a.TargetStack >= len(state.Board) {
		return state
	}
	source := state.Board[a.SourceStack]
	target := state.Board[a.TargetStack]
	var merged *CardStack
	switch a.Side {
	case LeftSide:
		merged = target.LeftMerge(source)
	case RightSide:
		merged = target.RightMerge(source)
	}
	if merged == nil {
		return state
	}
	newBoard := removeStack(state.Board, source)
	newBoard = removeStack(newBoard, target)
	newBoard = append(newBoard, *merged)
	return State{Board: newBoard, Hand: state.Hand}
}

func applyMergeHand(a MergeHandAction, state State) State {
	if a.TargetStack < 0 || a.TargetStack >= len(state.Board) {
		return state
	}
	hc := state.Hand.FindByCard(a.HandCard)
	if hc == nil {
		return state
	}
	target := state.Board[a.TargetStack]
	sourceStack := FromHandCard(*hc, Location{Top: -1, Left: -1})
	var merged *CardStack
	switch a.Side {
	case LeftSide:
		merged = target.LeftMerge(sourceStack)
	case RightSide:
		merged = target.RightMerge(sourceStack)
	}
	if merged == nil {
		return state
	}
	newBoard := removeStack(state.Board, target)
	newBoard = append(newBoard, *merged)
	return State{Board: newBoard, Hand: state.Hand.RemoveHandCard(*hc)}
}

func applyPlaceHand(a PlaceHandAction, state State) State {
	hc := state.Hand.FindByCard(a.HandCard)
	if hc == nil {
		return state
	}
	newStack := FromHandCard(*hc, a.Loc)
	newBoard := append([]CardStack{}, state.Board...)
	newBoard = append(newBoard, newStack)
	return State{Board: newBoard, Hand: state.Hand.RemoveHandCard(*hc)}
}

func applyMoveStack(a MoveStackAction, state State) State {
	if a.StackIndex < 0 || a.StackIndex >= len(state.Board) {
		return state
	}
	old := state.Board[a.StackIndex]
	moved := NewCardStack(old.BoardCards, a.NewLoc)
	newBoard := removeStack(state.Board, old)
	newBoard = append(newBoard, moved)
	return State{Board: newBoard, Hand: state.Hand}
}

// removeStack returns a new slice with the first occurrence of
// `target` (by structural equality) removed.
func removeStack(board []CardStack, target CardStack) []CardStack {
	for i, s := range board {
		if stacksEqual(s, target) {
			out := append([]CardStack{}, board[:i]...)
			return append(out, board[i+1:]...)
		}
	}
	return board
}

// ReplayActions walks the given action list from InitialState,
// applying each in order, and returns the final state.
func ReplayActions(actions []WireAction) State {
	state := InitialState()
	for _, a := range actions {
		state = ApplyAction(a, state)
	}
	return state
}
