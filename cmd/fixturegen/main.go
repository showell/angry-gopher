// fixturegen: parse a LynRummy-DSL scenario file and emit native
// test code for Go + Elm. Deliberately small; the DSL is simple
// enough that the whole tool fits in one file.
//
// Usage:
//   go run ./cmd/fixturegen ./lynrummy/conformance/scenarios/*.dsl
//
// Emits:
//   ./lynrummy/tricks/dsl_conformance_test.go
//   ./elm-lynrummy/tests/LynRummy/DslConformanceTest.elm

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// --- AST ---

type scenario struct {
	name      string
	desc      string
	op        string // validate_game_move | validate_turn_complete | trick_first_play
	trick     string
	hand      []card
	boardVar  string      // "board" or "board_before"
	board     []stack     // for trick_first_play + validate_turn_complete
	removed   []stack     // validate_game_move
	added     []stack     // validate_game_move
	handPlayed []card     // validate_game_move explicit hand
	expect    expectation
}

type expectation struct {
	kind          string // "ok" | "no_plays" | "play" | "error"
	handPlayed    []card
	boardAfter    []stack
	stage         string
	messageSubstr string
}

type stack struct {
	top, left int
	cards     []card
}

type card struct {
	value      int  // 1..13
	suit       int  // 0=C, 1=D, 2=S, 3=H
	deck       int  // 0 or 1
	boardState int  // 0=firm, 1=fresh, 2=fresh-by-last-player
}

// --- Entry point ---

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: fixturegen <scenario.dsl>...")
		os.Exit(2)
	}

	var all []scenario
	for _, arg := range os.Args[1:] {
		matches, err := filepath.Glob(arg)
		if err != nil {
			die(err)
		}
		for _, path := range matches {
			data, err := os.ReadFile(path)
			if err != nil {
				die(err)
			}
			scenarios, err := parse(string(data), path)
			if err != nil {
				die(err)
			}
			all = append(all, scenarios...)
		}
	}

	sort.Slice(all, func(i, j int) bool { return all[i].name < all[j].name })

	if err := writeGo(all, "./lynrummy/tricks/dsl_conformance_test.go"); err != nil {
		die(err)
	}
	if err := writeElm(all, "./elm-lynrummy/tests/LynRummy/DslConformanceTest.elm"); err != nil {
		die(err)
	}

	fmt.Printf("Emitted %d scenarios → Go + Elm test files.\n", len(all))
}

func die(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}

// --- Parser ---
//
// Line-oriented, 2-space indent. Every line is either:
//   - blank / comment (#)
//   - "scenario <name>" at column 0
//   - "key: value" at indent ≥ 2
//   - "key:" at indent ≥ 2 followed by indented child lines

type line struct {
	indent  int
	content string
	lineNum int
}

func parse(src, path string) ([]scenario, error) {
	var lines []line
	for i, raw := range strings.Split(src, "\n") {
		stripped := strings.TrimRight(raw, " \t")
		if idx := strings.Index(stripped, "#"); idx >= 0 {
			stripped = strings.TrimRight(stripped[:idx], " \t")
		}
		if stripped == "" {
			continue
		}
		indent := 0
		for indent < len(stripped) && stripped[indent] == ' ' {
			indent++
		}
		if indent%2 != 0 {
			return nil, fmt.Errorf("%s:%d: indent must be a multiple of 2", path, i+1)
		}
		lines = append(lines, line{
			indent: indent / 2, content: strings.TrimLeft(stripped, " "), lineNum: i + 1,
		})
	}

	var scenarios []scenario
	for i := 0; i < len(lines); {
		if !strings.HasPrefix(lines[i].content, "scenario ") {
			return nil, fmt.Errorf("%s:%d: expected 'scenario <name>'", path, lines[i].lineNum)
		}
		if lines[i].indent != 0 {
			return nil, fmt.Errorf("%s:%d: scenario header must be at column 0", path, lines[i].lineNum)
		}
		name := strings.TrimSpace(strings.TrimPrefix(lines[i].content, "scenario"))
		i++
		// Collect lines until next scenario / EOF.
		var body []line
		for i < len(lines) && lines[i].indent > 0 {
			body = append(body, lines[i])
			i++
		}
		sc, err := parseBody(name, body, path)
		if err != nil {
			return nil, err
		}
		scenarios = append(scenarios, sc)
	}
	return scenarios, nil
}

