// Package corpus walks a chat data tree and yields the renderable markdown
// bodies in it — one per chat message, one per doc. It's the shared input
// side for the offline markdown tooling (the render-diff tool and the
// zig-port gold harness): both need the exact same set of (id, markdown)
// pairs, decoded with the real chat decoder, so the noun lives here once.
//
// Only session transcripts (**/sessions/*.md, decoded message-by-message)
// and docs (**/docs/*.md, whole-file) are included — the server renders
// exactly these through RenderChatMarkdown. The per-user images.md/code.md
// feeds use a different on-disk shape and are skipped.
package corpus

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"angry-gopher/server/chat"
)

// DefaultRoot is the private prod extract produced by ops/backup.
var DefaultRoot = filepath.Join(os.Getenv("HOME"), "AngryGopher/corpus-work/prod/chat")

// Item is one renderable markdown body. ID is a stable, human-readable
// handle: "<relpath>#<n>" for the n-th message of a session, "<relpath>"
// for a doc. Markdown is the raw body fed to RenderChatMarkdown.
type Item struct {
	ID       string
	Markdown string
}

// Walk returns every renderable item under root, ordered deterministically
// (files sorted, messages in transcript order). Empty bodies are skipped.
func Walk(root string) ([]Item, error) {
	var files []string
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(p, ".md") {
			return nil
		}
		slash := filepath.ToSlash(p)
		if strings.Contains(slash, "/sessions/") || strings.Contains(slash, "/docs/") {
			files = append(files, p)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(files)

	var items []Item
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		rel, err := filepath.Rel(root, f)
		if err != nil {
			return nil, err
		}
		rel = filepath.ToSlash(rel)
		if strings.Contains(rel, "/sessions/") {
			for i, m := range chat.DecodeTranscript(data) {
				if strings.TrimSpace(m.Markdown) == "" {
					continue
				}
				items = append(items, Item{ID: rel + "#" + strconv.Itoa(i), Markdown: m.Markdown})
			}
			continue
		}
		if strings.TrimSpace(string(data)) == "" {
			continue
		}
		items = append(items, Item{ID: rel, Markdown: string(data)})
	}
	return items, nil
}
