// markdown_gold freezes and verifies the zig-port gold corpus: for every
// corpus item it records (id, markdown, expected-HTML), where the expected
// HTML is whatever the REAL Go renderer (RenderChatMarkdown) produces. The Go
// renderer is the oracle; this gold is what the zig port must reproduce
// byte-for-byte.
//
// Benchmark-pattern flow (see games/lynrummy/ts/bench for the house style):
//   - gold file missing  → bootstrap: write it, done.
//   - gold file present   → verify every case; FAIL FAST on the first
//     mismatch (printing the id + expected vs got), and do NOT rewrite.
//   - all cases match     → report success, leave the gold untouched.
// Re-baselining after an intentional renderer change is an explicit act:
// delete the gold file and re-run.
//
// Usage: markdown_gold [chat-root]
// chat-root defaults to the private prod extract (see internal/corpus). The
// gold file lives at ~/showell_repos/gopher-gold/gold.jsonl — a PRIVATE repo
// (it embeds real user messages; never push it to a public remote).
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"angry-gopher/internal/corpus"
	"angry-gopher/server/chat"
)

type goldCase struct {
	ID   string `json:"id"`
	MD   string `json:"md"`
	HTML string `json:"html"`
}

func goldPath() string {
	return filepath.Join(os.Getenv("HOME"), "showell_repos/gopher-gold/gold.jsonl")
}

func main() {
	root := corpus.DefaultRoot
	if len(os.Args) > 1 {
		root = os.Args[1]
	}
	path := goldPath()

	items, err := corpus.Walk(root)
	if err != nil {
		fail(err)
	}
	cur := make([]goldCase, len(items))
	for i, it := range items {
		cur[i] = goldCase{ID: it.ID, MD: it.Markdown, HTML: string(chat.RenderChatMarkdown(it.Markdown))}
	}

	if _, err := os.Stat(path); os.IsNotExist(err) {
		if err := writeGold(path, cur); err != nil {
			fail(err)
		}
		fmt.Printf("bootstrapped gold: wrote %d cases to %s\n", len(cur), path)
		return
	}

	gold, err := readGold(path)
	if err != nil {
		fail(err)
	}
	if len(gold) != len(cur) {
		fmt.Printf("MISMATCH: case count gold=%d current=%d\n", len(gold), len(cur))
		fmt.Println("(corpus changed — delete the gold file and re-run to re-baseline)")
		os.Exit(1)
	}
	for i := range cur {
		switch {
		case gold[i].ID != cur[i].ID:
			fmt.Printf("MISMATCH at case %d: id gold=%q current=%q\n", i, gold[i].ID, cur[i].ID)
			os.Exit(1)
		case gold[i].MD != cur[i].MD:
			fmt.Printf("MISMATCH at %s: input markdown differs (corpus changed; re-baseline)\n", cur[i].ID)
			os.Exit(1)
		case gold[i].HTML != cur[i].HTML:
			fmt.Printf("MISMATCH at %s:\n  md:       %q\n  expected: %q\n  got:      %q\n",
				cur[i].ID, cur[i].MD, gold[i].HTML, cur[i].HTML)
			os.Exit(1)
		}
	}
	fmt.Printf("verified %d cases against %s\n", len(cur), path)
}

// writeGold writes cases as JSONL (one JSON object per line), HTML escaping
// OFF so <, >, & stay literal — valid JSON, and far more readable/diffable.
// Written via a temp file + rename so a crash can't leave a half-file.
func writeGold(path string, cases []goldCase) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(f)
	enc.SetEscapeHTML(false)
	for _, c := range cases {
		if err := enc.Encode(c); err != nil {
			f.Close()
			return err
		}
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func readGold(path string) ([]goldCase, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	dec := json.NewDecoder(f)
	var out []goldCase
	for {
		var c goldCase
		if err := dec.Decode(&c); err == io.EOF {
			break
		} else if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, nil
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