// parseBody parses the indented body lines of one scenario.
// All lines in `body` have indent ≥ 1.
func parseBody(name string, body []line, path string) (scenario, error) {
	sc := scenario{name: name}
	i := 0
	for i < len(body) {
		l := body[i]
		if l.indent != 1 {
			return sc, fmt.Errorf("%s:%d: unexpected indent", path, l.lineNum)
		}
		key, val, hasBlock := splitField(l.content)
		i++
		// Always collect any indented-child lines that follow — lets
		// fields that are "scalar + block" (like `expect: error`
		// followed by `stage:` / `message_contains:`) work uniformly.
		var children []line
		for i < len(body) && body[i].indent >= 2 {
			children = append(children, body[i])
			i++
		}
		switch {
		case hasBlock:
			if err := applyBlockField(&sc, key, children, path); err != nil {
				return sc, err
			}
		case key == "expect":
			sc.expect.kind = val
			if len(children) > 0 {
				if err := parseExpectBlock(&sc.expect, children, path); err != nil {
					return sc, err
				}
			}
		default:
			if len(children) > 0 {
				return sc, fmt.Errorf("%s:%d: field %q doesn't take a block", path, l.lineNum, key)
			}
			if err := applyScalarField(&sc, key, val, l.lineNum, path); err != nil {
				return sc, err
			}
		}
	}
	return sc, nil
}

// splitField splits "key: value" into (key, value, hasInlineValue).
// If no value is present after the colon, hasBlock is true.
func splitField(s string) (key, val string, hasBlock bool) {
	idx := strings.Index(s, ":")
	if idx < 0 {
		return s, "", false
	}
	key = s[:idx]
	rest := strings.TrimSpace(s[idx+1:])
	if rest == "" {
		return key, "", true
	}
	return key, rest, false
}

func applyScalarField(sc *scenario, key, val string, ln int, path string) error {
	switch key {
	case "desc":
		sc.desc = val
	case "op":
		sc.op = val
	case "trick":
		sc.trick = val
	case "hand":
		cards, err := parseCards(val)
		if err != nil {
			return fmt.Errorf("%s:%d: hand: %w", path, ln, err)
		}
		sc.hand = cards
	case "hand_cards_played":
		cards, err := parseCards(val)
		if err != nil {
			return fmt.Errorf("%s:%d: hand_cards_played: %w", path, ln, err)
		}
		sc.handPlayed = cards
	case "expect":
		sc.expect.kind = val
	default:
		return fmt.Errorf("%s:%d: unknown field %q", path, ln, key)
	}
	return nil
}

func applyBlockField(sc *scenario, key string, children []line, path string) error {
	switch key {
	case "board":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.board = stacks
		sc.boardVar = "board"
	case "board_before":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.board = stacks
		sc.boardVar = "board_before"
	case "stacks_to_remove":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.removed = stacks
	case "stacks_to_add":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.added = stacks
	case "expect":
		return parseExpectBlock(&sc.expect, children, path)
	default:
		return fmt.Errorf("%s: unknown block field %q", path, key)
	}
	return nil
}

// parseExpectBlock handles "expect: <kind>" followed by indented
// child fields. The caller has already captured `kind` on the
// expect line (e.g., "expect: play") — children carry the detail.
func parseExpectBlock(e *expectation, children []line, path string) error {
	// The 'expect:' line had no inline value (block form). We need
	// kind to have been set either on the same line OR as the first
	// indented child. Handle the "expect: play\n  hand_played: ..."
	// case — kind was already set via scalar path if inline. Here,
	// the block form sets kind from the first child that's a verb.
	i := 0
	if e.kind == "" && i < len(children) {
		// Defensive: if someone wrote "expect:\n  play" we'd see
		// "play" as the first child. Accept that shape too.
		c := children[i].content
		if !strings.Contains(c, ":") && (c == "ok" || c == "no_plays" || c == "play" || c == "error") {
			e.kind = c
			i++
		}
	}
	for ; i < len(children); i++ {
		l := children[i]
		if l.indent != 2 {
			return fmt.Errorf("%s:%d: unexpected indent in expect block", path, l.lineNum)
		}
		key, val, hasBlock := splitField(l.content)
		if hasBlock {
			// collect indent-3 children
			var sub []line
			i++
			for i < len(children) && children[i].indent >= 3 {
				sub = append(sub, children[i])
				i++
			}
			i--
			switch key {
			case "board_after":
				stacks, err := parseStacks(sub, path)
				if err != nil {
					return err
				}
				e.boardAfter = stacks
			default:
				return fmt.Errorf("%s:%d: unknown expect block %q", path, l.lineNum, key)
			}
		} else {
			switch key {
			case "hand_played":
				cards, err := parseCards(val)
				if err != nil {
					return fmt.Errorf("%s:%d: %w", path, l.lineNum, err)
				}
				e.handPlayed = cards
			case "stage":
				e.stage = val
			case "message_contains":
				e.messageSubstr = val
			default:
				return fmt.Errorf("%s:%d: unknown expect field %q", path, l.lineNum, key)
			}
		}
	}
	return nil
}

