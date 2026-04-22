// fixturegen: parse a LynRummy-DSL scenario file and emit native
// test code for Go + Elm.
//
// Pipeline (template-driven):
//   parse .dsl → AST → render templates → goimports+gofmt → write
//   → go build verify → idempotence check
//
// Usage:
//   go run ./cmd/fixturegen ./lynrummy/conformance/scenarios/*.dsl

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/format"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"text/template"

	"golang.org/x/tools/imports"
)

// --- AST (exported fields so text/template can access them) ---

type Scenario struct {
	Name       string
	Desc       string
	Op         string
	Trick      string
	Hand       []Card
	BoardVar   string
	Board      []Stack
	Removed    []Stack
	Added      []Stack
	HandPlayed []Card
	Expect     Expectation
}

type Expectation struct {
	Kind          string
	HandPlayed    []Card
	BoardAfter    []Stack
	Stage         string
	MessageSubstr string
	Suggestions   []ExpectedSuggestion // expect: suggestions
}

// ExpectedSuggestion — one row inside an `expect: suggestions`
// block. Carries the trick_id we expect and the hand cards the
// top Play should reference. Rank is inferred from list order.
type ExpectedSuggestion struct {
	TrickID   string
	HandCards []Card
}

type Stack struct {
	Top, Left int
	Cards     []Card
}

type Card struct {
	Value      int
	Suit       int
	Deck       int
	BoardState int
}

// --- Entry point ---

const (
	goOutPath   = "./games/lynrummy/referee_conformance_test.go"
	elmOutPath  = "./games/lynrummy/elm/tests/Game/DslConformanceTest.elm"
	jsonOutPath = "./games/lynrummy/python/conformance_fixtures.json"
	goPackage   = "./games/lynrummy/..."
)

// goSupportedOps — the subset of scenario ops the Go emitter
// targets. Go owns the referee; hints live in Elm + Python only
// (hints-are-client-side, per project memory). Scenarios whose
// ops are not listed here are skipped by emitGo and routed to
// other targets instead.
var goSupportedOps = map[string]bool{
	"validate_game_move":     true,
	"validate_turn_complete": true,
}

// pythonSupportedOps — the subset of scenario ops the JSON
// fixtures target. Python is interpreted: the runner reads the
// JSON at run time and dispatches per op. No Python codegen.
var pythonSupportedOps = map[string]bool{
	"build_suggestions": true,
	"hint_invariant":    true,
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: fixturegen <scenario.dsl>...")
		os.Exit(2)
	}

	var all []Scenario
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

	sort.Slice(all, func(i, j int) bool { return all[i].Name < all[j].Name })

	if err := emitGo(all, goOutPath); err != nil {
		die(fmt.Errorf("go emit: %w", err))
	}
	if err := emitElm(all, elmOutPath); err != nil {
		die(fmt.Errorf("elm emit: %w", err))
	}
	if err := emitJSON(all, jsonOutPath); err != nil {
		die(fmt.Errorf("json emit: %w", err))
	}

	// Build-gate: the real compiler tells us instantly if the
	// generator produced invalid code.
	if err := runGoBuild(); err != nil {
		die(fmt.Errorf("generated Go didn't build:\n%w", err))
	}

	// Idempotence: regen and diff; a clean generator never produces
	// different output for the same input.
	if err := checkIdempotence(all); err != nil {
		die(fmt.Errorf("regen not idempotent: %w", err))
	}

	fmt.Printf("Emitted %d scenarios → Go + Elm test files + JSON fixtures (built + idempotent).\n", len(all))
}

func die(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}

// --- Post-process pipeline ---

// writeGoFile formats + imports-resolves + writes Go source.
// The emitter emits raw code without an import block; imports
// adds what's needed from context. gofmt happens as part of
// imports.Process.
func writeGoFile(path string, src []byte) error {
	formatted, err := imports.Process(path, src, &imports.Options{
		Comments:  true,
		TabIndent: true,
		TabWidth:  8,
	})
	if err != nil {
		// Fall back to plain gofmt so we can see what we wrote.
		_ = os.WriteFile(path+".raw", src, 0644)
		return fmt.Errorf("goimports: %w (raw saved to %s.raw)", err, path)
	}
	return os.WriteFile(path, formatted, 0644)
}

// writeElmFile is the Elm equivalent — no auto-formatter dep in
// the Go tool, so we just write as-is. (elm-format could be
// shelled out later if we want; not wired today.)
func writeElmFile(path string, src []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	return os.WriteFile(path, src, 0644)
}

