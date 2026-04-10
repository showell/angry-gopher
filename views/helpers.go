// Package views serves HTML CRUD pages for authenticated users.
// Each page is a thin layer over the corresponding API, rendered
// as server-side HTML with Basic auth (browser caches credentials).
package views

import (
	"database/sql"
	"fmt"
	"html"
	"net/http"

	"angry-gopher/auth"
)

var DB *sql.DB
var RenderMarkdown func(string) string

// RequireAuth returns the authenticated user ID or writes a 401
// response that triggers the browser's Basic auth prompt.
func RequireAuth(w http.ResponseWriter, r *http.Request) int {
	userID := auth.Authenticate(r)
	if userID == 0 {
		w.Header().Set("WWW-Authenticate", `Basic realm="Angry Gopher"`)
		http.Error(w, "Login required", http.StatusUnauthorized)
		return 0
	}
	return userID
}

// PageHeader writes the HTML boilerplate and opens the body.
func PageHeader(w http.ResponseWriter, title string) {
	fmt.Fprintf(w, `<!DOCTYPE html>
<html><head><title>%s — Angry Gopher</title>
<style>
body { font-family: sans-serif; margin: 40px; max-width: 700px; }
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
</style>
</head><body>
<nav>
<a href="/gopher/">Home</a>
<a href="/gopher/messages">Messages</a>
<a href="/gopher/channels">Channels</a>
<a href="/gopher/dm">DMs</a>
<a href="/gopher/users">Users</a>
<a href="/gopher/buddies">Buddies</a>
<a href="/gopher/github">GitHub</a>
<a href="/gopher/search">Search</a>
<a href="/gopher/game-lobby">Games</a>
<a href="/gopher/invites-view">Invites</a>
</nav>
<h1>%s</h1>`, title, title)
}

// PageFooter closes the HTML.
func PageFooter(w http.ResponseWriter) {
	fmt.Fprint(w, `</body></html>`)
}

// UserLink returns an HTML link to the user's page.
func UserLink(userID int, name string) string {
	return fmt.Sprintf(`<a href="/gopher/users?id=%d">%s</a>`, userID, html.EscapeString(name))
}

// ChannelLink returns an HTML link to the channel's page.
func ChannelLink(channelID int, name string) string {
	return fmt.Sprintf(`<a href="/gopher/channels?id=%d">#%s</a>`, channelID, html.EscapeString(name))
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

	fmt.Fprint(w, `<div style="display:flex;flex-direction:column;gap:12px;margin-top:8px">
<a href="/gopher/messages" style="font-size:18px;font-weight:bold">Messages</a>
<span class="muted">Browse channels, topics, and messages</span>
<a href="/gopher/channels" style="font-size:18px;font-weight:bold">Channels</a>
<span class="muted">List, create, and edit channels</span>
<a href="/gopher/dm" style="font-size:18px;font-weight:bold">Direct Messages</a>
<span class="muted">1:1 conversations</span>
<a href="/gopher/users" style="font-size:18px;font-weight:bold">Users</a>
<span class="muted">User directory, edit your profile</span>
<a href="/gopher/buddies" style="font-size:18px;font-weight:bold">Buddies</a>
<span class="muted">Manage your buddy list</span>
<a href="/gopher/github" style="font-size:18px;font-weight:bold">GitHub</a>
<span class="muted">Configure GitHub webhook integrations</span>
<a href="/gopher/search" style="font-size:18px;font-weight:bold">Search</a>
<span class="muted">Find messages by channel, topic, and sender</span>
<a href="/gopher/game-lobby" style="font-size:18px;font-weight:bold">Games</a>
<span class="muted">Game lobby — create, join, and view games</span>
<a href="/gopher/invites-view" style="font-size:18px;font-weight:bold">Invitations</a>
<span class="muted">View and revoke invitations (admin)</span>
</div>`)

	PageFooter(w)
}