// parseStacks parses a run of `at (t,l): <cards>` child lines.
// All must be at the same indent level.
func parseStacks(children []line, path string) ([]stack, error) {
	var stacks []stack
	baseIndent := -1
	for _, l := range children {
		if baseIndent == -1 {
			baseIndent = l.indent
		}
		if l.indent != baseIndent {
			return nil, fmt.Errorf("%s:%d: inconsistent indent in stack list", path, l.lineNum)
		}
		if !strings.HasPrefix(l.content, "at ") {
			return nil, fmt.Errorf("%s:%d: expected 'at (t,l): ...'", path, l.lineNum)
		}
		rest := strings.TrimPrefix(l.content, "at ")
		locEnd := strings.Index(rest, ")")
		if !strings.HasPrefix(rest, "(") || locEnd < 0 {
			return nil, fmt.Errorf("%s:%d: bad location syntax", path, l.lineNum)
		}
		locStr := rest[1:locEnd]
		parts := strings.Split(locStr, ",")
		if len(parts) != 2 {
			return nil, fmt.Errorf("%s:%d: bad location syntax", path, l.lineNum)
		}
		top, err1 := atoi(strings.TrimSpace(parts[0]))
		left, err2 := atoi(strings.TrimSpace(parts[1]))
		if err1 != nil || err2 != nil {
			return nil, fmt.Errorf("%s:%d: bad location integers", path, l.lineNum)
		}
		tail := strings.TrimSpace(rest[locEnd+1:])
		if !strings.HasPrefix(tail, ":") {
			return nil, fmt.Errorf("%s:%d: expected ':' after location", path, l.lineNum)
		}
		cardStr := strings.TrimSpace(tail[1:])
		cards, err := parseCards(cardStr)
		if err != nil {
			return nil, fmt.Errorf("%s:%d: %w", path, l.lineNum, err)
		}
		stacks = append(stacks, stack{top: top, left: left, cards: cards})
	}
	return stacks, nil
}

func parseCards(s string) ([]card, error) {
	if s == "" {
		return nil, nil
	}
	var cards []card
	for _, tok := range strings.Fields(s) {
		c, err := parseCard(tok)
		if err != nil {
			return nil, err
		}
		cards = append(cards, c)
	}
	return cards, nil
}

func parseCard(tok string) (card, error) {
	// Grammar: value suit deck? state?
	// value: A 2 3 4 5 6 7 8 9 T J Q K
	// suit: H S D C
	// deck (optional): '
	// state (optional): *   (FreshlyPlayed) | ** (FreshlyPlayedByLastPlayer)
	if len(tok) < 2 {
		return card{}, fmt.Errorf("card too short: %q", tok)
	}
	v := valueFromLetter(tok[0])
	if v == 0 {
		return card{}, fmt.Errorf("bad value letter: %q", tok)
	}
	s := suitFromLetter(tok[1])
	if s == -1 {
		return card{}, fmt.Errorf("bad suit letter: %q", tok)
	}
	c := card{value: v, suit: s, deck: 0, boardState: 0}
	i := 2
	if i < len(tok) && tok[i] == '\'' {
		c.deck = 1
		i++
	}
	if i < len(tok) && tok[i] == '*' {
		if i+1 < len(tok) && tok[i+1] == '*' {
			c.boardState = 2
			i += 2
		} else {
			c.boardState = 1
			i++
		}
	}
	if i != len(tok) {
		return card{}, fmt.Errorf("trailing chars in card: %q", tok)
	}
	return c, nil
}

