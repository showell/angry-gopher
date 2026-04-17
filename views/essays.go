// Essays landing — lists every markdown essay in
// showell/claude_writings/ with its last-modified date in
// US Eastern time. First-class Claude-writings index.
//
// label: SPIKE (essays-landing)
package views

import (
	"bufio"
	"fmt"
	"html"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// EssaysDir is the directory scanned for *.md essays. Set by
// main if needed; default assumes Gopher runs from the repo
// root.
var EssaysDir = "showell/claude_writings"

// excludedEssays are meta-files in EssaysDir that shouldn't
// appear in the listing (indices, queues, etc.).
var excludedEssays = map[string]bool{
	"QUEUE.md":  true,
	"README.md": true,
}

type essayEntry struct {
	Slug    string    // filename without .md
	File    string    // filename with .md
	Title   string    // from first "# " heading, fallback to slug
	ModTime time.Time // file mtime
}

// HandleEssays serves /gopher/essays — the landing list.
func HandleEssays(w http.ResponseWriter, r *http.Request) {
	entries := loadEssays(EssaysDir)
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].ModTime.After(entries[j].ModTime)
	})

	eastern, err := time.LoadLocation("America/New_York")
	if err != nil {
		eastern = time.UTC
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!DOCTYPE html>
<html><head><title>Essays — Angry Gopher</title>
<style>
body { font-family: sans-serif; margin: 60px auto; max-width: 820px; padding: 0 24px; color: #222; }
h1 { color: #000080; margin-bottom: 8px; }
.sub { color: #666; margin-bottom: 28px; font-size: 14px; }
nav { margin-bottom: 16px; font-size: 13px; }
nav a { color: #000080; }
ul.essays { list-style: none; padding: 0; margin: 0; }
ul.essays li { padding: 10px 0; border-bottom: 1px solid #eee; display: flex; justify-content: space-between; gap: 20px; align-items: baseline; }
ul.essays li:last-child { border-bottom: none; }
ul.essays a { color: #000080; font-weight: bold; text-decoration: none; font-size: 16px; }
ul.essays a:hover { text-decoration: underline; }
.date { color: #666; font-size: 13px; white-space: nowrap; font-variant-numeric: tabular-nums; }
</style>
</head><body>
<nav><a href="/gopher/">← Gopher home</a></nav>
<h1>Essays</h1>
<p class="sub">Long-form writing from Claude, with Steve's inline comments. Dates shown in US Eastern time.</p>
<ul class="essays">`)
	for _, e := range entries {
		localTime := e.ModTime.In(eastern).Format("Jan 2, 2006 · 3:04 PM MST")
		fmt.Fprintf(w,
			`<li><a href="/gopher/docs/gopher/%s/%s">%s</a><span class="date">%s</span></li>`,
			html.EscapeString(EssaysDir),
			html.EscapeString(e.File),
			html.EscapeString(e.Title),
			html.EscapeString(localTime),
		)
	}
	fmt.Fprint(w, `</ul>
</body></html>`)
}

func loadEssays(dir string) []essayEntry {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	out := make([]essayEntry, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasSuffix(name, ".md") {
			continue
		}
		if excludedEssays[name] {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		path := filepath.Join(dir, name)
		title := extractTitle(path)
		if title == "" {
			title = strings.TrimSuffix(name, ".md")
		}
		out = append(out, essayEntry{
			Slug:    strings.TrimSuffix(name, ".md"),
			File:    name,
			Title:   title,
			ModTime: info.ModTime(),
		})
	}
	return out
}

// extractTitle returns the first "# " heading in the file,
// or "" if none is present in the first few lines.
func extractTitle(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	lines := 0
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "# ") {
			return strings.TrimSpace(strings.TrimPrefix(line, "# "))
		}
		lines++
		if lines > 10 {
			break
		}
	}
	return ""
}
