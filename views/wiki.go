// Wiki view — browser-based reader for repo docs, sidecars, and
// source files. Serves multiple repos so Steve can navigate between
// Gopher + sibling Elm projects in one browser tab.
//
//   /gopher/wiki/                      — landing (lists repos + landmarks)
//   /gopher/wiki/<repo>/               — repo home (README.md)
//   /gopher/wiki/<repo>/<path>         — render any file in <repo>
//   /gopher/wiki/<repo>/tree[/subpath] — directory listing
//
// Known repos live in wikiRepos. To add one, map a name to an
// absolute path. Findability knob = 10: every repo Steve might want
// is exposed; no gating.
package views

import (
	"fmt"
	"html"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"angry-gopher/notify"
)

// wikiRepos maps a short repo name (used in URLs) to its filesystem
// root. Order is the display order in the sidebar.
var wikiRepoOrder = []string{"gopher", "elm-critters", "elm-lynrummy"}

var wikiRepos = map[string]string{
	"gopher":       "", // resolved to cwd lazily
	"elm-critters": filepath.Join(os.Getenv("HOME"), "showell_repos/elm-critters"),
	"elm-lynrummy": filepath.Join(os.Getenv("HOME"), "showell_repos/elm-lynrummy"),
}

func repoRoot(repo string) (string, bool) {
	root, ok := wikiRepos[repo]
	if !ok {
		return "", false
	}
	if repo == "gopher" {
		cwd, err := os.Getwd()
		if err != nil {
			return "", false
		}
		return cwd, true
	}
	return root, true
}

// resolveRepoPath joins sub onto the repo root and refuses anything
// that escapes via `..`.
func resolveRepoPath(repo, sub string) (string, bool) {
	root, ok := repoRoot(repo)
	if !ok {
		return "", false
	}
	cleaned := filepath.Clean(filepath.Join(root, sub))
	rel, err := filepath.Rel(root, cleaned)
	if err != nil || strings.HasPrefix(rel, "..") {
		return "", false
	}
	return cleaned, true
}

// HandleWiki dispatches all /gopher/wiki/* requests.
// No auth: V1 is read-only and the files are on disk for anyone
// with shell access. Findability is the point.
func HandleWiki(w http.ResponseWriter, r *http.Request) {
	sub := strings.TrimPrefix(r.URL.Path, "/gopher/wiki/")
	sub = strings.TrimPrefix(sub, "/gopher/wiki")
	sub = strings.TrimPrefix(sub, "/")

	if sub == "" {
		wikiLanding(w)
		return
	}

	// First segment is the repo name.
	parts := strings.SplitN(sub, "/", 2)
	repo := parts[0]
	rest := ""
	if len(parts) > 1 {
		rest = parts[1]
	}

	if _, ok := wikiRepos[repo]; !ok {
		http.Error(w, "Unknown repo: "+repo, http.StatusNotFound)
		return
	}

	if r.Method == "POST" && strings.HasSuffix(rest, ".claude.comments") {
		handleCommentReply(w, r, repo, rest)
		return
	}

	if rest == "" || rest == "/" {
		wikiRender(w, repo, "README.md", repo+"/README.md")
		return
	}

	if strings.HasPrefix(rest, "tree") {
		treeRest := strings.TrimPrefix(rest, "tree")
		treeRest = strings.TrimPrefix(treeRest, "/")
		wikiTree(w, repo, treeRest)
		return
	}

	wikiRender(w, repo, rest, repo+"/"+rest)
}

func wikiLanding(w http.ResponseWriter) {
	wikiHeader(w, "Wiki", "/", "")
	fmt.Fprint(w, `<p>Browser-based reader for Steve's dev harness. Pick a repo:</p><ul class="wiki-tree">`)
	for _, name := range wikiRepoOrder {
		root, ok := repoRoot(name)
		if !ok {
			continue
		}
		fmt.Fprintf(w, `<li><a href="/gopher/wiki/%s/"><b>%s</b></a> <span class="muted">— %s</span></li>`,
			html.EscapeString(name), html.EscapeString(name), html.EscapeString(root))
	}
	fmt.Fprint(w, `</ul>`)
	renderCommentsIndex(w, "gopher")
	wikiFooter(w)
}