func runGoBuild() error {
	cmd := exec.Command("go", "build", goPackage)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s\n%s", err, out)
	}
	return nil
}

func checkIdempotence(all []Scenario) error {
	originalGo, err := os.ReadFile(goOutPath)
	if err != nil {
		return err
	}
	originalElm, err := os.ReadFile(elmOutPath)
	if err != nil {
		return err
	}
	originalJSON, err := os.ReadFile(jsonOutPath)
	if err != nil {
		return err
	}
	if err := emitGo(all, goOutPath); err != nil {
		return err
	}
	if err := emitElm(all, elmOutPath); err != nil {
		return err
	}
	if err := emitJSON(all, jsonOutPath); err != nil {
		return err
	}
	afterGo, _ := os.ReadFile(goOutPath)
	afterElm, _ := os.ReadFile(elmOutPath)
	afterJSON, _ := os.ReadFile(jsonOutPath)
	if !bytes.Equal(originalGo, afterGo) {
		return fmt.Errorf("Go output differs on second regen")
	}
	if !bytes.Equal(originalElm, afterElm) {
		return fmt.Errorf("Elm output differs on second regen")
	}
	if !bytes.Equal(originalJSON, afterJSON) {
		return fmt.Errorf("JSON output differs on second regen")
	}
	return nil
}

// --- Go emission (template-based) ---

const goTemplate = `// GENERATED by cmd/fixturegen — DO NOT EDIT.
// Source scenarios: lynrummy/conformance/scenarios/*.dsl
// Regenerate with: go run ./cmd/fixturegen ./lynrummy/conformance/scenarios/*.dsl

package lynrummy

import (
	"testing"
)

{{range .}}// {{.Desc}}
func Test_{{.Name}}(t *testing.T) {
{{goScenarioBody .}}}

{{end}}`

func emitGo(scenarios []Scenario, outPath string) error {
	var filtered []Scenario
	for _, sc := range scenarios {
		if goSupportedOps[sc.Op] {
			filtered = append(filtered, sc)
		}
	}
	t := template.New("go").Funcs(goFuncs())
	if _, err := t.Parse(goTemplate); err != nil {
		return err
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, filtered); err != nil {
		return err
	}
	return writeGoFile(outPath, buf.Bytes())
}

func goFuncs() template.FuncMap {
	return template.FuncMap{
		"goScenarioBody": goScenarioBody,
	}
}

// goScenarioBody emits the inside of a Test_ function. Go only
// targets the referee ops (see goSupportedOps). Hint scenarios
// are routed to Elm + Python instead.
func goScenarioBody(sc Scenario) string {
	var b strings.Builder
	switch sc.Op {
	case "validate_game_move":
		goValidateMove(&b, sc, false)
	case "validate_turn_complete":
		goValidateMove(&b, sc, true)
	default:
		fmt.Fprintf(&b, "\tt.Fatalf(%q)\n", "unknown op "+sc.Op)
	}
	return b.String()
}

func goValidateMove(b *strings.Builder, sc Scenario, turnComplete bool) {
	b.WriteString("\tbounds := BoardBounds{MaxWidth: 800, MaxHeight: 600, Margin: 5}\n")
	var call string
	if turnComplete {
		fmt.Fprintf(b, "\tboard := %s\n", goStacksVar(sc.Board))
		call = "ValidateTurnComplete(board, bounds)"
	} else {
		fmt.Fprintf(b, "\tboardBefore := %s\n", goStacksVar(sc.Board))
		fmt.Fprintf(b, "\tstacksToRemove := %s\n", goStacksVar(sc.Removed))
		fmt.Fprintf(b, "\tstacksToAdd := %s\n", goStacksVar(sc.Added))
		fmt.Fprintf(b, "\thand := %s\n", goRawCardsVar(sc.HandPlayed))
		call = "ValidateGameMove(Move{BoardBefore: boardBefore, StacksToRemove: stacksToRemove, StacksToAdd: stacksToAdd, HandCardsPlayed: hand}, bounds)"
	}
	fmt.Fprintf(b, "\tgot := %s\n", call)
	switch sc.Expect.Kind {
	case "ok":
		b.WriteString("\tif got != nil {\n\t\tt.Fatalf(\"expected ok, got %s: %s\", got.Stage, got.Message)\n\t}\n")
	case "error":
		fmt.Fprintf(b, "\tif got == nil {\n\t\tt.Fatal(%q)\n\t}\n",
			fmt.Sprintf("expected error at stage %q, got ok", sc.Expect.Stage))
		fmt.Fprintf(b, "\tif got.Stage != %q {\n\t\tt.Fatalf(%q, got.Stage)\n\t}\n",
			sc.Expect.Stage,
			fmt.Sprintf("stage: want %q, got %%q", sc.Expect.Stage))
		if sc.Expect.MessageSubstr != "" {
			fmt.Fprintf(b, "\tif !strings.Contains(got.Message, %q) {\n\t\tt.Fatalf(%q, got.Message)\n\t}\n",
				sc.Expect.MessageSubstr,
				fmt.Sprintf("message: want substring %q, got %%q", sc.Expect.MessageSubstr))
		}
	default:
		fmt.Fprintf(b, "\tt.Fatalf(%q)\n", "unsupported expectation "+sc.Expect.Kind)
	}
}