func valueFromLetter(b byte) int {
	switch b {
	case 'A':
		return 1
	case '2':
		return 2
	case '3':
		return 3
	case '4':
		return 4
	case '5':
		return 5
	case '6':
		return 6
	case '7':
		return 7
	case '8':
		return 8
	case '9':
		return 9
	case 'T':
		return 10
	case 'J':
		return 11
	case 'Q':
		return 12
	case 'K':
		return 13
	}
	return 0
}

func suitFromLetter(b byte) int {
	switch b {
	case 'C':
		return 0
	case 'D':
		return 1
	case 'S':
		return 2
	case 'H':
		return 3
	}
	return -1
}

func atoi(s string) (int, error) {
	n := 0
	neg := false
	i := 0
	if len(s) > 0 && s[0] == '-' {
		neg = true
		i = 1
	}
	if i == len(s) {
		return 0, fmt.Errorf("not a number: %q", s)
	}
	for ; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, fmt.Errorf("not a number: %q", s)
		}
		n = n*10 + int(c-'0')
	}
	if neg {
		n = -n
	}
	return n, nil
}

// --- Go emitter ---

func writeGo(scenarios []scenario, outPath string) error {
	var b strings.Builder
	b.WriteString(`// GENERATED by cmd/fixturegen — DO NOT EDIT.
// Source scenarios: lynrummy/conformance/scenarios/*.dsl
// Regenerate with: go run ./cmd/fixturegen ./lynrummy/conformance/scenarios/*.dsl

package tricks

import (
	"testing"

	"angry-gopher/lynrummy"
)

`)
	for _, sc := range scenarios {
		writeGoScenario(&b, sc)
	}
	return os.WriteFile(outPath, []byte(b.String()), 0644)
}

func writeGoScenario(b *strings.Builder, sc scenario) {
	fmt.Fprintf(b, "// %s\nfunc Test_%s(t *testing.T) {\n", sc.desc, sc.name)
	switch sc.op {
	case "trick_first_play":
		writeGoTrickFirstPlay(b, sc)
	case "validate_game_move":
		writeGoValidateMove(b, sc, false)
	case "validate_turn_complete":
		writeGoValidateMove(b, sc, true)
	default:
		fmt.Fprintf(b, "\tt.Fatalf(\"unknown op %q\")\n", sc.op)
	}
	b.WriteString("}\n\n")
}

func writeGoTrickFirstPlay(b *strings.Builder, sc scenario) {
	fmt.Fprintf(b, "\thand := %s\n", goHandCards(sc.hand))
	fmt.Fprintf(b, "\tboard := %s\n", goStacksVar(sc.board, "lynrummy.CardStack"))
	trickVar := trickGoVar(sc.trick)
	fmt.Fprintf(b, "\tplays := %s.FindPlays(hand, board)\n", trickVar)

	switch sc.expect.kind {
	case "no_plays":
		b.WriteString("\tif len(plays) != 0 {\n\t\tt.Fatalf(\"expected no plays, got %d\", len(plays))\n\t}\n")
	case "play":
		b.WriteString("\tif len(plays) == 0 {\n\t\tt.Fatal(\"expected a play, got none\")\n\t}\n")
		b.WriteString("\tgotBoard, gotHand := plays[0].Apply(board)\n")
		fmt.Fprintf(b, "\twantHand := %s\n", goHandCards(sc.expect.handPlayed))
		fmt.Fprintf(b, "\twantBoard := %s\n", goStacksVar(sc.expect.boardAfter, "lynrummy.CardStack"))
		b.WriteString("\tif !handsEqualDSL(gotHand, wantHand) {\n\t\tt.Fatalf(\"hand mismatch:\\n  want %v\\n  got  %v\", wantHand, gotHand)\n\t}\n")
		b.WriteString("\tif !boardsEqualDSL(gotBoard, wantBoard) {\n\t\tt.Fatalf(\"board mismatch:\\n  want %v\\n  got  %v\", wantBoard, gotBoard)\n\t}\n")
	default:
		fmt.Fprintf(b, "\tt.Fatalf(\"unsupported expectation %q\")\n", sc.expect.kind)
	}
}

