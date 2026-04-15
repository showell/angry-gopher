// Claude log — chronological view of every reply Claude has made on
// the wiki. Reads /tmp/claude_inbox.log (the breadcrumb stream) and
// filters to wiki-comment entries authored by Claude.
//
// Purpose: findability=10 for "what has Claude been saying?". Pairs
// with the live SSE bell — the bell is the transient notification,
// this page is the permanent log.
//
// label: SPIKE (ANCHOR_COMMENTS)
package views

import (
	"fmt"
	"html"
	"net/http"
	"os"
	"strings"
)

const claudeLogInboxPath = "/tmp/claude_inbox.log"

type claudeLogEntry struct {
	When     string
	Author   string // may be "Claude" or "Claude (cron)"
	Location string // e.g. gopher/views/wiki.claude.comments
	Anchor   string // e.g. #c-...
	Body     string
}

func HandleClaudeLog(w http.ResponseWriter, r *http.Request) {
	entries := readClaudeWikiEntries()
	wikiHeader(w, "Claude log", "/claude-log", "")
	fmt.Fprintf(w, `<h1>Claude log</h1><p class="muted">Every wiki reply Claude has posted, newest first. %d entries.</p>`, len(entries))
	if len(entries) == 0 {
		fmt.Fprint(w, `<p>No replies yet.</p>`)
		wikiFooter(w)
		return
	}
	fmt.Fprint(w, `<ul class="wiki-tree">`)
	for i := len(entries) - 1; i >= 0; i-- {
		e := entries[i]
		tag := ""
		if strings.Contains(e.Author, "(cron)") {
			tag = ` <span style="background:#ffe080;border:1px solid #c9a000;border-radius:3px;padding:0 6px;font-size:11px;">cron</span>`
		}
		fmt.Fprintf(w,
			`<li><span class="muted">%s</span>%s — <a href="/gopher/wiki/%s%s">%s</a><br><span style="color:#333;">%s</span></li>`,
			html.EscapeString(e.When), tag,
			html.EscapeString(e.Location), html.EscapeString(e.Anchor),
			html.EscapeString(e.Location+e.Anchor),
			html.EscapeString(e.Body),
		)
	}
	fmt.Fprint(w, `</ul>`)
	wikiFooter(w)
}

func readClaudeWikiEntries() []claudeLogEntry {
	data, err := os.ReadFile(claudeLogInboxPath)
	if err != nil {
		return nil
	}
	var out []claudeLogEntry
	for _, line := range strings.Split(string(data), "\n") {
		if line == "" {
			continue
		}
		cols := strings.Split(line, "\t")
		if len(cols) < 6 {
			continue
		}
		when, source, author, location, anchor, body := cols[0], cols[1], cols[2], cols[3], cols[4], cols[5]
		if source != "wiki-comment" {
			continue
		}
		if !strings.HasPrefix(author, "Claude") {
			continue
		}
		out = append(out, claudeLogEntry{
			When: when, Author: author, Location: location, Anchor: anchor, Body: body,
		})
	}
	return out
}