// --- Go value renderers ---
//
// Generated tests live inside package lynrummy, so types are
// referenced unqualified (no `lynrummy.` prefix).

func goHandCards(cs []Card) string {
	if len(cs) == 0 {
		return "[]HandCard{}"
	}
	var parts []string
	for _, c := range cs {
		parts = append(parts, fmt.Sprintf("{Card: %s, State: HandNormal}", goCardLit(c)))
	}
	return "[]HandCard{" + strings.Join(parts, ", ") + "}"
}

func goRawCardsVar(cs []Card) string {
	if len(cs) == 0 {
		return "[]Card(nil)"
	}
	var parts []string
	for _, c := range cs {
		parts = append(parts, goCardLit(c))
	}
	return "[]Card{" + strings.Join(parts, ", ") + "}"
}

func goStacksVar(ss []Stack) string {
	if len(ss) == 0 {
		return "[]CardStack(nil)"
	}
	var parts []string
	for _, s := range ss {
		parts = append(parts, goStackLit(s))
	}
	return "[]CardStack{" + strings.Join(parts, ", ") + "}"
}

func goStackLit(s Stack) string {
	var bcs []string
	for _, c := range s.Cards {
		bcs = append(bcs, fmt.Sprintf("{Card: %s, State: %s}", goCardLit(c), goBoardState(c.BoardState)))
	}
	return fmt.Sprintf("NewCardStack([]BoardCard{%s}, Location{Top: %d, Left: %d})",
		strings.Join(bcs, ", "), s.Top, s.Left)
}

func goCardLit(c Card) string {
	return fmt.Sprintf("Card{Value: %d, Suit: %s, OriginDeck: %d}", c.Value, goSuit(c.Suit), c.Deck)
}

func goSuit(s int) string {
	return []string{"Club", "Diamond", "Spade", "Heart"}[s]
}

func goBoardState(s int) string {
	return []string{"FirmlyOnBoard", "FreshlyPlayed", "FreshlyPlayedByLastPlayer"}[s]
}

// --- Elm emission (template-based) ---

const elmTemplate = `-- GENERATED by cmd/fixturegen — DO NOT EDIT.
-- Source scenarios: lynrummy/conformance/scenarios/*.dsl
-- Regenerate with: go run ./cmd/fixturegen ./lynrummy/conformance/scenarios/*.dsl

module Game.DslConformanceTest exposing (suite)

import Expect
import Game.BoardGeometry exposing (BoardBounds)
import Game.Card exposing (Card, CardValue(..), OriginDeck(..), Suit(..))
import Game.CardStack
    exposing
        ( BoardCard
        , BoardCardState(..)
        , BoardLocation
        , CardStack
        , HandCard
        , HandCardState(..)
        )
import Game.Referee as Referee exposing (RefereeStage(..), refereeStageToString)
import Game.StackType as StackType
import Game.Strategy.DirectPlay
import Game.Strategy.HandStacks
import Game.Strategy.Hint as Hint
import Game.Strategy.LooseCardPlay
import Game.Strategy.PairPeel
import Game.Strategy.PeelForRun
import Game.Strategy.RbSwap
import Game.Strategy.SplitForSet
import Test exposing (Test, describe, test)


standardBounds : BoardBounds
standardBounds =
    { maxWidth = 800, maxHeight = 600, margin = 5 }


-- Invariant check: every stack must classify as a complete group
-- (Set, PureRun, or RedBlackRun). Anything else (Incomplete /
-- Bogus / Dup) means the trick's emission broke the board.
isCleanStack : CardStack -> Bool
isCleanStack s =
    case StackType.getStackType (List.map .card s.boardCards) of
        StackType.Set ->
            True

        StackType.PureRun ->
            True

        StackType.RedBlackRun ->
            True

        _ ->
            False


firstIncompleteStack : List CardStack -> Maybe ( Int, CardStack )
firstIncompleteStack stacks =
    stacks
        |> List.indexedMap Tuple.pair
        |> List.filter (\( _, s ) -> not (isCleanStack s))
        |> List.head

{{range .}}

{{elmTestFn .}} : Test
{{elmTestFn .}} =
    test {{quote .Name}} <|
        \_ ->
{{elmScenarioBody .}}
{{end}}

suite : Test
suite =
    describe "DSL conformance"
        [ {{range $i, $sc := .}}{{if $i}}
        , {{end}}{{elmTestFn $sc}}{{end}}
        ]
`

