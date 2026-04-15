// Claude issues — file-backed tracker for things Steve has asked
// Claude to do. Each issue lives at claude_issues/NNN-slug.md with a
// tiny frontmatter block. The UI is two routes:
//
//   /gopher/claude-issues       — index (status, title, updated)
//   /gopher/claude-issues/<id>  — detail (rendered markdown)
//
// Audience: Steve first, Claude second. Claude rebuilds the .md files
// as work progresses; the server just reads them on every request.
//
// label: SPIKE (issue #10 — dedicated page per reply)
package views

import (
	"fmt"
	"html"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const claudeIssuesDir = "claude_issues"

type claudeIssue struct {
	ID      int
	Title   string
	Source  string
	Status  string
	Created string
	Updated string
	Body    string // everything below the frontmatter
	File    string
}

func HandleClaudeIssues(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/gopher/claude-issues")
	rest = strings.TrimPrefix(rest, "/")

	if r.Method == "POST" && rest == "" {
		handleNewIssue(w, r)
		return
	}

	issues, err := loadClaudeIssues()
	if err != nil {
		http.Error(w, "Cannot load issues: "+err.Error(), http.StatusInternalServerError)
		return
	}

	if rest == "" {
		renderClaudeIssuesIndex(w, issues)
		return
	}
	id, _ := strconv.Atoi(rest)
	for _, iss := range issues {
		if iss.ID == id {
			renderClaudeIssueDetail(w, iss)
			return
		}
	}
	http.NotFound(w, r)
}

func renderClaudeIssuesIndex(w http.ResponseWriter, issues []claudeIssue) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "Claude issues")
	PageSubtitle(w, fmt.Sprintf("Backlog of things Steve has asked Claude to do (%d total). Click any row for the detail page.", len(issues)))

	// New-issue form at the top. File directly from the UI.
	fmt.Fprint(w, `<details style="margin:16px 0;padding:10px 16px;border:1px solid #ccc;border-radius:4px;background:#fcfcf8;">
<summary style="cursor:pointer;font-weight:bold;">➕ File a new issue</summary>
<form method="POST" action="/gopher/claude-issues" style="margin-top:12px;">
<div style="margin-bottom:8px;"><label>Title<br>
<input type="text" name="title" required style="width:100%;padding:6px;font-size:14px;box-sizing:border-box;"></label></div>
<div style="margin-bottom:8px;"><label>Source <span class="muted">(e.g. "dm msg=N" or "wiki" or free-form)</span><br>
<input type="text" name="source" placeholder="steve (direct file)" style="width:100%;padding:6px;font-size:14px;box-sizing:border-box;"></label></div>
<div style="margin-bottom:8px;"><label>What Steve said / context<br>
<textarea name="body" rows="8" style="width:100%;min-height:160px;font-size:14px;padding:8px;box-sizing:border-box;"></textarea></label></div>
<button type="submit">Create issue</button>
</form>
</details>`)

	counts := map[string]int{}
	for _, iss := range issues {
		counts[iss.Status]++
	}
	fmt.Fprintf(w, `<p class="muted">Status: <b>%d open</b> · <b>%d in-progress</b> · <b>%d done</b></p>`,
		counts["open"], counts["in-progress"], counts["done"])

	var active, shipped []claudeIssue
	for _, iss := range issues {
		if iss.Status == "done" {
			shipped = append(shipped, iss)
		} else {
			active = append(active, iss)
		}
	}

	fmt.Fprintf(w, `<h2>Active <span class="muted">(%d)</span></h2>`, len(active))
	if len(active) == 0 {
		fmt.Fprint(w, `<p class="muted">Nothing open.</p>`)
	} else {
		fmt.Fprint(w, `<table><thead><tr><th>#</th><th>Status</th><th>Title</th><th>Source</th><th>Updated</th></tr></thead><tbody>`)
		for _, iss := range active {
			fmt.Fprintf(w,
				`<tr><td>%d</td><td>%s</td><td><a href="/gopher/claude-issues/%d">%s</a></td><td class="muted">%s</td><td class="muted">%s</td></tr>`,
				iss.ID, statusBadge(iss.Status), iss.ID,
				html.EscapeString(iss.Title), html.EscapeString(iss.Source), html.EscapeString(iss.Updated),
			)
		}
		fmt.Fprint(w, `</tbody></table>`)
	}

	// Recently shipped — newest-first, capped at 10. Replaces the old
	// hand-maintained FIXES.md.
	sort.Slice(shipped, func(i, j int) bool {
		return shipped[i].Updated > shipped[j].Updated
	})
	limit := 10
	if len(shipped) < limit {
		limit = len(shipped)
	}
	fmt.Fprintf(w, `<h2>Recently shipped <span class="muted">(showing %d of %d)</span></h2>`, limit, len(shipped))
	if limit == 0 {
		fmt.Fprint(w, `<p class="muted">Nothing shipped yet.</p>`)
	} else {
		fmt.Fprint(w, `<table><thead><tr><th>#</th><th>Title</th><th>Shipped</th></tr></thead><tbody>`)
		for _, iss := range shipped[:limit] {
			fmt.Fprintf(w,
				`<tr><td>%d</td><td><a href="/gopher/claude-issues/%d">%s</a></td><td class="muted">%s</td></tr>`,
				iss.ID, iss.ID, html.EscapeString(iss.Title), html.EscapeString(iss.Updated),
			)
		}
		fmt.Fprint(w, `</tbody></table>`)
	}
	PageFooter(w)
}

