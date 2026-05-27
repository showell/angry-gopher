// Docs page: a three-pane authoring surface inside the chat subsystem.
// Left = doc list (per-user), middle = textarea (debounced autosave to
// /chat/docs/save), right = live render (debounced fetch to
// /chat/docs/render, reuses RenderChatMarkdown so docs and chat messages
// render identically).
//
// All endpoints require a member session and act on CurrentUser only —
// never a user id from the request — so each member can only read,
// write, and create their own docs.
package chat

import (
	"angry-gopher/server/users"
	"angry-gopher/server/web"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"strings"
)

// maxDocBytes caps a single doc body. Generous — these are for longer
// pieces — but bounded so a runaway client can't fill the disk.
const maxDocBytes = 1 << 20 // 1 MiB

// HandleDocs serves /chat/docs: the three-pane page. ?d=<slug> picks an
// existing doc; omitted or unknown slug shows the editor empty (with a
// "pick or create one" nudge if there are no docs yet).
func HandleDocs(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/chat/docs" {
		http.NotFound(w, r)
		return
	}
	user := requireMember(w, r, "/chat/docs")
	if user.ID == "" {
		return
	}
	docs, err := ListUserDocs(user.ID)
	if err != nil {
		http.Error(w, "list docs: "+err.Error(), http.StatusInternalServerError)
		return
	}
	slug := strings.TrimSpace(r.URL.Query().Get("d"))
	if slug != "" && !validDocSlug(slug) {
		http.Redirect(w, r, "/chat/docs", http.StatusSeeOther)
		return
	}
	// Unknown slug → drop the ?d= so the page state stays consistent.
	if slug != "" && !docExists(docs, slug) {
		http.Redirect(w, r, "/chat/docs", http.StatusSeeOther)
		return
	}
	body := ""
	if slug != "" {
		if body, err = ReadUserDoc(user.ID, slug); err != nil {
			http.Error(w, "read doc: "+err.Error(), http.StatusInternalServerError)
			return
		}
	}
	renderDocsPage(w, user, docs, slug, body)
}

func docExists(docs []DocSummary, slug string) bool {
	for _, d := range docs {
		if d.Slug == slug {
			return true
		}
	}
	return false
}

// HandleDocsNew creates a new (empty) doc and redirects to it. Title is
// required (otherwise the user's dir gets an "untitled" file silently).
func HandleDocsNew(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Redirect(w, r, "/chat/docs", http.StatusSeeOther)
		return
	}
	user := requireMember(w, r, "/chat/docs")
	if user.ID == "" {
		return
	}
	title := strings.TrimSpace(r.FormValue("title"))
	if title == "" {
		http.Redirect(w, r, "/chat/docs", http.StatusSeeOther)
		return
	}
	slug, err := CreateUserDoc(user.ID, title)
	if err != nil {
		http.Error(w, "create doc: "+err.Error(), http.StatusInternalServerError)
		return
	}
	http.Redirect(w, r, "/chat/docs?d="+url.QueryEscape(slug), http.StatusSeeOther)
}