// renderCommentsIndex walks the repo for *.claude.comments files and
// lists them. First stop on the wiki landing page — findability=10.
func renderCommentsIndex(w http.ResponseWriter, repo string) {
	root, ok := repoRoot(repo)
	if !ok {
		return
	}
	var found []string
	_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		name := info.Name()
		if strings.HasPrefix(name, ".") {
			return nil
		}
		if strings.HasSuffix(name, ".claude.comments") {
			rel, err := filepath.Rel(root, path)
			if err == nil {
				found = append(found, rel)
			}
		}
		return nil
	})
	if len(found) == 0 {
		return
	}
	sort.Strings(found)
	fmt.Fprintf(w, `<h2>Open comments <span class="muted">(%d)</span></h2><ul class="wiki-tree">`, len(found))
	for _, rel := range found {
		parent := strings.TrimSuffix(rel, ".comments")
		fmt.Fprintf(w, `<li><a href="/gopher/wiki/%s/%s">%s</a> <span class="muted">→ <a href="/gopher/wiki/%s/%s">sidecar</a></span></li>`,
			html.EscapeString(repo), html.EscapeString(rel), html.EscapeString(rel),
			html.EscapeString(repo), html.EscapeString(parent))
	}
	fmt.Fprint(w, `</ul>`)
}

// wikiRender reads a file and serves it — markdown for .md,
// preformatted for everything else.
func wikiRender(w http.ResponseWriter, repo, sub, displayPath string) {
	abs, ok := resolveRepoPath(repo, sub)
	if !ok {
		http.Error(w, "Invalid path", http.StatusBadRequest)
		return
	}
	info, err := os.Stat(abs)
	if err != nil {
		http.Error(w, "Not found: "+displayPath, http.StatusNotFound)
		return
	}
	if info.IsDir() {
		wikiTree(w, repo, sub)
		return
	}
	body, err := os.ReadFile(abs)
	if err != nil {
		http.Error(w, "Cannot read", http.StatusInternalServerError)
		return
	}

	wikiHeader(w, sub, displayPath, repo)
	if link := sidecarLink(repo, sub); link != "" {
		fmt.Fprint(w, link)
	}
	if link := commentsLink(repo, sub); link != "" {
		fmt.Fprint(w, link)
	}
	if strings.HasSuffix(sub, ".claude.comments") {
		renderCommentsSectioned(w, repo, sub, string(body))
	} else if strings.HasSuffix(sub, ".md") && RenderMarkdown != nil {
		fmt.Fprint(w, `<div class="wiki-md">`)
		fmt.Fprint(w, RenderMarkdown(string(body)))
		fmt.Fprint(w, `</div>`)
	} else {
		renderSourceWithLines(w, string(body))
	}
	if strings.HasSuffix(sub, ".claude") {
		renderInlineComments(w, repo, sub)
	}
	wikiFooter(w)
}

// commentsLink shows a banner when viewing a .claude sidecar that has
// a sibling .claude.comments file, or when viewing the .comments file
// itself (pointing back to the sidecar).
func commentsLink(repo, sub string) string {
	if strings.HasSuffix(sub, ".claude") {
		sib := sub + ".comments"
		abs, ok := resolveRepoPath(repo, sib)
		if !ok {
			return ""
		}
		if _, err := os.Stat(abs); err != nil {
			return ""
		}
		return fmt.Sprintf(
			`<div class="wiki-comments-banner">Has comments: <a href="/gopher/wiki/%s/%s">%s</a></div>`,
			html.EscapeString(repo), html.EscapeString(sib), html.EscapeString(sib),
		)
	}
	if strings.HasSuffix(sub, ".claude.comments") {
		parent := strings.TrimSuffix(sub, ".comments")
		return fmt.Sprintf(
			`<div class="wiki-comments-banner">Sidecar: <a href="/gopher/wiki/%s/%s">%s</a></div>`,
			html.EscapeString(repo), html.EscapeString(parent), html.EscapeString(parent),
		)
	}
	return ""
}

