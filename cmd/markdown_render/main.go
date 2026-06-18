// markdown_render renders every message body (and doc) in a chat data tree
// through the REAL chat renderer (RenderChatMarkdown) and prints a stable,
// diff-friendly stream: one "=== <relpath>#<i> ===" header per item followed
// by its rendered HTML. Used to snapshot the corpus BEFORE vs AFTER a
// renderer change so the diff shows exactly what moved.
//
// Usage: markdown_render [chat-root]
// Default root is ~/AngryGopher/corpus-work/prod/chat (private extract; see
// ops/backup). Pure read; never writes the corpus.
package main

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"angry-gopher/server/chat"
)

func main() {
	root := filepath.Join(os.Getenv("HOME"), "AngryGopher/corpus-work/prod/chat")
	if len(os.Args) > 1 {
		root = os.Args[1]
	}

	var files []string
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(p, ".md") {
			return nil
		}
		slash := filepath.ToSlash(p)
		if strings.Contains(slash, "/sessions/") || strings.Contains(slash, "/docs/") {
			files = append(files, p)
		}
		return nil
	})
	sort.Strings(files)

	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		rel, _ := filepath.Rel(root, f)
		rel = filepath.ToSlash(rel)
		if strings.Contains(rel, "/sessions/") {
			for i, m := range chat.DecodeTranscript(data) {
				if strings.TrimSpace(m.Markdown) == "" {
					continue
				}
				fmt.Printf("=== %s#%d ===\n%s\n", rel, i, chat.RenderChatMarkdown(m.Markdown))
			}
		} else {
			// docs/*.md render as a single whole-file body.
			fmt.Printf("=== %s ===\n%s\n", rel, chat.RenderChatMarkdown(string(data)))
		}
	}
}
