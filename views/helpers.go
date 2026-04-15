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

// PageHeader writes the HTML boilerplate and opens the body.
func PageHeader(w http.ResponseWriter, title string) {
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><title>%s — Angry Gopher</title>`, title)
	fmt.Fprint(w, `
<style>
body { font-family: sans-serif; margin: 40px; max-width: 700px; padding-bottom: 100px; }
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
</style>
</head><body>
<nav>
<a href="/gopher/">Home</a>
`)
	for _, p := range GetPages() {
		if p.NavLabel == "" {
			// Self-registered pages with no nav label are routes
			// only (e.g. /gopher/game-replay linked from a detail
			// view, not a top-level nav entry).
			continue
		}
		fmt.Fprintf(w, `<a href="%s">%s</a> `, p.Path, p.NavLabel)
	}
	fmt.Fprintf(w, `<span style="float:right;color:#888">%s</span>
</nav>
<h1>%s</h1>`, html.EscapeString(currentUserName(lastAuthUserID)), title)
}

// PageSubtitle renders a brief help/marketing blurb below the title.
func PageSubtitle(w http.ResponseWriter, text string) {
	fmt.Fprintf(w, `<p style="color:#666;font-size:13px;margin-top:-8px;margin-bottom:12px">%s</p>`, text)
}

// PageFooter closes the HTML.
func PageFooter(w http.ResponseWriter) {
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

// HandleIndex serves /gopher/ — the master page linking to all views.
func HandleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/gopher/" {
		http.NotFound(w, r)
		return
	}
	userID := RequireAuth(w, r)
	if userID == 0 {
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	PageHeader(w, "Angry Gopher")

	fmt.Fprint(w, `<div style="display:flex;flex-direction:column;gap:12px;margin-top:8px">`)
	for _, p := range GetPages() {
		fmt.Fprintf(w, `<a href="%s" style="font-size:18px;font-weight:bold">%s</a>
<span class="muted">%s</span>`, p.Path, p.Title, p.Subtitle)
	}
	fmt.Fprint(w, `</div>`)

	PageFooter(w)
}