// renderInlineComments appends the contents of a sibling .claude.comments
// file below the sidecar, so readers see comments in situ.
func renderInlineComments(w http.ResponseWriter, repo, sub string) {
	sib := sub + ".comments"
	abs, ok := resolveRepoPath(repo, sib)
	if !ok {
		return
	}
	body, err := os.ReadFile(abs)
	if err != nil {
		return
	}
	fmt.Fprint(w, `<div class="wiki-comments">`)
	fmt.Fprintf(w, `<h2>Comments <span class="muted">(%s)</span></h2>`, html.EscapeString(sib))
	renderCommentsSectioned(w, repo, sib, string(body))
	fmt.Fprint(w, `</div>`)
}

// renderCommentsSectioned splits the comments file on `## ` headings
// and renders each section with a reply form. Replies are `### `
// sub-sections inside the parent comment.
func renderCommentsSectioned(w http.ResponseWriter, repo, sub, body string) {
	intro, sections := splitCommentSections(body)
	if RenderMarkdown != nil && strings.TrimSpace(intro) != "" {
		fmt.Fprint(w, `<div class="wiki-md">`)
		fmt.Fprint(w, RenderMarkdown(intro))
		fmt.Fprint(w, `</div>`)
	}
	for _, sec := range sections {
		slug := slugify(sec.heading)
		fmt.Fprintf(w, `<div class="wiki-comment" id="c-%s">`, html.EscapeString(slug))
		if RenderMarkdown != nil {
			fmt.Fprint(w, `<div class="wiki-md">`)
			fmt.Fprint(w, RenderMarkdown("## "+sec.heading+"\n\n"+sec.body))
			fmt.Fprint(w, `</div>`)
		} else {
			fmt.Fprintf(w, `<pre>## %s\n\n%s</pre>`, html.EscapeString(sec.heading), html.EscapeString(sec.body))
		}
		fmt.Fprintf(w, `<form class="wiki-reply" method="POST" action="/gopher/wiki/%s/%s">`,
			html.EscapeString(repo), html.EscapeString(sub))
		fmt.Fprintf(w, `<input type="hidden" name="comment_slug" value="%s">`, html.EscapeString(slug))
		fmt.Fprint(w, `<textarea name="body" rows="12" placeholder="Reply..." style="width:100%;min-height:240px;font-size:15px;padding:10px;box-sizing:border-box;"></textarea><br>`)
		fmt.Fprint(w, `<button type="submit" name="author" value="Steve">Reply as Steve</button> `)
		fmt.Fprint(w, `<button type="submit" name="author" value="Claude">Reply as Claude</button>`)
		fmt.Fprint(w, `</form></div>`)
	}
}

type commentSection struct {
	heading string // text after "## "
	body    string // everything up to next "## " (includes "### " replies)
}

// splitCommentSections splits a markdown string on top-level `## `
// headings. The intro is everything before the first `## ` (usually
// a `# Title` line). Each section's body includes its `### ` replies.
func splitCommentSections(body string) (intro string, sections []commentSection) {
	lines := strings.Split(body, "\n")
	var cur *commentSection
	var introLines []string
	for _, line := range lines {
		if strings.HasPrefix(line, "## ") && !strings.HasPrefix(line, "### ") {
			if cur != nil {
				sections = append(sections, *cur)
			}
			h := strings.TrimPrefix(line, "## ")
			cur = &commentSection{heading: h}
			continue
		}
		if cur == nil {
			introLines = append(introLines, line)
		} else {
			cur.body += line + "\n"
		}
	}
	if cur != nil {
		sections = append(sections, *cur)
	}
	intro = strings.Join(introLines, "\n")
	return
}