func emitElm(scenarios []Scenario, outPath string) error {
	t := template.New("elm").Funcs(template.FuncMap{
		"elmTestFn":       elmTestFn,
		"elmScenarioBody": elmScenarioBody,
		"quote":           func(s string) string { return `"` + s + `"` },
	})
	if _, err := t.Parse(elmTemplate); err != nil {
		return err
	}
	var buf bytes.Buffer
	if err := t.Execute(&buf, scenarios); err != nil {
		return err
	}
	return writeElmFile(outPath, buf.Bytes())
}

func elmTestFn(sc Scenario) string {
	return elmTestName(sc.Name)
}

func elmTestName(s string) string {
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
			buf.WriteString(p)
		}
	}
	return buf.String()
}

// elmPortedTricks records which TS/Go tricks have a fully-ported
// Elm counterpart. Expand as more land in
// games/lynrummy/elm/src/Game/Strategy/. Scenarios for unported
// tricks stay as Expect.pass placeholders.
var elmPortedTricks = map[string]string{
	"direct_play":     "Game.Strategy.DirectPlay.trick",
	"hand_stacks":     "Game.Strategy.HandStacks.trick",
	"loose_card_play": "Game.Strategy.LooseCardPlay.trick",
	"pair_peel":       "Game.Strategy.PairPeel.trick",
	"peel_for_run":    "Game.Strategy.PeelForRun.trick",
	"rb_swap":         "Game.Strategy.RbSwap.trick",
	"split_for_set":   "Game.Strategy.SplitForSet.trick",
}

func elmScenarioBody(sc Scenario) string {
	var b strings.Builder
	switch sc.Op {
	case "trick_first_play":
		if trickVar, ok := elmPortedTricks[sc.Trick]; ok {
			elmTrickFirstPlay(&b, sc, trickVar)
		} else {
			fmt.Fprintf(&b, "            -- Elm TrickBag not ported yet (%s / %s)\n            Expect.pass", sc.Trick, sc.Expect.Kind)
		}
	case "validate_game_move":
		elmValidateMove(&b, sc, false)
	case "validate_turn_complete":
		elmValidateMove(&b, sc, true)
	case "build_suggestions":
		elmBuildSuggestions(&b, sc)
	case "hint_invariant":
		trickVar, ok := elmPortedTricks[sc.Trick]
		if !ok {
			fmt.Fprintf(&b, "            Expect.fail \"unknown trick %s\"", sc.Trick)
			return b.String()
		}
		elmHintInvariant(&b, sc, trickVar)
	default:
		fmt.Fprintf(&b, "            Expect.fail \"unknown op %s\"", sc.Op)
	}
	return b.String()
}


// elmHintInvariant emits a test body that runs the named trick
// against the scenario's (hand, board), applies the first Play,
// and asserts every resulting stack classifies as a complete
// group. An Elm Play's `apply` returns (newBoard, consumedHand)
// directly, so no primitive replay is needed.
func elmHintInvariant(b *strings.Builder, sc Scenario, trickVar string) {
	fmt.Fprintf(b, "            let\n                handCards =\n                    %s\n\n                board =\n                    %s\n\n                plays =\n                    %s.findPlays handCards board\n            in\n",
		elmHandCards(sc.Hand),
		elmStacks(sc.Board, "                        "),
		trickVar)
	b.WriteString(`            case plays of
                [] ->
                    Expect.fail "trick did not fire (no plays)"

                play :: _ ->
                    let
                        ( afterBoard, _ ) =
                            play.apply board
                    in
                    case firstIncompleteStack afterBoard of
                        Nothing ->
                            Expect.pass

                        Just ( i, s ) ->
                            Expect.fail
                                ("stack "
                                    ++ String.fromInt i
                                    ++ " is incomplete after trick emission: "
                                    ++ Debug.toString s
                                )`)
}