// HandleDocsSave overwrites an existing doc's body (autosave target).
// Returns 204 on success; the client never needs the body back. A POST
// for an unknown slug is rejected — autosave shouldn't be able to spawn
// a doc from a stale URL.
func HandleDocsSave(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	user := requireMember(w, r, "/chat/docs")
	if user.ID == "" {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxDocBytes)
	if err := r.ParseForm(); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			http.Error(w, "doc too large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	slug := strings.TrimSpace(r.FormValue("slug"))
	body := r.FormValue("body")
	if !validDocSlug(slug) {
		http.Error(w, "bad slug", http.StatusBadRequest)
		return
	}
	if err := WriteUserDoc(user.ID, slug, body); err != nil {
		http.Error(w, "save: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// HandleDocsRender renders posted markdown to HTML for the live-preview
// pane. Reuses RenderChatMarkdown (goldmark + bluemonday + linkifyMsgRefs)
// so docs and chat messages render identically, including the same XSS
// protections.
func HandleDocsRender(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !users.IsMember(r) {
		http.Error(w, "members only", http.StatusForbidden)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxDocBytes)
	if err := r.ParseForm(); err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			http.Error(w, "body too large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	body := r.FormValue("body")
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = io.WriteString(w, string(RenderChatMarkdown(body)))
}

// DocsJSPath is the embedded docs client bundle (committed, hand-written;
// not build-generated). Served at /chat/docs.js.
var DocsJSPath = "chat/docs.js"

// HandleDocsJS serves the docs client script from the embedded assets.
func HandleDocsJS(w http.ResponseWriter, r *http.Request) {
	web.ServeJS(w, DocsJSPath, "docs.js missing from the binary")
}

func renderDocsPage(w http.ResponseWriter, user users.User, docs []DocSummary, slug, body string) {
	chatPageHeader(w, "Docs", user, "docs")
	fmt.Fprint(w, docsCSS)
	fmt.Fprint(w, `<div class="docs-layout">`)

	// Left pane: doc list + "+ New" form.
	fmt.Fprint(w, `<aside class="docs-list">`)
	fmt.Fprint(w, `<form method="post" action="/chat/docs/new" class="docs-new">`+
		`<input type="text" name="title" placeholder="New doc title" autocomplete="off" maxlength="80" required>`+
		`<button type="submit">+ New</button></form>`)
	if len(docs) == 0 {
		fmt.Fprint(w, `<p class="docs-empty muted">No docs yet. Type a title above to create one.</p>`)
	} else {
		fmt.Fprint(w, `<ul class="docs-items">`)
		for _, d := range docs {
			cls := "docs-item"
			if d.Slug == slug {
				cls += " active"
			}
			fmt.Fprintf(w, `<li class="%s"><a href="/chat/docs?d=%s">%s</a></li>`,
				cls, url.QueryEscape(d.Slug), html.EscapeString(d.Title))
		}
		fmt.Fprint(w, `</ul>`)
	}
	fmt.Fprint(w, `</aside>`)

	// Middle pane: title + textarea (or hint when no doc is selected).
	fmt.Fprint(w, `<section class="docs-edit">`)
	if slug == "" {
		if len(docs) == 0 {
			fmt.Fprint(w, `<p class="muted docs-hint">Create your first doc on the left to start writing.</p>`)
		} else {
			fmt.Fprint(w, `<p class="muted docs-hint">Pick a doc on the left, or create a new one.</p>`)
		}
	} else {
		fmt.Fprintf(w, `<div class="docs-title-row"><span class="docs-title">%s</span>`+
			`<span class="docs-status" id="docs-status"></span></div>`,
			html.EscapeString(titleFromSlug(slug)))
		fmt.Fprintf(w, `<textarea id="docs-body" data-slug="%s" spellcheck="true">%s</textarea>`,
			html.EscapeString(slug), html.EscapeString(body))
	}
	fmt.Fprint(w, `</section>`)

	// Right pane: live preview.
	fmt.Fprint(w, `<section class="docs-preview" id="docs-preview">`)
	if slug != "" {
		// Server-render the initial body so the preview isn't blank on page load
		// (and so a JS-disabled browser still gets a reasonable read view).
		fmt.Fprint(w, string(RenderChatMarkdown(body)))
	}
	fmt.Fprint(w, `</section>`)

	fmt.Fprint(w, `</div>`) // .docs-layout
	if slug != "" {
		fmt.Fprintf(w, `<script src="/chat/docs.js?v=%s"></script>`,
			url.QueryEscape(web.AssetVersion))
	}
	web.PageFooter(w)
}

// docsCSS — the three-pane grid + small editor chrome. Reuses chat fonts/
// colors so it visually belongs to the same subsystem.
const docsCSS = `<style>
html, body { height:100%; }
.app-body-wrap { margin:10px auto; padding:0 18px 10px; min-height:0;
                 max-width:1400px; display:flex; flex-direction:column; flex:1; }
.docs-layout { display:grid; grid-template-columns:220px 1fr 1fr; gap:14px;
               flex:1; min-height:0; }
.docs-list { border:1px solid #ddd; border-radius:8px; background:#fcfcf8;
             padding:10px; overflow-y:auto; min-height:0; display:flex;
             flex-direction:column; gap:10px; }
.docs-new { display:flex; gap:6px; }
.docs-new input { flex:1; min-width:0; padding:5px 7px; font-size:13px;
                  border:1px solid #ccc; border-radius:4px; font-family:inherit; }
.docs-new button { padding:5px 10px; font-size:13px; }
.docs-items { list-style:none; padding:0; margin:0; }
.docs-item { padding:0; margin:2px 0; }
.docs-item a { display:block; padding:5px 8px; border-radius:4px; color:#000080;
               text-decoration:none; font-size:13px; }
.docs-item a:hover { background:#eef0ff; }
.docs-item.active a { background:#000080; color:#fff; font-weight:bold; }
.docs-empty { font-size:12px; margin:0; }
.docs-edit { display:flex; flex-direction:column; min-width:0; min-height:0; gap:6px; }
.docs-title-row { display:flex; align-items:baseline; justify-content:space-between; gap:8px; }
.docs-title { font-size:15px; font-weight:bold; color:#000080; overflow:hidden;
              text-overflow:ellipsis; white-space:nowrap; }
.docs-status { font-size:12px; color:#888; flex:none; }
.docs-status.saving { color:#888; }
.docs-status.saved  { color:#1a7a3a; }
.docs-status.error  { color:#b00020; }
#docs-body { flex:1; min-height:0; width:100%; box-sizing:border-box;
             font-family:ui-monospace,Menlo,Consolas,monospace; font-size:14px;
             line-height:1.45; padding:10px; border:1px solid #ccc;
             border-radius:6px; resize:none; }
.docs-preview { border:1px solid #ddd; border-radius:8px; background:#fcfcf8;
                padding:14px 18px; overflow-y:auto; min-width:0; min-height:0;
                overflow-wrap:anywhere; }
.docs-preview p:first-child { margin-top:0; }
.docs-preview pre { background:#f4f4ec; padding:8px; border-radius:4px;
                    overflow-x:auto; }
.docs-preview img { max-width:100%; border-radius:6px; }
.docs-preview a.msg-ref { font-family:ui-monospace,Menlo,Consolas,monospace;
                          font-size:0.9em; background:#eaeaff; color:#000080;
                          padding:0 4px; border-radius:3px; text-decoration:none;
                          cursor:default; }
.docs-hint { margin-top:30px; text-align:center; }
@media (max-width: 900px) {
  .docs-layout { grid-template-columns:1fr; grid-auto-rows:minmax(180px, auto); }
}
</style>`