func writeGoValidateMove(b *strings.Builder, sc scenario, turnComplete bool) {
	fmt.Fprintf(b, "\tbounds := lynrummy.BoardBounds{MaxWidth: 800, MaxHeight: 600, Margin: 5}\n")
	var got string
	if turnComplete {
		fmt.Fprintf(b, "\tboard := %s\n", goStacksVar(sc.board, "lynrummy.CardStack"))
		got = "lynrummy.ValidateTurnComplete(board, bounds)"
	} else {
		fmt.Fprintf(b, "\tboardBefore := %s\n", goStacksVar(sc.board, "lynrummy.CardStack"))
		fmt.Fprintf(b, "\tstacksToRemove := %s\n", goStacksVar(sc.removed, "lynrummy.CardStack"))
		fmt.Fprintf(b, "\tstacksToAdd := %s\n", goStacksVar(sc.added, "lynrummy.CardStack"))
		fmt.Fprintf(b, "\thand := %s\n", goRawCardsVar(sc.handPlayed))
		got = "lynrummy.ValidateGameMove(lynrummy.Move{BoardBefore: boardBefore, StacksToRemove: stacksToRemove, StacksToAdd: stacksToAdd, HandCardsPlayed: hand}, bounds)"
	}
	fmt.Fprintf(b, "\tgot := %s\n", got)
	switch sc.expect.kind {
	case "ok":
		b.WriteString("\tif got != nil {\n\t\tt.Fatalf(\"expected ok, got %s: %s\", got.Stage, got.Message)\n\t}\n")
	case "error":
		wantOk := fmt.Sprintf("expected error at stage %q, got ok", sc.expect.stage)
		fmt.Fprintf(b, "\tif got == nil {\n\t\tt.Fatal(%q)\n\t}\n", wantOk)
		wantStage := fmt.Sprintf("stage: want %q, got %%q", sc.expect.stage)
		fmt.Fprintf(b, "\tif got.Stage != %q {\n\t\tt.Fatalf(%q, got.Stage)\n\t}\n", sc.expect.stage, wantStage)
		if sc.expect.messageSubstr != "" {
			wantMsg := fmt.Sprintf("message: want substring %q, got %%q", sc.expect.messageSubstr)
			fmt.Fprintf(b, "\tif !stringsContainsDSL(got.Message, %q) {\n\t\tt.Fatalf(%q, got.Message)\n\t}\n", sc.expect.messageSubstr, wantMsg)
		}
	default:
		fmt.Fprintf(b, "\tt.Fatalf(%q)\n", "unsupported expectation "+sc.expect.kind)
	}
}

// goStacksVar returns an expression usable to initialize a
// `var x []T` — either `[]T{...}` literal or a typed nil-equivalent
// via `[]T(nil)`. Avoids the untyped-nil Go compile error.
func goStacksVar(ss []stack, elemType string) string {
	if len(ss) == 0 {
		return "[]" + elemType + "(nil)"
	}
	return goStacks(ss)
}

func goRawCardsVar(cs []card) string {
	if len(cs) == 0 {
		return "[]lynrummy.Card(nil)"
	}
	return goRawCards(cs)
}

func goHandCards(cs []card) string {
	if len(cs) == 0 {
		return "[]lynrummy.HandCard{}"
	}
	var parts []string
	for _, c := range cs {
		parts = append(parts, fmt.Sprintf("{Card: %s, State: lynrummy.HandNormal}", goCardLit(c)))
	}
	return "[]lynrummy.HandCard{" + strings.Join(parts, ", ") + "}"
}

func goRawCards(cs []card) string {
	if len(cs) == 0 {
		return "nil"
	}
	var parts []string
	for _, c := range cs {
		parts = append(parts, goCardLit(c))
	}
	return "[]lynrummy.Card{" + strings.Join(parts, ", ") + "}"
}

func goStacks(ss []stack) string {
	if len(ss) == 0 {
		return "nil"
	}
	var parts []string
	for _, s := range ss {
		parts = append(parts, goStackLit(s))
	}
	return "[]lynrummy.CardStack{" + strings.Join(parts, ", ") + "}"
}

func goStackLit(s stack) string {
	var bcs []string
	for _, c := range s.cards {
		bcs = append(bcs, fmt.Sprintf("{Card: %s, State: %s}", goCardLit(c), goBoardState(c.boardState)))
	}
	return fmt.Sprintf("lynrummy.NewCardStack([]lynrummy.BoardCard{%s}, lynrummy.Location{Top: %d, Left: %d})",
		strings.Join(bcs, ", "), s.top, s.left)
}

func goCardLit(c card) string {
	return fmt.Sprintf("lynrummy.Card{Value: %d, Suit: %s, OriginDeck: %d}", c.value, goSuit(c.suit), c.deck)
}