// elmBuildSuggestions emits a test body that calls
// Hint.buildSuggestions and walks each expected row in order,
// asserting trick_id + hand cards. Any mismatch short-circuits
// via Expect.fail with a descriptive message.
func elmBuildSuggestions(b *strings.Builder, sc Scenario) {
	fmt.Fprintf(b, "            let\n                handCards =\n                    %s\n\n                hand =\n                    { handCards = handCards }\n\n                board =\n                    %s\n\n                got =\n                    Hint.buildSuggestions hand board\n            in\n",
		elmHandCards(sc.Hand),
		elmStacks(sc.Board, "                        "))

	fmt.Fprintf(b, "            if List.length got /= %d then\n                Expect.fail (\"suggestion count: want %d, got \" ++ String.fromInt (List.length got))\n", len(sc.Expect.Suggestions), len(sc.Expect.Suggestions))
	b.WriteString("\n            else\n")
	if len(sc.Expect.Suggestions) == 0 {
		// No per-row assertions needed; count check is sufficient.
		b.WriteString("                Expect.pass")
		return
	}
	b.WriteString("                let\n")
	for i, sug := range sc.Expect.Suggestions {
		fmt.Fprintf(b, "                    want%d =\n                        { trickId = %q, handCards = %s }\n\n",
			i, sug.TrickID, elmRawCards(sug.HandCards))
	}
	b.WriteString("                in\n")
	b.WriteString("                Expect.all\n                    [")
	for i := range sc.Expect.Suggestions {
		if i > 0 {
			b.WriteString("\n                    ,")
		}
		fmt.Fprintf(b, " \\_ -> List.drop %d got |> List.head |> Maybe.map (\\s -> { trickId = s.trickId, handCards = s.handCards }) |> Expect.equal (Just want%d)", i, i)
	}
	b.WriteString("\n                    ]\n                    ()")
}


// elmRawCards renders a list of Card values (not HandCards).
// Reuses elmCardLit per card.
func elmRawCards(cs []Card) string {
	if len(cs) == 0 {
		return "[]"
	}
	var parts []string
	for _, c := range cs {
		parts = append(parts, elmCardLit(c))
	}
	return "[ " + strings.Join(parts, ", ") + " ]"
}

func elmTrickFirstPlay(b *strings.Builder, sc Scenario, trickVar string) {
	fmt.Fprintf(b, "            let\n                hand =\n                    %s\n\n                board =\n                    %s\n\n                plays =\n                    %s.findPlays hand board\n            in\n",
		elmHandCards(sc.Hand),
		elmStacks(sc.Board, "                        "),
		trickVar)
	switch sc.Expect.Kind {
	case "no_plays":
		b.WriteString(`            if not (List.isEmpty plays) then
                Expect.fail ("expected no plays, got " ++ String.fromInt (List.length plays))

            else
                Expect.pass`)
	case "play":
		fmt.Fprintf(b, `            case plays of
                [] ->
                    Expect.fail "expected a play, got none"

                play :: _ ->
                    let
                        ( gotBoard, gotHand ) =
                            play.apply board

                        wantHand =
                            %s

                        wantBoard =
                            %s
                    in
                    if gotHand /= wantHand then
                        Expect.fail ("hand mismatch:\n  want " ++ Debug.toString wantHand ++ "\n  got  " ++ Debug.toString gotHand)

                    else if gotBoard /= wantBoard then
                        Expect.fail ("board mismatch:\n  want " ++ Debug.toString wantBoard ++ "\n  got  " ++ Debug.toString gotBoard)

                    else
                        Expect.pass`,
			elmHandCards(sc.Expect.HandPlayed),
			elmStacks(sc.Expect.BoardAfter, "                            "))
	default:
		fmt.Fprintf(b, "            Expect.fail \"unsupported expectation: %s\"", sc.Expect.Kind)
	}
}

