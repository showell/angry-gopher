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
	"encoding/json"
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

// HandleDocs serves /chat/docs: the editor with no doc selected (doc list
// in the sidebar, a "pick or create" nudge in the middle). Individual docs
// live at /chat/docs/<slug> (HandleDocsItem); the list as JSON is at
// /chat/docs/list (HandleDocsList).
func HandleDocs(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/chat/docs" {
		http.NotFound(w, r)
		return
	}
	renderDocsEditor(w, r, "")
}

// HandleDocsItem serves /chat/docs/<slug> (the editor focused on one doc,
// for browsers) and /chat/docs/<slug>.md (the raw markdown — the literal
// file, for API clients). The .md form mirrors the on-disk path
// users/<uid>/docs/<slug>.md, with the uid implicit (the authenticated
// principal).
func HandleDocsItem(w http.ResponseWriter, r *http.Request) {
	slug := r.PathValue("slug")
	if strings.HasSuffix(slug, ".md") {
		serveRawDoc(w, r, strings.TrimSuffix(slug, ".md"))
		return
	}
	renderDocsEditor(w, r, slug)
}

// serveRawDoc returns a doc's raw markdown body. API-shaped auth (401, not
// an HTML login redirect) since this is the raw/bot path; acts on
// CurrentUser only, so you only ever read your own docs.
func serveRawDoc(w http.ResponseWriter, r *http.Request, slug string) {
	if !users.IsAuthorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	user := users.CurrentUser(r)
	path, err := docPath(user.ID, slug) // re-validates the slug
	if err != nil || !fileExists(path) {
		http.NotFound(w, r)
		return
	}
	body, err := ReadUserDoc(user.ID, slug)
	if err != nil {
		http.Error(w, "read doc: "+err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/markdown; charset=utf-8")
	_, _ = io.WriteString(w, body)
}

// renderDocsEditor renders the three-pane editor for the given slug ("" =
// no doc selected). Browser-facing, so unauthorized redirects to login and
// an unknown/invalid slug drops back to the bare editor.
func renderDocsEditor(w http.ResponseWriter, r *http.Request, slug string) {
	user := requireMember(w, r, r.URL.Path)
	if user.ID == "" {
		return
	}
	docs, err := ListUserDocs(user.ID)
	if err != nil {
		http.Error(w, "list docs: "+err.Error(), http.StatusInternalServerError)
		return
	}
	slug = strings.TrimSpace(slug)
	if slug != "" && (!validDocSlug(slug) || !docExists(docs, slug)) {
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

// HandleDocsList serves GET /chat/docs/list: a JSON listing of the
// authenticated principal's docs (slug + display title) for API-key
// clients. Passive read, acts on CurrentUser only. The browser reads the
// sidebar in the editor instead.
func HandleDocsList(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !users.IsAuthorized(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	user := users.CurrentUser(r)
	docs, err := ListUserDocs(user.ID)
	if err != nil {
		http.Error(w, "list docs: "+err.Error(), http.StatusInternalServerError)
		return
	}
	type docEntry struct {
		Slug  string `json:"slug"`
		Title string `json:"title"`
	}
	entries := make([]docEntry, 0, len(docs))
	for _, d := range docs {
		entries = append(entries, docEntry{Slug: d.Slug, Title: d.Title})
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(struct {
		Me   string     `json:"me"`
		Docs []docEntry `json:"docs"`
	}{Me: user.ID, Docs: entries})
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
	http.Redirect(w, r, "/chat/docs/"+url.PathEscape(slug), http.StatusSeeOther)
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

// HandleDocsPost appends the doc's current body as a chat message to the
// caller's default chat partner, and returns {conv, session, id} so the
// client can navigate to /chat/c/<conv>/<sid>#msg-<id> and land on the
// posted message. Today the default is hard-wired by the identity model:
// Steve (id 1) talks to Apoorva (id 2); everyone else talks to Steve.
func HandleDocsPost(w http.ResponseWriter, r *http.Request) {
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
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	slug := strings.TrimSpace(r.FormValue("slug"))
	if !validDocSlug(slug) {
		http.Error(w, "bad slug", http.StatusBadRequest)
		return
	}
	body, err := ReadUserDoc(user.ID, slug)
	if err != nil {
		http.Error(w, "read doc: "+err.Error(), http.StatusInternalServerError)
		return
	}
	if strings.TrimSpace(body) == "" {
		http.Error(w, "doc is empty", http.StatusBadRequest)
		return
	}
	partner := defaultChatPartner(user.ID)
	if !validChatPartner(user.ID, partner) {
		http.Error(w, "no default chat partner available", http.StatusBadRequest)
		return
	}
	conv := chatPairKey(user.ID, partner)
	sessionID := resolveSessionForUser(user.ID, partner)
	msg, err := AppendChatMessage(user, partner, sessionID, body, "")
	if err != nil {
		http.Error(w, "send to chat: "+err.Error(), http.StatusInternalServerError)
		return
	}
	users.TouchUser(user.ID)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"conv":    conv,
		"session": sessionID,
		"id":      msg.ID,
	})
}

// defaultChatPartner picks the partner id for a "post to chat" action.
// Hard-wired today (Steve talks to Apoorva; everyone else to Steve) —
// fits the current two-member reality. Generalize when there's actually
// a third member, not before.
func defaultChatPartner(uid string) string {
	const steveID = "1"
	const apoorvaID = "2"
	if uid == steveID {
		return apoorvaID
	}
	return steveID
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
	if !users.IsAuthorized(r) {
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
	// Cross-session new-message strip + favicon-violet alert, shared with
	// chat via /chat/notify.js. Empty (zero-height) until a ping arrives.
	fmt.Fprint(w, `<div class="docs-notify chat-notify" id="chat-notify"></div>`)
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
			fmt.Fprintf(w, `<li class="%s"><a href="/chat/docs/%s">%s</a></li>`,
				cls, url.PathEscape(d.Slug), html.EscapeString(d.Title))
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
			`<button type="button" id="docs-post-btn" class="docs-post-btn">Post to chat</button>`+
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

	// "Doc sent to chat" confirmation modal — shown by docs.js after a
	// successful POST to /chat/docs/post; OK navigates to the chat with
	// the partner id the server returned.
	if slug != "" {
		fmt.Fprint(w, `<dialog id="docs-posted-dialog" class="docs-alert-dialog">`+
			`<p>Doc sent to chat.</p>`+
			`<button type="button" id="docs-posted-ok">OK</button>`+
			`</dialog>`)
		fmt.Fprintf(w, `<script src="/chat/docs.js?v=%s"></script>`,
			url.QueryEscape(web.AssetVersion))
	}
	// notify.js loads even when no doc is open — the favicon-violet alert
	// and the #chat-notify status strip should work on the docs landing too.
	fmt.Fprintf(w, `<script src="/chat/notify.js?v=%s"></script>`,
		url.QueryEscape(web.AssetVersion))
	web.PageFooter(w)
}

// docsCSS — the three-pane grid + small editor chrome. Reuses chat fonts/
// colors so it visually belongs to the same subsystem.
const docsCSS = `<style>
html, body { height:100%; }
.app-body-wrap { margin:10px auto; padding:0 18px 10px; min-height:0;
                 max-width:1400px; display:flex; flex-direction:column; flex:1; }
.docs-notify:not(:empty) { margin-bottom:6px; }
.docs-layout { display:grid; grid-template-columns:220px 1fr 1fr; gap:14px;
               flex:1; min-height:0; }
.docs-list { border:1px solid var(--cc-border); border-radius:8px; background:var(--cc-card-bg);
             padding:10px; overflow-y:auto; min-height:0; display:flex;
             flex-direction:column; gap:10px; }
.docs-new { display:flex; gap:6px; }
.docs-new input { flex:1; min-width:0; padding:5px 7px; font-size:13px;
                  border:1px solid var(--cc-border); background:var(--cc-bg); color:var(--cc-fg);
                  border-radius:4px; font-family:inherit; }
.docs-new button { padding:5px 10px; font-size:13px; }
.docs-items { list-style:none; padding:0; margin:0; }
.docs-item { padding:0; margin:2px 0; }
.docs-item a { display:block; padding:5px 8px; border-radius:4px; color:var(--cc-accent);
               text-decoration:none; font-size:13px; }
.docs-item a:hover { background:var(--cc-search-sel-bg); }
.docs-item.active a { background:var(--cc-accent); color:var(--cc-bg); font-weight:bold; }
.docs-empty { font-size:12px; margin:0; }
.docs-edit { display:flex; flex-direction:column; min-width:0; min-height:0; gap:6px; }
.docs-title-row { display:flex; align-items:baseline; justify-content:space-between; gap:8px; }
.docs-title { font-size:15px; font-weight:bold; color:var(--cc-accent); overflow:hidden;
              text-overflow:ellipsis; white-space:nowrap; flex:1; min-width:0; }
.docs-post-btn { padding:4px 12px; font-size:12px; flex:none; }
.docs-status { font-size:12px; color:var(--cc-muted-fg); flex:none; }
.docs-status.saving { color:var(--cc-muted-fg); }
.docs-status.saved  { color:var(--cc-saved-fg); }
.docs-status.error  { color:var(--cc-error); }
.docs-alert-dialog { max-width:90vw; border:1px solid var(--cc-dialog-border);
                     background:var(--cc-bg); color:var(--cc-fg);
                     border-radius:8px; padding:18px 20px; }
.docs-alert-dialog::backdrop { background:var(--cc-backdrop); }
.docs-alert-dialog p { margin:0 0 14px; }
.docs-alert-dialog button { padding:5px 16px; }
#docs-body { flex:1; min-height:0; width:100%; box-sizing:border-box;
             font-family:ui-monospace,Menlo,Consolas,monospace; font-size:14px;
             line-height:1.45; padding:10px;
             border:1px solid var(--cc-border); background:var(--cc-bg); color:var(--cc-fg);
             border-radius:6px; resize:none; }
.docs-preview { border:1px solid var(--cc-border); border-radius:8px; background:var(--cc-card-bg);
                padding:14px 18px; overflow-y:auto; min-width:0; min-height:0;
                overflow-wrap:anywhere; }
.docs-preview p:first-child { margin-top:0; }
.docs-preview pre { background:var(--cc-code-bg); padding:8px; border-radius:4px;
                    overflow-x:auto; }
.docs-preview img { max-width:100%; border-radius:6px; }
.docs-preview a.msg-ref { font-family:ui-monospace,Menlo,Consolas,monospace;
                          font-size:0.9em; background:var(--cc-accent-soft-bg); color:var(--cc-accent);
                          padding:0 4px; border-radius:3px; text-decoration:none;
                          cursor:default; }
.docs-hint { margin-top:30px; text-align:center; }
@media (max-width: 900px) {
  .docs-layout { grid-template-columns:1fr; grid-auto-rows:minmax(180px, auto); }
}
</style>`
