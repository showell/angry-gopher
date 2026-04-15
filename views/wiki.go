// Wiki view — browser-based reader for the repo's docs, sidecars,
// and source files. V1 is read-only.
//
//   /gopher/wiki/                  — home (renders README.md)
//   /gopher/wiki/<path>            — render any file in the repo
//   /gopher/wiki/tree              — directory listing at repo root
//   /gopher/wiki/tree/<subpath>    — directory listing at subpath
//
// Files are resolved against the current working directory (the
// repo root when the server is started via ops/start).
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

// wikiRoot returns the repo root (current working directory when the
// server was started). Sufficient for V1.
func wikiRoot() string {
	cwd, err := os.Getwd()
	if err != nil {
		return "."
	}
	return cwd
}

// resolveWikiPath joins the request subpath onto the repo root and
// refuses anything that escapes the root (path traversal guard).
func resolveWikiPath(sub string) (string, bool) {
	root := wikiRoot()
	cleaned := filepath.Clean(filepath.Join(root, sub))
	rel, err := filepath.Rel(root, cleaned)
	if err != nil || strings.HasPrefix(rel, "..") {
		return "", false
	}
	return cleaned, true
}

// HandleWiki dispatches all /gopher/wiki/* requests.
func HandleWiki(w http.ResponseWriter, r *http.Request) {
	if RequireAuth(w, r) == 0 {
		return
	}
	sub := strings.TrimPrefix(r.URL.Path, "/gopher/wiki/")
	sub = strings.TrimPrefix(sub, "/gopher/wiki") // handles bare /gopher/wiki

	if sub == "" || sub == "/" {
		wikiRender(w, "README.md", "Wiki")
		return
	}

	if strings.HasPrefix(sub, "tree") {
		rest := strings.TrimPrefix(sub, "tree")
		rest = strings.TrimPrefix(rest, "/")
		wikiTree(w, rest)
		return
	}

	wikiRender(w, sub, sub)
}

// wikiRender reads a file and serves it — markdown for .md,
// preformatted for everything else.
func wikiRender(w http.ResponseWriter, sub, title string) {
	abs, ok := resolveWikiPath(sub)
	if !ok {
		http.Error(w, "Invalid path", http.StatusBadRequest)
		return
	}
	info, err := os.Stat(abs)
	if err != nil {
		http.Error(w, "Not found: "+sub, http.StatusNotFound)
		return
	}
	if info.IsDir() {
		wikiTree(w, sub)
		return
	}
	body, err := os.ReadFile(abs)
	if err != nil {
		http.Error(w, "Cannot read", http.StatusInternalServerError)
		return
	}

	wikiHeader(w, title, sub)
	if strings.HasSuffix(sub, ".md") && RenderMarkdown != nil {
		fmt.Fprint(w, `<div class="wiki-md">`)
		fmt.Fprint(w, RenderMarkdown(string(body)))
		fmt.Fprint(w, `</div>`)
	} else {
		fmt.Fprintf(w, `<pre class="wiki-src">%s</pre>`, html.EscapeString(string(body)))
	}
	wikiFooter(w)
}

// wikiTree lists a directory.
func wikiTree(w http.ResponseWriter, sub string) {
	abs, ok := resolveWikiPath(sub)
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
	wikiHeader(w, "Tree: "+title, "tree/"+sub)
	fmt.Fprint(w, `<ul class="wiki-tree">`)
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") && name != ".gitignore" {
			continue
		}
		child := filepath.Join(sub, name)
		if e.IsDir() {
			fmt.Fprintf(w, `<li><a href="/gopher/wiki/tree/%s">%s/</a></li>`,
				html.EscapeString(child), html.EscapeString(name))
		} else {
			fmt.Fprintf(w, `<li><a href="/gopher/wiki/%s">%s</a></li>`,
				html.EscapeString(child), html.EscapeString(name))
		}
	}
	fmt.Fprint(w, `</ul>`)
	wikiFooter(w)
}

// wikiHeader writes wiki-specific HTML shell with a sidebar.
// The regular PageHeader is too narrow (700px) for doc reading.
func wikiHeader(w http.ResponseWriter, title, currentPath string) {
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
main { flex: 1; padding: 24px 40px; max-width: 900px; }
h1 { color: #000080; } h2 { color: #000080; margin-top: 24px; }
a { color: #000080; }
pre.wiki-src { background: #f8f8f4; padding: 12px; border: 1px solid #ddd;
               overflow-x: auto; font-size: 12px; line-height: 1.4; }
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
</head><body>
<aside>
<h3><a href="/gopher/wiki/">Wiki Home</a></h3>
<h3>Landmarks</h3>
<ul>
<li><a href="/gopher/wiki/README.md">README</a></li>
<li><a href="/gopher/wiki/DECISIONS.md">DECISIONS</a></li>
<li><a href="/gopher/wiki/DATABASE.md">DATABASE</a></li>
<li><a href="/gopher/wiki/TESTING.md">TESTING</a></li>
<li><a href="/gopher/wiki/TASKS.md">TASKS</a></li>
<li><a href="/gopher/wiki/LABELS.md">LABELS</a></li>
</ul>
<h3>Browse</h3>
<ul>
<li><a href="/gopher/wiki/tree/">Repo tree</a></li>
<li><a href="/gopher/wiki/tree/lynrummy">lynrummy/</a></li>
<li><a href="/gopher/wiki/tree/views">views/</a></li>
<li><a href="/gopher/wiki/tree/agent_collab">agent_collab/</a></li>
<li><a href="/gopher/wiki/tree/cmd">cmd/</a></li>
<li><a href="/gopher/wiki/tree/tools">tools/</a></li>
</ul>
<h3>Back</h3>
<ul><li><a href="/gopher/">Gopher home</a></li></ul>
</aside>
<main>
<div class="breadcrumb"><a href="/gopher/wiki/">/</a> %s</div>
<h1>%s</h1>
`, html.EscapeString(title), html.EscapeString(currentPath), html.EscapeString(title))
}

func wikiFooter(w http.ResponseWriter) {
	fmt.Fprint(w, `</main></body></html>`)
}