func statusBadge(s string) string {
	var bg string
	switch s {
	case "open":
		bg = "#fff3a8"
	case "in-progress":
		bg = "#b4d9ff"
	case "done":
		bg = "#c6f6c6"
	default:
		bg = "#e0e0e0"
	}
	return fmt.Sprintf(`<span style="background:%s;padding:2px 8px;border-radius:3px;font-size:12px;font-weight:bold;">%s</span>`, bg, html.EscapeString(s))
}

func renderClaudeIssueDetail(w http.ResponseWriter, iss claudeIssue) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, fmt.Sprintf("#%d — %s", iss.ID, iss.Title))
	fmt.Fprintf(w, `<p><a href="/gopher/claude-issues">&larr; All issues</a></p>`)
	fmt.Fprintf(w,
		`<p>%s · <span class="muted">source: %s · created %s · updated %s</span></p>`,
		statusBadge(iss.Status),
		html.EscapeString(iss.Source),
		html.EscapeString(iss.Created),
		html.EscapeString(iss.Updated),
	)
	if RenderMarkdown != nil {
		fmt.Fprint(w, `<div class="wiki-md">`)
		fmt.Fprint(w, RenderMarkdown(iss.Body))
		fmt.Fprint(w, `</div>`)
	} else {
		fmt.Fprintf(w, `<pre>%s</pre>`, html.EscapeString(iss.Body))
	}
	fmt.Fprintf(w,
		`<p class="muted" style="margin-top:32px;">File: <code>%s</code> · <a href="/gopher/wiki/gopher/%s">view in wiki</a></p>`,
		html.EscapeString(iss.File),
		html.EscapeString(iss.File),
	)
	PageFooter(w)
}

func loadClaudeIssues() ([]claudeIssue, error) {
	entries, err := os.ReadDir(claudeIssuesDir)
	if err != nil {
		return nil, err
	}
	var out []claudeIssue
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") || e.Name() == "README.md" {
			continue
		}
		path := filepath.Join(claudeIssuesDir, e.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		iss, ok := parseClaudeIssue(string(data))
		if !ok {
			continue
		}
		iss.File = path
		out = append(out, iss)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

func handleNewIssue(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		http.Error(w, "Bad form", http.StatusBadRequest)
		return
	}
	title := strings.TrimSpace(r.FormValue("title"))
	source := strings.TrimSpace(r.FormValue("source"))
	body := strings.TrimSpace(r.FormValue("body"))
	if title == "" {
		http.Error(w, "Title required", http.StatusBadRequest)
		return
	}
	if source == "" {
		source = "steve (direct file)"
	}
	existing, err := loadClaudeIssues()
	if err != nil {
		http.Error(w, "Cannot load existing issues", http.StatusInternalServerError)
		return
	}
	nextID := 1
	for _, iss := range existing {
		if iss.ID >= nextID {
			nextID = iss.ID + 1
		}
	}
	slug := issueSlug(title)
	fname := fmt.Sprintf("%03d-%s.md", nextID, slug)
	path := filepath.Join(claudeIssuesDir, fname)
	now := time.Now().Format("2006-01-02T15:04")
	content := fmt.Sprintf(`---
id: %d
title: %s
source: %s
status: open
created: %s
updated: %s
---

## What Steve said

%s

## Status

Not started.

## Plan

(to be filled in by Claude)

## Log

- %s  Filed from the issues UI
`, nextID, title, source, now, now, body, now)
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		http.Error(w, "Cannot write: "+err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, fmt.Sprintf("/gopher/claude-issues/%d", nextID), http.StatusSeeOther)
}

func issueSlug(title string) string {
	var b strings.Builder
	prevDash := true
	for _, r := range strings.ToLower(title) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
			prevDash = false
		default:
			if !prevDash {
				b.WriteRune('-')
				prevDash = true
			}
		}
	}
	s := strings.Trim(b.String(), "-")
	if len(s) > 50 {
		s = s[:50]
	}
	return s
}

func parseClaudeIssue(raw string) (claudeIssue, bool) {
	if !strings.HasPrefix(raw, "---\n") {
		return claudeIssue{}, false
	}
	rest := raw[4:]
	end := strings.Index(rest, "\n---")
	if end < 0 {
		return claudeIssue{}, false
	}
	fm := rest[:end]
	body := strings.TrimPrefix(rest[end+4:], "\n")
	iss := claudeIssue{Body: body}
	for _, line := range strings.Split(fm, "\n") {
		colon := strings.Index(line, ":")
		if colon < 0 {
			continue
		}
		k := strings.TrimSpace(line[:colon])
		v := strings.TrimSpace(line[colon+1:])
		switch k {
		case "id":
			iss.ID, _ = strconv.Atoi(v)
		case "title":
			iss.Title = v
		case "source":
			iss.Source = v
		case "status":
			iss.Status = v
		case "created":
			iss.Created = v
		case "updated":
			iss.Updated = v
		}
	}
	if iss.ID == 0 || iss.Title == "" {
		return claudeIssue{}, false
	}
	return iss, true
}
