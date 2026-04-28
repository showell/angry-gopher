// Wiki view — browser-based reader for repo docs across all
// tracked repos.
//
// Mounted at /gopher/docs/<repo>/<path>. /gopher/wiki/* is a
// legacy redirect into /gopher/docs/*.
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
)

// wikiRepos maps a short repo name (used in URLs) to its filesystem
// root. Order is the display order in the sidebar.
var wikiRepoOrder = []string{"gopher", "elm-lynrummy"}

var wikiRepos = map[string]string{
	"gopher":       "", // resolved to cwd lazily
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

// HandleDocs is the public entry point.
func HandleDocs(w http.ResponseWriter, r *http.Request) { handleWikiSection(w, r, "docs") }

// HandleWikiLegacy 301-redirects any /gopher/wiki/* request to its
// /gopher/docs/* equivalent. Docs is the more common entry point;
// links on claude-issues, DMs, and external bookmarks from today
// still land somewhere useful.
func HandleWikiLegacy(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/gopher/wiki")
	target := "/gopher/docs" + rest
	if r.URL.RawQuery != "" {
		target += "?" + r.URL.RawQuery
	}
	http.Redirect(w, r, target, http.StatusMovedPermanently)
}

func handleWikiSection(w http.ResponseWriter, r *http.Request, section string) {
	prefix := "/gopher/" + section
	sub := strings.TrimPrefix(r.URL.Path, prefix+"/")
	sub = strings.TrimPrefix(sub, prefix)
	sub = strings.TrimPrefix(sub, "/")

	if sub == "" {
		wikiLanding(w, section)
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

	bare := r.URL.Query().Get("bare") == "1"

	if rest == "" || rest == "/" {
		wikiRenderMaybeBare(w, section, repo, "README.md", repo+"/README.md", bare)
		return
	}

	if strings.HasPrefix(rest, "tree") {
		treeRest := strings.TrimPrefix(rest, "tree")
		treeRest = strings.TrimPrefix(treeRest, "/")
		wikiTree(w, section, repo, treeRest)
		return
	}

	wikiRenderMaybeBare(w, section, repo, rest, repo+"/"+rest, bare)
}

// wikiRenderMaybeBare dispatches to the full-chrome renderer or a
// bare-content renderer (for iframe embeds on the Docs landing).
func wikiRenderMaybeBare(w http.ResponseWriter, section, repo, sub, displayPath string, bare bool) {
	if bare {
		wikiRenderBare(w, section, repo, sub, displayPath)
		return
	}
	wikiRender(w, section, repo, sub, displayPath)
}

// wikiRenderBare renders just the file content for iframe embedding:
// minimal HTML shell, no sidebar, no top/bottom chrome, no breadcrumb.
func wikiRenderBare(w http.ResponseWriter, section, repo, sub, displayPath string) {
	abs, ok := resolveRepoPath(repo, sub)
	if !ok {
		http.Error(w, "Invalid path", http.StatusBadRequest)
		return
	}
	body, err := os.ReadFile(abs)
	if err != nil {
		http.Error(w, "Cannot read", http.StatusInternalServerError)
		return
	}
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><title>%s</title>
<style>
body { font-family: sans-serif; margin: 0; padding: 24px 32px 40px;
       max-width: 820px; color: #222; line-height: 1.5; }
h1 { color: #000080; margin-top: 0; }
h2, h3 { color: #000080; }
a { color: #000080; }
code { background: #f0f0ec; padding: 1px 4px; border-radius: 2px; }
pre { background: #f8f8f4; padding: 12px; border: 1px solid #ddd; overflow-x: auto; }
pre code { background: none; padding: 0; }
table { border-collapse: collapse; margin: 8px 0; }
th, td { border: 1px solid #ccc; padding: 4px 10px; }
th { background: #000080; color: white; }
.wiki-path { color: #888; font-size: 12px; font-family: "Courier New", monospace;
             margin-bottom: 12px; }
.wiki-path a { color: #555; text-decoration: none; }
.wiki-path a:hover { text-decoration: underline; }
</style></head><body>`, html.EscapeString(displayPath))
	fmt.Fprintf(w, `<div class="wiki-path"><a href="/gopher/%s/%s/%s" target="_top">Open in full page ↗</a> · %s</div>`,
		html.EscapeString(section), html.EscapeString(repo), html.EscapeString(sub), html.EscapeString(displayPath))
	if strings.HasSuffix(sub, ".md") && RenderMarkdown != nil {
		fmt.Fprint(w, `<div class="wiki-md">`)
		fmt.Fprint(w, RenderMarkdown(string(body)))
		fmt.Fprint(w, `</div>`)
	} else {
		fmt.Fprint(w, `<pre style="white-space:pre-wrap">`)
		fmt.Fprint(w, html.EscapeString(string(body)))
		fmt.Fprint(w, `</pre>`)
	}
	fmt.Fprint(w, `</body></html>`)
}

func wikiLanding(w http.ResponseWriter, section string) {
	renderDocsLanding(w)
}

// renderDocsLanding is the Docs landing: a Google-ish search box, a
// flat A–Z index of every .md across all repos, and an iframe preview
// pane for bulk reading without losing your place in the index.
func renderDocsLanding(w http.ResponseWriter) {
	docs := collectAllDocs()
	renderDocsLandingHTML(w, docs)
}

// renderDocsLandingHTML is the actual HTML emitter — kept separate so
// we can reason about the markup without the file walking.
func renderDocsLandingHTML(w http.ResponseWriter, docs []docEntry) {
	fmt.Fprint(w, `<!DOCTYPE html>
<html><head><title>Docs — Angry Gopher</title>
<style>
body { margin: 0; padding: 0; display: flex; flex-direction: column; min-height: 100vh;
       font-family: sans-serif; color: #1d1a14; background: #fff; }
.docs-layout { flex: 1; display: flex; flex-direction: column; min-height: 0; }
.docs-searchbar { padding: 14px 24px; background: #fafafa; border-bottom: 1px solid #ddd; }
.docs-searchbar input { width: 100%; max-width: 900px; display: block; margin: 0 auto;
                        padding: 10px 14px; font-size: 16px; border: 1px solid #bbb;
                        border-radius: 20px; box-sizing: border-box; outline: none; }
.docs-searchbar input:focus { border-color: #000080; box-shadow: 0 0 0 3px #e0e8ff; }
.docs-split { flex: 1; display: flex; min-height: 0; }
.docs-index { width: 340px; border-right: 1px solid #ddd; overflow-y: auto;
              background: #fafafa; padding: 8px 0; }
.docs-index ul { list-style: none; margin: 0; padding: 0; }
.docs-index li.hidden { display: none; }
.docs-index a { display: block; padding: 5px 14px; font-family: "Courier New", monospace;
                font-size: 13px; color: #222; text-decoration: none;
                border-left: 3px solid transparent; }
.docs-index a:hover { background: #f0f0ff; }
.docs-index a.active { background: #e6eaf6; border-left-color: #000080; font-weight: bold; }
.docs-index .group-heading { padding: 10px 14px 4px; font-size: 11px; text-transform: uppercase;
                             letter-spacing: 0.06em; color: #888; font-weight: bold; }
.docs-count { padding: 6px 14px; color: #888; font-size: 12px; }
.docs-preview { flex: 1; position: relative; background: #fff; }
.docs-preview iframe { width: 100%; height: 100%; border: none; display: block; }
.docs-preview .empty-state { padding: 60px 40px; color: #888; text-align: center; font-size: 14px; }
@media (max-width: 820px) {
  .docs-split { flex-direction: column; }
  .docs-index { width: 100%; max-height: 40vh; border-right: none; border-bottom: 1px solid #ddd; }
}
` + AppChromeCSS + `
</style>
</head><body>`)
	AppChromeTop(w, "docs")
	fmt.Fprint(w, `<div class="docs-layout">
<div class="docs-searchbar">
  <input id="docs-search" type="search" placeholder="Search docs — filename or path (e.g. decisions, testing, README)" autofocus>
</div>
<div class="docs-split">
<div class="docs-index">`)
	fmt.Fprintf(w, `<div class="docs-count"><span id="docs-count">%d</span> documents</div><ul id="docs-list">`, len(docs))
	lastRepo := ""
	for _, d := range docs {
		if d.repo != lastRepo {
			fmt.Fprintf(w, `<li class="group-heading" data-repo="%s">%s</li>`,
				html.EscapeString(d.repo), html.EscapeString(d.repo))
			lastRepo = d.repo
		}
		fmt.Fprintf(w, `<li><a href="/gopher/docs/%s/%s?bare=1" data-repo="%s" data-path="%s">%s</a></li>`,
			html.EscapeString(d.repo), html.EscapeString(d.path),
			html.EscapeString(d.repo), html.EscapeString(d.path), html.EscapeString(d.path),
		)
	}
	fmt.Fprint(w, `</ul></div>
<div class="docs-preview">
  <iframe id="docs-preview" src="about:blank"></iframe>
  <div id="docs-preview-empty" class="empty-state">
    Pick a doc from the left to start reading. Use the searchbar to filter by filename or path.
  </div>
</div>
</div>
</div>
<script>
(function(){
  var search = document.getElementById('docs-search');
  var list = document.getElementById('docs-list');
  var count = document.getElementById('docs-count');
  var iframe = document.getElementById('docs-preview');
  var empty = document.getElementById('docs-preview-empty');
  var items = Array.prototype.slice.call(list.querySelectorAll('li a'));
  var groups = Array.prototype.slice.call(list.querySelectorAll('li.group-heading'));

  function filter() {
    var q = search.value.trim().toLowerCase();
    var visible = 0;
    var perRepo = {};
    items.forEach(function(a){
      var hay = (a.getAttribute('data-repo') + '/' + a.getAttribute('data-path')).toLowerCase();
      var match = q === '' || hay.indexOf(q) !== -1;
      a.parentElement.classList.toggle('hidden', !match);
      if (match) {
        visible++;
        var r = a.getAttribute('data-repo');
        perRepo[r] = (perRepo[r] || 0) + 1;
      }
    });
    groups.forEach(function(g){
      var r = g.getAttribute('data-repo');
      g.classList.toggle('hidden', !perRepo[r]);
    });
    count.textContent = visible;
  }
  search.addEventListener('input', filter);

  list.addEventListener('click', function(e){
    var a = e.target.closest('a');
    if (!a) return;
    e.preventDefault();
    items.forEach(function(x){ x.classList.remove('active'); });
    a.classList.add('active');
    iframe.src = a.getAttribute('href');
    empty.style.display = 'none';
  });

  search.addEventListener('keydown', function(e){
    if (e.key === 'Enter') {
      var first = items.find(function(a){ return !a.parentElement.classList.contains('hidden'); });
      if (first) first.click();
    } else if (e.key === 'Escape') {
      search.value = '';
      filter();
    }
  });
})();
</script>`)
	AppChromeBottom(w)
	fmt.Fprint(w, `</body></html>`)
}

type docEntry struct {
	repo string
	path string
}

// collectAllDocs walks every tracked repo for *.md files and returns
// a flat slice sorted A–Z by repo then path. Skips hidden directories
// and common vendored/build trees.
func collectAllDocs() []docEntry {
	skipDirs := map[string]bool{
		"node_modules": true, "elm-stuff": true, ".git": true,
		"dist": true, "build": true, "bin": true,
	}
	var out []docEntry
	for _, repo := range wikiRepoOrder {
		root, ok := repoRoot(repo)
		if !ok {
			continue
		}
		filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return nil
			}
			if info.IsDir() {
				name := info.Name()
				if path != root && strings.HasPrefix(name, ".") {
					return filepath.SkipDir
				}
				if skipDirs[name] {
					return filepath.SkipDir
				}
				return nil
			}
			if !strings.HasSuffix(info.Name(), ".md") {
				return nil
			}
			rel, err := filepath.Rel(root, path)
			if err != nil {
				return nil
			}
			out = append(out, docEntry{repo: repo, path: rel})
			return nil
		})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].repo != out[j].repo {
			return out[i].repo < out[j].repo
		}
		return out[i].path < out[j].path
	})
	return out
}

func sectionTitle(section string) string {
	return "Docs"
}

// sectionCSS returns an extra <style> block that layers on top of the
// base wiki stylesheet. Docs gets a "physical library" treatment —
// serif, cream paper, black ink; Code keeps the default look.
func sectionCSS(section string) string {
	if section != "docs" {
		return ""
	}
	return `<style>
body, main, aside { background: #faf7ef; }
body { color: #1d1a14; }
aside { background: #f1ece0; border-right: 1px solid #c9bfa7; }
main { font-family: Georgia, "Times New Roman", serif; font-size: 16px; line-height: 1.65;
       max-width: 720px; padding: 36px 48px 64px; }
main h1, main h2, main h3 { font-family: Georgia, "Times New Roman", serif;
                            color: #1d1a14; letter-spacing: 0.01em; }
main h1 { font-size: 34px; font-weight: normal; border-bottom: 1px solid #1d1a14;
          padding-bottom: 6px; margin-bottom: 24px; }
main h2 { font-size: 22px; font-weight: normal; font-style: italic; margin-top: 32px; }
main h3 { font-size: 18px; font-weight: bold; margin-top: 20px; }
main a { color: #1d1a14; text-decoration: underline; text-decoration-thickness: 1px; }
main a:hover { background: #f0e6c6; }
main p { margin: 0 0 14px; text-align: justify; hyphens: auto; }
main em { font-style: italic; }
main code { background: #efe9d7; color: #1d1a14; padding: 0 4px; border-radius: 0;
            font-family: "Courier New", monospace; font-size: 14px; }
main pre { background: #efe9d7; border: 1px solid #c9bfa7; border-radius: 0; }
main .wiki-md table { border: 1px solid #c9bfa7; }
main .wiki-md th { background: #1d1a14; color: #faf7ef; font-family: Georgia, serif;
                   font-weight: normal; letter-spacing: 0.04em; }
main .wiki-md td { border-color: #c9bfa7; }
.breadcrumb { font-family: Georgia, serif; font-style: italic; color: #5c5547; }
.breadcrumb a { color: #1d1a14; }
aside h3 { color: #5c5547; }
aside h3 a { color: #1d1a14; font-style: italic; font-weight: normal; }
aside a { color: #1d1a14; }
aside .repo-current { background: #e6dcc0; }
</style>`
}

// wikiRender reads a file and serves it — markdown for .md,
// preformatted for everything else.
func wikiRender(w http.ResponseWriter, section, repo, sub, displayPath string) {
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
		wikiTree(w, section, repo, sub)
		return
	}
	body, err := os.ReadFile(abs)
	if err != nil {
		http.Error(w, "Cannot read", http.StatusInternalServerError)
		return
	}

	wikiHeader(w, section, sub, displayPath, repo)
	if strings.HasSuffix(sub, ".md") && RenderMarkdown != nil {
		fmt.Fprint(w, `<div class="wiki-md">`)
		fmt.Fprint(w, RenderMarkdown(string(body)))
		fmt.Fprint(w, `</div>`)
	} else {
		renderSourceWithLines(w, string(body))
	}
	wikiFooter(w)
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
func wikiTree(w http.ResponseWriter, section, repo, sub string) {
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
	wikiHeader(w, section, "Tree: "+title, displayPath, repo)
	fmt.Fprint(w, `<ul class="wiki-tree">`)
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") && name != ".gitignore" {
			continue
		}
		child := filepath.Join(sub, name)
		if e.IsDir() {
			fmt.Fprintf(w, `<li><a href="/gopher/%s/%s/tree/%s">%s/</a></li>`,
				html.EscapeString(section), html.EscapeString(repo), html.EscapeString(child), html.EscapeString(name))
		} else {
			fmt.Fprintf(w, `<li><a href="/gopher/%s/%s/%s">%s</a></li>`,
				html.EscapeString(section), html.EscapeString(repo), html.EscapeString(child), html.EscapeString(name))
		}
	}
	fmt.Fprint(w, `</ul>`)
	wikiFooter(w)
}

// wikiHeader writes wiki-specific HTML shell with a sidebar.
// `currentRepo` scopes the per-repo landmarks/tree links; empty at
// the landing page.
func wikiHeader(w http.ResponseWriter, section, title, currentPath, currentRepo string) {
	secLabel := sectionTitle(section)
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><title>%s — %s</title>`, html.EscapeString(title), html.EscapeString(secLabel))
	fmt.Fprint(w, `
<style>
body { font-family: sans-serif; margin: 0; display: flex; flex-direction: column;
       min-height: 100vh; }
.app-body-wiki { display: flex; flex: 1; }
aside { width: 240px; background: #f4f4f0; padding: 16px; border-right: 1px solid #ccc;
        overflow-y: auto; max-height: 100vh; position: sticky; top: 0; font-size: 13px; }
aside h3 { margin: 16px 0 6px; color: #444; font-size: 12px; font-weight: 600;
           text-transform: uppercase; letter-spacing: 0.04em; }
aside h3 a { color: #000080; text-transform: none; letter-spacing: 0; font-size: 13px; }
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
code { background: #f0f0ec; padding: 1px 4px; border-radius: 2px; }
pre code { background: none; padding: 0; }
.wiki-md table { border-collapse: collapse; margin: 8px 0; }
.wiki-md th, .wiki-md td { border: 1px solid #ccc; padding: 4px 10px; }
.wiki-md th { background: #000080; color: white; }
.wiki-tree { list-style: none; padding-left: 0; }
.wiki-tree li { padding: 2px 0; }
.breadcrumb { color: #888; font-size: 12px; margin-bottom: 16px; }
.breadcrumb a { color: #000080; }
` + AppChromeCSS + `
</style>
` + sectionCSS(section) + `
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
`)
	AppChromeTop(w, section)
	fmt.Fprint(w, `<div class="app-body-wiki">`)
	fmt.Fprint(w, `<aside>`)
	fmt.Fprint(w, `<h3>Talk to Claude</h3>
<ul>
<li><a href="/gopher/dm?user_id=2" style="background:#fff3a8;padding:2px 8px;border-radius:3px;font-weight:bold;">💬 DM Claude</a></li>
<li><a href="/gopher/claude-issues" style="background:#ffe0e8;padding:2px 8px;border-radius:3px;font-weight:bold;">🗂️ Issues</a></li>
</ul>`)
	fmt.Fprintf(w, `<h3><a href="/gopher/%s/">%s home</a></h3>`, html.EscapeString(section), html.EscapeString(secLabel))
	fmt.Fprint(w, `<h3>Repos</h3><ul>`)
	for _, name := range wikiRepoOrder {
		cls := ""
		if name == currentRepo {
			cls = ` class="repo-current"`
		}
		fmt.Fprintf(w, `<li><a href="/gopher/%s/%s/"%s>%s</a></li>`, html.EscapeString(section), name, cls, name)
	}
	fmt.Fprint(w, `</ul>`)

	// Per-section sidebar content. Both sections still show both
	// flavors (docs + tree) so you can navigate across — section
	// only controls which is foregrounded.
	if currentRepo == "gopher" || currentRepo == "" {
		landmarks := fmt.Sprintf(`
<h3>Gopher landmarks</h3>
<ul>
<li><a href="/gopher/%[1]s/gopher/README.md">README</a></li>
<li><a href="/gopher/%[1]s/gopher/TESTING.md">TESTING</a></li>
<li><a href="/gopher/%[1]s/gopher/LABELS.md">LABELS</a></li>
<li><a href="/gopher/%[1]s/gopher/GLOSSARY.md">GLOSSARY</a></li>
<li><a href="/gopher/%[1]s/gopher/PATTERNS.md">PATTERNS</a></li>
<li><a href="/gopher/%[1]s/gopher/BRIDGES.md">BRIDGES</a></li>
</ul>`, html.EscapeString(section))
		tree := fmt.Sprintf(`
<h3>Browse Gopher</h3>
<ul>
<li><a href="/gopher/%[1]s/gopher/tree/">All files</a></li>
<li><a href="/gopher/%[1]s/gopher/tree/games">games/</a></li>
<li><a href="/gopher/%[1]s/gopher/tree/views">views/</a></li>
<li><a href="/gopher/%[1]s/gopher/tree/agent_collab">agent_collab/</a></li>
<li><a href="/gopher/%[1]s/gopher/tree/cmd">cmd/</a></li>
<li><a href="/gopher/%[1]s/gopher/tree/tools">tools/</a></li>
</ul>`, html.EscapeString(section))
		if section == "code" {
			fmt.Fprint(w, tree, landmarks)
		} else {
			fmt.Fprint(w, landmarks, tree)
		}
	}

	if currentRepo == "elm-lynrummy" {
		fmt.Fprintf(w, `
<h3>elm-lynrummy</h3>
<ul>
<li><a href="/gopher/%[1]s/elm-lynrummy/README.md">README</a></li>
<li><a href="/gopher/%[1]s/elm-lynrummy/tree/src">src/</a></li>
<li><a href="/gopher/%[1]s/elm-lynrummy/tree/">All files</a></li>
</ul>
<h3>Live product</h3>
<ul><li><a href="/gopher/game-lobby">Game lobby</a></li></ul>`, html.EscapeString(section))
	}

	fmt.Fprint(w, `
<h3>Products</h3>
<ul>
<li><a href="/gopher/">Gopher home</a></li>
<li><a href="/gopher/game-lobby">LynRummy</a></li>
</ul>
</aside>
<main>`)
	fmt.Fprintf(w, `<div class="breadcrumb"><a href="/gopher/%s/">/</a> %s</div>`,
		html.EscapeString(section), html.EscapeString(currentPath))
	fmt.Fprintf(w, `<h1>%s</h1>`, html.EscapeString(title))
}

func wikiFooter(w http.ResponseWriter) {
	fmt.Fprint(w, `</main></div>`)
	AppChromeBottom(w)
	fmt.Fprint(w, `</body></html>`)
}