func elmValidateMove(b *strings.Builder, sc Scenario, turnComplete bool) {
	if turnComplete {
		fmt.Fprintf(b, "            let\n                board =\n                    %s\n            in\n", elmStacks(sc.Board, "                    "))
		b.WriteString("            case Referee.validateTurnComplete board standardBounds of\n")
	} else {
		fmt.Fprintf(b, "            let\n                move =\n                    { boardBefore = %s\n                    , stacksToRemove = %s\n                    , stacksToAdd = %s\n                    , handCardsPlayed = %s\n                    }\n            in\n",
			elmStacks(sc.Board, "                        "),
			elmStacks(sc.Removed, "                        "),
			elmStacks(sc.Added, "                        "),
			elmHandCards(sc.HandPlayed),
		)
		b.WriteString("            case Referee.validateGameMove move standardBounds of\n")
	}
	switch sc.Expect.Kind {
	case "ok":
		b.WriteString(`                Ok _ ->
                    Expect.pass

                Err err ->
                    Expect.fail (refereeStageToString err.stage ++ ": " ++ err.message)`)
	case "error":
		stageQ := `"` + sc.Expect.Stage + `"`
		msgQ := `"` + sc.Expect.MessageSubstr + `"`
		fmt.Fprintf(b, `                Ok _ ->
                    Expect.fail ("expected error at stage " ++ %s ++ ", got ok")

                Err err ->
                    if refereeStageToString err.stage /= %s then
                        Expect.fail ("stage: want " ++ %s ++ ", got " ++ refereeStageToString err.stage)
                    else if not (String.contains %s err.message) then
                        Expect.fail ("message substring " ++ %s ++ " not found in " ++ err.message)
                    else
                        Expect.pass`,
			stageQ, stageQ, stageQ, msgQ, msgQ)
	}
}

func elmStacks(ss []Stack, indent string) string {
	if len(ss) == 0 {
		return "[]"
	}
	var parts []string
	for _, s := range ss {
		parts = append(parts, elmStackLit(s))
	}
	return "[ " + strings.Join(parts, "\n"+indent+", ") + "\n" + indent + "]"
}

func elmStackLit(s Stack) string {
	var bcs []string
	for _, c := range s.Cards {
		bcs = append(bcs, fmt.Sprintf("{ card = %s, state = %s }", elmCardLit(c), elmBoardState(c.BoardState)))
	}
	return fmt.Sprintf("{ boardCards = [ %s ], loc = { top = %d, left = %d } }",
		strings.Join(bcs, ", "), s.Top, s.Left)
}

func elmHandCards(cs []Card) string {
	if len(cs) == 0 {
		return "[]"
	}
	var parts []string
	for _, c := range cs {
		parts = append(parts, fmt.Sprintf("{ card = %s, state = HandNormal }", elmCardLit(c)))
	}
	return "[ " + strings.Join(parts, ", ") + " ]"
}

func elmCardLit(c Card) string {
	return fmt.Sprintf("{ value = %s, suit = %s, originDeck = %s }",
		elmValue(c.Value), elmSuit(c.Suit), elmDeck(c.Deck))
}

