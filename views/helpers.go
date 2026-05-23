// Package views serves the Angry Gopher HTML pages: the Lyn Rummy
// home/lobby, the full-game and puzzles surfaces, login, and admin.
package views

import (
	"fmt"
	"html"
	"net/http"

	"angry-gopher/auth"
)

// CurrentUser resolves the identity a request acts as. A valid member
// session is authoritative. Otherwise it's the guest named by the
// gopher_uid cookie — but only if that id is a NON-member; a uid pointing
// at a member without a session is a forge attempt and is ignored.
// Returns the zero User (ID == "") when there's no valid identity.
func CurrentUser(r *http.Request) User {
	if id, ok := SessionUser(r); ok {
		return LoadUser(id)
	}
	// An API key authenticates a member for read-only access; it is never
	// an admin credential, so strip Admin (the login gate also blocks any
	// non-GET key request).
	if id, ok := apiKeyUser(r); ok {
		u := LoadUser(id)
		u.Admin = false
		return u
	}
	id := auth.CurrentUID(r)
	if id != "" && UserExists(id) && !UserIsMember(id) {
		return LoadUser(id)
	}
	return User{}
}

// AppChromeCSS is the shared stylesheet for the app top bar.
const AppChromeCSS = `
.app-top { background: #f0ede4; border-bottom: 1px solid #c9bfa7; padding: 8px 24px;
           font-family: sans-serif; display: flex; justify-content: space-between;
           align-items: baseline; }
.app-top-home a { color: #000080; text-decoration: none; font-weight: bold; }
.app-top-home a:hover { text-decoration: underline; }
.app-top-user { font-size: 13px; color: #444; }
.app-top-user a { color: #000080; }
`

// AppChromeTop emits the top bar: a home link, who you're playing as, an
// Admin link for admins, and logout.
func AppChromeTop(w http.ResponseWriter, user User) {
	adminLink := ""
	if user.Admin {
		adminLink = ` · <a href="/admin">Admin</a>`
	}
	fmt.Fprintf(w,
		`<header class="app-top"><div class="app-top-home"><a href="/">Lyn Rummy</a></div>`+
			`<div class="app-top-user">Playing as <strong>%s</strong>%s · <a href="/logout">Log out</a></div></header>`,
		html.EscapeString(user.Name), adminLink)
}

// PageHeader writes the HTML boilerplate, top bar, and opens the body.
func PageHeader(w http.ResponseWriter, title string, user User) {
	fmt.Fprint(w, `<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>♦️ Lyn Rummy ♥️</title>`)
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
.chat-nav { margin: -4px 0 16px; font-size: 14px; }
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
	AppChromeTop(w, user)
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