// slugify turns a heading like "2026-04-15 · Claude · OPEN · meta"
// into "2026-04-15-claude-open-meta". Stable identifier for anchors.
func slugify(s string) string {
	var b strings.Builder
	prevDash := true
	for _, r := range strings.ToLower(s) {
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
	return strings.Trim(b.String(), "-")
}

// handleCommentReply appends a `### ` sub-heading under the matching
// `## ` parent, preserving the rest of the file.
func handleCommentReply(w http.ResponseWriter, r *http.Request, repo, sub string) {
	abs, ok := resolveRepoPath(repo, sub)
	if !ok {
		http.Error(w, "Invalid path", http.StatusBadRequest)
		return
	}
	if err := r.ParseForm(); err != nil {
		http.Error(w, "Bad form", http.StatusBadRequest)
		return
	}
	slug := r.FormValue("comment_slug")
	author := r.FormValue("author")
	origin := strings.TrimSpace(r.FormValue("origin"))
	replyBody := strings.TrimSpace(r.FormValue("body"))
	if slug == "" || author == "" || replyBody == "" {
		http.Redirect(w, r, "/gopher/wiki/"+repo+"/"+sub, http.StatusSeeOther)
		return
	}
	if origin != "" {
		author = author + " (" + origin + ")"
	}
	existing, err := os.ReadFile(abs)
	if err != nil {
		http.Error(w, "Cannot read", http.StatusInternalServerError)
		return
	}
	intro, sections := splitCommentSections(string(existing))
	found := false
	for i := range sections {
		if slugify(sections[i].heading) == slug {
			// Trim trailing blank lines, then append the reply.
			body := strings.TrimRight(sections[i].body, "\n")
			stamp := time.Now().Format("2006-01-02")
			reply := fmt.Sprintf("\n\n### %s · %s · reply\n\n%s\n", stamp, author, replyBody)
			sections[i].body = body + reply
			found = true
			break
		}
	}
	if !found {
		http.Error(w, "Comment not found: "+slug, http.StatusNotFound)
		return
	}
	var out strings.Builder
	out.WriteString(intro)
	if intro != "" && !strings.HasSuffix(intro, "\n") {
		out.WriteString("\n")
	}
	for _, sec := range sections {
		out.WriteString("## ")
		out.WriteString(sec.heading)
		out.WriteString("\n")
		out.WriteString(sec.body)
		if !strings.HasSuffix(sec.body, "\n") {
			out.WriteString("\n")
		}
	}
	if err := os.WriteFile(abs, []byte(out.String()), 0644); err != nil {
		http.Error(w, "Cannot write", http.StatusInternalServerError)
		return
	}
	location := repo + "/" + sub
	anchor := "#c-" + slug
	notify.Breadcrumb("wiki-comment", author, location, anchor, replyBody)
	if strings.HasPrefix(author, "Claude") {
		summary := "Claude replied on " + sub
		if origin != "" {
			summary = "Claude (" + origin + ") replied on " + sub
		}
		snippet := replyBody
		if len(snippet) > 200 {
			snippet = snippet[:200] + "…"
		}
		notify.Broadcast(notify.Event{
			Summary: summary,
			URL:     "/gopher/wiki/" + location + anchor,
			Kind:    "wiki-comment",
			Sender:  author,
			Snippet: snippet,
		})
	}
	http.Redirect(w, r, "/gopher/wiki/"+location+anchor, http.StatusSeeOther)
}

// sidecarLink returns a small HTML snippet cross-linking a source
// file to its .claude sidecar (or vice versa). Convention: sidecar
// shares the basename — `foo.go` ↔ `foo.claude`, also package-style
// `messages/messages.claude` ↔ `messages/messages.go`. Returns "" when
// there is no obvious pairing.
func sidecarLink(repo, sub string) string {
	ext := filepath.Ext(sub)
	if ext == "" {
		return ""
	}
	base := strings.TrimSuffix(sub, ext)

	if ext == ".claude" {
		// Find a sibling file with a different extension.
		dir := filepath.Dir(sub)
		abs, ok := resolveRepoPath(repo, dir)
		if !ok {
			return ""
		}
		entries, err := os.ReadDir(abs)
		if err != nil {
			return ""
		}
		want := filepath.Base(base) + "."
		self := filepath.Base(sub)
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			name := e.Name()
			if name == self {
				continue
			}
			if strings.HasPrefix(name, want) && !strings.HasSuffix(name, ".claude") {
				sib := filepath.Join(dir, name)
				return fmt.Sprintf(
					`<div class="wiki-sidecar">Source: <a href="/gopher/wiki/%s/%s">%s</a></div>`,
					html.EscapeString(repo), html.EscapeString(sib), html.EscapeString(sib),
				)
			}
		}
		return ""
	}

	sib := base + ".claude"
	abs, ok := resolveRepoPath(repo, sib)
	if !ok {
		return ""
	}
	if _, err := os.Stat(abs); err != nil {
		return ""
	}
	return fmt.Sprintf(
		`<div class="wiki-sidecar">Sidecar: <a href="/gopher/wiki/%s/%s">%s</a></div>`,
		html.EscapeString(repo), html.EscapeString(sib), html.EscapeString(sib),
	)
}

