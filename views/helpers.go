// Package views serves the Angry Gopher HTML pages: the Games
// surface (LynRummy + Puzzles) and the Claude essay-pointer.
package views

import (
	"fmt"
	"html"
	"net/http"

	"angry-gopher/auth"
)

// CurrentUser returns the username the request acts as. Hard-coded
// to Steve until login lands; this is the single seam every page
// goes through to learn who it's serving.
func CurrentUser(r *http.Request) string {
	return auth.CurrentUser(r)
}

// AppChromeCSS is the shared stylesheet for the app-wide top and
// bottom bars. Emitted by every page that uses AppChromeTop/Bottom.
const AppChromeCSS = `
.app-top { background: #f0ede4; border-bottom: 1px solid #c9bfa7; padding: 8px 24px;
           font-family: sans-serif; }
.app-top-home { font-size: 12px; }
.app-top-home a { color: #000080; text-decoration: none; font-weight: bold; }
.app-top-home a:hover { text-decoration: underline; }
.app-top-areas { margin-top: 4px; display: flex; gap: 18px; flex-wrap: wrap; }
.app-top-areas a { color: #000080; text-decoration: none; font-size: 14px; }
.app-top-areas a:hover { text-decoration: underline; }
.app-top-areas .current { font-weight: bold; background: #fff3a8; padding: 1px 6px; border-radius: 3px; }
`

// AppChromeTop emits the global top bar. `current` should be one of
// "games" / "claude" / "" (when not in any area).
func AppChromeTop(w http.ResponseWriter, current string) {
	areas := []struct{ key, label, href string }{
		{"games", "Games", "/gopher/game-lobby"},
		{"claude", "Claude", "/gopher/claude"},
	}
	fmt.Fprint(w, `<header class="app-top"><div class="app-top-home"><a href="/gopher/">← Gopher Home</a></div><div class="app-top-areas">`)
	for _, a := range areas {
		cls := ""
		if a.key == current {
			cls = ` class="current"`
		}
		fmt.Fprintf(w, `<a href="%s"%s>%s</a>`, a.href, cls, a.label)
	}
	fmt.Fprint(w, `</div></header>`)
}


