// HAND_STACKS: the hand already contains 3+ cards that form a
// complete set or run — push the whole group onto the board as a
// new stack.
//
// Mirrors angry-cat/src/lyn_rummy/tricks/hand_stacks.ts.

package tricks

import (
	"sort"

	"angry-gopher/games/lynrummy"
)

type handStacksTrick struct{}

// HandStacks is the singleton trick value.
var HandStacks Trick = handStacksTrick{}

func (handStacksTrick) ID() string { return "hand_stacks" }
func (handStacksTrick) Description() string {
	return "You already have 3+ cards in your hand that form a set or run!"
}

func (t handStacksTrick) FindPlays(
	hand []lynrummy.HandCard,
	_ []lynrummy.CardStack,
) []Play {
	var plays []Play
	for _, group := range findCandidateGroups(hand) {
		plays = append(plays, &handStacksPlay{group: group})
	}
	return plays
}

type handStacksPlay struct {
	group []lynrummy.HandCard
}

func (p *handStacksPlay) Trick() Trick                      { return HandStacks }
func (p *handStacksPlay) HandCards() []lynrummy.HandCard    { return p.group }

func (p *handStacksPlay) Apply(
	board []lynrummy.CardStack,
) ([]lynrummy.CardStack, []lynrummy.HandCard) {
	if !isValidGroup(p.group) {
		return append([]lynrummy.CardStack{}, board...), nil
	}
	bcs := make([]lynrummy.BoardCard, len(p.group))
	for i, hc := range p.group {
		bcs[i] = freshlyPlayed(hc)
	}
	out := append([]lynrummy.CardStack{}, board...)
	out = pushNewStack(out, bcs)
	return out, p.group
}

// --- Group finders ---

// findCandidateGroups returns every 3+ subset of `hand` whose cards
// form a valid set or run. Emit order: sets first (by value),
// then pure runs (by suit), then rb runs. Mirrors TS iteration
// order so first_play is stable across impls.
func findCandidateGroups(hand []lynrummy.HandCard) [][]lynrummy.HandCard {
	var out [][]lynrummy.HandCard

	// Sets: group by value, then pick one of each suit.
	byValue := groupByValue(hand)
	for _, v := range sortedValueKeys(byValue) {
		cards := byValue[v]
		if len(cards) < 3 {
			continue
		}
		if set := pickValidSet(cards); set != nil {
			out = append(out, set)
		}
	}

	// Pure runs: for each suit, find consecutive same-suit chains.
	bySuit := groupBySuit(hand)
	for _, s := range sortedSuitKeys(bySuit) {
		cards := bySuit[s]
		for _, run := range longestPureRuns(cards) {
			if len(run) >= 3 {
				out = append(out, run)
			}
		}
	}

	// Rb runs: consider all cards, consecutive alternating color.
	for _, run := range findRbRuns(hand) {
		if len(run) >= 3 {
			out = append(out, run)
		}
	}

	return out
}

func groupByValue(hand []lynrummy.HandCard) map[int][]lynrummy.HandCard {
	out := map[int][]lynrummy.HandCard{}
	for _, hc := range hand {
		out[hc.Card.Value] = append(out[hc.Card.Value], hc)
	}
	return out
}

func groupBySuit(hand []lynrummy.HandCard) map[lynrummy.Suit][]lynrummy.HandCard {
	out := map[lynrummy.Suit][]lynrummy.HandCard{}
	for _, hc := range hand {
		out[hc.Card.Suit] = append(out[hc.Card.Suit], hc)
	}
	return out
}