// renderSourceWithLines emits a <pre> where each source line is a
// <span class="line" id="L<n>">. Fragment #L42 or #L42-L57 highlights
// the range via the inline script in wikiHeader. Sharing a link to a
// specific section is the point: paste `…/file.go#L120-L140` into chat.
func renderSourceWithLines(w http.ResponseWriter, body string) {
	lines := strings.Split(body, "\n")
	// Avoid a trailing empty line from a terminating newline.
	if n := len(lines); n > 0 && lines[n-1] == "" {
		lines = lines[:n-1]
	}
	fmt.Fprint(w, `<pre class="wiki-src">`)
	for i, line := range lines {
		// No trailing newline between spans: .line is display:block,
		// and a literal \n inside <pre> renders as an extra blank line.
		fmt.Fprintf(w, `<span class="line" id="L%d">%s</span>`, i+1, html.EscapeString(line))
	}
	fmt.Fprint(w, `</pre>`)
}

// wikiTree lists a directory inside a repo.
func wikiTree(w http.ResponseWriter, repo, sub string) {
	abs, ok := resolveRepoPath(repo, sub)
	if !ok {
		http.Error(w, "Invalid path", http.StatusBadRequest)
		return
	}
	entries, err := os.ReadDir(abs)
	if err != nil {
		http.Error(w, "Cannot read dir", http.StatusNotFound)
		return
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].IsDir() != entries[j].IsDir() {
			return entries[i].IsDir()
		}
		return entries[i].Name() < entries[j].Name()
	})
	title := sub
	if title == "" {
		title = "/"
	}
	displayPath := repo + "/tree/" + sub
	wikiHeader(w, "Tree: "+title, displayPath, repo)
	fmt.Fprint(w, `<ul class="wiki-tree">`)
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") && name != ".gitignore" {
			continue
		}
		child := filepath.Join(sub, name)
		if e.IsDir() {
			fmt.Fprintf(w, `<li><a href="/gopher/wiki/%s/tree/%s">%s/</a></li>`,
				html.EscapeString(repo), html.EscapeString(child), html.EscapeString(name))
		} else {
			fmt.Fprintf(w, `<li><a href="/gopher/wiki/%s/%s">%s</a></li>`,
				html.EscapeString(repo), html.EscapeString(child), html.EscapeString(name))
		}
	}
	fmt.Fprint(w, `</ul>`)
	wikiFooter(w)
}