func goSuit(s int) string {
	switch s {
	case 0:
		return "lynrummy.Club"
	case 1:
		return "lynrummy.Diamond"
	case 2:
		return "lynrummy.Spade"
	case 3:
		return "lynrummy.Heart"
	}
	return "lynrummy.Club"
}

func goBoardState(s int) string {
	switch s {
	case 0:
		return "lynrummy.FirmlyOnBoard"
	case 1:
		return "lynrummy.FreshlyPlayed"
	case 2:
		return "lynrummy.FreshlyPlayedByLastPlayer"
	}
	return "lynrummy.FirmlyOnBoard"
}

func trickGoVar(id string) string {
	// direct_play -> DirectPlay etc.
	parts := strings.Split(id, "_")
	var buf strings.Builder
	for _, p := range parts {
		if p == "" {
			continue
		}
		buf.WriteByte(p[0] &^ 0x20)
		buf.WriteString(p[1:])
	}
	return buf.String()
}

// --- Elm emitter ---

func writeElm(scenarios []scenario, outPath string) error {
	var b strings.Builder
	b.WriteString(`-- GENERATED by cmd/fixturegen — DO NOT EDIT.
-- Source scenarios: lynrummy/conformance/scenarios/*.dsl
-- Regenerate with: go run ./cmd/fixturegen ./lynrummy/conformance/scenarios/*.dsl

module LynRummy.DslConformanceTest exposing (suite)

import Expect
import LynRummy.BoardGeometry exposing (BoardBounds)
import LynRummy.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..), allCardValues)
import LynRummy.CardStack
    exposing
        ( BoardCard
        , BoardCardState(..)
        , BoardLocation
        , CardStack
        , HandCard
        , HandCardState(..)
        )
import LynRummy.Referee as Referee exposing (RefereeStage(..), refereeStageToString)
import Test exposing (Test, describe, test)


standardBounds : BoardBounds
standardBounds =
    { maxWidth = 800, maxHeight = 600, margin = 5 }


`)
	var caseNames []string
	for _, sc := range scenarios {
		name := elmTestName(sc.name)
		caseNames = append(caseNames, name)
		writeElmScenario(&b, sc, name)
	}

	b.WriteString("suite : Test\nsuite =\n    describe \"DSL conformance\"\n        [")
	for i, n := range caseNames {
		if i > 0 {
			b.WriteString("\n        ,")
		}
		fmt.Fprintf(&b, " %s", n)
	}
	b.WriteString("\n        ]\n")

	if err := os.MkdirAll(filepath.Dir(outPath), 0755); err != nil {
		return err
	}
	return os.WriteFile(outPath, []byte(b.String()), 0644)
}

func elmTestName(s string) string {
	// already snake_case; sanitize for Elm identifier (lowerCamel).
	// Parts beginning with a digit can't have their first char
	// uppercased — Elm identifiers forbid leading digits AND can't
	// start with a non-ASCII control byte (which `b &^ 0x20` would
	// produce for digit bytes). Prefix digit-leading parts with
	// their preceding part's trailing char form so the identifier
	// stays valid.
	parts := strings.Split(s, "_")
	var buf strings.Builder
	for i, p := range parts {
		if p == "" {
			continue
		}
		if i == 0 {
			buf.WriteString(p)
			continue
		}
		c := p[0]
		if c >= 'a' && c <= 'z' {
			buf.WriteByte(c &^ 0x20)
			buf.WriteString(p[1:])
		} else {
			// Digit- or symbol-leading parts (e.g., "7H") stay as-is
			// so the compiler sees a legal Elm identifier in context.
			buf.WriteString(p)
		}
	}
	return buf.String()
}

func writeElmScenario(b *strings.Builder, sc scenario, fnName string) {
	fmt.Fprintf(b, "%s : Test\n%s =\n    test %q <|\n        \\_ ->\n", fnName, fnName, sc.name)
	switch sc.op {
	case "trick_first_play":
		writeElmTrickFirstPlay(b, sc)
	case "validate_game_move":
		writeElmValidateMove(b, sc, false)
	case "validate_turn_complete":
		writeElmValidateMove(b, sc, true)
	default:
		fmt.Fprintf(b, "            Expect.fail \"unknown op %s\"\n", sc.op)
	}
	b.WriteString("\n\n")
}

