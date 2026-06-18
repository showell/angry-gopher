// markdown_render renders every corpus item through the REAL chat renderer
// (RenderChatMarkdown) and prints a stable, diff-friendly stream: one
// "=== <id> ===" header per item followed by its rendered HTML. Used to
// snapshot the corpus BEFORE vs AFTER a renderer change so the diff shows
// exactly what moved. The gold harness (cmd/markdown_gold) is the canonical
// frozen artifact; this is the eyeball/diff companion.
//
// Usage: markdown_render [chat-root]
// Default root is the private prod extract (see internal/corpus). Pure read.
package main

import (
	"bufio"
	"fmt"
	"os"

	"angry-gopher/internal/corpus"
	"angry-gopher/server/chat"
)

func main() {
	root := corpus.DefaultRoot
	if len(os.Args) > 1 {
		root = os.Args[1]
	}
	items, err := corpus.Walk(root)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	out := bufio.NewWriter(os.Stdout)
	defer out.Flush()
	for _, it := range items {
		fmt.Fprintf(out, "=== %s ===\n%s\n", it.ID, chat.RenderChatMarkdown(it.Markdown))
	}
}