func sortedValueKeys(m map[int][]lynrummy.HandCard) []int {
	keys := make([]int, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Ints(keys)
	return keys
}

func sortedSuitKeys(m map[lynrummy.Suit][]lynrummy.HandCard) []lynrummy.Suit {
	keys := make([]lynrummy.Suit, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	return keys
}

// pickValidSet picks one card per distinct suit from same-value
// hand cards. Preserves insertion order (later duplicate-suits are
// skipped). Returns nil if fewer than 3 distinct suits are
// represented or if the resulting group isn't classified as a Set.
func pickValidSet(cards []lynrummy.HandCard) []lynrummy.HandCard {
	seen := map[lynrummy.Suit]bool{}
	var chosen []lynrummy.HandCard
	for _, hc := range cards {
		if seen[hc.Card.Suit] {
			continue
		}
		seen[hc.Card.Suit] = true
		chosen = append(chosen, hc)
	}
	if len(chosen) < 3 {
		return nil
	}
	if !isValidGroupType(chosen, lynrummy.Set) {
		return nil
	}
	return chosen
}

// longestPureRuns finds maximal consecutive-value runs inside a
// same-suit card list. Deduplicates by value (double-deck dups
// can't both be in a pure run).
func longestPureRuns(cards []lynrummy.HandCard) [][]lynrummy.HandCard {
	if len(cards) == 0 {
		return nil
	}
	byValue := map[int]lynrummy.HandCard{}
	for _, hc := range cards {
		if _, ok := byValue[hc.Card.Value]; !ok {
			byValue[hc.Card.Value] = hc
		}
	}
	sorted := make([]lynrummy.HandCard, 0, len(byValue))
	for _, v := range sortedValueKeys(map[int][]lynrummy.HandCard{}) {
		_ = v // keep imports used
	}
	values := make([]int, 0, len(byValue))
	for v := range byValue {
		values = append(values, v)
	}
	sort.Ints(values)
	for _, v := range values {
		sorted = append(sorted, byValue[v])
	}

	var runs [][]lynrummy.HandCard
	var current []lynrummy.HandCard
	for _, hc := range sorted {
		if len(current) == 0 || hc.Card.Value == current[len(current)-1].Card.Value+1 {
			current = append(current, hc)
		} else {
			if len(current) >= 3 && isValidGroup(current) {
				runs = append(runs, current)
			}
			current = []lynrummy.HandCard{hc}
		}
	}
	if len(current) >= 3 && isValidGroup(current) {
		runs = append(runs, current)
	}
	return runs
}

// findRbRuns finds runs of consecutive values with alternating
// colors across the whole hand.
func findRbRuns(hand []lynrummy.HandCard) [][]lynrummy.HandCard {
	byValue := map[int]lynrummy.HandCard{}
	for _, hc := range hand {
		if _, ok := byValue[hc.Card.Value]; !ok {
			byValue[hc.Card.Value] = hc
		}
	}
	values := make([]int, 0, len(byValue))
	for v := range byValue {
		values = append(values, v)
	}
	sort.Ints(values)

	var runs [][]lynrummy.HandCard
	var current []lynrummy.HandCard
	for _, v := range values {
		hc := byValue[v]
		if len(current) == 0 {
			current = []lynrummy.HandCard{hc}
			continue
		}
		last := current[len(current)-1]
		sameSuccessor := hc.Card.Value == last.Card.Value+1
		altColor := lynrummy.SuitColor(hc.Card.Suit) != lynrummy.SuitColor(last.Card.Suit)
		if sameSuccessor && altColor {
			current = append(current, hc)
		} else {
			if len(current) >= 3 && isValidGroup(current) {
				runs = append(runs, current)
			}
			current = []lynrummy.HandCard{hc}
		}
	}
	if len(current) >= 3 && isValidGroup(current) {
		runs = append(runs, current)
	}
	return runs
}

func isValidGroup(hcs []lynrummy.HandCard) bool {
	cards := make([]lynrummy.Card, len(hcs))
	for i, hc := range hcs {
		cards[i] = hc.Card
	}
	t := lynrummy.GetStackType(cards)
	return t == lynrummy.Set || t == lynrummy.PureRun || t == lynrummy.RedBlackRun
}

func isValidGroupType(hcs []lynrummy.HandCard, want lynrummy.StackType) bool {
	cards := make([]lynrummy.Card, len(hcs))
	for i, hc := range hcs {
		cards[i] = hc.Card
	}
	return lynrummy.GetStackType(cards) == want
}
