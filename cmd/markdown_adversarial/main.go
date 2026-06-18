// markdown_adversarial holds a small, hand-written set of HOSTILE markdown
// inputs that the real prod corpus never happened to contain — the corners of
// emphasis, lists, and blockquotes where a port is most likely to diverge from
// goldmark. It renders each through the REAL oracle (chat.RenderChatMarkdown)
// and writes zig-server/adversarial.jsonl ({id, md, html} per line), the same
// shape as the frozen gold corpus.
//
// Unlike gopher-gold/gold.jsonl, these inputs are synthetic (no user data), so
// the fixture lives in the repo. The zig harness checks it alongside the gold.
//
// Why hand-written, and why now: the corpus over-tests the common case and
// barely touches these corners (two blockquotes in all of prod history). These
// cases probe the rare constructs on purpose. They were authored BEFORE the zig
// emphasis/list code existed, so they're not just a mirror of that code's
// assumptions. Regenerate any time: go run ./cmd/markdown_adversarial.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"

	"angry-gopher/server/chat"
)

type goldCase struct {
	ID   string `json:"id"`
	MD   string `json:"md"`
	HTML string `json:"html"`
}

// cases: {id, markdown}. Grouped by the construct under attack. Keep these
// genuinely basic — the goal is corner coverage, not a fuzzer.
var cases = [][2]string{
	// --- emphasis -----------------------------------------------------------
	{"emph/basic-both", "**bold** and *italic* together"},
	{"emph/strong-intraword", "a**b**c"},
	{"emph/em-intraword-star", "a*b*c"},
	{"emph/underscore-em", "_underscore emphasis_"},
	{"emph/underscore-intraword", "snake_case_word stays literal"},
	{"emph/unclosed-strong", "**unclosed bold runs on"},
	{"emph/triple", "***bold and italic***"},
	{"emph/nested", "**bold _and italic_ inside**"},
	{"emph/space-inside-star", "* not emphasis *"},
	{"emph/abut-punct-paren", "(**bold**) and **bold**."},
	{"emph/overlap", "**a*b**c*"},
	{"emph/star-in-code", "`a*b*c` and *real*"},

	// --- lists --------------------------------------------------------------
	{"list/tight-ul", "- a\n- b\n- c"},
	{"list/tight-ol", "1. one\n2. two"},
	{"list/ol-start", "3. three\n4. four"},
	{"list/loose-ul", "- a\n\n- b"},
	{"list/interrupt-para-bullet", "some text\n- item"},
	{"list/interrupt-para-ordered", "some text\n1. item"},
	{"list/nested", "- outer\n  - inner\n- outer2"},
	{"list/emphasis-in-item", "- **bold** item\n- plain"},

	// --- blockquote ---------------------------------------------------------
	{"bq/single", "> quoted"},
	{"bq/multiline", "> line one\n> line two"},
	{"bq/lazy", "> line one\nstill quoted"},
	{"bq/emphasis", "> a **bold** quote"},
}

func main() {
	out := "zig-server/adversarial.jsonl"
	if len(os.Args) > 1 {
		out = os.Args[1]
	}
	f, err := os.Create(out)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer f.Close()
	w := bufio.NewWriter(f)
	defer w.Flush()

	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	for _, c := range cases {
		gc := goldCase{ID: c[0], MD: c[1], HTML: string(chat.RenderChatMarkdown(c[1]))}
		if err := enc.Encode(gc); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	fmt.Fprintf(os.Stderr, "wrote %d adversarial cases to %s\n", len(cases), out)
}