// wikiHeader writes wiki-specific HTML shell with a sidebar.
// `currentRepo` scopes the per-repo landmarks/tree links; empty at
// the landing page.
func wikiHeader(w http.ResponseWriter, title, currentPath, currentRepo string) {
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><title>%s — Wiki</title>
<style>
body { font-family: sans-serif; margin: 0; display: flex; min-height: 100vh; }
aside { width: 240px; background: #f4f4f0; padding: 16px; border-right: 1px solid #ccc;
        overflow-y: auto; max-height: 100vh; position: sticky; top: 0; font-size: 13px; }
aside h3 { margin: 16px 0 6px; color: #000080; font-size: 13px; }
aside ul { list-style: none; padding-left: 10px; margin: 4px 0; }
aside a { color: #000080; text-decoration: none; }
aside a:hover { text-decoration: underline; }
aside .muted { color: #888; font-size: 11px; }
aside .repo-current { font-weight: bold; background: #fff3a8; padding: 0 4px; }
main { flex: 1; padding: 24px 40px; max-width: 900px; }
h1 { color: #000080; } h2 { color: #000080; margin-top: 24px; }
a { color: #000080; }
pre.wiki-src { background: #f8f8f4; padding: 12px 12px 12px 0; border: 1px solid #ddd;
               overflow-x: auto; font-size: 16px; line-height: 1.2;
               counter-reset: wikiline; }
pre.wiki-src .line { display: block; counter-increment: wikiline; padding-left: 0.5em; }
pre.wiki-src .line::before { content: counter(wikiline); display: inline-block;
                             width: 3.5em; margin-right: 1em; color: #999;
                             text-align: right; user-select: none;
                             border-right: 1px solid #ddd; padding-right: 0.5em; }
pre.wiki-src .line.hilite { background: #fff3a8; }
pre.wiki-src .line:target { background: #fff3a8; }
.wiki-sidecar { background: #eef6ff; border: 1px solid #cfe2f7; padding: 6px 10px;
                margin: 0 0 12px; font-size: 13px; border-radius: 3px; }
.wiki-sidecar a { font-weight: bold; }
.wiki-comments-banner { background: #fff3a8; border: 1px solid #e6d670; padding: 6px 10px;
                margin: 0 0 12px; font-size: 13px; border-radius: 3px; }
.wiki-comments-banner a { font-weight: bold; }
.wiki-comments { margin-top: 32px; padding-top: 16px; border-top: 2px solid #ccc; }
.wiki-comments h2 { color: #000080; }
.wiki-comments .muted { color: #888; font-size: 12px; font-weight: normal; }
.wiki-comment { border: 1px solid #ddd; border-radius: 4px; padding: 10px 16px;
                margin: 12px 0; background: #fbfbf8; }
.wiki-comment h2 { margin-top: 4px; font-size: 15px; }
.wiki-comment h3 { margin-top: 12px; font-size: 13px; color: #555;
                   border-top: 1px dashed #ddd; padding-top: 8px; }
.wiki-reply { margin-top: 12px; padding-top: 8px; border-top: 1px dashed #ccc; }
.wiki-reply textarea { width: 100%; font-family: inherit; font-size: 15px;
                       line-height: 1.4; padding: 10px; box-sizing: border-box;
                       min-height: 200px; }
.wiki-reply button { margin-top: 6px; padding: 4px 10px; font-size: 13px; }
code { background: #f0f0ec; padding: 1px 4px; border-radius: 2px; }
pre code { background: none; padding: 0; }
.wiki-md table { border-collapse: collapse; margin: 8px 0; }
.wiki-md th, .wiki-md td { border: 1px solid #ccc; padding: 4px 10px; }
.wiki-md th { background: #000080; color: white; }
.wiki-tree { list-style: none; padding-left: 0; }
.wiki-tree li { padding: 2px 0; }
.breadcrumb { color: #888; font-size: 12px; margin-bottom: 16px; }
.breadcrumb a { color: #000080; }
</style>
<script>
(function () {
    // Accept #L42 or #L42-L57 (with or without the second 'L').
    function highlightFromHash() {
        document.querySelectorAll('.line.hilite').forEach(function (el) {
            el.classList.remove('hilite');
        });
        var m = location.hash.match(/^#L(\d+)(?:-L?(\d+))?$/);
        if (!m) return;
        var start = parseInt(m[1], 10);
        var end = m[2] ? parseInt(m[2], 10) : start;
        if (end < start) { var t = start; start = end; end = t; }
        for (var i = start; i <= end; i++) {
            var el = document.getElementById('L' + i);
            if (el) el.classList.add('hilite');
        }
        var first = document.getElementById('L' + start);
        if (first) first.scrollIntoView({ block: 'center' });
    }
    window.addEventListener('DOMContentLoaded', highlightFromHash);
    window.addEventListener('hashchange', highlightFromHash);
})();
</script>
</head><body>
` + NotificationWidget + `
<aside>
<h3><a href="/gopher/">← Gopher home</a></h3>
<h3><a href="/gopher/dm?user_id=2" style="background:#fff3a8;padding:2px 6px;border-radius:3px;">💬 DM Claude</a></h3>
<h3>Talk to Claude</h3>
<ul>
<li><a href="/gopher/dm?user_id=2" style="background:#fff3a8;padding:2px 8px;border-radius:3px;font-weight:bold;">💬 DM Claude</a></li>
<li><a href="/gopher/claude-issues" style="background:#ffe0e8;padding:2px 8px;border-radius:3px;font-weight:bold;">🗂️ Issues</a></li>
<li><a href="/gopher/claude-log" style="background:#e0f0ff;padding:2px 8px;border-radius:3px;font-weight:bold;">📝 Log</a></li>
</ul>
<h3><a href="/gopher/wiki/">Wiki home</a></h3>
<h3>Repos</h3>
<ul>`, html.EscapeString(title))
	for _, name := range wikiRepoOrder {
		cls := ""
		if name == currentRepo {
			cls = ` class="repo-current"`
		}
		fmt.Fprintf(w, `<li><a href="/gopher/wiki/%s/"%s>%s</a></li>`, name, cls, name)
	}
	fmt.Fprint(w, `</ul>`)
	// Inject notification bell (picks up SSE events from Claude).
	// Placed here so it appears on every wiki page. Must be in <body>.
	// (wikiHeader shells out the document structure in multiple
	// Fprint calls after this point, so emitting mid-stream is fine.)
	fmt.Fprint(w, NotificationWidget)

	if currentRepo == "gopher" || currentRepo == "" {
		fmt.Fprint(w, `
<h3>Gopher landmarks</h3>
<ul>
<li><a href="/gopher/wiki/gopher/README.md">README</a></li>
<li><a href="/gopher/wiki/gopher/DECISIONS.md">DECISIONS</a></li>
<li><a href="/gopher/wiki/gopher/DATABASE.md">DATABASE</a></li>
<li><a href="/gopher/wiki/gopher/TESTING.md">TESTING</a></li>
<li><a href="/gopher/wiki/gopher/TASKS.md">TASKS</a></li>
<li><a href="/gopher/wiki/gopher/LABELS.md">LABELS</a></li>
<li><a href="/gopher/wiki/gopher/GLOSSARY.md">GLOSSARY</a></li>
<li><a href="/gopher/wiki/gopher/FIXES.md">FIXES</a> <span class="muted">(running fixes log)</span></li>
</ul>
<h3>Browse Gopher</h3>
<ul>
<li><a href="/gopher/wiki/gopher/tree/">All files</a></li>
<li><a href="/gopher/wiki/gopher/tree/lynrummy">lynrummy/</a></li>
<li><a href="/gopher/wiki/gopher/tree/critters">critters/</a></li>
<li><a href="/gopher/wiki/gopher/tree/views">views/</a></li>
<li><a href="/gopher/wiki/gopher/tree/agent_collab">agent_collab/</a></li>
<li><a href="/gopher/wiki/gopher/tree/cmd">cmd/</a></li>
<li><a href="/gopher/wiki/gopher/tree/tools">tools/</a></li>
</ul>`)
	}

	if currentRepo == "elm-critters" {
		fmt.Fprint(w, `
<h3>elm-critters</h3>
<ul>
<li><a href="/gopher/wiki/elm-critters/README.md">README</a></li>
<li><a href="/gopher/wiki/elm-critters/src/Main.elm">Main.elm</a></li>
<li><a href="/gopher/wiki/elm-critters/tree/">All files</a></li>
</ul>
<h3>Live product</h3>
<ul><li><a href="/gopher/critters/">Critter studies portal</a></li></ul>`)
	}

	if currentRepo == "elm-lynrummy" {
		fmt.Fprint(w, `
<h3>elm-lynrummy</h3>
<ul>
<li><a href="/gopher/wiki/elm-lynrummy/README.md">README</a></li>
<li><a href="/gopher/wiki/elm-lynrummy/tree/src">src/</a></li>
<li><a href="/gopher/wiki/elm-lynrummy/tree/">All files</a></li>
</ul>
<h3>Live product</h3>
<ul><li><a href="/gopher/game-lobby">Game lobby</a></li></ul>`)
	}

	fmt.Fprint(w, `
<h3>Products</h3>
<ul>
<li><a href="/gopher/">Gopher home</a></li>
<li><a href="/gopher/critters/">Critter studies</a></li>
<li><a href="/gopher/game-lobby">LynRummy</a></li>
</ul>
</aside>
<main>
<div class="breadcrumb"><a href="/gopher/wiki/">/</a> `)
	fmt.Fprint(w, html.EscapeString(currentPath))
	fmt.Fprintf(w, `</div>
<h1>%s</h1>
`, html.EscapeString(title))
}

func wikiFooter(w http.ResponseWriter) {
	fmt.Fprint(w, `</main></body></html>`)
}
