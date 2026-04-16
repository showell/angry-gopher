// Package views serves HTML CRUD pages for authenticated users.
// Each page is a thin layer over the corresponding API, rendered
// as server-side HTML with Basic auth (browser caches credentials).
package views

import (
	"database/sql"
	"fmt"
	"html"
	"net/http"
	"time"

	"angry-gopher/auth"
)

var DB *sql.DB
var RenderMarkdown func(string) string
var lastAuthUserID int // set by RequireAuth, read by PageHeader

// RequireAuth returns the authenticated user ID or writes a 401
// response that triggers the browser's Basic auth prompt.
func RequireAuth(w http.ResponseWriter, r *http.Request) int {
	userID := auth.Authenticate(r)
	if userID == 0 {
		w.Header().Set("WWW-Authenticate", `Basic realm="Angry Gopher"`)
		http.Error(w, "Login required", http.StatusUnauthorized)
		return 0
	}
	lastAuthUserID = userID
	return userID
}

// currentUserName looks up the name for display in the nav.
func currentUserName(userID int) string {
	var name string
	DB.QueryRow(`SELECT full_name FROM users WHERE id = ?`, userID).Scan(&name)
	return name
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
.app-bottom { border-top: 1px solid #c9bfa7; padding: 10px 24px; font-size: 12px;
              color: #888; text-align: center; font-family: sans-serif; }
.app-bottom a { color: #000080; text-decoration: none; }
.app-bottom a:hover { text-decoration: underline; }
`

// AppChromeTop emits the global top bar. `current` should be one of
// "games" / "claude" / "docs" / "code" / "" (when not in any area).
// Pass empty for the home page or un-tagged pages.
func AppChromeTop(w http.ResponseWriter, current string) {
	areas := []struct{ key, label, href string }{
		{"claude", "Claude", "/gopher/claude"},
		{"code", "Code", "/gopher/code/"},
		{"docs", "Docs", "/gopher/docs/"},
		{"games", "Games", "/gopher/game-lobby"},
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

// AppChromeBottom emits the global bottom footer.
func AppChromeBottom(w http.ResponseWriter) {
	fmt.Fprint(w, `<footer class="app-bottom"><a href="/gopher/tour">All CRUD pages</a>&nbsp;·&nbsp;<a href="/admin/">Admin</a></footer>`)
}

// PageHeader writes the HTML boilerplate and opens the body. Use
// PageHeaderArea if this page belongs to one of the four major areas
// (Games/Claude/Docs/Code) so the top bar can highlight it.
func PageHeader(w http.ResponseWriter, title string) { PageHeaderArea(w, title, "") }

// PageHeaderArea is PageHeader plus an "area" key for top-bar
// highlighting. Pass "games" / "claude" / "docs" / "code", or ""
// for pages that don't belong to one.
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
	fmt.Fprint(w, NotificationWidget)
	AppChromeTop(w, area)
	fmt.Fprintf(w, `<div class="app-body-wrap"><h1>%s</h1>`, html.EscapeString(title))
}

// PageSubtitle renders a brief help/marketing blurb below the title.
func PageSubtitle(w http.ResponseWriter, text string) {
	fmt.Fprintf(w, `<p style="color:#666;font-size:13px;margin-top:-8px;margin-bottom:12px">%s</p>`, text)
}

// PageFooter closes the HTML.
func PageFooter(w http.ResponseWriter) {
	fmt.Fprint(w, `</div>`)
	AppChromeBottom(w)
	fmt.Fprint(w, `</body></html>`)
}

// FlashFromRequest checks for a flash= query param and renders it.
func FlashFromRequest(w http.ResponseWriter, r *http.Request) {
	msg := r.URL.Query().Get("flash")
	if msg != "" {
		fmt.Fprintf(w, `<div class="flash">%s</div>`, html.EscapeString(msg))
	}
}

// Breadcrumb renders a breadcrumb trail.
func Breadcrumb(w http.ResponseWriter, crumbs ...string) {
	// crumbs alternate: label, url, label, url, ..., final label (no url)
	fmt.Fprint(w, `<div class="breadcrumb">`)
	for i := 0; i < len(crumbs); i += 2 {
		if i > 0 {
			fmt.Fprint(w, ` <span>&rsaquo;</span> `)
		}
		label := crumbs[i]
		if i+1 < len(crumbs) {
			url := crumbs[i+1]
			fmt.Fprintf(w, `<a href="%s">%s</a>`, html.EscapeString(url), html.EscapeString(label))
		} else {
			fmt.Fprintf(w, `%s`, html.EscapeString(label))
		}
	}
	fmt.Fprint(w, `</div>`)
}

// TimeAgo returns a human-friendly relative time string.
func TimeAgo(timestamp int64) string {
	seconds := time.Now().Unix() - timestamp
	if seconds < 60 {
		return "just now"
	}
	minutes := seconds / 60
	if minutes < 60 {
		return fmt.Sprintf("%dm ago", minutes)
	}
	hours := minutes / 60
	if hours < 24 {
		return fmt.Sprintf("%dh ago", hours)
	}
	days := hours / 24
	if days < 30 {
		return fmt.Sprintf("%dd ago", days)
	}
	return time.Unix(timestamp, 0).Format("Jan 2")
}

// UserLink returns an HTML link to the user's page.
func UserLink(userID int, name string) string {
	return fmt.Sprintf(`<a href="/gopher/users?id=%d">%s</a>`, userID, html.EscapeString(name))
}

// ChannelLink returns an HTML link to the channel's topics page.
func ChannelLink(channelID int, name string) string {
	return fmt.Sprintf(`<a href="/gopher/messages?channel_id=%d">#%s</a>`, channelID, html.EscapeString(name))
}

// HandleIndex serves /gopher/ — the portal. Two top-level categories
// (Games, Wiki); secondary pages linked via /gopher/tour.
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
<div class="tag">Critter-sized server for games, docs, and small-team chat.</div>`)
	fmt.Fprint(w, `

<div class="cards">

  <div class="card">
    <h2><a href="/gopher/claude">Claude</a></h2>
    <p>Talk to Claude and see what he's working on. File issues; reply to DMs.</p>
    <ul>
      <li><a href="/gopher/claude-issues">Issues</a> <span class="muted">— active + recently shipped</span></li>
      <li><a href="/gopher/dm?user_id=2">DM Claude</a> <span class="muted">— ongoing conversation</span></li>
    </ul>
  </div>

  <div class="card">
    <h2><a href="/gopher/code/">Code</a></h2>
    <p>Browse source files and <code>.claude</code> sidecars across all tracked repos.</p>
    <ul>
      <li><a href="/gopher/code/">Repo tree</a> <span class="muted">— full filesystem</span></li>
      <li><a href="/gopher/code/views">views/</a> <span class="muted">— Gopher view handlers</span></li>
    </ul>
  </div>

  <div class="card">
    <h2><a href="/gopher/docs/">Docs</a></h2>
    <p>Curated markdown documentation — architecture, decisions, glossaries, testing notes.</p>
    <ul>
      <li><a href="/gopher/docs/">Docs home</a> <span class="muted">— repo READMEs</span></li>
      <li><a href="/gopher/docs/gopher/DECISIONS.md">Landmarks</a> <span class="muted">— DECISIONS, DATABASE, TESTING, GLOSSARY</span></li>
    </ul>
  </div>

  <div class="card">
    <h2><a href="/gopher/game-lobby">Games</a></h2>
    <p>Game hosting with a server-side referee. Play inside Angry Cat or on the CRUD pages.</p>
    <ul>
      <li><a href="/gopher/game-lobby">LynRummy</a> <span class="muted">— lobby + replay</span></li>
      <li><a href="/gopher/critters/">Critter studies</a> <span class="muted">— drag-and-drop behavioral studies</span></li>
    </ul>
  </div>

</div>
</div>`)
	AppChromeBottom(w)
	fmt.Fprint(w, `</body></html>`)
}