func elmValue(v int) string {
	return []string{"", "Ace", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Jack", "Queen", "King"}[v]
}

func elmSuit(s int) string {
	return []string{"Club", "Diamond", "Spade", "Heart"}[s]
}

func elmDeck(d int) string {
	if d == 0 {
		return "DeckOne"
	}
	return "DeckTwo"
}

func elmBoardState(s int) string {
	return []string{"FirmlyOnBoard", "FreshlyPlayed", "FreshlyPlayedByLastPlayer"}[s]
}

// keep format import reachable so goimports doesn't strip it in
// case we later use gofmt's Source directly
var _ = format.Source

// --- JSON emission (for Python, interpreted — no codegen) ---
//
// Python reads the JSON at runtime and dispatches per op. Only
// scenarios whose op is in pythonSupportedOps are included; the
// Go + Elm emitters handle the rest. Field names match the dict
// shape hints.py already uses (value/suit/origin_deck/state).

type jsonCard struct {
	Value      int `json:"value"`
	Suit       int `json:"suit"`
	OriginDeck int `json:"origin_deck"`
}

type jsonBoardCard struct {
	Card  jsonCard `json:"card"`
	State int      `json:"state"`
}

type jsonHandCard struct {
	Card  jsonCard `json:"card"`
	State int      `json:"state"`
}

type jsonStack struct {
	BoardCards []jsonBoardCard `json:"board_cards"`
	Loc        jsonLoc         `json:"loc"`
}

type jsonLoc struct {
	Top  int `json:"top"`
	Left int `json:"left"`
}

type jsonSuggestion struct {
	TrickID   string     `json:"trick_id"`
	HandCards []jsonCard `json:"hand_cards"`
}

type jsonExpect struct {
	Kind        string           `json:"kind"`
	Suggestions []jsonSuggestion `json:"suggestions,omitempty"`
}

type jsonScenario struct {
	Name   string         `json:"name"`
	Desc   string         `json:"desc"`
	Op     string         `json:"op"`
	Trick  string         `json:"trick,omitempty"`
	Hand   []jsonHandCard `json:"hand"`
	Board  []jsonStack    `json:"board"`
	Expect jsonExpect     `json:"expect"`
}

func emitJSON(scenarios []Scenario, outPath string) error {
	var out []jsonScenario
	for _, sc := range scenarios {
		if !pythonSupportedOps[sc.Op] {
			continue
		}
		out = append(out, toJSONScenario(sc))
	}
	if out == nil {
		out = []jsonScenario{}
	}
	// Indent for humans — diffs should be readable.
	bs, err := json.MarshalIndent(out, "", "  ")
	if err != nil {
		return err
	}
	bs = append(bs, '\n')
	if err := os.MkdirAll(filepath.Dir(outPath), 0755); err != nil {
		return err
	}
	return os.WriteFile(outPath, bs, 0644)
}

func toJSONScenario(sc Scenario) jsonScenario {
	js := jsonScenario{
		Name:  sc.Name,
		Desc:  sc.Desc,
		Op:    sc.Op,
		Trick: sc.Trick,
		Hand:  toJSONHand(sc.Hand),
		Board: toJSONBoard(sc.Board),
	}
	js.Expect = jsonExpect{Kind: sc.Expect.Kind}
	for _, es := range sc.Expect.Suggestions {
		js.Expect.Suggestions = append(js.Expect.Suggestions, jsonSuggestion{
			TrickID:   es.TrickID,
			HandCards: toJSONCards(es.HandCards),
		})
	}
	return js
}

func toJSONHand(cs []Card) []jsonHandCard {
	out := make([]jsonHandCard, 0, len(cs))
	for _, c := range cs {
		out = append(out, jsonHandCard{
			Card:  jsonCard{Value: c.Value, Suit: c.Suit, OriginDeck: c.Deck},
			State: 0,
		})
	}
	return out
}

func toJSONBoard(ss []Stack) []jsonStack {
	out := make([]jsonStack, 0, len(ss))
	for _, s := range ss {
		bcs := make([]jsonBoardCard, 0, len(s.Cards))
		for _, c := range s.Cards {
			bcs = append(bcs, jsonBoardCard{
				Card:  jsonCard{Value: c.Value, Suit: c.Suit, OriginDeck: c.Deck},
				State: c.BoardState,
			})
		}
		out = append(out, jsonStack{BoardCards: bcs, Loc: jsonLoc{Top: s.Top, Left: s.Left}})
	}
	return out
}

func toJSONCards(cs []Card) []jsonCard {
	out := make([]jsonCard, 0, len(cs))
	for _, c := range cs {
		out = append(out, jsonCard{Value: c.Value, Suit: c.Suit, OriginDeck: c.Deck})
	}
	return out
}

// --- Parser (unchanged) ---

type line struct {
	indent  int
	content string
	lineNum int
}

func parse(src, path string) ([]Scenario, error) {
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

	var scenarios []Scenario
	for i := 0; i < len(lines); {
		if !strings.HasPrefix(lines[i].content, "scenario ") {
			return nil, fmt.Errorf("%s:%d: expected 'scenario <name>'", path, lines[i].lineNum)
		}
		if lines[i].indent != 0 {
			return nil, fmt.Errorf("%s:%d: scenario header must be at column 0", path, lines[i].lineNum)
		}
		name := strings.TrimSpace(strings.TrimPrefix(lines[i].content, "scenario"))
		i++
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

func parseBody(name string, body []line, path string) (Scenario, error) {
	sc := Scenario{Name: name}
	i := 0
	for i < len(body) {
		l := body[i]
		if l.indent != 1 {
			return sc, fmt.Errorf("%s:%d: unexpected indent", path, l.lineNum)
		}
		key, val, hasBlock := splitField(l.content)
		i++
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
			sc.Expect.Kind = val
			if len(children) > 0 {
				if err := parseExpectBlock(&sc.Expect, children, path); err != nil {
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

func applyScalarField(sc *Scenario, key, val string, ln int, path string) error {
	switch key {
	case "desc":
		sc.Desc = val
	case "op":
		sc.Op = val
	case "trick":
		sc.Trick = val
	case "hand":
		cards, err := parseCards(val)
		if err != nil {
			return fmt.Errorf("%s:%d: hand: %w", path, ln, err)
		}
		sc.Hand = cards
	case "hand_cards_played":
		cards, err := parseCards(val)
		if err != nil {
			return fmt.Errorf("%s:%d: hand_cards_played: %w", path, ln, err)
		}
		sc.HandPlayed = cards
	case "expect":
		sc.Expect.Kind = val
	default:
		return fmt.Errorf("%s:%d: unknown field %q", path, ln, key)
	}
	return nil
}

func applyBlockField(sc *Scenario, key string, children []line, path string) error {
	switch key {
	case "board":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.Board = stacks
		sc.BoardVar = "board"
	case "board_before":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.Board = stacks
		sc.BoardVar = "board_before"
	case "stacks_to_remove":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.Removed = stacks
	case "stacks_to_add":
		stacks, err := parseStacks(children, path)
		if err != nil {
			return err
		}
		sc.Added = stacks
	case "expect":
		return parseExpectBlock(&sc.Expect, children, path)
	default:
		return fmt.Errorf("%s: unknown block field %q", path, key)
	}
	return nil
}

func parseSuggestionRow(s string) (ExpectedSuggestion, error) {
	// Format: "<trick_id>, <card card ...>"
	// Or just "<trick_id>" for suggestions with no cards.
	parts := strings.SplitN(s, ",", 2)
	trickID := strings.TrimSpace(parts[0])
	if trickID == "" {
		return ExpectedSuggestion{}, fmt.Errorf("missing trick_id")
	}
	var cards []Card
	if len(parts) == 2 {
		rest := strings.TrimSpace(parts[1])
		if rest != "" {
			cs, err := parseCards(rest)
			if err != nil {
				return ExpectedSuggestion{}, err
			}
			cards = cs
		}
	}
	return ExpectedSuggestion{TrickID: trickID, HandCards: cards}, nil
}


func parseExpectBlock(e *Expectation, children []line, path string) error {
	i := 0
	if e.Kind == "" && i < len(children) {
		c := children[i].content
		if !strings.Contains(c, ":") && (c == "ok" || c == "no_plays" || c == "play" || c == "error" || c == "suggestions") {
			e.Kind = c
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
				e.BoardAfter = stacks
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
				e.HandPlayed = cards
			case "stage":
				e.Stage = val
			case "message_contains":
				e.MessageSubstr = val
			case "suggestion":
				sug, err := parseSuggestionRow(val)
				if err != nil {
					return fmt.Errorf("%s:%d: suggestion: %w", path, l.lineNum, err)
				}
				e.Suggestions = append(e.Suggestions, sug)
			default:
				return fmt.Errorf("%s:%d: unknown expect field %q", path, l.lineNum, key)
			}
		}
	}
	return nil
}

func parseStacks(children []line, path string) ([]Stack, error) {
	var stacks []Stack
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
		stacks = append(stacks, Stack{Top: top, Left: left, Cards: cards})
	}
	return stacks, nil
}

func parseCards(s string) ([]Card, error) {
	if s == "" {
		return nil, nil
	}
	var cards []Card
	for _, tok := range strings.Fields(s) {
		c, err := parseCard(tok)
		if err != nil {
			return nil, err
		}
		cards = append(cards, c)
	}
	return cards, nil
}

func parseCard(tok string) (Card, error) {
	if len(tok) < 2 {
		return Card{}, fmt.Errorf("card too short: %q", tok)
	}
	v := valueFromLetter(tok[0])
	if v == 0 {
		return Card{}, fmt.Errorf("bad value letter: %q", tok)
	}
	s := suitFromLetter(tok[1])
	if s == -1 {
		return Card{}, fmt.Errorf("bad suit letter: %q", tok)
	}
	c := Card{Value: v, Suit: s, Deck: 0, BoardState: 0}
	i := 2
	if i < len(tok) && tok[i] == '\'' {
		c.Deck = 1
		i++
	}
	if i < len(tok) && tok[i] == '*' {
		if i+1 < len(tok) && tok[i+1] == '*' {
			c.BoardState = 2
			i += 2
		} else {
			c.BoardState = 1
			i++
		}
	}
	if i != len(tok) {
		return Card{}, fmt.Errorf("trailing chars in card: %q", tok)
	}
	return c, nil
}

func valueFromLetter(b byte) int {
	switch b {
	case 'A':
		return 1
	case 'T':
		return 10
	case 'J':
		return 11
	case 'Q':
		return 12
	case 'K':
		return 13
	}
	if b >= '2' && b <= '9' {
		return int(b - '0')
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