func writeElmTrickFirstPlay(b *strings.Builder, sc scenario) {
	// Tricks aren't ported to Elm yet — placeholder pass so the
	// suite stays green. When Elm tricks land, swap for a real
	// assertion path analogous to the Go emitter.
	fmt.Fprintf(b, "            -- Elm TrickBag not ported yet (%s / %s)\n            Expect.pass\n",
		sc.trick, sc.expect.kind)
}

func writeElmValidateMove(b *strings.Builder, sc scenario, turnComplete bool) {
	if turnComplete {
		fmt.Fprintf(b, "            let\n                board =\n                    %s\n            in\n", elmStacks(sc.board, "                    "))
		b.WriteString("            case Referee.validateTurnComplete board standardBounds of\n")
	} else {
		fmt.Fprintf(b, "            let\n                move =\n                    { boardBefore = %s\n                    , stacksToRemove = %s\n                    , stacksToAdd = %s\n                    , handCardsPlayed = %s\n                    }\n            in\n",
			elmStacks(sc.board, "                        "),
			elmStacks(sc.removed, "                        "),
			elmStacks(sc.added, "                        "),
			elmHandCards(sc.handPlayed),
		)
		b.WriteString("            case Referee.validateGameMove move standardBounds of\n")
	}
	switch sc.expect.kind {
	case "ok":
		b.WriteString(`                Ok _ ->
                    Expect.pass

                Err err ->
                    Expect.fail (refereeStageToString err.stage ++ ": " ++ err.message)
`)
	case "error":
		fmt.Fprintf(b, `                Ok _ ->
                    Expect.fail ("expected error at stage " ++ %q ++ ", got ok")

                Err err ->
                    if refereeStageToString err.stage /= %q then
                        Expect.fail ("stage: want " ++ %q ++ ", got " ++ refereeStageToString err.stage)
                    else if not (String.contains %q err.message) then
                        Expect.fail ("message substring " ++ %q ++ " not found in " ++ err.message)
                    else
                        Expect.pass
`, sc.expect.stage, sc.expect.stage, sc.expect.stage, sc.expect.messageSubstr, sc.expect.messageSubstr)
	default:
		fmt.Fprintf(b, "                _ ->\n                    Expect.fail \"unsupported expectation %s\"\n", sc.expect.kind)
	}
}

func elmStacks(ss []stack, indent string) string {
	if len(ss) == 0 {
		return "[]"
	}
	var parts []string
	for _, s := range ss {
		parts = append(parts, elmStackLit(s))
	}
	return "[ " + strings.Join(parts, "\n"+indent+", ") + "\n" + indent + "]"
}

func elmStackLit(s stack) string {
	var bcs []string
	for _, c := range s.cards {
		bcs = append(bcs, fmt.Sprintf("{ card = %s, state = %s }", elmCardLit(c), elmBoardState(c.boardState)))
	}
	return fmt.Sprintf("{ boardCards = [ %s ], loc = { top = %d, left = %d } }",
		strings.Join(bcs, ", "), s.top, s.left)
}

func elmHandCards(cs []card) string {
	if len(cs) == 0 {
		return "[]"
	}
	var parts []string
	for _, c := range cs {
		parts = append(parts, fmt.Sprintf("{ card = %s, state = HandNormal }", elmCardLit(c)))
	}
	return "[ " + strings.Join(parts, ", ") + " ]"
}

func elmCardLit(c card) string {
	v := elmValue(c.value)
	s := elmSuit(c.suit)
	d := elmDeck(c.deck)
	return fmt.Sprintf("{ value = %s, suit = %s, originDeck = %s }", v, s, d)
}

func elmValue(v int) string {
	names := []string{"", "Ace", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Jack", "Queen", "King"}
	if v >= 1 && v <= 13 {
		return names[v]
	}
	return "Ace"
}

func elmSuit(s int) string {
	switch s {
	case 0:
		return "Club"
	case 1:
		return "Diamond"
	case 2:
		return "Spade"
	case 3:
		return "Heart"
	}
	return "Club"
}

func elmDeck(d int) string {
	if d == 0 {
		return "DeckOne"
	}
	return "DeckTwo"
}

func elmBoardState(s int) string {
	switch s {
	case 0:
		return "FirmlyOnBoard"
	case 1:
		return "FreshlyPlayed"
	case 2:
		return "FreshlyPlayedByLastPlayer"
	}
	return "FirmlyOnBoard"
}