// PageHeaderArea writes the HTML boilerplate and opens the body.
// `area` is the top-bar highlight key: "games", "claude", or "" for
// pages that don't belong to either.
func PageHeaderArea(w http.ResponseWriter, title, area string) {
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><title>%s — Angry Gopher</title>`, title)
	fmt.Fprint(w, `
<style>
body { font-family: sans-serif; margin: 0; padding: 0;
       display: flex; flex-direction: column; min-height: 100vh; }
.app-body-wrap { flex: 1; max-width: 820px; margin: 32px auto; padding: 0 24px 60px;
                 width: 100%; box-sizing: border-box; }`)
	fmt.Fprint(w, AppChromeCSS)
	fmt.Fprint(w, `
h1 { color: #000080; }
h2 { color: #000080; margin-top: 24px; }
a { color: #000080; }
nav { margin-bottom: 16px; font-size: 13px; }
nav a { margin-right: 12px; }
table { border-collapse: collapse; margin-top: 8px; width: 100%%; }
th { background: #000080; color: white; padding: 6px 12px; text-align: left; }
td { border-bottom: 1px solid #ccc; padding: 6px 12px; }
tr:hover td { background: #f0f0ff; }
.muted { color: #888; }
.msg-content { padding: 4px 0; }
textarea { width: 100%%; height: 60px; padding: 6px; box-sizing: border-box; margin: 8px 0; }
button { background: #000080; color: white; border: none; padding: 8px 16px;
         font-size: 14px; cursor: pointer; border-radius: 4px; }
button:hover { background: #0000a0; }
.back { margin-bottom: 16px; display: inline-block; }
.breadcrumb { margin-bottom: 12px; font-size: 13px; color: #888; }
.breadcrumb a { color: #000080; }
.breadcrumb span { margin: 0 4px; }
.flash { background: #c6f6c6; color: #1a7a3a; padding: 8px 12px; border-radius: 4px;
         margin-bottom: 12px; animation: fadeout 3s forwards; }
@keyframes fadeout { 0%% { opacity: 1; } 70%% { opacity: 1; } 100%% { opacity: 0; } }
.new-msg { border-left: 3px solid violet; padding-left: 8px; }
.compose-sticky { position: sticky; bottom: 0; background: white; padding: 8px 0;
                   border-top: 1px solid #ccc; margin-top: 12px; }
.cards { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-top: 20px; }
@media (max-width: 640px) { .cards { grid-template-columns: 1fr; } }
.card { border: 1px solid #ccc; border-radius: 6px; padding: 20px; background: #fcfcf8; }
.card h2 { margin: 0 0 8px; font-size: 22px; }
.card h2 a { color: #000080; text-decoration: none; }
.card h2 a:hover { text-decoration: underline; }
.card p { color: #444; margin: 0 0 12px; font-size: 14px; }
.card ul { list-style: none; padding: 0; margin: 0; }
.card li { padding: 4px 0; }
.card ul a { color: #000080; text-decoration: none; font-weight: bold; }
.card ul a:hover { text-decoration: underline; }
.card .muted { color: #888; font-weight: normal; }
</style>
</head><body>
`)
	AppChromeTop(w, area)
	fmt.Fprintf(w, `<div class="app-body-wrap"><h1>%s</h1>`, html.EscapeString(title))
}

// PageSubtitle renders a brief help/marketing blurb below the title.
func PageSubtitle(w http.ResponseWriter, text string) {
	fmt.Fprintf(w, `<p style="color:#666;font-size:13px;margin-top:-8px;margin-bottom:12px">%s</p>`, text)
}

// PageFooter closes the HTML.
func PageFooter(w http.ResponseWriter) {
	fmt.Fprint(w, `</div></body></html>`)
}

// HandleIndex serves /gopher/ — the portal. Two top-level categories:
// Games and Claude.
func HandleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/gopher/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprint(w, `<!DOCTYPE html>
<html><head><title>Angry Gopher</title>
<style>
body { font-family: sans-serif; margin: 0; padding: 0;
       display: flex; flex-direction: column; min-height: 100vh; }
.app-body-wrap { flex: 1; max-width: 780px; margin: 40px auto 0; padding: 0 24px 40px;
                 width: 100%; box-sizing: border-box; }
h1 { color: #000080; font-size: 34px; margin-bottom: 4px; }
.tag { color: #888; font-size: 13px; margin-bottom: 40px; }
.cards { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
@media (max-width: 640px) { .cards { grid-template-columns: 1fr; } }
.card { border: 1px solid #ccc; border-radius: 6px; padding: 20px; background: #fcfcf8; }
.card h2 { margin: 0 0 8px; font-size: 22px; }
.card h2 a { color: #000080; text-decoration: none; }
.card h2 a:hover { text-decoration: underline; }
.card p { color: #444; margin: 0 0 12px; font-size: 14px; }
.card ul { list-style: none; padding: 0; margin: 0; }
.card li { padding: 4px 0; }
.card ul a { color: #000080; text-decoration: none; font-weight: bold; }
.card ul a:hover { text-decoration: underline; }
.card .muted { color: #888; font-weight: normal; }
` + AppChromeCSS + `
</style>
</head><body>`)
	AppChromeTop(w, "")
	fmt.Fprint(w, `<div class="app-body-wrap">
<h1>Angry Gopher</h1>
<div class="tag">Critter-sized server for LynRummy and Steve-Claude essays.</div>`)
	if user := CurrentUser(r); user == auth.DefaultUser {
		fmt.Fprint(w, `<div class="tag"><a href="/gopher/login">Log in with your name →</a></div>`)
	} else {
		fmt.Fprintf(w, `<div class="tag">Playing as <strong>%s</strong> · <a href="/gopher/login">change</a></div>`, html.EscapeString(user))
	}
	fmt.Fprint(w, `

<div class="cards">

  <div class="card">
    <h2><a href="/gopher/game-lobby">Games</a></h2>
    <p>LynRummy, via the Elm client.</p>
    <ul>
      <li><a href="/gopher/lynrummy-elm/">Play</a></li>
      <li><a href="/gopher/lynrummy-elm/sessions">Sessions</a></li>
      <li><a href="/gopher/puzzle/">Puzzle</a></li>
    </ul>
  </div>

  <div class="card">
    <h2><a href="/gopher/claude">Claude</a></h2>
    <p>Collaboration patterns and the essay format live in <a href="https://github.com/showell/claude-collab">claude-collab</a>.</p>
    <ul>
      <li><a href="http://localhost:9100">Local essay server</a> <span class="muted">— port 9100</span></li>
      <li><a href="https://github.com/showell/claude-collab">GitHub README</a></li>
    </ul>
  </div>

</div>
</div></body></html>`)
}
